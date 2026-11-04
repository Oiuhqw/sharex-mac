#if SHAREX_E2E
import AppKit
import ApplicationServices
import Darwin
import KeyboardShortcuts
import ShareXCore

@MainActor
enum E2ESettings {
    private struct ShortcutState: Codable, Equatable {
        let name: String
        let shortcut: KeyboardShortcuts.Shortcut?
    }

    private static func shortcutState() -> [ShortcutState] {
        Hotkeys.commands.map { ShortcutState(name: $0.name.rawValue, shortcut: KeyboardShortcuts.getShortcut(for: $0.name)) }
    }

    static func verifyPersistence(_ out: String) -> Bool {
        let url = URL(fileURLWithPath: out).appendingPathComponent("settings-shortcuts-expected.json")
        guard let data = try? Data(contentsOf: url),
              let expected = try? JSONDecoder().decode([ShortcutState].self, from: data) else { return false }
        return expected.count == 8 && shortcutState() == expected
    }

    private static let accessibility = SettingsAXClient()

    private static func activate(_ window: NSWindow) async -> Bool {
        var activated = false
        var info: [String: Any] = ["appActiveBefore": NSApp.isActive, "windowKeyBefore": window.isKeyWindow,
                                   "frontmostPIDBefore": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
        defer {
            info["appActive"] = NSApp.isActive
            info["windowKey"] = window.isKeyWindow
            info["frontmostPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            E2E.record("settings-activation", activated, info)
        }
        window.orderFrontRegardless()
        await E2E.wait(100)
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let titlebar = NSRect(x: frame.minX + 100, y: content.maxY + 2,
                              width: frame.width - 200, height: frame.maxY - content.maxY - 4)
        let point = NSPoint(x: titlebar.midX, y: titlebar.midY)
        guard window.isVisible, !window.isMiniaturized, window.styleMask.contains(.titled),
              titlebar.width > 0, titlebar.height > 0,
              [point.x, point.y, titlebar.width, titlebar.height].allSatisfy({ $0.isFinite }),
              frame.contains(point), !content.contains(point),
              window.screen?.visibleFrame.contains(point) == true,
              let screenTop = NSScreen.screens.first?.frame.maxY, screenTop.isFinite else {
            info["error"] = "Settings has no safe visible titlebar point"
            return false
        }
        let pointer = CGPoint(x: point.x, y: screenTop - point.y)
        let hitWindow = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        let canPost = CGPreflightPostEventAccess()
        info["titlebarPoint"] = NSStringFromPoint(point)
        info["pointerPoint"] = NSStringFromPoint(pointer)
        info["hitWindow"] = hitWindow
        info["settingsWindow"] = window.windowNumber
        info["canPostEvents"] = canPost
        guard pointer.x.isFinite, pointer.y.isFinite, hitWindow == window.windowNumber, canPost else {
            info["error"] = "Settings titlebar is not the pointer target or HID posting is unavailable"
            return false
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
        let events = types.compactMap {
            CGEvent(mouseEventSource: nil, mouseType: $0, mouseCursorPosition: pointer, mouseButton: .left)
        }
        guard events.count == types.count else {
            info["error"] = "Could not create Settings activation events"
            return false
        }
        for event in events {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        activated = await E2E.until(2000) { NSApp.isActive && window.isKeyWindow }
        return activated
    }

    private static func recorders(in window: NSWindow) -> [KeyboardShortcuts.RecorderCocoa] {
        var result: [KeyboardShortcuts.RecorderCocoa] = []
        func visit(_ view: NSView) {
            if let recorder = view as? KeyboardShortcuts.RecorderCocoa { result.append(recorder) }
            for child in view.subviews { visit(child) }
        }
        if let content = window.contentView { visit(content) }
        return result
    }

    private static func element(_ id: String, in window: NSWindow) async -> SettingsAXClient.Element? {
        await accessibility.find(id, in: window.title)
    }

    @discardableResult
    private static func press(_ id: String, in window: NSWindow) async -> Bool {
        guard let target = await element(id, in: window) else { return false }
        return click(target, in: window)
    }

    @discardableResult
    private static func click(_ target: SettingsAXClient.Element, in window: NSWindow) -> Bool {
        let frame = target.frame
        guard window.isKeyWindow, NSApp.isActive,
              frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              let content = window.contentView else { return false }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: screenTop - frame.midY))
        guard content.bounds.contains(content.convert(point, from: nil)) else { return false }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow,
                            flags: NSEvent.ModifierFlags = [], synchronously: Bool = false) {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                if synchronously { NSApp.sendEvent(event) }
                else { NSApp.postEvent(event, atStart: false) }
            }
        }
    }

