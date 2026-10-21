import AppKit
import AVFoundation
import CoreAudioKit

func runPluginEditorTests(matching filter: String, original: Bool) throws {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
    var plugins = AVAudioUnitComponentManager.shared().components(matching: description).filter { $0.name.localizedCaseInsensitiveContains(filter) }.sorted { $0.name < $1.name }
    if CommandLine.arguments.contains("--first-plugin-only") { plugins = Array(plugins.prefix(1)) }
    guard !plugins.isEmpty else { throw AudioFailure("No matching installed plugins: \(filter)") }
    for plugin in plugins {
        try autoreleasepool {
            let result = InstantiationResult()
            AVAudioUnit.instantiate(with: plugin.audioComponentDescription, options: original ? [.loadOutOfProcess] : PluginHost.options(plugin.audioComponentDescription)) { result.finish($0, $1) }
            let deadline = Date().addingTimeInterval(25)
            while !result.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            let (_, unit, error) = result.snapshot()
            guard let unit else { throw error ?? AudioFailure("Instantiation timeout: \(plugin.name)") }
            if original {
                let response = EditorResponse()
                unit.auAudioUnit.requestViewController { response.finish($0 != nil) }
                let deadline = Date().addingTimeInterval(8)
                while !response.snapshot().0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                let (done, customView) = response.snapshot()
                print("ORIGINAL \(plugin.name): callback=\(done), customViewController=\(customView), AUv3=\(PluginHost.isV3(plugin.audioComponentDescription))")
            } else {
                try PluginHost.prepareEditor(unit)
                let raw = unit.audioUnit
                try withExtendedLifetime(unit) {
                    guard let editor = try PluginHost.legacyEditor(raw) else { throw AudioFailure("Missing Cocoa UI: \(plugin.name)") }
                    let size = editor.view.frame.size
                    try check(size.width >= 100 && size.height >= 100, "Empty editor frame: \(plugin.name)")
                    try MainActor.assumeIsolated {
                        let controller = LegacyEditorController(editor: editor, audioUnit: unit)
                        let window = NSWindow(contentViewController: controller)
                        window.isReleasedWhenClosed = false
                        window.display(); controller.view.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        print("PASS \(plugin.name): native Cocoa editor \(type(of: editor.view)), \(Int(size.width))×\(Int(size.height)), attached to NSWindow")
                        if CommandLine.arguments.contains("--render-after-editor") { try testRenderingAfterEditor(unit) }
                        window.close()
                    }
                }
            }
        }
    }
}
private func testRenderingAfterEditor(_ unit: AVAudioUnit) throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try PluginHost.configureForRendering(unit, format: format)
    engine.attach(player); engine.attach(unit)
    engine.connect(player, to: unit, format: format); engine.connect(unit, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    input.frameLength = 48_000
    for channel in 0..<2 { for i in 0..<48_000 { input.floatChannelData![channel][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 48_000) } }
    player.scheduleBuffer(input); try engine.start(); player.play()
    defer { engine.stop(); engine.disconnectNodeInput(unit); engine.disconnectNodeOutput(unit); engine.detach(unit) }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    for _ in 0..<8 {
        let status = try engine.renderOffline(1024, to: output)
        try check(status == .success, "Render after opening editor: \(status)")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    print("PASS: offline rendering after native editor initialization and reconfiguration to 48 kHz")
}
private final class EditorResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false, hasView = false
    func finish(_ value: Bool) { lock.lock(); complete = true; hasView = value; lock.unlock() }
    func snapshot() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (complete, hasView) }
}
