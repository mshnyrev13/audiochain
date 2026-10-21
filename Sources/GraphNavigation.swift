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
enum GraphBlockLookup {
    static func matches(_ session:Session,query:String)->[(offset:Int,element:Block)] {
        let text=query.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("#") {
            let digits=text.dropFirst()
            if !digits.isEmpty,digits.utf8.allSatisfy({48...57 ~= $0}) {
                guard let number=Int(digits),number>0,number<=session.blocks.count else {return []}
                return [(number-1,session.blocks[number-1])]
            }
        }
        return session.blocks.enumerated().filter {
            text.isEmpty || ($0.element.kind == .source ? session.inputKind.title:$0.element.name).localizedCaseInsensitiveContains(text)
        }
    }
}
struct GraphSearch:View {
    @ObservedObject var model:AudioModel
    let navigator:GraphNavigator
    let zoom:Double
    let close:()->Void
    @State private var query=""
    @State private var highlighted:UUID?
    private func title(_ block:Block)->String {block.kind == .source ? model.session.inputKind.title : block.name}
    var body:some View {
        let results=GraphBlockLookup.matches(model.session,query:query)
        let ids=results.map { $0.element.id }
        let current=highlighted.flatMap {ids.contains($0) ? $0:nil} ?? ids.first
        VStack(alignment:.leading,spacing:8) {
            GraphSearchField(text:$query,onMove:{move($0,ids:ids,current:current)},
                onSubmit:{if let block=results.first(where:{$0.element.id==current})?.element {choose(block)}},onCancel:close)
                .frame(height:22).onChange(of:query) {_,_ in highlighted=nil}
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:2) {
                        ForEach(results,id:\.element.id) {item in
                            let block=item.element
                            Button {choose(block)} label: {
                                HStack(spacing:7) {
                                    Image(systemName:block.kind == .source ? "waveform" : block.kind == .output ? "speaker.wave.2" : "slider.horizontal.3")
                                        .foregroundStyle(AudioTheme.accent).frame(width:16)
                                    Text(title(block)).lineLimit(2)
                                    Spacer(minLength:2)
                                    if block.bypass {Image(systemName:"power").foregroundStyle(.secondary).help("Эффект обойдён")}
                                    Text("#\(item.offset+1)").monospacedDigit().foregroundStyle(.secondary)
                                }.font(.system(size:11)).frame(maxWidth:.infinity,alignment:.leading)
                                    .padding(7).contentShape(Rectangle())
                                    .background(block.id==current ? AudioTheme.accent.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:5))
                            }.buttonStyle(.plain).id(block.id)
                                .accessibilityLabel("\(title(block)), блок \(item.offset+1)"+(block.bypass ? ", выключен":""))
                                .accessibilityAddTraits(block.id==current ? [.isSelected]:[])
                        }
                        if results.isEmpty {Text("Блоки не найдены").foregroundStyle(.secondary).padding(6)}
                    }
                }.frame(maxHeight:240)
                    .onChange(of:current) {_,id in if let id {proxy.scrollTo(id,anchor:.center)}}
            }
            Text("\(results.count) из \(model.session.blocks.count) · ↑↓ выбор · Enter перейти · Esc закрыть")
                .font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(12).frame(width:280)
    }
    private func move(_ delta:Int,ids:[UUID],current:UUID?) {
        guard !ids.isEmpty else {return}
        let index=current.flatMap {ids.firstIndex(of:$0)} ?? 0
        highlighted=ids[max(0,min(ids.count-1,index+delta))]
    }
    private func choose(_ block:Block) {model.selected=block.id;navigator.reveal(block,zoom:zoom);close()}
}

// NSTextField consumes arrow commands before SwiftUI key handlers. Intercept
// only navigation commands; leave text editing, IME and shortcuts to AppKit.
struct GraphSearchField:NSViewRepresentable {
    @Binding var text:String
    let onMove:(Int)->Void
    let onSubmit:()->Void
    let onCancel:()->Void
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->SearchField {
        let field=SearchField()
        field.placeholderString="Название или #номер";field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize:12);field.delegate=context.coordinator
        field.setAccessibilityLabel("Найти блок")
        return field
    }
    func updateNSView(_ field:SearchField,context:Context) {
        context.coordinator.parent=self
        if field.stringValue != text {field.stringValue=text}
    }
    final class SearchField:NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async {[weak self] in
                guard let self,let window=self.window else {return}
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator:NSObject,NSTextFieldDelegate {
        var parent:GraphSearchField
        init(_ parent:GraphSearchField) {self.parent=parent}
        func controlTextDidChange(_ notification:Notification) {
            if let field=notification.object as? NSTextField {parent.text=field.stringValue}
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy command:Selector)->Bool {
            // Marked text belongs to the input method, including Return/Escape.
            guard !textView.hasMarkedText() else {return false}
            switch command {
            case #selector(NSResponder.moveDown(_:)):parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):parent.onCancel()
            default:return false
            }
            return true
        }
    }
}
