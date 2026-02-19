import Foundation

enum AppConstants {
    static let appName = "EnviousWispr"
    static let sampleRate: Double = 16000.0
    static let audioChannels: Int = 1
    static let appSupportDir = "EnviousWispr"
    static let transcriptsDir = "transcripts"

    /// Application Support directory for EnviousWispr.
    static var appSupportURL: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable")
        }
        return appSupport.appendingPathComponent(appSupportDir, isDirectory: true)
    }
}
