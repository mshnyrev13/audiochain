import AppKit
import AVFoundation

func auditSignal(_ count: Int, rate: Double) -> [Float] {
    var rng: UInt32 = 0x12345678
    return (0..<count).map { i in
        switch i * 5 / count {
        case 0: return 0
        case 1: return i == count/5 ? 0.05 : 0
        case 2: return Float(0.04 * sin(2 * .pi * 1000 * Double(i) / rate))
        case 3:
            let t = Double(i - count*3/5) / rate
            let duration = Double(count/5) / rate
            return Float(0.03 * sin(2 * .pi * (50*t + (min(20000,rate*0.45)-50)*t*t/(2*duration))))
        default:
            rng = 1664525 &* rng &+ 1013904223
            return Float(Double(rng) / Double(UInt32.max) * 0.08 - 0.04)
        }
    }
}

func runAuditSignals() throws {
    var worst: Float = 0
    for rate in [44100.0, 48000.0, 96000.0] {
        for frames in [128,256,512,1024,2048] {
            for count in [0,1,8] {
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                engine.attach(player)
                var previous: AVAudioNode = player
                for _ in 0..<count {
                    let eq = AVAudioUnitEQ(numberOfBands: 0); engine.attach(eq)
                    engine.connect(previous, to: eq, format: format); previous = eq
                }
                engine.connect(previous, to: engine.mainMixerNode, format: format)
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(frames))
                let signal = auditSignal(8192, rate: rate)
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
                input.frameLength = 8192
                for i in signal.indices { input.floatChannelData![0][i] = signal[i]; input.floatChannelData![1][i] = -signal[i] }
                player.scheduleBuffer(input); try engine.start(); player.play()
                let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                var times: [Double] = []
                for start in stride(from: 0, to: 8192, by: frames) {
                    let t = DispatchTime.now().uptimeNanoseconds
                    try check(try engine.renderOffline(AVAudioFrameCount(frames), to: output) == .success, "Audit offline render")
                    times.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
                    for c in 0..<2 { for i in 0..<frames {
                        let value = output.floatChannelData![c][i]
                        try check(value.isFinite, "Unexpected NaN/Inf in flat AU route")
                        let expected = signal[start+i] * (c == 0 ? 1 : -1)
                        worst = max(worst, abs(value-expected))
                    } }
                }
                engine.stop(); times.sort()
                print("SIGNAL rate=\(Int(rate)) frames=\(frames) effects=\(count) render_p50_ms=\(times[times.count/2]) max_ms=\(times.last!) deadline_ms=\(Double(frames)/rate*1000)")
            }
        }
    }
    try check(worst < 1e-6, "Silence/impulse/sine/sweep/noise changed: \(worst)")
    print("PASS: 45 stereo format/buffer/effect combinations; silence, impulse, sine, sweep, deterministic noise; max sample error=\(worst)")
    try auditDelayBranch()
    try auditMono()
    try auditUnitySumAndClipping()
    try auditReportedLatencyBranch()
}

private func auditDelayBranch() throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), delay = AVAudioUnitDelay()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    delay.delayTime = 0.005; delay.feedback = 0; delay.wetDryMix = 100; delay.lowPassCutoff = 22050
    engine.attach(player); engine.attach(delay)
    engine.connect(player, to: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0), AVAudioConnectionPoint(node: delay, bus: 0)], fromBus: 0, format: format)
    engine.connect(delay, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    input.frameLength = 8192; input.floatChannelData![0][1024] = 0.01; input.floatChannelData![1][1024] = -0.01
    player.scheduleBuffer(input); try engine.start(); player.play()
    defer { engine.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var peaks: [(Int,Float)] = []
    for block in 0..<16 {
        try check(try engine.renderOffline(512, to: output) == .success, "Delay branch render")
        for i in 0..<512 where abs(output.floatChannelData![0][i]) > 0.001 { peaks.append((block*512+i,output.floatChannelData![0][i])) }
    }
    try check(peaks.contains { $0.0 == 1024 } && peaks.contains { abs($0.0-1264) <= 4 }, "Dry and delayed impulses missing")
    print("DELAY_BRANCH reported_AU_ms=\(delay.auAudioUnit.latency*1000) musical_delay_ms=5 threshold_peaks=\(peaks.prefix(12)); dry/delayed paths are not time aligned; phase combing expected, no implicit compensation added")
}

private func auditMono() throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: mono)
    try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4096)!
    input.frameLength = 4096
    for i in 0..<4096 { input.floatChannelData![0][i] = 0.01 }
    player.scheduleBuffer(input); try engine.start(); player.play(); defer { engine.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 512)!
    try check(try engine.renderOffline(512, to: output) == .success, "Mono render")
    let l = output.floatChannelData![0][256], r = output.floatChannelData![1][256]
    try check(l.isFinite && l == r && l > 0, "Mono/stereo routing invalid")
    print("MONO_TO_STEREO input=0.01 left=\(l) right=\(r) gain_db=\(20*log10(Double(l/0.01)))")
}

