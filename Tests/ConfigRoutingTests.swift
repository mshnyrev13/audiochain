import AVFoundation
import AppKit

// Match ApplicationDelegate lifetime: native plugin views can have display-link callbacks.
// Keep the host alive until process exit instead of destroying live windows on return.
@MainActor private var configRoutingTestModel: AudioModel?

@MainActor func runConfigRoutingTest(path: String) async -> Int32 {
    let model = AudioModel(); configRoutingTestModel = model; model.diagnosticSilence = true
    let url = URL(fileURLWithPath: "/private/tmp/audiochain-config-routing-\(getpid()).caf")
    let originalDefault = try? Devices.defaultOutput()
    var testAggregate: AudioDeviceID = 0
    var alternateOutput: AudioDeviceID?
    defer {
        try? FileManager.default.removeItem(at: url)
        if CommandLine.arguments.contains("--switch-system-output"), let originalDefault { try? Devices.setSystemDefaultOutputForTest(originalDefault) }
        if testAggregate != 0 { AudioHardwareDestroyAggregateDevice(testAggregate) }
    }
    do {
        if CommandLine.arguments.contains("--switch-system-output"), let originalDefault {
            alternateOutput = Devices.all().first(where: { $0.outputs > 0 && $0.id != originalDefault && ($0.name.contains("Динамики MacBook") || $0.name.contains("FIIO")) })?.id
            if alternateOutput == nil {
                let uid = Devices.string(originalDefault, kAudioDevicePropertyDeviceUID)
                let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "AudioChain route diagnostic", kAudioAggregateDeviceUIDKey: "local.AudioChain.diagnostic.\(UUID())", kAudioAggregateDeviceIsPrivateKey: false, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]]]
                try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &testAggregate) == noErr, "Cannot create temporary alternate Core Audio device")
                alternateOutput = testAggregate
                model.refreshDevices()
            }
        }
        await model.load(url: URL(fileURLWithPath: path))
        if CommandLine.arguments.contains("--pin-output"), let originalDefault { model.session.outputUID = Devices.string(originalDefault, kAudioDevicePropertyDeviceUID) }
        print("LOAD: \(model.status)"); fflush(stdout)
        try check(model.session.blocks.contains { $0.name == "ToneGenerator" }, "Config ToneGenerator not loaded")
        let rate = try Devices.sampleRate(Devices.defaultOutput())
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.02 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        if !CommandLine.arguments.contains("--original-source") {
            model.session.inputKind = .file; model.session.filePath = url.path
        }
        if CommandLine.arguments.contains("--capture-startup-test") {
            if !CommandLine.arguments.contains("--keep-application-source") { model.session.inputKind = .system }
            model.diagnosticPreparationDelay = 1_500_000_000
        }
        if CommandLine.arguments.contains("--direct-only") {
            let source = model.session.blocks.first { $0.kind == .source }!, output = model.session.blocks.first { $0.kind == .output }!
            model.session.wires = [Wire(from: source.id, to: output.id)]
        }
        print("SOURCE: \(model.sourceSummary), OUTPUT: \(model.outputSummary)"); fflush(stdout)
        if CommandLine.arguments.contains("--add-another-generator"), let plugin = model.plugins.first(where: { $0.name.contains("ToneGenerator") }) {
            await model.add(plugin)
            print("ADD: \(model.status)"); fflush(stdout)
            try check(model.selected != nil, "Adding ToneGenerator failed")
            model.openEditor(model.selected!)
        }
        let tone = model.session.blocks.first { $0.name == "ToneGenerator" }!
        model.openEditor(tone.id)
        if CommandLine.arguments.contains("--open-all-editors") {
            for block in model.session.blocks where block.kind == .effect { model.openEditor(block.id) }
        }
        print("EDITOR: \(model.status)"); fflush(stdout)
        await model.start()
        print("START: \(model.status)"); fflush(stdout)
        try check(model.running, "Saved graph start: \(model.status)")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        if !CommandLine.arguments.contains("--original-source") { try check(model.outputLevels.left.isFinite, "Saved graph silent") }
        print("PASS: saved graph ToneGenerator + source → Pro-L2 → TonalBalance → Ozone → output; \(model.outputLevels.left) dBFS; output silent")
        if CommandLine.arguments.contains("--capture-startup-test") {
            var peakQueue: UInt64 = 0
            let rate = try Devices.sampleRate(Devices.defaultOutput())
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                try check(model.running, "Capture stopped during startup-queue test")
                guard let stats = model.transportStatistics else { throw AudioFailure("Missing capture statistics") }
                peakQueue = max(peakQueue, stats.queued)
                try check(stats.dropped == 0, "Capture dropped frames")
            }
            let milliseconds = Double(peakQueue) * 1000 / rate
            try check(milliseconds < 200, "Startup queue accumulated excessive latency: \(milliseconds) ms")
            print("PASS: 10s live capture after delayed preparation, max queued=\(peakQueue) frames / \(milliseconds) ms"); fflush(stdout)
        }
        if !CommandLine.arguments.contains("--switch-while-running") { await model.stop() }
        if CommandLine.arguments.contains("--repeat-starts") {
            for index in 1...3 {
                if CommandLine.arguments.contains("--switch-system-output") {
                    guard let originalDefault, let target = alternateOutput else { throw AudioFailure("No alternate output device available; route test cannot pass without a switch") }
                    let requested = index % 2 == 1 ? target : originalDefault
                    try Devices.setSystemDefaultOutputForTest(requested)
                    try await Task.sleep(nanoseconds: 600_000_000)
                    try check(try Devices.defaultOutput() == requested, "macOS did not actually switch output to the requested device")
                    if !CommandLine.arguments.contains("--pin-output") { model.session.outputUID = "" }
                    print("SYSTEM OUTPUT: \(Devices.string(try Devices.defaultOutput(), kAudioObjectPropertyName))"); fflush(stdout)
                }
                if CommandLine.arguments.contains("--switch-output"), let target = model.devices.first(where: { $0.outputs > 0 && $0.name.contains("Динамики MacBook") }) { model.session.outputUID = index % 2 == 1 ? target.uid : "" }
                if CommandLine.arguments.contains("--switch-while-running") {
                    print("AFTER LIVE SWITCH: running=\(model.running), \(model.status)"); fflush(stdout)
                    if CommandLine.arguments.contains("--auto-recover") {
                        let deadline = Date().addingTimeInterval(10)
                        while (model.busy || !model.running) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
                        try check(model.running && !model.busy, "Automatic recovery failed: \(model.status)")
                    } else { await model.stop() }
                }
                if !CommandLine.arguments.contains("--auto-recover") { await model.start() }
                print("RESTART \(index): \(model.status)"); fflush(stdout)
                try check(model.running, "Saved graph restart failed: \(model.status)")
                if model.session.inputKind == .system || model.session.inputKind == .application {
                    let expected: AudioDeviceID?
                    if model.session.outputUID.isEmpty { expected = try Devices.defaultOutput() }
                    else { expected = model.devices.first { $0.uid == model.session.outputUID }?.id }
                    try check(model.currentOutputDeviceForDiagnostics == expected, "Output block lost its device binding")
                }
                if CommandLine.arguments.contains("--open-all-editors") {
                    for block in model.session.blocks where block.kind == .effect {
                        try check(NSApp.windows.contains { $0.title == block.name && $0.isVisible }, "Editor not restored: \(block.name)")
                    }
                }
                try await Task.sleep(nanoseconds: 400_000_000)
                if !CommandLine.arguments.contains("--switch-while-running") { await model.stop() }
            }
        }
        if CommandLine.arguments.contains("--auto-recover"), let originalDefault {
            try Devices.setSystemDefaultOutputForTest(originalDefault)
            await model.stop()
            try await Task.sleep(nanoseconds: 900_000_000)
            try check(!model.running && !model.busy, "Manual Stop was undone by route recovery")
        }
        await model.stop()
        await model.shutdown()
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}

// Diagnostics only: restores the original system route in runConfigRoutingTest.defer.
extension Devices {
    static func setSystemDefaultOutputForTest(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard result == noErr else { throw AudioFailure("Cannot set system output for diagnostic: \(result)") }
    }
}
