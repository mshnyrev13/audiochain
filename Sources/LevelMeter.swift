import AVFoundation
import Combine

struct StereoLevels: Equatable {
    var left = -Double.infinity
    var right = -Double.infinity
    static func dBFS(_ peak: Float) -> Double { peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity }
    func applyingGain(_ gain: Float) -> StereoLevels {
        guard gain > 0 else { return StereoLevels() }
        let offset = 20 * log10(Double(gain))
        return StereoLevels(left: left + offset, right: right + offset)
    }
    func releasing(to next: StereoLevels, by amount: Double) -> StereoLevels {
        func release(_ old: Double, _ new: Double) -> Double {
            guard old.isFinite else { return new }
            let value = max(new, old - amount)
            return value < -90 ? -Double.infinity : value
        }
        return StereoLevels(left: release(left, next.left), right: release(right, next.right))
    }
}
struct MeterBallistics {
    private var latest = StereoLevels()
    private var displayed = StereoLevels()
    private var leftTicks = 0, rightTicks = 0
    mutating func tick(_ measured: StereoLevels) -> StereoLevels {
        // Engine taps may deliver 100 ms buffers while the UI polls every 50 ms.
        // An empty poll means no new buffer, not silence in the source.
        func hold(_ value: Double, latest: inout Double, ticks: inout Int) {
            if value.isFinite || value == .infinity { latest = value; ticks = 4 }
            else { ticks = max(0, ticks - 1); if ticks == 0 { latest = -.infinity } }
        }
        hold(measured.left, latest: &latest.left, ticks: &leftTicks)
        hold(measured.right, latest: &latest.right, ticks: &rightTicks)
        displayed = displayed.releasing(to: latest, by: 1.2)
        return displayed
    }
}
final class LevelMeter: @unchecked Sendable {
    private let meter = ACMeterCreate()!
    deinit { ACMeterDestroy(meter) }
    func observe(_ list: UnsafePointer<AudioBufferList>, skip: UInt32 = 0) { ACMeterObserve(meter, list, skip) }
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        observe(buffer.audioBufferList)
    }
    func read() -> StereoLevels {
        let peaks = ACMeterReadReset(meter)
        return StereoLevels(left: StereoLevels.dBFS(peaks.left), right: StereoLevels.dBFS(peaks.right))
    }
}

@MainActor final class DisplayMeters: ObservableObject {
    @Published var input = StereoLevels()
    @Published var output = StereoLevels()
}