@MainActor func runAuditMeterLive() async -> Int32 {
    let model = AudioModel(); model.diagnosticSilence = true; model.session.bufferFrames = nil
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-audit-meter-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let output = model.devices.first { $0.name == "ZoomAudioDevice" && $0.outputs == 2 }
        if let output { model.session.outputUID = output.uid }
        let device = try (output?.id ?? Devices.defaultOutput())
        let rate = try Devices.sampleRate(device), format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate*10))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = 0.01 * sin(Float(i)*2 * .pi * 1000 / Float(rate))
            buffer.floatChannelData![1][i] = -0.005 * sin(Float(i)*2 * .pi * 1000 / Float(rate))
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        model.session.inputKind = .file; model.session.filePath = url.path; model.volume = 0.25
        await model.start(); try check(model.running, model.status)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(model.diagnosticClientGain == 0, "HAL diagnostic mute did not survive start")
        print("DIRECT_FILE_METERS input=\(model.inputLevels.left)/\(model.inputLevels.right) output=\(model.outputLevels.left)/\(model.outputLevels.right); expected output=-52.0412/-58.0618 dBFS; HAL diagnostic mute enabled")
        try check(abs(model.outputLevels.left + 52.0412) < 0.2, "Direct file output meter ignores fader")
        model.volume = 0
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(model.outputLevels.left == -.infinity, "Direct file output meter ignores mute")
        await model.stop()
        // Read the actual HAL client fader using all-zero PCM: no signal is emitted.
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0 } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        model.diagnosticSilence = false; model.volume = 0.25
        try check(model.diagnosticMixerCount == 0, "Stopped volume change inserted a mixer in direct PCM graph")
        await model.start(); try check(model.running, model.status)
        try check(abs((model.diagnosticClientGain ?? -1)-0.25)<0.0001, "HAL client fader ignored startup volume")
        model.session.outputMuted = true; model.applyOutputLevel()
        try check(model.diagnosticClientGain == 0, "HAL client mute ignored")
        model.session.outputMuted = false; model.volume = 1
        try check(model.diagnosticClientGain == 1, "HAL client unity not restored")
        await model.shutdown()
        print("PASS: actual direct-file model meters include fader and mute; device settings preserved")
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}

func auditUnitySumAndClipping() throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), a = AVAudioUnitEQ(numberOfBands: 0), b = AVAudioUnitEQ(numberOfBands: 0)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    for node in [player,a,b] as [AVAudioNode] { engine.attach(node) }
    var session = Session.empty
    let source = session.blocks[0], output = session.blocks[1]
    let component = ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple)
    let ba = Block(kind: .effect, name: "A", x: 200, y: 70, component: component), bb = Block(kind: .effect, name: "B", x: 200, y: 200, component: component)
    session.blocks += [ba,bb]
    session.wires = [Wire(from: source.id,to: ba.id), Wire(from: source.id,to: bb.id), Wire(from: ba.id,to: output.id), Wire(from: bb.id,to: output.id)]
    try AudioGraphRouting.connect(session: session, route: session.orderedChain(), nodes: [source.id:player,ba.id:a,bb.id:b,output.id:engine.mainMixerNode], engine: engine, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    input.frameLength = 4096
    for i in 0..<4096 { input.floatChannelData![0][i] = 0.75; input.floatChannelData![1][i] = -0.75 }
    player.scheduleBuffer(input); try engine.start(); player.play(); defer {engine.stop()}
    let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    try check(try engine.renderOffline(512, to: result) == .success, "Sum rendering")
    let meter = LevelMeter(); meter.observe(result); let levels = meter.read()
    try check(abs(result.floatChannelData![0][256] - 1.5) < 1e-6 && abs(levels.left - 3.521825) < 1e-5, "Unexpected normalization/clipping or meter calibration")
    print("PASS: unity parallel sum 0.75+0.75=1.5, meter +3.5218 dBFS; no implicit normalization; offline only")
}

