import SwiftUI

struct HistoryControls:View {
    @ObservedObject var history:EditHistory
    let model:AudioModel
    let disabled:Bool
    var body:some View {
        HStack(spacing:4) {
            Button {Task {await model.undoEdit()}} label: {Image(systemName:"arrow.uturn.backward")}
                .help(history.undoName.map {"Отменить: "+$0+" · ⌘Z"} ?? "Нет действий для отмены")
                .accessibilityLabel("Отменить действие").keyboardShortcut("z",modifiers:.command)
                .disabled(disabled || history.undoName == nil)
            Button {Task {await model.redoEdit()}} label: {Image(systemName:"arrow.uturn.forward")}
                .help(history.redoName.map {"Повторить: "+$0+" · ⇧⌘Z"} ?? "Нет действий для повтора")
                .accessibilityLabel("Повторить действие").keyboardShortcut("z",modifiers:[.command,.shift])
                .disabled(disabled || history.redoName == nil)
        }
    }
}
struct PlaybackStateView:View {
    @ObservedObject var telemetry:DisplayTelemetry
    let status:String
    let running:Bool
    let attention:Bool
    private var presentation:PlaybackPresentation {
        PlaybackPresentation(status:status,health:telemetry.health,attention:attention)
    }
    var body:some View {
        HStack(spacing:8) {
            Circle().fill(presentation.warning ? .orange : running ? AudioTheme.accent : .gray).frame(width:6,height:6)
                .accessibilityHidden(true)
            Text(presentation.text)
                .font(.system(size:10)).lineLimit(1)
                .foregroundStyle(presentation.warning ? Color.orange : Color.primary)
                .help(telemetry.health.text+"\n"+status)
            Spacer(minLength:0)
            if telemetry.hasRunMeasurements {
                Text((running ? "" : "Итог · ")+"Подрывы \(telemetry.underruns) · Потери \(telemetry.dropped)")
                    .font(.system(size:9)).monospacedDigit().fixedSize()
                    .foregroundStyle(telemetry.underruns+telemetry.dropped>0 ? Color.orange : .secondary)
                    .help("Последние считанные значения за \(running ? "текущий" : "завершённый") запуск. Ошибок PCM: \(telemetry.pcmErrors). Сбрасываются при следующем запуске.")
            }
        }
    }
}
struct AULoadPanel:View {
    @ObservedObject var telemetry:DisplayTelemetry
    @State private var order:AULoadOrder
    init(telemetry:DisplayTelemetry,initialOrder:AULoadOrder = .chain) {
        self.telemetry=telemetry;_order=State(initialValue:initialOrder)
    }
    var body:some View {
        let rows=order.rows(telemetry.auLoads)
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("Нагрузка AU").font(.headline);Spacer();Text(telemetry.resources.appText).font(.system(size:10)).foregroundStyle(.secondary)}
            if telemetry.hasRunMeasurements && !telemetry.playbackRunning {
                Label("Последний запуск · измерения сохранены до следующего Старт",systemImage:"clock.arrow.circlepath")
                    .font(.system(size:10)).foregroundStyle(AudioTheme.accent)
            }
            HStack {
                Picker("Порядок AU",selection:$order) {
                    ForEach(AULoadOrder.allCases) {Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).labelsHidden().frame(width:270).controlSize(.small)
                Spacer()
                Text("AU: \(rows.count)").font(.system(size:10)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("Плагин").frame(maxWidth:.infinity,alignment:.leading)
                Text("≈ мс/блок").frame(width:75,alignment:.trailing)
                Text("Пик, мс").frame(width:62,alignment:.trailing)
                Text("Бюджет").frame(width:65,alignment:.trailing)
            }.font(.system(size:10)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing:4) {
                    ForEach(rows) {row in AULoadRowView(row:row)}
                    if rows.isEmpty {Text("Измерения появятся после запуска цепочки.").foregroundStyle(.secondary).padding(20)}
                }
            }.frame(maxHeight:250)
            Text("Время render за вычетом вложенных измеренных AU, не CPU процесса. Среднее — \(telemetry.playbackRunning ? "за последний интервал" : "за завершённый запуск"); бюджет — доля длительности кадров, пик — за запуск. RAM — всего AudioChain, включая AUv2.")
                .font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(14).frame(width:510).background(AudioTheme.surface).preferredColorScheme(.dark)
    }
}
private struct AULoadRowView:View {
    let row:AULoadRow
    private var load:AULoad {row.load}
    private var tint:Color {(load.measuredBudget ?? 0)>=100 ? .red : (load.measuredBudget ?? 0)>=70 ? .orange : AudioTheme.accent}
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Text("#\(row.ordinal)").font(.system(size:9)).foregroundStyle(.secondary)
                    .help("Номер блока схемы на момент измерения. Переход в поиске: #номер.")
                Text(load.name+(load.bypass ? " · обход":"")).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).help(load.name)
                Text(load.meanMS.map {String(format:"%.3f",$0)} ?? "—").frame(width:75,alignment:.trailing)
                Text(load.peakMS.map {String(format:"%.3f",$0)} ?? "—").frame(width:62,alignment:.trailing)
                Text(load.measuredBudget.map {String(format:"%.2f%%",$0)} ?? "—").frame(width:65,alignment:.trailing)
                    .foregroundStyle((load.measuredBudget ?? 0)>=70 ? tint:Color.primary)
            }.font(.system(size:11)).monospacedDigit()
            ProgressView(value:min(load.measuredBudget ?? 0,100),total:100).progressViewStyle(.linear)
                .tint(tint).controlSize(.mini).frame(height:3).opacity(load.measuredBudget == nil ? 0.3:1)
                .accessibilityLabel("Доля аудиобюджета: "+(load.measuredBudget.map {String(format:"%.2f%%",$0)} ?? "нет измерения"))
            if load.waiting {Text("Render начат, но нет завершения более 2 с").foregroundStyle(.orange).font(.caption)}
            else if load.invalid>0 {Text("Измерение недоступно · вложенность render").foregroundStyle(.orange).font(.caption)}
            else if load.errors>0 {Text("Ошибок render: \(load.errors)").foregroundStyle(.orange).font(.caption)}
            else if load.calls==0 {Text(load.active ? "Нет данных render · остановлено или AU не предоставляет измерение":"Вне тракта · не обрабатывается").font(.system(size:9)).foregroundStyle(.secondary)}
        }.padding(7).background(AudioTheme.card,in:RoundedRectangle(cornerRadius:5))
    }
}
