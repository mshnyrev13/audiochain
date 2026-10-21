import Foundation
import CoreAudio

func testBufferPresets() throws {
    for frames in Devices.bufferChoices {
        var session = Session.empty; session.bufferFrames = frames
        _ = try session.orderedChain()
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        try check(restored.bufferFrames == frames, "Buffer preset round trip: \(frames)")
    }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Session.empty)) as! [String: Any]
    json.removeValue(forKey: "bufferFrames")
    let legacy = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    try check(legacy.bufferFrames == nil, "Older sessions must preserve the current hardware buffer")
    var invalid = Session.empty; invalid.bufferFrames = 999
    try mustReject { _ = try invalid.orderedChain() }
    print("PASS: five buffer preset values, old-preset compatibility, invalid size rejection")
}
@MainActor func runHardwareBufferTest() async -> Int32 {
    do {
        let device = try Devices.defaultOutput()
        let original = try Devices.bufferFrames(device)
        guard Devices.bufferChoices.contains(original) else { throw AudioFailure("Current buffer is outside test choices; hardware unchanged") }
        print("Testing \(Devices.string(device, kAudioObjectPropertyName)); original=\(original)")
        do {
            for requested in Devices.bufferChoices {
                let actual = try await Devices.setBufferFrames(requested, for: device)
                print("requested=\(requested), actual=\(actual)")
                try check(actual == requested, "Hardware did not accept requested buffer \(requested)")
            }
        } catch {
            let restored = try await Devices.setBufferFrames(original, for: device)
            try check(restored == original, "Restore original hardware buffer")
            throw error
        }
        let restored = try await Devices.setBufferFrames(original, for: device)
        try check(restored == original, "Restore original hardware buffer")
        print("PASS: all five hardware sizes; restored=\(restored)")
        return 0
    } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); return 1 }
}
