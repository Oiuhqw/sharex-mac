import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import ShareXAgent

struct RecorderStatistics: Sendable {
    let acceptedFrames: Int
    let droppedFrames: Int
    let startedAt: Date?
    let durationSeconds: Double
}

struct RecordedVideo: Sendable {
    let width: Int
    let height: Int
    let duration: Double
    let statistics: RecorderStatistics
}

@MainActor
final class ScreenRecorder {
    private let stream: SCStream
    private let writer: CaptureVideoWriter
    private let partialURL: URL
    private let width: Int
    private let height: Int
    private var finishTask: Task<RecordedVideo, Error>?

    init(target: CaptureTargets.Resolved, options: RecordingOptions, url: URL,
         onFailure: @escaping @Sendable (AgentFailure) -> Void,
         onLimit: @escaping @Sendable (String) -> Void) throws {
        partialURL = url; width = target.configuration.width; height = target.configuration.height
        target.configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        writer = try CaptureVideoWriter(url: url, width: width, height: height, options: options, onFailure: onFailure, onLimit: onLimit)
        stream = SCStream(filter: target.filter, configuration: target.configuration, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
    }

    func start() async throws -> RecorderStatistics {
        try await withCheckedThrowingContinuation { continuation in
            writer.begin { result in continuation.resume(with: result) }
            stream.startCapture { [writer] error in
                if let error { writer.captureFailed(AgentFailure(.recordingFailed, "Cannot start screen recording: \(error.localizedDescription)")) }
            }
        }
    }

    func cancelStartup() { writer.cancelStartup() }
    func statistics() async -> RecorderStatistics { await writer.statistics() }

    func finish() async throws -> RecordedVideo {
        if let finishTask { return try await finishTask.value }
        let task = Task { @MainActor in
            writer.freeze()
            let stopFailure = await stopStream()
            let stats = try await writer.finish()
            if let stopFailure { throw stopFailure }
            let url = partialURL, expectedWidth = width, expectedHeight = height
            return try await Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw AgentFailure(.recordingFailed, "The finalized file contains no video track.")
                }
                let size = try await track.load(.naturalSize)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0, Int(size.width) == expectedWidth, Int(size.height) == expectedHeight,
                      duration + 0.15 >= stats.durationSeconds else {
                    throw AgentFailure(.recordingFailed, "The finalized video dimensions or duration do not match the capture.")
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw AgentFailure(.recordingFailed, "Cannot decode the finalized video.") }
                reader.add(output)
                guard reader.startReading(), let sample = output.copyNextSampleBuffer(), sample.isValid,
                      CMSampleBufferGetImageBuffer(sample) != nil else {
                    throw AgentFailure(.recordingFailed, "The finalized video has no readable video frame.")
                }
                reader.cancelReading()
                return RecordedVideo(width: expectedWidth, height: expectedHeight, duration: duration, statistics: stats)
            }.value
        }
        finishTask = task
        return try await task.value
    }

    private func stopStream() async -> AgentFailure? {
        // Writer finalization has its own deadline, including when ScreenCaptureKit never acknowledges stop.
        await withCheckedContinuation { continuation in
            let gate = StopContinuation(continuation)
            stream.stopCapture { error in
                gate.resume(error.map { AgentFailure(.recordingFailed, "The capture stream could not stop: \($0.localizedDescription)") })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                gate.resume(AgentFailure(.recordingFailed, "The capture stream did not acknowledge stop within 5 seconds."))
            }
        }
    }
}

private final class StopContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentFailure?, Never>?
    init(_ continuation: CheckedContinuation<AgentFailure?, Never>) { self.continuation = continuation }
    func resume(_ failure: AgentFailure?) {
        lock.lock()
        let value = continuation; continuation = nil
        lock.unlock()
        value?.resume(returning: failure)
    }
}

