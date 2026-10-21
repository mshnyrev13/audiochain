import SwiftUI

@MainActor func runCableInteractionAudit() async -> Int32 {
    let model=AudioModel()
    let host=NSHostingView(rootView:ContentView(model:model,initialLibrary:false,initialSelectedWire:model.session.wires.first))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:320),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host
    window.title="AudioChain cable test — no audio"
    window.makeKeyAndOrderFront(nil)
    do {
        try await Task.sleep(nanoseconds:300_000_000)
        // Selection is initialized in this fixture; exercise native Delete
        // against only this window, without OS-wide AX permissions.
        _ = window.makeFirstResponder(host)
        try await Task.sleep(nanoseconds:200_000_000)
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {
                try data.write(to:URL(fileURLWithPath:auditOutputDirectory(fallback:"Audit/2026-10-21-round4")+"/screenshots/keyboard-wire.png"))
            }
        }
        let original=model.session.wires
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51)!
            window.sendEvent(event)
        }
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.session.wires.isEmpty,"Delete key did not remove selected cable in own window")
        model.restoreLastConnection()
        try check(model.session.wires==original,"Cable keyboard deletion did not restore")
        window.close();window.contentView=nil;await model.shutdown()
        print("PASS: own native window with initialized cable selection: targeted Delete removes; restore preserves wire; no audio/no global input")
        return 0
    } catch {
        window.close();window.contentView=nil;await model.shutdown()
        print("FAIL: \(error)");return 1
    }
}
