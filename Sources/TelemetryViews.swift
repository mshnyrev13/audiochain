import SwiftUI

struct MacResourcesView: View {
    @ObservedObject var telemetry: DisplayTelemetry
    var body: some View {
        Text(telemetry.resources.macText).font(.system(size:10)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            .help("Mac CPU: 100% — весь процессор. RAM — занятая память без файлового кэша. Нагрузка AudioChain и параметры аудиотракта — в диагностике.")
    }
}

struct BlockLatencyLabel: View {
    @ObservedObject var telemetry: DisplayTelemetry
    let id: UUID
    let active: Bool
    private var text: String {
        guard active else {return "Задержка: —"}
        guard let value = telemetry.blockLatencies[id] else {return "Задержка: н/д"}
        return String(format:"≈ %.2f мс",value)
    }
    var body: some View {Text(text).font(.system(size:9)).monospacedDigit().foregroundStyle(.secondary)}
}

struct TelemetryDiagnostics: View {
    @ObservedObject var telemetry: DisplayTelemetry
    let status: String
    let needsAttention: Bool
    let running: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(status).foregroundStyle(needsAttention ? Color.orange : Color.primary).lineLimit(3).help(status)
            if !telemetry.transportStatus.isEmpty {Text(telemetry.transportStatus).foregroundStyle(.secondary).lineLimit(2)}
            Text(telemetry.health.text).foregroundStyle(telemetry.health.warning ? Color.orange : .secondary)
            HStack(spacing:12) {
                Text(telemetry.resources.appText)
                if running, let latency = telemetry.routeLatency, latency.isFinite {
                    Text(String(format:"Тракт ≈ %.2f мс",latency))
                        .help("Оценка по очереди, HAL и заявленным задержкам AU/SRC. Это не аппаратный loopback. Параллельные ветки суммируются без выравнивания.")
                }
            }.monospacedDigit().foregroundStyle(.secondary)
                .help("CPU AudioChain: 100% — одно ядро. AUv3-процессы учитываются в общей нагрузке Mac. RAM процесса — phys_footprint. «—» — измерение пока недоступно.")
        }
        .font(.system(size:10)).textSelection(.enabled)
        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,8)
        .background(AudioTheme.canvas)
    }
}
