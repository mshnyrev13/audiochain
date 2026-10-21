import AVFoundation
import AudioToolbox

// Apple AUConverter, explicitly Mastering/Max. A mixer uses a different,
// lower quality SRC; changing only its renderQuality does not select Mastering.
enum QualitySRC {
    private static func checked(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw AudioFailure("\(message): \(status)") }
    }
    static var description: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_AUConverter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }
    static func configure(_ unit: AVAudioUnit) throws {
        var complexity = UInt32(kAudioUnitSampleRateConverterComplexity_Mastering)
        try checked(AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_SampleRateConverterComplexity,
            kAudioUnitScope_Global, 0, &complexity, UInt32(MemoryLayout<UInt32>.size)), "Настроить Mastering SRC")
        unit.auAudioUnit.renderQuality = Int(kRenderQuality_Max)
        var actual: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        try checked(AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_SampleRateConverterComplexity,
            kAudioUnitScope_Global, 0, &actual, &size), "Проверить Mastering SRC")
        guard actual == complexity else { throw AudioFailure("Mastering SRC недоступен.") }
    }
    static func make() async throws -> AVAudioUnit {
        let unit: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: [.loadInProcess]) { unit, error in
                if let unit { continuation.resume(returning: unit) }
                else { continuation.resume(throwing: error ?? AudioFailure("Не удалось создать Mastering SRC.")) }
            }
        }
        try configure(unit)
        return unit
    }
}
