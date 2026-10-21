import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CoreAudioKit

@MainActor private final class EditorUnitRequest {
    let unit: AVAudioUnit
    init(_ unit: AVAudioUnit) { self.unit = unit }
}

struct AppChoice: Identifiable { let id: String; let name: String }

@MainActor final class AudioModel: ObservableObject {
    @Published var session = Session.empty { didSet { cachedActiveIDs = nil;cachedPlaybackRoute=nil } }
    private var cachedActiveIDs: Set<UUID>?
    private var cachedPlaybackRoute:Result<[Block],Error>?
    func playbackRoute() throws -> [Block] {
        if let cachedPlaybackRoute {return try cachedPlaybackRoute.get()}
#if AUDIOCHAIN_DIAGNOSTICS
        diagnosticPlaybackRouteBuilds += 1
#endif
        let result=Result {try session.orderedChain()}
        cachedPlaybackRoute=result
        return try result.get()
    }
    let editHistory = EditHistory()
    private var moveEntry:GraphEditEntry?
    private func editEntry(_ name:String) -> GraphEditEntry {GraphEditEntry(state:GraphEditState(session),selection:selected,name:name)}
    private func recordEdit(_ entry:GraphEditEntry) {
        if entry.state != GraphEditState(session) {editHistory.record(entry)}
    }
    func beginMove() {if !running && !busy && moveEntry == nil {moveEntry=editEntry("Перемещение")}}
    func endMove() {if let entry=moveEntry {moveEntry=nil;recordEdit(entry)}}
    func undoEdit() async {await applyHistory(redo:false)}
    func redoEdit() async {await applyHistory(redo:true)}
    private func applyHistory(redo:Bool) async {
        guard !running,!busy,!shuttingDown else {return}
        endMove()
        guard let target = redo ? editHistory.redoTarget : editHistory.undoTarget else {return}
        busy=true;defer {busy=false}
        do {
            let candidate=target.state.applying(to:session)
            try candidate.validateEditingGraph()
            var current=editEntry(target.name)
            let targetIDs=Set(candidate.blocks.map(\.id))
            let targetEffects=Set(candidate.blocks.filter {$0.kind == .effect}.map(\.id))
            for index in current.state.blocks.indices where !targetIDs.contains(current.state.blocks[index].id) {
                if let state=units[current.state.blocks[index].id]?.auAudioUnit.fullState {
                    current.state.blocks[index].state=try PropertyListSerialization.data(fromPropertyList:state,format:.binary,options:0)
                }
            }
            var restored=units.filter {id,_ in targetEffects.contains(id)}
            let token=runToken
            for block in candidate.blocks where block.kind == .effect && restored[block.id] == nil {
                guard let component=block.component else {throw AudioFailure("Нет идентификатора AU.")}
                let unit=try await instantiate(component,name:block.name)
                guard !shuttingDown,runToken==token else {return}
                if let data=block.state {
                    guard let state=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any] else {throw AudioFailure("Некорректное состояние AU.")}
                    try PluginHost.prepareEditor(unit);unit.auAudioUnit.fullState=state
                }
                restored[block.id]=unit
            }
            editorRequests=editorRequests.filter {targetEffects.contains($0.key)}
            for id in Array(editors.keys) where !targetIDs.contains(id) {
                editors[id]?.close();editors[id]?.contentViewController=nil;editors[id]=nil
            }
            units=restored;session=candidate
            for block in candidate.blocks where block.kind == .effect {units[block.id]?.auAudioUnit.shouldBypassEffect=block.bypass}
            selected=target.selection.flatMap {targetIDs.contains($0) ? $0:nil}
            pendingPort=nil;lastRemovedWire=nil;graphInvalidated=true
            editHistory.commit(redo:redo,current:current)
            status=(redo ? "Повторено: " : "Отменено: ")+target.name
        } catch {status="Не удалось отменить/повторить: \(error.localizedDescription)"}
    }
#if AUDIOCHAIN_DIAGNOSTICS
    private(set) var diagnosticActiveRouteBuilds = 0
    private(set) var diagnosticPlaybackRouteBuilds = 0
