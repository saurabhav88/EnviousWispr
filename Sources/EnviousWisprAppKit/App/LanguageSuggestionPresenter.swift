import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Owns the lifecycle of the passive language-detection discoverability chip:
/// when to show it, what state to show it in, when to suppress it, and how to
/// react to user actions on it. Carries per-language dismissal counter,
/// suppression set, the buffered detector trigger awaiting pipeline completion,
/// and the call to surface the chip onto `RecordingOverlayPanel`.
///
/// Owns the passive LID discoverability chip ONLY. Other language-related UIs
/// (auto-switch hints, vocabulary suggestions, language-display preferences,
/// future LID surfaces) do NOT belong here — they get their own home. The name
/// `LanguageSuggestionPresenter` is broad on purpose so views inject one stable
/// type, but the scope is narrow. See `state-ownership.md` decision-tree #6.
///
/// Heart-path: pure limb. All methods no-throw. Persistence is best-effort
/// (corrupted UserDefaults: log breadcrumb, delete bad key, start empty).
/// Never blocks the pipeline.
///
/// Two-phase API for buffer/surface timing:
/// - `bufferTrigger(_:)` is called from the LanguageDetector handler at emit
///   time, which happens during pipeline `.transcribing` (before `.complete`).
///   Stores the latest valid trigger.
/// - `surfaceBufferedChipIfPossible(currentLanguageMode:)` is called by the
///   pipeline-completion site on transition to `.complete` (parakeet) or
///   `.complete` / `.ready` (whisperkit). Decides whether to surface the chip
///   given current language mode and the overlay's current intent (read via
///   the injected `readCurrentIntent` closure). Calls `showOverlay` internally
///   when the chip is to surface — caller does not need to read state back.
/// - `clearBuffer()` is called on cancel/error paths so a half-buffered trigger
///   does not linger.
///
/// Constructor takes narrow overlay-presenting closures rather than an overlay
/// reference so the presenter doesn't know `RecordingOverlayPanel`'s type
/// (cleaner test seam; lets PR8/PR9 move the overlay's owner without changing
/// this type's signature).
@MainActor
@Observable
final class LanguageSuggestionPresenter {
  /// Currently visible chip payload (nil = none). Internal observers may read
  /// this for UI state; the canonical "show this chip" call happens via the
  /// injected `showOverlay` closure inside `surfaceBufferedChipIfPossible`.
  private(set) var currentChip: LanguageChipPayload?

  // MARK: - Persisted state (UserDefaults)

  private var dismissalCounts: [String: Int] = [:]
  private var suppressedLanguages: Set<String> = []

  // MARK: - In-memory state (per app launch)

  private var bufferedTrigger: PassiveChipTrigger?
  private var generationCounter: UInt64 = 0

  // MARK: - Persisted state (continued)

  /// Last language we surfaced a chip for. Persisted (Codex code-diff P2-3):
  /// if in-memory only, the different-lang reset logic cannot clear a previously
  /// suppressed language across an app restart. With persistence, dictating a
  /// different language after relaunch correctly clears the prior suppression.
  private var lastShownLanguage: String?

  // MARK: - Configuration

  private let defaults: UserDefaults
  private let dismissalCountsKey = "languageChipDismissalCounts"
  private let suppressedLanguagesKey = "languageChipSuppressedLanguages"
  private let lastShownLanguageKey = "languageChipLastShownLanguage"

  /// State-B boundary: `dismissalCounts[lang] == 2` -> State B. `> 2` -> suppressed.
  private let stateBBoundary = 2

  // MARK: - Injected overlay dependencies (narrow closures)

  private let showOverlay: @MainActor (OverlayIntent) -> Void
  private let readCurrentIntent: @MainActor () -> OverlayIntent
  /// Silent hide — does NOT post the "Recording complete" AX announcement.
  /// Codex code-diff r5 [P3]: chip dismissal must not announce "Recording
  /// complete" via the .hidden case's NSAccessibility.post, which would
  /// fire a false second recording-complete announcement to VoiceOver users.
  private let hideOverlay: @MainActor () -> Void

