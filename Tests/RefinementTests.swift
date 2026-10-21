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
        await model.shutdown()
        print("PASS: batched 130-block arrangement, no-op publication suppression, routing preserved")
        return 0
    } catch {await model.shutdown();print("FAIL: \(error)");return 1}
}
