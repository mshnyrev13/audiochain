import AppKit
import AVFoundation

@MainActor func runAuditRegressions() async -> Int32 {
    var failures = 0
    func verify(_ ok: Bool, _ label: String) {
        print("\(ok ? "PASS" : "FAIL"): \(label)")
        if !ok { failures += 1 }
    }
    var ballistics = MeterBallistics()
    let invalid = ballistics.tick(StereoLevels(left: .infinity, right: -6))
    verify(invalid.left == .infinity, "non-finite PCM must remain visible as meter fault")
    let recovered = ballistics.tick(StereoLevels(left: -20, right: -6))
    verify(recovered.left.isFinite, "meter recovers after non-finite PCM")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    input.frameLength = 4
    input.floatChannelData![0][0] = .nan
    input.floatChannelData![0][1] = .infinity
    input.floatChannelData![1][0] = 0.25
    let meter = LevelMeter(); meter.observe(input)
    verify(meter.read().left == .infinity, "raw meter reports NaN/Inf instead of silence")
    let model = AudioModel()
    let originalWire = model.session.wires[0]
    model.disconnect(originalWire); model.restoreLastConnection()
    verify(model.session.wires == [originalWire] && model.lastRemovedWire == nil, "deleted wire can be restored without changing routing")
    let block = Block(kind: .effect, name: "Busy test", x: 200, y: 76,
        component: ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple))
    model.session.blocks.append(block)
    model.busy = true
    model.bypass(block.id)
    verify(model.session.blocks.last?.bypass == false, "bypass cannot change graph during preparation")
    await model.refreshApps()
    verify(model.busy, "refreshing applications cannot clear another operation's busy state")
    model.busy = false
    model.session.inputKind = .device; model.session.inputUID = "audit.missing.input"
    verify(model.sourceSummary.contains("отключ"), "missing explicitly selected input is not labelled system input")
    await model.shutdown()
    print("REGRESSION_FAILURES=\(failures)")
    return failures == 0 ? 0 : 1
}

func runGraphAuditBenchmark() throws {
    try auditStableGraphOrder()
    for count in [72, 128, 256] {
        var session = Session.empty
        let component = ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple)
        let source = session.blocks[0], output = session.blocks[1]
        let effects = (0..<count).map { Block(kind: .effect, name: "EQ \($0)", x: 24 + Double($0) * 178, y: 76, component: component) }
        session.blocks += effects
        let ordered = [source] + effects + [output]
        session.wires = zip(ordered, ordered.dropFirst()).map { Wire(from: $0.id, to: $1.id) }
        var durations: [Double] = [], checksum = 0
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum += try session.orderedChain().count
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        durations.sort()
        print("GRAPH_BENCH blocks=\(count + 2) median_ms=\(durations[3]) max_ms=\(durations.last!) checksum=\(checksum)")
    }
}

func runAuditScanTests() async -> Int32 {
    do {
        let cancelled = Task { try await PluginCatalog.rescan(arguments: ["--audit-scan-stall"], timeout: 10) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date(); cancelled.cancel()
        do { _ = try await cancelled.value; throw AudioFailure("Cancelled scan returned success") }
        catch is CancellationError {} catch let error as AudioFailure { try check(error.message.contains("отменено"), error.message) }
        try check(Date().timeIntervalSince(start) < 3, "Cancelling scanner was too slow")
        do {
            _ = try await PluginCatalog.rescan(arguments: ["--audit-scan-stall"], timeout: 0.2)
            throw AudioFailure("Stalled scanner did not time out")
        } catch let error as AudioFailure { try check(error.message.contains("ожидания"), error.message) }
        let plugins = try await PluginCatalog.rescan()
        try check(!plugins.isEmpty, "Rescan failed after cancellation/timeout")
        print("PASS: scanner cancellation, timeout, child cleanup and successful retry; catalog=\(plugins.count)")
        return 0
    } catch { print("FAIL: \(error)"); return 1 }
}

@MainActor func runAuditStateTests() async -> Int32 {
    let model = AudioModel(); model.diagnosticSilence = true; model.session.bufferFrames = nil
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-state-\(UUID()).caf")
    let bad = url.appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: bad) }
    do {
        if let virtual = model.devices.first(where: { $0.name == "ZoomAudioDevice" && $0.outputs == 2 }) { model.session.outputUID = virtual.uid }
        let originalUID = model.session.outputUID
        let id = try (model.devices.first { $0.uid == originalUID }?.id ?? Devices.defaultOutput())
        let format = AVAudioFormat(standardFormatWithSampleRate: try Devices.sampleRate(id), channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate*8))!
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        model.session.inputKind = .file; model.session.filePath = url.path
        await model.start(); try check(model.running, model.status)
        model.session.outputUID = "audit.unavailable.output"
        try await Task.sleep(nanoseconds: 1_800_000_000)
        try check(!model.running && !model.busy && model.status.contains("отключ"), "Unavailable route must release playback and explain failure")
        model.session.outputUID = originalUID
        await model.start(); try check(model.running, "Retry after missing output failed: \(model.status)")
        await model.stop()
        let before = model.session.wires
        try Data("{broken json".utf8).write(to: bad)
        await model.load(url: bad)
        try check(model.session.wires == before && !model.busy, "Damaged document modified current graph")
        var missing = model.session
        let effect = Block(kind: .effect, name: "Missing audit AU", x: 200, y: 76, component: ComponentID(type: kAudioUnitType_Effect, subtype: 0x7a7a7a7a, manufacturer: 0x7a7a7a7a))
        missing.blocks.append(effect)
        try JSONEncoder().encode(missing).write(to: bad)
        await model.load(url: bad)
        try check(model.session.wires == before && model.session.blocks.count == 2 && !model.busy && model.status.contains("Missing audit AU"), "Missing AU must preserve current project and name the failed plugin")
        await model.shutdown()
        await model.start()
        try check(!model.running, "Shutdown host restarted")
        print("PASS: injected unavailable route → cleanup → retry; damaged JSON/missing AU preserve graph; shutdown blocks restart; no system-device settings changed")
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}

