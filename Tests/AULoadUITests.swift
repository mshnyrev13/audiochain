import SwiftUI

@MainActor func runAULoadUITests() async -> Int32 {
    do {
        let budgets:[Double?]=[20,nil,80,20,.nan,.infinity,-1,120]
        let loads=budgets.enumerated().map {index,value -> AULoad in
            var load=AULoad(id:UUID(),name:"EQ",bypass:index==0,active:index != 1)
            load.budgetPercent=value;load.meanMS=value.map {$0/10};load.peakMS=15;load.calls=value==nil ? 0:40
            return load
        }
        try check(AULoadOrder.chain.rows(loads).map(\.id)==loads.map(\.id),"Default order changed")
        let sorted=AULoadOrder.budget.rows(loads)
        try check(sorted.map(\.ordinal)==[8,3,1,4,2,5,6,7],"Budget sort is unstable or accepts invalid values")
        try check(sorted[0].load.measuredBudget==120 && sorted[1].load.measuredBudget==80,"Budget is normalized or capped in data")
        try check(AULoadOrder.budget.rows([]).isEmpty,"Empty load panel failed")
        let telemetry=DisplayTelemetry()
        telemetry.hasRunMeasurements=true;telemetry.playbackRunning=false
        telemetry.auLoads=[loads[0],loads[1],loads[2],loads[3],loads[7]]
        telemetry.resources.appMemory=150_000_000;telemetry.resources.appCPU=12.3
        let host=NSHostingView(rootView:AULoadPanel(telemetry:telemetry,initialOrder:.budget))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:380),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
        defer {window.close();window.contentView=nil}
        try await Task.sleep(nanoseconds:200_000_000)
        host.layoutSubtreeIfNeeded()
        let directory=URL(fileURLWithPath:auditOutputDirectory(fallback:"Audit/2026-10-21-round7")+"/screenshots")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:directory.appendingPathComponent("au-load-ranked.png"))}
        }
        print("PASS: stable descending budget, schema ordinals retained, unknown/nonfinite/negative values last, 120% preserved, empty rows, native ranked panel fixture; no audio")
        return 0
    } catch {print("FAIL: \(error)");return 1}
}
