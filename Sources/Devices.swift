import Foundation
import CoreAudio
import AVFoundation

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
}
enum Devices {
    static let bufferChoices: [UInt32] = [128, 256, 512, 1024, 2048]
    static func defaultInput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard status == noErr, value != 0 else { throw AudioFailure("Не найден системный аудиовход.") }
        return value
    }
    static func defaultOutput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard status == noErr, value != 0 else { throw AudioFailure("Не найден системный аудиовыход (Core Audio \(status)).") }
        return value
    }
    static func sampleRate(_ id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0, size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw AudioFailure("Не удалось прочитать частоту устройства.") }
        return rate
    }
    static func validateFloatStereoIO(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, sampleRate: Double) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { throw AudioFailure("Не удалось прочитать потоки выхода.") }
        var streams = [AudioStreamID](repeating: 0, count: Int(size)/MemoryLayout<AudioStreamID>.size)
        let result = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { throw AudioFailure("Не удалось прочитать потоки выхода.") }
        var channels = 0
        for stream in streams {
            var format = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address.mSelector = kAudioStreamPropertyVirtualFormat; address.mScope = kAudioObjectPropertyScopeGlobal
            guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mSampleRate == sampleRate else {
                throw AudioFailure("Бит в бит: HAL-формат выхода не совпадает с 32-bit float PCM захвата. Пересчёт отключён.")
            }
            channels += Int(format.mChannelsPerFrame)
        }
        guard channels >= 2 else { throw AudioFailure("Нужен стереовыход.") }
    }
    static func bufferFrames(_ id: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, value > 0 else { throw AudioFailure("Не удалось прочитать размер буфера (Core Audio \(status)).") }
        return value
    }
    static func setBufferFrames(_ frames: UInt32, for id: AudioDeviceID) async throws -> UInt32 {
        guard bufferChoices.contains(frames) else { throw AudioFailure("Допустимый буфер: 128, 256, 512, 1024 или 2048 кадров.") }
        if try bufferFrames(id) == frames { return frames }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        let propertyStatus = AudioObjectIsPropertySettable(id, &address, &settable)
        guard propertyStatus == noErr, settable.boolValue else { throw AudioFailure("Это устройство не разрешает изменение размера буфера.") }
        var value = frames
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw AudioFailure("Устройство отклонило буфер \(frames) кадров (Core Audio \(status)).") }
        // Device negotiation and HAL cache updates may finish after the setter returns.
        for _ in 0..<10 {
            let actual = try bufferFrames(id)
            if actual == frames { return actual }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try bufferFrames(id)
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr, let text = value.pointee else { return "" }
        return text as String
    }
    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.map { AudioDevice(id: $0, uid: string($0, kAudioDevicePropertyDeviceUID), name: string($0, kAudioObjectPropertyName), inputs: channels($0, scope: kAudioDevicePropertyScopeInput), outputs: channels($0, scope: kAudioDevicePropertyScopeOutput)) }
    }
    static func currentDevice(for node: AVAudioIONode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }
        var current: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr else { return nil }
        return current
    }
    static func select(_ id: AudioDeviceID, for node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw AudioFailure("Audio Unit устройства недоступен.") }
        var current: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        if readStatus == noErr && current == id { return }
        var device = id
        func apply() -> OSStatus {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let result = apply()
        guard result == noErr else {
            let direction = node is AVAudioInputNode ? "аудиовход" : "аудиовыход"
            throw AudioFailure("Не удалось выбрать \(direction) «\(string(id, kAudioObjectPropertyName))» (Core Audio \(result)).")
        }
    }
}
