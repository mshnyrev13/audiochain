import Foundation
import AppKit
import Combine
import AudioToolbox

@MainActor func runCompactSessionTests() async -> Int32 {
    let suite = "AudioChain.tests.history.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let history = SessionHistory(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioChain-history-\(UUID())")
    let model = AudioModel()
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try check(history.lastURL == nil, "Empty history must not invent a document")
        var candidate = Session.empty
        let effect = Block(kind: .effect, name: "Test EQ", x: 202, y: 76,
            component: ComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_NBandEQ, manufacturer: kAudioUnitManufacturer_Apple))
        candidate.blocks.append(effect)
        candidate.wires = [Wire(from: candidate.blocks[0].id, to: effect.id), Wire(from: effect.id, to: candidate.blocks[1].id)]
        candidate.volume = 0.75
        let url = directory.appendingPathComponent("Latest.audiochain.json")
        try JSONEncoder().encode(candidate).write(to: url)
        await model.restoreLastSession(history: history, migrationURL: url)
        try check(history.lastURL == url && model.session.wires == candidate.wires, "First launch migration must adopt the existing default document")
        history.remember(directory.appendingPathComponent("Older.json")); history.remember(url)
        await model.restoreLastSession(history: history)
        try check(model.session.wires == candidate.wires && model.volume == 0.75, "Last document did not restore")
        try check(model.unitForDiagnostics(effect.id) != nil && !model.running && !model.busy, "Restore must load AU without starting audio")
        let originalIDs = model.activeBlockIDs
        try check(originalIDs.contains(effect.id), "Route cache failed")
        model.session.wires = [Wire(from: candidate.blocks[0].id, to: candidate.blocks[1].id)]
        try check(!model.activeBlockIDs.contains(effect.id), "Wire edit must invalidate route cache")
        var graphUpdates = 0
        let subscription = model.objectWillChange.sink { graphUpdates += 1 }
        for index in 0..<100 {
            model.inputLevels = StereoLevels(left: -Double(index), right: -20)
            model.outputLevels = StereoLevels(left: -30, right: -Double(index))
        }
        try check(graphUpdates == 0 && model.outputLevels.right == -99, "Meters must not invalidate the whole graph")
        subscription.cancel()
        try FileManager.default.removeItem(at: url)
        await model.restoreLastSession(history: history)
        try check(!model.busy && !model.running && model.status.hasPrefix("Не удалось"), "Missing document must leave a usable stopped application")
        try check(model.activeBlockIDs == Set([candidate.blocks[0].id, candidate.blocks[1].id]), "Failed restore must preserve current graph")
        try check(history.lastURL == url, "Failed restore must preserve last document reference")
        await model.shutdown()
        print("PASS: latest saved document + AU restored without playback; missing file handled; route cache invalidation; 200 meter updates caused zero graph notifications")
        return 0
    } catch { await model.shutdown(); print("FAIL: \(error)"); return 1 }
}
