import Foundation
import AVFoundation

struct AULoad:Identifiable,Equatable {
    let id:UUID
    var name:String
    var bypass:Bool
    var active:Bool=true
    var meanMS:Double? = nil
    var peakMS:Double? = nil
    var budgetPercent:Double? = nil
    var calls:UInt64=0
    var errors:UInt64=0
    var invalid:UInt64=0
    var waiting=false
}
enum AULoadOrder:String,CaseIterable,Identifiable {
    case chain="Порядок схемы",budget="Тяжёлые сначала"
    var id:String {rawValue}
    func rows(_ loads:[AULoad])->[AULoadRow] {
        let rows=loads.enumerated().map {AULoadRow(ordinal:$0.offset+1,load:$0.element)}
        guard self == .budget else {return rows}
        return rows.sorted {a,b in
            switch (a.load.measuredBudget,b.load.measuredBudget) {
            case let (x?,y?) where x != y:return x>y
            case (_?,nil):return true
            case (nil,_?):return false
            default:return a.ordinal<b.ordinal
            }
        }
    }
}
struct AULoadRow:Identifiable {
    let ordinal:Int
    let load:AULoad
    var id:UUID {load.id}
}
extension AULoad {
    var measuredBudget:Double? {budgetPercent.flatMap {$0.isFinite && $0>=0 ? $0:nil}}
}

final class AUProbe {
    let unit:AVAudioUnit
    let pointer:OpaquePointer
    private var previous:ACRenderProbeStats
    private var lastCompletion=ProcessInfo.processInfo.systemUptime
    init?(_ unit:AVAudioUnit) {
        guard let pointer=ACRenderProbeCreate(unit.audioUnit) else {return nil}
        self.unit=unit;self.pointer=pointer;previous=ACRenderProbeGetStats(pointer)
    }
    // Must be released only after AVAudioEngine.stop() has quiesced callbacks.
    deinit {ACRenderProbeDestroy(pointer)}
    func sample(_ block:Block,cumulative:Bool=false) -> AULoad {
        let stats=ACRenderProbeGetStats(pointer)
        defer {previous=stats}
        let completed=stats.buffers &- previous.buffers
        let frames=cumulative ? stats.frames : stats.frames &- previous.frames
        let count=cumulative ? stats.buffers : completed
        let ns=cumulative ? stats.exclusiveNanoseconds : stats.exclusiveNanoseconds &- previous.exclusiveNanoseconds
        let now=ProcessInfo.processInfo.systemUptime
        if completed>0 {lastCompletion=now}
        var result=AULoad(id:block.id,name:block.name,bypass:block.bypass,calls:stats.buffers,errors:stats.errors,invalid:stats.invalidMeasurements)
        result.waiting=stats.inFlight>0 && now-lastCompletion>2
        if count>0 && frames>0 && stats.invalidMeasurements==0 {
            result.meanMS=Double(ns)/Double(count)/1e6
            result.peakMS=stats.exclusiveMaxMicroseconds/1000
            result.budgetPercent=stats.sampleRate>0 ? Double(ns)/(Double(frames)/stats.sampleRate*1e9)*100:nil
        }
        return result
    }
}
struct SignalHealth:Equatable {
    var text:String
    var warning:Bool=false
    static func evaluate(running:Bool,busy:Bool,routeError:String?,muted:Bool,fault:Bool,inputRecent:Bool,outputRecent:Bool,warmed:Bool,generator:Bool,renderError:String?,renderMissing:String?=nil,renderWaiting:String?=nil) -> SignalHealth {
        if busy {return SignalHealth(text:"Подготовка…")}
        if let routeError {return SignalHealth(text:"Нет маршрута: "+routeError,warning:true)}
        if !running {return SignalHealth(text:"Остановлено")}
        if fault {return SignalHealth(text:"Ошибка PCM: NaN/Inf",warning:true)}
        if let renderError {return SignalHealth(text:"Ошибка render: "+renderError,warning:true)}
        if let renderWaiting {return SignalHealth(text:"Render ожидает более 2 с: "+renderWaiting,warning:true)}
        if muted {return SignalHealth(text:"Выход заглушён",warning:true)}
        if !warmed {return SignalHealth(text:"Ожидание сигнала…")}
        if outputRecent {return SignalHealth(text:inputRecent ? "Сигнал проходит":"Есть сигнал на выходе")}
        if inputRecent {
            if let renderMissing {return SignalHealth(text:"Нет данных render от AU: "+renderMissing,warning:true)}
            return SignalHealth(text:"На входе сигнал, на выходе тишина — проверьте AU",warning:true)
        }
        return SignalHealth(text:generator ? "На выходе нет сигнала":"Источник молчит · ниже −100 dBFS",warning:true)
    }
}

// Put actionable warnings first: the compact footer can truncate its tail.
struct PlaybackPresentation {
    let text:String
    let warning:Bool
    init(status:String,health:SignalHealth,attention:Bool) {
        warning=attention || health.warning
        if attention {text=status}
        else if health.warning {text=health.text}
        else {text=health.text == "Остановлено" ? status : status+" · "+health.text}
    }
}
