#if FRAME_GAP_PROBE
import AppKit
@preconcurrency import ScreenCaptureKit
import IOSurface
import Darwin
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
    var sourcePixelFormat: UInt32?
    var surfaceID: UInt32?
    var retainedSurfaceID: UInt32?
    var writerStatus: Int?
    var writerReady: Bool?
    var finishing: Bool?
    var failed: Bool?
    var appendStart: Double?
    var appendEnd: Double?
    var appended: Bool?
    var ownedBuffers = false
    var copyStart: Double?
    var copyEnd: Double?
    var copyAllocationStart: Double?
    var copyAllocationEnd: Double?
    var copySourceLockStart: Double?
    var copySourceLockEnd: Double?
    var copyOwnedLockStart: Double?
    var copyOwnedLockEnd: Double?
    var copyRowsStart: Double?
    var copyRowsEnd: Double?
    var copyMetadataStart: Double?
    var copyMetadataEnd: Double?
    var copyOwnedUnlockStart: Double?
    var copyOwnedUnlockEnd: Double?
    var copySourceUnlockStart: Double?
    var copySourceUnlockEnd: Double?
    var copySucceeded: Bool?
    var copyError: String?
    var copyDisjoint: Bool?
    var sourceBaseAddress: UInt64?
    var ownedBaseAddress: UInt64?
    var sourceBytesPerRow: Int?
    var ownedBytesPerRow: Int?
    var copyWidth: Int?
    var copyHeight: Int?
    var copyPixelFormat: UInt32?
    var copyBytes: Int?
    var ownedSurfaceID: UInt32?
}

enum FrameGapOwnedBuffer {
    static let enabled = ProcessInfo.processInfo.environment["SHAREX_FRAME_GAP_OWNED_BUFFERS"] == "1"

    static func copy(_ sample: CMSampleBuffer, event: inout FrameGapCallback) throws -> CMSampleBuffer {
        event.copyStart = FrameGapTrace.now()
        event.copySucceeded = false
        defer { event.copyEnd = FrameGapTrace.now() }
        guard let source = CMSampleBufferGetImageBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              CMSampleBufferGetNumSamples(sample) == 1, CMSampleBufferDataIsReady(sample),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(source) else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic requires one ready, packed BGRA frame.")
        }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        event.copyWidth = width; event.copyHeight = height
        event.copyPixelFormat = CVPixelBufferGetPixelFormatType(source)
        event.copyAllocationStart = FrameGapTrace.now()
        var owned: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let allocation = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &owned)
        event.copyAllocationEnd = FrameGapTrace.now()
        guard allocation == kCVReturnSuccess, let owned else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic allocation failed with status \(allocation).")
        }
        event.copySourceLockStart = FrameGapTrace.now()
        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        event.copySourceLockEnd = FrameGapTrace.now()
        guard sourceLock == kCVReturnSuccess else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic could not lock the source pixels.")
        }
        defer {
            event.copySourceUnlockStart = FrameGapTrace.now()
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            event.copySourceUnlockEnd = FrameGapTrace.now()
        }
        event.copyOwnedLockStart = FrameGapTrace.now()
        let ownedLock = CVPixelBufferLockBaseAddress(owned, [])
        event.copyOwnedLockEnd = FrameGapTrace.now()
        guard ownedLock == kCVReturnSuccess else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic could not lock the owned pixels.")
        }
        defer {
            event.copyOwnedUnlockStart = FrameGapTrace.now()
            CVPixelBufferUnlockBaseAddress(owned, [])
            event.copyOwnedUnlockEnd = FrameGapTrace.now()
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let ownedBase = CVPixelBufferGetBaseAddress(owned) else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic received inaccessible pixels.")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source), ownedStride = CVPixelBufferGetBytesPerRow(owned)
        let rowBytes = width * 4
        guard width > 0, height > 0, sourceStride >= rowBytes, ownedStride >= rowBytes,
              CVPixelBufferGetDataSize(source) >= sourceStride * height,
              CVPixelBufferGetDataSize(owned) >= ownedStride * height else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic received an invalid BGRA row layout.")
        }
        let sourceAddress = UInt64(UInt(bitPattern: sourceBase)), ownedAddress = UInt64(UInt(bitPattern: ownedBase))
        let ownedSurfaceID = CVPixelBufferGetIOSurface(owned).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        event.sourceBaseAddress = sourceAddress; event.ownedBaseAddress = ownedAddress
        event.sourceBytesPerRow = sourceStride; event.ownedBytesPerRow = ownedStride
        event.ownedSurfaceID = ownedSurfaceID
        let addressDisjoint = sourceAddress + UInt64(sourceStride * height) <= ownedAddress ||
            ownedAddress + UInt64(ownedStride * height) <= sourceAddress
        let surfaceDisjoint = event.surfaceID == nil || ownedSurfaceID == nil || event.surfaceID != ownedSurfaceID
        event.copyDisjoint = addressDisjoint && surfaceDisjoint
        guard event.copyDisjoint == true else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic allocated overlapping pixel storage.")
        }
        event.copyRowsStart = FrameGapTrace.now()
        for row in 0..<height {
            let destination = ownedBase.advanced(by: row * ownedStride)
            memcpy(destination, sourceBase.advanced(by: row * sourceStride), rowBytes)
            if ownedStride > rowBytes { memset(destination.advanced(by: rowBytes), 0, ownedStride - rowBytes) }
        }
        event.copyRowsEnd = FrameGapTrace.now()
        event.copyBytes = rowBytes * height
        event.copyMetadataStart = FrameGapTrace.now()
        defer { event.copyMetadataEnd = FrameGapTrace.now() }
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            if let attachments = CVBufferCopyAttachments(source, mode) { CVBufferSetAttachments(owned, attachments, mode) }
        }
        guard CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: owned) else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic did not preserve the source format.")
        }
        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        guard timingStatus == noErr else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic could not read timing, status \(timingStatus).")
        }
        var result: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: owned, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
        guard sampleStatus == noErr, let result else {
            throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic could not wrap pixels, status \(sampleStatus).")
        }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: mode) {
                CMSetAttachments(result, attachments: attachments, attachmentMode: mode)
            }
        }
        if let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) {
            guard CFArrayGetCount(sourceAttachments) == 1,
                  let ownedAttachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
                  CFArrayGetCount(ownedAttachments) == 1 else {
                throw AgentFailure(.recordingFailed, "Owned-buffer diagnostic could not copy the frame attachments.")
            }
            let sourceDictionary = unsafeBitCast(CFArrayGetValueAtIndex(sourceAttachments, 0), to: CFDictionary.self)
            let ownedDictionary = unsafeBitCast(CFArrayGetValueAtIndex(ownedAttachments, 0), to: CFMutableDictionary.self)
            CFDictionaryApplyFunction(sourceDictionary, { key, value, context in
                let destination = Unmanaged<CFMutableDictionary>.fromOpaque(context!).takeUnretainedValue()
                CFDictionarySetValue(destination, key, value)
            }, Unmanaged.passUnretained(ownedDictionary).toOpaque())
        }
        event.copySucceeded = true
        return result
    }
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
    var operations: [FrameGapOperation] = []
    var operationOverflow = 0
    var context: FrameGapContext?
    var history: FrameGapHistorySnapshot?
    var writerID: String?
}

