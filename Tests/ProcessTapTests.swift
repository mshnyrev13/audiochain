import AppKit
import AVFoundation
import CoreAudio

func testTapPolicyAndSelection() throws {
    let app = ACMakeTapDescription([NSNumber(value: 7)], ["com.example.browser"], false)
    let system = ACMakeTapDescription([NSNumber(value: 8)], ["local.AudioCanvas"], true)
    try check(app.muteBehavior == .mutedWhenTapped && system.muteBehavior == .mutedWhenTapped, "Direct playback must be muted only while reading the tap")
    try check(!app.isExclusive && system.isExclusive && app.isPrivate && system.isPrivate, "Tap scope / private policy")
    let root = "/Applications/Example.app"
    let helper = AudioProcess(objectID: 1, pid: 1, bundleID: "com.example.browser.helper", bundlePath: root + "/Contents/Helpers/Helper.app")
    try check(AudioProcesses.matches(helper, bundleID: "com.example.browser", bundlePath: root), "Browser helper selection")
    let unrelated = AudioProcess(objectID: 2, pid: 2, bundleID: "com.example.browser2", bundlePath: "/Applications/Other.app")
    try check(!AudioProcesses.matches(unrelated, bundleID: "com.example.browser", bundlePath: root), "Unrelated app must not be muted")
    let excluded = AudioProcesses.selected(bundleID: nil, excludedBundleIDs: ["com.example.browser"])
    try check(excluded.bundles.contains("com.example.browser"), "Not-yet-running excluded app must persist in tap description")
    print("PASS: mutedWhenTapped policy, private/exclusive scope, browser helpers and unrelated app exclusion")
}

