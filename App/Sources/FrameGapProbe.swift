#if FRAME_GAP_PROBE
import AppKit
@preconcurrency import ScreenCaptureKit
import IOSurface
import ShareXAgent

// Diagnostic build only. Values copied into these records never retain a capture buffer.
struct FrameGapCallback: Codable, Sendable {
    var entryUptime: Double
    var exitUptime = 0.0
    var pts: Double?
    var ptsValue: Int64
    var ptsTimescale: Int32
    var ptsEpoch: Int64
    var ptsFlags: UInt32
    var displayTime: UInt64?
    var status: Int?
    var valid: Bool
    var dataReady: Bool
    var screen: Bool
    var image: Bool
    var surfaceID: UInt32?
    var retainedSurfaceID: UInt32?
    var writerStatus: Int?
    var writerReady: Bool?
    var finishing: Bool?
    var failed: Bool?
    var appendStart: Double?
    var appendEnd: Double?
    var appended: Bool?
}

struct FrameGapLimit: Codable, Sendable {
    var entryUptime: Double
    var exitUptime = 0.0
    var fileStart: Double?
    var fileEnd: Double?
    var volumeStart: Double?
    var volumeEnd: Double?
}

struct FrameGapSnapshot: Codable, Sendable {
    let callbacks: [FrameGapCallback]
    let limits: [FrameGapLimit]
    let overflow: Int
    let heartbeats: [Double]
    let streamErrors: [String]
}

final class FrameGapTrace: @unchecked Sendable {
    private let capacity = 4096
    private var callbacks: [FrameGapCallback] = []
    private var limits: [FrameGapLimit] = []
    private var overflow = 0
    private var heartbeats: [Double] = []
    private var streamErrors: [String] = []
    private var heartbeat: DispatchSourceTimer?

    init() {
        callbacks.reserveCapacity(capacity)
        limits.reserveCapacity(capacity)
        heartbeats.reserveCapacity(capacity)
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func surfaceID(_ sample: CMSampleBuffer?) -> UInt32? {
        guard let sample, let image = CMSampleBufferGetImageBuffer(sample),
              let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return nil }
        return IOSurfaceGetID(surface)
    }

    func enter(_ sample: CMSampleBuffer, type: SCStreamOutputType) -> FrameGapCallback {
        let entry = Self.now()
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        return FrameGapCallback(entryUptime: entry, pts: pts.isNumeric && pts.seconds.isFinite ? pts.seconds : nil,
            ptsValue: pts.value, ptsTimescale: pts.timescale, ptsEpoch: pts.epoch, ptsFlags: pts.flags.rawValue,
            displayTime: (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value,
            status: attachments?.first?[.status] as? Int, valid: sample.isValid,
            dataReady: CMSampleBufferDataIsReady(sample), screen: type == .screen,
            image: CMSampleBufferGetImageBuffer(sample) != nil, surfaceID: Self.surfaceID(sample))
    }

    func leave(_ value: FrameGapCallback) {
        guard callbacks.count < capacity else { overflow += 1; return }
        var value = value
        value.exitUptime = Self.now()
        callbacks.append(value)
    }

    func leave(_ value: FrameGapLimit) {
        guard limits.count < capacity else { overflow += 1; return }
        var value = value
        value.exitUptime = Self.now()
        limits.append(value)
    }

    func startHeartbeat(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if heartbeats.count < capacity { heartbeats.append(Self.now()) } else { overflow += 1 }
        }
        heartbeat = timer
        timer.resume()
    }

    func stopHeartbeat() { heartbeat?.cancel(); heartbeat = nil }
    func streamFailed(_ error: Error) {
        if streamErrors.count < 16 { streamErrors.append(error.localizedDescription) } else { overflow += 1 }
    }
    func snapshot() -> FrameGapSnapshot {
        FrameGapSnapshot(callbacks: callbacks, limits: limits, overflow: overflow, heartbeats: heartbeats, streamErrors: streamErrors)
    }
}

private final class ProbeStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error? = nil) {
        lock.lock()
        let value = continuation; continuation = nil
        lock.unlock()
        if let error { value?.resume(throwing: error) } else { value?.resume() }
    }
}

private final class MetadataConsumer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.sharexmac.probe.metadata", qos: .userInitiated)
    let trace = FrameGapTrace()
    var startup: ProbeStartGate?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        let event = trace.enter(sampleBuffer, type: outputType)
        defer { trace.leave(event) }
        if event.screen, event.valid, event.image, event.status == SCFrameStatus.complete.rawValue, event.pts != nil {
            startup?.finish(); startup = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.trace.streamFailed(error)
            self.startup?.finish(error); self.startup = nil
        }
    }

    func snapshot() async -> FrameGapSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.trace.stopHeartbeat()
                continuation.resume(returning: self.trace.snapshot())
            }
        }
    }
}

