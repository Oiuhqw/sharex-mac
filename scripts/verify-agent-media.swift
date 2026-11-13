import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct VerificationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Anchor: Decodable {
    let x: Double
    let y: Double
    let rgb: [Int]
}

private struct Expectation: Decodable {
    let width: Int
    let height: Int
    let anchors: [Anchor]
    let marker: Anchor
    let stages: [Int]
    let minimumDuration: Double
    let maximumDuration: Double
    let fps: Double
}

private struct Pixels {
    let width: Int
    let height: Int
    let rowBytes: Int
    let bytes: UnsafePointer<UInt8>
    let bgra: Bool

    func color(at anchor: Anchor) throws -> [Int] {
        guard anchor.x > 0, anchor.x < 1, anchor.y > 0, anchor.y < 1 else {
            throw VerificationError("Expected sample lies outside the captured area.")
        }
        let x = Int(anchor.x * Double(width))
        let y = Int(anchor.y * Double(height))
        var sums = [0, 0, 0]
        var count = 0
        for row in max(0, y - 2)...min(height - 1, y + 2) {
            for column in max(0, x - 2)...min(width - 1, x + 2) {
                let offset = row * rowBytes + column * 4
                for channel in 0..<3 { sums[channel] += Int(bytes[offset + (bgra ? 2 - channel : channel)]) }
                count += 1
            }
        }
        return sums.map { $0 / count }
    }

    func inspect(_ expected: Expectation) throws -> [String: Any] {
        guard width == expected.width, height == expected.height else {
            throw VerificationError("Decoded dimensions \(width)x\(height) differ from expected \(expected.width)x\(expected.height).")
        }
        var measured: [[Int]] = []
        for anchor in expected.anchors {
            let rgb = try color(at: anchor)
            guard matches(rgb, anchor.rgb) else {
                throw VerificationError("Fixture color at \(anchor.x),\(anchor.y) is \(rgb), expected \(anchor.rgb).")
            }
            measured.append(rgb)
        }
        let marker = try color(at: expected.marker)
        let palette = [[0, 255, 255], [255, 0, 255], [255, 255, 255]]
        let stage = palette.firstIndex { matches(marker, $0) } ?? -1
        return ["stage": stage, "markerRGB": marker, "anchorRGB": measured]
    }
}

private func matches(_ observed: [Int], _ expected: [Int]) -> Bool {
    observed.count == 3 && expected.count == 3
        && zip(observed, expected).allSatisfy { pair in abs(pair.0 - pair.1) <= 45 }
}

private func fileHash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func verifyPNG(_ url: URL, expected: Expectation) throws -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw VerificationError("ImageIO could not decode a single PNG image.")
    }
    let stride = image.width * 4
    var bytes = [UInt8](repeating: 0, count: stride * image.height)
    let sample = try bytes.withUnsafeMutableBytes { buffer -> [String: Any] in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                        | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VerificationError("Cannot allocate an independent PNG decoder.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return try Pixels(width: image.width, height: image.height, rowBytes: stride,
                          bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), bgra: false).inspect(expected)
    }
    guard expected.stages == [sample["stage"] as? Int ?? -1] else {
        throw VerificationError("PNG marker does not show the requested fixture stage.")
    }
    return ["kind": "png", "width": image.width, "height": image.height, "sample": sample]
}

