import AppKit
import AVFoundation
import CoreAudio

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let bundlePath: String
}
enum AudioProcesses {
    static func otherActiveHosts() -> [pid_t] {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.mshnyrev.AudioCanvas"
        return all().filter { process in
            guard process.pid != getpid(), process.bundleID == bundleID else { return false }
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(process.objectID, &address, 0, nil, &size, &running) == noErr && running != 0 { return true }
            }
            return false
        }.map(\.pid)
    }
    static func all() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var pid: pid_t = 0; var size = UInt32(MemoryLayout<pid_t>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr else { return nil }
            return AudioProcess(objectID: id, pid: pid, bundleID: Devices.string(id, kAudioProcessPropertyBundleID), bundlePath: NSRunningApplication(processIdentifier: pid)?.bundleURL?.path ?? "")
        }
    }
    static func outputDevices(_ ids: [AudioObjectID]) throws -> Set<AudioDeviceID> {
        var result = Set<AudioDeviceID>()
        for id in ids {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
            guard status == noErr else { throw AudioFailure("Не удалось определить выход источника (Core Audio \(status)).") }
            if size == 0 { continue }
            var devices = [AudioDeviceID](repeating: 0, count: Int(size)/MemoryLayout<AudioDeviceID>.size)
            let read = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
            guard read == noErr else { throw AudioFailure("Не удалось прочитать выход источника.") }
            result.formUnion(devices)
        }
        return result
    }
    static func matches(_ process: AudioProcess, bundleID: String, bundlePath: String) -> Bool {
        process.bundleID == bundleID || process.bundleID.hasPrefix(bundleID + ".") ||
        (!bundlePath.isEmpty && (process.bundlePath == bundlePath || process.bundlePath.hasPrefix(bundlePath + "/")))
    }
    static func selected(bundleID: String?, excludedBundleIDs: [String] = []) -> (ids: [AudioObjectID], bundles: [String]) {
        let all = all()
        guard let bundleID else {
            // Excluding our own playback is necessary to avoid capturing the processed output again.
            let excluded = Array(Set(excludedBundleIDs + [Bundle.main.bundleIdentifier ?? "local.mshnyrev.AudioCanvas"]))
            let paths = excluded.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path ?? "" }
            let processes = all.filter { process in
                process.pid == getpid() || zip(excluded, paths).contains { matches(process, bundleID: $0.0, bundlePath: $0.1) }
            }
            return (processes.map(\.objectID), Array(Set(excluded + processes.map(\.bundleID).filter { !$0.isEmpty })).sorted())
        }
        let path = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL?.path ?? ""
        let selected = all.filter { matches($0, bundleID: bundleID, bundlePath: path) && $0.pid != getpid() }
        return (selected.map(\.objectID), Array(Set([bundleID] + selected.map(\.bundleID).filter { !$0.isEmpty })).sorted())
    }
}

@MainActor final class ProcessCapture {
    let buffer = AudioQueueBuffer()
    private(set) var format: AVAudioFormat?
    private(set) var actualBufferFrames: UInt32?
    private(set) var cleanupStatuses: [OSStatus] = []
    var diagnosticIDs: (tap: AudioObjectID, aggregate: AudioDeviceID) { (tap, aggregate) }
    var onFailure: ((Error) -> Void)?
    private var direct: DirectPCMTransport?
    private var directOutput: AudioDeviceID?
    var inputMeter: LevelMeter { direct?.inputMeter ?? buffer.inputMeter }
    var outputMeter: LevelMeter? { direct?.outputMeter }
    var directStats: ACDirectStats? { direct?.statistics }
    var statistics: ACRingStats {
        if let stats = directStats { return ACRingStats(written: stats.frames, underruns: stats.invalidBlocks, dropped: stats.mismatches, queued: 0) }
        return buffer.statistics
    }
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var timer: Timer?
    private var target: String?
    private var selection: [AudioObjectID] = []
    private var excludedBundleIDs: [String] = []
    private var selectionBundles: [String] = []
    private var started = false
    private var generation = UUID()