    private static func navigate(_ page: String, in window: NSWindow) async -> Bool {
        guard let target = await element("settings.page.\(page)", in: window) else {
            E2E.record("settings-navigation-\(page)", false, ["error": "sidebar item absent"])
            return false
        }
        let clicked = click(target, in: window)
        let identifiers = ["capture": "settings.capture.cursor", "shortcuts": "settings.shortcuts.search", "output": "settings.output.saveToFile"]
        var arrived = false
        if let identifier = identifiers[page] {
            for _ in 0..<15 {
                if await element(identifier, in: window) != nil { arrived = true; break }
                await E2E.wait(100)
            }
        }
        E2E.record("settings-navigation-\(page)", clicked && arrived, ["targetFrame": NSStringFromRect(target.frame),
                   "windowKey": window.isKeyWindow, "appActive": NSApp.isActive])
        return clicked && arrived
    }

    private static func screenshot(_ name: String, window: NSWindow) async {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            E2E.record(name, false, ["error": "no window bitmap"]); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                E2E.record(name, false, ["error": "PNG encoding failed"]); return
            }
            try png.write(to: E2E.out.appendingPathComponent("\(name).png"))
            E2E.record(name, bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0,
                       ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
        } catch { E2E.record(name, false, ["error": error.localizedDescription]) }
        let snapshot = await accessibility.snapshot(in: window.title)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: E2E.out.appendingPathComponent("\(name)-accessibility.json"))
            if let error = snapshot.error { NSLog("E2E AX diagnostic %@ incomplete: %@", name, error) }
        } catch { E2E.record("\(name)-accessibility", false, ["error": error.localizedDescription]) }
    }

    private static func recorder(_ id: String, in window: NSWindow) -> KeyboardShortcuts.RecorderCocoa? {
        recorders(in: window)
            .first { $0.accessibilityIdentifier() == "settings.shortcut.\(id).recorder" }
    }

    private static func feedback(in window: NSWindow) async -> String {
        await element("settings.shortcuts.feedback", in: window)?.text ?? ""
    }

    private static func focusRecorder(_ id: String, in window: NSWindow) async -> Bool {
        guard let field = await element("settings.shortcut.\(id).recorder", in: window) else { return false }
        guard click(field, in: window) else { return false }
        await E2E.wait(80)
        return true
    }

    private static func prepareSheetDismissal(_ button: String, in window: NSWindow) -> Task<SettingsAXClient.ModalResult, Never> {
        let client = accessibility
        let title = window.title
        return Task.detached { await client.dismissSheet(button, in: title) }
    }

    private static func restoreShortcuts(dismissing button: String, in window: NSWindow) async -> SettingsAXClient.ModalResult {
        guard let control = await element("settings.shortcuts.restoreAll", in: window) else {
            return .init(shown: false, pressed: false)
        }
        let response = prepareSheetDismissal(button, in: window)
        guard click(control, in: window) else {
            response.cancel()
            _ = await response.value
            return .init(shown: false, pressed: false)
        }
        return await response.value
    }

    private static func search(_ text: String, in window: NSWindow) async -> Bool {
        guard let field = await element("settings.shortcuts.search", in: window) else { return false }
        guard click(field, in: window) else { return false }
        await E2E.wait(60)
        key(0, "a", in: window, flags: .command)
        key(51, "\u{7f}", in: window)
        for character in text { key(0, String(character), in: window) }
        await E2E.wait(160)
        return true
    }

    private static func rowAction(_ id: String, restore: Bool, in window: NSWindow) async -> Bool {
        guard let options = await element("settings.shortcut.\(id).options", in: window) else { return false }
        guard click(options, in: window) else { return false }
        let selection = Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            let codes: [CGKeyCode] = restore ? [125, 125, 36] : [125, 36]
            for code in codes {
                for down in [true, false] {
                    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        await selection.value
        await E2E.wait(180)
        return true
    }

    private static func dismissSheet(_ title: String, in window: NSWindow) async -> Bool {
        await accessibility.dismissSheet(title, in: window.title).pressed
    }

    static func run() async {
        await runScenario()
        let failures = await accessibility.takeFailures()
        E2E.record("settings-accessibility-helper-health", failures.isEmpty, ["errors": failures])
    }

    private static func runScenario() async {
        let settings = E2E.app.settings.value
        let oldShortcuts = Hotkeys.commands.map { ($0.name, KeyboardShortcuts.getShortcut(for: $0.name)) }
        var keepPersistenceFixture = false
        defer {
            E2E.app.settings.update { $0 = settings }
            if !keepPersistenceFixture {
                for (name, shortcut) in oldShortcuts { KeyboardShortcuts.setShortcut(shortcut, for: name) }
            }
            E2E.app.settingsWindow?.close()
        }

        E2E.app.openSettings()
        guard let window = E2E.app.settingsWindow else { E2E.record("settings-open", false); return }
        window.setContentSize(NSSize(width: 760, height: 560))
        await E2E.wait(250)
        E2E.record("settings-resizable", window.styleMask.contains(.resizable) && window.contentMinSize.width >= 700)
        guard await activate(window) else { return }

        let focusBefore: [String: Any] = ["appActive": NSApp.isActive, "windowKey": window.isKeyWindow,
                                          "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
        NSLog("E2E Settings focus before first AX request: %@", "\(focusBefore)")
        let capture = await element("settings.capture.cursor", in: window) != nil
        let focusAfter: [String: Any] = ["appActive": NSApp.isActive, "windowKey": window.isKeyWindow,
                                         "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
        NSLog("E2E Settings focus after first AX request: %@", "\(focusAfter)")
        let retainedFocus = NSApp.isActive && window.isKeyWindow
        E2E.record("settings-focus-after-accessibility", retainedFocus, ["before": focusBefore, "after": focusAfter])
        E2E.record("settings-initial-capture-page", capture)
        guard retainedFocus else { return }
        let cursor = E2E.app.settings.value.options.showCursor
        let toggledCursor = await press("settings.capture.cursor", in: window)
        await E2E.wait(100)
        E2E.record("settings-capture-toggle-persists", capture && toggledCursor
                   && SettingsStore().value.options.showCursor == !cursor,
                   ["navigation": capture, "pressed": toggledCursor, "before": cursor,
                    "after": SettingsStore().value.options.showCursor])
        await screenshot("settings-capture", window: window)

        let output = await navigate("output", in: window)
        let save = E2E.app.settings.value.saveToFile
        let toggledSave = await press("settings.output.saveToFile", in: window)
        await E2E.wait(100)
        E2E.record("settings-output-toggle-persists", output && toggledSave && SettingsStore().value.saveToFile == !save,
                   ["navigation": output, "pressed": toggledSave, "before": save,
                    "after": SettingsStore().value.saveToFile])
        _ = await press("settings.output.saveToFile", in: window)
        let folderBefore = E2E.app.settings.value.saveFolder
        let chooser = await press("settings.output.chooseFolder", in: window)
        let sheetOpened = await E2E.until(1500) { window.attachedSheet != nil }
        if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
        else { _ = await dismissSheet("Cancel", in: window) }
        let sheetClosed = await E2E.until(1500) { window.attachedSheet == nil }
        E2E.record("settings-folder-chooser-cancel", chooser && sheetOpened && sheetClosed
                   && E2E.app.settings.value.saveFolder == folderBefore)
        let selectedFolder = E2E.out.appendingPathComponent("settings-selected-folder", isDirectory: true)
        do { try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true) }
        catch { E2E.record("settings-folder-chooser-setup", false, ["error": error.localizedDescription]); return }
        let chooseAgain = await press("settings.output.chooseFolder", in: window)
        let selectionOpened = await E2E.until(1500) { window.attachedSheet is NSOpenPanel }
        if let panel = window.attachedSheet as? NSOpenPanel { panel.directoryURL = selectedFolder }
        await E2E.wait(200)
        let acceptedFolder = await dismissSheet("Choose Folder", in: window)
        let selectionClosed = await E2E.until(1500) { window.attachedSheet == nil }
        E2E.record("settings-folder-chooser-accept-persists", chooseAgain && selectionOpened && acceptedFolder && selectionClosed
                   && folderBefore != selectedFolder.path && SettingsStore().value.saveFolder == selectedFolder.path)
        if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
        await E2E.wait(100)
        let defaultFolder = await press("settings.output.defaultFolder", in: window)
        await E2E.wait(100)
        let folderVisible = await element("settings.output.folder", in: window) != nil
        E2E.record("settings-folder-default-persists", defaultFolder && SettingsStore().value.saveFolder.isEmpty
                   && folderVisible)
        await screenshot("settings-output", window: window)

        _ = await navigate("capture", in: window)
        let shortcutsPage = await navigate("shortcuts", in: window)
        let nativeRecorders = recorders(in: window)
        E2E.record("settings-eight-labeled-native-recorders", shortcutsPage && nativeRecorders.count == 8
                   && nativeRecorders.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty }, ["count": nativeRecorders.count])
        await screenshot("settings-shortcuts", window: window)
        window.setContentSize(NSSize(width: 900, height: 850))
        window.center()
        await E2E.wait(200)
        await screenshot("settings-shortcuts-expanded", window: window)

        _ = await search("frontmost", in: window)
        E2E.record("settings-shortcut-search-description", recorder("activeWindow", in: window) != nil
                   && recorder("region", in: window) == nil)
        _ = await search("no-such-command", in: window)
        let emptySearch = await element("settings.shortcuts.empty", in: window) != nil
        E2E.record("settings-shortcut-search-empty", emptySearch)
        _ = await search("Region", in: window)
        guard let region = recorder("region", in: window) else {
            E2E.record("settings-shortcut-native-record", false, ["error": "region recorder absent"]); return
        }
        let custom = KeyboardShortcuts.Shortcut(.eight, modifiers: [.control, .option, .shift])
        _ = await focusRecorder("region", in: window)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        let recorded = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .region) == custom }
        E2E.record("settings-shortcut-native-record", recorded && region.stringValue == custom.description)

        guard recorder("lastRegion", in: window) != nil else {
            E2E.record("settings-shortcut-conflict", false, ["error": "last-region recorder absent"]); return
        }
        let previous = KeyboardShortcuts.getShortcut(for: .lastRegion)
        _ = await focusRecorder("lastRegion", in: window)
        let conflictDeadline = SettingsModalDeadline(window: window)
        let conflictResponse = prepareSheetDismissal("OK", in: window)
        key(28, "8", in: window, flags: [.control, .option, .shift], synchronously: true)
        let conflict = conflictDeadline.finish(await conflictResponse.value)
        await E2E.wait(100)
        let conflictText = await feedback(in: window)
        E2E.record("settings-shortcut-conflict", conflict.shown && conflict.pressed
                   && KeyboardShortcuts.getShortcut(for: .lastRegion) == previous
                   && KeyboardShortcuts.getShortcut(for: .region) == custom
                   && conflictText.contains("Region"), ["feedback": conflictText])
        key(53, "\u{1b}", in: window)
        await E2E.wait(80)
        let cleared = await rowAction("region", restore: false, in: window)
        E2E.record("settings-shortcut-clear", cleared && KeyboardShortcuts.getShortcut(for: .region) == nil)
        _ = await focusRecorder("lastRegion", in: window)
        key(18, "1", in: window, flags: [.control, .shift])
        let movedDefault = await E2E.until(1500) {
            KeyboardShortcuts.getShortcut(for: .lastRegion) == KeyboardShortcuts.Name.region.initialShortcut
        }
        let beforeRestoreFeedback = await feedback(in: window)
        let blockedRestore = await rowAction("region", restore: true, in: window)
        let restoreFeedback = await feedback(in: window)
        E2E.record("settings-shortcut-default-conflict", movedDefault && blockedRestore
                   && KeyboardShortcuts.getShortcut(for: .region) == nil
                   && KeyboardShortcuts.getShortcut(for: .lastRegion) == KeyboardShortcuts.Name.region.initialShortcut
                   && restoreFeedback != beforeRestoreFeedback && restoreFeedback.contains("used by \(CaptureStyle.lastRegion.title)"),
                   ["feedback": restoreFeedback])
        let noDefaultCleared = await rowAction("lastRegion", restore: true, in: window)
        E2E.record("settings-shortcut-unassigned-default", noDefaultCleared && KeyboardShortcuts.getShortcut(for: .lastRegion) == nil)
        let restored = await rowAction("region", restore: true, in: window)
        E2E.record("settings-shortcut-default", restored
                   && KeyboardShortcuts.getShortcut(for: .region) == KeyboardShortcuts.Name.region.initialShortcut)

        _ = await focusRecorder("region", in: window)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        _ = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .region) == custom }
        let cancelled = await restoreShortcuts(dismissing: "Cancel", in: window)
        await E2E.wait(100)
        E2E.record("settings-shortcut-restore-confirmation", cancelled.shown && cancelled.pressed
                   && KeyboardShortcuts.getShortcut(for: .region) == custom)
        let restoreAll = await restoreShortcuts(dismissing: "Restore Defaults", in: window)
        await E2E.wait(100)
        E2E.record("settings-shortcut-restore-all", restoreAll.shown && restoreAll.pressed && Hotkeys.commands.allSatisfy {
            KeyboardShortcuts.getShortcut(for: $0.name) == $0.name.initialShortcut
        })

        _ = await focusRecorder("lastRegion", in: window)
        let persisted = KeyboardShortcuts.Shortcut(.nine, modifiers: [.control, .option, .shift])
        key(25, "9", in: window, flags: [.control, .option, .shift])
        let persistedRecorded = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .lastRegion) == persisted }
        do {
            try JSONEncoder().encode(shortcutState()).write(to: E2E.out.appendingPathComponent("settings-shortcuts-expected.json"))
            keepPersistenceFixture = persistedRecorded
            E2E.record("settings-shortcut-persistence-fixture", persistedRecorded && verifyPersistence(E2E.out.path))
        } catch { E2E.record("settings-shortcut-persistence-fixture", false, ["error": error.localizedDescription]) }

        window.close()
        E2E.setOpts { $0.options.openEditor = true; $0.options.delaySeconds = 0 }
        let canPostEvents = CGPreflightPostEventAccess()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 25, keyDown: down)
            event?.flags = [.maskControl, .maskAlternate, .maskShift]
            event?.post(tap: .cghidEventTap)
        }
        let fired = await E2E.until(2000) { E2E.surface() != nil }
        if fired { E2E.esc(); _ = await E2E.until { !E2E.coord.busy } }
        E2E.record("settings-custom-shortcut-capture", persistedRecorded && fired,
                   ["eventPostingPermitted": canPostEvents,
                    "note": "Synthetic HID event after closing Settings; a physical key press needs a Mac."],
                   status: !canPostEvents && !fired && persistedRecorded ? "unverifiable" : nil)
    }
}