private func verifyVideo(_ url: URL, expected: Expectation) async throws -> [String: Any] {
    let file = try FileHandle(forReadingFrom: url)
    let header = try file.read(upToCount: 64) ?? Data()
    try file.close()
    let brand = header.count >= 12 ? String(data: header[8..<12], encoding: .ascii) ?? "" : ""
    guard header.count >= 12, String(data: header[4..<8], encoding: .ascii) == "ftyp",
          ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "].contains(brand) else {
        throw VerificationError("Video is not an MPEG-4 container with a recognized file type brand.")
    }
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count == 1, audio.isEmpty else {
        throw VerificationError("Expected one video track and no audio tracks.")
    }
    let formats = try await tracks[0].load(.formatDescriptions)
    guard !formats.isEmpty, formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
        throw VerificationError("Video track is not H.264.")
    }
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration >= expected.minimumDuration, duration <= expected.maximumDuration else {
        throw VerificationError("Video duration \(duration) is outside \(expected.minimumDuration)...\(expected.maximumDuration).")
    }
    let transform = try await tracks[0].load(.preferredTransform)
    guard transform == .identity else { throw VerificationError("Unexpected video orientation transform.") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw VerificationError("AVAssetReader cannot decode the video track.") }
    reader.add(output)
    guard reader.startReading() else { throw VerificationError("AVAssetReader did not start: \(String(describing: reader.error))") }
    var frames: [[String: Any]] = []
    var previousTime = -Double.infinity
    var maximumGap = 0.0
    var stageCounts = [Int: Int]()
    while let sample = output.copyNextSampleBuffer() {
        try autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw VerificationError("Decoded sample has no image buffer.")
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite, timestamp > previousTime else {
                throw VerificationError("Frame timestamps are invalid or not strictly increasing.")
            }
            if previousTime.isFinite { maximumGap = max(maximumGap, timestamp - previousTime) }
            previousTime = timestamp
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw VerificationError("Decoded frame bytes are unavailable.")
            }
            var check = try Pixels(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                                   rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   bytes: base.assumingMemoryBound(to: UInt8.self), bgra: true).inspect(expected)
            check["timeSeconds"] = timestamp
            frames.append(check)
            stageCounts[check["stage"] as? Int ?? -1, default: 0] += 1
        }
    }
    guard reader.status == .completed else {
        throw VerificationError("Video decoder did not complete: \(String(describing: reader.error))")
    }
    guard frames.count >= max(3, Int(expected.minimumDuration * expected.fps * 0.65)) else {
        throw VerificationError("Video has too few decoded frames: \(frames.count).")
    }
    let first = frames[0]
    let last = frames[frames.count - 1]
    let firstTime = first["timeSeconds"] as! Double
    let lastTime = last["timeSeconds"] as! Double
    guard firstTime <= 0.20, lastTime >= duration - max(0.25, 3 / expected.fps), maximumGap <= 0.5 else {
        throw VerificationError("Frame timing lacks beginning, ending, or continuous coverage.")
    }
    let middle = frames.min { abs(($0["timeSeconds"] as! Double) - duration / 2)
        < abs(($1["timeSeconds"] as! Double) - duration / 2) }!
    let observedStages = [first, middle, last].map { $0["stage"] as! Int }
    let expectedStages = expected.stages.count == 1 ? Array(repeating: expected.stages[0], count: 3) : expected.stages
    guard observedStages == expectedStages else {
        throw VerificationError("First, middle, last marker stages are \(observedStages), expected \(expectedStages).")
    }
    for stage in Set(expected.stages) {
        guard stageCounts[stage, default: 0] >= max(2, Int(expected.fps * 0.25)) else {
            throw VerificationError("Fixture stage \(stage) has too little decoded coverage.")
        }
    }
    guard stageCounts[-1, default: 0] <= max(1, frames.count / 100) else {
        throw VerificationError("Video contains unrecognized marker frames.")
    }
    return ["kind": "mp4", "containerBrand": brand, "codec": "H.264",
            "width": expected.width, "height": expected.height,
            "durationSeconds": duration, "frameCount": frames.count, "maximumFrameGapSeconds": maximumGap,
            "estimatedMissingFrames": max(0, Int((duration * expected.fps).rounded()) - frames.count),
            "estimatedMissingFramesBasis": "Decoded frame count compared with requested FPS times track duration.",
            "stageFrameCounts": Dictionary(uniqueKeysWithValues: stageCounts.map { (String($0.key), $0.value) }),
            "first": first, "middle": middle, "last": last]
}

@main
private struct Main {
    static func main() async {
        var result: [String: Any] = ["status": "failed"]
        var code: Int32 = 1
        do {
            guard CommandLine.arguments.count == 3 else {
                throw VerificationError("Usage: verify-agent-media MEDIA_PATH EXPECTATION_JSON")
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let expected = try JSONDecoder().decode(Expectation.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            guard expected.width > 0, expected.height > 0, expected.fps > 0,
                  !expected.anchors.isEmpty, !expected.stages.isEmpty else {
                throw VerificationError("Incomplete media expectation.")
            }
            switch url.pathExtension.lowercased() {
            case "png": result = try verifyPNG(url, expected: expected)
            case "mp4": result = try await verifyVideo(url, expected: expected)
            default: throw VerificationError("Only PNG and MP4 evidence is accepted.")
            }
            result["sha256"] = try fileHash(url)
            result["bytes"] = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            result["status"] = "passed"
            code = 0
        } catch { result["reason"] = String(describing: error) }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
        exit(code)
    }
}
