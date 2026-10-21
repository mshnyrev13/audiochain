import SwiftUI
import AppKit

@MainActor final class GraphViewport: ObservableObject {
    @Published private(set) var rect:CGRect = .zero
    func update(_ value:CGRect) {if value != rect {rect=value}}
}
@MainActor final class GraphNavigator {
    weak var scrollView:NSScrollView?
    let viewport=GraphViewport()
    func center(_ point:CGPoint) {
        guard point.x.isFinite,point.y.isFinite,let scrollView,let document=scrollView.documentView else {return}
        let clip=scrollView.contentView
        let x=max(0,min(max(0,document.bounds.width-clip.bounds.width),point.x-clip.bounds.width/2))
        let y=max(0,min(max(0,document.bounds.height-clip.bounds.height),point.y-clip.bounds.height/2))
        clip.scroll(to:CGPoint(x:x,y:y));scrollView.reflectScrolledClipView(clip)
        viewport.update(clip.bounds)
    }
    func reveal(_ block:Block,zoom:Double) {
        center(CGPoint(x:(block.x+GraphLayout.width(for:block)/2)*zoom,y:(block.y+GraphLayout.height(for:block)/2)*zoom))
    }
}
struct GraphScrollAccessor:NSViewRepresentable {
    let navigator:GraphNavigator
    func makeNSView(context:Context) -> ScrollAttachment {ScrollAttachment(navigator:navigator)}
    func updateNSView(_ view:ScrollAttachment,context:Context) {view.attachSoon()}
    final class ScrollAttachment:NSView {
        let navigator:GraphNavigator
        var token:NSObjectProtocol?
        init(navigator:GraphNavigator) {self.navigator=navigator;super.init(frame:.zero)}
        required init?(coder:NSCoder) {fatalError()}
        override func hitTest(_ point:NSPoint) -> NSView? {nil}
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();attachSoon()}
        func attachSoon() {
            DispatchQueue.main.async {[weak self] in
                guard let self,let scroll=self.enclosingScrollView else {return}
                if self.navigator.scrollView !== scroll || self.token == nil {
                    if let token=self.token {NotificationCenter.default.removeObserver(token)}
                    self.navigator.scrollView=scroll
                    scroll.contentView.postsBoundsChangedNotifications=true
                    self.token=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) {[weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self,let clip=self.navigator.scrollView?.contentView else {return}
                            self.navigator.viewport.update(clip.bounds)
                        }
                    }
                }
                self.navigator.viewport.update(scroll.contentView.bounds)
            }
        }
        deinit {if let token {NotificationCenter.default.removeObserver(token)}}
    }
}

struct GraphMiniMap:View {
    @ObservedObject var viewport:GraphViewport
    let blocks:[Block]
    let wires:[Wire]
    let extent:CGSize
    let zoom:Double
    let navigator:GraphNavigator
    let selected:UUID?
    private func transform(_ size:CGSize) -> (Double,CGPoint) {
        let scale=min((size.width-12)/max(1,extent.width),(size.height-12)/max(1,extent.height))
        return (scale,CGPoint(x:(size.width-extent.width*scale)/2,y:(size.height-extent.height*scale)/2))
    }
    var body:some View {
        GeometryReader {geometry in
            let (scale,origin)=transform(geometry.size)
            Canvas {context,size in
                let byID=Dictionary(blocks.map {($0.id,$0)},uniquingKeysWith:{first,_ in first})
                for wire in wires {
                    guard let a=byID[wire.from],let b=byID[wire.to] else {continue}
                    var path=Path();path.move(to:CGPoint(x:origin.x+(a.x+GraphLayout.width(for:a))*scale,y:origin.y+(a.y+14)*scale))
                    path.addLine(to:CGPoint(x:origin.x+b.x*scale,y:origin.y+(b.y+14)*scale))
                    context.stroke(path,with:.color(AudioTheme.accent.opacity(0.45)),lineWidth:1)
                }
                for block in blocks {
                    let rect=CGRect(x:origin.x+block.x*scale,y:origin.y+block.y*scale,width:max(3,GraphLayout.width(for:block)*scale),height:max(3,GraphLayout.height(for:block)*scale))
                    context.fill(Path(roundedRect:rect,cornerRadius:1),with:.color(block.kind == .effect ? .gray : AudioTheme.accent))
                    if block.id == selected {context.stroke(Path(rect.insetBy(dx:-1,dy:-1)),with:.color(.white),lineWidth:1.5)}
                }
                let r=viewport.rect
                let visible=CGRect(x:origin.x+r.minX/zoom*scale,y:origin.y+r.minY/zoom*scale,width:r.width/zoom*scale,height:r.height/zoom*scale)
                let clipped=visible.intersection(CGRect(origin:origin,size:CGSize(width:extent.width*scale,height:extent.height*scale)))
                if !clipped.isNull && !clipped.isEmpty {context.stroke(Path(clipped),with:.color(.white.opacity(0.9)),lineWidth:1)}
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged {value in
                navigator.center(CGPoint(x:(value.location.x-origin.x)/scale*zoom,y:(value.location.y-origin.y)/scale*zoom))
            })
        }.frame(width:156,height:76).clipped()
            .background(AudioTheme.surface,in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(AudioTheme.border))
            .accessibilityLabel("Мини-карта схемы").help("Нажмите или перетащите на мини-карте для перехода к части схемы")
    }
}
struct GraphSearch:View {
    @ObservedObject var model:AudioModel
    let navigator:GraphNavigator
    let zoom:Double
    let close:()->Void
    @State private var query=""
    @FocusState private var focused:Bool
    private var matches:[Block] {
        model.session.blocks.filter {query.isEmpty || title($0).localizedCaseInsensitiveContains(query)}
    }
    private func title(_ block:Block)->String {block.kind == .source ? model.session.inputKind.title : block.name}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("Найти блок…",text:$query).focused($focused).textFieldStyle(.roundedBorder)
                .onSubmit {if let first=matches.first {choose(first)}}
            ScrollView {
                LazyVStack(alignment:.leading,spacing:2) {
                    ForEach(matches) {block in
                        Button {choose(block)} label: {
                            HStack {Text(title(block)).lineLimit(2);Spacer();if block.bypass {Text("OFF").foregroundStyle(.secondary)}}
                                .frame(maxWidth:.infinity,alignment:.leading).padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty {Text("Блоки не найдены").foregroundStyle(.secondary).padding(6)}
                }
            }.frame(maxHeight:240)
            Text("\(matches.count) из \(model.session.blocks.count) · Enter — перейти").font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(width:260).onAppear {focused=true}
    }
    private func choose(_ block:Block) {model.selected=block.id;navigator.reveal(block,zoom:zoom);close()}
}