func printAuditDeviceSnapshot() throws {
    let devices = Devices.all().map { device -> [String:Any] in
        ["uid": device.uid, "name": device.name, "inputs": device.inputs, "outputs": device.outputs,
         "rate": (try? Devices.sampleRate(device.id)) as Any? ?? NSNull(), "buffer": (try? Devices.bufferFrames(device.id)) as Any? ?? NSNull()]
    }
    let data: [String:Any] = ["defaultOutput":Devices.string(try Devices.defaultOutput(),kAudioDevicePropertyDeviceUID),"defaultInput":Devices.string(try Devices.defaultInput(),kAudioDevicePropertyDeviceUID),"devices":devices]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]))
}

func auditReportedLatencyBranch() throws {
    let description = AudioComponentDescription(componentType:kAudioUnitType_Effect,componentSubType:kAudioUnitSubType_DynamicsProcessor,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
    let dynamics = AVAudioUnitEffect(audioComponentDescription:description)
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
    engine.attach(player); engine.attach(dynamics)
    var session = Session.empty
    let source = session.blocks[0], output = session.blocks[1]
    let effect = Block(kind:.effect,name:"Lookahead",x:200,y:76,component:ComponentID(type:description.componentType,subtype:description.componentSubType,manufacturer:description.componentManufacturer))
    session.blocks.append(effect)
    session.wires = [Wire(from:source.id,to:output.id),Wire(from:source.id,to:effect.id),Wire(from:effect.id,to:output.id)]
    try AudioGraphRouting.connect(session:session,route:session.orderedChain(),nodes:[source.id:player,effect.id:dynamics,output.id:engine.mainMixerNode],engine:engine,format:format)
    try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:512)
    let input = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
    input.frameLength = 4096; input.floatChannelData![0][1024] = 0.01; input.floatChannelData![1][1024] = -0.01
    player.scheduleBuffer(input); try engine.start(); player.play(); defer {engine.stop()}
    let outputBuffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:512)!
    var peaks: [(Int,Float)] = []
    for block in 0..<8 {
        try check(try engine.renderOffline(512,to:outputBuffer) == .success,"Reported latency branch render")
        for i in 0..<512 where abs(outputBuffer.floatChannelData![0][i])>0.001 {peaks.append((block*512+i,outputBuffer.floatChannelData![0][i]))}
    }
    try check(!peaks.isEmpty,"Lookahead branch produced no impulses")
    print("REPORTED_LATENCY_BRANCH AU_ms=\(dynamics.auAudioUnit.latency*1000) impulses=\(peaks.prefix(12)); dry_impulse_at_1024=\(peaks.contains {$0.0 == 1024}); input impulse=0.01 at frame1024; no host delay compensation inserted")
}

