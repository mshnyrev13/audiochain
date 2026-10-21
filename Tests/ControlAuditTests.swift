import AppKit
import AVFoundation

private func referenceDirect(_ session: Session, _ route: [Block]) -> Bool {
    let ids = Set(route.map(\.id))
    return route.contains {$0.kind == .source} && !route.contains {$0.kind == .effect && (!$0.bypass || $0.component?.isGenerator == true)} && route.allSatisfy {block in
        session.wires.filter {$0.from == block.id && ids.contains($0.to)}.count <= 1 && session.wires.filter {$0.to == block.id && ids.contains($0.from)}.count <= 1
    }
}
private func referenceLatency(_ session: Session, _ route: [Block], _ values:[UUID:Double]) -> Double? {
    var longest: [UUID:Double] = [:]
    for block in route {
        guard let own = values[block.id] else {return nil}
        longest[block.id] = (session.wires.filter {$0.to == block.id}.compactMap {longest[$0.from]}.max() ?? 0) + own
    }
    return route.last.flatMap {longest[$0.id]}
}
private func fixture(_ count:Int) -> (Session,[Block]) {
    var session = Session.empty
    let component = ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
    let nodes = (0..<count).map {Block(kind:.effect,name:"EQ \($0)",x:24+Double($0)*172,y:76,component:component,bypass:true)}
    let route = [session.blocks[0]]+nodes+[session.blocks[1]]
    session.blocks += nodes
    session.wires = zip(route,route.dropFirst()).map {Wire(from:$0.id,to:$1.id)}
    return (session,route)
}
func runControlGraphAudit() throws {
    // Deterministic DAGs: sequential paths, fan-in/out, disconnected effects,
    // bypass and generator roles; preserve exact stable accumulation order.
    var seed: UInt64 = 30421
    func next(_ n:Int) -> Int {seed = seed &* 6364136223846793005 &+ 1;return Int((seed>>32)%UInt64(n))}
    for iteration in 0..<240 {
        var (session,route) = fixture(4+next(28))
        for _ in 0..<next(20) {
            let a=next(route.count-1), b=next(route.count-1)+1
            if a<b {
                let wire=Wire(from:route[a].id,to:route[b].id)
                if !session.wires.contains(wire) {session.wires.append(wire)}
            }
        }
        if iteration%3 == 0 {session.blocks[2].bypass = false}
        if iteration%7 == 0 {session.blocks[2].component?.type = kAudioUnitType_Generator;session.wires.removeAll {$0.to == session.blocks[2].id}}
        route = try session.orderedChain()
        let values=Dictionary(uniqueKeysWithValues:route.map {($0.id,Double(next(1000))/10)})
        try check(session.canUseDirectPCM(route) == referenceDirect(session,route),"Direct eligibility changed on DAG \(iteration)")
        try check(RouteLatency.total(route:route,wires:session.wires,values:values) == referenceLatency(session,route,values),"Longest latency changed on DAG \(iteration)")
        if let first=route.first {
            var missing=values;missing[first.id]=nil
            try check(RouteLatency.total(route:route,wires:session.wires,values:missing) == nil,"Missing latency shown as known")
        }
    }
    for count in [128,512,2048] {
        let (session,route)=fixture(count)
        let values=Dictionary(uniqueKeysWithValues:route.map {($0.id,1.0)})
        for mode in ["direct","latency"] {
            var oldTimes:[Double]=[],newTimes:[Double]=[],oldChecksum=0.0,newChecksum=0.0
            for _ in 0..<7 {
                var t=DispatchTime.now().uptimeNanoseconds
                oldChecksum += mode == "direct" ? (referenceDirect(session,route) ? 1:0) : (referenceLatency(session,route,values) ?? -1)
                oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
                t=DispatchTime.now().uptimeNanoseconds
                newChecksum += mode == "direct" ? (session.canUseDirectPCM(route) ? 1:0) : (RouteLatency.total(route:route,wires:session.wires,values:values) ?? -1)
                newTimes.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
            }
            try check(oldChecksum==newChecksum,"Benchmark checksum mismatch")
            print("CONTROL_BENCH mode=\(mode) blocks=\(route.count) old_median_ms=\(oldTimes.sorted()[3]) new_median_ms=\(newTimes.sorted()[3]) checksum=\(newChecksum)")
        }
    }
    print("PASS: 240 deterministic DAGs preserve direct eligibility and longest route latency; missing values stay unknown")
}

@MainActor func runDevicePollAudit() throws {
    let devices=Devices.all().filter {$0.outputs>0}
    for device in devices {
        let binding=try AudioModel.DeviceBinding(device.id,scope:kAudioObjectPropertyScopeOutput)
        let oldID=Devices.all().first {$0.uid==device.uid && $0.outputs>0}?.id
        try check(oldID == binding.id && (try? AudioModel.DeviceBinding(binding.id,scope:kAudioObjectPropertyScopeOutput)) == binding,"Pinned binding does not match enumerated output")
    }
    guard let device=devices.first else {throw AudioFailure("No outputs")}
    let binding=try AudioModel.DeviceBinding(device.id,scope:kAudioObjectPropertyScopeOutput)
    var oldTimes:[Double]=[],newTimes:[Double]=[]
    for _ in 0..<7 {
        var t=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<50 {
            let id=Devices.all().first {$0.uid==device.uid && $0.outputs>0}?.id
            try check(id.flatMap {try? AudioModel.DeviceBinding($0,scope:kAudioObjectPropertyScopeOutput)} == binding,"Old binding changed during benchmark")
        }
        oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6/50)
        t=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<50 {try check((try? AudioModel.DeviceBinding(binding.id,scope:kAudioObjectPropertyScopeOutput)) == binding,"Pinned binding changed during benchmark")}
        newTimes.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6/50)
    }
    try check((try? AudioModel.DeviceBinding(0,scope:kAudioObjectPropertyScopeOutput)) == nil,"Invalid HAL object accepted")
    print("DEVICE_POLL outputs=\(devices.count) old_median_ms=\(oldTimes.sorted()[3]) new_median_ms=\(newTimes.sorted()[3]); reads only, no rate/buffer/default writes")
    print("PASS: all available outputs preserve binding identity; invalid ID rejected")
}

@MainActor func runPinnedRouteRecoveryAudit() async -> Int32 {
    let model=AudioModel();model.diagnosticSilence=true;model.session.bufferFrames=nil
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-route-\(UUID()).caf")
    defer {try? FileManager.default.removeItem(at:url)}
    do {
        guard let device=model.devices.first(where:{$0.name=="ZoomAudioDevice" && $0.outputs==2}) else {throw AudioFailure("No virtual output")}
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for _ in 0..<12 {try file.write(from:buffer)}
        model.session.inputKind = .file;model.session.filePath=url.path;model.session.outputUID=device.uid
        await model.start();try check(model.running,model.status)
        for _ in 0..<50 {model.diagnosticCheckOutputRoute()}
        try check(model.running && !model.busy,"Unchanged pinned route restarted")
        // Inject a missing selection in memory; do not unplug or mutate hardware.
        model.session.outputUID="audit.missing.output"
        model.diagnosticCheckOutputRoute()
        try await Task.sleep(nanoseconds:1_000_000_000)
        try check(!model.running,"Missing pinned route was not stopped")
        model.session.outputUID=device.uid
        await model.start();try check(model.running,model.status)
        await model.stop();await model.shutdown()
        print("PASS: actual pinned virtual route stays running for 50 polls; injected missing selection stops, retry restores; muted output")
        return 0
    } catch {await model.stop();await model.shutdown();print("FAIL: \(error)");return 1}
}
