import Foundation

enum JSONDepth {
    static let limit = 32

    /// Foundation also decodes UTF-16 and UTF-32 JSON. In those encodings the byte after a backslash is 0x00, so this
    /// scan would lose track of strings. Each bracket in those encodings needs a 0x00 byte, so a 0x00 byte is refused.
    static func isWithinLimit(_ data: Data) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if byte == 0 { return false }
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth > 0 { depth -= 1 }
            default: break
            }
        }
        return true
    }
}
