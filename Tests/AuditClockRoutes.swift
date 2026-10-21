import AppKit
import AVFoundation

private func scheduleAuditClockLoop(_ player: AVAudioPlayerNode, _ buffer: AVAudioPCMBuffer) {
    player.scheduleBuffer(buffer, at:nil, options:.loops)
}
private func writeAuditClockFile(_ url: URL, _ buffer: AVAudioPCMBuffer) throws {
    let file = try AVAudioFile(forWriting:url,settings:buffer.format.settings)
    try file.write(from:buffer)
}

@MainActor func runAuditToneSource() async -> Int32 {
    do {
        guard let output = Devices.all().first(where: {$0.name == "ZoomAudioDevice" && $0.outputs == 2}) else {throw AudioFailure("No virtual output")}
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        try Devices.select(output.id, for:engine.outputNode)
        let format = AVAudioFormat(standardFormatWithSampleRate:try Devices.sampleRate(output.id),channels:2)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<48000 {buffer.floatChannelData![0][i]=Float(0.01*sin(2 * .pi * 1000*Double(i)/format.sampleRate));buffer.floatChannelData![1][i] = -buffer.floatChannelData![0][i]}
        engine.attach(player);engine.connect(player,to:engine.outputNode,format:format)
        scheduleAuditClockLoop(player,buffer)
        try engine.start();player.play()
        print("READY: synthetic source bundle=\(Bundle.main.bundleIdentifier ?? "") virtual_output=\(output.name) -40dBFS, no physical output");fflush(stdout)
        try await Task.sleep(nanoseconds:240_000_000_000)
        player.stop();engine.stop();return 0
    } catch {print("FAIL: \(error)");return 1}
}

@MainActor func runAuditClockRoutes() async -> Int32 {
    let model = AudioModel(); model.diagnosticSilence = true; model.session.bufferFrames = nil
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-clock-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        guard let output = model.devices.first(where: {$0.name == "ZoomAudioDevice" && $0.outputs == 2}) else { throw AudioFailure("Virtual test output unavailable") }
        model.session.outputUID = output.uid
        guard let eq = model.plugins.first(where: {$0.component.subtype == kAudioUnitSubType_NBandEQ && $0.component.manufacturer == kAudioUnitManufacturer_Apple}) else {throw AudioFailure("EQ missing")}
        await model.add(eq); try model.session.insertBeforeOutput(model.selected!)
        for rate in [44100.0,48000.0,96000.0] {
            let currentURL = url.deletingPathExtension().appendingPathExtension("\(Int(rate)).caf")
            defer {try? FileManager.default.removeItem(at:currentURL)}
            let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(rate*5))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {let value=Float(0.01*sin(2 * .pi * 20000*Double(i)/rate));buffer.floatChannelData![0][i]=value;buffer.floatChannelData![1][i] = -value}
            try writeAuditClockFile(currentURL,buffer)
            let verifyFile = try AVAudioFile(forReading:currentURL)
            let verify = AVAudioPCMBuffer(pcmFormat:verifyFile.processingFormat,frameCapacity:4096)!
            try verifyFile.read(into:verify)
            try check(verifyFile.fileFormat.sampleRate == rate,"Fixture file sample rate changed")
            for i in 0..<4096 {try check(verify.floatChannelData![0][i] == buffer.floatChannelData![0][i],"Fixture file PCM changed before playback")}
            model.session.inputKind = .file; model.session.filePath = currentURL.path
            await model.start(); try check(model.running,model.status)
            try await Task.sleep(nanoseconds:1_100_000_000)
            print("CLOCK_ROUTE_METERS rate=\(rate) input=\(model.inputLevels.left) output=\(model.outputLevels.left)");fflush(stdout)
            try check(model.outputLevels.left.isFinite && model.outputLevels.left > -42 && model.outputLevels.left < -39.9,"HF file route output missing or attenuated: \(model.outputLevels.left)")
            print("CLOCK_ROUTE file_rate=\(rate) output_rate=\(try Devices.sampleRate(output.id)) 20k_output_peak_dbfs=\(model.outputLevels.left) status=\(model.status)")
            await model.stop()
        }
        // Do not trigger a new TCC prompt or touch privacy settings in an audit.
        if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized, output.inputs > 0 {
            model.session.inputKind = .device; model.session.inputUID = output.uid
            await model.start(); try check(model.running,model.status)
            try await Task.sleep(nanoseconds:3_000_000_000)
            guard let stats = model.transportStatistics else {throw AudioFailure("No device clock statistics")}
            print("CLOCK_ROUTE virtual_device frames=\(stats.written) queue=\(stats.queued) underruns=\(stats.underruns) dropped=\(stats.dropped)")
            try check(stats.written>0 && stats.underruns==0 && stats.dropped==0,"Device sink/source clock bridge failed")
            await model.stop()
        } else {print("SKIP: device clock bridge: existing microphone permission or duplex virtual device unavailable")}
        await model.shutdown(); print("PASS: live quality SRC routes, HAL client muted, no system settings changed")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}