private final class CaptureVideoWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.sharexmac.agent.video", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let fps: Int
    private let url: URL
    private let options: RecordingOptions
    private let onFailure: @Sendable (AgentFailure) -> Void
    private let onLimit: @Sendable (String) -> Void
    private var limitTimer: DispatchSourceTimer?
    private var startup: (@Sendable (Result<RecorderStatistics, Error>) -> Void)?
    private var completion: CheckedContinuation<RecorderStatistics, Error>?
    private var firstPTS: CMTime?
    private var firstUptime: Double?
    private var startedAt: Date?
    private var lastSample: CMSampleBuffer?
    private var accepted = 0
    private var dropped = 0
    private var endingDuration: Double?
    private var finishing = false
    private var failure: AgentFailure?

    init(url: URL, width: Int, height: Int, options: RecordingOptions, onFailure: @escaping @Sendable (AgentFailure) -> Void,
         onLimit: @escaping @Sendable (String) -> Void) throws {
        let fps = options.fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(2_000_000, width * height * 4)),
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AgentFailure(.recordingFailed, "H.264 encoding is unavailable for these dimensions.") }
        writer.add(input)
        self.fps = fps; self.url = url; self.options = options; self.onFailure = onFailure; self.onLimit = onLimit
        super.init()
    }

    func begin(_ callback: @escaping @Sendable (Result<RecorderStatistics, Error>) -> Void) {
        queue.async {
            self.startup = callback
            guard self.writer.startWriting() else { self.fail(self.writerFailure()); return }
            self.queue.asyncAfter(deadline: .now() + 12) {
                if self.startup != nil { self.fail(AgentFailure(.startupTimeout, "The writer did not accept a complete frame within 12 seconds.")) }
            }
        }
    }

    func cancelStartup() {
        queue.async {
            if self.firstPTS == nil { self.fail(AgentFailure(.interrupted, "Recording stopped before its first complete frame.")) }
        }
    }

    func captureFailed(_ error: AgentFailure) { queue.async { self.fail(error) } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureFailed(AgentFailure(.recordingFailed, "The capture stream stopped: \(error.localizedDescription)"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, !finishing, failure == nil, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard writer.status == .writing else { fail(writerFailure()); return }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { dropped += 1; return }
        if firstPTS == nil { writer.startSession(atSourceTime: pts) }
        guard input.append(sampleBuffer) else { fail(writerFailure()); return }
        accepted += 1; lastSample = sampleBuffer
        if firstPTS == nil {
            firstPTS = pts; firstUptime = ProcessInfo.processInfo.systemUptime; startedAt = Date()
            startLimitTimer()
            let callback = startup; startup = nil; callback?(.success(snapshot()))
        }
    }

    func statistics() async -> RecorderStatistics {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.snapshot()) } }
    }

    func freeze() {
        queue.async {
            self.finishing = true
            self.limitTimer?.cancel(); self.limitTimer = nil
            if self.endingDuration == nil { self.endingDuration = self.firstUptime.map { ProcessInfo.processInfo.systemUptime - $0 } }
        }
    }

    private func startLimitTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkLimits() }
        limitTimer = timer; timer.resume()
    }

    private func checkLimits() {
        guard !finishing, failure == nil, let firstUptime else { return }
        let reason: String?
        if ProcessInfo.processInfo.systemUptime - firstUptime >= options.maxDurationSeconds {
            reason = "duration_limit"
        } else {
            do {
                let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let available = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                if bytes >= options.maxBytes - min(options.maxBytes / 10, 16_777_216) { reason = "byte_limit" }
                else if available < CaptureLimits().diskReserveBytes + 8_388_608 { reason = "disk_reserve" }
                else { reason = nil }
            } catch { fail(AgentFailure(.storageFailed, "Cannot monitor recording storage: \(error.localizedDescription)")); return }
        }
        if let reason {
            finishing = true; endingDuration = ProcessInfo.processInfo.systemUptime - firstUptime
            limitTimer?.cancel(); limitTimer = nil
            onLimit(reason)
        }
    }

    func finish() async throws -> RecorderStatistics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishing = true; self.completion = continuation
                if self.endingDuration == nil { self.endingDuration = self.firstUptime.map { ProcessInfo.processInfo.systemUptime - $0 } }
                if let failure = self.failure { self.writer.cancelWriting(); self.complete(.failure(failure)); return }
                guard self.firstPTS != nil else {
                    self.writer.cancelWriting()
                    self.complete(.failure(AgentFailure(.recordingFailed, "No complete frame was accepted by the writer.")))
                    return
                }
                self.appendEndingFrame(deadline: ProcessInfo.processInfo.systemUptime + 10)
            }
        }
    }

    private func appendEndingFrame(deadline: Double) {
        guard writer.status == .writing else { complete(.failure(writerFailure())); return }
        guard input.isReadyForMoreMediaData else {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                writer.cancelWriting(); complete(.failure(AgentFailure(.recordingFailed, "The writer did not accept the ending frame."))); return
            }
            queue.asyncAfter(deadline: .now() + 0.01) { self.appendEndingFrame(deadline: deadline) }
            return
        }
        guard let lastSample, let firstPTS else { complete(.failure(writerFailure())); return }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let endPTS = max(CMTimeAdd(firstPTS, CMTime(seconds: endingDuration ?? 0, preferredTimescale: 600)),
                         CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(lastSample), frameDuration))
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: endPTS, decodeTimeStamp: .invalid)
        var endingSample: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastSample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &endingSample) == noErr,
              let endingSample, input.append(endingSample) else { complete(.failure(writerFailure())); return }
        accepted += 1
        writer.endSession(atSourceTime: CMTimeAdd(endPTS, frameDuration))
        input.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                if self.writer.status == .completed { self.complete(.success(self.snapshot())) }
                else { self.complete(.failure(self.writerFailure())) }
            }
        }
        queue.asyncAfter(deadline: .now() + 20) {
            guard self.completion != nil else { return }
            self.writer.cancelWriting()
            self.complete(.failure(AgentFailure(.recordingFailed, "Video finalization exceeded its deadline. The partial file is incomplete.")))
        }
    }

    private func snapshot() -> RecorderStatistics {
        RecorderStatistics(acceptedFrames: accepted, droppedFrames: dropped, startedAt: startedAt,
            durationSeconds: endingDuration ?? firstUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }
    private func writerFailure() -> AgentFailure {
        AgentFailure(.recordingFailed, writer.error?.localizedDescription ?? "The video writer rejected the capture.")
    }
    private func fail(_ error: AgentFailure) {
        guard failure == nil, !finishing else { return }
        failure = error
        limitTimer?.cancel(); limitTimer = nil
        let callback = startup; startup = nil; callback?(.failure(error))
        onFailure(error)
    }
    private func complete(_ result: Result<RecorderStatistics, Error>) {
        let continuation = completion; completion = nil; lastSample = nil
        limitTimer?.cancel(); limitTimer = nil
        continuation?.resume(with: result)
    }
}
