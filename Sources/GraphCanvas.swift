import SwiftUI

struct GraphCanvas: View {
    @ObservedObject var model: AudioModel
    @State private var zoom: Double
    init(model: AudioModel, initialZoom: Double = 1, initialSelectedWire: Wire? = nil, initialMap:Bool=false) {
        self.model = model
        _zoom = State(initialValue: min(1.5, max(0.5, initialZoom)))
        _selectedWire = State(initialValue:initialSelectedWire)
        _showMap = State(initialValue:initialMap)
    }
    @State private var connectionEnd: CGPoint?
    @State private var selectedWire: Wire?
    @State private var navigator=GraphNavigator()
    @State private var showMap=false
    @State private var showSearch=false
    @FocusState private var graphFocused: Bool
    private func wirePath(from a: CGPoint, to b: CGPoint) -> Path {
        CableCurve(from:a,to:b).path
    }
    private func selectWire(_ wire: Wire) {
        selectedWire = wire; model.selected = nil; graphFocused = true
        model.pendingPort = nil; connectionEnd = nil
    }
    private func blockTitle(_ block: Block) -> String {
        block.kind == .source ? model.session.inputKind.title : block.name
    }
    private func completeDrag(at point: CGPoint) {
        guard !model.running, !model.busy else { connectionEnd = nil; model.pendingPort = nil; return }
        if let target = model.session.blocks.first(where: {
            $0.kind != .source && $0.component?.isGenerator != true && hypot(point.x - $0.x, point.y - ($0.y + GraphLayout.portY)) < 22
        }) { model.inputPort(target.id) }
        else { model.pendingPort = nil }
        connectionEnd = nil
    }
    var body: some View {
#if AUDIOCHAIN_DIAGNOSTICS
        let _ = UIAuditCounters.graph()
#endif
        GeometryReader { geometry in
        let activeIDs = model.activeBlockIDs
        let index = GraphDisplayIndex(model.session.blocks)
        let viewportWidth=geometry.size.width/zoom, viewportHeight=geometry.size.height/zoom
        // A distant end block needs room to reach the viewport centre rather
        // than getting pinned beneath the navigation controls at the edges.
        let logicalWidth = index.width > viewportWidth ? index.width+viewportWidth/2 : viewportWidth
        let logicalHeight = index.height > viewportHeight ? index.height+viewportHeight/2 : viewportHeight
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(ImagePaint(image:Image(nsImage:AudioTheme.gridTile)))
                    .contentShape(Rectangle()).onTapGesture {
                        model.selected = nil;selectedWire = nil;model.pendingPort = nil;connectionEnd = nil;graphFocused = true
                    }
                ForEach(model.session.wires, id: \.self) { wire in
                    if let from = index.blocks[wire.from],
                       let to = index.blocks[wire.to] {
                        let curve = CableCurve(from:CGPoint(x:from.x+GraphLayout.width(for:from),y:from.y+GraphLayout.portY),
                                               to:CGPoint(x:to.x,y:to.y+GraphLayout.portY))
                        let path = curve.path
                        let inRoute = activeIDs.contains(wire.from) && activeIDs.contains(wire.to)
                        let related = model.selected == nil || model.selected == wire.from || model.selected == wire.to
                        let selected = selectedWire == wire
                        let cableColor = selected ? Color.white : (inRoute ? AudioTheme.accent.opacity(related ? (model.running ? 1 : 0.7) : 0.22) : Color.gray.opacity(related ? 0.5 : 0.2))
                        path.stroke(cableColor, style: StrokeStyle(lineWidth:selected ? 2.8 : 2, lineCap:.round, dash:inRoute ? [] : [5,4]))
                            .contentShape(path.strokedPath(StrokeStyle(lineWidth: 16)))
                            .help(inRoute ? "Соединение в тракте выбранного выхода" : "Ветка не ведёт к выходу и не обрабатывается")
                            .onTapGesture { selectWire(wire) }
                            .accessibilityLabel("Соединение: \(blockTitle(from)) → \(blockTitle(to))")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {selectWire(wire)}
                            .focusable()
                            .onKeyPress(.return) {selectWire(wire);return .handled}
                            .onKeyPress(.space) {selectWire(wire);return .handled}
                            .contextMenu {
                                Button("Удалить соединение", role: .destructive) { model.disconnect(wire); selectedWire = nil }
                                    .disabled(model.running || model.busy)
                            }
                        curve.arrow.fill(cableColor).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                if let fromID = model.pendingPort,
                   let from = index.blocks[fromID], let end = connectionEnd {
                    wirePath(from: CGPoint(x: from.x + GraphLayout.width(for:from), y: from.y + GraphLayout.portY), to: end)
                        .stroke(AudioTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [5,4])).allowsHitTesting(false)
                }
                ForEach(model.session.blocks) { block in
                    BlockCard(model: model, block: block, connectionChanged: { point in
                        selectedWire = nil; connectionEnd = point
                    }, connectionEnded: completeDrag).offset(x: block.x, y: block.y)
                }
                HStack(spacing:8) {
                    Text("Цепочка").font(.system(size:11,weight:.medium))
                    Text("Блоки: \(model.session.blocks.count) · Связи: \(model.session.wires.count)")
                        .font(.system(size:10)).monospacedDigit().foregroundStyle(.secondary)
                }.padding(16).help("Протяните провод от выхода к входу. Двойной клик открывает настройки. Пунктир — ветка вне тракта. Параллельные входы суммируются без выравнивания задержек.")
                if model.session.wires.isEmpty {
                    Text("Протяните провод от выходного порта к входному.")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                        .frame(maxWidth:360,alignment:.leading).padding(.leading,24).padding(.top,200).allowsHitTesting(false)
                }
            }
            .frame(width: logicalWidth, height: logicalHeight)
            .background(AudioTheme.canvas)
            .coordinateSpace(name: "audioGraph")
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: logicalWidth * zoom, height: logicalHeight * zoom, alignment: .topLeading)
            .background(GraphScrollAccessor(navigator:navigator))
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if model.pendingPort != nil {
                    Label("Выберите вход",systemImage:"cable.connector").font(.system(size:10))
                        .foregroundStyle(AudioTheme.accent).lineLimit(1)
                    Button { model.pendingPort = nil; connectionEnd = nil } label: { Image(systemName: "xmark") }.help("Отменить соединение · Esc")
                }
                if let wire = selectedWire, model.session.wires.contains(wire) {
                    if let from = index.blocks[wire.from], let to = index.blocks[wire.to] {
                        HStack(spacing:4) {
                            Text(blockTitle(from)).lineLimit(1).truncationMode(.tail)
                            Image(systemName:"arrow.right").font(.system(size:8)).fixedSize().foregroundStyle(.secondary)
                            Text(blockTitle(to)).lineLimit(1).truncationMode(.tail)
                        }.frame(maxWidth:148,alignment:.leading)
                            .accessibilityElement(children:.ignore)
                            .accessibilityLabel("\(blockTitle(from)) → \(blockTitle(to))")
                            .help("\(blockTitle(from)) → \(blockTitle(to)) · Delete — удалить провод, Esc — снять выделение")
                    }
                    Button { model.disconnect(wire); selectedWire = nil } label: { Image(systemName: "trash") }
                        .help("Удалить выбранный провод · Delete").disabled(model.running || model.busy)
                }
                if model.lastRemovedWire != nil { Button { model.restoreLastConnection() } label: { Image(systemName: "arrow.uturn.backward") }.help("Восстановить последний удалённый провод").disabled(model.running || model.busy) }
            }.buttonStyle(CompactButtonStyle()).font(.system(size: 10)).padding(6)
                .background(model.pendingPort != nil || selectedWire != nil || model.lastRemovedWire != nil ? AudioTheme.surface : .clear,in:RoundedRectangle(cornerRadius:8)).padding(8)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment:.trailing,spacing:5) {
            if showMap {GraphMiniMap(viewport:navigator.viewport,blocks:model.session.blocks,wires:model.session.wires,extent:CGSize(width:logicalWidth,height:logicalHeight),zoom:zoom,navigator:navigator,selected:model.selected)}
            HStack(spacing: 4) {
                Button {showSearch.toggle()} label: {Image(systemName:"text.magnifyingglass")}
                    .accessibilityLabel("Найти блок").help("Поиск блока · ⌘F").keyboardShortcut("f",modifiers:.command)
                    .popover(isPresented:$showSearch) {GraphSearch(model:model,navigator:navigator,zoom:zoom,close:{showSearch=false})}
                Button {showMap.toggle()} label: {Image(systemName:"map").foregroundStyle(showMap ? AudioTheme.accent : Color.primary)}
                    .accessibilityLabel("Мини-карта").help("Показать/скрыть мини-карту")
                Button {
                    let width = index.width
                    let height = index.height
                    zoom = min(1.5,max(0.5,min(geometry.size.width/max(1,width),max(1,geometry.size.height-48)/max(1,height))))
                } label: {Image(systemName:"arrow.up.left.and.arrow.down.right")}
                .help("Вписать схему в окно; длинные цепочки остаются доступны прокруткой")
                .accessibilityLabel("Вписать схему")
                Button { zoom = max(0.5, zoom - 0.125) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(zoom <= 0.5).accessibilityLabel("Уменьшить схему")
                Button { zoom = 1 } label: { Text("\(Int((zoom*100).rounded()))%").monospacedDigit().frame(width: 36) }.help("Вернуть масштаб 100%")
                Button { zoom = min(1.5, zoom + 0.125) } label: { Image(systemName: "plus.magnifyingglass") }.disabled(zoom >= 1.5).accessibilityLabel("Увеличить схему")
            }.buttonStyle(CompactButtonStyle()).font(.system(size: 10)).padding(6)
                .background(AudioTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }.padding(8)
        }
        }.frame(minHeight: 140)
        .focusable().focused($graphFocused)
        .onChange(of: model.pendingPort) { _, value in if value != nil { selectedWire = nil; graphFocused = true } }
        .onChange(of: model.selected) {_, value in if value != nil {selectedWire = nil}}
        .onExitCommand { model.pendingPort = nil; connectionEnd = nil; selectedWire = nil }
        .onDeleteCommand {
            if let wire = selectedWire { model.disconnect(wire); selectedWire = nil }
        }
        .onChange(of: model.running) { _, _ in model.pendingPort = nil; connectionEnd = nil; selectedWire = nil }
    }
}
struct BlockCard: View {
    @ObservedObject var model: AudioModel
    let block: Block
    var connectionChanged: (CGPoint) -> Void
    var connectionEnded: (CGPoint) -> Void
    @State private var dragOrigin: CGPoint?
    private var tint: Color { inChain && !block.bypass ? AudioTheme.accent : .gray }
    private var inChain: Bool { model.activeBlockIDs.contains(block.id) }
    private var title: String { block.kind == .source ? model.session.inputKind.title : block.name }
    private var header: some View {
        HStack(spacing:6) {
            Image(systemName:block.kind == .source ? "waveform" : block.kind == .output ? "speaker.wave.2" : "slider.horizontal.3")
                .font(.system(size:10)).foregroundStyle(block.kind == .effect ? Color.secondary : AudioTheme.accent)
            Text(title).font(.system(size:11,weight:.semibold)).lineLimit(2).help(title)
            Spacer(minLength:0)
        }.padding(.horizontal,9).frame(height:28)
        .contentShape(Rectangle()).gesture(DragGesture(coordinateSpace:.named("audioGraph")).onChanged {value in
            guard !model.running, !model.busy else {return}
            if dragOrigin == nil {
                guard let current = model.session.blocks.first(where:{$0.id == block.id}) else {return}
                dragOrigin = CGPoint(x:current.x,y:current.y)
                model.beginMove()
                model.selected = block.id
            }
            if let origin = dragOrigin {
                model.moveBlock(block.id,to:CGPoint(x:origin.x+value.translation.width,y:origin.y+value.translation.height))
            }
        }.onEnded {_ in dragOrigin = nil;model.endMove()})
    }
    private var effectControls: some View {
        HStack(spacing:4) {
            Text(block.bypass ? "OFF" : inChain ? (block.component?.isGenerator == true ? "Генератор" : "В цепи") : "Вне цепи")
                .font(.system(size:8,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)
                .help(block.bypass ? "Плагин обойдён (bypass)" : inChain ? "В тракте выбранного выхода" : "Соедините порты или вставьте плагин перед выходом")
            Spacer(minLength:0)
            if !inChain {
                Button {model.insertBeforeOutput(block.id)} label: {Image(systemName:"cable.connector")}
                    .help("Вставить перед выходом").accessibilityLabel("Подключить \(title)").disabled(model.running || model.busy)
            }
            Button {model.openEditor(block.id)} label: {Image(systemName:"gearshape")}
                .help("Открыть редактор AU").accessibilityLabel("Редактор \(title)").disabled(model.busy)
            Button {model.bypass(block.id)} label: {
                Image(systemName:"power").foregroundStyle(block.bypass ? Color.secondary : AudioTheme.accent)
            }
            .help(block.bypass ? "Включить плагин" : "Выключить плагин (bypass)")
            .accessibilityLabel(block.bypass ? "Включить \(title)" : "Выключить \(title)")
            .accessibilityValue(block.bypass ? "Выключен" : "Включён").disabled(model.busy)
        }.buttonStyle(CardButtonStyle()).padding(.horizontal,7).frame(height:28)
    }
    private var ioControls: some View {
        VStack(spacing:3) {
            HStack(spacing:4) {
                Text(block.kind == .source ? model.sourceSummary : model.outputSummary)
                    .font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
                    .help(block.kind == .source ? model.sourceSummary : model.outputSummary)
                Spacer(minLength:0)
                Button {model.openEditor(block.id)} label: {Image(systemName:"gearshape")}
                    .buttonStyle(.plain).font(.system(size:10)).frame(width:22,height:20)
                    .contentShape(Rectangle()).help("Настройки блока").accessibilityLabel("Настройки \(title)").disabled(model.busy)
            }.frame(height:14)
            BlockMetersView(meters:model.meters,isInput:block.kind == .source)
            BlockLatencyLabel(telemetry:model.telemetry,id:block.id,active:model.running && inChain)
                .frame(maxWidth:.infinity,alignment:.leading)
                .help("Оценка по очереди, буферу, SRC и HAL. Не измерение физической или беспроводной задержки.")
        }.padding(.horizontal,8).frame(height:76)
    }
    var body: some View {
        VStack(spacing:0) {
            header
            if block.kind == .effect {effectControls} else {ioControls}
        }
        .frame(width:GraphLayout.width(for:block),height:GraphLayout.height(for:block))
        .background(block.bypass ? AudioTheme.surface : AudioTheme.card)
        .clipShape(RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).stroke(model.selected == block.id ? Color.white.opacity(0.9) : AudioTheme.border,lineWidth:model.selected == block.id ? 1.5 : 1))
        .overlay(alignment:.topLeading) {
            if block.kind != .source && block.component?.isGenerator != true {port(input:true).offset(x:-11,y:-2)}
        }
        .overlay(alignment:.topTrailing) {
            if block.kind != .output {port(input:false).offset(x:11,y:-2)}
        }
        .onTapGesture(count:2) {
            guard !model.busy else {return}
            model.selected = block.id; model.openEditor(block.id)
        }
        .onTapGesture(count:1) {model.selected = block.id}
        .contextMenu {
            Button(block.kind == .effect ? "Редактор AU" : "Настройки блока") {model.openEditor(block.id)}
            if block.kind == .effect {
                Button(block.bypass ? "Включить плагин" : "Обойти плагин") {model.bypass(block.id)}.disabled(model.busy)
                Button("Удалить блок",role:.destructive) {model.remove(block.id)}.disabled(model.running || model.busy)
            }
        }
    }
    private func activatePort(input: Bool) {
        guard !model.running, !model.busy else { return }
        if input { model.inputPort(block.id) }
        else { model.pendingPort = model.pendingPort == block.id ? nil : block.id }
    }
    private func port(input: Bool) -> some View {
        let target = input && model.pendingPort != nil && model.pendingPort != block.id && !model.running && !model.busy
        let selected = model.pendingPort == block.id && !input
        return Circle().fill(selected ? Color.white : target ? AudioTheme.accent : tint)
            .frame(width: 9, height: 9).overlay(Circle().stroke(AudioTheme.canvas, lineWidth: 1.5))
            .overlay(Circle().stroke(selected ? Color.white : AudioTheme.accent,lineWidth:1).frame(width:16,height:16).opacity(target || selected ? 1 : 0))
            .frame(width: 22, height: 32).contentShape(Rectangle())
            .accessibilityLabel((input ? "Вход" : "Выход") + " блока " + title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activatePort(input: input) }
            .focusable()
            .onKeyPress(.space) { activatePort(input: input); return .handled }
            .onKeyPress(.return) { activatePort(input: input); return .handled }
            .help(input ? "Вход: завершить соединение" : "Выход: протяните к входу другого блока или нажмите")
            .onTapGesture { activatePort(input: input) }
            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("audioGraph"))
                .onChanged { value in
                    guard !input, !model.running, !model.busy else { return }
                    model.pendingPort = block.id; connectionChanged(value.location)
                }.onEnded { value in
                    guard !input else { return }
                    connectionEnded(value.location)
                })
    }
}

// SwiftUI-drawn chrome stays readable in dark mode and in reproducible view captures.
struct CompactButtonStyle: ButtonStyle {
    var accent: Color? = nil
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7).padding(.vertical, 5)
            .foregroundStyle(accent == nil ? Color.white : Color.black)
            .background(accent ?? Color.white.opacity(configuration.isPressed ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke((accent ?? .white).opacity(0.16)))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct CardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:10)).frame(width:20,height:20)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.035),in:RoundedRectangle(cornerRadius:4))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
    }
}