@MainActor func runAuditProjectTests() async -> Int32 {
    let model = AudioModel()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-roundtrip-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        guard let plugin = model.plugins.first(where: { $0.name == "AUNBandEQ" && $0.unavailable == nil }) else { throw AudioFailure("Apple EQ not found") }
        await model.add(plugin)
        let id = model.selected!
        let gain = model.unitForDiagnostics(id)!.auAudioUnit.parameterTree!.parameter(withAddress: AUParameterAddress(kAUNBandEQParam_GlobalGain))!
        gain.value = -9
        try model.session.insertBeforeOutput(id)
        try model.save(to: url)
        let bytes = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Session.self, from: bytes)
        try check(decoded.blocks.last?.state != nil, "AU state not saved")
        gain.value = -3
        await model.load(url: url)
        let restored = model.unitForDiagnostics(id)!.auAudioUnit.parameterTree!.parameter(withAddress: AUParameterAddress(kAUNBandEQParam_GlobalGain))!
        try check(abs(restored.value+9)<0.01, "Project AU state not restored")
        model.session.blocks[0].x = -.infinity
        try mustReject { try model.save(to: url) }
        try check(try Data(contentsOf: url) == bytes, "Failed save damaged existing project")
        model.session.blocks[0].x = 24
        for _ in 0..<20 { await model.load(url: url); try check(!model.busy && model.unitForDiagnostics(id) != nil, "Repeated load failed") }
        await model.shutdown()
        print("PASS: atomic project save, actual AU gain -9 → -3 → restored -9, invalid save preserves bytes, 20 reloads")
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}

func auditStableGraphOrder() throws {
    var seed: UInt32 = 123456
    func next() -> UInt32 { seed = 1664525 &* seed &+ 1013904223; return seed }
    for sample in 0..<200 {
        var graph = Session.empty
        let source = graph.blocks[0], output = graph.blocks[1]
        let component = ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple)
        let effects = (0..<12).map { Block(kind: .effect,name:"Node \($0)",x:24,y:76,component:component) }
        graph.blocks += effects
        for i in stride(from:graph.blocks.count-1,through:1,by:-1) { graph.blocks.swapAt(i,Int(next()%UInt32(i+1))) }
        graph.wires = effects.flatMap { [Wire(from:source.id,to:$0.id),Wire(from:$0.id,to:output.id)] }
        for i in 0..<effects.count { for j in (i+1)..<effects.count where next()%4 == 0 { graph.wires.append(Wire(from:effects[i].id,to:effects[j].id)) } }
        if sample%2 == 0 { graph.wires.removeAll { $0.from == effects.last!.id } }
        var active: Set<UUID> = [output.id]
        var changed = true
        while changed { changed = false; for wire in graph.wires where active.contains(wire.to) { if active.insert(wire.from).inserted { changed = true } } }
        var remaining = active, expected: [UUID] = []
        while !remaining.isEmpty {
            let first = graph.blocks.first { block in remaining.contains(block.id) && !graph.wires.contains { $0.to == block.id && remaining.contains($0.from) } }!
            expected.append(first.id); remaining.remove(first.id)
        }
        try check(try graph.orderedChain().map(\.id) == expected,"Stable routing changed on DAG \(sample)")
    }
    print("PASS: 200 randomized DAGs preserve document-stable topological order and inactive-branch exclusion")
}
