import Foundation
import AVFoundation

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw AudioFailure(message) }
}
func mustReject(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw AudioFailure("Некорректный граф принят.")
}
func runSelfTests() throws {
    var graph = Session.empty
    try check(try graph.orderedChain().count == 2, "Прямая цепочка")
    let a = Block(kind: .effect, name: "Gain", x: 300, y: 150, component: ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter, manufacturer: kAudioUnitManufacturer_Apple))
    let source = graph.blocks[0].id, output = graph.blocks[1].id
    graph.blocks.append(a); graph.wires = [Wire(from: source, to: a.id), Wire(from: a.id, to: output)]
    try check(try graph.orderedChain().map(\.id) == [source, a.id, output], "Порядок AU")
    let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(graph))
    try check(try restored.orderedChain().map(\.id) == [source, a.id, output], "Сохранение графа")
    var disconnected = graph; disconnected.wires.removeLast()
    try mustReject { _ = try disconnected.orderedChain() }
    var cycle = graph; cycle.wires = [Wire(from: source, to: a.id), Wire(from: a.id, to: source)]
    try mustReject { _ = try cycle.orderedChain() }
    var branch = graph; branch.wires.append(Wire(from: source, to: output))
    try check(try branch.orderedChain().count == 3, "Parallel dry/effect branch")
    try check(!branch.canUseDirectPCM(try branch.orderedChain()), "Parallel summing must not enter direct PCM path")
    var orphan = graph; var extra = a; extra.id = UUID(); orphan.blocks.append(extra)
    try check(try orphan.orderedChain().map(\.id) == [source, a.id, output], "Unconnected plugin must not prevent Start")
    try orphan.insertBeforeOutput(extra.id)
    try check(try orphan.orderedChain().map(\.id) == [source, a.id, extra.id, output], "Explicit plugin insertion")
    let insertedWires = orphan.wires
    try orphan.insertBeforeOutput(extra.id)
    try check(orphan.wires == insertedWires, "Repeated insertion must preserve cables")
    var rewire = graph
    try rewire.connect(from: source, to: output)
    try check(rewire.wires.filter { $0.from == source }.count == 2, "Fan-out preserves previous wires")
    try mustReject { try rewire.connect(from: output, to: source) }
    var manual = graph
    var second = a; second.id = UUID(); second.name = "Second"
    manual.blocks.append(second); manual.wires = []
    try manual.validateEditingGraph()
    let draft = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(manual))
    try draft.validateEditingGraph()
    try mustReject { _ = try draft.orderedChain() }
    // Connect in arbitrary order; canvas position never determines processing order.
    try manual.connect(from: second.id, to: output)
    try manual.connect(from: source, to: a.id)
    try manual.connect(from: a.id, to: second.id)
    try check(try manual.orderedChain().map(\.id) == [source, a.id, second.id, output], "Manual routing order")
    let validWires = manual.wires
    try mustReject { try manual.connect(from: second.id, to: a.id) }
    try check(manual.wires == validWires, "Rejected cycle must preserve existing routing")
    manual.wires.removeAll { $0.from == a.id }
    try manual.validateEditingGraph()
    try mustReject { _ = try manual.orderedChain() }
    var detachedCycle = draft
    detachedCycle.wires = [Wire(from: a.id, to: second.id), Wire(from: second.id, to: a.id)]
    try mustReject { try detachedCycle.validateEditingGraph() }
    print("PASS: manual routing, draft JSON, cable removal, cycle rollback and disconnected-cycle rejection")
    print("PASS: validation, ordering, JSON round trip, disconnected graph, cycles, branching, orphan, rewiring")
    try testParallelRendering()
    try testMonitoringAndCatalog()
    try testLongHorizontalChain()
    try testLevels()
    try testExactOfflineOutput()
    try testDirectOutputGain()
    try testOfflineAU()
    try testPluginInstantiation()
    try testCaptureBuffer()
    try testTapPolicyAndSelection()
    try testBufferPresets()
    print("Devices: \(Devices.all().map { "\($0.name) [in=\($0.inputs), out=\($0.outputs)]" }.joined(separator: "; "))")
}

