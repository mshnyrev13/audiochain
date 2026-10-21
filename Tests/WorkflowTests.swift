import SwiftUI
import AVFoundation

@MainActor func runWorkflowTests() async -> Int32 {
    let model=AudioModel()
    do {
        let first=model.session.blocks[0], wire=model.session.wires[0]
        model.beginMove()
        for i in 0..<30 {model.moveBlock(first.id,to:CGPoint(x:100+Double(i),y:180))}
        model.endMove()
        let moved=GraphEditState(model.session)
        try check(model.editHistory.undoName=="Перемещение","Drag not grouped")
        model.session.outputUID="preserve.output.choice"
        await model.undoEdit()
        try check(model.session.blocks[0]==first && model.editHistory.undoName==nil,"Drag undo was not one action")
        try check(model.session.outputUID=="preserve.output.choice","Undo changed device selection")
        await model.redoEdit();try check(GraphEditState(model.session)==moved,"Redo did not restore coordinates")
        model.disconnect(wire);await model.undoEdit();try check(model.session.wires==[wire],"Wire undo failed")
        await model.redoEdit();try check(model.session.wires.isEmpty,"Wire redo failed")
        model.pendingPort=wire.from;model.inputPort(wire.to)
        try check(model.editHistory.redoName==nil && model.session.wires==[wire],"New edit did not clear redo")
        let requested=CommandLine.arguments.firstIndex(of:"--undo-plugin").flatMap {CommandLine.arguments.count>$0+1 ? CommandLine.arguments[$0+1]:nil}
        guard let plugin=model.plugins.first(where:{choice in choice.unavailable == nil && (requested.map {choice.name==$0} ?? (choice.component.subtype==kAudioUnitSubType_NBandEQ && choice.component.manufacturer==kAudioUnitManufacturer_Apple))}) else {throw AudioFailure("EQ missing")}
        func gainParameter(_ unit:AVAudioUnit) throws -> AUParameter {
            let tree=unit.auAudioUnit.parameterTree
            if requested == nil,let value=tree?.parameter(withAddress:AUParameterAddress(kAUNBandEQParam_GlobalGain)) {return value}
            guard let value=tree?.allParameters.first(where:{["GAIN: Output L (Locked)","Output Level"].contains($0.displayName)}) else {throw AudioFailure("Output gain missing")}
            return value
        }
        await model.add(plugin)
        guard let id=model.selected,let unit=model.unitForDiagnostics(id) else {throw AudioFailure(model.status)}
        try PluginHost.prepareEditor(unit)
        try gainParameter(unit).value = -9
        model.insertBeforeOutput(id)
        let connected=model.session.wires
        model.remove(id);try check(model.unitForDiagnostics(id)==nil,"Remove failed")
        await model.undoEdit()
        guard let restored=model.unitForDiagnostics(id) else {throw AudioFailure(model.status)}
        let gain=try gainParameter(restored)
        try check(abs(gain.value+9)<0.01 && model.session.wires==connected,"Delete undo lost AU state or cables")
        gain.value = -12
        await model.redoEdit();try check(model.unitForDiagnostics(id)==nil,"Delete redo failed")
        await model.undoEdit()
        try check(abs(gainParameter(model.unitForDiagnostics(id)!).value+12)<0.01,"Redo/undo lost updated AU state")
        let before=GraphEditState(model.session)
        model.running=true;await model.undoEdit();try check(GraphEditState(model.session)==before,"Undo changed running graph")
        model.running=false
        var broken=GraphEditState(model.session)
        broken.blocks.append(Block(kind:.effect,name:"Missing AU",x:800,y:76,component:ComponentID(type:kAudioUnitType_Effect,subtype:0xdeadbeef,manufacturer:0x78787878)))
        model.editHistory.record(GraphEditEntry(state:broken,selection:nil,name:"Missing fixture"))
        await model.undoEdit()
        try check(GraphEditState(model.session)==before && model.editHistory.undoName=="Missing fixture","Failed AU restore consumed history or modified graph")
        await model.shutdown()
        print("PASS: grouped drag, undo/redo cables, new-edit redo reset, AU removal/restoration with -9/-12 state, device choices preserved, running guard, transactional restore failure")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}

func runSignalDiagnosisTests() throws {
    func evaluate(input:Bool=false,output:Bool=false,muted:Bool=false,fault:Bool=false,error:String?=nil,missing:String?=nil) -> SignalHealth {
        SignalHealth.evaluate(running:true,busy:false,routeError:nil,muted:muted,fault:fault,inputRecent:input,outputRecent:output,warmed:true,generator:false,renderError:error,renderMissing:missing)
    }
    try check(evaluate(muted:true).text=="Выход заглушён","Mute reason lost")
    try check(evaluate().text.contains("Источник молчит"),"Silence reason lost")
    try check(evaluate(input:true).text.contains("на выходе тишина"),"AU attenuation not distinguished from input silence")
    try check(evaluate(input:true,output:true).text=="Сигнал проходит","Good route misdiagnosed")
    try check(evaluate(fault:true).text.contains("PCM"),"Non-finite fault hidden")
    try check(evaluate(error:"EQ").text.contains("Ошибка render: EQ"),"Measured render error hidden")
    try check(evaluate(input:true,missing:"EQ").text.contains("Нет данных render"),"Missing AU heartbeat hidden")
    try check(SignalHealth.evaluate(running:true,busy:false,routeError:nil,muted:false,fault:false,inputRecent:true,outputRecent:false,warmed:true,generator:false,renderError:nil,renderWaiting:"EQ").text.contains("более 2 с: EQ"),"In-flight AU stall hidden")
    try check(SignalHealth.evaluate(running:false,busy:false,routeError:"Нет входа",muted:false,fault:false,inputRecent:false,outputRecent:false,warmed:false,generator:false,renderError:nil).text.contains("Нет маршрута"),"Disconnected cable hidden")
    let warning=PlaybackPresentation(status:"AU-цепочка",health:evaluate(input:true),attention:false)
    try check(warning.text.hasPrefix("На входе сигнал") && warning.warning,"Compact footer truncates warning after the transport label")
    let failure=PlaybackPresentation(status:"Не удалось запустить: устройство отключено",health:SignalHealth(text:"Остановлено"),attention:true)
    try check(failure.text.hasPrefix("Не удалось") && failure.warning,"Start failure hidden behind health")
    print("PASS: diagnosis separates disconnected routing, silence, mute, PCM fault, AU render error, missing render data and healthy signal")
}

@MainActor func runNavigationTest() async -> Int32 {
    let model=AudioModel()
    let zoom=CommandLine.arguments.firstIndex(of:"--preview-zoom").flatMap {CommandLine.arguments.count>$0+1 ? Double(CommandLine.arguments[$0+1]):nil}.map {$0/100} ?? 1
    let host=NSHostingView(rootView:ContentView(model:model,initialZoom:zoom,initialLibrary:false,initialMap:true))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    do {
        for i in 0..<40 {model.session.blocks.append(Block(kind:.effect,name:"EQ \(i)",x:220+Double(i)*172,y:76,component:ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)))}
        model.session.blocks[model.session.blocks.count-1].y=1800
        try await Task.sleep(nanoseconds:300_000_000)
        // Exercise the actual NSScrollView bridge in the SwiftUI graph.
        func attachment(_ view:NSView)->GraphScrollAccessor.ScrollAttachment? {
            if let value=view as? GraphScrollAccessor.ScrollAttachment {return value}
            return view.subviews.compactMap {attachment($0)}.first
        }
        guard let navigator=attachment(host)?.navigator,let scroll=navigator.scrollView else {throw AudioFailure("Graph scroll bridge not attached")}
        let target=model.session.blocks.last!
        model.selected=target.id;navigator.reveal(target,zoom:zoom)
        let targetCenter=CGPoint(x:(target.x+GraphLayout.width(for:target)/2)*zoom,y:(target.y+GraphLayout.height(for:target)/2)*zoom)
        try check(scroll.contentView.bounds.contains(targetCenter),"Search target outside viewport at zoom \(zoom): \(scroll.contentView.bounds), \(targetCenter)")
        try check(abs(scroll.contentView.bounds.midX-targetCenter.x)<2 && abs(scroll.contentView.bounds.midY-targetCenter.y)<2,"End block is pinned to the navigation overlay instead of centred")
        try check(scroll.contentView.bounds.minX>5000*zoom && scroll.contentView.bounds.minY>1000*zoom,"Search failed on one axis")
        host.layoutSubtreeIfNeeded()
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:URL(fileURLWithPath:auditOutputDirectory(fallback:"Features/2026-10-21")+"/screenshots/map-distant.png"))}
        }
        navigator.center(.zero)
        try check(scroll.contentView.bounds.minX==0,"Mini-map cannot return to origin")
        let old=model.session.blocks[0]
        model.beginMove();model.moveBlock(old.id,to:CGPoint(x:80,y:90));model.endMove()
        try await Task.sleep(nanoseconds:100_000_000)
        let undo=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
        try check(window.performKeyEquivalent(with:undo),"Cmd Z not handled")
        try await Task.sleep(nanoseconds:200_000_000)
        try check(model.session.blocks[0]==old,"Cmd Z did not undo move")
        let search=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"f",charactersIgnoringModifiers:"f",isARepeat:false,keyCode:3)!
        try check(window.performKeyEquivalent(with:search),"Cmd F not handled")
        window.close();window.contentView=nil;await model.shutdown()
        print("PASS: native SwiftUI scroll bridge reveals far block and returns via map coordinates; Cmd Z undoes, Cmd F opens search; own window only")
        return 0
    } catch {window.close();window.contentView=nil;await model.shutdown();print("FAIL: \(error)");return 1}
}
