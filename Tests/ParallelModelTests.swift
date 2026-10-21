import AppKit
import AVFoundation

@MainActor func runParallelModelTest() async -> Int32 {
    let model = AudioModel()
    model.diagnosticSilence = true
    model.session.bufferFrames = nil
    let url = URL(fileURLWithPath: "/private/tmp/audiochain-branch-test-\(getpid()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        await model.rescanPlugins()
        try check(model.plugins.contains { $0.name.contains("ToneGenerator") }, "Fresh AU scan lost ToneGenerator")
        let virtual = model.devices.first { $0.name == "ZoomAudioDevice" && $0.outputs == 2 }
        if let virtual {model.session.outputUID = virtual.uid}
        let outputID = try (virtual?.id ?? Devices.defaultOutput()), rate = try Devices.sampleRate(outputID)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.1 * sin(Float(i) * 2 * .pi * 1000 / Float(rate)) } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
        guard let eq = model.plugins.first(where: { $0.component.subtype == kAudioUnitSubType_NBandEQ && $0.component.manufacturer == kAudioUnitManufacturer_Apple }) else { throw AudioFailure("Apple EQ missing") }
        await model.add(eq); let a = model.selected!
        await model.add(eq); let b = model.selected!
        guard let ua = model.unitForDiagnostics(a), let ub = model.unitForDiagnostics(b) else { throw AudioFailure("EQ load failure") }
        ua.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUNBandEQParam_GlobalGain))?.value = -6
        ub.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUNBandEQParam_GlobalGain))?.value = -12
        let source = model.session.blocks.first { $0.kind == .source }!.id
        let output = model.session.blocks.first { $0.kind == .output }!.id
        model.session.wires = []
        try model.session.connect(from: source, to: a); try model.session.connect(from: source, to: b)
        try model.session.connect(from: a, to: output); try model.session.connect(from: b, to: output)
        model.session.inputKind = .file; model.session.filePath = url.path
        await model.start(); try check(model.running, model.status)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let expected = -20 + 20 * log10(pow(10, -6.0/20) + pow(10, -12.0/20))
        try check(abs(model.outputLevels.left - expected) < 0.2, "Model branch sum: \(model.outputLevels.left), expected \(expected)")
        try check(model.blockLatencies[a] != nil && model.blockLatencies[b] != nil && model.blockLatencies[source] != nil && model.blockLatencies[output] != nil, "Live latency missing")
        try check(model.resources.cpu != nil && model.resources.appMemory != nil, "Live resources missing")
        print("PASS: actual model two-AU branches, output=\(model.outputLevels.left) dBFS, route latency=\(String(describing: model.routeLatency)); \(model.resources.macText)")
        await model.stop(); await model.start()
        try check(model.running, "Branch restart: \(model.status)")
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(abs(model.outputLevels.left - expected) < 0.2, "Branch restart lost AU routing")
        await model.stop()
        guard let tone = model.plugins.first(where: { $0.name.contains("ToneGenerator") }) else { throw AudioFailure("Tone missing") }
        await model.add(tone); let generator = model.selected!
        let unit = model.unitForDiagnostics(generator)!
        try PluginHost.prepareEditor(unit)
        let sine = unit.auAudioUnit.parameterTree!.allParameters.first { $0.displayName == "Sine" }!
        sine.value = sine.minValue + (sine.maxValue - sine.minValue) * 0.5
        model.session.wires = []
        try model.session.connect(from: generator, to: output)
        model.session.inputKind = .system // Unconnected source must not capture/mute system audio.
        await model.start(); try check(model.running, "Generator model start: \(model.status)")
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(model.transportStatistics == nil, "Generator-only route captured unrelated system audio")
        try check(model.outputLevels.left > -60, "Generator model has no output: \(model.outputLevels.left)")
        model.bypass(generator)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        try check(model.outputLevels.left < -60, "Generator bypass not muted")
        model.bypass(generator)
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(model.outputLevels.left > -60, "Generator un-bypass failed")
        print("PASS: actual model ToneGenerator mono→stereo, generator-only route avoids system capture, bypass/un-bypass; output silent")
        await model.shutdown()
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}
