import Foundation

// Remember only successfully loaded/saved documents. Diagnostics use isolated defaults.
struct SessionHistory {
    var defaults: UserDefaults = .standard
    private let key = "AudioChain.lastSessionPath"
    var lastURL: URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    func remember(_ url: URL) { defaults.set(url.standardizedFileURL.path, forKey: key) }
}
