import Foundation

/// Which landing results are a MISS the app may act on (#3106): the one tuning table.
///
/// The arrival session reports what it observed; this decides which observations are trustworthy
/// misses for a destination class. It starts narrow: a readable field that stayed without the text,
/// or no focus at all in an app whose focus can be read without opting it in. Everything else,
/// including every `cannotRead` and `inconclusive`, is not a miss: the app then does what it does
/// today. Changing eligibility is an edit to `isMiss`, nowhere else.
package enum PasteLandingPolicy {

  package static func isMiss(
    _ landing: PasteArrivalLanding, appClass: TelemetryService.LearnFromEditsTelemetry.AppClass
  ) -> Bool {
    switch landing {
    case .absent:
      switch appClass {
      // A manual-accessibility host is eligible only because `.absent` itself required its field
      // to be readable BEFORE dispatch and unchanged throughout (the session's negative rules).
      case .native, .browser, .manualAccessibility: return true
      case .other: return false
      }
    case .noTarget:
      switch appClass {
      case .native, .browser: return true
      // An Electron host that was never opted in can report no focus while a field has it.
      case .manualAccessibility, .other: return false
      }
    case .found, .cannotRead, .inconclusive:
      return false
    }
  }

  /// An app, and optionally one paste route in it, where a checked miss must NOT keep the dictation
  /// on the clipboard (#3106 PR B). `tier == nil` excludes every route in that app.
  package struct Exclusion: Hashable, Sendable {
    package let bundleID: String
    package let tier: PasteTier?

    package init(bundleID: String, tier: PasteTier? = nil) {
      self.bundleID = bundleID
      self.tier = tier
    }
  }

  /// Apps and routes that failed a PR B gate. Starts EMPTY (founder 2026-09-23: built on, narrowed only
  /// by evidence); each entry added later carries its evidence line beside it. An exclusion changes
  /// only permission: the arrival session still observes and reports the paste, late hits included.
  package static let excludedRoutes: Set<Exclusion> = [
    // G3, #3106 PR B #996 app UAT 2026-09-23: the dictation landed in the editor (read back by
    // the harness) while the arrival session saw `absent` (`late_check=censored`); VS Code's editor
    // does not expose the pasted text to the reader in time. A false miss would replace the user's
    // clipboard, so no route retains here.
    Exclusion(bundleID: "com.microsoft.VSCode"),
    // Same run: `menu_paste` into a cell read `absent`, and neither the harness nor #996 could read
    // the cell back, so the miss is unconfirmed; a cell paste can land outside the element watched.
    Exclusion(bundleID: "com.microsoft.Excel"),
  ]

  /// May this paste's miss keep the dictation on the clipboard and show the clipboard pill?
  ///
  /// Permission, separate from `isMiss` on purpose: `isMiss` also decides which results get the
  /// late-hit shadow, so an exclusion placed there would stop collecting the very evidence that could
  /// lift it. Only routes that put the dictation on the board and posted a paste can retain it:
  /// Tier 1 never wrote the board, and clipboard-only already leaves the dictation there.
  package static func mayRetain(
    _ landing: PasteArrivalLanding,
    bundleID: String?,
    appClass: TelemetryService.LearnFromEditsTelemetry.AppClass,
    tier: PasteTier,
    excluded: Set<Exclusion> = excludedRoutes
  ) -> Bool {
    routeMayRetain(bundleID: bundleID, tier: tier, excluded: excluded)
      && isMiss(landing, appClass: appClass)
  }

  /// The route half of `mayRetain`, answerable before the landing decision: whether this app and
  /// route could keep a miss at all. The cleanup waits for a decision only when this is true, so an
  /// excluded route, Tier 1 and clipboard-only keep today's cleanup timing exactly.
  package static func routeMayRetain(
    bundleID: String?, tier: PasteTier, excluded: Set<Exclusion> = excludedRoutes
  ) -> Bool {
    switch tier {
    case .cgEvent, .appleScript, .menuPaste: break
    case .axDirect, .clipboardOnly: return false
    }
    // An app we cannot name cannot be checked against the exclusions, so it does not retain.
    guard let bundleID else { return false }
    return !excluded.contains(Exclusion(bundleID: bundleID))
      && !excluded.contains(Exclusion(bundleID: bundleID, tier: tier))
  }
}
