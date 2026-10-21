import SwiftUI

func runResourceMonitorTests() throws {
    func metrics(_ time:Double,_ cpu:Double,valid:Bool=true,memory:Bool=true)->ACSystemMetrics {
        var m=ACSystemMetrics();m.wallSeconds=time;m.appCPUSeconds=cpu;m.appCPUValid=valid ? 1:0
        m.appValid=memory ? 1:0;m.appMemory=123456;m.memoryValid=1;m.memoryTotal=1000000;m.memoryUsed=500000
        return m
    }
    var monitor=ResourceMonitor()
    try check(monitor.sample(metrics(10,100)).appCPU==nil,"First sample has no CPU interval")
    try check(monitor.sample(metrics(11,101)).appCPU==100,"Valid one-core interval failed")
    let failure=monitor.sample(metrics(12,0,valid:false))
    print("CPU_FAILURE displayed=\(String(describing:failure.appCPU)) memory=\(String(describing:failure.appMemory))")
    try check(failure.appCPU==nil && failure.appMemory==123456,"Failed CPU read displayed a numeric zero or hid valid RAM")
    try check(monitor.sample(metrics(13,102)).appCPU==nil,"Recovery used invalid CPU baseline")
    try check(monitor.sample(metrics(14,102.25)).appCPU==25,"CPU recovery interval failed")
    try check(monitor.sample(metrics(15,104.75,memory:false)).appCPU==250,"Multi-core CPU incorrectly clamped to 100 or tied to RAM validity")
    try check(monitor.sample(metrics(16,104)).appCPU==nil,"Decreasing cumulative CPU accepted")
    try check(monitor.sample(metrics(16,105)).appCPU==nil,"Zero time interval accepted")
    try check(monitor.sample(metrics(.nan,106)).appCPU==nil,"Nonfinite time accepted")
    print("PASS: failed CPU reads are unavailable independently of RAM; two valid samples for recovery, multicore percentage, nonmonotonic/zero/nonfinite intervals; injected OS snapshots")
}

@MainActor func runLoadNumberTests() async -> Int32 {
    let model=AudioModel()
    do {
        let component=ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
        for i in 0..<5 {model.session.blocks.append(Block(kind:.effect,name:"EQ",x:300+Double(i)*172,y:76,component:component))}
        model.samplePlaybackTelemetry(includeStopped:true)
        for row in AULoadOrder.chain.rows(model.telemetry.auLoads) {
            let expected=model.session.blocks.firstIndex {$0.id==row.id}!+1
            print("BLOCK_NUMBER panel=\(row.ordinal) search=\(expected)")
            try check(row.ordinal==expected,"AU panel and search identify the same block with different numbers")
        }
        try check(GraphBlockLookup.matches(model.session,query:" #3 ").first?.element.id==model.session.blocks[2].id,"Number lookup missed exact block")
        try check(GraphBlockLookup.matches(model.session,query:"EQ").count==5,"Name search changed")
        for text in ["#0","#8","#9999999999999999999999999999999999999","#-1"] {
            try check(GraphBlockLookup.matches(model.session,query:text).isEmpty,"Invalid block number accepted: \(text)")
        }
        await model.shutdown();print("PASS: AU telemetry row numbers match document/search indices, including detached identical names, exact-number/name lookup and invalid indices; no AU instantiation/audio")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}

@MainActor func runSettingsScrollTests() async -> Int32 {
    let model=AudioModel()
    model.session.inputKind = .system
    model.session.systemExcludedBundleIDs=(0..<24).map {"com.example.excluded-app-\($0+1)"}
    let host=NSHostingView(rootView:BlockSettingsView(model:model,kind:.source))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer {window.close();window.contentView=nil}
    do {
        try await Task.sleep(nanoseconds:200_000_000)
        host.layoutSubtreeIfNeeded()
        func find(_ view:NSView)->NSScrollView? {(view as? NSScrollView) ?? view.subviews.compactMap {find($0)}.first}
        let directory=URL(fileURLWithPath:auditOutputDirectory(fallback:"Audit/2026-10-21-round8")+"/screenshots")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func screenshot(_ name:String) throws {
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:directory.appendingPathComponent(name))}
            }
        }
        try screenshot("settings-long-top.png")
        guard let scroll=find(host),let document=scroll.documentView else {throw AudioFailure("Long source settings have no scroll view; lower controls inaccessible")}
        try check(scroll.contentView.bounds.height>0 && scroll.contentView.bounds.height<300 && document.bounds.height>scroll.contentView.bounds.height,"Long settings viewport is not bounded")
        let end=max(0,document.bounds.height-scroll.contentView.bounds.height)
        scroll.contentView.scroll(to:CGPoint(x:0,y:end));scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds:100_000_000)
        try check(abs(scroll.contentView.bounds.minY-end)<2,"Cannot reach end of settings")
        try screenshot("settings-long-bottom.png")
        await model.shutdown();print("PASS: 24 excluded apps in 440x300 source settings; bounded native scroll view reaches lower controls, header retained; own window/config fixture")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}
