// Compiled only into CI test builds (SHAREX_E2E); never shipped.
#if SHAREX_E2E
import AppKit
import ImageIO
import ShareXCore

/// Keyboard reaches the overlay while another app stays frontmost. Every key here is a system-level
/// CGEvent posted to the HID tap (the path a real keyboard takes), not keyDown/sendEvent on our view,
/// and the capture is opened by the real global hotkey when it fires.
@MainActor
enum E2EKeyboard {
    static func post(_ code: CGKeyCode, flags: CGEventFlags = []) async {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags; e?.post(tap: .cghidEventTap)
        }
        await E2E.wait(120)
    }

    static func frontPattern() async -> Bool {
        guard E2E.patternPID != 0 else { return false }
        NSRunningApplication(processIdentifier: E2E.patternPID)?.activate()
        return await E2E.until(2000) { NSWorkspace.shared.frontmostApplication?.processIdentifier == E2E.patternPID }
    }

    /// Opens Region through the global hotkey (falls back to the coordinator if the hotkey post is refused).
    static func open() async -> (viaHotkey: Bool, ok: Bool) {
        await post(18, flags: [.maskControl, .maskShift])
        if await E2E.until(2000, { E2E.surface() != nil }) { await E2E.wait(200); return (true, true) }
        E2E.coord.capture(.region)
        let ok = await E2E.until({ E2E.surface() != nil }); await E2E.wait(200)
        return (false, ok)
    }

    static func state() -> [String: Any] {
        let s = E2E.surface()
        return ["isKey": s?.window.isKeyWindow ?? false, "appActive": NSApp.isActive,
                "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "pattern": E2E.patternPID]
    }

    static func run() async {
        OverlayController.e2eDeclineActivation = true
        defer { OverlayController.e2eDeclineActivation = false }
        guard await frontPattern() else {
            E2E.record("keyboard-other-app-front", false, ["error": "pattern app not frontmost"], status: "unverifiable"); return
        }
        // 1. Esc cancels.
        let m = E2E.markClipboard()
        var o = await open()
        var info = state(); info["viaHotkey"] = o.viaHotkey
        let patternStayedFront = (info["frontmost"] as? Int32) == E2E.patternPID
        await post(53)
        let cancelled = await E2E.until(2000) { !E2E.coord.busy && E2E.surface() == nil }
        if !cancelled { E2E.esc(); _ = await E2E.until({ !E2E.coord.busy }) }
        E2E.unchanged("keyboard-esc-cancels-other-app-front", m,
                      extra: info.merging(["cancelled": cancelled, "patternStayedFront": patternStayedFront]) { $1 },
                      cond: o.ok && cancelled && (info["isKey"] as? Bool ?? false) && patternStayedFront)

        // 2. Tool hotkey, typed text into a Text annotation, Enter commits.
        _ = await frontPattern()
        let m2 = E2E.markClipboard()
        o = await open()
        guard o.ok, let s = E2E.surface() else { E2E.record("keyboard-text-enter-other-app-front", false, ["error": "no overlay"]); return }
        E2E.drag(CGPoint(x: E2E.C.minX, y: E2E.C.minY), CGPoint(x: E2E.C.maxX, y: E2E.C.maxY))
        await E2E.wait(150)
        await post(15)                                            // R
        let rect = s.view.tool == .shape(.rectangle)
        await post(17)                                            // T
        let textTool = s.view.tool == .shape(.text)
        E2E.click(CGPoint(x: E2E.C.minX + 40, y: E2E.C.minY + 40)); await E2E.wait(200)
        for k: CGKeyCode in [4, 34] { await post(k) }               // h, i
        await post(36)                                            // Return commits the text field
        await E2E.wait(150)
        let text = s.view.doc.annotations.first { $0.kind == .text }?.text ?? "<none>"
        let before = state()
        await post(36)                                            // Return finishes the capture
        let finished = await E2E.until(3000) { !E2E.coord.busy }
        if !finished { E2E.esc(); _ = await E2E.until({ !E2E.coord.busy }) }
        let clip = E2E.checkClipboard("keyboard-text-enter-other-app-front", since: m2, w: E2E.cw, h: E2E.ch)
        let info2 = before.merging(["viaHotkey": o.viaHotkey, "toolR": rect, "toolT": textTool, "text": text,
                                    "finished": finished, "clipOK": clip?.ok ?? false]) { $1 }
        let front = (before["frontmost"] as? Int32) == E2E.patternPID
        E2E.record("keyboard-tool-hotkeys-other-app-front", rect && textTool && front, info2)
        E2E.record("keyboard-text-enter-other-app-front", text == "hi" && finished && (clip?.ok ?? false) && front, info2)
    }
}

/// Skeptic (d): the clipboard image keeps the frame's colour profile, and busy clears only after the write.
@MainActor
enum E2EClipboardOrder {
    static func run() async {
        let m = E2E.markClipboard()
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let s = E2E.surface() else { E2E.record("clipboard-busy-after-write", false, ["error": "no overlay"]); return }
        await E2E.wait(150)
        let frameCS = (s.view.renderer.frame.colorSpace?.name as String?) ?? "<unnamed>"
        E2E.drag(CGPoint(x: E2E.C.minX, y: E2E.C.minY), CGPoint(x: E2E.C.maxX, y: E2E.C.maxY))
        E2E.ret()
        // Sample every main-loop turn; the first turn busy is false must already see the new pasteboard.
        var writtenWhenIdle: Bool?
        for _ in 0..<4000 {
            if !E2E.coord.busy { writtenWhenIdle = NSPasteboard.general.changeCount != m.change && NSPasteboard.general.data(forType: .png) != nil; break }
            await Task.yield(); try? await Task.sleep(for: .milliseconds(1))
        }
        E2E.record("clipboard-busy-after-write", writtenWhenIdle == true, ["writtenWhenIdle": writtenWhenIdle as Any])
        var pngCS = "<none>", hasICC = false
        if let d = NSPasteboard.general.data(forType: .png), let src = CGImageSourceCreateWithData(d as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            pngCS = (img.colorSpace?.name as String?) ?? "<unnamed>"
            hasICC = img.colorSpace?.copyICCData() != nil
        }
        E2E.record("clipboard-colour-profile-preserved", hasICC && pngCS == frameCS,
                   ["png": pngCS, "frame": frameCS, "embeddedICC": hasICC,
                    "note": "the frame is captured in sRGB by design (ScreenCapture.swift:107); this checks export does not change it"])
    }
}
#endif