    func start(bundleID: String?, bufferFrames: UInt32? = nil, passThroughOutput: AudioDeviceID? = nil, diagnosticSilence: Bool = false, excludedBundleIDs: [String] = [], outputGain: Float = 1, startImmediately: Bool = true) async throws {
        target = bundleID
        self.excludedBundleIDs = excludedBundleIDs
        let processes = AudioProcesses.selected(bundleID: bundleID, excludedBundleIDs: excludedBundleIDs)
        if bundleID != nil && processes.ids.isEmpty {
            throw AudioFailure("У выбранного приложения пока нет аудиопроцесса. Включите в нём воспроизведение и нажмите Старт снова.")
        }
        if bundleID == nil && processes.ids.isEmpty {
            throw AudioFailure("Не удалось исключить AudioChain из системного захвата. Выберите отдельное приложение.")
        }
        selection = processes.ids
        selectionBundles = processes.bundles
        directOutput = passThroughOutput
        let outputUID = passThroughOutput.map { Devices.string($0, kAudioDevicePropertyDeviceUID) }
        if let output = passThroughOutput {
            if bundleID != nil {
                let routes = try AudioProcesses.outputDevices(processes.ids)
                guard routes == [output] else { throw AudioFailure("Бит в бит: выберите тот же выход, на который сейчас играет источник. Для браузера сначала выберите этот выход в macOS.") }
            } else {
                guard try Devices.defaultOutput() == output else { throw AudioFailure("Бит в бит для системы: выход AudioChain должен совпадать с системным выходом macOS.") }
            }
            direct = DirectPCMTransport()
            direct?.setGain(outputGain)
        }
        let description = outputUID.map { ACMakeDeviceTapDescription(processes.ids.map { NSNumber(value: $0) }, processes.bundles, bundleID == nil, $0) }
            ?? ACMakeTapDescription(processes.ids.map { NSNumber(value: $0) }, processes.bundles, bundleID == nil)
        do {
            try checked(AudioHardwareCreateProcessTap(description, &tap), "Создать перехват. Разрешите AudioChain запись системного аудио в настройках macOS")
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try checked(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Получить формат перехвата")
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 2, asbd.mSampleRate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: 2) else { throw AudioFailure("Перехват вернул неподдерживаемый формат аудио.") }
            self.format = format
            let uid = Devices.string(tap, kAudioTapPropertyUID)
            guard !uid.isEmpty else { throw AudioFailure("Не удалось получить UID перехвата.") }
            var specification: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioChain private tap",
                kAudioAggregateDeviceUIDKey: "local.AudioChain.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: false]]
            ]
            if let outputUID {
                specification[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: false]]
                specification[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            }
            try checked(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate), "Создать приватный вход перехвата")
            if let bufferFrames { actualBufferFrames = try await Devices.setBufferFrames(bufferFrames, for: aggregate) }
            else { actualBufferFrames = try Devices.bufferFrames(aggregate) }
            if passThroughOutput != nil {
                try Devices.validateFloatStereoIO(aggregate, scope: kAudioDevicePropertyScopeOutput, sampleRate: asbd.mSampleRate)
                guard try Devices.sampleRate(aggregate) == asbd.mSampleRate else { throw AudioFailure("Бит в бит: частоты захвата и выхода различаются.") }
            }
            let physicalInputChannels = passThroughOutput == nil ? 0 : max(0, Devices.channels(aggregate, scope: kAudioDevicePropertyScopeInput) - 2)
            let direct = self.direct
            let buffer = self.buffer
            try checked(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
                if let direct { direct.copy(input: input, output: output, skip: UInt32(physicalInputChannels), silence: diagnosticSilence); return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, first.mNumberChannels > 0 else { return }
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
                if frames > 0 { buffer.append(list, frames: frames) }
            }, "Подключить чтение перехвата")
            if startImmediately { try activate() }
        } catch { await stop(); throw error }
    }
    // Preparing a tap reveals its format without reading/muting or accumulating PCM.
    // The AU host activates it only after all plugins and the output are ready.
    func activate() throws {
        guard !started else { return }
        guard aggregate != 0, ioProc != nil, format != nil else { throw AudioFailure("Перехват не подготовлен.") }
        try checked(AudioDeviceStart(aggregate, ioProc), "Запустить перехват")
        started = true
        actualBufferFrames = try Devices.bufferFrames(aggregate)
        let token = generation
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.started else { return }
                self.updateProcesses()
            }
        }
    }
    private func updateProcesses() {
        let processes = AudioProcesses.selected(bundleID: target, excludedBundleIDs: excludedBundleIDs)
        if let output = directOutput {
            do {
                if let stats = directStats, stats.invalidBlocks > 0 || stats.mismatches > 0 { throw AudioFailure("Бит в бит: нарушено соответствие входных и выходных блоков; перехват остановлен.") }
                let routeOK = target == nil ? try Devices.defaultOutput() == output : try AudioProcesses.outputDevices(processes.ids) == [output]
                guard routeOK, let format, try Devices.sampleRate(output) == format.sampleRate else { throw AudioFailure("Бит в бит: изменился выход или частота источника. Запустите цепочку снова.") }
            } catch { onFailure?(error); return }
        }
        if Set(processes.ids) == Set(selection) && Set(processes.bundles) == Set(selectionBundles) { return }
        let status = ACUpdateTapProcesses(tap, processes.ids.map { NSNumber(value: $0) }, processes.bundles)
        if status == noErr { selection = processes.ids; selectionBundles = processes.bundles }
        else { onFailure?(AudioFailure("Обновить процессы перехвата (Core Audio \(status)).")) }
    }
    func setOutputGain(_ gain: Float) { direct?.setGain(gain) }
    func setSystemExclusions(_ bundleIDs: [String]) {
        guard target == nil, started else { return }
        excludedBundleIDs = bundleIDs
        updateProcesses()
    }
    func stop() async {
        generation = UUID(); timer?.invalidate(); timer = nil
        cleanupStatuses = []
        // Destroy the reader first. mutedWhenTapped restores the direct route when reading ends.
        if aggregate != 0 {
            if started { cleanupStatuses.append(AudioDeviceStop(aggregate, ioProc)) }
            if let ioProc { cleanupStatuses.append(AudioDeviceDestroyIOProcID(aggregate, ioProc)) }
            cleanupStatuses.append(AudioHardwareDestroyAggregateDevice(aggregate))
        }
        if tap != 0 { cleanupStatuses.append(AudioHardwareDestroyProcessTap(tap)) }
        direct = nil; directOutput = nil
        started = false; ioProc = nil; aggregate = 0; tap = 0; format = nil; actualBufferFrames = nil
    }
    private func checked(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw AudioFailure("\(action) (Core Audio \(status)).") }
    }
}