@MainActor
enum FrameGapProbe {
    struct Report: Codable {
        var variant: String
        var windowTitle: String
        var pid = ProcessInfo.processInfo.processIdentifier
        var width = 640
        var height = 480
        var fps = 15
        var queueDepth = 3
        var requestedDuration = 6.0
        var startRequested: Double?
        var startAcknowledged: Double?
        var stopRequested: Double?
        var stopAcknowledged: Double?
        var acceptedFrames: Int?
        var droppedFrames: Int?
        var duration: Double?
        var error: String?
        var trace: FrameGapSnapshot?
    }

    static func handlesMode() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--frame-gap-probe" else { return false }
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard arguments.count == 3, ["production", "metadata"].contains(arguments[0]) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let result = await run(variant: arguments[0], title: arguments[1], directory: URL(fileURLWithPath: arguments[2]))
            exit(result ? 0 : 1)
        }
        app.run()
        return true
    }

    private static func run(variant: String, title: String, directory: URL) async -> Bool {
        var report = Report(variant: variant, windowTitle: title)
        do {
            guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
                throw AgentFailure(.invalidRequest, "This diagnostic is restricted to a disposable GitHub runner.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let targets = CaptureTargets()
            guard let target = try await targets.list().first(where: { $0.kind == .window && $0.name == title }) else {
                throw AgentFailure(.targetNotFound, "The named diagnostic fixture window was not found.")
            }
            let resolved = try await targets.resolve(CaptureSelection(target: target.token), recording: true)
            resolved.configuration.width = report.width
            resolved.configuration.height = report.height
            resolved.configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(report.fps))
            report.queueDepth = resolved.configuration.queueDepth
            if variant == "production" {
                let recorder = try ScreenRecorder(target: resolved,
                    options: RecordingOptions(fps: report.fps, maxDurationSeconds: 20),
                    url: directory.appendingPathComponent("recording.mp4"), onFailure: { _ in }, onLimit: { _ in })
                do {
                    report.startRequested = FrameGapTrace.now()
                    _ = try await recorder.start()
                    report.startAcknowledged = FrameGapTrace.now()
                    try await Task.sleep(for: .seconds(report.requestedDuration))
                    report.stopRequested = FrameGapTrace.now()
                    let video = try await recorder.finish()
                    report.stopAcknowledged = FrameGapTrace.now()
                    report.acceptedFrames = video.statistics.acceptedFrames
                    report.droppedFrames = video.statistics.droppedFrames
                    report.duration = video.duration
                } catch {
                    report.error = error.localizedDescription
                    _ = try? await recorder.finish()
                    report.stopAcknowledged = FrameGapTrace.now()
                }
                report.trace = await recorder.probeSnapshot()
            } else {
                let consumer = MetadataConsumer()
                let stream = SCStream(filter: resolved.filter, configuration: resolved.configuration, delegate: consumer)
                try stream.addStreamOutput(consumer, type: .screen, sampleHandlerQueue: consumer.queue)
                do {
                    report.startRequested = FrameGapTrace.now()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let gate = ProbeStartGate(continuation)
                        consumer.queue.async {
                            consumer.trace.startHeartbeat(on: consumer.queue)
                            consumer.startup = gate
                        }
                        stream.startCapture { error in if let error { gate.finish(error) } }
                        consumer.queue.asyncAfter(deadline: .now() + 12) {
                            gate.finish(AgentFailure(.startupTimeout, "Metadata consumer saw no complete frame within 12 seconds."))
                        }
                    }
                    report.startAcknowledged = FrameGapTrace.now()
                    try await Task.sleep(for: .seconds(report.requestedDuration))
                } catch { report.error = error.localizedDescription }
                report.stopRequested = FrameGapTrace.now()
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let gate = ProbeStartGate(continuation)
                        stream.stopCapture { error in gate.finish(error) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                            gate.finish(AgentFailure(.recordingFailed, "Metadata stream stop exceeded 5 seconds."))
                        }
                    }
                } catch { report.error = [report.error, error.localizedDescription].compactMap { $0 }.joined(separator: "; ") }
                report.stopAcknowledged = FrameGapTrace.now()
                report.trace = await consumer.snapshot()
            }
        } catch { report.error = error.localizedDescription }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("trace.json"), options: .atomic)
        } catch { return false }
        return report.error == nil
    }
}
#endif
