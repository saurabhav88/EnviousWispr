import Foundation

/// Tracks which onboarding step the user has reached.
/// Raw values are legacy UserDefaults strings — do NOT change them.
public enum OnboardingState: String, Codable, Sendable {
  case notStarted = "needsMicPermission"
  case settingUp = "needsModelDownload"
  case needsPermissions = "needsCompletion"
  case completed = "completed"
}

/// User's window-appearance preference. `.system` follows the macOS setting
/// (and repaints live when it changes); `.light`/`.dark` pin a mode.
/// Persisted by its `rawValue`; unknown/missing values resolve to `.system`.
public enum AppearancePreference: String, CaseIterable, Sendable {
  case system
  case light
  case dark
}

/// Which engine draws the on-screen preview (#2123, chunk 5 of #2077).
///
/// Persisted by rawValue; unknown or missing values resolve to `.apple`, which
/// is the founder's Gate 1 decision: Apple's engine wherever it genuinely works,
/// and the 217 MB universal model offered rather than imposed.
///
/// An enum rather than a Bool so a third engine costs a case, not a migration —
/// this feature already replaced "the only engine" with "two engines" once.
public enum LivePreviewEngineChoice: String, CaseIterable, Sendable {
  /// macOS speech recognition. No separate download, needs macOS 26, and only
  /// covers the languages macOS has already installed.
  case apple
  /// The downloadable universal model. No OS floor beyond the app's own, carries
  /// its own languages, costs one optional 217 MB download.
  case universal
}

/// Which recording pill the user gets (#2375 Phase 3; moved here by #2376 C4/C6).
///
/// **A DESIGN, not a capability.** Whether the machine can show words as you
/// speak is a capability the director reads; which pill is drawn is a choice the
/// user makes. Keeping those two vocabularies apart is what lets one change
/// without touching the other.
///
/// **It lives in Core because a SETTING persists it**, and `SettingsManager` is
/// in Services. Only the identity is here: `canHoldWords`, `width`,
/// `reservedHeight` and `chrome` are an AppKit extension, because Core has no
/// business knowing a pill's pixels. Persisted by rawValue, which derives from
/// the case NAMES — `recordingPillDesignRawValuesAreStable` pins them, because a
/// rename would silently orphan every saved selection to the fallback.
///
/// **`package`, not `public`, and it is forced rather than stylistic.** A public
/// non-frozen enum from another module makes every switch over it demand
/// `@unknown default`, which would destroy this phase's exhaustive-routing
/// requirement — a design added later could then render as a neighbour by falling
/// through. `package` keeps the compiler's exhaustiveness and is already used
/// cross-module in this build.
package enum RecordingPillDesign: String, Equatable, Sendable, CaseIterable {
  /// The rainbow-lips capsule: a fixed 185x92 interaction frame that holds the
  /// normal capsule, the locked state and the #1060 notice expansion without
  /// resizing on every morph.
  case classic
  /// The wide panel that shows words as you speak. Content-sized from the first
  /// frame so it does not visibly snap as lines wrap.
  ///
  /// **`.readingWell`, deliberately not `.livePreview`.** Naming a design after
  /// the capability that enables it makes the settings group label and the card
  /// label the same word, and forecloses a second with-words design before one
  /// exists. The capability keeps its own name.
  case readingWell
  /// A wider capsule carrying the clock beside a live rainbow level rail, and no
  /// lips mark (#2376 Phase 4, C5). Named for what it DRAWS, following
  /// `.readingWell`'s reasoning; it says nothing about words or preview, so it
  /// survives a capability rename.
  case levelRail
}

/// Where the recording pill (and every transient overlay sharing its window —
/// polishing, warnings, cold-start notices, the Bluetooth card) appears on
/// screen. Persisted by rawValue; unknown/missing values resolve to `.top`.
public enum OverlayPillPosition: String, CaseIterable, Sendable {
  case top
  case bottom
}

/// Which sound pairing plays for the recording start/stop cue (#1342, grown
/// to 12 pairings in #1618). Each pairing is an original, procedurally
/// synthesized start/stop pair — no sampled, recorded, licensed, or
/// competitor audio. Persisted by rawValue; unknown or missing values
/// resolve to `.whisperTick`.
///
/// Declared in ascending-loudness order (founder-validated by ear, not
/// derived from synthesis gain alone — see the #1618 plan §3a): the Settings
/// picker renders `allCases` directly with no explicit sort, so THIS
/// declaration order IS the display order. `pairingCatalogOrderMatchesApprovedSequence`
/// (RecordingSoundCueTests.swift) asserts the exact sequence to catch
/// accidental drift.
public enum RecordingSoundPairing: String, CaseIterable, Sendable {
  case dustMote
  case velvetHush
  case mutedConfirm
  case whisperTick
  case roundPebble
  case paperTap
  case softHush
  case lowNod
  case cloudPop
  case velvetTap
  case satinShift
  case airGlint
}
