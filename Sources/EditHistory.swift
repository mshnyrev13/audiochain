import Foundation
import Combine

struct GraphEditState: Equatable {
    var blocks:[Block]
    var wires:[Wire]
    init(_ session:Session) {blocks=session.blocks;wires=session.wires}
    func applying(to session:Session) -> Session {
        var result=session;result.blocks=blocks;result.wires=wires;return result
    }
}
struct GraphEditEntry {
    var state:GraphEditState
    let selection:UUID?
    let name:String
}
@MainActor final class EditHistory: ObservableObject {
    @Published private(set) var undoName:String? = nil
    @Published private(set) var redoName:String? = nil
    private var past:[GraphEditEntry]=[], future:[GraphEditEntry]=[]
    var undoTarget:GraphEditEntry? {past.last}
    var redoTarget:GraphEditEntry? {future.last}
    private func publish() {undoName=past.last?.name;redoName=future.last?.name}
    func record(_ entry:GraphEditEntry) {
        past.append(entry);future.removeAll()
        if past.count>50 {past.removeFirst(past.count-50)}
        publish()
    }
    func commit(redo:Bool,current:GraphEditEntry) {
        if redo {_=future.popLast();past.append(current)}
        else {_=past.popLast();future.append(current)}
        publish()
    }
    func clear() {past.removeAll();future.removeAll();publish()}
}
