import AppKit
import ShareXCore
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        #if SHAREX_E2E
        if E2E.handlesHelperMode() { return }
        #endif
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement in Info.plist already makes this a menu-bar app with no Dock icon.
        app.mainMenu = editMenuBar()
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Never shown (LSUIElement), but key equivalents go through it: without an Edit menu ⌘Z, ⌘C, ⌘V and ⌘A do
/// nothing in the editor's text field or in Settings. Actions are nil-targeted, so they reach the first responder.
@MainActor
private func editMenuBar() -> NSMenu {
    let bar = NSMenu()
    let appItem = NSMenuItem(), editItem = NSMenuItem()
    bar.addItem(appItem); bar.addItem(editItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "Quit ShareX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu
    let edit = NSMenu(title: "Edit")
    edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(redo)
    edit.addItem(.separator())
    edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = edit
    return bar
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = SettingsStore()
    lazy var coordinator = CaptureCoordinator(settings: settings)
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShareX")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        Hotkeys.register { [weak self] in self?.coordinator.capture($0) }
        ScreenCapture.prefetch()
        #if SHAREX_E2E
        if E2E.enabled { E2E.start(self); return }
        #endif
        if !Permissions.hasScreenRecording { Permissions.requestScreenRecording() }
    }

    /// Rebuilt on every open so checkmarks always match the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for style in CaptureStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(captureItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let before = NSMenuItem(title: "Before capture", action: nil, keyEquivalent: "")
        before.submenu = beforeCaptureMenu()
        menu.addItem(before)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit ShareX", #selector(quit), key: "q"))
    }

    private func beforeCaptureMenu() -> NSMenu {
        toggles = [:]
        let o = settings.value.options
        let m = NSMenu()
        let delay = NSMenu()
        for d in CaptureOptions.delayChoices {
            let i = item(d == 0 ? "No delay" : "\(d) seconds", #selector(setDelay(_:)))
            i.tag = d; i.state = o.delaySeconds == d ? .on : .off
            delay.addItem(i)
        }
        let delayItem = NSMenuItem(title: "Delay", action: nil, keyEquivalent: "")
        delayItem.submenu = delay
        m.addItem(delayItem)
        m.addItem(toggle("Show cursor", o.showCursor, \.showCursor))
        m.addItem(toggle("Magnifier", o.showMagnifier, \.showMagnifier))
        m.addItem(toggle("Border", o.borderWidth > 0, nil))
        m.addItem(toggle("Drop shadow", o.shadow, \.shadow))
        m.addItem(toggle("Open editor for fixed areas", o.openEditor, \.openEditor))
        return m
    }

    private var toggles: [Int: WritableKeyPath<CaptureOptions, Bool>] = [:]

    private func toggle(_ title: String, _ on: Bool, _ kp: WritableKeyPath<CaptureOptions, Bool>?) -> NSMenuItem {
        let i = item(title, #selector(flip(_:)))
        i.state = on ? .on : .off
        i.tag = 1000 + toggles.count
        if let kp { toggles[i.tag] = kp } else { i.tag = -1 }
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func captureItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = CaptureStyle(rawValue: raw) else { return }
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.coordinator.capture(style) }
    }

    @objc private func setDelay(_ sender: NSMenuItem) { settings.update { $0.options.delaySeconds = sender.tag } }

    @objc private func flip(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            settings.update { $0.options.borderWidth = $0.options.borderWidth > 0 ? 0 : 2 }
        } else if let kp = toggles[sender.tag] {
            settings.update { $0.options[keyPath: kp].toggle() }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: settings)))
            w.title = "ShareX Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
