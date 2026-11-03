import Foundation

/// libFuzzer entry point: stored settings bytes must decode to something that round-trips, never trap.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let s = AppSettings.decode(Data(bytes: start, count: count))
    if AppSettings.decode(s.encoded()) != s { fatalError("settings do not round-trip") }
    _ = s.lastRegion?.resolve(displays: [(1, CGSize(width: 1440, height: 900))])
    return 0
}
