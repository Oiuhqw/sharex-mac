#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ECapturePolish {
    static func run() async {
        await outputSnapshot()
        let sound = NSSound(data: CaptureSound.waveData, byReference: false)
        try? CaptureSound.waveData.write(to: E2E.out.appendingPathComponent("capture-click.wav"))
        E2E.record("capture-sound-decodes-short-shutter", sound != nil && abs((sound?.duration ?? 0) - 0.09) < 0.002,
                   ["duration": sound?.duration ?? 0, "bytes": CaptureSound.waveData.count])
        let defaults = AppSettings.decode(nil)
        let legacy = AppSettings.decode(Data("{}".utf8))
        let optedOut = AppSettings.decode(Data("{\"saveToFile\":false}".utf8))
        E2E.record("capture-saving-default-and-opt-out", defaults.saveToFile && legacy.saveToFile && !optedOut.saveToFile)

        guard let source = E2ELoupe.fixture(), let context = Imaging.context(width: 220, height: 200, flipped: true) else {
            E2E.record("capture-round-loupe-fixture", false); return
        }
        let chrome = ChromeView(frame: CGRect(x: 0, y: 0, width: 220, height: 200))
        chrome.setMagnifierSource(source)
        var state = ChromeView.State()
        state.magnifier = (CGPoint(x: 20, y: 20), 2)
        chrome.apply(state)
        chrome.layer?.render(in: context)
        guard let image = context.makeImage() else { E2E.record("capture-round-loupe", false); return }
        let bitmap = E2E.bitmap(image), frame = chrome.e2eLoupe.frame
        let corners = [(frame.minX + 2, frame.minY + 2), (frame.maxX - 3, frame.minY + 2),
                       (frame.minX + 2, frame.maxY - 3), (frame.maxX - 3, frame.maxY - 3)]
        let clearCorners = corners.allSatisfy { bitmap.at(Int($0.0), Int($0.1)).a < 0.01 }
        let center = bitmap.at(Int(frame.midX), Int(frame.midY))
        E2E.record("capture-round-loupe-rendered", clearCorners && center.a > 0.99,
                   ["clearCorners": clearCorners, "centerAlpha": center.a])
        E2EOrientation.writePNG(image, "round-loupe.png")
        chrome.releaseResources()
    }

    private static func outputSnapshot() async {
        let original = E2E.app.settings.value
        defer { E2E.setOpts { $0 = original } }
        E2E.setOpts {
            $0.saveToFile = true; $0.saveFolder = E2E.saved.path; $0.playSound = false
            $0.options.borderWidth = 0; $0.options.shadow = false
        }
        guard let session = await E2EEditing.open("capture-output-snapshot") else { return }
        let shown = session.view.session.outputSummary.contains(E2E.saved.path)
            && session.view.session.outputAction == "Copy and save"
        E2E.setOpts { $0.saveToFile = false; $0.saveFolder = "/invalid/changed-during-capture" }
        await E2EEditing.finish("capture-output-snapshot", session, condition: shown,
                                info: ["settingsChangedWhileOpen": true]) { $0.px == session.original.px }
    }
}
#endif
