import AppKit
import SwiftUI
import Combine

if CommandLine.arguments.contains("--version") {
    print("AudioChain " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")); exit(0)
}

if CommandLine.arguments.contains("--scan-plugins") {
    do { FileHandle.standardOutput.write(try JSONEncoder().encode(PluginCatalog.scan())); exit(0) }
    catch { exit(1) }
}

#if AUDIOCHAIN_DIAGNOSTICS
if CommandLine.arguments.contains("--update-sheet-test") {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runUpdateSheetTest())};app.run();exit(1)
}
if CommandLine.arguments.contains("--update-network-test") {
    let app=NSApplication.shared
    Task {exit(await runLiveUpdateCheck())};app.run();exit(1)
}
if CommandLine.arguments.contains("--update-tests") {
    let app=NSApplication.shared
    Task {@MainActor in exit(await runAppUpdateTests())};app.run();exit(1)
}
if CommandLine.arguments.contains("--audit-refinements") {
    let app=NSApplication.shared
    Task {@MainActor in exit(await runRefinementTests())};app.run();exit(1)
}
if CommandLine.arguments.contains("--workflow-tests") {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runWorkflowTests())};app.run();exit(1)
}
if CommandLine.arguments.contains("--navigation-test") {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runNavigationTest())};app.run();exit(1)
}
if CommandLine.arguments.contains("--au-load-tests") {
    let app=NSApplication.shared
    Task {@MainActor in exit(await runAULoadTests())};app.run();exit(1)
}
if CommandLine.arguments.contains("--signal-diagnosis-tests") {
    do {try runSignalDiagnosisTests();exit(0)} catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--audit-cable-interaction") {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runCableInteractionAudit())}
    app.run();exit(1)
}
if CommandLine.arguments.contains("--audit-movement") {
    let app=NSApplication.shared
    Task {@MainActor in exit(await runMovementAudit())}
    app.run();exit(1)
}
if CommandLine.arguments.contains("--audit-connection-index") {
    do {try runConnectionIndexAudit();exit(0)} catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--audit-control-graph") {
    do {try runControlGraphAudit();exit(0)} catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--audit-device-poll") {
    do {try MainActor.assumeIsolated {try runDevicePollAudit()};exit(0)} catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--audit-pinned-recovery") {
    let app=NSApplication.shared
    Task {@MainActor in exit(await runPinnedRouteRecoveryAudit())}
    app.run();exit(1)
}
if CommandLine.arguments.contains("--display-index-bench") {
    do {try runDisplayIndexBenchmark();exit(0)} catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--ui-meter-lifecycle") {
    let app = NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runMeterLifecycle())}
    app.run();exit(1)
}
if CommandLine.arguments.contains("--ui-profile") {
    let app = NSApplication.shared;app.setActivationPolicy(.regular)
    Task {@MainActor in exit(await runUIProfile())}
    app.run();exit(1)
}
if CommandLine.arguments.contains("--design-ui-tests") {
    _ = NSApplication.shared
    do {try MainActor.assumeIsolated {try runDesignUITests()};exit(0)}
    catch {print("FAIL: \(error)");exit(1)}
}
if CommandLine.arguments.contains("--audit-tone-source") {
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await runAuditToneSource()) }
    app.run(); exit(1)
}
if CommandLine.arguments.contains("--audit-clock-routes") {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    Task { @MainActor in exit(await runAuditClockRoutes()) }
    app.run(); exit(1)
}
if CommandLine.arguments.contains("--audit-src") {
    do { try auditSampleRateConversion(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if CommandLine.arguments.contains("--audit-window-test") {
    _ = NSApplication.shared
    do { try MainActor.assumeIsolated { try runAuditWindowTest() }; exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--audit-editor-churn"), CommandLine.arguments.count > index+1 {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runAuditEditorChurn(name:CommandLine.arguments[index+1])) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audit-devices") {
    do { try printAuditDeviceSnapshot(); exit(0) } catch { print(error); exit(1) }
}
if CommandLine.arguments.contains("--audit-project-tests") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runAuditProjectTests()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audit-state-tests") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runAuditStateTests()) }
    app.run(); exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--audit-plugin"), CommandLine.arguments.count > index+1 {
    do { try runAuditPlugin(CommandLine.arguments[index+1]); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if CommandLine.arguments.contains("--audit-realtime") {
    let app = NSApplication.shared
    let seconds = CommandLine.arguments.firstIndex(of: "--audit-seconds").flatMap { CommandLine.arguments.count > $0+1 ? Int(CommandLine.arguments[$0+1]) : nil } ?? 120
    Task { @MainActor in exit(await runAuditRealtime(seconds: max(10,min(seconds,600)))) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audit-scan-stall") { Thread.sleep(forTimeInterval: 60); exit(0) }
if CommandLine.arguments.contains("--audit-scan-tests") {
    let app = NSApplication.shared
    Task { exit(await runAuditScanTests()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audit-signals") {
    do { try runAuditSignals(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if CommandLine.arguments.contains("--audit-live-meters") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runAuditMeterLive()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audit-regressions") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runAuditRegressions()) }
    app.run(); exit(1)
}
if CommandLine.arguments.contains("--audit-graph-bench") {
    do { try runGraphAuditBenchmark(); exit(0) } catch { print(error); exit(1) }
}

if let index = CommandLine.arguments.firstIndex(of: "--config-routing-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runConfigRoutingTest(path: CommandLine.arguments[index + 1])) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--session-history-test") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runCompactSessionTests()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--parallel-model-test") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runParallelModelTest()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--generator-test") {
    do { try runGeneratorTest(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}


if CommandLine.arguments.contains("--capture-level-test") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runCaptureLevelTest()) }
    app.run(); exit(1)
}
if CommandLine.arguments.contains("--editor-lifecycle-test") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runEditorLifecycleProbe()) }
    app.run(); exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--saved-chain-test"), CommandLine.arguments.count > index + 1 {
    do { try runSavedChainTests(path: CommandLine.arguments[index + 1]); exit(0) }
    catch { print("FAIL: \(error)"); exit(1) }
}

if let index = CommandLine.arguments.firstIndex(of: "--transport-probe"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in exit(await runTransportProbe(bundleID: CommandLine.arguments[index + 1])) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--buffer-test") {
    let app = NSApplication.shared
    Task { @MainActor in exit(await runHardwareBufferTest()) }
    app.run(); exit(1)
}

if CommandLine.arguments.contains("--audio-processes") {
    for app in NSWorkspace.shared.runningApplications {
        guard let id = app.bundleIdentifier,
              id.localizedCaseInsensitiveContains("yandex") || (app.localizedName ?? "").localizedCaseInsensitiveContains("яндекс") else { continue }
        let selected = AudioProcesses.selected(bundleID: id)
        print("\(app.localizedName ?? id): \(id); audioProcesses=\(selected.ids); bundles=\(selected.bundles)")
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--tap-probe"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        let code = await runTapProbe(bundleID: CommandLine.arguments[index + 1])
        exit(code)
    }
    app.run(); exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--plugin-editor-test"), CommandLine.arguments.count > index + 1 {
    do { try runPluginEditorTests(matching: CommandLine.arguments[index + 1], original: CommandLine.arguments.contains("--original-editor")); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--block-settings-test") {
    _ = NSApplication.shared
    do {
        try MainActor.assumeIsolated {
            let model = AudioModel()
            let source = model.session.blocks.first { $0.kind == .source }!.id
            let output = model.session.blocks.first { $0.kind == .output }!.id
            model.openEditor(source); model.openEditor(output); model.openEditor(source)
            let windows = NSApp.windows.filter { $0.title == "Источник" || $0.title == "Выход" }
            try check(windows.count == 2 && windows.allSatisfy { $0.contentViewController != nil }, "Settings windows must open and be reused")
            windows.forEach { $0.close() }
        }
        print("PASS: source/output settings windows open and repeated open reuses window"); exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let host = MainActor.assumeIsolated {
        let model = AudioModel()
        if CommandLine.arguments.contains("--compact-demo") {
            let block = Block(kind: .effect, name: "Ozone Equalizer", x: 202, y: 76,
                component: ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple))
            model.session.blocks.append(block)
            try? model.session.insertBeforeOutput(block.id)
            model.arrange()
        }
        if CommandLine.arguments.contains("--meter-demo") {
            model.inputLevels = StereoLevels(left: -18, right: -24)
            model.outputLevels = StereoLevels(left: -6, right: 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audit-preview-case"), CommandLine.arguments.count > index+1 { configureAuditPreview(model, scenario: CommandLine.arguments[index+1]) }
        let zoom = CommandLine.arguments.firstIndex(of: "--preview-zoom").flatMap { CommandLine.arguments.count > $0+1 ? Double(CommandLine.arguments[$0+1]) : nil } ?? 100
        if CommandLine.arguments.contains("--preview-running") {
            model.running = true
            model.status = "AU-цепочка · 48000 Гц · Mastering SRC · буфер 512"
            model.transportStatus = "Синхронизация: +0.0 ppm · очередь: 2175 · подрывы: 0 · потеряно: 0"
        }
        return NSHostingView(rootView: ContentView(model: model, initialZoom: zoom/100,
            initialLibrary: CommandLine.arguments.contains("--preview-library"),
            initialDiagnostics: CommandLine.arguments.contains("--preview-diagnostics"),
            initialSelectedWire: CommandLine.arguments.contains("--preview-selected-wire") ? model.session.wires.first : nil,
            initialMap:CommandLine.arguments.contains("--preview-map")))
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CommandLine.arguments.contains("--small-window") ? 640 : 780, height: CommandLine.arguments.contains("--small-window") ? 320 : 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: .darkAqua)
    window.display(); host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let oneX = CommandLine.arguments.contains("--preview-1x") ? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: Int(host.bounds.width)*4, bitsPerPixel: 32) : nil
    if let bitmap = oneX ?? host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Preview saved"); exit(0) }
            catch { fputs("\(error)\n", stderr) }
        }
    }
    exit(1)
}
#endif

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var model: AudioModel?
    var updateChecker:AppUpdateChecker?
    private var updateMenuObservation:AnyCancellable?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updateChecker?.stop()
        Task { @MainActor in
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AudioModel(); self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 640, height: 320)
        window.title = "AudioChain \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"; window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let checker=AppUpdateChecker(canPresent:{[weak self,weak model] in
            guard let model else {return false}
            return !model.running && !model.busy && NSApp.isActive && NSApp.modalWindow == nil && self?.window?.isVisible == true
        },window:{[weak window] in window});updateChecker=checker
        let appMenu = NSMenu()
        let checkItem=appMenu.addItem(withTitle:"Проверить обновления…",action:#selector(AppUpdateChecker.checkManually),keyEquivalent:"")
        checkItem.target=checker
        updateMenuObservation=checker.$checking.receive(on:RunLoop.main).sink {checking in
            checkItem.title=checking ? "Проверка обновлений…":"Проверить обновления…"
        }
        let autoItem=appMenu.addItem(withTitle:"Проверять обновления автоматически",action:#selector(AppUpdateChecker.toggleAutomatic(_:)),keyEquivalent:"")
        autoItem.target=checker;autoItem.state=checker.automatic ? .on:.off
        appMenu.addItem(.separator());appMenu.addItem(withTitle: "Quit AudioChain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); menu.addItem(editItem); let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; NSApp.mainMenu = menu
        Task { @MainActor in
            if let index = CommandLine.arguments.firstIndex(of: "--load-session"), CommandLine.arguments.count > index + 1 {
                await model.load(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]), remember: true)
            } else {
                await model.restoreLastSession(migrationURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("My Chain.audiochain.json"))
            }
            if let index = CommandLine.arguments.firstIndex(of: "--open-plugin-editor") ?? CommandLine.arguments.firstIndex(of: "--add-plugin"), CommandLine.arguments.count > index + 1,
               let plugin = model.plugins.first(where: { $0.name == CommandLine.arguments[index + 1] }) {
                await model.add(plugin); model.arrange()
            }
            if CommandLine.arguments.contains("--browser-source") {
                await model.refreshApps()
                if let browser = model.applications.first(where: { $0.id == "ru.yandex.desktop.yandex-browser" }) {
                    model.session.inputKind = .application; model.session.applicationBundleID = browser.id
                }
            }
            if CommandLine.arguments.contains("--system-source") { model.session.inputKind = .system }
            if CommandLine.arguments.contains("--open-plugin-editor"), let selected = model.selected { model.openEditor(selected) }
            if CommandLine.arguments.contains("--source-settings"), let source = model.session.blocks.first(where: { $0.kind == .source }) { model.openEditor(source.id) }
            checker.start(model:model)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.appearance = NSAppearance(named: .darkAqua)
app.setActivationPolicy(.regular)
let delegate = ApplicationDelegate(); app.delegate = delegate
app.run()
