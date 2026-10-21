import SwiftUI

enum AudioTheme {
    static let gridTile = NSImage(size:NSSize(width:24,height:24),flipped:true) {_ in
        NSColor.white.withAlphaComponent(0.045).setFill()
        NSBezierPath(ovalIn:NSRect(x:15,y:15,width:1.5,height:1.5)).fill()
        return true
    }
    static let appIcon = Bundle.main.url(forResource:"AudioChain",withExtension:"icns").flatMap {NSImage(contentsOf:$0)} ?? NSImage(named:NSImage.applicationIconName) ?? NSImage()
    static let canvas = Color(red: 0.065, green: 0.075, blue: 0.09)
    static let surface = Color(red: 0.095, green: 0.108, blue: 0.125)
    static let card = Color(red: 0.125, green: 0.14, blue: 0.16)
    static let accent = Color(red: 0.10, green: 0.84, blue: 0.73)
    static let border = Color.white.opacity(0.10)
}

// Same cubic for the visible cable, hit target and direction marker. Short
// forward connections must not get control points that reverse their tangent.
struct CableCurve {
    let from: CGPoint
    let to: CGPoint
    var bend: Double {
        let dx = to.x - from.x
        return dx >= 0 ? max(1, min(110, dx * 0.45)) : max(48, min(140, -dx * 0.5))
    }
    var control1: CGPoint { CGPoint(x:from.x + bend,y:from.y) }
    var control2: CGPoint { CGPoint(x:to.x - bend,y:to.y) }
    var path: Path {
        var path = Path(); path.move(to:from)
        path.addCurve(to:to,control1:control1,control2:control2)
        return path
    }
    var arrow: Path {
        let a = control1, b = control2
        let center = CGPoint(x:(from.x+3*a.x+3*b.x+to.x)/8,y:(from.y+3*a.y+3*b.y+to.y)/8)
        let dx = 0.75*(a.x-from.x)+1.5*(b.x-a.x)+0.75*(to.x-b.x)
        let dy = 0.75*(a.y-from.y)+1.5*(b.y-a.y)+0.75*(to.y-b.y)
        let length = max(0.001,hypot(dx,dy)), ux = dx/length, uy = dy/length
        var path = Path()
        path.move(to:CGPoint(x:center.x+ux*3.5,y:center.y+uy*3.5))
        path.addLine(to:CGPoint(x:center.x-ux*3.5-uy*2.5,y:center.y-uy*3.5+ux*2.5))
        path.addLine(to:CGPoint(x:center.x-ux*3.5+uy*2.5,y:center.y-uy*3.5-ux*2.5))
        path.closeSubpath(); return path
    }
}

// Presentation state only; never changes PCM or the sample-peak meter.
struct MeterPeakHold: Equatable {
    private(set) var peak = -Double.infinity
    private var peakUntil = 0.0
    private(set) var clipUntil = 0.0
    private var lastLevel = -Double.infinity
    mutating func update(_ level: Double, at time: Double) {
        defer {lastLevel = level}
        if level == .infinity || level.isNaN { peak = .infinity; peakUntil = time; return }
        if !peak.isFinite || level >= peak {
            peak = level; peakUntil = time + 1.2
        } else if lastLevel == peak {
            // Begin the hold on a falling edge, including after a long steady
            // level. No periodic timer is needed to keep renewing a deadline.
            peakUntil = time + 1.2
        } else if time >= peakUntil {
            peak = level; peakUntil = time + 1.2
        }
        if level.isFinite && level >= 0 || lastLevel.isFinite && lastLevel >= 0 { clipUntil = time + 2 }
    }
    func nextUpdate(for level: Double, at time: Double) -> Double? {
        let peakDue = peak.isFinite && peak > level && peakUntil > time ? peakUntil : nil
        // A steady overload needs no timer: it remains indicated until the
        // level changes. Only a lower level needs a delayed clearing event.
        let clipDue = level < 0 && clipUntil > time ? clipUntil : nil
        if let peakDue, let clipDue {return min(peakDue,clipDue)}
        return peakDue ?? clipDue
    }
}

struct GraphDisplayIndex {
    var blocks: [UUID:Block] = [:]
    var width = 24.0
    var height = 24.0
    init(_ items:[Block]) {
        blocks.reserveCapacity(items.count)
        for block in items {
            if blocks[block.id] == nil {blocks[block.id] = block}
            width = max(width,block.x+GraphLayout.width(for:block)+24)
            height = max(height,block.y+GraphLayout.height(for:block)+24)
        }
    }
}

struct StatusPresentation {
    let text: String
    let needsAttention: Bool
    init(status:String,running:Bool,direct:Bool,busy:Bool,muted:Bool,volume:Float) {
        needsAttention = status.hasPrefix("Не удалось") || status.hasPrefix("Ошибка") ||
            status.hasPrefix("Захват остановлен") || status.hasPrefix("Для включения плагина")
        if needsAttention {text = status}
        else if busy {text = "Подготовка…"}
        else if running {
            let suffix = muted || volume == 0 ? " · MUTE" : volume < 1 ? " · \(Int(volume*100))%" : ""
            text = (direct ? "Прямой PCM" : "AU-цепочка")+suffix
        } else {text = status.hasPrefix("Готово.") ? "Готово" : status}
    }
}
