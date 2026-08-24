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
///   given the current language mode. Admission is the overlay's answer, not a
///   question asked of it: `present` returns a receipt or nil, and a nil commits
///   nothing (#2292 C3). Caller does not need to read state back.
/// - `clearBuffer()` is called on cancel/error paths so a half-buffered trigger
///   does not linger.
///
/// Constructor takes `any OverlayPresenting` rather than the concrete director,
/// so the presenter still does not know the overlay's type. It replaced three
/// generic closures — show, read-current-intent, hide — whose problem was not
/// their narrowness but that the middle one made this type a SECOND authority on
/// whether a chip may appear (#2292 C3).
@MainActor
@Observable
final class LanguageSuggestionPresenter {
  /// Currently visible chip payload (nil = none). Internal observers may read
  /// this for UI state.
  ///
  /// **Committed only after the overlay ACCEPTS**, never before. A refused chip
  /// leaves this nil, which is what stops the presenter believing it owns a pill
  /// somebody else is showing.
  private(set) var currentChip: LanguageChipPayload?

  /// The accepted presentation this chip owns, or nil when nothing is showing.
  ///
  /// **Every clearing path clears BOTH this and `currentChip`, and dismisses
  /// through this rather than unconditionally.** The failure it prevents is
  /// real: a chip replaced by a recording, then a Settings reset or a stale
  /// cleanup, would otherwise dismiss the RECORDING pill.
  private var currentReceipt: PillReceipt?

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

  /// Held STRONGLY, and every callback this presenter hands to a request
  /// captures `self` weakly.
  ///
  /// The cycle that shape breaks is real: the overlay retains the active
  /// presentation's callbacks, so a strong capture there would make
  /// presenter -> overlay -> binding -> presenter for as long as a chip is up.
  /// Breaking it at the BINDING is right because the binding is the transient
  /// half — it dies with the presentation — while the overlay is app-lifetime.
  private let overlay: any OverlayPresenting

  /// What to do with a language the user chose to lock.
  ///
  /// **The settings write and its telemetry stay with their owner**
  /// (`OverlayChipWiring`), which is what keeps plan §5's required sequence —
  /// clear state, dismiss, read prior mode, mutate, emit — preserved by
  /// construction rather than re-derived here. This presenter owns the chip's
  /// state machine and nothing about `SettingsManager`.
  private let onLanguageAccepted: @MainActor (String) -> Void

  init(
    overlay: any OverlayPresenting,
    onLanguageAccepted: @escaping @MainActor (String) -> Void,
    defaults: UserDefaults = .standard
  ) {
    self.overlay = overlay
    self.onLanguageAccepted = onLanguageAccepted
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
  /// `.complete`/`.ready` (whisperkit). Decides whether to OFFER the buffered
  /// trigger, given the current language mode; whether it is then admitted is
  /// the overlay's answer, returned by `present`.
  ///
  /// F5 locked-mode guard: no-op if `currentLanguageMode != .auto`.
  /// F14 overlay-priority: the chip surfaces only when the overlay ADMITS it.
  /// That decision lives in `present`, not here (#2292 C3).
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
    // **F14 overlay-priority, now asked ONCE and by the overlay.** The chip must
    // not replace a recording, a processing pill or a clipboard hint, because the
    // slot holds one presentation. That decision used to be made here by reading
    // the current intent; it now lives inside `present`, beside the state change,
    // and a refusal comes back as nil.
    //
    // **Nothing is committed before the answer.** A refused chip must not be
    // recorded as shown — not in `currentChip`, not in `lastShownLanguage`, and
    // not in the `chip_shown` breadcrumb. The previous-language reset above is
    // the deliberate exception and still persists, because its effect is about
    // the language the user has now dictated rather than about this chip.
    //
    // A refusal consumes a generation. Generations are equality/staleness
    // tokens, never dense indices, so a gap costs nothing.
    // **Committed on the RESULT, not on the receipt** (PR #2370). A receipt
    // proves admission and ownership; it cannot prove the host drew anything,
    // because the first presentation of a launch reaches the host a run loop
    // later. `lastShownLanguage` PERSISTS, so a chip committed on a refusal
    // would suppress that language across relaunches for a chip nobody saw.
    //
    // Production language chips are emitted only after a dictation presentation,
    // so the hosting view already exists and this result is synchronous. Unlike
    // launch-time Bluetooth, there is no pending-ownership window: the card in
    // `BluetoothAwarenessPresenter` holds its receipt from admission so a
    // reconcile can cancel a card that is owned but not yet drawn, and nothing
    // here needs that because nothing here can be in that state.
    //
    // **If a pre-dictation chip ingress is added, it must add pending receipt
    // ownership before shipping.** That is the activation condition, stated here
    // rather than left as an unwritten ordering assumption — without it a chip
    // admitted before the first render would be uncancellable by every path
    // below, all of which key on `currentChip` or `currentReceipt`.
    overlay.present(
      .languageChip(
        payload: payload,
        onLock: { [weak self] in self?.acceptCurrentChip() },
        onDismiss: { [weak self] in self?.dismissExplicit() },
        onExpire: { [weak self] in self?.expireCurrentChip() }
      ),
      onResult: { [weak self] result in
        guard let self else { return }
        guard case .presented(let receipt) = result else {
          if prevLangChanged { self.persistState() }
          return
        }
        self.currentChip = payload
        self.currentReceipt = receipt
        self.lastShownLanguage = lang
        self.persistState()
        SentryBreadcrumb.add(
          stage: "language_chip",
          message: "chip_shown",
          data: [
            "lang": lang,
            "state": state == .askToLock ? "askToLock" : "educateAboutSettings",
            "dismissalCount": count,
            "generation": Int(self.generationCounter),
          ]
        )
      })
  }

