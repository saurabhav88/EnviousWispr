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
