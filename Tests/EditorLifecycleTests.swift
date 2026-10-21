import AppKit
import AVFoundation

@MainActor func runEditorLifecycleProbe() async -> Int32 {
    let model = AudioModel()
    let url = URL(fileURLWithPath: "/private/tmp/audiochain-synthetic-lifecycle-\(getpid()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        guard let plugin = model.plugins.first(where: { $0.name == "Ozone 12 Equalizer" }) else { throw AudioFailure("Ozone EQ not installed") }
        await model.load(url: URL(fileURLWithPath:NSHomeDirectory()+"/Documents/My Chain.audiochain.json"))
        guard let id = model.session.blocks.first(where: { $0.name == plugin.name })?.id, let initialUnit = model.unitForDiagnostics(id) else { throw AudioFailure("Ozone load failed: \(model.status)") }
        var unit = initialUnit
        try model.session.insertBeforeOutput(id)
        model.session.inputKind = .file; model.session.filePath = url.path; model.volume = 1; model.diagnosticSilence = true
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 8)!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 44100) } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        model.openEditor(id)
        guard let _ = NSApp.windows.first(where: { $0.title == plugin.name && $0.isVisible }) else { throw AudioFailure("Editor not opened") }
        func set(_ name: String, _ value: Float) throws {
            guard let p = unit.auAudioUnit.parameterTree!.allParameters.first(where: { $0.displayName == name }) else { throw AudioFailure("Missing \(name)") }; p.value = value
        }
        try set("EQ: Stereo/Main Frequency 1", 440); try set("EQ: Stereo/Main Q 1", 0.707)
        try set("EQ: Stereo/Main Enable 1", 1); try set("EQ: Stereo/Main Shape 1", 0)
        try set("EQ: Stereo/Main Gain 1", 12)
        await model.start()
        try check(model.running, "Start failed: \(model.status)")
        unit = model.unitForDiagnostics(id)!
        guard let renderProbe = ACRenderProbeCreate(unit.audioUnit) else { throw AudioFailure("Render probe unsupported") }
        defer { ACRenderProbeDestroy(renderProbe) }
        try check(NSApp.windows.contains(where: { $0.title == plugin.name && $0.isVisible }), "Editor was not preserved or rebuilt")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let boosted = model.outputLevels
        try check(abs(boosted.left + 8) < 0.2, "Ozone +12 band after Start: \(boosted.left)")
        try set("EQ: Stereo/Main Gain 1", -12)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await Task.sleep(nanoseconds: 500_000_000)
        let cut = model.outputLevels
        try check(abs(model.outputLevels.left + 32) < 0.2, "Ozone live -12 band: \(model.outputLevels.left) dBFS, expected -32")
        await model.stop(); await model.start()
        try check(model.running, "Restart failed: \(model.status)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let restarted = model.outputLevels
        try check(abs(restarted.left + 32) < 0.2, "Ozone state after restart: \(restarted.left)")
        await model.stop()
        try check(ACRenderProbeFrames(renderProbe) > 0, "Native AU render was not called")
        print("PASS: native Ozone editor survives Start/Stop; actual model graph EQ +12 = \(boosted.left) dBFS, live -12 = \(cut.left), restart = \(restarted.left); output silent")
        NSApp.windows.filter { $0.title == plugin.name }.forEach { $0.close() }
        return 0
    } catch { await model.stop(); print("FAIL: \(error)"); return 1 }
}