#endif
    func moveBlock(_ id: UUID, to point: CGPoint) {
        guard !running, !busy, point.x.isFinite, point.y.isFinite,
              let index = session.blocks.firstIndex(where: {$0.id == id}) else {return}
        var block = session.blocks[index]
        let validBefore = block.x.isFinite && block.y.isFinite && block.x >= 0 && block.y >= 0
        let x = max(24,point.x), y = max(70,point.y)
        guard block.x != x || block.y != y else {return}
        block.x = x; block.y = y
        let previousActive = cachedActiveIDs
        let entry=moveEntry == nil ? editEntry("Перемещение") : nil
        // One published mutation per gesture event. A move between valid
        // coordinates cannot change validation or the active ancestor set.
        session.blocks[index] = block
        if validBefore {cachedActiveIDs = previousActive}
        if let entry {recordEdit(entry)}
    }
    @Published var devices: [AudioDevice] = []
    @Published var plugins: [PluginChoice] = []
    @Published var applications: [AppChoice] = []
    @Published var running = false {didSet {
        if running != oldValue {telemetry.playbackRunning=running}
        if running && !oldValue {
            monitorStarted=ProcessInfo.processInfo.systemUptime;lastInputActivity=0;lastOutputActivity=0
            telemetry.hasRunMeasurements=true
            telemetry.auLoads=[];telemetry.underruns=0;telemetry.dropped=0;telemetry.pcmErrors=0
        }
    }}
    @Published var busy = false
    @Published var status = "Готово. Выберите источник и выход."
    let telemetry = DisplayTelemetry()
    var transportStatus: String {
        get {telemetry.transportStatus}
        set {if telemetry.transportStatus != newValue {telemetry.transportStatus = newValue}}
    }
    private var transportTimer: Timer?
    let meters = DisplayMeters()
    var inputLevels: StereoLevels {
        get { meters.input }
        set { if meters.input != newValue { meters.input = newValue } }
    }
    var outputLevels: StereoLevels {
        get { meters.output }
        set { if meters.output != newValue { meters.output = newValue } }
    }
    private var levelTimer: Timer?
    private var auProbes:[UUID:AUProbe]=[:]
    private var boundaryProbes:[AUProbe]=[]
    private var monitorStarted=0.0,lastInputActivity=0.0,lastOutputActivity=0.0
    private var pcmFault=false
    private var lastPCMErrorAt=0.0
    private func installAUProbes(_ route:[Block]) {
        // Exclude the source/SRC pull from the first effect's own timing.
        if let inputSRC,let probe=AUProbe(inputSRC) {boundaryProbes.append(probe)}
        for block in route where block.kind == .effect {
            if let unit=units[block.id],let probe=AUProbe(unit) {auProbes[block.id]=probe}
        }
    }
    func samplePlaybackTelemetry(includeStopped:Bool=false) {
        let now=ProcessInfo.processInfo.systemUptime
        var route:[Block]=[],issue:String?
        do {route=try playbackRoute()} catch {issue=error.localizedDescription}
        let active=Set(route.map(\.id))
        if running || includeStopped {
            let loads=session.blocks.filter {$0.kind == .effect}.map {block in
                auProbes[block.id]?.sample(block,cumulative:includeStopped) ?? AULoad(id:block.id,name:block.name,bypass:block.bypass,active:active.contains(block.id))
            }
            if loads != telemetry.auLoads {telemetry.auLoads=loads}
            let stats=transportStatistics
            let under=stats?.underruns ?? 0,drop=stats?.dropped ?? 0
            let errors=capture?.directStats?.invalidBlocks ?? 0
            if telemetry.underruns != under {telemetry.underruns=under}
            if telemetry.dropped != drop {telemetry.dropped=drop}
            if telemetry.pcmErrors != errors {telemetry.pcmErrors=errors}
        }
        let loads=running ? telemetry.auLoads : []
        let renderError=loads.first {$0.errors>0}?.name
        let waitingIDs=Set(loads.filter(\.waiting).map(\.id))
        let renderWaiting=route.first {waitingIDs.contains($0.id)}?.name
        let health=SignalHealth.evaluate(running:running,busy:busy,routeError:issue,muted:outputGain==0,fault:pcmFault,
            inputRecent:lastInputActivity>0 && now-lastInputActivity<2,
            outputRecent:lastOutputActivity>0 && now-lastOutputActivity<2,warmed:now-monitorStarted>2,
            generator:route.contains {$0.component?.isGenerator == true && !$0.bypass},renderError:renderError,
            renderMissing:now-monitorStarted>3 ? loads.first {!$0.bypass && $0.active && $0.calls==0 && auProbes[$0.id] != nil}?.name:nil,
            renderWaiting:renderWaiting)
        if health != telemetry.health {telemetry.health=health}
    }
    private var inputDisplay = MeterBallistics(), outputDisplay = MeterBallistics()
    private var meterTaps: [AVAudioNode] = []
    private func startMeters(input: LevelMeter, output: LevelMeter) {
        levelTimer?.invalidate()
        inputDisplay = MeterBallistics(); outputDisplay = MeterBallistics()
        levelTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                let inputSample=input.read()
                self.inputLevels = self.inputDisplay.tick(inputSample)
                let measured = output.read()
                // Direct file/device taps precede the HAL client's linear fader.
                let postFader = self.directGraphActive && self.capture == nil ? measured.applyingGain(self.outputGain) : measured
                self.outputLevels = self.outputDisplay.tick(postFader)
                let now=ProcessInfo.processInfo.systemUptime
                if max(inputSample.left,inputSample.right) > -100 {self.lastInputActivity=now}
                if max(postFader.left,postFader.right) > -100 {self.lastOutputActivity=now}
                if [inputSample.left,inputSample.right,postFader.left,postFader.right].contains(where:{$0 == .infinity || $0.isNaN}) {self.lastPCMErrorAt=now}
                self.pcmFault=self.lastPCMErrorAt>0 && now-self.lastPCMErrorAt<2
            }
        }
        RunLoop.main.add(levelTimer!, forMode: .common)
    }
    @Published var selected: UUID?
    @Published var pendingPort: UUID?
    @Published private(set) var lastRemovedWire: Wire?
    @Published var actualOutputBuffer: UInt32?
    @Published var actualInputBuffer: UInt32?
    @Published var volume: Float = 1 { didSet { applyOutputLevel() } }
    private var directGraphActive = false
    private var outputGain: Float { session.outputMuted == true ? 0 : volume }
    func applyOutputLevel(preparingGraph: Bool = false) {
        guard running || preparingGraph else { return }
        if let capture, capture.directStats != nil {
            capture.setOutputGain(outputGain)
            if let format = capture.format {
                bitPerfectActive = outputGain == 1
                status = "\(bitPerfectActive ? "Бит в бит (PCM)" : "PCM · уровень \(Int(outputGain * 100))%") · \(Int(format.sampleRate)) Гц · без SRC · выход: \(outputSummary)"
            }
            return // The unused AVAudioEngine must not create/wire its lazy main mixer.
        }
        if directGraphActive, let unit = engine?.outputNode.audioUnit {
            AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, diagnosticSilence ? 0 : outputGain, 0)
        } else { mainMixerCache?.outputVolume = outputGain }
    }
    var usesDirectPCM: Bool { directGraphActive || capture?.directStats != nil }
    var diagnosticPreparationDelay: UInt64 = 0 // Test-only slow AU preparation probe.
    var diagnosticSilence = false // Test-only; never persisted or enabled by the UI.
    @Published var bitPerfectActive = false
    var activeBlockIDs: Set<UUID> {
        if let cachedActiveIDs { return cachedActiveIDs }
#if AUDIOCHAIN_DIAGNOSTICS
        diagnosticActiveRouteBuilds += 1
#endif
        let ids = Set(((try? playbackRoute()) ?? []).map(\.id))
        cachedActiveIDs = ids
        return ids
    }
    var hasActiveEffects: Bool { !session.canUseDirectPCM((try? playbackRoute()) ?? []) }
    var sourceSummary: String {
        switch session.inputKind {
        case .application: return applications.first(where: { $0.id == session.applicationBundleID })?.name ?? (session.applicationBundleID.isEmpty ? "Приложение не выбрано" : session.applicationBundleID)
        case .device:
            if session.inputUID.isEmpty, let id = try? Devices.defaultInput() { return devices.first(where: { $0.id == id })?.name ?? "Системный вход" }
            return devices.first(where: { $0.uid == session.inputUID })?.name ?? "Вход отключён"
        case .system: return "Системный звук"
        case .file: return session.filePath.isEmpty ? "Файл не выбран" : URL(fileURLWithPath: session.filePath).lastPathComponent
        }
    }
    var outputSummary: String {
        if session.outputUID.isEmpty, let id = try? Devices.defaultOutput() { return "Системный → " + Devices.string(id, kAudioObjectPropertyName) }
        return devices.first(where: { $0.uid == session.outputUID })?.name ?? "Выход отключён"
    }
    private var units: [UUID: AVAudioUnit] = [:]
    func unitForDiagnostics(_ id: UUID) -> AVAudioUnit? { units[id] }
    private var generatorGates: [UUID: AVAudioMixerNode] = [:]
    private var engine: AVAudioEngine?
    private var mainMixerCache: AVAudioMixerNode?
    private func mainMixer(for graph: AVAudioEngine) -> AVAudioMixerNode {
        if let mainMixerCache { return mainMixerCache }
        let mixer = graph.mainMixerNode
        mainMixerCache = mixer
        return mixer
    }
    private var capture: ProcessCapture?
    private var clockBuffer: AudioQueueBuffer?
    private var inputSRC: AVAudioUnit?
    private var outputSRC: AVAudioUnit?
    var transportStatistics: ACRingStats? { capture?.statistics ?? clockBuffer?.statistics }
    var outputRenderUnitForDiagnostics: AudioUnit? { outputSRC?.audioUnit }
    var currentOutputDeviceForDiagnostics: AudioDeviceID? { engine.flatMap { Devices.currentDevice(for: $0.outputNode) } }
#if AUDIOCHAIN_DIAGNOSTICS
    func diagnosticCheckOutputRoute() {checkOutputRoute()}
    var diagnosticMixerCount: Int { engine?.attachedNodes.filter { $0 is AVAudioMixerNode }.count ?? 0 }
    var diagnosticClientGain: Float? {
        guard let unit = engine?.outputNode.audioUnit else { return nil }
        var value: AudioUnitParameterValue = 0
        guard AudioUnitGetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, &value) == noErr else { return nil }
        return value
    }
