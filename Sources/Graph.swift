import Foundation
import AudioToolbox

enum BlockKind: String, Codable { case source, effect, output }
enum GraphLayout {
    static let portY = 14.0
    static let gap = 32.0
    static func width(for block: Block) -> Double { block.kind == .effect ? 140 : 164 }
    static func height(for block: Block) -> Double { block.kind == .effect ? 56 : 104 }
}
struct ComponentID: Codable, Equatable {
    var type: UInt32; var subtype: UInt32; var manufacturer: UInt32
    var isGenerator: Bool { type == kAudioUnitType_Generator || type == kAudioUnitType_MusicDevice }
    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}
struct Block: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: BlockKind
    var name: String
    var x: Double
    var y: Double
    var component: ComponentID? = nil
    var bypass = false
    var state: Data? = nil
}
struct Wire: Codable, Hashable { var from: UUID; var to: UUID }
enum InputKind: String, Codable, CaseIterable {
    case device, system, application, file
    var title: String {
        switch self { case .device: return "Аудиовход"; case .system: return "Звук системы"
        case .application: return "Приложение"; case .file: return "Аудиофайл" }
    }
}
struct Session: Codable {
    var version = 1
    var blocks: [Block]
    var wires: [Wire]
    var inputKind: InputKind = .system
    var inputUID = ""
    var outputUID = ""
    var applicationBundleID = ""
    var systemExcludedBundleIDs: [String]? = nil
    var outputMuted: Bool? = nil
    var filePath = ""
    var volume: Float = 1
    // Missing in old presets: nil means preserve the device's current buffer.
    var bufferFrames: UInt32? = 512
    static var empty: Session {
        let a = Block(kind: .source, name: "Источник", x: 24, y: 76)
        let b = Block(kind: .output, name: "Выход", x: 220, y: 76)
        return Session(blocks: [a,b], wires: [Wire(from: a.id, to: b.id)])
    }
    // Index once: validation and ancestor traversal must not rescan all cables per node.
    private func graphIndex() throws -> (order: [UUID], incoming: [UUID: [UUID]]) {
        if let excluded = systemExcludedBundleIDs {
            guard Set(excluded).count == excluded.count, excluded.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AudioFailure("Некорректный список исключённых приложений.") }
        }
        guard version == 1 else { throw AudioFailure("Неизвестная версия схемы.") }
        if let bufferFrames, !Devices.bufferChoices.contains(bufferFrames) { throw AudioFailure("Некорректный размер буфера в схеме.") }
        guard volume.isFinite, volume >= 0, volume <= 1,
              Set(blocks.map(\.id)).count == blocks.count,
              blocks.filter({ $0.kind == .source }).count == 1,
              blocks.filter({ $0.kind == .output }).count == 1 else {
            throw AudioFailure("Схема должна содержать один источник и один выход.")
        }
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var incoming = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, [UUID]()) })
        var outgoing = incoming
        guard Set(wires).count == wires.count else { throw AudioFailure("Повторное соединение.") }
        for wire in wires {
            guard let from = byID[wire.from], let to = byID[wire.to], wire.from != wire.to,
                  from.kind != .output, to.kind != .source else { throw AudioFailure("Недопустимое соединение.") }
            incoming[wire.to]!.append(wire.from); outgoing[wire.from]!.append(wire.to)
        }
        for block in blocks {
            guard block.x.isFinite, block.y.isFinite, block.x >= 0, block.y >= 0,
                  block.kind != .effect || PluginCatalog.supported.contains(block.component?.type ?? 0) else {
                throw AudioFailure("Некорректный AU или координаты блока.")
            }
            if block.component?.isGenerator == true && !incoming[block.id]!.isEmpty {
                throw AudioFailure("Генератор создаёт звук сам и не принимает аудиовход.")
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
        var degrees = incoming.mapValues(\.count)
        // Descending indices: popLast always preserves the document's stable order.
        var ready = blocks.indices.filter { degrees[blocks[$0].id] == 0 }.reversed().map { $0 }
        var order: [UUID] = []; order.reserveCapacity(blocks.count)
        while let index = ready.popLast() {
            let id = blocks[index].id; order.append(id)
            for next in outgoing[id]! {
                degrees[next]! -= 1
                if degrees[next] == 0 {
                    let value = rank[next]!
                    var low = 0, high = ready.count
                    while low < high { let mid = (low+high)/2; if ready[mid] > value { low = mid+1 } else { high = mid } }
                    ready.insert(value, at: low)
                }
            }
        }
        guard order.count == blocks.count else { throw AudioFailure("В схеме есть цикл.") }
        return (order, incoming)
    }
    func validateEditingGraph() throws { _ = try graphIndex() }
    // All ancestors of the output, in stable topological order. Detached blocks stay editable.
    func orderedChain() throws -> [Block] {
        let index = try graphIndex()
        guard let output = blocks.first(where: { $0.kind == .output }) else { throw AudioFailure("Нет выхода.") }
        var active: Set<UUID> = [output.id], pending = [output.id]
        while let id = pending.popLast() {
            for previous in index.incoming[id]! where active.insert(previous).inserted { pending.append(previous) }
        }
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        return try index.order.filter { active.contains($0) }.map { id in
            let block = byID[id]!
            guard block.kind == .source || block.component?.isGenerator == true || !index.incoming[id]!.isEmpty else {
                throw AudioFailure("Нет входного сигнала у «\(block.name)». Соедините блок с источником или генератором.")
            }
            return block
        }
    }
    func canUseDirectPCM(_ route: [Block]) -> Bool {
        guard route.contains(where: { $0.kind == .source }),
              !route.contains(where: { $0.kind == .effect && (!$0.bypass || $0.component?.isGenerator == true) }) else { return false }
        let ids = Set(route.map(\.id))
        var incoming: Set<UUID> = [], outgoing: Set<UUID> = []
        for wire in wires where ids.contains(wire.from) && ids.contains(wire.to) {
            if !outgoing.insert(wire.from).inserted || !incoming.insert(wire.to).inserted { return false }
        }
        return true
    }
    mutating func insertBeforeOutput(_ id: UUID) throws {
        guard blocks.contains(where: { $0.id == id && $0.kind == .effect }) else { throw AudioFailure("Выберите плагин.") }
        let chain = try orderedChain()
        guard !chain.contains(where: { $0.id == id }) else { return }
        if blocks.first(where: { $0.id == id })?.component?.isGenerator == true { try connect(from: id, to: chain.last!.id); return }
        guard !wires.contains(where: { $0.from == id || $0.to == id }),
              let output = chain.last, chain.count >= 2 else { throw AudioFailure("Сначала отключите провода этого блока или соедините его вручную.") }
        guard wires.filter({ $0.to == output.id }).count == 1, let previousID = wires.first(where: { $0.to == output.id })?.from,
              let previous = blocks.first(where: { $0.id == previousID }) else { throw AudioFailure("У выхода несколько веток. Подключите новый плагин вручную.") }
        let old = wires
        do {
            wires.removeAll { $0.from == previous.id && $0.to == output.id }
            try connect(from: previous.id, to: id)
            try connect(from: id, to: output.id)
            _ = try orderedChain()
        } catch { wires = old; throw error }
    }
    mutating func connect(from: UUID, to: UUID) throws {
        guard from != to, blocks.contains(where: { $0.id == from && $0.kind != .output }),
              blocks.contains(where: { $0.id == to && $0.kind != .source }) else { throw AudioFailure("Недопустимые порты.") }
        let old = wires
        let wire = Wire(from: from, to: to)
        if wires.contains(wire) { return }
        wires.append(wire)
        do { try validateEditingGraph() }
        catch { wires = old; throw error }
    }
}

// Longest declared latency through an already validated topological route.
// Index cables once; no per-block scan of every wire on each monitoring tick.
enum RouteLatency {
    static func total(route: [Block], wires: [Wire], values: [UUID:Double]) -> Double? {
        var incoming: [UUID:[UUID]] = [:]
        for wire in wires { incoming[wire.to,default:[]].append(wire.from) }
        var longest: [UUID:Double] = [:]
        for block in route {
            guard let own = values[block.id], own.isFinite, own >= 0 else {return nil}
            let previous = incoming[block.id,default:[]].compactMap {longest[$0]}.max() ?? 0
            longest[block.id] = previous + own
        }
        return route.last.flatMap {longest[$0.id]}
    }
}
struct AudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
