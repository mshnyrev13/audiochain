import Foundation
import CoreAudio
import Combine

struct ResourceSnapshot: Equatable {
    var cpu: Double? = nil
    var memoryUsed: UInt64? = nil
    var memoryTotal: UInt64 = 0
    var appCPU: Double? = nil
    var appMemory: UInt64? = nil
    var macText: String {
        let cpuText = cpu.map { String(format: "%.0f%%", $0) } ?? "—"
        let ram = memoryUsed.map { String(format: "%.1f / %.0f ГБ", Double($0) / 1_073_741_824, Double(memoryTotal) / 1_073_741_824) } ?? "—"
        return "Mac CPU \(cpuText) · RAM \(ram)"
    }
    var appText: String {
        "AudioChain CPU \(appCPU.map { String(format: "%.1f%%", $0) } ?? "—") · RAM \(appMemory.map { String(format: "%.0f МБ", Double($0) / 1_048_576) } ?? "—")"
    }
}

// Fast-changing measurements have their own publisher. A CPU sample or a
// queue-depth change must not invalidate every card and cable in AudioModel.
final class DisplayTelemetry: ObservableObject {
    @Published var resources = ResourceSnapshot()
    @Published var blockLatencies: [UUID:Double] = [:]
    @Published var routeLatency: Double?
    @Published var transportStatus = ""
    @Published var auLoads:[AULoad]=[]
    @Published var health=SignalHealth(text:"Остановлено")
    @Published var underruns:UInt64=0
    @Published var dropped:UInt64=0
    @Published var pcmErrors:UInt64=0
    @Published var hasRunMeasurements=false
    @Published var playbackRunning=false
}
struct ResourceMonitor {
    private var previous: ACSystemMetrics? = nil
    mutating func sample(_ current:ACSystemMetrics = ACReadSystemMetrics()) -> ResourceSnapshot {
        var result = ResourceSnapshot()
        if current.memoryValid != 0 { result.memoryUsed = min(current.memoryUsed, current.memoryTotal); result.memoryTotal = current.memoryTotal }
        if current.appValid != 0 { result.appMemory = current.appMemory }
        if let previous {
            if current.cpuValid != 0 && previous.cpuValid != 0 && current.cpuTotal > previous.cpuTotal && current.cpuBusy >= previous.cpuBusy {
                result.cpu = min(100, max(0, Double(current.cpuBusy - previous.cpuBusy) / Double(current.cpuTotal - previous.cpuTotal) * 100))
            }
            let dt = current.wallSeconds - previous.wallSeconds
            if current.appCPUValid != 0,previous.appCPUValid != 0,dt.isFinite,dt>0,
               current.appCPUSeconds.isFinite,previous.appCPUSeconds.isFinite,
               previous.appCPUSeconds>=0,current.appCPUSeconds>=previous.appCPUSeconds {
                let value=(current.appCPUSeconds-previous.appCPUSeconds)/dt*100
                if value.isFinite {result.appCPU=value}
            }
        }
        previous = current
        return result
    }
}
extension Devices {
    // HAL reports device/stream latency; wireless/network delays may be unreported.
    static func latencyMilliseconds(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, buffer: UInt32) -> Double? {
        guard let rate = try? sampleRate(id) else { return nil }
        func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }
        guard let device = frames(id, kAudioDevicePropertyLatency, scope), let safety = frames(id, kAudioDevicePropertySafetyOffset, scope) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0, streamLatency: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            let result = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
            if result == noErr { streamLatency = streams.map { frames($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) ?? 0 }.max() ?? 0 }
        }
        return (Double(device) + Double(safety) + Double(streamLatency) + Double(buffer)) * 1000 / rate
    }
}
