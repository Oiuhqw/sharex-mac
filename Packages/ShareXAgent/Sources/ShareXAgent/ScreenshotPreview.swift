import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

enum ScreenshotPreview {
    static let maxPixelSize = 1568
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private struct Session: Decodable {
        struct Artifact: Decodable {
            let id: UUID
            let path: String?
        }
        let artifacts: [Artifact]
    }

    static func imageBlock(for response: AgentResponse) -> JSONValue? {
        guard let session = try? response.result?.decode(Session.self),
              let path = session.artifacts.first(where: { $0.id == response.id })?.path,
              let file = FileManager.default.contents(atPath: path), file.starts(with: pngSignature),
              let image = scaled(file) else { return nil }
        return .object(["type": .string("image"), "data": .string(image.base64EncodedString()), "mimeType": .string("image/png")])
    }

    private static func scaled(_ png: Data) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard max(image.width, image.height) > maxPixelSize else { return png }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        let output = NSMutableData()
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
        #else
        return png
        #endif
    }
}