func testDirectOutputGain() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!, output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
    input.frameLength = 64; output.frameLength = 64
    for c in 0..<2 { for i in 0..<64 { input.floatChannelData![c][i] = Float(i - 32) / 128 * (c == 0 ? 1 : -1) } }
    input.floatChannelData![0][0] = -0.0
    let transport = DirectPCMTransport()
    for gain: Float in [1, 0.5, 0, 1] {
        transport.setGain(gain)
        transport.copy(input: input.audioBufferList, output: output.mutableAudioBufferList, skip: 0, silence: false)
        for c in 0..<2 {
            if gain == 1 { try check(memcmp(input.floatChannelData![c], output.floatChannelData![c], 64 * 4) == 0, "Unity gain changed PCM bits") }
            else { for i in 0..<64 { try check(output.floatChannelData![c][i] == input.floatChannelData![c][i] * gain, "Output fader/mute not applied") } }
        }
    }
    try check(transport.statistics.mismatches == 0 && transport.statistics.invalidBlocks == 0, "Output controls damaged PCM transport")
    var session = Session.empty; session.systemExcludedBundleIDs = ["com.example.browser"]; session.outputMuted = true
    let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
    try check(restored.outputMuted == true && restored.systemExcludedBundleIDs == ["com.example.browser"], "Output/source settings were not saved")
    session.systemExcludedBundleIDs = [""]
    try mustReject { try session.validateEditingGraph() }
    print("PASS: realtime PCM output fader/mute/unity bit-exact restore; source exclusions and output mute persistence")
}

final class InstantiationResult: @unchecked Sendable {
    let lock = NSLock()
    var completed = false
    var unit: AVAudioUnit?
    var error: Error?
    func finish(_ unit: AVAudioUnit?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        self.unit = unit; self.error = error; completed = true
    }
    func snapshot() -> (Bool, AVAudioUnit?, Error?) {
        lock.lock(); defer { lock.unlock() }; return (completed, unit, error)
    }
}
func testPluginInstantiation() throws {
    let result = InstantiationResult()
    let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_NBandEQ, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    AVAudioUnit.instantiate(with: description, options: PluginHost.options(description)) { result.finish($0, $1) }
    let deadline = Date().addingTimeInterval(20)
    while !result.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let (_, unit, error) = result.snapshot()
    guard let unit else { throw error ?? AudioFailure("AU instantiation timeout") }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try unit.auAudioUnit.inputBusses[0].setFormat(format)
    try unit.auAudioUnit.outputBusses[0].setFormat(format)
    let gain = unit.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUNBandEQParam_GlobalGain))
    guard let gain else { throw AudioFailure("AU gain parameter missing") }
    gain.value = -9
    guard let state = unit.auAudioUnit.fullState else { throw AudioFailure("AU fullState missing") }
    let encoded = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    gain.value = 0
    unit.auAudioUnit.fullState = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) as? [String: Any]
    try check(abs(gain.value + 9) < 0.01, "AU state round trip failed")
    unit.auAudioUnit.shouldBypassEffect = true
    try check(unit.auAudioUnit.shouldBypassEffect, "AU bypass failed")
    print("PASS: AU loading with host policy, stereo bus negotiation, parameter/state restore, bypass")
}
func testCaptureBuffer() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6)!
    input.frameLength = 6
    for i in 0..<6 { input.floatChannelData![0][i] = Float(i + 1); input.floatChannelData![1][i] = -Float(i + 1) }
    let queue = AudioQueueBuffer(prefillFrames: 0)
    queue.append(UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList), frames: 6)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
    output.frameLength = 8
    queue.render(UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList), frames: 8)
    for i in 0..<8 {
        try check(output.floatChannelData![0][i] == (i < 6 ? Float(i + 1) : 0), "Capture left channel / underflow")
        try check(output.floatChannelData![1][i] == (i < 6 ? -Float(i + 1) : 0), "Capture right channel / underflow")
    }
    print("PASS: capture buffer stereo order and silence on underflow")
}

func testOfflineAU() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 1); eq.globalGain = -6
    engine.attach(player); engine.attach(eq)
    engine.connect(player, to: eq, format: format); engine.connect(eq, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    input.frameLength = 48_000
    for channel in 0..<2 {
        for i in 0..<48_000 { input.floatChannelData![channel][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
    }
    player.scheduleBuffer(input); try engine.start(); player.play()
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var peak: Float = 0
    for _ in 0..<40 {
        let status = try engine.renderOffline(1024, to: output)
        try check(status == .success, "Offline render failed: \(status)")
        for i in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][i])) }
    }
    engine.stop()
    try check(peak > 0.085 && peak < 0.115, "AU gain not applied: \(peak)")
    print("PASS: actual offline audio → Apple AU EQ (-6 dB) → stereo output; peak=\(peak)")
}

