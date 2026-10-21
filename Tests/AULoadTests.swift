import AppKit
import SwiftUI
import AVFoundation

@MainActor func runAULoadTests() async -> Int32 {
    let model=AudioModel();model.diagnosticSilence=true;model.session.bufferFrames=nil
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-load-\(UUID()).caf")
    defer {try? FileManager.default.removeItem(at:url)}
    var external:OpaquePointer?
    do {
        guard let device=model.devices.first(where:{$0.name=="ZoomAudioDevice" && $0.outputs==2}),
            let plugin=model.plugins.first(where:{$0.component.subtype==kAudioUnitSubType_NBandEQ && $0.component.manufacturer==kAudioUnitManufacturer_Apple}) else {throw AudioFailure("Virtual route/Apple EQ missing")}
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for i in 0..<48000 {let x=Float(0.01*sin(2 * .pi * 1000*Double(i)/48000));buffer.floatChannelData![0][i]=x;buffer.floatChannelData![1][i] = -x}
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        for _ in 0..<15 {try file.write(from:buffer)}
        model.session.inputKind = .file;model.session.filePath=url.path;model.session.outputUID=device.uid
        for _ in 0..<4 {await model.add(plugin);model.insertBeforeOutput(model.selected!)}
        await model.start();try check(model.running,model.status)
        let last=model.session.blocks.last {$0.kind == .effect}!
        guard let summaryProbe=AUProbe(model.unitForDiagnostics(last.id)!) else {throw AudioFailure("Summary probe failed")}
        external=ACRenderProbeCreate(model.unitForDiagnostics(last.id)!.audioUnit)
        try check(external != nil,"External diagnostic probe failed")
        try await Task.sleep(nanoseconds:3_000_000_000)
        model.samplePlaybackTelemetry()
        try check(model.telemetry.auLoads.count==4,"AU load rows missing")
        for load in model.telemetry.auLoads {
            try check(load.calls>0 && load.meanMS != nil && load.budgetPercent != nil && load.invalid==0 && load.errors==0,"AU probe failed: \(load)")
            print("AU_LOAD name=\(load.name) mean_ms=\(load.meanMS!) peak_ms=\(load.peakMS!) budget_percent=\(load.budgetPercent!) calls=\(load.calls)")
        }
        try check(abs(model.inputLevels.left+40)<0.2 && abs(model.outputLevels.left+40)<0.2,"Profiling changed unity level")
        try check(model.telemetry.health.text=="Сигнал проходит","Live signal diagnosis failed: \(model.telemetry.health)")
        let host=NSHostingView(rootView:AULoadPanel(telemetry:model.telemetry))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:538,height:310),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.display();host.layoutSubtreeIfNeeded()
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:URL(fileURLWithPath:auditOutputDirectory(fallback:"Features/2026-10-21")+"/screenshots/au-load-live.png"))}
        }
        window.close();window.contentView=nil
        model.volume=0
        try await Task.sleep(nanoseconds:600_000_000);model.samplePlaybackTelemetry()
        try check(model.telemetry.health.text=="Выход заглушён","Live zero fader diagnosis failed")
        await model.stop()
        let stoppedLoads=model.telemetry.auLoads
        try check(stoppedLoads.count==4 && stoppedLoads.allSatisfy {$0.calls>0 && ($0.meanMS ?? 0)>0 && $0.budgetPercent != nil},"Stop erased the last AU measurements")
        let summary=summaryProbe.sample(last,cumulative:true)
        let repeated=summaryProbe.sample(last,cumulative:true)
        try check(summary.calls>0 && summary.meanMS != nil && summary==repeated,"Completed-run summary depends on new callbacks")
        model.samplePlaybackTelemetry()
        try check(model.telemetry.auLoads==stoppedLoads,"Idle poll erased the last AU measurements")
        let stoppedHost=NSHostingView(rootView:AULoadPanel(telemetry:model.telemetry))
        let stoppedWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:538,height:350),styleMask:[.titled],backing:.buffered,defer:false)
        stoppedWindow.isReleasedWhenClosed=false;stoppedWindow.contentView=stoppedHost;stoppedWindow.display();stoppedHost.layoutSubtreeIfNeeded()
        if let bitmap=stoppedHost.bitmapImageRepForCachingDisplay(in:stoppedHost.bounds) {
            stoppedHost.cacheDisplay(in:stoppedHost.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:URL(fileURLWithPath:auditOutputDirectory(fallback:"Features/2026-10-21")+"/screenshots/au-load-stopped.png"))}
        }
        stoppedWindow.close();stoppedWindow.contentView=nil
        await model.stop()
        try check(model.telemetry.auLoads==stoppedLoads,"Repeated Stop erased completed measurements")
        if let external {let stats=ACRenderProbeGetStats(external);try check(stats.buffers>0 && stats.invalidMeasurements==0,"Coexisting observer invalidated measurements");ACRenderProbeDestroy(external)}
        external=nil
        model.volume=1
        await model.start();try check(model.running,model.status)
        try check(model.telemetry.auLoads.isEmpty && model.telemetry.underruns==0 && model.telemetry.playbackRunning,"New run did not reset old measurements")
        await model.stop()
        await model.shutdown()
        print("PASS: four real AU probes, duplicate external observer, unity levels unchanged, live healthy/mute diagnosis, stopped teardown")
        return 0
    } catch {
        await model.stop();if let external {ACRenderProbeDestroy(external)}
        await model.shutdown();print("FAIL: \(error)");return 1
    }
}