@MainActor func runTapProbe(bundleID: String) async -> Int32 {
    let capture = ProcessCapture()
    do {
        let processes = AudioProcesses.selected(bundleID: bundleID)
        print("Selected \(processes.ids.count) audio processes for \(bundleID)")
        var requested: UInt32?
        if let index = CommandLine.arguments.firstIndex(of: "--buffer-frames"), CommandLine.arguments.count > index + 1 {
            requested = UInt32(CommandLine.arguments[index + 1])
        }
        let exact = CommandLine.arguments.contains("--exact-loopback")
        try await capture.start(bundleID: bundleID, bufferFrames: requested,
                                passThroughOutput: exact ? try Devices.defaultOutput() : nil,
                                diagnosticSilence: exact)
        print("Tap buffer requested=\(requested.map(String.init) ?? "auto"), actual=\(capture.actualBufferFrames.map(String.init) ?? "unknown")")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let frames = Int(capture.statistics.written)
        if let stats = capture.directStats {
            print("Exact HAL PCM: frames=\(stats.frames), mismatchedBits=\(stats.mismatches), invalidBlocks=\(stats.invalidBlocks), rate=\(capture.format?.sampleRate ?? 0)")
            try check(stats.frames > 0 && stats.mismatches == 0 && stats.invalidBlocks == 0, "Exact HAL PCM comparison failed")
        }
        let ids = capture.diagnosticIDs
        await capture.stop()
        try check(capture.cleanupStatuses.allSatisfy { $0 == noErr }, "Tap cleanup failed: \(capture.cleanupStatuses)")
        // HAL may retain cached properties of a retired ID. Check live registry membership,
        // allowing the asynchronous property-list notification to settle.
        for _ in 0..<20 {
            if try !hardwareObjects(kAudioHardwarePropertyTapList).contains(ids.tap) && !hardwareObjects(kAudioHardwarePropertyDevices).contains(ids.aggregate) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(try !hardwareObjects(kAudioHardwarePropertyTapList).contains(ids.tap) && !hardwareObjects(kAudioHardwarePropertyDevices).contains(ids.aggregate), "HAL tap/device still registered after Stop")
        try check(frames > 0, "Tap did not deliver audio frames (permission or source playback may be missing)")
        print("PASS: live tap read \(frames) frames; reader, private aggregate and tap destroyed; direct route restored by mutedWhenTapped policy")
        return 0
    } catch {
        await capture.stop(); fputs("FAIL: \(error.localizedDescription)\n", stderr); return 1
    }
}
private func hardwareObjects(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeResult = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard sizeResult == noErr else { throw AudioFailure("HAL registry size query failed: \(sizeResult)") }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !ids.isEmpty else { return [] }
    let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
    guard result == noErr else { throw AudioFailure("HAL registry query failed: \(result)") }
    return ids
}

// Runs the full realtime engine silently; no audio recording or content logging.
@MainActor func runTransportProbe(bundleID: String) async -> Int32 {
    let model = AudioModel()
    if let index = CommandLine.arguments.firstIndex(of: "--load-session"), CommandLine.arguments.count > index + 1 {
        await model.load(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    model.session.inputKind = CommandLine.arguments.contains("--system-source") ? .system : .application
    model.session.applicationBundleID = bundleID
    model.session.bufferFrames = nil
    model.volume = 0
    model.diagnosticSilence = true
    if let index = CommandLine.arguments.firstIndex(of: "--add-plugin"), CommandLine.arguments.count > index + 1 {
        let name = CommandLine.arguments[index + 1]
        guard let plugin = model.plugins.first(where: { $0.name == name }) else { return 1 }
        await model.add(plugin)
        if !CommandLine.arguments.contains("--leave-plugin-unconnected"), let effect = model.session.blocks.first(where: { $0.kind == .effect }) {
            do { try model.session.insertBeforeOutput(effect.id) }
            catch { print(error); return 1 }
        }
        guard model.session.blocks.contains(where: { $0.kind == .effect }) else { print(model.status); return 1 }
    }
    print("Plugin load finished: busy=\(model.busy), connectedEffects=\((try? model.session.orderedChain().filter { $0.kind == .effect }.count) ?? -1)")
    await model.start()
    guard model.running else { print("FAIL: \(model.status)"); return 1 }
    print(model.status)
    let probeUnits = ((try? model.session.orderedChain()) ?? []).filter { $0.kind == .effect }.compactMap { model.unitForDiagnostics($0.id) }
    let renderProbes = probeUnits.compactMap { ACRenderProbeCreate($0.audioUnit) }
    defer { renderProbes.forEach { ACRenderProbeDestroy($0) } }
    if CommandLine.arguments.contains("--leave-plugin-unconnected"), !model.bitPerfectActive { await model.stop(); print("FAIL: unused plugin must preserve direct PCM path"); return 1 }
    do {
        let seconds: UInt64 = CommandLine.arguments.contains("--short-probe") ? 5 : 15
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        guard let stats = model.transportStatistics else { throw AudioFailure("No capture diagnostics") }
        let stillRunning = model.running
        let inputLevels = model.inputLevels, outputLevels = model.outputLevels
        print("Meters dBFS: input=\(inputLevels.left)/\(inputLevels.right), output=\(outputLevels.left)/\(outputLevels.right)")
        if model.bitPerfectActive {
            try check(inputLevels.left == outputLevels.left && inputLevels.right == outputLevels.right, "Direct PCM meter mismatch")
        } else {
            try check(outputLevels.left == -.infinity && outputLevels.right == -.infinity, "Output meter must be after zero test volume")
        }
        await model.stop()
        if !probeUnits.isEmpty {
            let counts = renderProbes.map { ACRenderProbeFrames($0) }
            print("Native AU rendered frames: \(counts)")
            try check(counts.count == probeUnits.count && counts.allSatisfy { $0 > 0 }, "Connected AU was not rendered")
        }
        print("Realtime transport: written=\(stats.written), queued=\(stats.queued), underruns=\(stats.underruns), dropped=\(stats.dropped)")
        try check(stillRunning && stats.written > 0 && stats.underruns == 0 && stats.dropped == 0, "Realtime transport interrupted")
        print("PASS: realtime transport for \(seconds) seconds, no loss or invalid blocks; test output muted")
        if CommandLine.arguments.contains("--leave-plugin-unconnected"), let effect = model.session.blocks.first(where: { $0.kind == .effect }) {
            model.insertBeforeOutput(effect.id)
            try check(model.hasActiveEffects, "Explicit connection did not activate the plugin")
            model.volume = 0
            await model.start()
            try check(model.running && !model.busy && !model.bitPerfectActive, "Start after connecting plugin failed: \(model.status)")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let pluginStats = model.transportStatistics
            print("Plugin meters dBFS: input=\(model.inputLevels.left)/\(model.inputLevels.right), output=\(model.outputLevels.left)/\(model.outputLevels.right)")
            try check(model.outputLevels.left == -.infinity && model.outputLevels.right == -.infinity, "Plugin output meter is not after the zero-volume fader")
            await model.stop()
            try check(pluginStats != nil && pluginStats!.written > 0 && pluginStats!.underruns == 0 && pluginStats!.dropped == 0, "Connected-plugin transport failed")
            print("PASS: Stop → explicit Подключить → Start with plugin, 3 seconds, no underruns or loss")
        }
        return 0
    } catch { await model.stop(); print("FAIL: \(error.localizedDescription)"); return 1 }
}
