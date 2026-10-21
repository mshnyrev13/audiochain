import AVFoundation

func testParallelRendering() throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let a = AVAudioUnitEQ(numberOfBands: 0), b = AVAudioUnitEQ(numberOfBands: 0), join = AVAudioUnitEQ(numberOfBands: 0)
    a.globalGain = -6; b.globalGain = -12; join.globalGain = -3
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    for node in [player, a, b, join] as [AVAudioNode] { engine.attach(node) }
    var session = Session.empty
    let source = session.blocks[0], output = session.blocks[1]
    let component = ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple)
    let ba = Block(kind: .effect, name: "A", x: 200, y: 100, component: component)
    let bb = Block(kind: .effect, name: "B", x: 200, y: 250, component: component)
    let bj = Block(kind: .effect, name: "Join", x: 400, y: 100, component: component)
    session.blocks += [ba, bb, bj]; session.wires = []
    try session.connect(from: source.id, to: ba.id); try session.connect(from: source.id, to: bb.id)
    try session.connect(from: ba.id, to: bj.id); try session.connect(from: bb.id, to: bj.id)
    try session.connect(from: bj.id, to: output.id)
    let wires = session.wires
    try mustReject { try session.connect(from: bj.id, to: ba.id) }
    try check(session.wires == wires, "Branch cycle rollback")
    let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
    let route = try restored.orderedChain()
    try check(route.count == 5, "Branch JSON lost nodes")
    try AudioGraphRouting.connect(session: restored, route: route, nodes: [source.id: player, ba.id: a, bb.id: b, bj.id: join, output.id: engine.mainMixerNode], engine: engine, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    input.frameLength = input.frameCapacity
    for i in 0..<48000 {
        let x = Float(0.1 * sin(2 * Double.pi * 1000 * Double(i) / 48000))
        input.floatChannelData![0][i] = x; input.floatChannelData![1][i] = -x
    }
    player.scheduleBuffer(input); try engine.start(); player.play()
    defer { player.stop(); engine.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    let gain = Float((pow(10, -6.0/20) + pow(10, -12.0/20)) * pow(10, -3.0/20))
    var maxError: Float = 0
    for block in 0..<40 {
        try check(try engine.renderOffline(512, to: buffer) == .success, "Branch rendering failed")
        for c in 0..<2 { for i in 0..<512 {
            maxError = max(maxError, abs(buffer.floatChannelData![c][i] - input.floatChannelData![c][block * 512 + i] * gain))
        } }
    }
    try check(maxError < 0.00001, "Fan-out / sum / shared input changed sample timeline: \(maxError)")
    print("PASS: actual stereo fan-out → EQ -6/-12 dB → common EQ -3 dB → output; sample error=\(maxError)")
}

func testMonitoringAndCatalog() throws {
    var monitor = ResourceMonitor()
    _ = monitor.sample()
    var snapshot = monitor.sample()
    let deadline = Date().addingTimeInterval(2)
    while snapshot.cpu == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        snapshot = monitor.sample()
    }
    try check(snapshot.cpu != nil && snapshot.cpu! >= 0 && snapshot.cpu! <= 100, "System CPU unavailable/out of range")
    try check(snapshot.memoryUsed != nil && snapshot.memoryTotal > 0 && snapshot.memoryUsed! <= snapshot.memoryTotal, "System RAM invalid")
    try check(snapshot.appMemory != nil && snapshot.appMemory! > 0 && snapshot.appCPU != nil, "App metrics invalid")
    let catalog = PluginCatalog.scan()
    try check(catalog.contains { $0.component.type == kAudioUnitType_Output }, "Catalog filters out output AU")
    try check(catalog.contains { $0.component.isGenerator }, "Catalog filters out generators/instruments")
    if FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/Components/ToneGenerator.component") {
        try check(catalog.contains { $0.name.contains("ToneGenerator") && $0.component.type == kAudioUnitType_Generator && $0.unavailable == nil }, "Installed ToneGenerator not visible/registered")
    }
    print("PASS: live Mac/app CPU/RAM; all AU types; catalog size=\(catalog.count)")
}

func runGeneratorTest() throws {
    guard let plugin = PluginCatalog.scan().first(where: { $0.name.contains("ToneGenerator") }) else { throw AudioFailure("ToneGenerator not found") }
    let result = InstantiationResult()
    AVAudioUnit.instantiate(with: plugin.component.description, options: PluginHost.options(plugin.component.description)) { result.finish($0, $1) }
    let deadline = Date().addingTimeInterval(20)
    while !result.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard let unit = result.snapshot().1 else { throw result.snapshot().2 ?? AudioFailure("Generator failed to load") }
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try PluginHost.configureForRendering(unit, format: format)
    engine.attach(unit)
    let gate = AVAudioMixerNode(); engine.attach(gate)
    engine.connect(unit, to: gate, format: unit.auAudioUnit.outputBusses[0].format)
    var session = Session.empty
    let generator = Block(kind: .effect, name: plugin.name, x: 200, y: 100, component: plugin.component)
    session.blocks.append(generator); session.wires = []
    try session.connect(from: generator.id, to: session.blocks[1].id)
    try mustReject { try session.connect(from: session.blocks[0].id, to: generator.id) }
    try AudioGraphRouting.connect(session: session, route: session.orderedChain(), nodes: [generator.id: gate, session.blocks[1].id: engine.mainMixerNode], engine: engine, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    for parameter in unit.auAudioUnit.parameterTree?.allParameters ?? [] {
        print("GEN PARAM: \(parameter.displayName) = \(parameter.value), \(parameter.minValue)...\(parameter.maxValue)")
    }
    try engine.start(); defer { engine.stop() }
    guard let sine = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.displayName == "Sine" }) else { throw AudioFailure("ToneGenerator Sine parameter missing") }
    sine.value = sine.minValue + (sine.maxValue - sine.minValue) * 0.75 // Test excitation in the bridge parameter range, not a dB calibration.
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var peak: Float = 0
    for _ in 0..<40 {
        try check(try engine.renderOffline(512, to: output) == .success, "Generator offline render failed")
        for i in 0..<512 { peak = max(peak, abs(output.floatChannelData![0][i])) }
    }
    try check(peak > 0.001 && peak.isFinite, "ToneGenerator produced no finite signal")
    print("PASS: ToneGenerator without audio input → output; peak=\(peak), latency=\(unit.auAudioUnit.latency * 1000) ms")
}
