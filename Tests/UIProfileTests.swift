import SwiftUI
import Combine

@MainActor enum UIAuditCounters {
    static var graphBodies = 0
    static var meterBodies = 0
    static var inputPeak = -Double.infinity
    static var inputClipping = false
    static func graph() {graphBodies += 1}
    static func meter(input:Bool = false,peak:Double = -.infinity,clipping:Bool = false) {
        meterBodies += 1
        if input {inputPeak = peak;inputClipping = clipping}
    }
}

@MainActor func runMeterLifecycle() async -> Int32 {
    let model = AudioModel()
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:320),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView:ContentView(model:model,initialLibrary:false))
    window.makeKeyAndOrderFront(nil)
    do {
        model.inputLevels = StereoLevels(left:1,right:-6)
        try await Task.sleep(nanoseconds:300_000_000)
        try check(UIAuditCounters.inputClipping,"Visible meter did not indicate overload")
        try await Task.sleep(nanoseconds:2_200_000_000)
        try check(UIAuditCounters.inputClipping,"Steady overload expired without a falling edge")
        model.inputLevels = StereoLevels(left:-20,right:-20)
        try await Task.sleep(nanoseconds:100_000_000)
        try check(UIAuditCounters.inputPeak == 1 && UIAuditCounters.inputClipping,"Falling edge lost held peak/clip")
        try await Task.sleep(nanoseconds:1_250_000_000)
        try check(UIAuditCounters.inputPeak == -20 && UIAuditCounters.inputClipping,"Peak deadline did not expire independently of clip")
        try await Task.sleep(nanoseconds:1_000_000_000)
        try check(!UIAuditCounters.inputClipping,"Clip deadline did not expire")
        model.inputLevels = StereoLevels(left:.nan,right:-20)
        try await Task.sleep(nanoseconds:100_000_000)
        try check(UIAuditCounters.inputPeak == .infinity,"NaN presentation did not become stable fault")
        model.inputLevels = StereoLevels()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(UIAuditCounters.inputPeak == -.infinity,"Fault presentation did not recover to silence")
        let before = UIAuditCounters.meterBodies
        try await Task.sleep(nanoseconds:400_000_000)
        try check(UIAuditCounters.meterBodies == before,"Silent meters keep waking after deadlines")
        window.close();window.contentView = nil;await model.shutdown()
        print("PASS: actual SwiftUI task lifecycle: steady overload, falling edge, separate peak/clip expiry, NaN recovery, no idle redraws");return 0
    } catch {window.close();window.contentView = nil;await model.shutdown();print("FAIL: \(error)");return 1}
}

func runDisplayIndexBenchmark() throws {
    let component = ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
    for count in [128,512,2048] {
        let blocks = (0..<count).map {Block(kind:.effect,name:"EQ",x:Double($0)*172,y:76,component:component)}
        let wires = zip(blocks,blocks.dropFirst()).map {Wire(from:$0.id,to:$1.id)}
        var oldTimes:[Double] = [],newTimes:[Double] = []
        var oldChecksum = 0.0,newChecksum = 0.0
        for _ in 0..<7 {
            let begin = DispatchTime.now().uptimeNanoseconds
            for wire in wires {oldChecksum += blocks.first {$0.id == wire.from}!.x+blocks.first {$0.id == wire.to}!.x}
            oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds-begin)/1e6)
            let next = DispatchTime.now().uptimeNanoseconds
            let index = GraphDisplayIndex(blocks)
            for wire in wires {newChecksum += index.blocks[wire.from]!.x+index.blocks[wire.to]!.x}
            newTimes.append(Double(DispatchTime.now().uptimeNanoseconds-next)/1e6)
        }
        try check(oldChecksum == newChecksum,"Indexed wire endpoints changed")
        print("DISPLAY_INDEX blocks=\(count) old_median_ms=\(oldTimes.sorted()[3]) new_median_ms=\(newTimes.sorted()[3]) checksum=\(newChecksum)")
    }
}

@MainActor func runUIProfile() async -> Int32 {
    let model = AudioModel()
    let component = ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
    let source = model.session.blocks[0], output = model.session.blocks[1]
    let effects = (0..<128).map {Block(kind:.effect,name:"EQ \($0+1)",x:220+Double($0)*172,y:76,component:component)}
    model.session.blocks = [source]+effects+[output]
    let route = [source]+effects+[output]
    model.session.wires = zip(route,route.dropFirst()).map {Wire(from:$0.id,to:$1.id)}
    model.arrange()
    let host = NSHostingView(rootView:ContentView(model:model,initialLibrary:false))
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false;window.contentView = host;window.title = "AudioChain idle UI profile — no audio"
    window.makeKeyAndOrderFront(nil)
    var changes = 0
    let token = model.objectWillChange.sink {_ in changes += 1}
    try? await Task.sleep(nanoseconds:1_000_000_000)
    UIAuditCounters.graphBodies = 0;UIAuditCounters.meterBodies = 0;changes = 0
    let start = ACReadSystemMetrics()
    try? await Task.sleep(nanoseconds:8_000_000_000)
    let end = ACReadSystemMetrics()
    print("UI_IDLE blocks=130 seconds=\(end.wallSeconds-start.wallSeconds) model_publications=\(changes) graph_bodies=\(UIAuditCounters.graphBodies) meter_bodies=\(UIAuditCounters.meterBodies) cpu_seconds=\(end.appCPUSeconds-start.appCPUSeconds) footprint=\(end.appMemory)")
    if CommandLine.arguments.contains("--ui-profile-strict") {
        guard changes == 0, UIAuditCounters.graphBodies == 0, UIAuditCounters.meterBodies == 0 else {
            token.cancel();window.close();window.contentView = nil;await model.shutdown()
            print("FAIL: idle telemetry/timers invalidated static graph or meters");return 1
        }
    }
    token.cancel();window.close();window.contentView = nil;await model.shutdown()
    print("PASS: idle UI profile, audio never started");return 0
}
