import SwiftUI

@MainActor func runDesignUITests() throws {
    var hold = MeterPeakHold()
    hold.update(-6,at:10);hold.update(-18,at:10.5)
    try check(hold.peak == -6,"Peak marker did not hold")
    hold.update(-18,at:11.8)
    try check(hold.peak == -18,"Peak marker did not release")
    hold.update(0.1,at:12);hold.update(-30,at:12.5)
    try check(hold.peak == 0.1 && hold.clipUntil == 14.5,"Overload hold failed")
    hold.update(-30,at:14.6)
    try check(hold.peak == -30 && hold.clipUntil < 14.6,"Overload indicator stuck")
    hold.update(.infinity,at:15);hold.update(-9,at:15.1)
    try check(hold.peak == -9,"Fault marker did not recover")
    hold.update(.nan,at:16);hold.update(-.infinity,at:16.1)
    try check(hold.peak == -.infinity,"Fault -> silence did not recover")
    for distance in [8.0,18,32,80,300] {
        let cable = CableCurve(from:CGPoint(x:0,y:0),to:CGPoint(x:distance,y:0))
        var points: [CGPoint] = []
        cable.arrow.forEach {element in
            switch element {case .move(to:let point),.line(to:let point):points.append(point);default:break}
        }
        try check(points.count == 3 && points[0].x > points[1].x,"Short forward cable arrow reversed")
        try check(cable.control1.x <= cable.control2.x,"Short cable folds back")
    }
    let model = AudioModel()
    for i in 0..<12 {model.session.blocks.append(Block(kind:.effect,name:"EQ \(i)",x:24,y:100,component:ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)))}
    let wires = model.session.wires
    model.arrange()
    let blocks = model.session.blocks.sorted {$0.x < $1.x}
    for pair in zip(blocks,blocks.dropFirst()) {
        try check(pair.1.x-pair.0.x >= GraphLayout.width(for:pair.0)+GraphLayout.gap-0.001,"Variable-width cards overlap")
        try check(pair.0.y == pair.1.y,"Long chain wrapped")
    }
    try check(model.session.wires == wires,"Visual alignment changed routing")
    var steady = MeterPeakHold()
    steady.update(-6,at:0)
    try check(steady.nextUpdate(for:-6,at:0) == nil,"Steady signal scheduled idle wakeups")
    steady.update(-20,at:100)
    try check(steady.peak == -6 && steady.nextUpdate(for:-20,at:100) == 101.2,"Long steady peak lost on falling edge")
    steady.update(-20,at:101.3)
    try check(steady.peak == -20 && steady.nextUpdate(for:-20,at:101.3) == nil,"Released peak still schedules wakeups")
    steady.update(1,at:200)
    try check(steady.nextUpdate(for:1,at:200) == nil,"Steady overload scheduled timer")
    steady.update(-20,at:400)
    try check(steady.clipUntil == 402,"Long steady overload did not hold after return below full scale")
    let action = "Для включения плагина нажмите Стоп, затем Старт."
    let notice = StatusPresentation(status:action,running:true,direct:true,busy:false,muted:false,volume:1)
    try check(notice.needsAttention && notice.text == action,"PCM restart instruction hidden by running status")
    let silent = StatusPresentation(status:"AU-цепочка",running:true,direct:false,busy:false,muted:false,volume:0)
    try check(silent.text.contains("MUTE"),"Zero output fader is not labelled muted")
    let index = GraphDisplayIndex(model.session.blocks)
    try check(index.blocks.count == model.session.blocks.count && index.width >= blocks.last!.x+GraphLayout.width(for:blocks.last!),"Display index lost block extent")
    print("PASS: peak/clip expiry and fault recovery, short-cable arrows, variable-width 14-card alignment without wrapping or routing changes")
}