struct FrameGapHistoryEvent: Codable, Sendable {
    let name: String
    let uptime: Double
    let writerID: String?
    let requestID: String?
    let deadline: Double?
    let value: Bool?
}

struct FrameGapHistorySnapshot: Codable, Sendable {
    let events: [FrameGapHistoryEvent]
    let overflow: Int
}

final class FrameGapHistory: @unchecked Sendable {
    static let shared = FrameGapHistory()
    private let lock = NSLock()
    private var events: [FrameGapHistoryEvent] = []
    private var overflow = 0
    private init() { events.reserveCapacity(20000) }

    func record(_ name: String, writerID: String? = nil, requestID: String? = nil,
                deadline: Double? = nil, value: Bool? = nil) {
        let event = FrameGapHistoryEvent(name: name, uptime: FrameGapTrace.now(), writerID: writerID,
                                        requestID: requestID, deadline: deadline, value: value)
        lock.lock()
        defer { lock.unlock() }
        if events.count < 20000 { events.append(event) } else { overflow += 1 }
    }

    func snapshot() -> FrameGapHistorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FrameGapHistorySnapshot(events: events, overflow: overflow)
    }

    @MainActor
    static func permission(_ name: String) -> Bool {
        shared.record("permission.\(name).begin")
        let result = CGPreflightScreenCaptureAccess()
        shared.record("permission.\(name).end", value: result)
        return result
    }

    func flushAfterShutdown() {
        guard let path = ProcessInfo.processInfo.environment["SHAREX_FRAME_GAP_TRACE_DIR"] else { return }
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot()).write(to: directory.appendingPathComponent("lifecycle-final.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Frame gap final history flush failed: \(error)\n".utf8))
        }
    }
}

struct FrameGapOperation: Codable, Sendable {
    let name: String
    let phase: String
    let uptime: Double
}

struct FrameGapContext: Codable, Sendable {
    let videoPath: String
    let width: Int
    let height: Int
    let fps: Int
    let queueDepth: Int
    let machTimebaseNumerator: UInt32
    let machTimebaseDenominator: UInt32

    init(videoPath: String, width: Int, height: Int, fps: Int, queueDepth: Int) {
        self.videoPath = videoPath; self.width = width; self.height = height
        self.fps = fps; self.queueDepth = queueDepth
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        machTimebaseNumerator = timebase.numer
        machTimebaseDenominator = timebase.denom
    }
}

@MainActor
final class FrameGapOperationLog {
    private(set) var events: [FrameGapOperation] = []
    private(set) var overflow = 0
    init() { events.reserveCapacity(8192) }
    func record(_ name: String, _ phase: String) {
        if events.count < 8192 { events.append(FrameGapOperation(name: name, phase: phase, uptime: FrameGapTrace.now())) }
        else { overflow += 1 }
    }
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
            image: CMSampleBufferGetImageBuffer(sample) != nil,
            sourcePixelFormat: CMSampleBufferGetImageBuffer(sample).map { CVPixelBufferGetPixelFormatType($0) },
            surfaceID: Self.surfaceID(sample))
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
        guard ProcessInfo.processInfo.environment["SHAREX_FRAME_GAP_HEARTBEAT"] != "0" else { return }
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