@MainActor
private final class SettingsModalDeadline: NSObject {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var expired = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        let timer = Timer(timeInterval: 6, target: self, selector: #selector(expire(_:)), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    func finish(_ result: SettingsAXClient.ModalResult) -> SettingsAXClient.ModalResult {
        timer?.invalidate()
        timer = nil
        return .init(shown: result.shown, pressed: result.pressed && !expired)
    }

    @objc private func expire(_: Timer) {
        expired = true
        guard let window, let sheet = window.attachedSheet else { return }
        if NSApp.modalWindow === sheet { NSApp.abortModal() }
        window.endSheet(sheet, returnCode: .abort)
        sheet.orderOut(nil)
    }
}

private actor SettingsAXClient {
    struct Element: Codable, Sendable {
        let identifier: String
        let role: String
        let title: String
        let label: String
        let value: String
        let frame: CGRect
        var text: String { [label, title, value].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    struct Snapshot: Codable, Sendable {
        let elements: [Element]
        let trusted: Bool
        let error: String?
        let issues: [AttributeIssue]
    }

    struct AttributeIssue: Codable, Sendable {
        let role: String
        let attribute: String
        let code: Int32
    }

    struct ModalResult: Codable, Sendable {
        let shown: Bool
        let pressed: Bool
    }

    enum Operation: Codable, Sendable {
        case find(String), snapshot, dismissSheet(String)
    }

    struct Request: Codable, Sendable {
        let operation: Operation
        let title: String
    }

    enum Reply: Codable, Sendable {
        case element(Element?), snapshot(Snapshot), modal(ModalResult), failure(String)

        var error: String? {
            switch self {
            case .failure(let message): return message
            case .snapshot(let snapshot): return snapshot.error
            default: return nil
            }
        }
    }

    private var failures: [String] = []

    func takeFailures() -> [String] {
        defer { failures.removeAll() }
        return failures
    }

    func find(_ identifier: String, in title: String) async -> Element? {
        let reply = await invoke(.find(identifier), in: title)
        if case .element(let element) = reply { return element }
        rejectUnexpected(reply)
        return nil
    }

    func snapshot(in title: String) async -> Snapshot {
        let reply = await invoke(.snapshot, in: title)
        if case .snapshot(let snapshot) = reply { return snapshot }
        rejectUnexpected(reply)
        return Snapshot(elements: [], trusted: false, error: reply.error ?? "Unexpected AX helper reply", issues: [])
    }

    func dismissSheet(_ button: String, in title: String) async -> ModalResult {
        let reply = await invoke(.dismissSheet(button), in: title)
        if case .modal(let result) = reply { return result }
        rejectUnexpected(reply)
        return ModalResult(shown: false, pressed: false)
    }

    private func rejectUnexpected(_ reply: Reply) {
        if reply.error == nil { failures.append("Unexpected AX helper reply") }
    }

    private func invoke(_ operation: Operation, in title: String) async -> Reply {
        let reply: Reply
        do { reply = try await exchange(Request(operation: operation, title: title)) }
        catch { reply = .failure(error.localizedDescription) }
        if let error = reply.error {
            let message = "\(operation): \(error)"
            failures.append(message)
            NSLog("E2E AX helper failed: %@", message)
        }
        return reply
    }

    private func exchange(_ request: Request) async throws -> Reply {
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= SettingsAXTransport.requestLimit else {
            throw SettingsAXTransport.Failure("AX helper request exceeds \(SettingsAXTransport.requestLimit) bytes")
        }
        guard let executable = Bundle.main.executableURL else { throw SettingsAXTransport.Failure("App executable unavailable") }
        guard !Task.isCancelled else { throw SettingsAXTransport.Failure("AX helper request cancelled") }
        let response = try SettingsAXTransport.responseFile()
        let process = Process()
        defer {
            do { try response.close() }
            catch { failures.append("AX helper file close failed: \(error.localizedDescription)") }
        }
        process.executableURL = executable
        process.arguments = [SettingsAXTransport.mode, requestData.base64EncodedString()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = response
        process.standardError = FileHandle.nullDevice
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try process.run()
        while process.isRunning && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            await pause()
        }
        if process.isRunning {
            let reason = Task.isCancelled ? "AX helper request cancelled" : "AX helper exceeded 5 seconds"
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { await pause() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let exitDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < exitDeadline { await pause() }
            guard !process.isRunning else {
                throw SettingsAXTransport.Failure("\(reason); exit not observed after SIGKILL")
            }
            throw SettingsAXTransport.Failure(reason)
        }
        guard !Task.isCancelled else { throw SettingsAXTransport.Failure("AX helper request cancelled") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SettingsAXTransport.Failure("AX helper exited with status \(process.terminationStatus), reason \(process.terminationReason.rawValue)")
        }
        try response.seek(toOffset: 0)
        let data = try SettingsAXTransport.read(response)
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    private func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
        }
    }
}

private enum SettingsAXTransport {
    static let mode = "--e2e-ax"
    static let requestLimit = 8 * 1024
    static let replyLimit = 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func responseFile() throws -> FileHandle {
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("sharex-e2e-ax-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw Failure("Could not create AX response file, errno \(errno)") }
        do {
            guard unlink(path) == 0 else { throw Failure("Could not unlink AX response file, errno \(errno)") }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Failure("Could not protect AX response descriptor, errno \(errno)")
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func read(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: replyLimit + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= replyLimit else { throw Failure("AX helper reply exceeds \(replyLimit) bytes") }
        }
        return data
    }

    static func write(_ data: Data) throws {
        guard data.count <= replyLimit else { throw Failure("AX helper reply exceeds \(replyLimit) bytes") }
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

@MainActor
enum SettingsAXHelper {
    static func handlesHelperMode() -> Bool {
        let args = CommandLine.arguments
        guard args.contains(SettingsAXTransport.mode) else { return false }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) { _exit(124) }
        let parent = getppid()
        guard parent > 1, args.count == 3, args[1] == SettingsAXTransport.mode else { _exit(64) }
        let reply: SettingsAXClient.Reply
        do {
            guard args[2].utf8.count <= 4 * ((SettingsAXTransport.requestLimit + 2) / 3),
                  let data = Data(base64Encoded: args[2]), data.count <= SettingsAXTransport.requestLimit else {
                throw SettingsAXTransport.Failure("Invalid or oversized AX helper request")
            }
            let request = try JSONDecoder().decode(SettingsAXClient.Request.self, from: data)
            reply = SettingsAXWalker(parent: parent).run(request)
        } catch { reply = .failure(error.localizedDescription) }
        do {
            let encoded: Data
            do {
                encoded = try JSONEncoder().encode(reply)
                guard encoded.count <= SettingsAXTransport.replyLimit else {
                    throw SettingsAXTransport.Failure("AX helper reply exceeds \(SettingsAXTransport.replyLimit) bytes")
                }
            } catch {
                let failure = SettingsAXClient.Reply.failure(error.localizedDescription)
                try SettingsAXTransport.write(JSONEncoder().encode(failure))
                _exit(0)
            }
            try SettingsAXTransport.write(encoded)
            _exit(0)
        } catch { _exit(74) }
    }
}

@MainActor
private final class SettingsAXWalker {
    private typealias Element = SettingsAXClient.Element
    private typealias Snapshot = SettingsAXClient.Snapshot
    private typealias AttributeIssue = SettingsAXClient.AttributeIssue
    private typealias ModalResult = SettingsAXClient.ModalResult

    private enum Match {
        case identifier(String), button(String), all
    }

    private let parent: pid_t
    private let deadline = ProcessInfo.processInfo.systemUptime + 3
    private let trusted = AXIsProcessTrusted()
    private var failure: String?
    private var issues: [AttributeIssue] = []

    init(parent: pid_t) { self.parent = parent }

    func run(_ request: SettingsAXClient.Request) -> SettingsAXClient.Reply {
        switch request.operation {
        case .find(let identifier):
            let element = find(identifier, in: request.title)
            return failure.map(SettingsAXClient.Reply.failure) ?? .element(element)
        case .snapshot: return .snapshot(snapshot(in: request.title))
        case .dismissSheet(let button):
            let result = dismissSheet(button, in: request.title)
            return failure.map(SettingsAXClient.Reply.failure) ?? .modal(result)
        }
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard failure == nil else { return false }
        guard getppid() == parent else { failure = "AX helper parent exited"; return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { failure = "AX operation exceeded 3 seconds"; return false }
        let status = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
        guard status == .success else { failure = "AX timeout setup failed with AXError \(status.rawValue)"; return false }
        return true
    }

    private func checkDeadline() {
        if ProcessInfo.processInfo.systemUptime >= deadline { failure = "AX operation exceeded 3 seconds" }
    }

    private func attribute(_ attribute: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        guard prepare(element) else { return (.failure, nil) }
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        checkDeadline()
        return (status, result)
    }

    private func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        let (status, result) = self.attribute(attribute, of: element)
        guard failure == nil else { return nil }
        if status == .success { return result }
        switch status {
        case .attributeUnsupported, .noValue:
            break
        case .failure, .invalidUIElement:
            var role: CFTypeRef?
            if attribute != kAXRoleAttribute {
                role = value(kAXRoleAttribute, of: element)
            }
            issues.append(AttributeIssue(role: role as? String ?? "unknown", attribute: attribute, code: status.rawValue))
        default:
            failure = "\(attribute) failed with AXError \(status.rawValue)"
        }
        return nil
    }

    private func text(_ attribute: String, of element: AXUIElement) -> String {
        let result = value(attribute, of: element)
        return result as? String ?? (result as? NSNumber)?.stringValue ?? ""
    }

    private func matches(_ element: AXUIElement, _ match: Match) -> Bool {
        switch match {
        case .identifier(let identifier): return text(kAXIdentifierAttribute, of: element) == identifier
        case .button(let title):
            return text(kAXRoleAttribute, of: element) == kAXButtonRole
                && (text(kAXTitleAttribute, of: element) == title || text(kAXDescriptionAttribute, of: element) == title)
        case .all: return true
        }
    }

    private func walk(in title: String, matching match: Match, sheetOnly: Bool = false) -> (found: [AXUIElement], captured: [Element]) {
        guard trusted else {
            failure = "AX client is not trusted"
            return ([], [])
        }
        let application = AXUIElementCreateApplication(parent)
        guard let windows = value(kAXWindowsAttribute, of: application) as? [AXUIElement] else {
            failure = failure ?? "AXWindows unavailable" + (issues.last.map { " with AXError \($0.code)" } ?? "")
            return ([], [])
        }
        guard let window = windows.first(where: { text(kAXTitleAttribute, of: $0) == title }) else {
            failure = failure ?? "Settings AX window absent"
            return ([], [])
        }
        var pending = [window]
        if sheetOnly {
            let children = value(kAXChildrenAttribute, of: window) as? [AXUIElement] ?? []
            pending = children.filter { text(kAXRoleAttribute, of: $0) == kAXSheetRole }
        }
        var visited: [AXUIElement] = []
        var found: [AXUIElement] = []
        var captured: [Element] = []
        while let element = pending.popLast(), failure == nil {
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            guard visited.count < 512 else { failure = "AX traversal exceeded 512 elements"; break }
            visited.append(element)
            if matches(element, match) {
                found.append(element)
                if case .all = match { captured.append(capture(element)) } else { break }
            }
            pending += value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        }
        checkDeadline()
        return (found, captured)
    }

    private func capture(_ element: AXUIElement) -> Element {
        var point = CGPoint.zero
        var size = CGSize.zero
        if let position = value(kAXPositionAttribute, of: element), CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
        }
        if let extent = value(kAXSizeAttribute, of: element), CFGetTypeID(extent) == AXValueGetTypeID() {
            AXValueGetValue(extent as! AXValue, .cgSize, &size)
        }
        return Element(identifier: text(kAXIdentifierAttribute, of: element), role: text(kAXRoleAttribute, of: element),
                       title: text(kAXTitleAttribute, of: element), label: text(kAXDescriptionAttribute, of: element),
                       value: text(kAXValueAttribute, of: element), frame: CGRect(origin: point, size: size))
    }

    private func find(_ identifier: String, in title: String) -> Element? {
        let element = walk(in: title, matching: .identifier(identifier)).found.first.map(capture)
        if let failure { NSLog("E2E AX lookup %@ failed: %@", identifier, failure) }
        if element == nil, let issue = issues.first {
            NSLog("E2E AX lookup %@ missing after %ld node issues; first %@ %@ AXError %d",
                  identifier, issues.count, issue.role, issue.attribute, issue.code)
        }
        return failure == nil ? element : nil
    }

    private func snapshot(in title: String) -> Snapshot {
        let elements = walk(in: title, matching: .all).captured
        return Snapshot(elements: elements, trusted: trusted, error: failure, issues: issues)
    }

    private func dismissSheet(_ button: String, in title: String) -> ModalResult {
        repeat {
            if let element = walk(in: title, matching: .button(button), sheetOnly: true).found.first {
                guard prepare(element) else { break }
                let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
                checkDeadline()
                if status != .success { failure = "AXPress failed with AXError \(status.rawValue)" }
                return ModalResult(shown: true, pressed: status == .success && failure == nil)
            }
            guard failure == nil else { break }
            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        } while ProcessInfo.processInfo.systemUptime < deadline
        failure = failure ?? "AX sheet button did not appear within 3 seconds"
        return ModalResult(shown: false, pressed: false)
    }
}
#endif
