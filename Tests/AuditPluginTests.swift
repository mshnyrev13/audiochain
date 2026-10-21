import AppKit
import SwiftUI
import AVFoundation

func runAuditPlugin(_ name: String) throws {
    _ = NSApplication.shared
    guard let plugin = PluginCatalog.scan().first(where: { $0.name == name && $0.unavailable == nil }) else { throw AudioFailure("Installed/registered AU not found: \(name)") }
    let result = InstantiationResult()
    AVAudioUnit.instantiate(with: plugin.component.description, options: PluginHost.options(plugin.component.description)) { result.finish($0,$1) }
    let deadline = Date().addingTimeInterval(20)
    while !result.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard let unit = result.snapshot().1 else { throw result.snapshot().2 ?? AudioFailure("Instantiation timeout") }
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    try PluginHost.configureForRendering(unit, format: format)
    try PluginHost.prepareEditor(unit)
    if let state = unit.auAudioUnit.fullState {
        let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        unit.auAudioUnit.fullState = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String:Any]
        print("STATE bytes=\(data.count)")
    }
    // Editors and render resources have the same lifetime; do not reinitialize old GUI DSP.
    var editor: ACLegacyEditor?
    if !PluginHost.isV3(plugin.component.description) { editor = try PluginHost.legacyEditor(unit.audioUnit) }
    if let editor {
        MainActor.assumeIsolated {
            let window = NSWindow(contentViewController: LegacyEditorController(editor: editor, audioUnit: unit))
            window.isReleasedWhenClosed = false
            window.display()
            for _ in 0..<5 { window.orderFront(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.02)); window.orderOut(nil) }
            window.close(); window.contentViewController = nil
        }
    }
    let nativeEditor = editor != nil
    engine.attach(unit)
    if !plugin.component.isGenerator { engine.attach(player); engine.connect(player, to: unit, format: format) }
    engine.connect(unit, to: engine.mainMixerNode, format: unit.auAudioUnit.outputBusses[0].format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    input.frameLength = 48000
    let signal = auditSignal(48000, rate: 48000)
    for c in 0..<2 { for i in 0..<48000 { input.floatChannelData![c][i] = signal[i] * (c == 0 ? 1 : -1) } }
    if !plugin.component.isGenerator { player.scheduleBuffer(input) }
    try engine.start(); if !plugin.component.isGenerator { player.play() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var peak: Float = 0, energy = 0.0, first: Int?, maximumIndex = 0, nonfinite = 0
    for block in 0..<93 {
        try check(try engine.renderOffline(512, to: output) == .success, "Offline plugin render failed")
        for i in 0..<512 {
            let value = output.floatChannelData![0][i]
            if !value.isFinite { nonfinite += 1; continue }
            if abs(value)>peak { peak=abs(value); maximumIndex=block*512+i }
            if first == nil && abs(value)>1e-6 { first=block*512+i }
            energy += Double(value)*Double(value)
        }
    }
    engine.stop()
    if name == "Ozone 12 Equalizer" || name == "Pro-L 2" {
        let names = ["GAIN: Output L (Locked)","Output Level"]
        guard let gain = unit.auAudioUnit.parameterTree?.allParameters.first(where: {names.contains($0.displayName)}) else { throw AudioFailure("Output gain parameter unavailable") }
        gain.value = -12
        guard let saved = unit.auAudioUnit.fullState else {throw AudioFailure("Changed AU state unavailable")}
        gain.value = 0; unit.auAudioUnit.fullState = saved
        try check(abs(gain.value+12)<0.01,"AU parameter state did not restore -12 dB")
        player.stop(); player.scheduleBuffer(input); try engine.start(); player.play()
        var changedPeak: Float = 0
        let warmup = Int(ceil(unit.auAudioUnit.latency*48000/512))+4
        for block in 0..<93 {
            try check(try engine.renderOffline(512,to:output) == .success,"Changed gain render")
            if block >= warmup { for i in 0..<512 {changedPeak = max(changedPeak,abs(output.floatChannelData![0][i]))} }
        }
        engine.stop()
        let delta = 20*log10(Double(changedPeak/peak))
        try check(abs(delta+12)<0.2,"Native AU gain does not affect DSP: \(delta) dB")
        print("PARAMETER_STATE name=\(name) restore_value=\(gain.value) measured_gain_delta_db=\(delta)")
    }
    let reported = unit.auAudioUnit.latency*1000
    editor = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    engine.disconnectNodeInput(unit); engine.disconnectNodeOutput(unit); engine.detach(unit)
    if unit.auAudioUnit.renderResourcesAllocated { unit.auAudioUnit.deallocateRenderResources() }
    editor = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try check(nonfinite == 0, "Plugin generated NaN/Inf")
    if !plugin.component.isGenerator { try check(peak > 1e-6, "Plugin produced only silence (license/state/compatibility)") }
    print("PLUGIN_RESULT name=\(name) rate=48000 channels=2 frames=47616 peak=\(peak) rms=\(sqrt(energy/47616)) nonfinite=\(nonfinite) reported_latency_ms=\(reported) signal_first_frame=\(first.map(String.init) ?? "none") signal_peak_frame=\(maximumIndex) native_editor=\(nativeEditor)")
    print("PASS: loaded, state serialized/restored, offline known signals rendered; signal onset includes fixture's initial silence and plugin response, not a calibrated physical latency")
}

@MainActor func runAuditRealtime(seconds: Int) async -> Int32 {
    let model = AudioModel(); model.diagnosticSilence = true; model.session.bufferFrames = nil
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-audit-realtime-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    var probe: OpaquePointer?
    var preview: NSWindow?
    do {
        let usingSaved = CommandLine.arguments.firstIndex(of: "--audit-user-chain").flatMap { CommandLine.arguments.count > $0+1 ? CommandLine.arguments[$0+1] : nil }
        if let path = usingSaved { await model.load(url: URL(fileURLWithPath: path)); try check(!model.status.hasPrefix("Не удалось"), model.status); model.session.bufferFrames = nil }
        if let output = model.devices.first(where: { $0.name == "ZoomAudioDevice" && $0.outputs == 2 }) { model.session.outputUID = output.uid }
        let id = try (model.devices.first { $0.uid == model.session.outputUID }?.id ?? Devices.defaultOutput())
        let rate = try Devices.sampleRate(id), format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        for i in 0..<4096 { buffer.floatChannelData![0][i] = 0.01*sin(Float(i)*2 * .pi * 32/4096); buffer.floatChannelData![1][i] = -buffer.floatChannelData![0][i] }
        for _ in 0..<Int(rate*Double(seconds+60)/4096)+1 { try file.write(from: buffer) }
        model.session.inputKind = .file; model.session.filePath = url.path
        let captureSource = CommandLine.arguments.firstIndex(of:"--audit-capture-source").flatMap {CommandLine.arguments.count>$0+1 ? CommandLine.arguments[$0+1] : nil}
        if let captureSource {model.session.inputKind = .application;model.session.applicationBundleID = captureSource}
        guard let plugin = model.plugins.first(where: { $0.component.subtype == kAudioUnitSubType_NBandEQ && $0.component.manufacturer == kAudioUnitManufacturer_Apple }) else { throw AudioFailure("Apple EQ missing") }
        if usingSaved == nil { for _ in 0..<8 { await model.add(plugin); try model.session.insertBeforeOutput(model.selected!) } }
        if usingSaved != nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(model: model, initialZoom: 0.75))
            window.title = "AudioChain — audit, silent output"; window.orderFront(nil); preview = window
        }
        await model.start(); try check(model.running, model.status)
        let chain = try model.session.orderedChain()
        let last = chain.last(where: { $0.kind == .effect })!
        let unit = model.unitForDiagnostics(last.id)!
        probe = ACRenderProbeCreate(model.outputRenderUnitForDiagnostics ?? unit.audioUnit)
        try check(probe != nil, "No real-time render notify")
        var memory: [UInt64] = [], cpu: [Double] = []
        var peakQueue: UInt64 = 0
        let wallStart = Date()
        for second in 0..<seconds {
            if second % 4 == 0 { model.openEditor(last.id) }
            if second % 4 == 2 { NSApp.windows.filter { $0.title == last.name }.forEach { $0.close() } }
            if second % 7 == 3 { model.bypass(last.id) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try check(model.running && !model.busy, "Realtime model stopped")
            if let stats = model.transportStatistics {
                peakQueue = max(peakQueue,stats.queued)
                try check(stats.underruns==0 && stats.dropped==0,"Clock transport underflow/overflow: \(stats)")
            }
            if let value = model.resources.appMemory { memory.append(value) }
            if let value = model.resources.appCPU { cpu.append(value) }
            if second % 30 == 29 { print("REALTIME_PROGRESS seconds=\(second+1) peakRSS=\(memory.max() ?? 0)"); fflush(stdout) }
        }
        let elapsed = Date().timeIntervalSince(wallStart)
        if CommandLine.arguments.contains("--feature-report") {
            print("FEATURE_HEALTH \(model.telemetry.health.text) underruns=\(model.telemetry.underruns) dropped=\(model.telemetry.dropped)")
            for load in model.telemetry.auLoads {
                print("FEATURE_AU name=\(load.name) bypass=\(load.bypass) mean_ms=\(load.meanMS.map(String.init(describing:)) ?? "n/a") budget_percent=\(load.budgetPercent.map(String.init(describing:)) ?? "n/a") calls=\(load.calls) errors=\(load.errors) invalid=\(load.invalid)")
            }
            let host=NSHostingView(rootView:AULoadPanel(telemetry:model.telemetry))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:538,height:350),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host;window.display();host.layoutSubtreeIfNeeded()
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:URL(fileURLWithPath:auditOutputDirectory(fallback:"Features/2026-10-21")+"/screenshots/live-user-au-load.png"))}
            }
            window.close();window.contentView=nil
        }
        if let view = preview?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let folder = auditOutputDirectory(fallback:CommandLine.arguments.contains("--design-ui") ? "Design/2026-10-21" : "Audit/2026-10-21")
                    try? data.write(to: URL(fileURLWithPath: "\(folder)/screenshots/live-user-chain.png"))
                }
            }
        }
        if let transport = model.transportStatistics {print("REALTIME_CLOCK frames=\(transport.written) queue=\(transport.queued) peak_queue=\(peakQueue) underruns=\(transport.underruns) dropped=\(transport.dropped) \(model.transportStatus)")}
        await model.stop()
        let stats = ACRenderProbeGetStats(probe!)
        ACRenderProbeDestroy(probe!); probe = nil
        try check(stats.frames > 0 && stats.buffers > 0 && stats.errors == 0, "Render callbacks did not run cleanly")
        print("REALTIME seconds=\(seconds) effects=\(chain.filter { $0.kind == .effect }.count) schemaUI=\(preview != nil) elapsed_wall_s=\(elapsed) rate=\(rate) buffer=\(try Devices.bufferFrames(id)) rendered=\(stats.frames) calls=\(stats.buffers) mean_us=\(stats.meanMicroseconds) max_us=\(stats.maxMicroseconds) over_deadline=\(stats.lateBuffers) errors=\(stats.errors) peak_footprint_bytes=\(memory.max() ?? 0) first_footprint=\(memory.first ?? 0) last_footprint=\(memory.last ?? 0) meanCPU=\(cpu.reduce(0,+)/Double(max(cpu.count,1)))")
        for _ in 0..<20 { await model.start(); try check(model.running, model.status); await model.stop() }
        preview?.close(); preview?.contentView = nil
        await model.shutdown()
        print("PASS: realtime AU chain, editor open/close, bypass and 20 restarts; HAL diagnostic mute; no system settings changed")
        return 0
    } catch {
        await model.stop()
        if let probe { ACRenderProbeDestroy(probe) }
        preview?.close(); preview?.contentView = nil
        await model.shutdown(); print("FAIL: \(error)"); return 1
    }
}
