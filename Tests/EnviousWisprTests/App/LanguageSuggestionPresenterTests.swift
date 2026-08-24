import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Test-controllable overlay double (#2292 C3).
///
/// **It is an `OverlayPresenting`, and that is the point of the chunk.** The
/// previous double answered a `readCurrentIntent` question and separately
/// recorded shows and hides, which let a test assert admission and presentation
/// as two independent things. They are one transaction now: `present` either
/// returns a receipt or refuses, and every dismissal names the receipt it means.
///
/// It also HOLDS the chip's three callbacks, because that is the only route a
/// user's press takes. A test drives Lock, Dismiss and Expire through
/// `pressLock()`/`pressDismiss()`/`expire()` rather than calling the presenter,
/// which is what makes these cases exercise the shipped path.
@MainActor
private final class FakeOverlay: OverlayPresenting {

  /// Whether the next `present` is admitted. False stands for "something else
  /// owns the slot" — a recording, a processing pill, a clipboard hint.
  var slotIsFree = true

  private(set) var presentedRequests: [PillRequest] = []
  /// Every receipt handed to `dismissIfCurrent`, matching or not.
  private(set) var dismissAttempts: [PillReceipt] = []
  /// Dismissals that actually took a presentation away.
  private(set) var hideCallCount = 0
  /// `dismissCurrent` calls — nothing in C3a should produce one.
  private(set) var unconditionalDismissals = 0
  private(set) var currentReceipt: PillReceipt?

  private var onLock: (() -> Void)?
  private var onDismiss: (() -> Void)?
  private var onExpire: (() -> Void)?

  var featureSlotIsAvailable: Bool { slotIsFree }

  func present(_ request: PillRequest) -> PillReceipt? {
    presentedRequests.append(request)
    guard slotIsFree else { return nil }
    if case .languageChip(_, let lock, let dismiss, let expire) = request {
      onLock = lock
      onDismiss = dismiss
      onExpire = expire
    }
    let receipt = PillReceipt(presentationID: PresentationID())
    currentReceipt = receipt
    slotIsFree = false
    return receipt
  }

  // MARK: - Deferred results (PR #2370)

  /// Hold the result instead of answering immediately, modelling the FIRST
  /// presentation of a launch — the only window in which a receipt can exist
  /// before the host has been asked. The chip cannot currently BE that first
  /// presentation, since a dictation always draws a pill first; the switch
  /// exists so the presenter's commit rule is testable rather than resting on
  /// a bootstrap ordering nothing here enforces.
  var defersResult = false
  var deferredHostAccepts = true
  private var heldResult: ((PillPresentationResult) -> Void)?
  private var heldReceipt: PillReceipt?

  func releaseDeferredResult() {
    guard let sink = heldResult else { return }
    heldResult = nil
    let receipt = heldReceipt
    heldReceipt = nil
    if deferredHostAccepts, let receipt {
      sink(.presented(receipt))
    } else {
      currentReceipt = nil
      slotIsFree = true
      sink(.notPresented)
    }
  }

  @discardableResult
  func present(
    _ request: PillRequest,
    onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt? {
    guard let receipt = present(request) else {
      onResult(.notPresented)
      return nil
    }
    guard defersResult else {
      onResult(.presented(receipt))
      return receipt
    }
    heldResult = onResult
    heldReceipt = receipt
    return receipt
  }

  func update(_ update: PillUpdate) {}

  func dismissCurrent(_ mode: PillDismissal) {
    unconditionalDismissals += 1
    hideCallCount += 1
    currentReceipt = nil
    slotIsFree = true
  }

  func dismissIfCurrent(_ receipt: PillReceipt) {
    dismissAttempts.append(receipt)
    guard receipt == currentReceipt else { return }
    hideCallCount += 1
    currentReceipt = nil
    slotIsFree = true
  }

  func isCurrent(_ receipt: PillReceipt) -> Bool { receipt == currentReceipt }

  // MARK: - Driving the chip's own buttons

  func pressLock() { onLock?() }
  func pressDismiss() { onDismiss?() }
  func expire() { onExpire?() }

  /// Something else took the slot while the chip was up.
  ///
  /// The callbacks deliberately SURVIVE: production drops the binding when the
  /// presentation changes, and the presenter's own guards are what this models.
  /// Keeping them lets a test fire a stale expiry and prove it takes nothing
  /// away, which is the whole point of receipt-scoped dismissal.
  func simulateReplacement() {
    currentReceipt = PillReceipt(presentationID: PresentationID())
    slotIsFree = false
  }

  /// The chips this fake was ASKED to show, refused ones included.
  var shownChips: [LanguageChipPayload] {
    presentedRequests.compactMap {
      if case .languageChip(let payload, _, _, _) = $0 { return payload }
      return nil
    }
  }
}

/// Collects breadcrumb messages from the process-global delegate.
///
/// `@unchecked Sendable` with internal locking, which is the justification
/// `swift-concurrency-patterns.md` `no-new-unchecked-sendable` requires: the
/// delegate is `@Sendable` and nonisolated, so it cannot call a `@MainActor`
/// method, and the lock is what makes every access safe rather than an
/// assumption about which thread Sentry happens to call on.
private final class BreadcrumbBox: @unchecked Sendable {
  private let mutex = NSLock()
  private var stored: [String] = []

  var messages: [String] { mutex.withLock { stored } }

  func append(stage: String, message: String) {
    guard stage == "language_chip" else { return }
    mutex.withLock { stored.append(message) }
  }
}

/// One `Int`, so a callback can record what it observed at the moment it ran.
@MainActor
private final class HideCountBox {
  var value = -1
}

/// Per-test UserDefaults suite so tests do not cross-contaminate or pollute
/// the real defaults domain. Mirrors the pattern in `LanguageDetectorTests`.
@MainActor
private func makeEphemeralDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
  UserDefaults(suiteName: suite)!
}

/// Records the languages handed to the accepted-language owner, in order.
@MainActor
private final class AcceptedLanguages {
  var values: [String] = []
}

@MainActor
private func makePresenter(
  defaults: UserDefaults? = nil
) -> (LanguageSuggestionPresenter, FakeOverlay) {
  let (presenter, fake, _) = makePresenterRecordingAccepts(defaults: defaults)
  return (presenter, fake)
}

@MainActor
private func makePresenterRecordingAccepts(
  defaults: UserDefaults? = nil
) -> (LanguageSuggestionPresenter, FakeOverlay, AcceptedLanguages) {
  let fake = FakeOverlay()
  let accepted = AcceptedLanguages()
  let presenter = LanguageSuggestionPresenter(
    overlay: fake,
    onLanguageAccepted: { accepted.values.append($0) },
    defaults: defaults ?? makeEphemeralDefaults()
  )
  return (presenter, fake, accepted)
}

@Suite("LanguageSuggestionPresenter state machine")
@MainActor
struct LanguageSuggestionPresenterTests {

  // MARK: - bufferTrigger filtering

  @Test("bufferTrigger stores a consistentHighConfidence trigger for non-English")
  func bufferStoresValidTrigger() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
  }

  @Test("bufferTrigger drops .lidFlipFlop reason in v1")
  func bufferDropsFlipFlop() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .lidFlipFlop))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops .consecutiveLowConfidence in v1")
  func bufferDropsLowConfidence() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consecutiveLowConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops English (en) — F4 invisibility")
  func bufferDropsEnglish() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "en", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger normalizes variant codes: en-US dropped, EN_GB dropped")
  func bufferDropsEnglishVariants() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "en-US", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
    presenter.bufferTrigger(.init(lang: "EN_GB", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger drops nil lang")
  func bufferDropsNilLang() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: nil, reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("bufferTrigger latest-wins: two buffers, only last surfaces")
  func bufferLatestWins() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "fr")
  }

  // MARK: - surface guards

  @Test("F5 locked-mode guard: no chip surfaces when languageMode = .locked")
  func lockedModeBlocksSurface() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .locked("es"))
    #expect(presenter.currentChip == nil)
  }

  @Test("F14 overlay-priority guard: no chip when overlay is not .hidden")
  func overlayBusyBlocksSurface() {
    let (presenter, fake) = makePresenter()
    fake.simulateReplacement()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("clipboardFallback intent blocks chip per F14 R3 tightening")
  func clipboardFallbackBlocksSurface() {
    let (presenter, fake) = makePresenter()
    fake.slotIsFree = false
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("Buffered trigger is consumed even when surface is guarded out")
  func bufferConsumedOnGuardedSurface() {
    let (presenter, fake) = makePresenter()
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
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
  }

  @Test("Strike 2 still surfaces State A; strike 3 surfaces State B (educate)")
  func strike3IsStateB() {
    let (presenter, fake) = makePresenter()
    // Strike 1
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
    fake.pressDismiss()
    // Strike 2
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
    fake.pressDismiss()
    // Strike 3
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .educateAboutSettings)
  }

  @Test("Dismissing State B inserts language into suppression set")
  func dismissingStateBSuppresses() {
    let (presenter, fake) = makePresenter()
    // Walk to State B then dismiss it
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      fake.pressDismiss()
    }
    // Next attempt is suppressed
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  @Test("Different language clears prior suppression and counter")
  func differentLanguageReset() {
    let (presenter, fake) = makePresenter()
    // Suppress Spanish via 3 dismissals
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      fake.pressDismiss()
    }
    // French chip arrives → clears Spanish state
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "fr")
    fake.pressDismiss()  // dismiss French
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
      fake.pressDismiss()
    }
    // French chip arrives, but overlay is busy with clipboardFallback —
    // chip does NOT surface, but the different-lang reset MUST still happen.
    fake.slotIsFree = false
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)  // didn't surface
    // Now overlay is hidden. Spanish surfaces fresh (suppression cleared).
    fake.slotIsFree = true
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.lang == "es")
    #expect(presenter.currentChip?.state == .askToLock)
  }

  // MARK: - user actions

  /// **The language now travels to its OWNER instead of being returned**
  /// (#2292 C3). `accept()` handed a `String?` back to a caller that wrote the
  /// setting; the chip's Lock button is bound to the presenter directly, so the
  /// presenter calls the accepted-language owner itself. The assertion moves
  /// from a return value to what that owner received, which is the same fact
  /// observed one step further along the shipped path.
  @Test("locking hands the chip's language to its owner and clears the chip")
  func acceptReturnsLangAndClearsChip() {
    let (presenter, fake, accepted) = makePresenterRecordingAccepts()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    fake.pressLock()
    #expect(accepted.values == ["es"])
    #expect(presenter.currentChip == nil)
  }

  @Test("accept() unsuppresses + resets count for that language")
  func acceptUnsuppresses() {
    let (presenter, fake) = makePresenter()
    // Suppress Spanish
    for _ in 0..<3 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      fake.pressDismiss()
    }
    // French → Spanish reset → Spanish surfaces fresh → user accepts
    presenter.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    fake.pressDismiss()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    fake.pressLock()
    // Verify accept cleared current chip
    #expect(presenter.currentChip == nil)
  }

  @Test("autoDismiss does NOT increment dismissal count (F2)")
  func autoDismissNotAStrike() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let gen = presenter.currentChip!.generation
    fake.expire()
    // Next time should still be State A (count not incremented)
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip?.state == .askToLock)
  }

  /// **This case's SUBJECT no longer exists** (#2292 C3), so it asserts the
  /// property that replaced it rather than being deleted.
  ///
  /// It used to pass a stale generation to a public `autoDismiss(generation:)`
  /// and require no effect. Expiry now arrives through the `onExpire` callback
  /// that travelled with the chip's own request, and the director drops that
  /// binding when the presentation identity changes — so a stale timer cannot
  /// reach the presenter at all, and there is no generation to pass.
  ///
  /// What is still worth pinning is the consequence the generation guard bought:
  /// an expiry arriving after something else took the slot must not take that
  /// successor away. That is now receipt-scoped, and it is what this asserts.
  /// `languageResetDoesNotDismissSuccessorRecording` covers the same property on
  /// the reset path.
  @Test("an expiry that arrives after the slot changed hands takes nothing away")
  func expiryAfterReplacementTakesNothingAway() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    fake.simulateReplacement()
    let beforeHide = fake.hideCallCount

    fake.expire()

    #expect(
      fake.hideCallCount == beforeHide,
      "the lapsed chip's expiry dismissed the presentation that replaced it")
    #expect(
      fake.dismissAttempts.count == 1,
      "the expiry must still ASK, scoped to its own receipt — asking nothing is a different bug")
  }

  // MARK: - clear paths

  @Test("clearCurrentChip nils the visible chip")
  func clearCurrentChipWorks() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    presenter.clearCurrentChip()
    #expect(presenter.currentChip == nil)
  }

  @Test("clearBuffer drops the buffered trigger")
  func clearBufferDropsTrigger() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.clearBuffer()
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip == nil)
  }

  // MARK: - settings reset

  @Test("resetAllChipState clears in-memory state and removes UserDefaults keys")
  func resetClearsEverything() {
    let defaults = makeEphemeralDefaults()
    let (presenter, fake) = makePresenter(defaults: defaults)
    // Accumulate some state
    for _ in 0..<2 {
      presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      fake.pressDismiss()
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
    let (p1, f1) = makePresenter(defaults: defaults)
    p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    f1.pressDismiss()
    // Re-instantiate (simulates app relaunch)
    let (p2, f2) = makePresenter(defaults: defaults)
    // Dismissal count should persist → next chip is State A but count=1
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.state == .askToLock)
    f2.pressDismiss()
    // Strike 3 → State B
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.state == .educateAboutSettings)
  }

  @Test("Suppression survives presenter re-instantiation")
  func suppressionPersists() {
    let defaults = makeEphemeralDefaults()
    let (p1, f1) = makePresenter(defaults: defaults)
    for _ in 0..<3 {
      p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      f1.pressDismiss()
    }
    // Re-instantiate
    let (p2, f2) = makePresenter(defaults: defaults)
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip == nil)  // still suppressed
  }

  @Test("lastShownLanguage persists across re-instantiation (Codex P2-3 fix)")
  func lastShownPersistsAcrossRelaunch() {
    let defaults = makeEphemeralDefaults()
    let (p1, f1) = makePresenter(defaults: defaults)
    // Suppress Spanish
    for _ in 0..<3 {
      p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      f1.pressDismiss()
    }
    // Re-instantiate → different lang detected → should clear es suppression
    let (p2, f2) = makePresenter(defaults: defaults)
    p2.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p2.currentChip?.lang == "fr")
    f2.pressDismiss()
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
    let (presenter, fake) = makePresenter(defaults: defaults)
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
    let chipIntents = fake.shownChips
    #expect(chipIntents.count == 1)
    #expect(chipIntents.first?.lang == "es")
  }

  @Test("accept() pushes .hidden to overlay after returning lang")
  func acceptHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    fake.pressLock()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("dismissExplicit silently hides overlay (Codex r5 [P3])")
  func dismissHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    fake.pressDismiss()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("autoDismiss silently hides overlay when chip is still visible (Codex r4+r5)")
  func autoDismissHidesOverlay() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let beforeHide = fake.hideCallCount
    let gen = presenter.currentChip!.generation
    fake.expire()
    #expect(fake.hideCallCount > beforeHide)
  }

  @Test("autoDismiss does NOT hide when chip has been replaced (Codex r4 [P2])")
  func autoDismissDoesNotHideAfterReplacement() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let gen = presenter.currentChip!.generation
    // Simulate that recording started and replaced the overlay
    fake.simulateReplacement()
    let beforeHide = fake.hideCallCount
    fake.expire()
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
    fake.pressDismiss()  // chip cleared; persisted count=1
    fake.simulateReplacement()
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

  // MARK: - #2292 C3a: admission is the overlay's answer, not a question asked of it

  /// **A refused chip must not be recorded as shown.**
  ///
  /// The presenter used to read the overlay's current intent, decide for itself,
  /// and then commit `currentChip`, `lastShownLanguage` and a `chip_shown`
  /// breadcrumb before pushing. Committing before the answer is what made this
  /// possible; the answer is now `present` returning nil.
  ///
  /// REPRODUCIBLE: language detection completes while a recording, a processing
  /// pill or a clipboard hint owns the slot. The user sees no chip — correctly —
  /// and this pins that the presenter agrees with what is on screen.
  @Test("a refused chip commits no shown state")
  func refusedLanguageDoesNotCommitShownState() {
    let (presenter, fake) = makePresenter()
    fake.slotIsFree = false
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))

    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)

    #expect(fake.shownChips.count == 1, "control: the request must still have been ATTEMPTED")
    #expect(presenter.currentChip == nil, "a refused chip was recorded as the current chip")
  }

  /// **The previous-language reset survives a refusal, and that is deliberate.**
  ///
  /// Its effect is about the language the user has NOW dictated, not about this
  /// chip: dictating French clears a Spanish suppression whether or not the
  /// French chip gets a slot. Losing it on refusal would leave Spanish
  /// suppressed forever for a user who keeps switching language mid-recording.
  ///
  /// REPRODUCIBLE: suppress Spanish, then dictate French while the slot is busy,
  /// then dictate Spanish with the slot free. Spanish must surface.
  /// **Crosses a relaunch on purpose, because the in-memory version of this
  /// case cannot fail.** The reset mutates `suppressedLanguages` in memory
  /// whether or not `persistState()` runs, so a single-instance test passes with
  /// the refusal branch's persist deleted — it would assert nothing. Only a
  /// second presenter reading the same defaults can tell a reset that SURVIVED
  /// from one that merely happened.
  @Test("a different language clears the old suppression even when the chip is refused")
  func differentLanguageResetPersistsAcrossRefusal() {
    let defaults = makeEphemeralDefaults()
    let (p1, f1) = makePresenter(defaults: defaults)
    for _ in 0..<3 {
      p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
      p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
      f1.pressDismiss()
    }
    p1.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p1.currentChip == nil, "control: Spanish must be suppressed before we start")

    // French arrives while something else owns the slot. The chip is refused;
    // the previous-language reset must still be written down.
    f1.slotIsFree = false
    p1.bufferTrigger(.init(lang: "fr", reason: .consistentHighConfidence))
    p1.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(p1.currentChip == nil, "control: the French chip must have been refused")

    // Relaunch. Only what was persisted survives.
    let (p2, _) = makePresenter(defaults: defaults)
    p2.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    p2.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)

    #expect(
      p2.currentChip?.lang == "es",
      "the refusal swallowed the previous-language reset, so Spanish stayed suppressed")
  }

  /// **A refused chip stops claiming it was shown in the diagnostic trail.**
  ///
  /// NOT user-facing, and it is a Sentry breadcrumb rather than a PostHog event
  /// — no dashboard number moves. What it costs when wrong is an investigation:
  /// a trail saying `chip_shown` for a chip nobody could have seen sends the
  /// next reader looking for a rendering bug that does not exist.
  ///
  /// Synchronous install-fire-restore with no `await`, which is the shape
  /// `swift-patterns.md` RULE: tests-no-process-global-mutable-delegate permits
  /// for a process-global delegate.
  @Test("a refused chip emits no chip_shown breadcrumb")
  func refusedLanguageDoesNotEmitChipShown() {
    let (presenter, fake) = makePresenter()
    let box = BreadcrumbBox()
    SentryBreadcrumb.breadcrumbDelegate = { stage, message, _, _ in
      box.append(stage: stage, message: message)
    }
    defer { SentryBreadcrumb.breadcrumbDelegate = nil }

    fake.slotIsFree = false
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    let afterRefusal = box.messages

    fake.slotIsFree = true
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)

    #expect(
      !afterRefusal.contains("chip_shown"),
      "a chip nobody could see was recorded as shown")
    #expect(
      box.messages.contains("chip_shown"),
      "control: an ACCEPTED chip must still emit it, or this case proves nothing")
  }

  /// **A Settings reset must not take away whatever replaced the chip.**
  ///
  /// REPRODUCIBLE: a chip is up, a recording starts and replaces it, and the
  /// user opens Settings and resets language suggestions. The recording pill
  /// must survive. The old form asked this presenter's own remembered flag and
  /// then re-read the overlay's intent; the receipt answers both at once and is
  /// owned by the party that knows.
  @Test("resetting chip state does not dismiss the presentation that replaced the chip")
  func languageResetDoesNotDismissSuccessorRecording() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    fake.simulateReplacement()
    let beforeHide = fake.hideCallCount

    presenter.resetAllChipState()

    #expect(
      fake.hideCallCount == beforeHide,
      "the reset dismissed the presentation that had replaced the chip")
    #expect(
      fake.unconditionalDismissals == 0,
      "the reset dismissed unconditionally instead of naming its own receipt")
  }

  /// **Lock dismisses the chip BEFORE handing the language to its owner.**
  ///
  /// Plan §5 requires the sequence `clear state -> silent receipt dismissal ->
  /// read prior mode -> mutate -> telemetry`. This pins the part this presenter
  /// owns: the dismissal happens BEFORE the language reaches its owner. Handing
  /// over first would let the owner read a language mode this call is about to
  /// change, so every chip-driven lock would report the user moving from the
  /// language they moved TO.
  ///
  /// **The owner's own half is NOT covered, and no test here can cover it.**
  /// `TelemetryService.trackManualLockUsed` calls PostHog directly and exposes
  /// no observation seam, so whether `OverlayChipWiring.acceptedLanguage` reads
  /// the prior mode before or after mutating is unobservable — both orders leave
  /// the same setting and differ only in an event nothing can see. Recorded as a
  /// known gap rather than covered by a case that cannot fail; closing it needs
  /// a production seam, which is a decision for the supervisor rather than a
  /// change smuggled in beside a test.
  @Test("locking dismisses the chip before the language reaches its owner")
  func manualLockDismissesFirstAndTracksPriorMode() {
    let fake = FakeOverlay()
    let hidesWhenAccepted = HideCountBox()
    let presenter = LanguageSuggestionPresenter(
      overlay: fake,
      onLanguageAccepted: { _ in hidesWhenAccepted.value = fake.hideCallCount },
      defaults: makeEphemeralDefaults()
    )
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(fake.hideCallCount == 0, "control: nothing is dismissed before Lock")

    fake.pressLock()

    #expect(
      hidesWhenAccepted.value == 1,
      "the language reached its owner before the chip was dismissed")
    #expect(presenter.currentChip == nil)
  }

  /// **An expiry clears the presenter and is NOT a strike.**
  ///
  /// Per the F2 council resolution, a user not looking is not a user rejecting,
  /// so the next chip for the same language must still be State A. REPRODUCIBLE:
  /// a user who ignores three chips must not have that language suppressed.
  ///
  /// Also pins that the expiry ARRIVES at all — dropping `onExpire` from the
  /// request leaves a chip that lapses on screen but never in the presenter.
  @Test("an expiry clears the presenter without adding a strike")
  func languageExpiryClearsPresenterWithoutAddingAStrike() {
    let (presenter, fake) = makePresenter()
    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(presenter.currentChip != nil, "control: a chip must be showing")

    fake.expire()

    #expect(presenter.currentChip == nil, "the expiry never reached the presenter")
    #expect(fake.hideCallCount == 1, "the lapsed chip was not taken off screen")

    presenter.bufferTrigger(.init(lang: "es", reason: .consistentHighConfidence))
    presenter.surfaceBufferedChipIfPossible(currentLanguageMode: .auto)
    #expect(
      presenter.currentChip?.state == .askToLock,
      "the expiry counted as a dismissal strike")
  }

  // MARK: - normalization helper

  @Test("normalizedBase strips variant suffix and lowercases")
  func normalizationHelper() {
    let (presenter, fake) = makePresenter()
    #expect(presenter.normalizedBase("en-US") == "en")
    #expect(presenter.normalizedBase("EN_GB") == "en")
    #expect(presenter.normalizedBase("Es") == "es")
    #expect(presenter.normalizedBase("pt_BR") == "pt")
    #expect(presenter.normalizedBase("fr") == "fr")
  }
}
