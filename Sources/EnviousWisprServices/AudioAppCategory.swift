import Foundation

/// Coarse app classes for audio-environment diagnostics.
///
/// This intentionally never exposes exact app identity. Bundle IDs are only used
/// locally to collapse apps with similar audio behavior into a small category set.
public enum AudioAppCategory: String, CaseIterable, Sendable {
  case meeting
  case media
  case browser
  case capture
  case voiceInput = "voice_input"
  case system
  case unknown

  public static func categorize(bundleID: String?) -> Self {
    guard let bundleID else { return .unknown }
    let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return .unknown }

    if systemBundleIDs.contains(normalized)
      || normalized.hasPrefix("com.apple.audio")
      || normalized.hasPrefix("com.apple.coreaudio")
    {
      return .system
    }
    if meetingBundleIDs.contains(normalized) { return .meeting }
    if mediaBundleIDs.contains(normalized) { return .media }
    if browserBundleIDs.contains(normalized) { return .browser }
    if captureBundleIDs.contains(normalized) { return .capture }
    if voiceInputBundleIDs.contains(normalized) { return .voiceInput }
    return .unknown
  }

  private static let meetingBundleIDs: Set<String> = [
    "com.apple.facetime",
    "com.cisco.webexmeetingsapp",
    "com.cisco.webex",
    "com.google.chrome.app.gpjlkieedgaklpjfjconbcdnfocfcegj", // Google Meet PWA
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.tinyspeck.slackmacgap",
    "com.webex.meetingmanager",
    "us.zoom.xos",
    "com.zoom.xos",
    "com.hnc.discord",
  ]

  private static let mediaBundleIDs: Set<String> = [
    "com.apple.music",
    "com.apple.quicktimeplayerx",
    "com.apple.tv",
    "com.google.chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod", // YouTube PWA
    "com.netflix.netflix",
    "com.spotify.client",
    "org.videolan.vlc",
  ]

  private static let browserBundleIDs: Set<String> = [
    "app.zen-browser.zen",
    "com.apple.safari",
    "com.brave.browser",
    "com.google.chrome",
    "com.microsoft.edgemac",
    "company.thebrowser.browser",
    "org.mozilla.firefox",
  ]

  private static let captureBundleIDs: Set<String> = [
    "com.globaldelight.vmaker",
    "com.latenitesoft.screenflow",
    "com.loom.desktop",
    "com.obsproject.obs-studio",
    "com.riverside.riverside",
  ]

  private static let voiceInputBundleIDs: Set<String> = [
    "com.apple.siri",
    "com.apple.speechrecognitioncorespeechd",
    "com.enviouswispr.app",
    "com.enviouswispr.app.dev",
    "com.superwhisper.superwhisper",
    "com.wisprflow.wisprflow",
  ]

  private static let systemBundleIDs: Set<String> = [
    "com.apple.audiomxd",
    "com.apple.audio.coreaudiod",
    "com.apple.coreaudiod",
    "com.apple.controlcenter",
    "com.apple.systemuiserver",
  ]
}
