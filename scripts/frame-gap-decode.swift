import AVFoundation
import Foundation

@main
private struct Main {
    static func main() async {
        var result: [String: Any] = ["status": "failed", "frames": [[String: Any]]()]
        var frames: [[String: Any]] = []
        do {
            guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Usage: frame-gap-decode VIDEO", code: 2) }
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            result["durationSeconds"] = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "No video track", code: 1)
            }
            let size = try await track.load(.naturalSize)
            result["width"] = size.width; result["height"] = size.height
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "Decoder did not start", code: 1) }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while frames.count < 4096, ProcessInfo.processInfo.systemUptime < deadline {
                let found = autoreleasepool { () -> Bool in
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let duration = CMSampleBufferGetDuration(sample).seconds
                    var frame: [String: Any] = ["valid": sample.isValid,
                        "image": CMSampleBufferGetImageBuffer(sample) != nil]
                    if pts.isFinite { frame["pts"] = pts }
                    if duration.isFinite { frame["duration"] = duration }
                    frames.append(frame)
                    return true
                }
                if !found { break }
            }
            guard reader.status == .completed else {
                reader.cancelReading()
                throw reader.error ?? NSError(domain: "Decoder failed or exceeded its bounded budget", code: 1)
            }
            result["status"] = "passed"
        } catch { result["error"] = error.localizedDescription }
        result["frames"] = frames
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(result["status"] as? String == "passed" ? 0 : 1)
    }
}
