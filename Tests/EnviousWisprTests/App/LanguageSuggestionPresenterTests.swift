import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Test-controllable overlay double. Holds the current intent that
/// `readCurrentIntent()` returns and records all `showOverlay(...)` and
/// `hideOverlay()` calls so tests can assert on what the presenter pushed
/// to the overlay.
@MainActor
private final class FakeOverlay {
  var currentIntent: OverlayIntent = .hidden
  var shownIntents: [OverlayIntent] = []
  var hideCallCount: Int = 0

  func show(_ intent: OverlayIntent) {
    shownIntents.append(intent)
    currentIntent = intent
  }

  func hide() {
    hideCallCount += 1
    currentIntent = .hidden
  }
}

/// Per-test UserDefaults suite so tests do not cross-contaminate or pollute
/// the real defaults domain. Mirrors the pattern in `LanguageDetectorTests`.
@MainActor
private func makeEphemeralDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
  UserDefaults(suiteName: suite)!
}

@MainActor
private func makePresenter(
  defaults: UserDefaults? = nil
) -> (LanguageSuggestionPresenter, FakeOverlay) {
  let fake = FakeOverlay()
  let presenter = LanguageSuggestionPresenter(
    showOverlay: { intent in fake.show(intent) },
    readCurrentIntent: { fake.currentIntent },
    hideOverlay: { fake.hide() },
    defaults: defaults ?? makeEphemeralDefaults()
  )
  return (presenter, fake)
}

@Suite("LanguageSuggestionPresenter state machine")
@MainActor
struct LanguageSuggestionPresenterTests {

  // MARK: - bufferTrigger filtering

