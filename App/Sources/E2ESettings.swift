#if SHAREX_E2E
import AppKit
import ApplicationServices
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
                            flags: NSEvent.ModifierFlags = []) {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
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

        let capture = await element("settings.capture.cursor", in: window) != nil
        E2E.record("settings-initial-capture-page", capture)
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
        let conflictResponse = prepareSheetDismissal("OK", in: window)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        let conflict = await conflictResponse.value
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

    struct ModalResult: Sendable {
        let shown: Bool
        let pressed: Bool
    }

    private enum Match {
        case identifier(String), button(String), all
    }

    private var deadline: TimeInterval = 0
    private var failure: String?
    private var issues: [AttributeIssue] = []

    private func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        guard failure == nil else { return nil }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            failure = "AX traversal exceeded 3 seconds"
            return nil
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        if status == .success { return result }
        switch status {
        case .attributeUnsupported, .noValue:
            break
        case .failure, .invalidUIElement:
            var role: CFTypeRef?
            if attribute != kAXRoleAttribute, ProcessInfo.processInfo.systemUptime < deadline {
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
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
        failure = nil
        issues = []
        deadline = ProcessInfo.processInfo.systemUptime + 3
        guard AXIsProcessTrusted() else {
            failure = "AX client is not trusted"
            return ([], [])
        }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
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

    func find(_ identifier: String, in title: String) -> Element? {
        let element = walk(in: title, matching: .identifier(identifier)).found.first.map(capture)
        if let failure { NSLog("E2E AX lookup %@ failed: %@", identifier, failure) }
        if element == nil, let issue = issues.first {
            NSLog("E2E AX lookup %@ missing after %ld node issues; first %@ %@ AXError %d",
                  identifier, issues.count, issue.role, issue.attribute, issue.code)
        }
        return failure == nil ? element : nil
    }

    func snapshot(in title: String) -> Snapshot {
        let elements = walk(in: title, matching: .all).captured
        return Snapshot(elements: elements, trusted: AXIsProcessTrusted(), error: failure, issues: issues)
    }

    func dismissSheet(_ button: String, in title: String) async -> ModalResult {
        let end = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            guard !Task.isCancelled else { return ModalResult(shown: false, pressed: false) }
            if let element = walk(in: title, matching: .button(button), sheetOnly: true).found.first {
                let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                return ModalResult(shown: true, pressed: pressed)
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < end
        return ModalResult(shown: false, pressed: false)
    }
}
#endif
