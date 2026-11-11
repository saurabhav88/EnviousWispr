import EnviousWisprCore
import Foundation

/// Which EG-1 size the app advises for this Mac (#4473, founder 2026-11-10).
///
/// Advice only. It is computed from the Mac's installed memory and the dictation language
/// setting, and from nothing else: not from which sizes are published or installed, not from
/// the interface language, not from what was recognised recently. The size the app USES is
/// the stored preference (`SettingsManager.egOneSize`); this value only seeds that preference
/// once, for a user with no EG-1 history, and labels a card "Recommended".
///
/// Memory tiers, by installed memory in GiB (Macs report whole binary gigabytes):
/// - under 16: Micro, or Mini when dictation is locked to a language that is not English.
///   Automatic language detection counts as English here, so the 8 GB default stays Micro.
/// - 16 up to (not including) 32: Mini. This holds the 16, 18 and 24 GB Macs.
/// - 32 and more: the full size.
public enum EGOneSizeRecommendation {
  static let bytesPerGiB: UInt64 = 1 << 30

  public static func recommended(physicalMemoryBytes: UInt64, language: LanguageMode)
    -> EGOneSize
  {
    if physicalMemoryBytes >= 32 * bytesPerGiB { return .full }
    if physicalMemoryBytes >= 16 * bytesPerGiB { return .mini }
    return isLockedToAnotherLanguageThanEnglish(language) ? .mini : .micro
  }

  /// This Mac's recommendation, for the dictation language given.
  public static func forThisMac(language: LanguageMode) -> EGOneSize {
    recommended(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, language: language)
  }

  static func isLockedToAnotherLanguageThanEnglish(_ language: LanguageMode) -> Bool {
    guard case .locked(let code) = language else { return false }
    let lowered = code.lowercased()
    return !(lowered == "en" || lowered.hasPrefix("en-") || lowered.hasPrefix("en_"))
  }
}

/// The one rule that turns "what is stored" into the EG-1 size preference, the first time a
/// build that knows sizes starts (#4473 plan §3.1.1 S4).
///
/// - A known stored size is kept, whatever else is true.
/// - Nothing stored, and the user already used EG-1 (it is selected on a surface, or an EG-1
///   install record exists): the full size. EG-1 was one model before sizes, and that model
///   continues as the full size, so an existing user is never moved to a smaller model.
/// - Nothing stored and no EG-1 history: the recommendation.
/// - A stored value this build does not know (written by a newer build): the recommendation,
///   even with EG-1 history. The value meant a size this build cannot run.
///
/// It never looks at which sizes are installed or published.
public enum EGOneSizeResolution {
  public enum Stored: Equatable, Sendable {
    case absent
    case known(EGOneSize)
    case unknown
  }

  public static func resolve(stored: Stored, hasPriorEGOneUse: Bool, recommendation: EGOneSize)
    -> EGOneSize
  {
    switch stored {
    case .known(let size): size
    case .absent: hasPriorEGOneUse ? .full : recommendation
    case .unknown: recommendation
    }
  }
}

/// What happens to the size preference when one EG-1 size is removed (#4473 plan §3.1.1 S9).
/// The only automatic substitution in the app, and it happens at a removal the user pressed,
/// never during a dictation, an import or a summary.
///
/// - The removed size is not the preference: nothing changes.
/// - It is the preference: another size takes over, chosen from the sizes that are installed
///   and are not the one being removed. The recommended size if it is one of them; otherwise
///   the nearest size, the smaller one when two are equally near.
/// - No other size is installed: EG-1 has nothing to run, so the surfaces that selected it
///   leave EG-1 (the bundled-engine removal rule), and the preference returns to the
///   recommendation for the day the user comes back.
public enum EGOneSizeRemoval {
  public enum Outcome: Equatable, Sendable {
    case preferenceUnchanged
    case moveTo(EGOneSize)
    case leaveEGOne(resetPreferenceTo: EGOneSize)
  }

  /// `preference` nil means no resolution has run yet, which every reader treats as the full
  /// size (`SettingsManager.polishModelID(for:)`). `installed` may still contain `removing`:
  /// its files exist until the removal completes, and it is never a candidate.
  public static func outcome(
    removing: EGOneSize, preference: EGOneSize?, installed: Set<EGOneSize>,
    recommendation: EGOneSize
  ) -> Outcome {
    guard (preference ?? .full) == removing else { return .preferenceUnchanged }
    let candidates = installed.subtracting([removing])
    if candidates.contains(recommendation) { return .moveTo(recommendation) }
    let nearest = candidates.min { a, b in
      let da = abs(rank(a) - rank(removing))
      let db = abs(rank(b) - rank(removing))
      return da != db ? da < db : rank(a) < rank(b)
    }
    if let nearest { return .moveTo(nearest) }
    return .leaveEGOne(resetPreferenceTo: recommendation)
  }

  /// Sizes in order, smallest first.
  static func rank(_ size: EGOneSize) -> Int {
    switch size {
    case .micro: 0
    case .mini: 1
    case .full: 2
    }
  }
}
