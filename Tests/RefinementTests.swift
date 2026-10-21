import SwiftUI
import Combine

@MainActor func runRefinementTests() async -> Int32 {
    let model=AudioModel()
    do {
        let component=ComponentID(type:kAudioUnitType_Effect,subtype:kAudioUnitSubType_NBandEQ,manufacturer:kAudioUnitManufacturer_Apple)
        for i in 0..<128 {model.session.blocks.append(Block(kind:.effect,name:"EQ \(i)",x:24,y:200,component:component))}
        let original=GraphEditState(model.session)
        var publications=0
        let token=model.objectWillChange.sink {publications += 1}
        model.arrange()
        print("ARRANGE blocks=\(model.session.blocks.count) model_publications=\(publications)")
        try check(publications==1,"Arrange publishes intermediate coordinates: \(publications)")
        let arranged=GraphEditState(model.session)
        publications=0;model.arrange()
        try check(publications==0,"No-op alignment publishes")
        token.cancel()
        try check(model.session.wires==original.wires,"Alignment changed routing")
        try check(arranged.blocks.allSatisfy {$0.y==76},"Alignment wrapped")
        model.session=Session.empty;model.editHistory.clear()
        model.session.blocks[0].x=90;model.session.blocks[1].y=240
        let before=GraphEditState(model.session)
        model.arrange();await model.undoEdit()
        try check(GraphEditState(model.session)==before,"Batched arrangement undo lost original layout")
        await model.redoEdit()
        try check(model.session.blocks[0].x==24 && model.session.blocks[1].y==76,"Batched arrangement redo failed")
        var fixture=Session.empty
        let effects=(0..<128).map {Block(kind:.effect,name:"EQ \($0)",x:Double($0)*172,y:76,component:component)}
        let route=[fixture.blocks[0]]+effects+[fixture.blocks[1]]
        fixture.blocks=route;fixture.wires=zip(route,route.dropFirst()).map {Wire(from:$0.id,to:$1.id)}
        model.session=fixture
        let builds=model.diagnosticPlaybackRouteBuilds
        for _ in 0..<100 {model.samplePlaybackTelemetry();_ = model.hasActiveEffects;_ = model.activeBlockIDs}
        try check(model.diagnosticPlaybackRouteBuilds==builds+1,"Unchanged telemetry repeatedly validates the route")
        try check(try model.playbackRoute()==fixture.orderedChain(),"Cached route changed stable order")
        var old:[Double]=[],cached:[Double]=[]
        for _ in 0..<7 {
            var checksum=0
            var time=DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 {checksum += try fixture.orderedChain().count}
            old.append(Double(DispatchTime.now().uptimeNanoseconds-time)/1e6)
            time=DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 {checksum -= try model.playbackRoute().count}
            cached.append(Double(DispatchTime.now().uptimeNanoseconds-time)/1e6)
            try check(checksum==0,"Cached route differs")
        }
        model.session.blocks[1].bypass=true;model.session.blocks[1].name="Renamed"
        try check(try model.playbackRoute()[1].bypass && model.playbackRoute()[1].name=="Renamed","Cache retained old AU metadata")
        model.moveBlock(effects[0].id,to:CGPoint(x:900,y:700))
        try check(try model.playbackRoute()[1].x==900,"Cache retained old coordinates")
        model.session.wires=[]
        try check((try? model.playbackRoute())==nil,"Disconnected route retained valid cache")
        let invalidBuilds=model.diagnosticPlaybackRouteBuilds
        model.samplePlaybackTelemetry();model.samplePlaybackTelemetry()
        try check(model.diagnosticPlaybackRouteBuilds==invalidBuilds,"Invalid route rebuilt without edits")
        model.session=fixture;model.session.bufferFrames=3
        try check((try? model.playbackRoute())==nil,"Invalid buffer bypassed route validation")
        model.session=fixture;model.session.volume = .nan
        try check((try? model.playbackRoute())==nil,"Invalid volume bypassed route validation")
        model.session=fixture
        try check(try model.playbackRoute()==fixture.orderedChain(),"Route not restored after invalid settings")
        print("ROUTE_CACHE blocks=130 reads=100 uncached_median_ms=\(old.sorted()[3]) cached_median_ms=\(cached.sorted()[3]); route validation only, not audio DSP CPU")
        await model.shutdown()
        print("PASS: batched 130-block arrangement, no-op publication suppression, routing preserved")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}
