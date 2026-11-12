import Foundation

/// What first-run Setup may know about this Mac when it recommends a language, a speech model
/// and an AI polish model (#4528 plan §3.2).
///
/// A snapshot of advice inputs, never stored: `MacProfileReader` (Services) rebuilds it each time
/// advice is asked for. Unknown values are valid and mean "do not use this input"; nothing here
/// is guessed from another field.
public struct MacProfile: Sendable, Equatable {
  /// Installed memory in whole binary gigabytes (Macs report whole GiB).
  public let memoryGiB: Int
  /// The chip name as the Mac reports it (for example "Apple M4 Pro"), or nil when it could not be
  /// read. Kept raw: there is no hardware catalogue, and no rule reads it today.
  public let chipName: String?
  /// The macOS major version (14, 15, 26, 27).
  public let macOSMajor: Int
  /// What Setup may say about Apple Intelligence on this Mac (plan M24).
  public let appleIntelligence: AppleIntelligenceSetupState
  /// The Mac's own preferred languages, most preferred first, as BCP-47 identifiers ("fr-CA",
  /// "de"). The system list, never the app's interface language (plan M20).
  public let macLanguages: [String]
  /// Free space on the startup volume for important downloads, in bytes, or nil when unknown.
  public let freeDiskBytes: Int64?

  public init(
    memoryGiB: Int, chipName: String?, macOSMajor: Int,
    appleIntelligence: AppleIntelligenceSetupState, macLanguages: [String], freeDiskBytes: Int64?
  ) {
    self.memoryGiB = memoryGiB
    self.chipName = chipName
    self.macOSMajor = macOSMajor
    self.appleIntelligence = appleIntelligence
    self.macLanguages = macLanguages
    self.freeDiskBytes = freeDiskBytes
  }

  /// The base language code of the Mac's most preferred language ("fr" for "fr-CA"), or nil.
  public var primaryMacLanguageCode: String? {
    macLanguages.first.flatMap { Self.baseCode($0) }
  }

  /// "fr-CA" → "fr", "zh-Hans-CN" → "zh", "EN" → "en". Nil for an empty identifier.
  public static func baseCode(_ identifier: String) -> String? {
    let base = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
    guard let base, !base.isEmpty else { return nil }
    return base.lowercased()
  }
}

/// What Setup may say about Apple Intelligence (plan M24, #1454, #1080).
///
/// Derived ONLY from the availability report's actionable notice and its live status, never from
/// the chip, the macOS version or a missing notice: Apple's reasons are not to be guessed
/// (`AppleIntelligenceAvailabilityReport.onboardingPolishNotice`).
public enum AppleIntelligenceSetupState: String, Sendable, Equatable, CaseIterable {
  /// Available now: Setup may offer it as the easiest way to start.
  case available
  /// Reported turned off: Setup may say it can be turned on in System Settings.
  case turnedOff
  /// This macOS is too old for it: Setup may say so.
  case needsNewerMacOS
  /// The model is still getting ready: Setup may offer to check again.
  case gettingReady
  /// Not available for a reason the app cannot act on or does not know. Setup says nothing about why.
  case unavailable

  /// The one mapping from the report's facts.
  public static func from(
    notice: AppleIntelligenceAvailabilityReport.OnboardingPolishNotice?,
    live: AppleIntelligenceLiveAvailability
  ) -> AppleIntelligenceSetupState {
    switch notice {
    case .enableInSettings: return .turnedOff
    case .updateMacOS: return .needsNewerMacOS
    case nil:
      switch live {
      case .available: return .available
      case .modelNotReady: return .gettingReady
      case .disabled, .notEligible, .unsupported, .unknown: return .unavailable
      }
    }
  }
}
