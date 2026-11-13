import AppKit
import CoreGraphics
import Foundation

@MainActor
private final class PatternView: NSView {
    var stage = 0
    var tick = 0
    var noisy = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (230, 32, 40), (32, 210, 80), (30, 80, 230), (240, 210, 40)
        ]
        for (index, rgb) in colors.enumerated() {
            NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255,
                    blue: rgb.2 / 255, alpha: 1).setFill()
            NSRect(x: CGFloat(index % 2) * bounds.width / 2,
                   y: CGFloat(index / 2) * bounds.height / 2,
                   width: bounds.width / 2, height: bounds.height / 2).fill()
        }
        let markers: [NSColor] = [.cyan, .magenta, .white]
        markers[stage].setFill()
        NSRect(x: bounds.width * 0.4, y: bounds.height * 0.4,
               width: bounds.width * 0.2, height: bounds.height * 0.2).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: bounds.height * 0.88, width: bounds.width,
               height: bounds.height * 0.08).fill()
        NSColor.white.setFill()
        NSRect(x: CGFloat(tick % 90) / 90 * bounds.width * 0.9,
               y: bounds.height * 0.89, width: bounds.width * 0.1,
               height: bounds.height * 0.06).fill()
        if noisy {
            let width = 640
            let height = 56
            var seed = UInt64(tick + 1)
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
                bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 32)
                bytes[index + 2] = UInt8(truncatingIfNeeded: seed >> 40)
            }
            if let provider = CGDataProvider(data: Data(bytes) as CFData),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) {
                NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(
                    x: 0, y: bounds.height * 0.88, width: bounds.width, height: bounds.height * 0.12))
            }
        }
    }
}

@MainActor
private final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate {
    let directory: URL
    let title: String
    var window: NSWindow?
    var view: PatternView?
    var timer: Timer?
    var lastCommand = ""
    var observedPID: Int32 = 0
    var draws = 0
    var displayID: CGDirectDisplayID = 0
    var failure: String?

    init(directory: URL, title: String) {
        self.directory = directory
        self.title = title
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              screen.visibleFrame.width >= 760, screen.visibleFrame.height >= 560 else {
            failure = "A local desktop with at least 760 by 560 logical points is required."
            writeState()
            NSApp.terminate(nil)
            return
        }
        displayID = number.uint32Value
        let frame = NSRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 40,
                           width: 640, height: 480)
        let window = FixtureWindow(contentRect: frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces]
        let view = PatternView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        self.window = window
        self.view = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self,
                                    selector: #selector(update), userInfo: nil, repeats: true)
    }

    @objc func update() {
        let commandURL = directory.appendingPathComponent("command.json")
        if let data = try? Data(contentsOf: commandURL),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = command["id"] as? String, id != lastCommand {
            if let pid = command["observedPID"] as? Int32 { observedPID = pid }
            switch command["action"] as? String {
            case "stage":
                if let stage = command["stage"] as? Int, (0...2).contains(stage) { view?.stage = stage }
            case "noise": view?.noisy = command["enabled"] as? Bool ?? false
            case "close-window": window?.close()
            case "terminate-observed":
                if observedPID > 0 { NSRunningApplication(processIdentifier: observedPID)?.terminate() }
            case "quit": NSApp.terminate(nil)
            default: break
            }
            lastCommand = id
        }
        view?.tick += 1
        view?.needsDisplay = true
        window?.displayIfNeeded()
        draws += 1
        writeState()
    }

    func writeState() {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        let ownWindow = windows.first { ($0[kCGWindowNumber as String] as? Int) == window?.windowNumber }
        let bounds = ownWindow?[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let display = CGDisplayBounds(displayID)
        let observedWindows = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == observedPID
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }.compactMap { $0[kCGWindowNumber as String] as? Int }.sorted()
        var state: [String: Any] = [
            "status": failure == nil ? "ready" : "blocked", "draws": draws,
            "pid": ProcessInfo.processInfo.processIdentifier, "title": title,
            "windowID": window?.windowNumber ?? 0, "displayID": displayID,
            "displayBounds": ["x": display.minX, "y": display.minY,
                              "width": display.width, "height": display.height],
            "windowBounds": bounds, "scale": window?.backingScaleFactor ?? 1,
            "stage": view?.stage ?? 0, "commandID": lastCommand,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "clipboardChangeCount": NSPasteboard.general.changeCount,
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "observedWindows": observedWindows
        ]
        if let failure { state["reason"] = failure }
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Fixture state write failed: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
}

@main
@MainActor
private struct Main {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: agent-capture-fixture OUTPUT_DIRECTORY UNIQUE_TITLE\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture(directory: directory, title: CommandLine.arguments[2])
        app.delegate = fixture
        app.run()
        exit(fixture.failure == nil ? 0 : 3)
    }
}
