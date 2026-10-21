import Foundation
import AppKit
import Combine

struct AppVersion:Comparable {
    let major:UInt64,minor:UInt64,patch:UInt64
    init?(_ raw:String) {
        let text=raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts=text.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy {48...57 ~= $0}}),
              let a=UInt64(parts[0]),let b=UInt64(parts[1]),let c=UInt64(parts[2]) else {return nil}
        major=a;minor=b;patch=c
    }
    static func < (a:Self,b:Self)->Bool {(a.major,a.minor,a.patch)<(b.major,b.minor,b.patch)}
    var text:String {"\(major).\(minor).\(patch)"}
}

struct AvailableUpdate:Equatable {
    let version:String
    let page:URL
}
enum UpdateLookup:Equatable {case current,noRelease,available(AvailableUpdate)}
enum UpdateFailure:Error {case response,rateLimited,invalidRelease}

struct GitHubUpdateClient {
    static let repository="mshnyrev13/audiochain"
    static let endpoint=URL(string:"https://api.github.com/repos/\(repository)/releases/latest")!
    static let project=URL(string:"https://github.com/\(repository)")!
    typealias Fetch=(URLRequest) async throws -> (Data,HTTPURLResponse)
    let fetch:Fetch
    init(fetch:Fetch?=nil) {
        if let fetch {self.fetch=fetch}
        else {
            let configuration=URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20
            configuration.httpShouldSetCookies=false;configuration.urlCredentialStorage=nil
            let session=URLSession(configuration:configuration)
            self.fetch={request in
                let (data,response)=try await session.data(for:request)
                guard let http=response as? HTTPURLResponse else {throw UpdateFailure.response}
                return (data,http)
            }
        }
    }
    func check(current:String) async throws -> UpdateLookup {
        guard let installed=AppVersion(current) else {throw UpdateFailure.invalidRelease}
        var request=URLRequest(url:Self.endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
        request.setValue("AudioChain/\(installed.text)",forHTTPHeaderField:"User-Agent")
        let (data,response)=try await fetch(request)
        try Task.checkCancellation()
        guard response.url==Self.endpoint else {throw UpdateFailure.response}
        if response.statusCode==404 {return .noRelease}
        if [403,429].contains(response.statusCode) {throw UpdateFailure.rateLimited}
        guard response.statusCode==200,data.count<=1_048_576 else {throw UpdateFailure.response}
        let release=try JSONDecoder().decode(Release.self,from:data)
        guard !release.draft,!release.prerelease else {return .noRelease}
        guard let version=AppVersion(release.tag_name) else {throw UpdateFailure.invalidRelease}
        guard version>installed else {return .current}
        let page=Self.project.appendingPathComponent("releases/tag").appendingPathComponent(release.tag_name)
        let name="AudioChain-\(version.text).dmg"
        let download=Self.project.appendingPathComponent("releases/download").appendingPathComponent(release.tag_name).appendingPathComponent(name)
        guard release.html_url==page.absoluteString,
              release.assets.contains(where:{$0.name==name && $0.size>0 && $0.browser_download_url==download.absoluteString}) else {throw UpdateFailure.invalidRelease}
        return .available(AvailableUpdate(version:version.text,page:page))
    }
    private struct Release:Decodable {
        let tag_name:String,html_url:String
        let draft:Bool,prerelease:Bool
        let assets:[Asset]
        struct Asset:Decodable {let name:String,browser_download_url:String;let size:UInt64}
    }
}

enum UpdateNotice:Equatable {
    case available(AvailableUpdate)
    case information(String,String)
}
enum UpdateChoice {case openRelease,later,skip}

@MainActor final class AppUpdateChecker:NSObject,ObservableObject {
    @Published private(set) var checking=false
    @Published private(set) var automatic:Bool
    private let defaults:UserDefaults
    private let current:String
    private let client:GitHubUpdateClient
    private let now:()->Date
    private let canPresent:()->Bool
    private let presenter:(UpdateNotice,@escaping(UpdateChoice)->Void)->Void
    private let open:(URL)->Void
    private var timer:Timer?
    private var task:Task<Void,Never>?
    private var observations:Set<AnyCancellable>=[]
    private var pending:(notice:UpdateNotice,manual:Bool)?
    private var presenting=false,scheduled=false,stopped=false
    static let automaticKey="AudioChain.updates.automatic"
    static let attemptKey="AudioChain.updates.lastAttempt"
    static let skippedKey="AudioChain.updates.skippedVersion"

