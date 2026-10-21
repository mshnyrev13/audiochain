import AppKit
import AVFoundation
import AudioToolbox

enum PluginHost {
    static func renderingFormat(_ unit: AVAudioUnit, preferred: AVAudioFormat) -> AVAudioFormat {
        let type = unit.audioComponentDescription.componentType
        if (type == kAudioUnitType_Generator || type == kAudioUnitType_MusicDevice), unit.auAudioUnit.outputBusses.count > 0 {
            let channels = unit.auAudioUnit.outputBusses[0].format.channelCount
            return AVAudioFormat(standardFormatWithSampleRate: preferred.sampleRate, channels: max(1, channels)) ?? preferred
        }
        return preferred
    }
    static func configureForRendering(_ unit: AVAudioUnit, format preferred: AVAudioFormat) throws {
        let format = renderingFormat(unit, preferred: preferred)
        let au = unit.auAudioUnit
        guard au.outputBusses.count > 0, au.inputBusses.count > 0 || ComponentID(type: unit.audioComponentDescription.componentType, subtype: 0, manufacturer: 0).isGenerator else { throw AudioFailure("AU не имеет аудиовхода или выхода.") }
        // Leave the initialized DSP core intact when no format change is needed.
        guard (au.inputBusses.count > 0 && !au.inputBusses[0].format.isEqual(format)) || !au.outputBusses[0].format.isEqual(format) else { return }
        let state = au.fullState
        if au.renderResourcesAllocated { au.deallocateRenderResources() }
        if au.inputBusses.count > 0 { try au.inputBusses[0].setFormat(format) }
        try au.outputBusses[0].setFormat(format)
        if let state {
            try au.allocateRenderResources()
            au.fullState = state
        }
    }
    static func prepareEditor(_ unit: AVAudioUnit) throws {
        // Ozone's Cocoa view accesses its DSP core when it joins an NSWindow.
        // The AUv2 bridge creates that core on AudioUnitInitialize.
        if !unit.auAudioUnit.renderResourcesAllocated { try unit.auAudioUnit.allocateRenderResources() }
    }
    static func legacyEditor(_ unit: AudioUnit) throws -> ACLegacyEditor? {
        var error: NSError?
        let editor = ACCreateLegacyEditor(unit, &error)
        if let error { throw error }
        return editor
    }
    static func isV3(_ description: AudioComponentDescription) -> Bool {
        var search = description
        guard let component = AudioComponentFindNext(nil, &search) else { return false }
        var registered = AudioComponentDescription()
        guard AudioComponentGetDescription(component, &registered) == noErr else { return false }
        return registered.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
    }
    static func options(_ description: AudioComponentDescription) -> AudioComponentInstantiationOptions {
        // AUv2 Cocoa factories need the actual local AudioUnit, not a remote proxy.
        isV3(description) ? [.loadOutOfProcess] : [.loadInProcess]
    }
}

@MainActor final class LegacyEditorController: NSViewController {
    private let editor: ACLegacyEditor
    private let audioUnit: AVAudioUnit
    init(editor: ACLegacyEditor, audioUnit: AVAudioUnit) {
        self.editor = editor; self.audioUnit = audioUnit
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func loadView() { view = editor.view }
}
