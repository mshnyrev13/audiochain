import AppKit
import Foundation
import SwiftUI

private func verifyUpdate(_ value:Bool,_ message:String) throws {if !value {throw AudioFailure(message)}}

private func releaseFixture(_ tag:String="v0.1.35",draft:Bool=false,prerelease:Bool=false,page:String?=nil,asset:String?=nil) throws -> Data {
    let version=String(tag.drop(while:{$0=="v"}))
    let base="https://github.com/mshnyrev13/audiochain/releases/"
    return try JSONSerialization.data(withJSONObject:["tag_name":tag,"html_url":page ?? base+"tag/"+tag,"draft":draft,"prerelease":prerelease,
        "assets":[["name":"AudioChain-\(version).dmg","size":12345,"browser_download_url":asset ?? base+"download/\(tag)/AudioChain-\(version).dmg"]]])
}

private actor UpdateFixture {
    var data:Data
    var status=200
    var calls=0
    init(_ data:Data) {self.data=data}
    func respond(_ request:URLRequest) throws -> (Data,HTTPURLResponse) {
        guard request.url==GitHubUpdateClient.endpoint,request.value(forHTTPHeaderField:"Accept")=="application/vnd.github+json",
              request.value(forHTTPHeaderField:"Authorization")==nil,request.value(forHTTPHeaderField:"Cookie")==nil else {throw AudioFailure("Unsafe update request")}
        calls+=1
        return (data,HTTPURLResponse(url:GitHubUpdateClient.endpoint,statusCode:status,httpVersion:nil,headerFields:[:])!)
    }
    func configure(_ data:Data,status:Int=200) {self.data=data;self.status=status}
    func count()->Int {calls}
}

@MainActor func runAppUpdateTests() async -> Int32 {
    let suite="AudioChain.tests.updates.\(UUID())"
    let defaults=UserDefaults(suiteName:suite)!
    // Every preference used by this test belongs to an isolated defaults suite.
    defer {defaults.removePersistentDomain(forName:suite)}
    do {
        try verifyUpdate(AppVersion("0.1.9")!<AppVersion("0.1.10")!,"Version comparison is lexicographic")
        try verifyUpdate(AppVersion("v1.0.0")==AppVersion("1.0.0"),"v prefix failed")
        for bad in ["", "1.2", "1.2.3.4","1..2","1.2.3-beta","1.2.-3"," 1.2.3","1.2.18446744073709551616","١.٢.٣"] {
            try verifyUpdate(AppVersion(bad)==nil,"Accepted invalid tag: \(bad)")
        }
        let fixture=UpdateFixture(try releaseFixture())
        let client=GitHubUpdateClient(fetch:{try await fixture.respond($0)})
        let expected=AvailableUpdate(version:"0.1.35",page:URL(string:"https://github.com/mshnyrev13/audiochain/releases/tag/v0.1.35")!)
        try verifyUpdate(try await client.check(current:"0.1.34") == .available(expected),"New stable release missing")
        try verifyUpdate(try await client.check(current:"0.1.35") == .current,"Same release prompts update")
        try verifyUpdate(try await client.check(current:"0.2.0") == .current,"Older release prompts downgrade")
        for data in [try releaseFixture(draft:true),try releaseFixture(prerelease:true)] {
            await fixture.configure(data)
            try verifyUpdate(try await client.check(current:"0.1.34") == .noRelease,"Draft/prerelease was offered")
        }
        let hostile=[
            try releaseFixture(page:"https://example.com/update"),
            try releaseFixture(page:"http://github.com/mshnyrev13/audiochain/releases/tag/v0.1.35"),
            try releaseFixture(page:"https://github.com.evil.test/mshnyrev13/audiochain/releases/tag/v0.1.35"),
            try releaseFixture(asset:"https://github.com/other/repo/releases/download/v0.1.35/AudioChain-0.1.35.dmg"),
            Data("{}".utf8),Data(repeating:65,count:1_048_577)]
        for data in hostile {
            await fixture.configure(data)
            var rejected=false;do {_=try await client.check(current:"0.1.34")} catch {rejected=true}
            try verifyUpdate(rejected,"Accepted untrusted/malformed release")
        }
        await fixture.configure(Data(),status:404)
        try verifyUpdate(try await client.check(current:"0.1.34") == .noRelease,"404 handling failed")
        for status in [403,429,500] {
            await fixture.configure(Data(),status:status)
            var rejected=false;do {_=try await client.check(current:"0.1.34")} catch {rejected=true}
            try verifyUpdate(rejected,"Accepted HTTP \(status)")
        }
        await fixture.configure(try releaseFixture())
        var idle=false,clock=Date(timeIntervalSince1970:1_700_000_000)
        var notices:[UpdateNotice]=[],actions:[(UpdateChoice)->Void]=[],opened:[URL]=[]
        let checker=AppUpdateChecker(current:"0.1.34",defaults:defaults,client:client,now:{clock},canPresent:{idle},
            presenter:{notice,action in notices.append(notice);actions.append(action)},open:{opened.append($0)})
        await checker.check(manual:false);checker.presentPending()
        try verifyUpdate(notices.isEmpty,"Update interrupted playback/busy state")
        idle=true;checker.presentPending()
        try verifyUpdate(notices==[.available(expected)],"Queued update not offered after stop")
        actions.removeFirst()(.skip)
        try verifyUpdate(defaults.string(forKey:AppUpdateChecker.skippedKey)=="0.1.35","Skip not remembered")
        let before=await fixture.count()
        await checker.check(manual:false)
        try verifyUpdate(await fixture.count()==before,"Automatic checks are not throttled")
        clock=clock.addingTimeInterval(86401)
        await checker.check(manual:false);checker.presentPending()
        try verifyUpdate(notices.count==1,"Skipped version prompted automatically")
        await checker.check(manual:true);checker.presentPending()
        try verifyUpdate(notices.count==2,"Manual check did not override skip/throttle")
        actions.removeFirst()(.openRelease)
        try verifyUpdate(opened==[expected.page],"Download action did not open the validated release")
        let toggle=NSMenuItem();checker.toggleAutomatic(toggle)
        clock=clock.addingTimeInterval(86401)
        let disabledCount=await fixture.count()
        await checker.check(manual:false)
        try verifyUpdate(await fixture.count()==disabledCount && toggle.state == .off,"Disabled checks still contact GitHub")
        await fixture.configure(Data(),status:500)
        await checker.check(manual:true);checker.presentPending()
        guard case .information?=notices.last else {throw AudioFailure("Manual error not explained")}
        actions.removeFirst()(.later)
        checker.stop()
        let stoppedCount=await fixture.count();await checker.check(manual:true)
        try verifyUpdate(await fixture.count()==stoppedCount,"Shutdown still starts network work")
        print("PASS: numeric versions, draft/prerelease/downgrade exclusion, canonical release and asset URLs, bounded JSON, HTTP 404/403/429/500, no auth/cookies, 24h throttle, playback deferral, skip/manual override, automatic off, safe release opening, shutdown; no network/audio")
        return 0
    } catch {print("FAIL: \(error)");return 1}
}

