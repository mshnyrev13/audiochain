import AppKit
import AVFoundation

func runSavedChainTests(path: String) throws {
    _ = NSApplication.shared
    let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let chain = try session.orderedChain()
    print("ROUTE: " + chain.map(\.name).joined(separator: " → "))
    print("SOURCE: \(session.inputKind), app=\(session.applicationBundleID), input=\(session.inputUID), output=\(session.outputUID)")
    for block in chain where block.kind == .effect {
        let result = InstantiationResult()
        AVAudioUnit.instantiate(with: block.component!.description, options: PluginHost.options(block.component!.description)) { result.finish($0, $1) }
        let deadline = Date().addingTimeInterval(25)
        while !result.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let unit = result.snapshot().1 else { throw AudioFailure("Instantiation failed: \(block.name)") }
        try PluginHost.prepareEditor(unit)
        if let data = block.state {
            unit.auAudioUnit.fullState = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        }
        print("PLUGIN: \(block.name), bypass=\(block.bypass)")
        for p in unit.auAudioUnit.parameterTree?.allParameters ?? [] {
            print("PARAM \(p.address) \(p.displayName): \(p.value) [\(p.minValue)...\(p.maxValue)]")
        }
        try PluginHost.prepareEditor(unit)
        let active = try renderSavedUnit(unit, bypass: false)
        let bypass = try renderSavedUnit(unit, bypass: true)
        print("DSP \(block.name): active RMS=\(active), bypass RMS=\(bypass), gain=\(20 * log10(active / bypass)) dB")
        if let gain = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.displayName == "Output Level" || $0.displayName == "GAIN: Output L (Locked)" }) {
            gain.value = -12
            let changed = try renderSavedUnit(unit, bypass: false)
            let repeated = try renderSavedUnit(unit, bypass: false)
            let attenuation = 20 * log10(changed / bypass)
            print("CHANGE \(block.name): -12 dB setting → \(attenuation) dB measured; restart=\(20 * log10(repeated / bypass)); parameter=\(gain.value)")
            try check(abs(attenuation + 12) < 0.2 && abs(repeated / changed - 1) < 0.01, "Gain change or restart persistence failed")
        }
        fflush(stdout)
        if block.name == "Ozone 12 Equalizer" { try testOzoneBands(unit) }
    }
}

private func testOzoneBands(_ unit: AVAudioUnit) throws {
    let parameters = unit.auAudioUnit.parameterTree!.allParameters
    func set(_ name: String, _ value: Float) throws {
        guard let p = parameters.first(where: { $0.displayName == name }) else { throw AudioFailure("Missing \(name)") }
        p.value = value
    }
    try set("GAIN: Output L (Locked)", 0)
    try set("EQ: Stereo/Main Frequency 1", 440)
    try set("EQ: Stereo/Main Q 1", 0.707)
    try set("EQ: Stereo/Main Enable 1", 1)
    try set("EQ: Stereo/Main Shape 1", 0)
    try set("EQ: Stereo/Main Gain 1", 0)
    let reference = try renderSavedUnit(unit, bypass: false)
    try set("EQ: Stereo/Main Gain 1", 12)
    let boost = try renderSavedUnit(unit, bypass: false)
    try set("EQ: Stereo/Main Gain 1", -12)
    let cut = try renderSavedUnit(unit, bypass: false)
    print("OZONE BAND: +12 → \(20 * log10(boost / reference)) dB; -12 → \(20 * log10(cut / reference)) dB")
    try check(abs(20 * log10(boost / reference) - 12) < 0.3 && abs(20 * log10(cut / reference) + 12) < 0.3, "Ozone EQ band is not processing")
    fflush(stdout)
}

private func renderSavedUnit(_ unit: AVAudioUnit, bypass: Bool) throws -> Double {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    try PluginHost.configureForRendering(unit, format: format)
    engine.attach(player); engine.attach(unit)
    unit.auAudioUnit.shouldBypassEffect = bypass
    engine.connect(player, to: unit, format: format)
    engine.connect(unit, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
    input.frameLength = input.frameCapacity
    for c in 0..<2 { for i in 0..<Int(input.frameLength) {
        input.floatChannelData![c][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44100)
    } }
    player.scheduleBuffer(input); try engine.start(); player.play()
    defer { engine.stop(); engine.disconnectNodeInput(unit); engine.disconnectNodeOutput(unit); engine.detach(unit) }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var sum = 0.0, count = 0
    for block in 0..<240 {
        let status = try engine.renderOffline(512, to: output)
        try check(status == .success, "Offline render: \(status)")
        if block > 120 { for i in 0..<Int(output.frameLength) {
            let v = Double(output.floatChannelData![0][i]); sum += v * v; count += 1
        } }
    }
    return sqrt(sum / Double(count))
}
