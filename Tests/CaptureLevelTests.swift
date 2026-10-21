import AppKit
import AVFoundation
import CoreAudio

private final class LevelProbeTap {
    let meter = LevelMeter()
    var tap: AudioObjectID = 0, aggregate: AudioDeviceID = 0
    var io: AudioDeviceIOProcID?
    init(_ description: CATapDescription) throws {
        func require(_ status: OSStatus) throws { if status != noErr { throw AudioFailure("Level probe HAL \(status)") } }
        do {
            try require(AudioHardwareCreateProcessTap(description, &tap))
            let uid = Devices.string(tap, kAudioTapPropertyUID)
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioChain level test",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: false]]
            ]
            try require(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
            let meter = self.meter
            try require(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, _, _ in meter.observe(input) })
            try require(AudioDeviceStart(aggregate, io))
        } catch { close(); throw error }
    }
    func close() {
        if aggregate != 0 {
            if let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        aggregate = 0; tap = 0; io = nil
    }
    deinit { close() }
}

@MainActor func runCaptureLevelTest() async -> Int32 {
    do {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let output = try Devices.defaultOutput()
        try Devices.select(output, for: engine.outputNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: try Devices.sampleRate(output), channels: 2)!
        engine.attach(player); engine.connect(player, to: engine.outputNode, format: format)
        let processes = AudioProcesses.all().filter { $0.pid == getpid() }.map { NSNumber(value: $0.objectID) }
        try check(!processes.isEmpty, "No diagnostic process registered")
        let mixdown = try LevelProbeTap(ACMakeTapDescription(processes, [], false))
        defer { mixdown.close() }
        let device = try LevelProbeTap(ACMakeDeviceTapDescription(processes, [], false, Devices.string(output, kAudioDevicePropertyDeviceUID)))
        defer { device.close() }
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 4))!
        input.frameLength = input.frameCapacity
        for i in 0..<Int(input.frameLength) {
            input.floatChannelData![0][i] = 0.01 * sin(Float(i) * 2 * .pi * 440 / Float(format.sampleRate))
            input.floatChannelData![1][i] = 0.005 * sin(Float(i) * 2 * .pi * 440 / Float(format.sampleRate))
        }
        scheduleLevelDiagnostic(player, input); try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let a = mixdown.meter.read(), b = device.meter.read()
        print("OUTPUT: \(Devices.string(output, kAudioObjectPropertyName)), channels=\(Devices.channels(output, scope: kAudioDevicePropertyScopeOutput)), rate=\(format.sampleRate)")
        print("EXPECTED: -40 / -46.0206 dBFS; mixdown: \(a.left) / \(a.right); stream: \(b.left) / \(b.right)")
        try check(abs(b.left + 40) < 0.1 && abs(b.right + 46.0206) < 0.1, "Device tap altered source amplitude")
        print("PASS: device-stream capture preserves known synthetic amplitude; output muted by tap, no audio recorded")
        return 0
    } catch { print("FAIL: \(error)"); return 1 }
}

private func scheduleLevelDiagnostic(_ player: AVAudioPlayerNode, _ buffer: AVAudioPCMBuffer) {
    player.scheduleBuffer(buffer)
}