#endif
    private var player: AVAudioPlayerNode?
    private var runToken = UUID()
    private var observer: NSObjectProtocol?
    struct DeviceBinding: Equatable {
        let id: AudioDeviceID
        let uid: String
        let rate: Double
        let channels: Int
        init(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws {
            self.id = id
            uid = Devices.string(id, kAudioDevicePropertyDeviceUID)
            rate = try Devices.sampleRate(id)
            channels = Devices.channels(id, scope: scope)
        }
    }
    private var outputBinding: DeviceBinding?
    private var inputBinding: DeviceBinding?
    private var graphInvalidated = false
    private var playbackRequested = false
    private var routeRecoveryTask: Task<Void, Never>?
    private func checkOutputRoute() {
        guard running, !busy, let outputBinding else { return }
        // A pinned route already has a HAL ID. Read its live UID/rate/channels
        // below so disconnects and ID reuse still trigger recovery. Enumerating
        // every unrelated input/output twice a second is unnecessary.
        let id = session.outputUID.isEmpty ? (try? Devices.defaultOutput()) :
            (session.outputUID == outputBinding.uid ? outputBinding.id : nil)
        guard let id, let current = try? DeviceBinding(id, scope: kAudioObjectPropertyScopeOutput), current == outputBinding else {
            recoverOutputRoute(); return
        }
    }
    private func recoverOutputRoute() {
        graphInvalidated = true
        guard playbackRequested, !busy, routeRecoveryTask == nil else { return }
        routeRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.busy = true
            await self.stop(cancelRecovery: false)
            self.status = "Аудиоустройство изменилось. Восстанавливаю цепочку…"
            do { try await Task.sleep(nanoseconds: 600_000_000) }
            catch { self.busy = false; return }
            guard self.playbackRequested, !Task.isCancelled else { self.busy = false; return }
            self.busy = false
            await self.start()
            self.routeRecoveryTask = nil
        }
    }
    func updateSystemExclusions() {
        guard session.inputKind == .system else { return }
        capture?.setSystemExclusions(session.systemExcludedBundleIDs ?? [])
    }
    private var configurationObserverToken = UUID()
    private func liveBindingsUnchanged(_ graph: AVAudioEngine) -> Bool {
        guard graph.isRunning, let outputBinding,
              Devices.currentDevice(for:graph.outputNode) == outputBinding.id,
              (try? DeviceBinding(outputBinding.id,scope:kAudioObjectPropertyScopeOutput)) == outputBinding,
              graph.outputNode.inputFormat(forBus:0).sampleRate == outputBinding.rate else {return false}
        if let inputBinding {
            guard Devices.currentDevice(for:graph.inputNode) == inputBinding.id,
                  (try? DeviceBinding(inputBinding.id,scope:kAudioObjectPropertyScopeInput)) == inputBinding,
                  graph.inputNode.outputFormat(forBus:0).sampleRate == inputBinding.rate else {return false}
        }
        return true
    }
    private func observeConfiguration(_ graph: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let token = UUID(); configurationObserverToken = token
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.configurationObserverToken == token, !self.busy else { return }
                // Enabling input can post a delayed configuration notification
                // after start() has completed. Rebuilding that unchanged running
                // graph creates a restart loop, since each restart posts it again.
                if self.running, let liveGraph = self.engine, self.liveBindingsUnchanged(liveGraph) {return}
                self.graphInvalidated = true
                self.refreshDevices()
                if self.running {
                    self.recoverOutputRoute()
                }
            }
        }
    }
#if AUDIOCHAIN_DIAGNOSTICS
    var diagnosticEditorLoader:((AVAudioUnit,@escaping(NSViewController?)->Void)->Void)?