@MainActor func runUpdateSheetTest() async -> Int32 {
    let model=AudioModel()
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=NSHostingView(rootView:ContentView(model:model,initialLibrary:false));window.title="AudioChain — проверка окна обновления"
    window.makeKeyAndOrderFront(nil)
    var idle=false
    let fixture=UpdateFixture((try? releaseFixture()) ?? Data())
    let suite="AudioChain.tests.update-sheet.\(UUID())"
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite)}
    let checker=AppUpdateChecker(current:"0.1.34",defaults:defaults,client:GitHubUpdateClient(fetch:{try await fixture.respond($0)}),canPresent:{idle},window:{window})
    defer {checker.stop();window.close();window.contentView=nil}
    do {
        await checker.check(manual:true)
        try await Task.sleep(nanoseconds:100_000_000)
        try verifyUpdate(window.attachedSheet==nil,"Update sheet interrupted busy playback")
        idle=true;checker.schedulePresentation()
        try await Task.sleep(nanoseconds:200_000_000)
        guard let sheet=window.attachedSheet,let view=sheet.contentView else {throw AudioFailure("Native update sheet did not open")}
        func buttonTitles(_ view:NSView)->[String] {
            (view as? NSButton).map {[$0.title]} ?? view.subviews.flatMap {buttonTitles($0)}
        }
        let titles=buttonTitles(view)
        try verifyUpdate(["Открыть релиз","Позже","Пропустить версию"].allSatisfy {titles.contains($0)},"Native update actions missing: \(titles)")
        view.layoutSubtreeIfNeeded()
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {
                let directory=URL(fileURLWithPath:auditOutputDirectory(fallback:"Updates/2026-10-21")+"/screenshots")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try data.write(to:directory.appendingPathComponent("update-sheet.png"))
            }
        }
        window.endSheet(sheet,returnCode:.alertSecondButtonReturn)
        try await Task.sleep(nanoseconds:100_000_000)
        try verifyUpdate(window.attachedSheet==nil,"Later did not close the update sheet")
        await model.shutdown()
        print("PASS: actual NSAlert sheet deferred until idle, three update buttons, native rendering and Later dismissal; no network/audio")
        return 0
    } catch {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.alertSecondButtonReturn)};await model.shutdown();print("FAIL: \(error)");return 1}
}

func runLiveUpdateCheck() async -> Int32 {
    let current=CommandLine.arguments.firstIndex(of:"--update-current").flatMap {CommandLine.arguments.count>$0+1 ? CommandLine.arguments[$0+1]:nil} ?? "0.1.34"
    do {
        switch try await GitHubUpdateClient().check(current:current) {
        case .current:print("UPDATE_NETWORK current=\(current) up-to-date")
        case .noRelease:print("UPDATE_NETWORK no published stable release")
        case .available(let release):print("UPDATE_NETWORK current=\(current) available=\(release.version) page=\(release.page.absoluteString)")
        }
        return 0
    } catch {print("UPDATE_NETWORK failed: \(type(of:error))");return 1}
}
