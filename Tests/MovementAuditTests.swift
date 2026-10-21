import SwiftUI
import Combine

@MainActor func runMovementAudit() async -> Int32 {
    let model=AudioModel()
    do {
        var initial=Session.empty
        let component=ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
        let effects=(0..<128).map {Block(kind:.effect,name:"EQ \($0)",x:24+Double($0)*172,y:76,component:component)}
        initial.blocks += effects
        let route=[initial.blocks[0]]+effects+[initial.blocks[1]]
        initial.wires=zip(route,route.dropFirst()).map {Wire(from:$0.id,to:$1.id)}
        let index=initial.blocks.count-1, id=initial.blocks[index].id
        var changes=0
        let subscription=model.objectWillChange.sink {changes += 1}
        var oldTimes:[Double]=[],newTimes:[Double]=[]
        for _ in 0..<7 {
            var checksums:[Int]=[],publications:[Int]=[],builds:[Int]=[]
            for optimized in [false,true] {
                model.session=initial;_ = model.activeBlockIDs
                let before=model.diagnosticActiveRouteBuilds;changes=0
                var checksum=0
                let start=DispatchTime.now().uptimeNanoseconds
                for step in 0..<100 {
                    let point=CGPoint(x:25+Double(step),y:77+Double(step))
                    if optimized {model.moveBlock(id,to:point)}
                    else {model.session.blocks[index].x=point.x;model.session.blocks[index].y=point.y}
                    checksum += model.activeBlockIDs.count
                }
                let ms=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
                if optimized {newTimes.append(ms)} else {oldTimes.append(ms)}
                checksums.append(checksum);publications.append(changes);builds.append(model.diagnosticActiveRouteBuilds-before)
                try check(model.session.wires==initial.wires,"Movement changed routing")
                try check(model.session.blocks[index].x==124 && model.session.blocks[index].y==176,"Movement changed final coordinates")
            }
            try check(checksums[0]==checksums[1],"Movement changed active IDs")
            try check(publications==[200,100] && builds==[100,0],"Movement still duplicates notifications or route validation: \(publications), \(builds)")
        }
        let last=model.session.blocks[index]
        changes=0
        model.moveBlock(id,to:CGPoint(x:last.x,y:last.y))
        model.moveBlock(id,to:CGPoint(x:Double.infinity,y:0))
        model.moveBlock(UUID(),to:CGPoint(x:24,y:76))
        try check(changes==0,"No-op or invalid move published")
        model.running=true;changes=0
        model.moveBlock(id,to:CGPoint(x:200,y:200))
        try check(changes==0 && model.session.blocks[index].x==last.x,"Move accepted while running")
        model.running=false;model.busy=true;changes=0
        model.moveBlock(id,to:CGPoint(x:200,y:200))
        try check(changes==0,"Move accepted while preparing")
        model.busy=false
        model.session.blocks[index].x = .nan
        try check(model.activeBlockIDs.isEmpty,"Invalid coordinate not rejected")
        model.moveBlock(id,to:CGPoint(x:-10,y:-10))
        try check(model.activeBlockIDs.count==route.count && model.session.blocks[index].x==24 && model.session.blocks[index].y==70,"Coordinate repair retained stale invalid route")
        model.session.wires=[]
        try check(model.activeBlockIDs.isEmpty,"Cable change retained stale active route")
        model.session=initial
        try check(model.activeBlockIDs.count==route.count,"Restored routing stayed stale")
        subscription.cancel()
        print("MOVE_BENCH blocks=\(route.count) moves=100 old_median_ms=\(oldTimes.sorted()[3]) new_median_ms=\(newTimes.sorted()[3]) old_publications=200 new_publications=100 old_route_builds=100 new_route_builds=0; model only, not GPU/frame timing")
        print("PASS: identical final coordinates/active IDs/wires; invalid/no-op/running/busy moves rejected; invalid-coordinate repair and cable changes invalidate route cache")
        await model.shutdown();return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}

func runConnectionIndexAudit() throws {
    var seed:UInt64=417
    func next(_ n:Int)->Int {seed=seed &* 6364136223846793005 &+ 1;return Int((seed>>32)%UInt64(n))}
    for iteration in 0..<240 {
        let ids=(0..<40).map {_ in UUID()}, active=Set(ids.prefix(30))
        var wires:[Wire]=[]
        for _ in 0..<120 {
            let a=next(ids.count),b=next(ids.count)
            if a<b {let w=Wire(from:ids[a],to:ids[b]);if !wires.contains(w) {wires.append(w)}}
        }
        let filtered=wires.filter {active.contains($0.from) && active.contains($0.to)}
        let index=AudioConnectionIndex(wires:wires,active:active)
        for id in ids {
            try check(index.incoming[id,default:[]]==filtered.filter {$0.to==id},"Mixer input bus order changed in graph \(iteration)")
            try check(index.outgoing[id,default:[]]==filtered.filter {$0.from==id},"Fan-out order changed in graph \(iteration)")
        }
    }
    for count in [128,512,2048] {
        let ids=(0..<count).map {_ in UUID()},active=Set(ids)
        let wires=zip(ids,ids.dropFirst()).map {Wire(from:$0,to:$1)}
        var old:[Double]=[],new:[Double]=[]
        for _ in 0..<7 {
            var oldChecksum=0,newChecksum=0
            var t=DispatchTime.now().uptimeNanoseconds
            for id in ids {oldChecksum += wires.filter {$0.to==id}.count+wires.filter {$0.from==id}.count}
            old.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
            t=DispatchTime.now().uptimeNanoseconds
            let index=AudioConnectionIndex(wires:wires,active:active)
            for id in ids {newChecksum += index.incoming[id,default:[]].count+index.outgoing[id,default:[]].count}
            new.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
            try check(oldChecksum==newChecksum,"Connection index checksum changed")
        }
        print("WIRING_INDEX blocks=\(count) old_median_ms=\(old.sorted()[3]) new_median_ms=\(new.sorted()[3]); cable grouping only, not AU initialization time")
    }
    print("PASS: 240 ordered cable graphs preserve every mixer bus/fan-out order and exclude detached endpoints")
}
