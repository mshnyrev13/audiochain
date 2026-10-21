import SwiftUI

struct BlockSettingsView: View {
    @ObservedObject var model: AudioModel
    let kind: BlockKind
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(kind == .source ? "Источник" : "Выход", systemImage: kind == .source ? "waveform" : "speaker.wave.2").font(.headline)
            if kind == .source { SourceSettings(model: model) }
            else { OutputSettings(model: model) }
            Spacer(minLength: 0)
            if model.running { Text("Для изменения устройства или буфера нажмите Стоп.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(minWidth: 400, minHeight: 260).controlSize(.small).preferredColorScheme(.dark)
    }
}
struct SourceSettings: View {
    @ObservedObject var model: AudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Тип", selection: $model.session.inputKind) {
                ForEach(InputKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(model.running || model.busy)
            switch model.session.inputKind {
            case .device:
                Picker("Аудиовход", selection: $model.session.inputUID) {
                    Text("Системный по умолчанию").tag("")
                    if !model.session.inputUID.isEmpty && !model.devices.contains(where: { $0.uid == model.session.inputUID && $0.inputs > 0 }) { Text("Устройство отключено").tag(model.session.inputUID) }
                    ForEach(model.devices.filter { $0.inputs > 0 }) { Text($0.name).tag($0.uid) }
                }
                Button("Обновить устройства") { model.refreshDevices() }
            case .application:
                Picker("Приложение", selection: $model.session.applicationBundleID) {
                    Text(model.session.applicationBundleID.isEmpty ? "Выберите…" : model.sourceSummary).tag(model.session.applicationBundleID)
                    ForEach(model.applications.filter { $0.id != model.session.applicationBundleID }) { Text($0.name).tag($0.id) }
                }
                Button("Обновить приложения") { Task { await model.refreshApps() } }
            case .system:
                SystemSourceSettings(model: model)
            case .file:
                Button("Выбрать аудиофайл…") { model.chooseFile() }
                Text(model.sourceSummary).font(.caption).lineLimit(2)
            }
        }.disabled(model.busy || (model.running && model.session.inputKind != .system))
    }
}
struct SystemSourceSettings: View {
    @ObservedObject var model: AudioModel
    @State private var selectedApp = ""
    private var excluded: [String] { model.session.systemExcludedBundleIDs ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Весь звук Mac → цепочка → выбранное устройство. Прямой звук перехваченных приложений отключён до Стоп.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Исключённые приложения").font(.caption.bold())
            ForEach(excluded, id: \.self) { id in
                HStack {
                    Text(model.applications.first(where: { $0.id == id })?.name ?? id).font(.caption).lineLimit(1)
                    Spacer()
                    Button { model.session.systemExcludedBundleIDs = excluded.filter { $0 != id } } label: { Image(systemName: "minus.circle") }
                        .help("Снова пропускать приложение через цепочку")
                }
            }
            HStack {
                Picker("Приложение", selection: $selectedApp) {
                    Text("Выберите…").tag("")
                    ForEach(model.applications.filter { !excluded.contains($0.id) && $0.id != Bundle.main.bundleIdentifier }) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Button("Исключить") {
                    guard !selectedApp.isEmpty, !excluded.contains(selectedApp) else { return }
                    model.session.systemExcludedBundleIDs = excluded + [selectedApp]; selectedApp = ""
                }.disabled(selectedApp.isEmpty)
            }
            Button("Обновить приложения") { Task { await model.refreshApps() } }
            Text("Исключённые приложения играют напрямую на свой выход macOS.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: model.session.systemExcludedBundleIDs) { _, _ in model.updateSystemExclusions() }
    }
}
struct OutputSettings: View {
    @ObservedObject var model: AudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Устройство", selection: $model.session.outputUID) {
                Text("Системный по умолчанию").tag("")
                if !model.session.outputUID.isEmpty && !model.devices.contains(where: { $0.uid == model.session.outputUID && $0.outputs > 0 }) { Text("Устройство отключено").tag(model.session.outputUID) }
                ForEach(model.devices.filter { $0.outputs > 0 }) { Text($0.name).tag($0.uid) }
            }.disabled(model.running || model.busy)
            Picker("Буфер, кадров", selection: $model.session.bufferFrames) {
                Text("Авто").tag(nil as UInt32?)
                ForEach(Devices.bufferChoices, id: \.self) { Text("\($0)").tag(Optional($0)) }
            }.disabled(model.running || model.busy)
            if let actual = model.actualOutputBuffer, model.running { Text("Фактический буфер выхода: \(actual) кадров").font(.caption).foregroundStyle(.secondary) }
            if let input = model.actualInputBuffer, model.running, input != model.actualOutputBuffer { Text("Буфер входа: \(input) кадров").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Уровень")
                Slider(value: $model.volume, in: 0...1).disabled(model.busy)
                Text("\(Int(model.volume * 100))%").monospacedDigit().frame(width: 40)
            }
            Toggle("Отключить звук этого выхода", isOn: Binding(get: { model.session.outputMuted == true }, set: { model.session.outputMuted = $0; model.applyOutputLevel() })).disabled(model.busy)
            if !model.hasActiveEffects {
                Text(model.running && !model.usesDirectPCM ? "Плагины обойдены. Для прямого PCM без DSP нажмите Стоп/Старт." : "Без AU при 100% PCM сохраняется бит в бит. Изменение уровня меняет амплитуду.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Обновить устройства") { model.refreshDevices() }.disabled(model.running || model.busy)
        }
    }
}
struct BlockLevelView: View {
    let levels: StereoLevels
    var heldLeft = -Double.infinity
    var heldRight = -Double.infinity
    var clipping = false
    private var fault: Bool { levels.left == .infinity || levels.right == .infinity || levels.left.isNaN || levels.right.isNaN }
    private func value(_ dB: Double) -> String {dB == -.infinity ? "−∞" : !dB.isFinite ? "ERR" : String(format:"%.1f",dB)}
    private func fraction(_ dB: Double) -> Double {
        if !dB.isFinite {return dB == .infinity || dB.isNaN ? 1 : 0}
        return max(0,min(1,(dB+60)/60))
    }
    private func row(_ name: String, _ dB: Double, _ held: Double) -> some View {
        HStack(spacing:5) {
            Text(name).font(.system(size:8)).foregroundStyle(.secondary).frame(width:7)
            GeometryReader {geometry in
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.black.opacity(0.32))
                    HStack(spacing:0) {
                        AudioTheme.accent.frame(width:geometry.size.width*0.8)
                        Color.yellow.frame(width:geometry.size.width*0.15)
                        Color.red
                    }.mask(alignment:.leading) {Rectangle().frame(width:geometry.size.width*fraction(dB))}
                    ForEach([-48.0,-24,-12],id:\.self) {tick in
                        Rectangle().fill(AudioTheme.card.opacity(0.7)).frame(width:1)
                            .offset(x:geometry.size.width*fraction(tick))
                    }
                    if held.isFinite && held > -60 {
                        Rectangle().fill(held >= 0 ? Color.red : Color.white.opacity(0.9)).frame(width:1.5)
                            .offset(x:max(0,min(geometry.size.width-1.5,geometry.size.width*fraction(held))))
                    }
                }.clipShape(Capsule())
            }.frame(height:6)
            Text(value(dB)).font(.system(size:9,design:.monospaced))
                .foregroundStyle(dB >= 0 || dB.isNaN ? Color.red : Color.secondary).frame(width:35,alignment:.trailing)
        }.frame(height:11)
    }
    var body: some View {
        VStack(spacing:3) {
            HStack(spacing:5) {
                Color.clear.frame(width:7)
                GeometryReader {geometry in
                    Text("−60").position(x:8,y:4)
                    Text("−24").position(x:geometry.size.width*0.6,y:4)
                    Text("0").position(x:geometry.size.width-3,y:4)
                }.foregroundStyle(.secondary).accessibilityHidden(true)
                Text(fault ? "ERR" : clipping ? "CLIP" : "dBFS")
                    .fontWeight(fault || clipping ? .semibold : .regular)
                    .foregroundStyle(fault || clipping ? Color.red : .secondary)
                    .frame(width:35,alignment:.trailing)
            }.font(.system(size:7.5)).frame(height:8)
            row("L",levels.left,heldLeft)
            row("R",levels.right,heldRight)
        }
        .help("Sample peak L/R: шкала −60…0 dBFS, числа справа. Белая метка удерживает пик 1.2 с, CLIP — 2 с. 0 dBFS — полный цифровой уровень. ERR — NaN/Inf. Это не true peak.")
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Уровень \(isFaultLabel)")
        .accessibilityValue("L \(value(levels.left)), R \(value(levels.right)) dBFS\(clipping ? ", перегрузка" : "")")
    }
    private var isFaultLabel: String {fault ? "с ошибкой PCM" : "сэмплов"}
}

