import Foundation

/// Single source of truth for XPC service name resolution.
///
/// The service name must match the `CFBundleIdentifier` in the XPC service's
/// Info.plist. Dev builds stamp a `.dev` suffix during bundle assembly — this
/// helper derives the correct name at runtime by checking the host app's bundle ID.
public enum XPCServiceName {
    private static let audioServiceBase = "com.enviouswispr.audioservice"

    /// XPC service name for the audio capture service.
    /// Returns `com.enviouswispr.audioservice.dev` when running inside a dev bundle,
    /// `com.enviouswispr.audioservice` otherwise.
    public static var audioService: String {
        let hostID = Bundle.main.bundleIdentifier ?? ""
        if hostID.hasSuffix(".dev") {
            return audioServiceBase + ".dev"
        }
        return audioServiceBase
    }
}
