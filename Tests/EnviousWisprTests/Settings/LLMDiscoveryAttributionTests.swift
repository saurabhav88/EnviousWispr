import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2772 chunk 3 — the published discovery state must never describe a provider it is not
/// about.
///
/// **One coordinator now serves two screens.** Dictation's polisher and the file import's
/// can be different engines, so `discoveredModels` and `keyValidationState` acquired an
/// owner (`stateProvider`) and the Transcribe a File gate reads them only when that owner
/// matches. Three review rounds found three ways the label and the labelled could come
/// apart: a stale async completion publishing over a newer request, a request ENTRY moving
/// the owner while the previous catalog was still published, and an invalidated request
/// leaving a pending verdict nobody could ever resolve.
///
/// The last two are synchronous, so no generation counter reaches them. They are closed by
/// `stateProvider`'s `didSet` and by `invalidateInFlightDiscovery`, and these rows hold
/// those two invariants at the public paths that trigger them.
///
/// Product coverage: the failure a person sees is one engine's models listed under another
/// engine's name, or a Continue button stuck on "Checking that engine" forever.
@MainActor
@Suite("Discovery state attribution (#2772)", .tags(.productOutcome))
struct LLMDiscoveryAttributionTests {
  /// A model cache nobody else is writing to.
  ///
  /// The shared preference store on this machine already holds a real OpenAI catalog, so
  /// "loading OpenAI's cache leaves the list empty" would have been a claim about what
  /// happens to be on disk. Found by Codex, which also named the limit these rows do NOT
  /// reach: they drive the SYNCHRONOUS public transitions, never two overlapping async
  /// requests, so the late-completion half of the class rests on the guarded writers rather
  /// than on this suite.
  private static func coordinator() -> LLMModelDiscoveryCoordinator {
    let defaults = UserDefaults(
      suiteName: "ew.tests.discovery-attribution.\(UUID().uuidString)")!
    return LLMModelDiscoveryCoordinator(
      keychainManager: KeychainManager(), cacheDefaults: defaults)
  }

  private static func row(_ id: String, provider: LLMProvider) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: id, provider: provider, isAvailable: true, isRemote: false)
  }

  /// The owner change is the moment the old answers stop being true, and it is the ONLY
  /// moment: nothing else may need to remember to clear them.
  @Test("taking a new owner drops the previous owner's models and verdict")
  func aNewOwnerLabelsNothing() {
    let c = Self.coordinator()
    c.loadCachedModels(for: .gemini)
    c.discoveredModels = [Self.row("gemini-3-flash", provider: .gemini)]
    c.keyValidationState = .valid

    c.loadCachedModels(for: .openAI)

    #expect(c.stateProvider == .openAI)
    #expect(c.discoveredModels.isEmpty, "Gemini's catalog is sitting under OpenAI's name")
    #expect(
      c.keyValidationState == .idle,
      "Gemini's key verdict is being read as OpenAI's")
  }

  /// The other direction, so a rule that cleared on EVERY load would fail here. A refresh of
  /// the same provider must leave what is on screen alone.
  @Test("re-loading the same owner keeps a verdict it already reached")
  func aSameProviderReloadKeepsItsVerdict() {
    let c = Self.coordinator()
    c.loadCachedModels(for: .openAI)
    c.keyValidationState = .valid

    c.loadCachedModels(for: .openAI)

    #expect(c.keyValidationState == .valid, "a completed verdict was discarded by a refresh")
  }

  /// A pending verdict belongs to a request. Dismiss the request and the verdict has no
  /// author left, so leaving it standing means the gate says "Checking that engine" with
  /// nothing in flight that could ever finish.
  @Test("dismissing a request in flight also drops the verdict it was going to reach")
  func aDismissedRequestLeavesNoPendingVerdict() {
    let c = Self.coordinator()
    c.loadCachedModels(for: .openAI)
    c.keyValidationState = .validating
    c.isDiscoveringModels = true

    // Same provider, so the owner does NOT change: this is the case a rule keyed on the
    // owner alone cannot see.
    c.loadCachedModels(for: .openAI)

    #expect(c.keyValidationState == .idle, "the gate is stuck on Checking with nothing running")
    #expect(!c.isDiscoveringModels, "the spinner outlived the request that raised it")
  }

  @Test("reset leaves no owner and nothing labelled")
  func resetClearsEverything() {
    let c = Self.coordinator()
    c.loadCachedModels(for: .claude)
    c.discoveredModels = [Self.row("claude-haiku-4-5", provider: .claude)]
    c.keyValidationState = .validating
    c.isDiscoveringModels = true

    c.reset()

    #expect(c.stateProvider == nil)
    #expect(c.discoveredModels.isEmpty)
    #expect(c.keyValidationState == .idle)
    #expect(!c.isDiscoveringModels)
  }
}