    init(current:String=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0",
         defaults:UserDefaults = .standard,client:GitHubUpdateClient=GitHubUpdateClient(),now:@escaping()->Date=Date.init,
         canPresent:@escaping()->Bool,presenter:((UpdateNotice,@escaping(UpdateChoice)->Void)->Void)?=nil,
         open:((URL)->Void)?=nil,window:@escaping()->NSWindow?={nil}) {
        self.current=current;self.defaults=defaults;self.client=client;self.now=now;self.canPresent=canPresent
        self.presenter=presenter ?? {notice,completion in Self.present(notice,window:window(),completion:completion)}
        self.open=open ?? {NSWorkspace.shared.open($0)}
        automatic=defaults.object(forKey:Self.automaticKey) == nil || defaults.bool(forKey:Self.automaticKey)
        super.init()
    }
    func start(model:AudioModel) {
        guard !stopped,timer==nil else {return}
        model.$running.combineLatest(model.$busy).sink {[weak self] _,_ in self?.schedulePresentation()}.store(in:&observations)
        for name in [NSApplication.didBecomeActiveNotification,NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.publisher(for:name).sink {[weak self] _ in self?.schedulePresentation()}.store(in:&observations)
        }
        timer=Timer(timeInterval:3600,repeats:true) {[weak self] _ in
            Task {@MainActor in self?.launch(manual:false)}
        }
        RunLoop.main.add(timer!,forMode:.common)
        launch(manual:false)
    }
    func stop() {stopped=true;task?.cancel();task=nil;timer?.invalidate();timer=nil;observations.removeAll();pending=nil}
    @objc func checkManually() {launch(manual:true)}
    @objc func toggleAutomatic(_ sender:NSMenuItem) {
        automatic.toggle();defaults.set(automatic,forKey:Self.automaticKey);sender.state=automatic ? .on:.off
        if !automatic,pending?.manual == false {pending=nil}
        if automatic {launch(manual:false)}
    }
    private func launch(manual:Bool) {
        guard task==nil,!stopped else {return}
        task=Task {@MainActor [weak self] in
            guard let self else {return}
            await self.check(manual:manual);self.task=nil
        }
    }
    func check(manual:Bool) async {
        guard !checking,!stopped else {return}
        if !manual {
            guard automatic else {return}
            if let last=defaults.object(forKey:Self.attemptKey) as? Date {
                let elapsed=now().timeIntervalSince(last)
                if elapsed>=0 && elapsed<86400 {return}
            }
        }
        checking=true;defer {checking=false}
        defaults.set(now(),forKey:Self.attemptKey)
        do {
            let result=try await client.check(current:current)
            guard !stopped,!Task.isCancelled,manual || automatic else {return}
            switch result {
            case .available(let release):
                if manual || defaults.string(forKey:Self.skippedKey) != release.version {enqueue(.available(release),manual:manual)}
            case .current:
                if manual {enqueue(.information("Установлена актуальная версия","AudioChain \(current). Новых стабильных релизов нет."),manual:true)}
            case .noRelease:
                if manual {enqueue(.information("Релиз пока не опубликован","На GitHub ещё нет доступного стабильного релиза AudioChain."),manual:true)}
            }
        } catch is CancellationError {return}
        catch {
            guard manual,!stopped,!Task.isCancelled else {return}
            let detail:String
            if case UpdateFailure.rateLimited=error {detail="GitHub временно ограничил запросы. Повторите позже."}
            else if case UpdateFailure.invalidRelease=error {detail="Новый релиз пока не содержит подходящей сборки AudioChain. Повторите позже."}
            else {detail="Проверьте подключение к интернету и повторите позже."}
            enqueue(.information("Не удалось проверить обновления",detail),manual:true)
        }
        schedulePresentation()
    }
    private func enqueue(_ notice:UpdateNotice,manual:Bool) {
        // A periodic result must not replace an explicit check awaiting idle.
        if !manual,pending?.manual == true {return}
        pending=(notice,manual)
    }
    func schedulePresentation() {
        guard !scheduled,!stopped else {return};scheduled=true
        DispatchQueue.main.async {[weak self] in self?.scheduled=false;self?.presentPending()}
    }
    func presentPending() {
        guard !stopped,!presenting,canPresent(),let notice=pending?.notice else {return}
        pending=nil;presenting=true
        presenter(notice) {[weak self] choice in
            guard let self else {return};self.presenting=false
            guard !self.stopped else {return}
            if case .available(let release)=notice {
                if choice == .openRelease {self.open(release.page)}
                if choice == .skip {self.defaults.set(release.version,forKey:Self.skippedKey)}
            }
            self.schedulePresentation()
        }
    }
    private static func present(_ notice:UpdateNotice,window:NSWindow?,completion:@escaping(UpdateChoice)->Void) {
        guard let window else {completion(.later);return}
        let alert=NSAlert();alert.alertStyle = .informational
        switch notice {
        case .available(let release):
            alert.messageText="Доступна AudioChain \(release.version)"
            alert.informativeText="На GitHub опубликована новая версия. Открыть страницу релиза для загрузки? Текущая цепочка останется открыта."
            alert.addButton(withTitle:"Открыть релиз");alert.addButton(withTitle:"Позже");alert.addButton(withTitle:"Пропустить версию")
        case .information(let title,let detail):
            alert.messageText=title;alert.informativeText=detail;alert.addButton(withTitle:"OK")
        }
        alert.beginSheetModal(for:window) {response in
            completion(response == .alertFirstButtonReturn ? .openRelease : response == .alertThirdButtonReturn ? .skip:.later)
        }
    }
}
