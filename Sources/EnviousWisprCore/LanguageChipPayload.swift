import Foundation

/// Visual state of the language-lock chip surfaced post-dictation.
///
/// Strikes 1 and 2 surface `.askToLock`: "Detected <Lang>. Lock it?" with Lock + Dismiss buttons.
/// Strike 3 surfaces `.educateAboutSettings`: "Detected <Lang>. This can be changed in Settings."
/// with Dismiss only. After State B is dismissed, the chip suppresses for that language until
/// a different language is detected.
public enum LanguageChipDisplayState: Equatable, Sendable {
  /// Strikes 1 and 2: ask the user to lock, with both Lock and Dismiss buttons.
  case askToLock
  /// Strike 3: educate about Settings, no Lock button.
  case educateAboutSettings
}

/// Payload for the passive language-detection chip overlay surface.
///
/// Carried by `OverlayIntent.passiveChip(payload:)`. Created by `LanguageChipCoordinator`
/// when surfacing a buffered detector trigger; consumed by the overlay panel to render
/// the chip view.
///
/// `generation` is a per-coordinator-instance monotonic counter used as a race-protection
/// token for auto-dismiss timers. The auto-dismiss callback checks `currentChip.generation
/// == passedGeneration` before clearing state — protects the rare case where a newer chip
/// arrived while the old timer was still pending.
public struct LanguageChipPayload: Equatable, Sendable {
  /// Normalized ISO 639-1 base code (e.g. "es", "fr", "ja"). Variant suffixes (`en-US`,
  /// `pt_BR`) are stripped upstream in `LanguageChipCoordinator.normalizedBase`.
  public let lang: String

  /// Localized display name from `Locale.current.localizedString(forLanguageCode:)`,
  /// capitalized. Falls back to the raw `lang` code if the locale lookup returns nil.
  public let displayName: String

  /// Visual state derived from `dismissalCounts[lang]` at surface time.
  public let state: LanguageChipDisplayState

  /// Monotonic race-protection token. Auto-dismiss callbacks pass the generation they
  /// captured at chip-show time; coordinator only acts if the current chip still has that
  /// generation.
  public let generation: UInt64

  public init(
    lang: String,
    displayName: String,
    state: LanguageChipDisplayState,
    generation: UInt64
  ) {
    self.lang = lang
    self.displayName = displayName
    self.state = state
    self.generation = generation
  }
}
