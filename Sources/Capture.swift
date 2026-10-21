import AVFoundation

// One capture producer, one render consumer. Allocation happens before audio starts.
final class AudioQueueBuffer: @unchecked Sendable {
    let inputMeter = LevelMeter()
    private let ring: OpaquePointer
    init(prefillFrames: UInt32 = 2048) { ring = ACRingCreate(prefillFrames)! }
    deinit { ACRingDestroy(ring) }
    var statistics: ACRingStats { ACRingGetStats(ring) }
    var writtenFrames: Int { Int(statistics.written) }
    var correctionPPM: Double { ACRingCorrectionPPM(ring) }
    func configureClockSync(sampleRate: Double) throws {
        guard ACRingConfigureClockSync(ring, sampleRate) != 0 else { throw AudioFailure("Не удалось подготовить синхронизацию аудиочасов.") }
    }
    func append(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        inputMeter.observe(UnsafePointer(list.unsafeMutablePointer))
        ACRingAppend(ring, list.unsafeMutablePointer, UInt32(frames))
    }
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        ACRingRender(ring, list.unsafeMutablePointer, UInt32(frames))
    }
}

final class DirectPCMTransport: @unchecked Sendable {
    let inputMeter = LevelMeter()
    let outputMeter = LevelMeter()
    private let transport = ACDirectCreate()!
    deinit { ACDirectDestroy(transport) }
    var statistics: ACDirectStats { ACDirectGetStats(transport) }
    func setGain(_ gain: Float) { ACDirectSetGain(transport, gain) }
    func copy(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, skip: UInt32, silence: Bool) {
        inputMeter.observe(input, skip: skip)
        ACDirectCopy(transport, input, output, skip, 0)
        outputMeter.observe(UnsafePointer(output))
        if silence {
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
    }
}