func testExactOfflineOutput() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let player = AVAudioPlayerNode(); engine.attach(player)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    engine.connect(player, to: engine.outputNode, format: format)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    input.frameLength = 4096
    for i in 0..<4096 {
        let value = Float(0.1 * sin(2 * Double.pi * 1000 * Double(i) / 48000) + 0.1 * sin(2 * Double.pi * 18000 * Double(i) / 48000) + 0.1 * sin(2 * Double.pi * 20000 * Double(i) / 48000))
        input.floatChannelData![0][i] = value; input.floatChannelData![1][i] = -value
    }
    let meter = LevelMeter()
    player.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in meter.observe(buffer) }
    player.scheduleBuffer(input)
    try engine.start(); player.play()
    defer { player.stop(); engine.stop(); player.removeTap(onBus: 0) }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    for block in 0..<4 {
        let status = try engine.renderOffline(1024, to: output)
        try check(status == .success && output.frameLength == 1024, "Direct PCM offline render failed")
        for channel in 0..<2 {
            try check(memcmp(input.floatChannelData![channel] + block * 1024, output.floatChannelData![channel], 4096) == 0, "Direct player → output changed PCM bits")
        }
    }
    print("PASS: file/player → output with no mixer or SRC, bit-exact Float32 including 18/20kHz")
}

func testLevels() throws {
    var display = MeterBallistics()
    for tick in 0..<20 {
        let measured = tick % 2 == 0 ? StereoLevels(left: -20, right: -26) : StereoLevels()
        let shown = display.tick(measured)
        try check(shown.left == -20 && shown.right == -26, "Meter decays between tap buffers")
    }
    for _ in 0..<20 { _ = display.tick(StereoLevels(left: -44, right: -50)) }
    let lower = display.tick(StereoLevels(left: -44, right: -50))
    try check(abs(lower.left + 44) < 0.001, "Meter release after lower signal")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 4
    let l: [Float] = [-0.5, 0.1, 0, 0.25], r: [Float] = [0.25, -0.1, 0, 0.2]
    for i in 0..<4 { buffer.floatChannelData![0][i] = l[i]; buffer.floatChannelData![1][i] = r[i] }
    let meter = LevelMeter(); meter.observe(buffer)
    let peak = meter.read()
    try check(abs(peak.left + 6.020599913) < 0.000001 && abs(peak.right + 12.041199827) < 0.000001, "dBFS calibration incorrect")
    let silent = meter.read()
    try check(silent.left == -.infinity && silent.right == -.infinity, "Silence must be -infinity dBFS")
    for i in 0..<4 { try check(buffer.floatChannelData![0][i].bitPattern == l[i].bitPattern && buffer.floatChannelData![1][i].bitPattern == r[i].bitPattern, "Meter modified PCM") }
    try check(StereoLevels.dBFS(1) == 0 && StereoLevels.dBFS(2) > 6, "Full scale and overload calibration")
    let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    let stereo = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 2)!; stereo.frameLength = 2
    let list = UnsafeMutableAudioBufferListPointer(stereo.mutableAudioBufferList)
    let data = list[0].mData!.assumingMemoryBound(to: Float.self)
    data[0] = 0.125; data[1] = 1; data[2] = -0.25; data[3] = 0.5
    meter.observe(stereo)
    let measured = meter.read()
    try check(abs(measured.left + 12.041199827) < 0.000001 && measured.right == 0, "Interleaved meter channels")
    print("PASS: dBFS sample-peak calibration, stereo separation, interleaving, silence, overload and unchanged PCM")
}

func testLongHorizontalChain() throws {
    try MainActor.assumeIsolated {
        let model = AudioModel()
        var graph = Session.empty
        let source = graph.blocks.first { $0.kind == .source }!, output = graph.blocks.first { $0.kind == .output }!
        graph.wires = []; var previous = source.id
        for index in 0..<70 {
            let block = Block(kind: .effect, name: "Effect \(index + 1)", x: 24, y: 100,
                              component: ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_ParametricEQ, manufacturer: kAudioUnitManufacturer_Apple))
            graph.blocks.append(block); graph.wires.append(Wire(from: previous, to: block.id)); previous = block.id
        }
        graph.wires.append(Wire(from: previous, to: output.id))
        model.session = graph; model.arrange()
        let chain = try model.session.orderedChain()
        try check(chain.count == 72 && Set(chain.map(\.y)).count == 1, "Long chain wraps or loses blocks")
        try check(Set(chain.map(\.x)).count == 72 && chain.last!.x > 8000, "Horizontal chain has overlapping blocks or old width limit")
        for index in 1..<chain.count { try check(chain[index].x > chain[index-1].x, "Layout must follow the connected processing order") }
        let loaded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(model.session))
        try check(try loaded.orderedChain().count == 72, "Long chain JSON could not be loaded")
    }
    print("PASS: 70 AU blocks + source/output in one row, no wrapping, no overlap, >8000px and JSON reload")
}
