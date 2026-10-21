import SwiftUI
import AVFoundation

@MainActor func configureAuditPreview(_ model: AudioModel, scenario: String) {
    let component = ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple)
    if scenario == "branches" || scenario == "pending" {
        let a = Block(kind: .effect, name: "Эквалайзер с очень длинным названием", x: 210, y: 76, component: component)
        let b = Block(kind: .effect, name: "Параллельная ветка", x: 210, y: 210, component: component, bypass: true)
        model.session.blocks[0].y = 140; model.session.blocks[1].x = 410; model.session.blocks[1].y = 140
        let source = model.session.blocks[0], output = model.session.blocks[1]
        model.session.blocks += [a,b]
        model.session.wires = [Wire(from: source.id,to:a.id),Wire(from:source.id,to:b.id),Wire(from:a.id,to:output.id),Wire(from:b.id,to:output.id)]
        model.selected = a.id
        if scenario == "pending" {model.selected = nil;model.pendingPort = source.id}
    } else if scenario == "long" {
        for i in 0..<18 {
            let block = Block(kind:.effect,name:"EQ \(i+1)",x:0,y:76,component:component)
            model.session.blocks.append(block); try? model.session.insertBeforeOutput(block.id)
        }
        model.arrange()
    } else if scenario == "fault" {
        model.inputLevels = StereoLevels(left: .infinity, right: -.infinity)
        model.outputLevels = StereoLevels(left: 1.2, right: -6)
        model.status = "Ошибка PCM: NaN/Inf. Проверьте источник и плагины."
    } else if scenario == "empty" {
        model.session.wires = []
        model.status = "Соедините источник и выход. Двойной клик открывает настройки."
    }
}

@MainActor func runAuditWindowTest() throws {
    let libraryKey = "AudioChain.ui.libraryExpanded"
    let previousLibrary = UserDefaults.standard.object(forKey:libraryKey)
    defer {
        if let previousLibrary {UserDefaults.standard.set(previousLibrary,forKey:libraryKey)}
        else {UserDefaults.standard.removeObject(forKey:libraryKey)}
    }
    let outputDirectory = auditOutputDirectory(fallback:CommandLine.arguments.contains("--design-ui") ? "Design/2026-10-21" : "Audit/2026-10-21")+"/screenshots"
    let model = AudioModel()
    let host = NSHostingView(rootView: ContentView(model:model))
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:400),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:.darkAqua)
    window.contentView = host; window.title = "AudioChain UI audit — no audio"
    defer { window.close(); window.contentView = nil }
    for (index,screen) in NSScreen.screens.enumerated() {
        window.setFrameOrigin(NSPoint(x:screen.visibleFrame.minX+24,y:screen.visibleFrame.minY+24))
        for size in [NSSize(width:640,height:320),NSSize(width:780,height:400)] {
            window.setContentSize(size); window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until:Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
            try check(host.bounds.width >= 640 && host.bounds.height >= 320,"Minimum window clipped root")
            print("WINDOW screen=\(screen.localizedName) scale=\(window.backingScaleFactor) content=\(host.bounds.size)")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                if let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:"\(outputDirectory)/screen-\(index)-\(Int(size.width)).png")) }
            }
        }
    }
    let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"b",charactersIgnoringModifiers:"b",isARepeat:false,keyCode:11)!
    let handled = window.performKeyEquivalent(with:event)
    try check(handled,"Library keyboard shortcut unhandled")
    let diagnostics = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"d",charactersIgnoringModifiers:"d",isARepeat:false,keyCode:2)!
    let diagnosticsHandled = window.performKeyEquivalent(with:diagnostics)
    try check(diagnosticsHandled,"Diagnostics keyboard shortcut unhandled")
    RunLoop.current.run(until:Date().addingTimeInterval(0.1))
    print("KEYBOARD command_b_handled=\(handled) command_d_handled=\(diagnosticsHandled); preferences restored; drag/zoom/VoiceOver require separate interactive validation")
    print("PASS: native minimum/default window layout on connected screens; own windows only, no audio")
}

@MainActor func runAuditEditorChurn(name: String) async -> Int32 {
    let model = AudioModel()
    do {
        guard let plugin = model.plugins.first(where: {$0.name == name && $0.unavailable == nil}) else {throw AudioFailure("Plugin missing")}
        for iteration in 0..<20 {
            await model.add(plugin)
            guard let id = model.selected else {throw AudioFailure(model.status)}
            model.openEditor(id)
            try await Task.sleep(nanoseconds:30_000_000)
            model.remove(id)
            try check(model.unitForDiagnostics(id) == nil && !model.session.blocks.contains {$0.id == id},"Remove left AU in graph")
            try await Task.sleep(nanoseconds:30_000_000)
            if iteration%5 == 4 {print("EDITOR_CHURN plugin=\(name) cycles=\(iteration+1)");fflush(stdout)}
        }
        await model.shutdown()
        print("PASS: 20 rapid native editor create/open/remove cycles, no audio")
        return 0
    } catch {await model.shutdown(); print("FAIL: \(error)");return 1}
}