  @Test("bufferTrigger stores a consistentHighConfidence trigger for non-English")
  func bufferStoresValidTrigger() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
  }

  @Test("bufferTrigger drops .lidFlipFlop reason in v1")
  func bufferDropsFlipFlop() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .lidFlipFlop))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops .consecutiveLowConfidence in v1")
  func bufferDropsLowConfidence() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consecutiveLowConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops English (en) — F4 invisibility")
  func bufferDropsEnglish() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "en", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger normalizes variant codes: en-US dropped, EN_GB dropped")
  func bufferDropsEnglishVariants() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "en-US", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
    presenter.bufferTrigger(.init(lang: "EN_GB", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops nil lang")
  func bufferDropsNilLang() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: nil, reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger latest-wins: two buffers, only last surfaces")
  func bufferLatestWins() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "fr")
  }

  // MARK: - surface guards

  @Test("F5 locked-mode guard: no chip surfaces when languageMode = .locked")
  func lockedModeBlocksSurface() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .locked("es"))
    #expect(presenter.currentChip == nil)
  }

  @Test("F14 overlay-priority guard: no chip when overlay is not .hidden")
  func overlayBusyBlocksSurface() {
    let (presenter, fake) = makePresenter()
    fake.currentIntent = .recording(audioLevel: 0.5)
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("clipboardFallback intent blocks chip per F14 R3 tightening")
  func clipboardFallbackBlocksSurface() {
    let (presenter, fake) = makePresenter()
    fake.currentIntent = .clipboardFallback
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("Buffered trigger is consumed even when surface is guarded out")
  func bufferConsumedOnGuardedSurface() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .locked("es"))
    // Even after unlocking + retrying, the prior buffered trigger should not
    // resurface — stale triggers should not roll over to the next dictation.
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  // MARK: - three-strike state machine

  @Test("Strike 1 surfaces State A (askToLock)")
  func strike1IsStateA() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
  }

  @Test("Strike 2 still surfaces State A; strike 3 surfaces State B (educate)")
  func strike3IsStateB() {
    let (presenter, _) = makePresenter()
    // Strike 1
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
    presenter.dismissExplicit()
    // Strike 2
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
    presenter.dismissExplicit()
    // Strike 3
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .educateAboutSettings)
  }

  @Test("Dismissing State B inserts language into suppression set")
  func dismissingStateBSuppresses() {
    let (presenter, _) = makePresenter()
    // Walk to State B then dismiss it
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      presenter.dismissExplicit()
    }
    // Next attempt is suppressed
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("Different language clears prior suppression and counter")
  func differentLanguageReset() {
    let (presenter, _) = makePresenter()
    // Suppress Spanish via 3 dismissals
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      presenter.dismissExplicit()
    }
    // French chip arrives → clears Spanish state
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "fr")
    presenter.dismissExplicit()  // dismiss French
    // Spanish should now surface fresh
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
    #expect(presenter.currentChip?.state == .askToLock)
  }

  @Test("Different language clears prior suppression even when overlay is busy (Codex r8 [P2])")
  func differentLanguageResetSurvivesOverlayBusy() {
    let (presenter, fake) = makePresenter()
    // Suppress Spanish via 3 dismissals
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      presenter.dismissExplicit()
    }
    // French chip arrives, but overlay is busy with clipboardFallback —
    // chip does NOT surface, but the different-lang reset MUST still happen.
    fake.currentIntent = .clipboardFallback
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)  // didn't surface
    // Now overlay is hidden. Spanish surfaces fresh (suppression cleared).
    fake.currentIntent = .hidden
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
    #expect(presenter.currentChip?.state == .askToLock)
  }

  // MARK: - user actions

  @Test("accept() returns lang and clears chip")
  func acceptReturnsLangAndClearsChip() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let lang = presenter.accept()
    #expect(lang == "es")
    #expect(presenter.currentChip == nil)
  }

  @Test("accept() unsuppresses + resets count for that language")
  func acceptUnsuppresses() {
    let (presenter, _) = makePresenter()
    // Suppress Spanish
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      presenter.dismissExplicit()
    }
    // French → Spanish reset → Spanish surfaces fresh → user accepts
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    presenter.dismissExplicit()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    _ = presenter.accept()
    // Verify accept cleared current chip
    #expect(presenter.currentChip == nil)
  }

  @Test("autoDismiss does NOT increment dismissal count (F2)")
  func autoDismissNotAStrike() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let gen = presenter.currentChip!.generation
    presenter.autoDismiss(generation: gen)
    // Next time should still be State A (count not incremented)
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
  }

  @Test("autoDismiss guarded by generation token")
  func autoDismissGenerationGuard() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let staleGen: UInt64 = 999_999
    presenter.autoDismiss(generation: staleGen)
    // Stale generation → no effect; chip still visible
    #expect(presenter.currentChip != nil)
  }

  // MARK: - clear paths

  @Test("clearCurrentChip nils the visible chip")
  func clearCurrentChipWorks() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    presenter.clearCurrentChip()
    #expect(presenter.currentChip == nil)
  }

  @Test("clearBuffer drops the buffered trigger")
  func clearBufferDropsTrigger() {
    let (presenter, _) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.clearBuffer()
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  // MARK: - settings reset

  @Test("resetAllChipState clears in-memory state and removes UserDefaults keys")
  func resetClearsEverything() {
    let defaults = makeEphemeralDefaults()
    let (presenter, _) = makePresenter(defaults: defaults)
    // Accumulate some state
    for _ in 0..<2 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      presenter.dismissExplicit()
    }
    #expect(defaults.data(forKey: "languageChipDismissalCounts") != nil)
    presenter.resetAllChipState()
    // After reset, keys should be REMOVED (not empty-encoded)
    #expect(defaults.data(forKey: "languageChipDismissalCounts") == nil)
    #expect(defaults.data(forKey: "languageChipSuppressedLanguages") == nil)
    #expect(defaults.string(forKey: "languageChipLastShownLanguage") == nil)
    // Next trigger should surface fresh State A
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
  }

  // MARK: - persistence

  @Test("Persisted state survives presenter re-instantiation")
  func persistenceRoundTrip() {
    let defaults = makeEphemeralDefaults()
    let (p1, _) = makePresenter(defaults: defaults)
    p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    p1.dismissExplicit()
    // Re-instantiate (simulates app relaunch)
    let (p2, _) = makePresenter(defaults: defaults)
    // Dismissal count should persist → next chip is State A but count=1
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.state == .askToLock)
    p2.dismissExplicit()
    // Strike 3 → State B
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.state == .educateAboutSettings)
  }

  @Test("Suppression survives presenter re-instantiation")
  func suppressionPersists() {
    let defaults = makeEphemeralDefaults()
    let (p1, _) = makePresenter(defaults: defaults)
    for _ in 0..<3 {
      p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      p1.dismissExplicit()
    }
    // Re-instantiate
    let (p2, _) = makePresenter(defaults: defaults)
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip == nil)  // still suppressed
  }

  @Test("lastShownLanguage persists across re-instantiation (Codex P2-3 fix)")
  func lastShownPersistsAcrossRelaunch() {
    let defaults = makeEphemeralDefaults()
    let (p1, _) = makePresenter(defaults: defaults)
    // Suppress Spanish
    for _ in 0..<3 {
      p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      p1.dismissExplicit()
    }
    // Re-instantiate → different lang detected → should clear es suppression
    let (p2, _) = makePresenter(defaults: defaults)
    p2.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.lang == "fr")
    p2.dismissExplicit()
    // Spanish should now surface fresh — the lastShownLanguage = "es" persisted,
    // and detecting "fr" (different lang) cleared es suppression.
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.lang == "es")
    #expect(p2.currentChip?.state == .askToLock)
  }

  @Test("Corrupted UserDefaults data deletes the bad key and starts empty (F8)")
  func corruptedDefaultsRecovery() {
    let defaults = makeEphemeralDefaults()
    defaults.set("not json".data(using: .utf8)!, forKey: "languageChipDismissalCounts")
    let (presenter, _) = makePresenter(defaults: defaults)
    // Should recover gracefully — bufferTrigger + surface still works
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
    // Bad key should have been removed
    #expect(defaults.data(forKey: "languageChipDismissalCounts") != nil)  // re-encoded fresh
  }

  // MARK: - overlay call assertions (presenter calls showOverlay itself)

  @Test("Surface call pushes .passiveChip intent to overlay")
  func surfacePushesPassiveChipIntent() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let chipIntents = fake.shownIntents.compactMap { intent -> LanguageChipPayload? in
      if case .passiveChip(let payload) = intent { return payload }
      return nil
    }
    #expect(chipIntents.count == 1)
    #expect(chipIntents.first?.lang == "es")
  }

  @Test("accept() pushes .hidden to overlay after returning lang")
  func acceptHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    _ = presenter.accept()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("dismissExplicit silently hides overlay (Codex r5 [P3])")
  func dismissHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    presenter.dismissExplicit()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("autoDismiss silently hides overlay when chip is still visible (Codex r4+r5)")
  func autoDismissHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    let gen = presenter.currentChip!.generation
    presenter.autoDismiss(generation: gen)
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("autoDismiss does NOT hide when chip has been replaced (Codex r4 [P2])")
  func autoDismissDoesNotHideAfterReplacement() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let gen = presenter.currentChip!.generation
    // Simulate that recording started and replaced the overlay
    fake.currentIntent = .recording(audioLevel: 0.5)
    let beforeHide = fake.hideCallCount
    presenter.autoDismiss(generation: gen)
    // Should not have hidden the recording overlay
    #expect(fake.hideCallCount == beforeHide)
  }

  @Test(
    "resetAllChipState silently hides overlay ONLY if chip is visible (Codex r2 [P2] + r5 [P3])")
  func resetHidesOverlayOnlyWhenChipVisible() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    presenter.resetAllChipState()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("resetAllChipState does NOT touch overlay during active recording (Codex r2 [P2])")
  func resetDoesNotHideUnrelatedOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    presenter.dismissExplicit()  // chip cleared; persisted count=1
    fake.currentIntent = .recording(audioLevel: 0.5)
    let beforeHide = fake.hideCallCount
    presenter.resetAllChipState()
    #expect(fake.hideCallCount == beforeHide)
  }

  @Test("resetAllChipState does NOT touch overlay when no chip is visible (idle)")
  func resetWhenIdleDoesNotHideOverlay() {
    let (presenter, fake) = makePresenter()
    let beforeHide = fake.hideCallCount
    presenter.resetAllChipState()
    #expect(fake.hideCallCount == beforeHide)
  }

  // MARK: - normalization helper

  @Test("normalizedBase strips variant suffix and lowercases")
  func normalizationHelper() {
    let (presenter, _) = makePresenter()
    #expect(presenter.normalizedBase("en-US") == "en")
    #expect(presenter.normalizedBase("EN_GB") == "en")
    #expect(presenter.normalizedBase("Es") == "es")
    #expect(presenter.normalizedBase("pt_BR") == "pt")
    #expect(presenter.normalizedBase("fr") == "fr")
  }
}
