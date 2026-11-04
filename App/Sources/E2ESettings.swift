#if SHAREX_E2E
import AppKit
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

    private static func elements(in root: Any) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: Any) {
            guard let element = object as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }

    private static func element(_ id: String, in window: NSWindow) -> (any NSAccessibilityProtocol)? {
        elements(in: window).first { $0.accessibilityIdentifier() == id }
    }

    @discardableResult
    private static func press(_ id: String, in window: NSWindow) -> Bool {
        guard let target = element(id, in: window) else { return false }
        return target.accessibilityPerformPress()
    }

    private static func click(_ target: any NSAccessibilityProtocol, in window: NSWindow) {
        let frame = target.accessibilityFrame()
        let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
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
        guard let target = element("settings.page.\(page)", in: window) else { return false }
        click(target, in: window)
        await E2E.wait(200)
        let identifiers = ["capture": "settings.capture.cursor", "shortcuts": "settings.shortcuts.search", "output": "settings.output.saveToFile"]
        return identifiers[page].flatMap { element($0, in: window) } != nil
    }

    private static func screenshot(_ name: String, window: NSWindow) {
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
    }

    private static func recorder(_ id: String, in window: NSWindow) -> KeyboardShortcuts.RecorderCocoa? {
        elements(in: window).compactMap { $0 as? KeyboardShortcuts.RecorderCocoa }
            .first { $0.accessibilityIdentifier() == "settings.shortcut.\(id).recorder" }
    }

    private static func search(_ text: String, in window: NSWindow) async -> Bool {
        guard let field = element("settings.shortcuts.search", in: window) else { return false }
        click(field, in: window)
        await E2E.wait(60)
        key(0, "a", in: window, flags: .command)
        key(51, "\u{7f}", in: window)
        for character in text { key(0, String(character), in: window) }
        await E2E.wait(160)
        return true
    }

    private static func rowAction(_ id: String, restore: Bool, in window: NSWindow) async -> Bool {
        guard let options = element("settings.shortcut.\(id).options", in: window) else { return false }
        click(options, in: window)
        await E2E.wait(150)
        key(125, "\u{f701}", in: window)
        if restore { key(125, "\u{f701}", in: window) }
        key(36, "\r", in: window)
        await E2E.wait(180)
        return true
    }

    private static func dismissSheet(_ title: String, in window: NSWindow) -> Bool {
        guard let sheet = window.attachedSheet,
              let button = elements(in: sheet).first(where: {
                  $0.accessibilityRole() == .button && ($0.accessibilityTitle() == title || $0.accessibilityLabel() == title)
              }) else { return false }
        return button.accessibilityPerformPress()
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

        let capture = await navigate("capture", in: window)
        let cursor = E2E.app.settings.value.options.showCursor
        let toggledCursor = press("settings.capture.cursor", in: window)
        await E2E.wait(100)
        E2E.record("settings-capture-toggle-persists", capture && toggledCursor
                   && SettingsStore().value.options.showCursor == !cursor)
        screenshot("settings-capture", window: window)

        let output = await navigate("output", in: window)
        let save = E2E.app.settings.value.saveToFile
        let toggledSave = press("settings.output.saveToFile", in: window)
        await E2E.wait(100)
        E2E.record("settings-output-toggle-persists", output && toggledSave && SettingsStore().value.saveToFile == !save)
        _ = press("settings.output.saveToFile", in: window)
        let folderBefore = E2E.app.settings.value.saveFolder
        let chooser = press("settings.output.chooseFolder", in: window)
        let sheetOpened = await E2E.until(1500) { window.attachedSheet != nil }
        if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
        else { _ = dismissSheet("Cancel", in: window) }
        let sheetClosed = await E2E.until(1500) { window.attachedSheet == nil }
        E2E.record("settings-folder-chooser-cancel", chooser && sheetOpened && sheetClosed
                   && E2E.app.settings.value.saveFolder == folderBefore)
        E2E.app.settings.update { $0.saveFolder = E2E.saved.path }
        await E2E.wait(100)
        let defaultFolder = press("settings.output.defaultFolder", in: window)
        await E2E.wait(100)
        E2E.record("settings-folder-default-persists", defaultFolder && SettingsStore().value.saveFolder.isEmpty
                   && element("settings.output.folder", in: window) != nil)
        screenshot("settings-output", window: window)

        let shortcutsPage = await navigate("shortcuts", in: window)
        let recorders = elements(in: window).compactMap { $0 as? KeyboardShortcuts.RecorderCocoa }
        E2E.record("settings-eight-accessible-recorders", shortcutsPage && recorders.count == 8
                   && recorders.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty }, ["count": recorders.count])
        screenshot("settings-shortcuts", window: window)
        window.setContentSize(NSSize(width: 900, height: 850))
        await E2E.wait(200)
        screenshot("settings-shortcuts-expanded", window: window)

        _ = await search("frontmost", in: window)
        E2E.record("settings-shortcut-search-description", recorder("activeWindow", in: window) != nil
                   && recorder("region", in: window) == nil)
        _ = await search("no-such-command", in: window)
        E2E.record("settings-shortcut-search-empty", element("settings.shortcuts.empty", in: window) != nil)
        _ = await search("Region", in: window)
        guard let region = recorder("region", in: window) else {
            E2E.record("settings-shortcut-native-record", false, ["error": "region recorder absent"]); return
        }
        let custom = KeyboardShortcuts.Shortcut(.eight, modifiers: [.control, .option, .shift])
        window.makeFirstResponder(region)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        let recorded = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .region) == custom }
        E2E.record("settings-shortcut-native-record", recorded && region.stringValue == custom.description)

        guard let lastRegion = recorder("lastRegion", in: window) else {
            E2E.record("settings-shortcut-conflict", false, ["error": "last-region recorder absent"]); return
        }
        let previous = KeyboardShortcuts.getShortcut(for: .lastRegion)
        window.makeFirstResponder(lastRegion)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        let conflictAlert = await E2E.until(1500) { window.attachedSheet != nil }
        let conflictText = element("settings.shortcuts.feedback", in: window).map {
            ($0.accessibilityLabel() ?? "") + ($0.accessibilityValue() as? String ?? "")
        } ?? ""
        let dismissed = dismissSheet("OK", in: window)
        await E2E.wait(100)
        E2E.record("settings-shortcut-conflict", conflictAlert && dismissed
                   && KeyboardShortcuts.getShortcut(for: .lastRegion) == previous
                   && KeyboardShortcuts.getShortcut(for: .region) == custom
                   && conflictText.contains("Region"), ["feedback": conflictText])
        key(53, "\u{1b}", in: window)
        await E2E.wait(80)
        let cleared = await rowAction("region", restore: false, in: window)
        E2E.record("settings-shortcut-clear", cleared && KeyboardShortcuts.getShortcut(for: .region) == nil)
        window.makeFirstResponder(lastRegion)
        key(18, "1", in: window, flags: [.control, .shift])
        let movedDefault = await E2E.until(1500) {
            KeyboardShortcuts.getShortcut(for: .lastRegion) == KeyboardShortcuts.Name.region.initialShortcut
        }
        let blockedRestore = await rowAction("region", restore: true, in: window)
        E2E.record("settings-shortcut-default-conflict", movedDefault && blockedRestore
                   && KeyboardShortcuts.getShortcut(for: .region) == nil
                   && KeyboardShortcuts.getShortcut(for: .lastRegion) == KeyboardShortcuts.Name.region.initialShortcut)
        let noDefaultCleared = await rowAction("lastRegion", restore: true, in: window)
        E2E.record("settings-shortcut-unassigned-default", noDefaultCleared && KeyboardShortcuts.getShortcut(for: .lastRegion) == nil)
        let restored = await rowAction("region", restore: true, in: window)
        E2E.record("settings-shortcut-default", restored
                   && KeyboardShortcuts.getShortcut(for: .region) == KeyboardShortcuts.Name.region.initialShortcut)

        window.makeFirstResponder(region)
        key(28, "8", in: window, flags: [.control, .option, .shift])
        _ = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .region) == custom }
        _ = press("settings.shortcuts.restoreAll", in: window)
        let confirm = await E2E.until(1000) { window.attachedSheet != nil }
        let cancelled = dismissSheet("Cancel", in: window)
        await E2E.wait(100)
        E2E.record("settings-shortcut-restore-confirmation", confirm && cancelled
                   && KeyboardShortcuts.getShortcut(for: .region) == custom)
        _ = press("settings.shortcuts.restoreAll", in: window)
        _ = await E2E.until(1000) { window.attachedSheet != nil }
        let restoreAll = dismissSheet("Restore Defaults", in: window)
        await E2E.wait(100)
        E2E.record("settings-shortcut-restore-all", restoreAll && Hotkeys.commands.allSatisfy {
            KeyboardShortcuts.getShortcut(for: $0.name) == $0.name.initialShortcut
        })

        window.makeFirstResponder(lastRegion)
        let persisted = KeyboardShortcuts.Shortcut(.nine, modifiers: [.control, .option, .shift])
        key(25, "9", in: window, flags: [.control, .option, .shift])
        let persistedRecorded = await E2E.until(1500) { KeyboardShortcuts.getShortcut(for: .lastRegion) == persisted }
        do {
            try JSONEncoder().encode(shortcutState()).write(to: E2E.out.appendingPathComponent("settings-shortcuts-expected.json"))
            keepPersistenceFixture = persistedRecorded
            E2E.record("settings-shortcut-persistence-fixture", persistedRecorded && verifyPersistence(E2E.out.path))
        } catch { E2E.record("settings-shortcut-persistence-fixture", false, ["error": error.localizedDescription]) }
    }
}
#endif