#endif
    private var editors: [UUID: NSWindow] = [:]
    private var editorRequests:[UUID:UUID]=[:]
    private var shuttingDown = false
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true; busy = true
        editorRequests.removeAll()
        pluginScanTask?.cancel()
        await stop()
        monitoringTimer?.invalidate(); monitoringTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        configurationObserverToken = UUID()
        for window in editors.values { window.close(); window.contentViewController = nil }
        editors.removeAll()
        // Let native display-link/timer callbacks finish while their DSP still exists.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let engine {
            for unit in units.values where engine.attachedNodes.contains(unit) {
                engine.disconnectNodeInput(unit); engine.disconnectNodeOutput(unit); engine.detach(unit)
            }
        }
        engine = nil; mainMixerCache = nil; generatorGates.removeAll()
        for unit in units.values { if unit.auAudioUnit.renderResourcesAllocated { unit.auAudioUnit.deallocateRenderResources() } }
        units.removeAll()
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    var resources: ResourceSnapshot {
        get {telemetry.resources}
        set {if telemetry.resources != newValue {telemetry.resources = newValue}}
    }
    var blockLatencies: [UUID:Double] {
        get {telemetry.blockLatencies}
        set {if telemetry.blockLatencies != newValue {telemetry.blockLatencies = newValue}}
    }
    var routeLatency: Double? {
        get {telemetry.routeLatency}
        set {if telemetry.routeLatency != newValue {telemetry.routeLatency = newValue}}
    }
    private var monitoringTimer: Timer?
    private var resourceMonitor = ResourceMonitor()
    private var latencyOutputID: AudioDeviceID?
    private var latencyInputID: AudioDeviceID?
    private var latencySourceRate = 0.0
    init() {
        refreshDevices(); refreshPlugins()
        resources = resourceMonitor.sample()
        monitoringTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resources = self.resourceMonitor.sample()
                self.updateLatencies()
                self.checkOutputRoute()
                self.samplePlaybackTelemetry()
            }
        }
        RunLoop.main.add(monitoringTimer!, forMode: .common)
    }
    func latencyText(_ block: Block) -> String {
        guard running, activeBlockIDs.contains(block.id) else { return "Задержка: —" }
        guard let value = blockLatencies[block.id] else { return "Задержка: н/д" }
        return String(format: block.kind == .effect ? "AU: %.2f мс" : "≈ %.2f мс", value)
    }
    private func updateLatencies() {
        guard running, let route = try? playbackRoute() else { routeLatency = nil; return }
        var values: [UUID: Double] = [:]
        for block in route {
            if block.kind == .effect, let unit = units[block.id] {
                let seconds = unit.auAudioUnit.latency
                if seconds.isFinite && seconds >= 0 { values[block.id] = seconds * 1000 }
            } else if block.kind == .output, let id = latencyOutputID {
                values[block.id] = Devices.latencyMilliseconds(id, scope: kAudioObjectPropertyScopeOutput, buffer: actualOutputBuffer ?? 0)
                values[block.id] = (values[block.id] ?? 0) + (outputSRC?.auAudioUnit.latency ?? 0) * 1000
            } else if block.kind == .source {
                if let id = latencyInputID {
                    values[block.id] = (Devices.latencyMilliseconds(id, scope: kAudioObjectPropertyScopeInput, buffer: actualInputBuffer ?? 0) ?? 0) + Double(clockBuffer?.statistics.queued ?? 0) * 1000 / max(latencySourceRate, 1)
                } else if capture != nil && latencySourceRate > 0 {
                    let queue = bitPerfectActive ? 0 : Double(capture?.statistics.queued ?? 0)
                    values[block.id] = (queue + Double(actualInputBuffer ?? 0)) * 1000 / latencySourceRate
                } else { values[block.id] = 0 } // File player, no capture queue.
                values[block.id] = (values[block.id] ?? 0) + (inputSRC?.auAudioUnit.latency ?? 0) * 1000
            }
        }
        blockLatencies = values
        routeLatency = RouteLatency.total(route:route,wires:session.wires,values:values)
    }
    func refreshDevices() { devices = Devices.all() }
    func refreshPlugins() { plugins = PluginCatalog.scan() }
    @Published var refreshingPlugins = false
    private var pluginScanTask: Task<[PluginChoice], Error>?
    func cancelPluginRescan() { pluginScanTask?.cancel() }
    func rescanPlugins() async {
        guard !refreshingPlugins, !shuttingDown else { return }
        refreshingPlugins = true
        let task = Task { try await PluginCatalog.rescan() }
        pluginScanTask = task
        defer { refreshingPlugins = false; pluginScanTask = nil }
        do {
            let result = try await task.value
            guard !shuttingDown else { return }
            plugins = result
            status = "Список AU обновлён: \(plugins.count) компонентов."
        } catch is CancellationError { if !shuttingDown { status = "Обновление AU отменено." } }
        catch { if !shuttingDown { status = error.localizedDescription } }
    }
    func refreshApps() async {
        guard !shuttingDown else { return }
            var seen = Set<String>()
            applications = NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      seen.insert(id).inserted else { return nil }
                return AppChoice(id: id, name: app.localizedName ?? id)
            }.sorted { $0.name < $1.name }
            if !running { status = "Список приложений обновлён." }
    }
    private func instantiate(_ component: ComponentID, name: String) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: component.description, options: PluginHost.options(component.description)) { unit, error in
                if let unit { continuation.resume(returning: unit) }
                else { continuation.resume(throwing: AudioFailure("Не удалось загрузить «\(name)»: \(error?.localizedDescription ?? "AU-плагин не ответил.")")) }
            }
        }
    }
    func add(_ plugin: PluginChoice) async {
        guard !running, !busy, !shuttingDown else { return }
        if let reason = plugin.unavailable { status = reason; return }
        busy = true; defer { busy = false }
        do {
            let token = runToken
            let unit = try await instantiate(plugin.component, name: plugin.name)
            guard !shuttingDown, runToken == token else { return }
            let block = Block(kind: .effect, name: plugin.name, x: (session.blocks.map { $0.x + GraphLayout.width(for:$0) }.max() ?? 24) + GraphLayout.gap, y: session.blocks.first(where: { $0.kind == .source })?.y ?? 100, component: plugin.component)
            let entry=editEntry("Добавление AU")
            session.blocks.append(block); units[block.id] = unit; selected = block.id
            recordEdit(entry)
            status = "Добавлен \(plugin.name). Соедините порты блоков."
        } catch { status = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        guard !running, !busy, session.blocks.first(where: { $0.id == id })?.kind == .effect else { return }
        var entry=editEntry("Удаление AU")
        if let index=entry.state.blocks.firstIndex(where:{$0.id==id}),let state=units[id]?.auAudioUnit.fullState {
            do {entry.state.blocks[index].state=try PropertyListSerialization.data(fromPropertyList:state,format:.binary,options:0)}
            catch {status="Не удалось сохранить AU для отмены: \(error.localizedDescription)";return}
        }
        session.wires.removeAll { $0.from == id || $0.to == id }
        editorRequests[id]=nil
        session.blocks.removeAll { $0.id == id }; editors[id]?.close();editors[id]?.contentViewController=nil;editors[id]=nil; units[id] = nil
        if lastRemovedWire?.from == id || lastRemovedWire?.to == id { lastRemovedWire = nil }
        selected = nil; pendingPort = nil
        recordEdit(entry)
    }
    func insertBeforeOutput(_ id: UUID) {
        guard !running, !busy else { return }
        let entry=editEntry("Подключение AU")
        do { try session.insertBeforeOutput(id);recordEdit(entry); pendingPort = nil; status = "Плагин подключён перед выходом. Можно нажать Старт." }
        catch { status = error.localizedDescription }
    }
    func disconnect(_ wire: Wire) {
        guard !running, !busy else { return }
        guard session.wires.contains(wire) else { return }
        let entry=editEntry("Удаление провода")
        session.wires.removeAll { $0 == wire }
        lastRemovedWire = wire
        pendingPort = nil
        status = "Соединение удалено."
        recordEdit(entry)
    }
    func restoreLastConnection() {
        guard !running, !busy, let wire = lastRemovedWire else { return }
        let entry=editEntry("Восстановление провода")
        do { try session.connect(from: wire.from, to: wire.to);recordEdit(entry); lastRemovedWire = nil; status = "Соединение восстановлено." }
        catch { status = error.localizedDescription }
    }
    func inputPort(_ id: UUID) {
        guard !running, !busy, let from = pendingPort else { return }
        let entry=editEntry("Соединение")
        do { try session.connect(from: from, to: id);recordEdit(entry); status = "Соединение создано." }
        catch { status = error.localizedDescription }
        pendingPort = nil
    }
    func bypass(_ id: UUID) {
        guard !busy, !shuttingDown, session.blocks.contains(where: { $0.id == id && $0.kind == .effect }) else { return }
        if running && (bitPerfectActive || capture?.directStats != nil || directGraphActive) { status = "Для включения плагина нажмите Стоп, затем Старт."; return }
        guard let index = session.blocks.firstIndex(where: { $0.id == id }) else { return }
        let entry=editEntry("Обход AU")
        session.blocks[index].bypass.toggle()
        recordEdit(entry)
        if let gate = generatorGates[id] { gate.outputVolume = session.blocks[index].bypass ? 0 : 1 }
        else { units[id]?.auAudioUnit.shouldBypassEffect = session.blocks[index].bypass }
    }
    func openEditor(_ id: UUID, restoring frame:NSRect? = nil) {
        guard !shuttingDown else { return }
        guard let block = session.blocks.first(where: { $0.id == id }) else { return }
        if block.kind != .effect {
            if let window = editors[id] { if let frame {window.setFrame(frame,display:true)};window.makeKeyAndOrderFront(nil);return }
            showEditor(NSHostingController(rootView: BlockSettingsView(model: self, kind: block.kind)), for: id, restoring:frame)
            if block.kind == .source { Task { await refreshApps() } }
            return
        }
        guard let unit = units[id] else { return }
        if let window = editors[id] { if let frame {window.setFrame(frame,display:true)};window.makeKeyAndOrderFront(nil);return }
        var asynchronous=PluginHost.isV3(unit.audioComponentDescription)
#if AUDIOCHAIN_DIAGNOSTICS
        if diagnosticEditorLoader != nil {asynchronous=true}
#endif
        if !asynchronous {
            do {
                try PluginHost.prepareEditor(unit)
                if let editor = try PluginHost.legacyEditor(unit.audioUnit) {
                    showEditor(LegacyEditorController(editor: editor, audioUnit: unit), for: id, restoring:frame)
                    status = "Открыт собственный AUv2-редактор."
                } else {
                    showEditor(NSHostingController(rootView: ParameterEditor(unit: unit)), for: id, restoring:frame)
                    status = "У плагина нет Cocoa-редактора; открыт редактор параметров."
                }
            } catch { status = "Не удалось открыть редактор: \(error.localizedDescription)" }
            return
        }
        guard editorRequests[id] == nil else {return}
        let token=UUID();editorRequests[id]=token
        let request = EditorUnitRequest(unit)
        let completion:(NSViewController?)->Void = { [weak self] controller in
            Task { @MainActor in
                guard let self,self.editorRequests[id]==token else {return}
                self.editorRequests[id]=nil
                guard !self.shuttingDown,self.units[id] === request.unit else {return}
                let viewController: NSViewController
                if let controller { viewController = controller }
                else {
                    viewController = NSHostingController(rootView: ParameterEditor(unit: request.unit))
                }
                self.showEditor(viewController, for: id, restoring:frame)
            }
        }
#if AUDIOCHAIN_DIAGNOSTICS
        if let diagnosticEditorLoader {diagnosticEditorLoader(unit,completion);return}
#endif
        unit.auAudioUnit.requestViewController {completion($0)}
    }
    private func showEditor(_ controller: NSViewController, for id: UUID, restoring frame:NSRect? = nil) {
        if let window=editors[id] {if let frame {window.setFrame(frame,display:true)};window.makeKeyAndOrderFront(nil);return}
        let window = NSWindow(contentViewController: controller)
        window.title = session.blocks.first(where: { $0.id == id })?.name ?? "AU"
        if session.blocks.first(where: { $0.id == id })?.kind != .effect { window.setContentSize(NSSize(width: 440, height: 300)) }
        window.styleMask.formUnion([.titled, .closable, .resizable])
        window.isReleasedWhenClosed = false
        if window.frame.width < 320 || window.frame.height < 160 { window.setContentSize(NSSize(width: 520, height: 400)) }
        if let frame {window.setFrame(frame,display:false)} else {window.center()}
        window.makeKeyAndOrderFront(nil);editors[id]=window
    }
    private func retireEffectEditors(_ ids: Set<UUID>) -> [UUID: NSRect] {
        var frames: [UUID: NSRect] = [:]
        for id in ids {
            editorRequests[id]=nil
            guard let window = editors.removeValue(forKey: id) else { continue }
            if window.isVisible { frames[id] = window.frame }
            window.close()
            // Destroy the native view before the AU's DSP core can be replaced.
            window.contentViewController = nil
        }
        return frames
    }
    private func restoreEffectEditors(_ frames: [UUID: NSRect]) {
        let savedStatus = status
        for (id, frame) in frames {
            openEditor(id,restoring:frame)
        }
        status = savedStatus
    }
#if AUDIOCHAIN_DIAGNOSTICS
    func diagnosticRebuildEditor(_ id:UUID) {
        let frames=retireEffectEditors([id]);restoreEffectEditors(frames)
    }
#endif
    func start() async {
        guard !running, !busy, !shuttingDown else { return }
        endMove()
        playbackRequested = true
        var editorFrames: [UUID: NSRect] = [:]
        busy = true; defer { restoreEffectEditors(editorFrames); busy = false }
        do {
            guard diagnosticSilence || AudioProcesses.otherActiveHosts().isEmpty else {
                throw AudioFailure("Звук уже обрабатывается в другом окне AudioChain. Нажмите там Стоп, затем запустите эту цепочку.")
            }
            let chain = try session.orderedChain()
            let noEffects = session.canUseDirectPCM(chain)
            let chainIDs = Set(chain.map(\.id))
            let unused = session.blocks.filter { $0.kind == .effect && !chainIDs.contains($0.id) }.count
            let startingToken = runToken
            refreshDevices()
            let outputID: AudioDeviceID
            if !session.outputUID.isEmpty {
                guard let output = devices.first(where: { $0.uid == session.outputUID && $0.outputs > 0 }) else { throw AudioFailure("Выходное устройство отключено. Выберите доступное.") }
                outputID = output.id
            } else { outputID = try Devices.defaultOutput() }
            if let requested = session.bufferFrames { actualOutputBuffer = try await Devices.setBufferFrames(requested, for: outputID) }
            else { actualOutputBuffer = try Devices.bufferFrames(outputID) }
            guard runToken == startingToken else { throw AudioFailure("Запуск отменён.") }
            let requestedOutput = try DeviceBinding(outputID, scope: kAudioObjectPropertyScopeOutput)
            let inputID: AudioDeviceID?
            if session.inputKind == .device && chain.contains(where: { $0.kind == .source }) {
                if session.inputUID.isEmpty { inputID = try Devices.defaultInput() }
                else {
                    guard let input = devices.first(where: { $0.uid == session.inputUID && $0.inputs > 0 }) else { throw AudioFailure("Входное устройство отключено.") }
                    inputID = input.id
                }
            } else { inputID = nil }
            let requestedInput = try inputID.map { try DeviceBinding($0, scope: kAudioObjectPropertyScopeInput) }
            if let previous = engine, graphInvalidated || outputBinding != requestedOutput || inputBinding != requestedInput || Devices.currentDevice(for: previous.outputNode) != outputID || (noEffects && mainMixerCache != nil) {
                // Once input I/O was active, AVAudioEngine retains a device-bound HAL graph.
                // Rebuild that graph for a different output rather than mutating its old HAL AU.
                // Retire native views before replacing DSP; restore state into fresh instances.
                let states = units.mapValues { $0.auAudioUnit.fullState }
                editorFrames.merge(retireEffectEditors(Set(units.keys))) { old, _ in old }
                var replacements: [UUID: AVAudioUnit] = [:]
                for block in session.blocks where block.kind == .effect {
                    guard let component = block.component else { throw AudioFailure("Нет идентификатора AU.") }
                    let unit = try await instantiate(component, name: block.name)
                    guard runToken == startingToken, !shuttingDown else { throw AudioFailure("Запуск отменён.") }
                    if let state = states[block.id] ?? nil {
                        try PluginHost.prepareEditor(unit)
                        unit.auAudioUnit.fullState = state
                    }
                    replacements[block.id] = unit
                }
                units = replacements
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                configurationObserverToken = UUID()
                engine = AVAudioEngine(); mainMixerCache = nil
            }
            let graph = engine ?? AVAudioEngine(); engine = graph
            // Keep AU instances attached across Stop/Start so their native editors
            // continue to address the same initialized DSP core.
            let effectNodes = Set(units.values)
            for node in graph.attachedNodes where !(node is AVAudioIONode) && node !== mainMixerCache && !effectNodes.contains(where: { $0 === node }) {
                graph.disconnectNodeInput(node); graph.disconnectNodeOutput(node); graph.detach(node)
            }
            for unit in units.values where graph.attachedNodes.contains(unit) {
                graph.disconnectNodeInput(unit); graph.disconnectNodeOutput(unit)
            }
            _ = graph.outputNode // Register our HAL client before excluding it from a global tap.
            try Devices.select(outputID, for: graph.outputNode)
            if diagnosticSilence, let outputUnit = graph.outputNode.audioUnit {
                let result = AudioUnitSetParameter(outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0, 0)
                guard result == noErr else { throw AudioFailure("Не удалось заглушить диагностический выход (\(result)).") }
            }
            // The no-effect process path copies HAL PCM within one IOProc on one hardware clock.
            // It never passes through a ring, AVAudioMixer, resampler, fader or plugin.
            if noEffects && (session.inputKind == .application || session.inputKind == .system) {
                let capture = ProcessCapture(); self.capture = capture
                let token = runToken
                capture.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.runToken == token else { return }
                        if self.session.outputUID.isEmpty, (try? Devices.defaultOutput()) != self.outputBinding?.id { self.recoverOutputRoute(); return }
                        await self.stop(); self.status = error.localizedDescription
                    }
                }
                try await capture.start(bundleID: session.inputKind == .application ? session.applicationBundleID : nil,
                                        bufferFrames: session.bufferFrames, passThroughOutput: outputID, diagnosticSilence: diagnosticSilence,
                                        excludedBundleIDs: session.inputKind == .system ? session.systemExcludedBundleIDs ?? [] : [], outputGain: outputGain)
                guard runToken == startingToken, let format = capture.format else { throw AudioFailure("Запуск отменён.") }
                actualInputBuffer = capture.actualBufferFrames
                running = true; bitPerfectActive = outputGain == 1
                latencyOutputID = outputID; latencySourceRate = format.sampleRate; latencyInputID = nil
                updateLatencies()
                if let outputMeter = capture.outputMeter { startMeters(input: capture.inputMeter, output: outputMeter) }
                transportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.running, let stats = capture.directStats else { return }
                        self.transportStatus = "PCM: \(stats.frames) кадров · несовпадений битов: \(stats.mismatches) · ошибок блоков: \(stats.invalidBlocks)"
                    }
                }
                status = "Бит в бит (PCM) · \(Int(format.sampleRate)) Гц → \(Int(format.sampleRate)) Гц · Float32 · 100% · без DSP/SRC"
                if let actualOutputBuffer { status += " · буфер \(actualOutputBuffer)" }
                if unused > 0 { status += " · вне тракта: \(unused)" }
                status += " · источник: \(sourceSummary)"
                outputBinding = try DeviceBinding(outputID, scope: kAudioObjectPropertyScopeOutput)
                inputBinding = requestedInput; graphInvalidated = false
                observeConfiguration(graph)
                if !bitPerfectActive { applyOutputLevel() }
                return
            }
            let source: AVAudioNode
            let format: AVAudioFormat
            var pendingFile: AVAudioFile?
            let sourceInRoute = chain.contains { $0.kind == .source }
            if !sourceInRoute {
                format = graph.outputNode.inputFormat(forBus: 0)
                let silent = AVAudioSourceNode(format: format) { isSilence, _, _, list in
                    for buffer in UnsafeMutableAudioBufferListPointer(list) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    isSilence.pointee = true; return noErr
                }
                graph.attach(silent); source = silent
            } else { switch session.inputKind {
            case .device:
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard runToken == startingToken else { throw AudioFailure("Запуск отменён.") }
                guard allowed else { throw AudioFailure("Разрешите микрофон в настройках конфиденциальности macOS.") }
                // The default input may be a HAL private aggregate (e.g. Bluetooth).
                // Let AVAudioEngine choose that default; setting its physical UID fails.
                if !session.inputUID.isEmpty, let inputID { try Devices.select(inputID, for: graph.inputNode) }
                guard let activeInput = Devices.currentDevice(for: graph.inputNode) else { throw AudioFailure("Не удалось определить устройство входа.") }
                if let requested = session.bufferFrames { actualInputBuffer = try await Devices.setBufferFrames(requested, for: activeInput) }
                else { actualInputBuffer = try Devices.bufferFrames(activeInput) }
                format = graph.inputNode.outputFormat(forBus: 0)
                if noEffects { source = graph.inputNode }
                else {
                    guard format.commonFormat == .pcmFormatFloat32, format.channelCount <= 2 else {
                        throw AudioFailure("Синхронизация входа поддерживает mono/stereo Float32.")
                    }
                    let buffer = AudioQueueBuffer()
                    try buffer.configureClockSync(sampleRate: format.sampleRate)
                    clockBuffer = buffer
                    let sink = AVAudioSinkNode { _, frames, list in
                        buffer.append(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)), frames: Int(frames))
                        return noErr
                    }
                    graph.attach(sink); graph.connect(graph.inputNode, to: sink, format: format)
                    let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
                    let node = AVAudioSourceNode(format: stereo) { silence, _, frames, list in
                        buffer.render(UnsafeMutableAudioBufferListPointer(list), frames: Int(frames))
                        silence.pointee = false; return noErr
                    }
                    graph.attach(node); source = node
                }
                guard runToken == startingToken else { throw AudioFailure("Запуск отменён.") }
            case .system, .application:
                if session.inputKind == .application && session.applicationBundleID.isEmpty { throw AudioFailure("Выберите приложение.") }
                let capture = ProcessCapture(); self.capture = capture
                let token = runToken
                capture.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.runToken == token else { return }
                        await self.stop(); self.status = "Захват остановлен: \(error.localizedDescription)"
                    }
                }
                try await capture.start(bundleID: session.inputKind == .application ? session.applicationBundleID : nil, bufferFrames: session.bufferFrames,
                                        excludedBundleIDs: session.inputKind == .system ? session.systemExcludedBundleIDs ?? [] : [], startImmediately: false)
                guard runToken == startingToken else { throw AudioFailure("Захват остановлен во время запуска.") }
                guard let capturedFormat = capture.format else { throw AudioFailure("Перехват не предоставил аудиоформат.") }
                format = capturedFormat
                actualInputBuffer = capture.actualBufferFrames
                let buffer = capture.buffer
                try buffer.configureClockSync(sampleRate: format.sampleRate)
                clockBuffer = buffer
                let node = AVAudioSourceNode(format: format) { isSilence, _, count, list in
                    buffer.render(UnsafeMutableAudioBufferListPointer(list), frames: Int(count))
                    isSilence.pointee = false
                    return noErr
                }
                graph.attach(node); source = node
            case .file:
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: session.filePath))
                format = file.processingFormat
                let node = AVAudioPlayerNode(); graph.attach(node); source = node; player = node
                pendingFile = file
            }
            }
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure("Источник не имеет активных аудиоканалов.") }
            if noEffects {
                let output = graph.outputNode.inputFormat(forBus: 0)
                guard format.sampleRate == output.sampleRate, format.channelCount == 2, output.channelCount >= 2 else {
                    throw AudioFailure("Без плагинов пересчёт отключён: вход \(Int(format.sampleRate)) Гц / \(format.channelCount) каналов, выход \(Int(output.sampleRate)) Гц. Выберите совпадающий формат.")
                }
            }
            let outputFormat = graph.outputNode.inputFormat(forBus: 0)
            if diagnosticSilence {
                print("HAL ROUTE: output requested=\(outputID), actual=\(Devices.currentDevice(for: graph.outputNode) ?? 0), format=\(outputFormat.sampleRate)/\(outputFormat.channelCount), hardware=\((try? Devices.sampleRate(outputID)) ?? 0)/\(Devices.channels(outputID, scope: kAudioObjectPropertyScopeOutput)), input=\(inputID ?? 0), source=\(format.sampleRate)/\(format.channelCount)"); fflush(stdout)
            }
            // Effects use a stereo processing graph; the output mixer supports mono
            // hardware too (Bluetooth switches to mono while its microphone is active).
            // The no-effects path above still requires a matching stereo format.
            // Many third-party AUs reject Bluetooth voice rates (8/16/24 kHz).
            // Keep their DSP at 48 kHz and let the output mixer use the hardware format.
            let processingRate = !noEffects && outputFormat.sampleRate < 32_000 ? 48_000 : outputFormat.sampleRate
            guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
                  let processing = AVAudioFormat(standardFormatWithSampleRate: processingRate, channels: 2) else { throw AudioFailure("Выходное устройство не имеет активных аудиоканалов.") }
            if noEffects {
                // A file player renders on the output clock. Hardware input must share that clock.
                if session.inputKind == .device, let unit = graph.inputNode.audioUnit {
                    var inputID: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
                    let result = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputID, &size)
                    guard result == noErr, inputID == outputID else { throw AudioFailure("Бит в бит: аппаратный вход и выход должны быть на одном аудиоинтерфейсе; коррекция независимых часов отключена.") }
                }
                guard format.commonFormat == .pcmFormatFloat32 else { throw AudioFailure("Прозрачный путь поддерживает Float32 PCM без преобразования разрядности.") }
                graph.connect(source, to: graph.outputNode, format: format)
            } else {
                let converter = try await QualitySRC.make()
                guard runToken == startingToken, !shuttingDown else { throw AudioFailure("Запуск отменён.") }
                graph.attach(converter)
                inputSRC = converter
                let sourceFormat = clockBuffer != nil ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)! : format
                graph.connect(source, to: converter, format: sourceFormat)
                var nodes: [UUID: AVAudioNode] = [:]
                if let sourceBlock = chain.first(where: { $0.kind == .source }) { nodes[sourceBlock.id] = converter }
                if let outputBlock = chain.first(where: { $0.kind == .output }) { nodes[outputBlock.id] = mainMixer(for: graph) }
                generatorGates.removeAll()
                for block in chain where block.kind == .effect {
                    guard var unit = units[block.id] else { throw AudioFailure("Не загружен плагин \(block.name).") }
                    guard unit.auAudioUnit.outputBusses.count > 0, unit.auAudioUnit.inputBusses.count > 0 || block.component?.isGenerator == true else { throw AudioFailure("\(block.name) не имеет аудиовхода или выхода.") }
                    let unitFormat = PluginHost.renderingFormat(unit, preferred: processing)
                    if (unit.auAudioUnit.inputBusses.count > 0 && !unit.auAudioUnit.inputBusses[0].format.isEqual(unitFormat)) || !unit.auAudioUnit.outputBusses[0].format.isEqual(unitFormat) {
                        let state = unit.auAudioUnit.fullState
                        editorFrames.merge(retireEffectEditors([block.id])) { old, _ in old }
                        if graph.attachedNodes.contains(unit) { graph.detach(unit) }
                        guard let component = block.component else { throw AudioFailure("Нет идентификатора AU.") }
                        unit = try await instantiate(component, name: block.name)
                        guard runToken == startingToken, !shuttingDown else { throw AudioFailure("Запуск отменён.") }
                        try PluginHost.configureForRendering(unit, format: processing)
                        if let state { try PluginHost.prepareEditor(unit); unit.auAudioUnit.fullState = state }
                        units[block.id] = unit
                    }
                    try PluginHost.configureForRendering(unit, format: processing)
                    if !graph.attachedNodes.contains(unit) { graph.attach(unit) }
                    if block.component?.isGenerator == true {
                        unit.auAudioUnit.shouldBypassEffect = false // Host gate handles generator mute, including loaded presets.
                        let gate = AVAudioMixerNode(); graph.attach(gate)
                        graph.connect(unit, to: gate, format: unit.auAudioUnit.outputBusses[0].format)
                        gate.outputVolume = block.bypass ? 0 : 1
                        generatorGates[block.id] = gate; nodes[block.id] = gate
                    } else {
                        unit.auAudioUnit.shouldBypassEffect = block.bypass
                        nodes[block.id] = unit
                    }
                }
                try AudioGraphRouting.connect(session: session, route: chain, nodes: nodes, engine: graph, format: processing)
                // Keep the hidden mixer from applying its lower quality SRC at
                // voice rates. The converter also handles stereo -> mono output.
                let finalConverter = try await QualitySRC.make()
                guard runToken == startingToken, !shuttingDown else { throw AudioFailure("Запуск отменён.") }
                graph.attach(finalConverter)
                outputSRC = finalConverter
                graph.connect(mainMixer(for: graph), to: finalConverter, format: processing)
                graph.connect(finalConverter, to: graph.outputNode, format: outputFormat)
                mainMixerCache?.outputVolume = outputGain
            }
            let inputMeter = capture?.inputMeter ?? clockBuffer?.inputMeter ?? LevelMeter()
            let outputMeter = LevelMeter()
            if noEffects {
                source.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
                    inputMeter.observe(buffer); outputMeter.observe(buffer)
                }
                meterTaps = [source]
            } else {
                if capture == nil && clockBuffer == nil && sourceInRoute {
                    source.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in inputMeter.observe(buffer) }
                    meterTaps.append(source)
                }
                let meterNode: AVAudioNode = outputSRC ?? mainMixer(for: graph)
                meterNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in outputMeter.observe(buffer) }
                meterTaps.append(meterNode)
            }
            directGraphActive = noEffects
            applyOutputLevel(preparingGraph: true)
            graph.prepare()
            if !noEffects {installAUProbes(chain)}
            // Schedule only after the player's connected format is finalized.
            // Scheduling on the unattached/default 44.1k bus can cache a hidden
            // conversion before the later 48/96k connection is configured.
            if let file = pendingFile, let player {
                let token = runToken
                player.scheduleFile(file, at:nil, completionCallbackType:.dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.running, self.runToken == token else { return }
                        await self.stop(); self.status = "Файл проигран."
                    }
                }
            }
            if diagnosticSilence, diagnosticPreparationDelay > 0, let capture {
                try await Task.sleep(nanoseconds: diagnosticPreparationDelay)
                guard runToken == startingToken else { throw AudioFailure("Запуск отменён.") }
                guard capture.statistics.written == 0 else { throw AudioFailure("Диагностика: звук накопился до готовности DSP.") }
                print("PASS: delayed DSP preparation, captured frames=0, queue=0"); fflush(stdout)
            }
            try graph.start()