func auditSampleRateConversion() throws {
    let highQuality = CommandLine.arguments.contains("--audit-src-high-quality")
    var issues: [String] = []
    for (sourceRate,targetRate) in [(44100.0,48000.0),(48000.0,44100.0),(48000.0,96000.0),(96000.0,48000.0)] {
        for frequency in [1000.0,18000.0,20000.0] {
            if highQuality {
                let (gain,rms) = try auditExplicitSRC(sourceRate:sourceRate,targetRate:targetRate,frequency:frequency)
                if abs(gain)>=0.5 {issues.append("\(sourceRate)→\(targetRate)/\(frequency):\(gain)")}
                print("SRC_EXPLICIT_PROTOTYPE source=\(sourceRate) target=\(targetRate) tone_hz=\(frequency) measured_gain_db=\(gain) rms_gain_db=\(rms) quality=127; not enabled in application")
                continue
            }
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let converter: AVAudioNode
            if CommandLine.arguments.contains("--audit-src-native-mastering") {
                let result = InstantiationResult()
                AVAudioUnit.instantiate(with: QualitySRC.description, options: [.loadInProcess]) {result.finish($0,$1)}
                let deadline = Date().addingTimeInterval(10)
                while !result.snapshot().0 && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
                guard let unit = result.snapshot().1 else {throw AudioFailure("Native SRC instantiate failed")}
                try QualitySRC.configure(unit)
                converter = unit
            } else {converter = AVAudioMixerNode()}
            let src = AVAudioFormat(standardFormatWithSampleRate:sourceRate,channels:2)!, dst = AVAudioFormat(standardFormatWithSampleRate:targetRate,channels:2)!
            engine.attach(player); engine.attach(converter)
            engine.connect(player,to:converter,format:src); engine.connect(converter,to:engine.mainMixerNode,format:dst)
            try engine.enableManualRenderingMode(.offline,format:dst,maximumFrameCount:512)
            let input = AVAudioPCMBuffer(pcmFormat:src,frameCapacity:AVAudioFrameCount(sourceRate*2))!
            input.frameLength = input.frameCapacity
            for i in 0..<Int(input.frameLength) {let x=Float(0.01*sin(2 * .pi * frequency*Double(i)/sourceRate));input.floatChannelData![0][i]=x;input.floatChannelData![1][i] = -x}
            player.scheduleBuffer(input)
            engine.prepare()
            let defaultQuality = converter.auAudioUnit.renderQuality
            if highQuality { converter.auAudioUnit.renderQuality = Int(kRenderQuality_Max) }
            try engine.start();player.play()
            let output=AVAudioPCMBuffer(pcmFormat:dst,frameCapacity:512)!
            var sine=0.0,cosine=0.0,energy=0.0,n=0
            for start in stride(from:0,to:Int(targetRate*2),by:512) {
                try check(try engine.renderOffline(512,to:output) == .success,"SRC render")
                for i in 0..<512 where start+i >= Int(targetRate*0.5) && start+i < Int(targetRate*1.5) {
                    let x=Double(output.floatChannelData![0][i]), phase=2 * .pi * frequency*Double(start+i)/targetRate
                    try check(x.isFinite,"SRC generated non-finite PCM")
                    sine+=x*sin(phase);cosine+=x*cos(phase);energy+=x*x;n+=1
                }
            }
            engine.stop()
            let amplitude=2*sqrt(sine*sine+cosine*cosine)/Double(n), gain=20*log10(amplitude/0.01)
            let rmsGain = 20*log10(sqrt(energy/Double(n))*sqrt(2)/0.01)
            if abs(gain)>=(CommandLine.arguments.contains("--audit-src-native-mastering") ? 0.001 : 0.5) { issues.append("\(sourceRate)→\(targetRate)/\(frequency):\(gain)") }
            try check(gain.isFinite,"SRC returned no finite signal")
            print("SRC source=\(sourceRate) target=\(targetRate) tone_hz=\(frequency) measured_gain_db=\(gain) rms_gain_db=\(rmsGain) quality_default=\(defaultQuality) quality_used=\(converter.auAudioUnit.renderQuality); AU conversion path only")
        }
    }
    print("SRC_ANALYSIS high_quality_prototype=\(highQuality) passband_issues=\(issues.count)")
    if CommandLine.arguments.contains("--audit-src-strict") { try check(issues.isEmpty,"SRC passband loss: \(issues)") }
}

private func auditExplicitSRC(sourceRate: Double, targetRate: Double, frequency: Double) throws -> (Double,Double) {
    let source = AVAudioFormat(standardFormatWithSampleRate:sourceRate,channels:2)!, target = AVAudioFormat(standardFormatWithSampleRate:targetRate,channels:2)!
    let converter = AVAudioConverter(from:source,to:target)!
    converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
    let input = AVAudioPCMBuffer(pcmFormat:source,frameCapacity:AVAudioFrameCount(sourceRate*2))!
    input.frameLength = input.frameCapacity
    for i in 0..<Int(input.frameLength) {let value=Float(0.01*sin(2 * .pi * frequency*Double(i)/sourceRate));input.floatChannelData![0][i]=value;input.floatChannelData![1][i] = -value}
    let output = AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(targetRate*2+2048))!
    var position=0
    var failure:NSError?
    // Offline prototype only: production would need preallocated input/output storage.
    let status = converter.convert(to:output,error:&failure) { requested, state in
        let frames=min(Int(requested),Int(input.frameLength)-position)
        guard frames>0 else {state.pointee = .endOfStream;return nil}
        let chunk=AVAudioPCMBuffer(pcmFormat:source,frameCapacity:AVAudioFrameCount(frames))!
        chunk.frameLength=AVAudioFrameCount(frames)
        for c in 0..<2 {memcpy(chunk.floatChannelData![c],input.floatChannelData![c]+position,frames*4)}
        position+=frames;state.pointee = .haveData;return chunk
    }
    if let failure {throw failure}
    try check(status != .error && output.frameLength >= AVAudioFrameCount(targetRate*1.5),"Explicit SRC produced insufficient output")
    var sine=0.0,cosine=0.0,energy=0.0,n=0
    for i in Int(targetRate*0.5)..<Int(targetRate*1.5) {
        let value=Double(output.floatChannelData![0][i]), phase=2 * .pi * frequency*Double(i)/targetRate
        sine+=value*sin(phase);cosine+=value*cos(phase);energy+=value*value;n+=1
    }
    return (20*log10(2*sqrt(sine*sine+cosine*cosine)/Double(n)/0.01),20*log10(sqrt(2*energy/Double(n))/0.01))
}
