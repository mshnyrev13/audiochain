import AVFoundation

enum PluginCategory: String, CaseIterable, Identifiable {
    case all = "Все AU", effects = "Эффекты", generators = "Генераторы", instruments = "Инструменты", mixers = "Микшеры", other = "Остальные"
    var id: String { rawValue }
    func contains(_ plugin: PluginChoice) -> Bool {
        switch self {
        case .all: return true
        case .effects: return [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].contains(plugin.component.type)
        case .generators: return plugin.component.type == kAudioUnitType_Generator
        case .instruments: return plugin.component.type == kAudioUnitType_MusicDevice
        case .mixers: return plugin.component.type == kAudioUnitType_Mixer
        case .other: return ![kAudioUnitType_Effect, kAudioUnitType_MusicEffect, kAudioUnitType_Generator, kAudioUnitType_MusicDevice, kAudioUnitType_Mixer].contains(plugin.component.type)
        }
    }
}

struct PluginChoice: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let manufacturer: String
    let component: ComponentID
    var unavailable: String? = nil
    var typeLabel: String {
        switch component.type {
        case kAudioUnitType_Effect, kAudioUnitType_MusicEffect: return "Эффект"
        case kAudioUnitType_Generator: return "Генератор"
        case kAudioUnitType_MusicDevice: return "Инструмент · MIDI"
        case kAudioUnitType_Mixer: return "Микшер"
        case kAudioUnitType_FormatConverter: return "Конвертер"
        case kAudioUnitType_Panner: return "Панорама"
        case kAudioUnitType_Output: return "Выход AU"
        case kAudioUnitType_MIDIProcessor: return "MIDI-процессор"
        default: return "AU"
        }
    }
}
enum PluginCatalog {
    static let supported: [UInt32] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect, kAudioUnitType_Generator, kAudioUnitType_MusicDevice, kAudioUnitType_Mixer, kAudioUnitType_FormatConverter, kAudioUnitType_Panner]
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func scan() -> [PluginChoice] {
        let query = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var items: [String: PluginChoice] = [:]
        func add(_ component: ComponentID, _ name: String, _ manufacturer: String, registered: Bool) {
            guard component.type >> 16 == 0x6175 else { return } // Audio Units (au**), exclude codec components.
            let id = "\(component.type)-\(component.subtype)-\(component.manufacturer)"
            if items[id] != nil { return }
            let reason = !registered ? "macOS ещё не зарегистрировала этот AU для данного процесса/архитектуры. Обновите список или перезапустите AudioChain." :
                (!supported.contains(component.type) ? "Тип AU пока не поддерживает подключение к аудиографу AudioChain." : nil)
            items[id] = PluginChoice(id: id, name: name, manufacturer: manufacturer, component: component, unavailable: reason)
        }
        for item in AVAudioUnitComponentManager.shared().components(matching: query) {
            let d = item.audioComponentDescription
            add(ComponentID(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer), item.name, item.manufacturerName, registered: true)
        }
        // Installed but unregistered components remain visible with their actual status.
        let roots = ["/Library/Audio/Plug-Ins/Components", NSHomeDirectory() + "/Library/Audio/Plug-Ins/Components", "/System/Library/Components"]
        for root in roots {
            for url in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "component" {
                guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let components = plist["AudioComponents"] as? [[String: Any]] else { continue }
                for entry in components {
                    guard let type = entry["type"] as? String, let subtype = entry["subtype"] as? String, let manufacturer = entry["manufacturer"] as? String else { continue }
                    let component = ComponentID(type: fourCC(type), subtype: fourCC(subtype), manufacturer: fourCC(manufacturer))
                    var d = component.description
                    add(component, entry["name"] as? String ?? url.deletingPathExtension().lastPathComponent, manufacturer, registered: AudioComponentFindNext(nil, &d) != nil)
                }
            }
        }
        return items.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
