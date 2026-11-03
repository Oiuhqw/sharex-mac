import Foundation
import os

/// Signposts (visible in Instruments' Points of Interest / os_signpost) plus wall-clock timing for the perf scenario.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.sharexmac.ShareX", category: .pointsOfInterest)
    /// Host uptime in milliseconds (monotonic).
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    /// Main-thread stamps written by instrumented code; read by the perf scenario.
    nonisolated(unsafe) static var stamps: [String: Double] = [:]
    static func stamp(_ name: StaticString) {
        stamps["\(name)"] = now()
        signposter.emitEvent(name)
    }
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let st = signposter.beginInterval(name)
        defer { signposter.endInterval(name, st) }
        return try body()
    }
}