  init(
    showOverlay: @escaping @MainActor (OverlayIntent) -> Void,
    readCurrentIntent: @escaping @MainActor () -> OverlayIntent,
    hideOverlay: @escaping @MainActor () -> Void,
    defaults: UserDefaults = .standard
  ) {
    self.showOverlay = showOverlay
    self.readCurrentIntent = readCurrentIntent
    self.hideOverlay = hideOverlay
    self.defaults = defaults
    loadPersistedState()
  }

  // MARK: - Entry points

  /// Called from `LanguageDetector` emit handler during `.transcribing`.
  /// Filters obvious irrelevance (wrong reason, English, nil lang) then stores
  /// the latest trigger for surfacing on pipeline completion. Latest-wins.
  func bufferTrigger(_ trigger: PassiveChipTrigger) {
    guard trigger.reason == .consistentHighConfidence else { return }
    guard let rawLang = trigger.lang else { return }
    let base = normalizedBase(rawLang)
    guard base != "en" else { return }
    bufferedTrigger = trigger
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_trigger_received",
      data: [
        "lang": base,
        "reason": trigger.reason.rawValue,
      ]
    )
  }

  /// Called on pipeline transition to `.complete` (parakeet) or
  /// `.complete`/`.ready` (whisperkit). Decides whether to surface the buffered
  /// trigger given the current language mode and the overlay's current intent
  /// (read via the injected closure). Calls `showOverlay(.passiveChip(...))`
  /// internally when surfacing.
  ///
  /// F5 locked-mode guard: no-op if `currentLanguageMode != .auto`.
  /// F14 overlay-priority guard: chip surfaces ONLY when `readCurrentIntent()` returns `.hidden`.
  /// Different-lang reset: if a previously surfaced lang differs from the new one,
  /// clear that previous lang's suppression and dismissal count first.
  ///
  /// The buffered trigger is consumed regardless of outcome (a stale trigger
  /// should not roll over into the next dictation).
  func surfaceBufferedChipIfPossible(currentLanguageMode: LanguageMode) {
    guard let trigger = bufferedTrigger else { return }
    bufferedTrigger = nil
    guard let rawLang = trigger.lang else { return }
    let lang = normalizedBase(rawLang)

    // F5: locked-mode guard
    if case .locked = currentLanguageMode { return }

    // Different-lang reset (R1 F4 + R2-3 cross-launch persistence): clear prev
    // lang's state before considering current lang's suppression OR the overlay
    // guard. lastShownLanguage is persisted so this also fires after a relaunch.
    //
    // Codex code-diff r8 [P2]: this MUST run before the F14 overlay-priority
    // guard. Otherwise, a different-language trigger arriving while another
    // overlay is active (clipboardFallback, accessibilityToast, warning) would
    // consume the buffer without clearing the previous lang's suppression —
    // leaving a previously suppressed lang stuck even though the user has
    // since dictated in a different language.
    let prevLangChanged: Bool
    if let prev = lastShownLanguage, prev != lang {
      suppressedLanguages.remove(prev)
      dismissalCounts[prev] = 0
      prevLangChanged = true
    } else {
      prevLangChanged = false
    }

    // F14: overlay-priority guard. Chip MUST NOT replace an active overlay
    // (including .clipboardFallback) because the panel is single-intent.
    let currentIntent = readCurrentIntent()
    guard case .hidden = currentIntent else {
      // Persist the prev-lang reset if it happened — its effect must survive.
      if prevLangChanged { persistState() }
      return
    }

    guard !suppressedLanguages.contains(lang) else {
      // Suppressed; still persist the cleared previous lang state above
      // (lastShownLanguage stays at its prior value until we actually surface
      // a chip for the new lang).
      persistState()
      return
    }

    let count = dismissalCounts[lang] ?? 0
    let state: LanguageChipDisplayState =
      (count >= stateBBoundary) ? .educateAboutSettings : .askToLock
    generationCounter &+= 1
    let payload = LanguageChipPayload(
      lang: lang,
      displayName: Self.localizedDisplayName(lang),
      state: state,
      generation: generationCounter
    )
    currentChip = payload
    lastShownLanguage = lang
    persistState()
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_shown",
      data: [
        "lang": lang,
        "state": state == .askToLock ? "askToLock" : "educateAboutSettings",
        "dismissalCount": count,
        "generation": Int(generationCounter),
      ]
    )
    showOverlay(.passiveChip(payload: payload))
  }

  /// Clear the currently visible chip payload, e.g. when a new recording starts
  /// or pipeline errors. Hides the overlay via the injected closure.
  func clearCurrentChip() {
    currentChip = nil
  }

  /// Cancel/error path: drop any buffered trigger so it does not surface later.
  func clearBuffer() {
    bufferedTrigger = nil
  }

  // MARK: - User actions

  /// User tapped Lock. Returns the language code so the caller can write
  /// `settings.languageMode = .locked(lang)`. Hides the chip overlay.
  @discardableResult
  func accept() -> String? {
    guard let chip = currentChip else { return nil }
    let prevCount = dismissalCounts[chip.lang] ?? 0
    dismissalCounts[chip.lang] = 0
    suppressedLanguages.remove(chip.lang)
    currentChip = nil
    persistState()
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_locked",
      data: ["lang": chip.lang, "prevDismissalCount": prevCount]
    )
    hideOverlay()
    return chip.lang
  }

  /// User tapped the Dismiss button (explicit). Increments the dismissal count.
  /// Crossing the State-B boundary suppresses the language. Hides the chip overlay.
  func dismissExplicit() {
    guard let chip = currentChip else { return }
    let prevCount = dismissalCounts[chip.lang] ?? 0
    let newCount = prevCount + 1
    dismissalCounts[chip.lang] = newCount
    let nowSuppressed: Bool
    if newCount > stateBBoundary {
      suppressedLanguages.insert(chip.lang)
      nowSuppressed = true
    } else {
      nowSuppressed = false
    }
    currentChip = nil
    persistState()
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_dismissed_explicit",
      data: [
        "lang": chip.lang,
        "prevDismissalCount": prevCount,
        "newDismissalCount": newCount,
        "nowSuppressed": nowSuppressed,
      ]
    )
    if nowSuppressed {
      SentryBreadcrumb.add(
        stage: "language_chip",
        message: "chip_suppressed",
        data: ["lang": chip.lang]
      )
    }
    hideOverlay()
  }

  /// Auto-dismiss timer fired. Per F2 council resolution: does NOT count as a
  /// strike (user not looking is not user rejecting). Generation token guards
  /// against acting on stale timers. Hides the chip overlay ONLY if the
  /// overlay is still showing the chip — Codex code-diff r4 [P2]: a stale
  /// auto-dismiss task from a chip that was replaced by recording/processing/
  /// clipboardFallback would otherwise call .hidden and clobber the new overlay.
  func autoDismiss(generation: UInt64) {
    guard let chip = currentChip, chip.generation == generation else { return }
    let prevCount = dismissalCounts[chip.lang] ?? 0
    currentChip = nil
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_auto_dismissed",
      data: [
        "lang": chip.lang,
        "generation": Int(generation),
        "prevDismissalCount": prevCount,
      ]
    )
    // Only hide if the overlay still shows this chip — replacing-overlay race guard.
    if case .passiveChip(let payload) = readCurrentIntent(), payload.generation == generation {
      hideOverlay()
    }
  }

  /// Settings reset: clear all chip state (counts, suppression, buffer, current,
  /// last-shown). Persisted keys are fully REMOVED (not overwritten with empty
  /// values) so re-reads start from a clean absent-key state.
  func resetAllChipState() {
    let priorCounts = dismissalCounts.count
    let priorSuppressed = suppressedLanguages.count
    let chipWasVisibleBeforeReset = currentChip != nil
    dismissalCounts.removeAll()
    suppressedLanguages.removeAll()
    lastShownLanguage = nil
    bufferedTrigger = nil
    currentChip = nil
    // Codex grounded review 2026-05-18 Finding 4: explicit removeObject for
    // all three keys, so post-reset the persisted state is absent-keys (matches
    // first-run semantics) rather than empty-encoded-containers.
    defaults.removeObject(forKey: dismissalCountsKey)
    defaults.removeObject(forKey: suppressedLanguagesKey)
    defaults.removeObject(forKey: lastShownLanguageKey)
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_settings_reset",
      data: [
        "priorCountsCount": priorCounts,
        "priorSuppressedCount": priorSuppressed,
      ]
    )
    // Codex code-diff review 2026-05-18 [P2]: only hide the overlay if the
    // chip itself was visible. Reset is fired from Settings, which is
    // independent of the chip's visibility — if another overlay (recording,
    // processing, clipboardFallback) is active, hiding it would corrupt UI
    // state during active dictation.
    if chipWasVisibleBeforeReset, case .passiveChip = readCurrentIntent() {
      hideOverlay()
    }
  }

  // MARK: - Helpers

  /// Normalize a language code to ISO 639-1 base by lowercasing and stripping
  /// any variant suffix after `-` or `_`. `en-US` -> `en`, `pt_BR` -> `pt`.
  /// Aligns with `LanguageDetector.normalizeLangCode` behavior plus variant stripping.
  func normalizedBase(_ lang: String) -> String {
    let lower = lang.lowercased()
    if let sepIdx = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
      return String(lower[..<sepIdx])
    }
    return lower
  }

  private static func localizedDisplayName(_ lang: String) -> String {
    Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang
  }

  // MARK: - Persistence (best-effort, no-throw)

  /// Load persisted state. On JSON decode failure, log a breadcrumb AND delete
  /// the corrupted key (F8: prevents recurrence on the next launch).
  private func loadPersistedState() {
    if let data = defaults.data(forKey: dismissalCountsKey) {
      do {
        dismissalCounts = try JSONDecoder().decode([String: Int].self, from: data)
      } catch {
        SentryBreadcrumb.add(
          stage: "language_chip",
          message: "chip_state_decode_failed",
          level: .warning,
          data: [
            "key": dismissalCountsKey,
            "errorDescription": "\(error)",
          ]
        )
        defaults.removeObject(forKey: dismissalCountsKey)
        dismissalCounts = [:]
      }
    }
    if let data = defaults.data(forKey: suppressedLanguagesKey) {
      do {
        let arr = try JSONDecoder().decode([String].self, from: data)
        suppressedLanguages = Set(arr)
      } catch {
        SentryBreadcrumb.add(
          stage: "language_chip",
          message: "chip_state_decode_failed",
          level: .warning,
          data: [
            "key": suppressedLanguagesKey,
            "errorDescription": "\(error)",
          ]
        )
        defaults.removeObject(forKey: suppressedLanguagesKey)
        suppressedLanguages = []
      }
    }
    // P2-3: lastShownLanguage persists so the different-lang reset rule works
    // across app launches.
    lastShownLanguage = defaults.string(forKey: lastShownLanguageKey)
  }

  private func persistState() {
    if let data = try? JSONEncoder().encode(dismissalCounts) {
      defaults.set(data, forKey: dismissalCountsKey)
    }
    if let data = try? JSONEncoder().encode(Array(suppressedLanguages).sorted()) {
      defaults.set(data, forKey: suppressedLanguagesKey)
    }
    if let last = lastShownLanguage {
      defaults.set(last, forKey: lastShownLanguageKey)
    } else {
      defaults.removeObject(forKey: lastShownLanguageKey)
    }
  }
}
