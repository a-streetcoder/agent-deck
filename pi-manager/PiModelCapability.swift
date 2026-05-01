import Foundation

enum PiModelCapability {
    /// Mirrors @mariozechner/pi-ai supportsXhigh(model) for Pi's current model families.
    /// Keep this small and conservative; explicit runtime metadata still wins when present.
    static func supportsXhigh(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return id.contains("gpt-5.2")
            || id.contains("gpt-5.3")
            || id.contains("gpt-5.4")
            || id.contains("gpt-5.5")
            || id.contains("deepseek-v4-pro")
            || id.contains("deepseek-v4-flash")
            || id.contains("opus-4-6")
            || id.contains("opus-4.6")
            || id.contains("opus-4-7")
            || id.contains("opus-4.7")
    }
}
