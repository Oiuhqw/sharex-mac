#if SHAREX_E2E
import AppKit
import Darwin
import ShareXCore

@MainActor
enum E2EResources {
    private struct Snapshot {
        let rss: UInt64
        let lifetimePeakRSS: UInt64
        let cpuMS: Double
        let wallMS: Double

        static func read() -> Snapshot? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            var usage = rusage()
            guard result == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0, info.resident_size > 0, usage.ru_maxrss > 0 else { return nil }
            func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
            return Snapshot(rss: info.resident_size, lifetimePeakRSS: UInt64(usage.ru_maxrss),
                            cpuMS: milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime), wallMS: Perf.now())
        }
    }

    private final class Ownership {
        weak var renderer: Renderer?
        weak var editor: EditorView?
        var released: Bool { renderer == nil && editor == nil }
    }

    private struct Session {
        let ownership: Ownership
        var metrics: [String: Any]
    }

    private static func edit(_ image: CGImage, scale: CGFloat, name: String, index: Int) -> Session? {
        autoreleasepool {
            let renderer = Renderer(frame: image, scale: scale)
            let bounds = CGRect(origin: .zero, size: renderer.pointSize)
            let editor = EditorView(frame: bounds, renderer: renderer, mode: .rectangle, initialCrop: bounds,
                                    styles: [.rectangle: ShapeStyle(color: .red, filled: true)],
                                    showMagnifier: true, pickRects: [], finishOnPick: false)
            let window = OverlayWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
            window.contentView = editor; window.orderFrontRegardless(); window.makeKey(); window.makeFirstResponder(editor)
            defer { editor.releaseResources(); window.orderOut(nil); window.contentView = nil; window.close(); CATransaction.flush() }
            let ownership = Ownership(); ownership.renderer = renderer; ownership.editor = editor
            let start = CGPoint(x: bounds.width * 0.15, y: bounds.height * 0.2)
            let end = CGPoint(x: bounds.width * 0.6, y: bounds.height * 0.65)
            editor.setTool(.shape(.pixelate))
            E2EPerf.send(.leftMouseDown, start, editor, window)
            E2EPerf.send(.leftMouseDragged, end, editor, window)
            window.displayIfNeeded(); CATransaction.flush()
            let liveBytes = renderer.e2eLiveBytes
            let liveLayerBytes = editor.e2eLiveLayerBytes
            E2EPerf.send(.leftMouseUp, end, editor, window)
            window.displayIfNeeded(); CATransaction.flush()
            let liveBytesAfterCommit = renderer.e2eLiveBytes
            let liveLayerBytesAfterCommit = editor.e2eLiveLayerBytes
            editor.setTool(.shape(.rectangle))
            E2EPerf.send(.leftMouseDown, CGPoint(x: bounds.width * 0.7, y: bounds.height * 0.2), editor, window)
            E2EPerf.send(.leftMouseDragged, CGPoint(x: bounds.width * 0.9, y: bounds.height * 0.4), editor, window)
            E2EPerf.send(.leftMouseUp, CGPoint(x: bounds.width * 0.9, y: bounds.height * 0.4), editor, window)
            editor.setTool(.crop)
            let syncs = editor.e2eAnnotationSyncCount
            var lastPointer = CGPoint.zero
            for i in 0..<60 {
                lastPointer = CGPoint(x: (bounds.width * CGFloat(i + 1) / 62).rounded(.down), y: (bounds.height * 0.8).rounded(.down))
                E2EPerf.send(.mouseMoved, lastPointer, editor, window)
            }
            let pointerSyncs = editor.e2eAnnotationSyncCount - syncs
            let loupe = editor.e2eLoupe
            let pointerVerified = loupe.visible && loupe.label.contains("X: \(Int(lastPointer.x * scale))")
                && loupe.label.contains("Y: \(Int(lastPointer.y * scale))")
            guard let flat = Export.flatten(renderer: renderer, doc: editor.doc, crop: bounds, lasso: nil),
                  let encoded = Export.encode(flat, scale: scale), let decoded = E2E.decode(encoded.png),
                  let active = Snapshot.read() else { return nil }
            let pixels = E2E.bitmap(flat)
            let correct = flat.width == image.width && flat.height == image.height
                && decoded.width == image.width && decoded.height == image.height
                && editor.doc.annotations.count == 2 && pixels.px == E2E.bitmap(decoded).px && pointerVerified
                && E2E.isRed(pixels.at(Int(CGFloat(image.width) * 0.8), Int(CGFloat(image.height) * 0.3)))
            let budgetOK = renderer.e2eCacheBytes > 0 && renderer.e2eCacheBytes <= 64 * 1024 * 1024
                && renderer.e2eCacheEntryCount > 0 && renderer.e2eCacheEntryCount <= 128
                && liveBytes <= 16 * 1024 * 1024 && liveLayerBytes <= 16 * 1024 * 1024
                && liveBytesAfterCommit == 0 && liveLayerBytesAfterCommit == 0 && pointerSyncs == 0
            if index == 0 { E2EOrientation.writePNG(flat, "resources-\(name).png") }
            return Session(ownership: ownership, metrics: [
                "index": index, "width": image.width, "height": image.height, "scale": scale,
                "activeRSSBytes": active.rss, "cacheBytes": renderer.e2eCacheBytes,
                "cacheEntries": renderer.e2eCacheEntryCount, "liveBytes": liveBytes,
                "liveLayerBytes": liveLayerBytes, "liveBytesAfterCommit": liveBytesAfterCommit,
                "liveLayerBytesAfterCommit": liveLayerBytesAfterCommit, "pointerDocumentSyncs": pointerSyncs,
                "pointerEventsVerified": pointerVerified, "outputCorrect": correct, "budgetsPassed": budgetOK
            ])
        }
    }

    private static func session(_ name: String, index: Int) async -> Session? {
        if name == "synthetic2x" {
            return autoreleasepool {
                guard let image = E2E.checker(E2EPerf.pxW, E2EPerf.pxH) else { return nil }
                return edit(image, scale: E2EPerf.sc, name: name, index: index)
            }
        }
        do {
            guard let frame = try await ScreenCapture.freeze([E2E.screen], showCursor: false).first else { return nil }
            return edit(frame.image, scale: frame.scale, name: name, index: index)
        } catch {
            E2E.record("resources-fullDisplay-capture", false, ["error": error.localizedDescription])
            return nil
        }
    }

    private static func idle() async -> [[String: Double]]? {
        var samples: [[String: Double]] = []
        for _ in 0..<5 {
            guard let before = Snapshot.read() else { return nil }
            await E2E.wait(500)
            guard let after = Snapshot.read() else { return nil }
            let cpu = after.cpuMS - before.cpuMS, wall = after.wallMS - before.wallMS
            guard cpu >= 0, wall > 0 else { return nil }
            samples.append(["cpuMS": cpu, "wallMS": wall, "cpuPercentOneCore": 100 * cpu / wall])
        }
        return samples
    }

    static func run() async {
        var scenarios: [String: Any] = [:]
        for name in ["synthetic2x", "fullDisplay"] {
            guard let warmup = await session(name, index: -1) else {
                E2E.record("resources-\(name)-warmup", false); return
            }
            await E2E.wait(500)
            guard warmup.ownership.released, let idleSamples = await idle(), let baseline = Snapshot.read() else {
                E2E.record("resources-\(name)-measurement", false, ["reason": "Process metrics or warmup cleanup unavailable"]); return
            }
            var sessions: [[String: Any]] = []
            for index in 0..<5 {
                guard let before = Snapshot.read(), var result = await session(name, index: index), let active = Snapshot.read() else {
                    E2E.record("resources-\(name)-session-\(index)", false); return
                }
                await E2E.wait(200)
                guard let after = Snapshot.read() else { E2E.record("resources-\(name)-rss", false); return }
                result.metrics["beforeRSSBytes"] = before.rss
                result.metrics["afterRSSBytes"] = after.rss
                result.metrics["lifetimePeakRSSBytes"] = after.lifetimePeakRSS
                result.metrics["cpuMS"] = active.cpuMS - before.cpuMS
                result.metrics["wallMS"] = active.wallMS - before.wallMS
                result.metrics["ownershipReleased"] = result.ownership.released
                let pass = result.metrics["outputCorrect"] as? Bool == true
                    && result.metrics["budgetsPassed"] as? Bool == true && result.ownership.released
                E2E.record("resources-\(name)-session-\(index)", pass, result.metrics)
                sessions.append(result.metrics)
            }
            guard let end = Snapshot.read() else { E2E.record("resources-\(name)-final", false); return }
            scenarios[name] = ["frameSource": name == "synthetic2x" ? "synthetic" : (E2E.source.contains("fixture") ? "fixture-display" : "ScreenCaptureKit"),
                               "warmIdle": idleSamples, "baselineRSSBytes": baseline.rss, "endRSSBytes": end.rss,
                               "residualGrowthBytes": Int64(end.rss) - Int64(baseline.rss),
                               "lifetimePeakRSSBytes": end.lifetimePeakRSS, "sessions": sessions]
        }
        let report: [String: Any] = ["schemaVersion": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "rssSource": "mach_task_basic_info.resident_size", "peakSource": "getrusage.ru_maxrss (macOS bytes, process lifetime)",
            "cpuSource": "getrusage user+system CPU; percent is relative to one core",
            "scope": "App process including PNG validation and framework caches; excludes WindowServer/GPU memory and CPU. RSS is reported without a baseline-derived growth gate.",
            "scenarios": scenarios]
        E2EPerf.out["resources"] = report
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: E2E.out.appendingPathComponent("resources.json"), options: .atomic)
        } catch { E2E.record("resources-write", false, ["error": error.localizedDescription]) }
    }
}
#endif
