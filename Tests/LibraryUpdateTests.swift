import SwiftUI

@MainActor func runLibraryUpdateTests() async -> Int32 {
    let model=AudioModel()
    let component=ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
    model.plugins=(0..<140).map {PluginChoice(id:"fixture-\($0)",name:"EQ \($0)",manufacturer:"Fixture",component:component)}
    let host=NSHostingView(rootView:ContentView(model:model,initialLibrary:true))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer {window.close();window.contentView=nil}
    do {
        try await Task.sleep(nanoseconds:300_000_000)
        UIAuditCounters.libraryBodies=0
        for i in 0..<40 {
            model.session.blocks[0].x=Double(40+i)
            model.selected=i.isMultiple(of:2) ? model.session.blocks[0].id:nil
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let unrelated=UIAuditCounters.libraryBodies
        print("LIBRARY catalog=140 graph_moves=40 selection_changes=40 body_evaluations=\(unrelated)")
        try check(unrelated==0,"Graph edits refiltered the unrelated AU catalogue")
        let state=PluginLibraryState(model:model)
        try check(state.plugins.count==140 && state.canAdd && !state.refreshing,"Initial library state is stale")
        model.busy=true
        try await Task.sleep(nanoseconds:50_000_000)
        try check(!UIAuditCounters.libraryCanAdd,"Native library ignored busy state")
        try check(!state.canAdd,"Busy model permits adding AU")
        model.running=true;model.busy=false
        try check(!state.canAdd,"Running model permits adding AU")
        model.running=false
        try await Task.sleep(nanoseconds:50_000_000)
        try check(UIAuditCounters.libraryCanAdd,"Native library ignored stopped state")
        try check(state.canAdd,"Stopped model still disables adding AU")
        model.refreshingPlugins=true
        try await Task.sleep(nanoseconds:50_000_000)
        try check(UIAuditCounters.libraryRefreshing,"Native library ignored scanner state")
        try check(state.refreshing,"Scan start not forwarded")
        model.refreshingPlugins=false
        try check(!state.refreshing,"Scan completion not forwarded")
        try await Task.sleep(nanoseconds:50_000_000)
        try check(!UIAuditCounters.libraryRefreshing,"Native library retained spinner")
        let first=model.plugins[0]
        var replacement=first;replacement.unavailable="Fixture unavailable"
        model.plugins[0]=replacement
        try check(state.plugins[0].unavailable==replacement.unavailable,"Catalogue replacement lost availability change")
        model.plugins.append(PluginChoice(id:"new-fixture",name:"New",manufacturer:"Fixture",component:component))
        try await Task.sleep(nanoseconds:50_000_000)
        try check(UIAuditCounters.libraryCount==141,"Native library ignored new catalogue")
        let fixtures=[first,PluginChoice(id:"generator",name:"Tone",manufacturer:"Fixture",component:ComponentID(type:kAudioUnitType_Generator,subtype:0,manufacturer:0)),model.plugins[1]]
        let favorites:Set<String>=["generator",first.id]
        try check(PluginLibraryFilter.visible(fixtures,favorites:favorites,search:"",category:.all,favoritesOnly:false).map(\.id)==[first.id,"generator",model.plugins[1].id],"Stable favorite-first order changed")
        try check(PluginLibraryFilter.visible(fixtures,favorites:favorites,search:"  tone  ",category:.all,favoritesOnly:true).map(\.id)==["generator"],"Trimmed favorite search failed")
        try check(PluginLibraryFilter.visible(fixtures,favorites:favorites,search:"",category:.effects,favoritesOnly:true).map(\.id)==[first.id],"Category/favorites intersection failed")
        try check(PluginLibraryFilter.emptyMessage(fixtures,favorites:favorites,favoritesOnly:true).contains("Ничего не найдено"),"Hidden favorites incorrectly described as absent")
        try check(PluginLibraryFilter.emptyMessage(fixtures,favorites:["uninstalled"],favoritesOnly:true).contains("звёздочку"),"Missing favorites has no useful instruction")
        try await Task.sleep(nanoseconds:100_000_000)
        let directory=URL(fileURLWithPath:auditOutputDirectory(fallback:"Audit/2026-10-21-round9")+"/screenshots")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        host.layoutSubtreeIfNeeded()
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:directory.appendingPathComponent("library.png"))}
        }
        weak var released:PluginLibraryState?
        do {let temporary=PluginLibraryState(model:model);released=temporary}
        try check(released==nil,"Subscriptions retain library state after disposal")
        print("PASS: library in real ContentView ignores graph/selection changes; busy/running, scan lifecycle, availability refresh, stable favorites, query/category, truthful empty states, subscription disposal; no audio")
        await model.shutdown();return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}
