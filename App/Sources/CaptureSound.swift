import AppKit

@MainActor
enum CaptureSound {
    private static let click = NSSound(data: waveData, byReference: false)

    static func play() {
        click?.stop()
        click?.volume = 0.65
        click?.play()
    }

    static let waveData: Data = {
        let rate = 44_100
        let count = rate * 9 / 100
        var samples = Data(capacity: count * 2)
        var noise: UInt32 = 0x53485258
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            noise = 1_664_525 &* noise &+ 1_013_904_223
            let random = Double(noise >> 8) / Double(0x00ff_ffff) * 2 - 1
            let attack = min(1, t / 0.0008)
            let first = exp(-t / 0.006) * (0.65 * random + 0.35 * sin(2 * .pi * 2_100 * t))
            let secondTime = max(0, t - 0.024)
            let second = t >= 0.024 ? exp(-secondTime / 0.009) * sin(2 * .pi * 1_400 * secondTime) * 0.35 : 0
            var sample = Int16(max(-1, min(1, (first + second) * attack * 0.75)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }()
}