// Only the two meter views update at meter/peak-hold frequency, not the graph.
struct BlockMetersView: View {
    @ObservedObject var meters: DisplayMeters
    let isInput: Bool
    @State private var leftHold = MeterPeakHold()
    @State private var rightHold = MeterPeakHold()
    @State private var clipping = false
    private var levels: StereoLevels {
        let raw = isInput ? meters.input : meters.output
        return StereoLevels(left:raw.left.isNaN ? .infinity : raw.left,right:raw.right.isNaN ? .infinity : raw.right)
    }
    private func update(_ sample: StereoLevels) {
        let now = ProcessInfo.processInfo.systemUptime
        leftHold.update(sample.left,at:now);rightHold.update(sample.right,at:now)
        clipping = now < max(leftHold.clipUntil,rightHold.clipUntil)
    }
    private func deadline(_ sample: StereoLevels) -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        let left = leftHold.nextUpdate(for:sample.left,at:now), right = rightHold.nextUpdate(for:sample.right,at:now)
        if let left, let right {return min(left,right)}
        return left ?? right
    }
    var body: some View {
#if AUDIOCHAIN_DIAGNOSTICS
        let _ = UIAuditCounters.meter(input:isInput,peak:leftHold.peak,clipping:clipping)
#endif
        BlockLevelView(levels:levels,heldLeft:leftHold.peak,heldRight:rightHold.peak,clipping:clipping)
            .task(id:levels) {
                let sample = levels
                update(sample)
                while let next = deadline(sample) {
                    let delay = max(0.001,next-ProcessInfo.processInfo.systemUptime)
                    do {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))} catch {return}
                    guard !Task.isCancelled, levels == sample else {return}
                    update(sample)
                }
            }
    }
}
