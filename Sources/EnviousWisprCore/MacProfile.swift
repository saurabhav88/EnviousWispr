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

extension MacProfile {
  /// The Mac's own preferred languages, most preferred first (the global-domain `AppleLanguages`
  /// list, for example `["fr-CA", "en-US"]`), or empty when macOS reports none. The one reader of
  /// that list: Setup advice (`MacProfileReader`), the Appearance page and Apple Live Preview's
  /// Auto language read it here. Never the app's interface override, which `Locale.current` and
  /// `Bundle.main` follow (#4813: the language of `Locale.current` is the best match among the
  /// interface languages the app ships, not the Mac's language).
  package static var systemLanguages: [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
      as? [String] ?? []
  }

  /// The Mac's first preferred language and its script, for the given region (#4813 rule; moved
  /// here for #4824 so Live Preview's Auto tag and snippet dates share it). Nil when the first
  /// preference gives no language.
  ///
  /// The script is the preference's own (zh-Hant-TW) or, when it names a region, the one that
  /// region implies (zh-TW is Traditional), so a different `region` cannot change the script
  /// (zh-TW with Region United States must not become zh-US, which Apple reads as Simplified).
  /// A script `region` already implies is dropped (zh-Hant with TW gives zh-TW, the spelling
  /// Apple's dictation and meeting lists carry); an unusual one is kept (sr-Latn-RS,
  /// zh-Hans-TW), and any script is kept when there is no region.
  package static func preferredLanguage(macLanguages: [String], region: Locale.Region?)
    -> (code: Locale.LanguageCode, script: Locale.Script?)?
  {
    guard let first = macLanguages.first, !first.isEmpty else { return nil }
    // Components, not `Locale.Language`: the latter infers a script ("en-Latn-US").
    let preferred = Locale.Language.Components(identifier: first)
    guard let code = preferred.languageCode else { return nil }
    var script =
      preferred.script
      ?? (preferred.region == nil
        ? nil
        : Locale.Language.Components(
          identifier: Locale.Language(identifier: first).maximalIdentifier
        ).script)
    if let explicit = script, let region {
      let implied = Locale.Language(languageCode: code, script: nil, region: region)
        .maximalIdentifier
      if Locale.Language(identifier: implied).script == explicit { script = nil }
    }
    return (code: code, script: script)
  }

  /// The Mac's own clock and format settings that a locale rebuilt from components would lose
  /// (#4824 Codex review). Read from the global domain: custom date or time formats
  /// (`AppleICUDateFormatStrings` / `AppleICUTimeFormatStrings`, which `Locale.current` honors and
  /// a rebuilt locale does not) and a forced 24- or 12-hour clock (`AppleICUForce24HourTime` /
  /// `AppleICUForce12HourTime`).
  package struct FormatPreferences: Sendable, Equatable {
    package var customFormats: Bool
    package var forcedHourCycle: Locale.HourCycle?

    package init(customFormats: Bool, forcedHourCycle: Locale.HourCycle?) {
      self.customFormats = customFormats
      self.forcedHourCycle = forcedHourCycle
    }

    package static var live: FormatPreferences {
      let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
      let custom = ["AppleICUDateFormatStrings", "AppleICUTimeFormatStrings"].contains {
        (global?[$0] as? [String: Any])?.isEmpty == false
      }
      let cycle: Locale.HourCycle? =
        global?["AppleICUForce24HourTime"] as? Bool == true
        ? .zeroToTwentyThree
        : global?["AppleICUForce12HourTime"] as? Bool == true ? .oneToTwelve : nil
      return FormatPreferences(customFormats: custom, forcedHourCycle: cycle)
    }
  }

  /// `current` speaking the Mac's language (#4824): the language and script come from
  /// `preferredLanguage`, while region, calendar, a forced 24- or 12-hour clock and the user's
  /// other preferences stay. `current` itself when the list gives no language, already names
  /// that language, or the Mac has custom date or time formats: the user's own format wins,
  /// exactly as before #4824 (a Mac with only a custom time format therefore keeps dates in
  /// `current`'s language too: accepted, no worse than before). An unforced clock follows the
  /// Mac's language and region, as macOS shows it. In the app `Locale.current` takes its
  /// LANGUAGE from the interface language (#4813), so text the user writes (a dictated date)
  /// must not use it directly.
  package static func macLanguageLocale(
    macLanguages: [String], current: Locale, preferences: FormatPreferences
  ) -> Locale {
    guard !preferences.customFormats,
      let preferred = preferredLanguage(macLanguages: macLanguages, region: current.region)
    else { return current }
    var components = Locale.Components(locale: current)
    if components.languageComponents.languageCode == preferred.code,
      components.languageComponents.script == preferred.script
    {
      return current
    }
    if let cycle = preferences.forcedHourCycle { components.hourCycle = cycle }
    components.languageComponents.languageCode = preferred.code
    components.languageComponents.script = preferred.script
    // Keep the user's calendar even when the replacement language defaults to another one.
    components.calendar = current.calendar.identifier
    return Locale(components: components)
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
