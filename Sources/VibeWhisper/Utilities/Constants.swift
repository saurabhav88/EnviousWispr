import Foundation

enum AppConstants {
    static let appName = "VibeWhisper"
    static let bundleID = "com.vibewhisper.app"
    static let sampleRate: Double = 16000.0
    static let audioChannels: Int = 1
    static let appSupportDir = "VibeWhisper"
    static let transcriptsDir = "transcripts"
    static let modelsDir = "Models"

    /// Application Support directory for VibeWhisper.
    static var appSupportURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent(appSupportDir, isDirectory: true)
    }
}
