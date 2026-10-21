import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AudioModel
    var initialZoom: Double = 1
    var initialLibrary: Bool? = nil
    var initialDiagnostics = false
    var initialSelectedWire: Wire? = nil
    var initialMap = false
    @AppStorage("AudioChain.ui.libraryExpanded") private var libraryExpanded = false
    @State private var showDiagnostics = false
    @State private var showAULoad = false
    private var libraryVisible: Bool { initialLibrary ?? libraryExpanded }
    private var diagnosticsVisible: Bool { initialDiagnostics || showDiagnostics }
    private var presentation: StatusPresentation {
        StatusPresentation(status:model.status,running:model.running,direct:model.usesDirectPCM,
            busy:model.busy,muted:model.session.outputMuted == true,volume:model.volume)
    }
    private var hasError: Bool {presentation.needsAttention}
    private var compactStatus: String {presentation.text}
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(AudioTheme.border)
            HStack(spacing: 0) {
                if libraryVisible {
                    PluginLibraryView(model:model).equatable()
                    Divider().overlay(AudioTheme.border)
                }
                GraphCanvas(model:model,initialZoom:initialZoom,initialSelectedWire:initialSelectedWire,initialMap:initialMap)
            }
            if diagnosticsVisible {
                Divider().overlay(AudioTheme.border)
                diagnostics
            }
            Divider().overlay(AudioTheme.border)
            footer
        }
        .background(AudioTheme.surface)
        .frame(minWidth:640,minHeight:320).preferredColorScheme(.dark)
        .onAppear { if hasError {showDiagnostics = true} }
        .onChange(of:model.status) { _, _ in if hasError {showDiagnostics = true} }
    }
    private var toolbar: some View {
        HStack(spacing:8) {
            Button { libraryExpanded.toggle() } label: {
                Label("AU",systemImage:"sidebar.left")
                    .foregroundStyle(libraryVisible ? AudioTheme.accent : Color.primary)
            }
            .help("Библиотека AU · ⌘B").accessibilityLabel("Библиотека AU")
            .accessibilityValue(libraryVisible ? "Показана" : "Скрыта").keyboardShortcut("b",modifiers:.command)
            Image(nsImage:AudioTheme.appIcon).resizable().interpolation(.high).frame(width:24,height:24).accessibilityHidden(true)
            Text("AudioChain").font(.system(size:12,weight:.semibold))
            Spacer(minLength:8)
            HistoryControls(history:model.editHistory,model:model,disabled:model.running || model.busy)
            Button {showAULoad.toggle()} label: {Image(systemName:"cpu")}
                .help("Нагрузка каждого AU").accessibilityLabel("Нагрузка AU")
                .popover(isPresented:$showAULoad) {AULoadPanel(telemetry:model.telemetry)}
            Button { model.arrange() } label: {Image(systemName:"rectangle.3.group")}
                .help("Выровнять блоки").accessibilityLabel("Выровнять блоки").disabled(model.running || model.busy)
            Button { Task { await model.load() } } label: {Image(systemName:"folder")}
                .help("Открыть схему · ⌘O").accessibilityLabel("Открыть схему")
                .keyboardShortcut("o",modifiers:.command).disabled(model.running || model.busy)
            Button { model.save() } label: {Image(systemName:"square.and.arrow.down")}
                .help("Сохранить схему · ⌘S").accessibilityLabel("Сохранить схему")
                .keyboardShortcut("s",modifiers:.command).disabled(model.busy)
            Button {
                Task { if model.running {await model.stop()} else {await model.start()} }
            } label: {
                Label(model.running ? "Стоп" : "Старт",systemImage:model.running ? "stop.fill" : "play.fill").frame(width:66)
            }
            .buttonStyle(CompactButtonStyle(accent:model.running ? .orange : AudioTheme.accent))
            .keyboardShortcut(.return,modifiers:.command).disabled(model.busy)
        }
        .buttonStyle(CompactButtonStyle()).font(.system(size:11))
        .padding(.horizontal,10).padding(.vertical,6)
    }
    private var footer: some View {
        HStack(spacing:8) {
            PlaybackStateView(telemetry:model.telemetry,status:compactStatus,running:model.running,attention:hasError)
            if model.busy {ProgressView().controlSize(.mini)}
            Spacer(minLength:4)
            MacResourcesView(telemetry:model.telemetry)
            Button { showDiagnostics.toggle() } label: {
                HStack(spacing:4) {
                    Image(systemName:"waveform.path.ecg")
                    Image(systemName:diagnosticsVisible ? "chevron.down" : "chevron.up").font(.system(size:8,weight:.semibold))
                }.frame(width:30,height:18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(diagnosticsVisible ? AudioTheme.accent : .secondary)
            .accessibilityLabel("Диагностика").accessibilityValue(diagnosticsVisible ? "Открыта" : "Закрыта")
            .help("Диагностика · ⌘D: SRC, очередь, счётчики, нагрузка AudioChain").keyboardShortcut("d",modifiers:.command)
        }.padding(.horizontal,12).padding(.vertical,5)
    }
    private var diagnostics: some View {
        TelemetryDiagnostics(telemetry:model.telemetry,status:model.status,needsAttention:hasError,running:model.running)
    }
}