  /// Clear the currently visible chip payload, e.g. when a new recording starts
  /// or pipeline errors.
  ///
  /// **Drops the receipt too, and deliberately does NOT dismiss.** The callers
  /// are paths where something ELSE is taking the slot, so the presentation is
  /// already being replaced; dismissing here would be this presenter acting on a
  /// pill it no longer owns. Forgetting the receipt is the whole obligation.
  func clearCurrentChip() {
    currentChip = nil
    currentReceipt = nil
  }

  /// Cancel/error path: drop any buffered trigger so it does not surface later.
  func clearBuffer() {
    bufferedTrigger = nil
  }

  // MARK: - User actions

  /// User tapped Lock.
  ///
  /// **Order is load-bearing and plan §5 requires it exactly**: clear this
  /// presenter's state, dismiss the pill silently through its own receipt, and
  /// only then hand the language to its owner — which reads the PRIOR language
  /// mode before mutating it and emits `language.manual_lock_used` with the same
  /// `fromLang`, `toLang` and `reason` as a Settings-driven lock. Handing over
  /// first would let the owner read a mode this call is about to change.
  ///
  /// Silent dismissal, not announced: a chip going away is not a dictation
  /// ending, and `.hidden` would post a false second "Recording complete" to
  /// VoiceOver users.
  private func acceptCurrentChip() {
    guard let chip = currentChip, let receipt = currentReceipt else { return }
    let prevCount = dismissalCounts[chip.lang] ?? 0
    dismissalCounts[chip.lang] = 0
    suppressedLanguages.remove(chip.lang)
    currentChip = nil
    currentReceipt = nil
    persistState()
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_locked",
      data: ["lang": chip.lang, "prevDismissalCount": prevCount]
    )
    overlay.dismissIfCurrent(receipt)
    onLanguageAccepted(chip.lang)
  }

  /// User tapped the Dismiss button (explicit). Increments the dismissal count.
  /// Crossing the State-B boundary suppresses the language.
  ///
  /// Receipt-scoped dismissal, same reason as everywhere else here: this must
  /// only ever take away the pill this presenter was given.
  private func dismissExplicit() {
    guard let chip = currentChip else { return }
    let receipt = currentReceipt
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
    currentReceipt = nil
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
    if let receipt { overlay.dismissIfCurrent(receipt) }
  }

  /// The chip's dwell elapsed.
  ///
  /// **Does NOT count as a strike** — per the F2 council resolution, a user not
  /// looking is not a user rejecting.
  ///
  /// **No generation argument any more, and none is needed** (#2292 C3). This
  /// arrives through the `onExpire` callback that travelled WITH the chip's own
  /// request, so "which chip lapsed" is answered structurally: a superseded
  /// presentation's binding is dropped by the director when identity changes, so
  /// a stale timer cannot reach here at all. The generation lives on for the
  /// reducer, which still uses it as an expiry token.
  ///
  /// Dismissal is receipt-scoped for the reason the old generation check
  /// existed: a chip replaced by a recording, a processing pill or a clipboard
  /// hint must not have its expiry clobber the successor.
  private func expireCurrentChip() {
    guard let chip = currentChip else { return }
    let receipt = currentReceipt
    let prevCount = dismissalCounts[chip.lang] ?? 0
    currentChip = nil
    currentReceipt = nil
    SentryBreadcrumb.add(
      stage: "language_chip",
      message: "chip_auto_dismissed",
      data: [
        "lang": chip.lang,
        "generation": Int(chip.generation),
        "prevDismissalCount": prevCount,
      ]
    )
    if let receipt { overlay.dismissIfCurrent(receipt) }
  }

  /// Settings reset: clear all chip state (counts, suppression, buffer, current,
  /// last-shown). Persisted keys are fully REMOVED (not overwritten with empty
  /// values) so re-reads start from a clean absent-key state.
  func resetAllChipState() {
    let priorCounts = dismissalCounts.count
    let priorSuppressed = suppressedLanguages.count
    let resetReceipt = currentReceipt
    dismissalCounts.removeAll()
    suppressedLanguages.removeAll()
    lastShownLanguage = nil
    bufferedTrigger = nil
    currentChip = nil
    currentReceipt = nil
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
    // Codex code-diff review 2026-05-18 [P2]: reset is fired from Settings,
    // which is independent of the chip's visibility. If another presentation
    // (recording, processing, clipboardFallback) has taken the slot, dismissing
    // would corrupt UI state during an active dictation.
    //
    // **The receipt subsumes both halves of the old test** (#2292 C3). It
    // answers "was a chip showing" and "is that same chip still the current
    // presentation" in one question the overlay owns, where the old form asked
    // this presenter's own remembered flag and then re-read the overlay's intent.
    if let receipt = resetReceipt { overlay.dismissIfCurrent(receipt) }
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
