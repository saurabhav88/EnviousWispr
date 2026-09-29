import Foundation

/// Interprets landing observations and decides whether they may keep a dictation (#3106, #3286).
///
/// `isMiss` also controls the late-hit shadow; keep it observational. `mayRetain` is the
/// clipboard permission and may reject an observed miss when it is not proof of failure.
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

  /// Apps measured to reveal pasted text to the reader later than the default deadline, with their
  /// own deadline. Only the MISS decision waits longer: a new occurrence still resolves at first
  /// sight. The late-hit shadow (`PastedRegionTiming.arrivalShadowMs`) must stay longer than each.
  package static let slowRevealDeadlinesMs: [String: Int] = [
    // Ghostty exposes the whole terminal as one text area and updates it after drawing: 15 real
    // dictations (plain shell and Claude Code) first seen at 385-464 ms, median 440, as late hits
    // after a 300 ms `absent` (#3106 PR B, 2026-09-23/24). 700 ms is about 50% over the slowest.
    // Founder 2026-09-24.
    "com.mitchellh.ghostty": 700
  ]

  /// When the arrival session decides a miss for this app.
  package static func landingDeadlineMs(bundleID: String?) -> Int {
    bundleID.flatMap { slowRevealDeadlinesMs[$0] } ?? PastedRegionTiming.landingDeadlineMs
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
  ///
  /// `noTarget` cannot prove a miss while a Chromium host's accessibility is asleep (#3286): Chrome,
  /// Brave, Edge and the ChatGPT app report no focused element with their box focused and the paste
  /// landing (453 of 569 retained takes in 2.5.1). Only a permitted key route with an
  /// evidence-backed miss may retain.
  package static func mayRetain(
    _ landing: PasteArrivalLanding,
    bundleID: String?,
    appClass: TelemetryService.LearnFromEditsTelemetry.AppClass,
    tier: PasteTier,
    excluded: Set<Exclusion> = excludedRoutes
  ) -> Bool {
    guard landing != .noTarget else { return false }
    return routeMayRetain(bundleID: bundleID, tier: tier, excluded: excluded)
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