#if AUDIOCHAIN_DIAGNOSTICS
            if CommandLine.arguments.contains("--audit-clock-routes") {
                for node in graph.attachedNodes {
                    print("CLOCK_FORMAT node=\(type(of:node)) input=\(node.numberOfInputs>0 ? node.inputFormat(forBus:0).sampleRate : 0) output=\(node.numberOfOutputs>0 ? node.outputFormat(forBus:0).sampleRate : 0)")
                }
            }
#endif
            try capture?.activate()
            if let capture { actualInputBuffer = capture.actualBufferFrames }
            player?.play(); running = true
            startMeters(input: inputMeter, output: outputMeter)
            actualOutputBuffer = try Devices.bufferFrames(outputID)
            latencyOutputID = outputID; latencySourceRate = format.sampleRate
            latencyInputID = session.inputKind == .device && sourceInRoute ? (devices.first { $0.uid == session.inputUID }?.id ?? (try? Devices.defaultInput())) : nil
            updateLatencies()
            if let buffer = clockBuffer {
                transportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.running else { return }
                        let stats = buffer.statistics
                        self.transportStatus = "Синхронизация: \(String(format: "%+.1f", buffer.correctionPPM)) ppm · очередь: \(stats.queued) · подрывы: \(stats.underruns) · потеряно: \(stats.dropped)"
                    }
                }
            }
            outputBinding = try DeviceBinding(outputID, scope: kAudioObjectPropertyScopeOutput)
            inputBinding = try inputID.map { try DeviceBinding($0, scope: kAudioObjectPropertyScopeInput) }
            graphInvalidated = false
            observeConfiguration(graph)
            status = "\(noEffects ? (outputGain == 1 ? "Без DSP/SRC · 100%" : "PCM · без SRC") : "AU-цепочка") · \(session.inputKind == .application || session.inputKind == .system ? "Перехват работает · прямой звук отключён" : "Цепочка работает") · \(Int(processing.sampleRate)) Гц"
            if !noEffects { status += " · Mastering SRC" }
            if outputFormat.sampleRate != processing.sampleRate || outputFormat.channelCount == 1 { status += " · выход: \(Int(outputFormat.sampleRate)) Гц / \(outputFormat.channelCount) кан." }
            status += " · источник: \(sourceInRoute ? sourceSummary : "AU-генератор")"
            if let actualOutputBuffer { status += " · буфер \(actualOutputBuffer)" }
            if let requested = session.bufferFrames, actualOutputBuffer != requested { status += " (запрошено \(requested))" }
            if unused > 0 { status += " · вне тракта: \(unused)" }
            if outputGain != 1 { status += " · уровень выхода: \(Int(outputGain * 100))%" }
        } catch { graphInvalidated = true; await stop(); status = "Не удалось запустить: \(error.localizedDescription)" }
    }
    func stop(cancelRecovery: Bool = true) async {
        if cancelRecovery { playbackRequested = false; routeRecoveryTask?.cancel(); routeRecoveryTask = nil }
        let wasBusy = busy; busy = true; defer { busy = wasBusy }
        let wasRunning=running
        runToken = UUID(); running = false; bitPerfectActive = false
        directGraphActive = false
        transportTimer?.invalidate(); transportTimer = nil; transportStatus = ""
        levelTimer?.invalidate(); levelTimer = nil
        inputLevels = StereoLevels(); outputLevels = StereoLevels()
        blockLatencies = [:]; routeLatency = nil; latencyOutputID = nil; latencyInputID = nil
        player?.stop(); player = nil
        engine?.stop()
        // Read the stopped engine's observers before releasing them. Capture
        // counters are the last observed values before its IOProc is removed.
        if wasRunning {samplePlaybackTelemetry(includeStopped:true)}
        if engine != nil {
            auProbes.removeAll()
            boundaryProbes.removeAll()
            for node in meterTaps { node.removeTap(onBus: 0) }
            meterTaps.removeAll()
        }
        let oldCapture = capture; capture = nil
        await oldCapture?.stop()
        clockBuffer = nil
        pcmFault=false;lastPCMErrorAt=0
        inputSRC = nil; outputSRC = nil
        if let oldCapture, oldCapture.cleanupStatuses.contains(where: { $0 != noErr }) {
            status = "Ошибка освобождения перехвата: \(oldCapture.cleanupStatuses). Закройте AudioChain для восстановления прямого звука."
        } else { status = "Остановлено." }
        telemetry.health=SignalHealth(text:"Остановлено")
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { session.filePath = url.path }
    }
    private func snapshot() throws -> Session {
        var copy = session
        copy.volume = volume
        for index in copy.blocks.indices {
            if let state = units[copy.blocks[index].id]?.auAudioUnit.fullState {
                copy.blocks[index].state = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            }
        }
        return copy
    }
    func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "My Chain.audiochain.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try save(to: url, remember: true) }
        catch { status = "Не удалось сохранить: \(error.localizedDescription)" }
    }
    func save(to url: URL, remember: Bool = false) throws {
        let copy = try snapshot()
        try copy.validateEditingGraph()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encode/validate before the atomic replacement; failure leaves the old file intact.
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
        if remember { SessionHistory().remember(url) }
        status = "Схема и параметры AU сохранены."
    }
    func load() async {
        guard !running, !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await load(url: url, remember: true)
    }
    func restoreLastSession(history: SessionHistory = SessionHistory(), migrationURL: URL? = nil) async {
        let remembered = history.lastURL
        // Older releases did not keep document history. Adopt their default saved file once.
        guard let url = remembered ?? migrationURL else { return }
        if remembered == nil && !FileManager.default.fileExists(atPath: url.path) { return }
        await load(url: url)
        if remembered == nil && status == "Схема загружена." { history.remember(url) }
    }
    func load(url: URL, remember: Bool = false) async {
        guard !running, !busy, !shuttingDown else { return }
        busy = true; defer { busy = false }
        do {
            let candidate = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
            try candidate.validateEditingGraph()
            let token = runToken
            var loaded: [UUID: AVAudioUnit] = [:]
            var committed = false
            defer { if !committed { for unit in loaded.values where unit.auAudioUnit.renderResourcesAllocated { unit.auAudioUnit.deallocateRenderResources() } } }
            for block in candidate.blocks where block.kind == .effect {
                guard let component = block.component else { throw AudioFailure("Нет идентификатора AU.") }
                let unit = try await instantiate(component, name: block.name)
                guard !shuttingDown, runToken == token else { return }
                if let state = block.state {
                    guard let dictionary = try PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? [String: Any] else { throw AudioFailure("Некорректное состояние AU.") }
                    // iZotope's AUv2 state restoration accesses the initialized DSP core.
                    try PluginHost.prepareEditor(unit)
                    unit.auAudioUnit.fullState = dictionary
                }
                unit.auAudioUnit.shouldBypassEffect = block.bypass; loaded[block.id] = unit
            }
            for window in editors.values { window.close(); window.contentViewController = nil }
            editors.removeAll()
            editorRequests.removeAll()
            committed = true
            units = loaded; session = candidate; volume = candidate.volume; selected = nil; pendingPort = nil; lastRemovedWire = nil
            editHistory.clear();moveEntry=nil
            if remember { SessionHistory().remember(url) }
            status = "Схема загружена."
        } catch { status = "Не удалось открыть схему: \(error.localizedDescription)" }
    }
    func arrange() {
        guard !running, !busy else { return }
        let entry=editEntry("Выравнивание")
        let connected = try? session.orderedChain()
        let blocks: [Block]
        if let connected {
            let ids = Set(connected.map(\.id))
            blocks = connected + session.blocks.filter { !ids.contains($0.id) }
        } else {
            blocks = session.blocks.filter { $0.kind == .source } + session.blocks.filter { $0.kind == .effect } + session.blocks.filter { $0.kind == .output }
        }
        var updated=session.blocks
        let indices=Dictionary(updated.enumerated().map {($0.element.id,$0.offset)},uniquingKeysWith:{first,_ in first})
        var nextX = 24.0
        for block in blocks {
            if let index = indices[block.id] {
                updated[index].x = nextX
                updated[index].y = 76
                nextX += GraphLayout.width(for: block) + GraphLayout.gap
            }
        }
        if updated != session.blocks {session.blocks=updated}
        recordEdit(entry)
    }
}

struct ParameterEditor: View {
    let unit: AVAudioUnit
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Параметры Audio Unit").font(.title2)
                Text("Этот плагин не предоставил собственный редактор.").foregroundStyle(.secondary)
                ForEach(unit.auAudioUnit.parameterTree?.allParameters ?? [], id: \.address) { parameter in
                    ParameterControl(parameter: parameter)
                }
            }.padding(24)
        }.frame(minWidth: 460, minHeight: 300)
    }
}
struct ParameterControl: View {
    let parameter: AUParameter
    @State private var value: Float = 0
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(parameter.displayName); Spacer(); Text(parameter.string(fromValue: nil)).monospacedDigit() }
            if parameter.maxValue > parameter.minValue {
                Slider(value: $value, in: parameter.minValue...parameter.maxValue).onChange(of: value) { _, newValue in parameter.value = newValue }
            }
        }.onAppear { value = parameter.value }
    }
}
