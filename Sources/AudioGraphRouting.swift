import AVFoundation

// Preserve document cable order, including mixer input-bus order, while
// resolving incoming/outgoing groups once during graph preparation.
struct AudioConnectionIndex {
    var incoming: [UUID:[Wire]] = [:]
    var outgoing: [UUID:[Wire]] = [:]
    init(wires:[Wire], active:Set<UUID>) {
        for wire in wires where active.contains(wire.from) && active.contains(wire.to) {
            incoming[wire.to,default:[]].append(wire)
            outgoing[wire.from,default:[]].append(wire)
        }
    }
}

// Use one fan-out call per output bus; separate connect calls would replace old branches.
// Each join gets independent input buses and sums at unity gain.
enum AudioGraphRouting {
    static func connect(session: Session, route: [Block], nodes: [UUID: AVAudioNode], engine: AVAudioEngine, format: AVAudioFormat) throws {
        let active = Set(route.map(\.id))
        let index = AudioConnectionIndex(wires:session.wires,active:active)
        var destinations: [Wire: AVAudioConnectionPoint] = [:]
        for block in route where block.kind != .source {
            guard let node = nodes[block.id] else { throw AudioFailure("Нет аудиоузла «\(block.name)».") }
            let incoming = index.incoming[block.id,default:[]]
            if incoming.isEmpty { continue }
            if block.kind == .output {
                for (bus, wire) in incoming.enumerated() { destinations[wire] = AVAudioConnectionPoint(node: node, bus: AVAudioNodeBus(bus)) }
            } else if incoming.count > 1 {
                let join = AVAudioMixerNode(); engine.attach(join)
                engine.connect(join, to: node, format: format)
                for (bus, wire) in incoming.enumerated() { destinations[wire] = AVAudioConnectionPoint(node: join, bus: AVAudioNodeBus(bus)) }
            } else {
                destinations[incoming[0]] = AVAudioConnectionPoint(node: node, bus: 0)
            }
        }
        for block in route where block.kind != .output {
            guard let node = nodes[block.id] else { throw AudioFailure("Нет аудиоузла «\(block.name)».") }
            let points = index.outgoing[block.id,default:[]].compactMap { destinations[$0] }
            if !points.isEmpty { engine.connect(node, to: points, fromBus: 0, format: format) }
        }
    }
}
