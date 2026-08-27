import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #1914: eviction is suppressed for models the Ollama daemon proxies to its
/// own servers, and for nothing else.
///
/// Why the observation point is a scheduling seam rather than the connector's
/// network seam: suppression happens BEFORE any connector exists, so
/// `OllamaConnector.networkExecutor` sits downstream of the gate and can never
/// see a request that was never scheduled. `evictionScheduler` observes the one
/// call site that produces the network path at all.
///
/// The positive controls matter as much as the suppression tests. An
/// implementation that skipped EVERYTHING would satisfy every zero-eviction
/// assertion here while silently disabling the #286 VRAM unload, so local and
/// unknown models each have their own must-evict test.
@MainActor
@Suite("PipelineSettingsSync Ollama eviction suppression (#1914)")
struct PipelineSettingsSyncOllamaEvictionTests {

  // MARK: - Fixture

  /// Records every model the sync home actually scheduled for eviction.
  private final class EvictionRecorder {
    private(set) var scheduled: [String] = []
    func record(_ model: String) { scheduled.append(model) }
  }

  private func catalogRow(_ name: String, isRemote: Bool) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: name,
      canonicalName: OllamaSetupService.canonicalModelName(name),
      parameterSize: "4B",
      parameterBillions: 4,
      fileSizeBytes: 2_900_000_000,
      displayName: name,
      facts: OllamaModelFacts(isRemote: isRemote, thinks: false)
    )
  }

  /// Builds a real `PipelineSettingsSync`, wired to the PRODUCTION lookup
  /// helper over a fixture catalog. The lookup is deliberately not a
  /// test-written predicate: a hand-rolled matcher would prove only that the
  /// copy works, and canonical matching is exactly where a copy would drift.
  private func makeSync(
    catalog: [OllamaDownloadedModel],
    lookupCounter: (() -> Void)? = nil
  ) -> (PipelineSettingsSync, SettingsManager, EvictionRecorder) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager(
      defaults: UserDefaults(suiteName: "SM-1914-evict-\(UUID().uuidString)")!)
    let recorder = EvictionRecorder()

    let sync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKit,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
      ollamaRemotenessLookup: { model in
        lookupCounter?()
        return PipelineSettingsSync.ollamaRemoteness(of: model, in: catalog)
      }
    )
    sync.evictionScheduler = { recorder.record($0) }
    return (sync, settings, recorder)
  }

  /// Arms `first`, seeds the tracker, then switches to `second`.
  private func swap(
    from first: String, to second: String,
    catalog: [OllamaDownloadedModel],
    lookupCounter: (() -> Void)? = nil
  ) -> EvictionRecorder {
    let (sync, settings, recorder) = makeSync(catalog: catalog, lookupCounter: lookupCounter)
    settings.llmProvider = .ollama
    settings.ollamaModel = first
    sync.applyInitialSettings(settings)
    #expect(recorder.scheduled.isEmpty, "seeding must never evict")

    settings.ollamaModel = second
    sync.handleSettingChanged(.ollamaModel, settings: settings)
    return recorder
  }

  // MARK: - Suppression

  @Test("switching away from a PROVEN REMOTE model schedules zero evictions")
  func remotePreviousIsSuppressed() {
    let recorder = swap(
      from: "gpt-oss:120b-cloud", to: "mistral",
      catalog: [
        catalogRow("gpt-oss:120b-cloud", isRemote: true),
        catalogRow("mistral", isRemote: false),
      ])
    #expect(recorder.scheduled.isEmpty)
  }

  /// The skip must ADVANCE the tracker, not defer. Leaving it pinned at the
  /// remote name would re-ask the same question on every later settings change
  /// and could evict it later from a different path.
  @Test("a remote skip advances the tracker, so a second reconcile asks nothing more")
  func remoteSkipAdvancesTracker() {
    var lookups = 0
    let catalog = [
      catalogRow("gpt-oss:120b-cloud", isRemote: true),
      catalogRow("mistral", isRemote: false),
    ]
    let (sync, settings, recorder) = makeSync(catalog: catalog, lookupCounter: { lookups += 1 })
    settings.llmProvider = .ollama
    settings.ollamaModel = "gpt-oss:120b-cloud"
    sync.applyInitialSettings(settings)

    settings.ollamaModel = "mistral"
    sync.handleSettingChanged(.ollamaModel, settings: settings)
    let afterFirst = lookups
    #expect(recorder.scheduled.isEmpty)

    // Same value again: `pre == new` now, so the guard returns before any
    // lookup. If the tracker had NOT advanced, `pre` would still be the remote
    // name and this would look the model up again.
    sync.handleSettingChanged(.ollamaModel, settings: settings)
    #expect(lookups == afterFirst, "the tracker did not advance past the skipped remote model")
    #expect(recorder.scheduled.isEmpty)
  }

  // MARK: - Positive controls (an implementation that skips everything fails these)

  @Test("a PROVEN LOCAL previous model still schedules exactly one eviction")
  func localPreviousStillEvicts() {
    let recorder = swap(
      from: "llama3.2", to: "mistral",
      catalog: [
        catalogRow("llama3.2", isRemote: false),
        catalogRow("mistral", isRemote: false),
      ])
    #expect(recorder.scheduled == ["llama3.2"])
  }

  /// Unknown is fail-OPEN, and deliberately the opposite default from warm-up.
  /// A model absent from the catalog may well be resident in local VRAM, and
  /// leaving it there is the #286 Bluetooth-audio regression. One needless
  /// local request is the cheaper mistake.
  @Test("an UNKNOWN previous model still schedules exactly one eviction")
  func unknownPreviousStillEvicts() {
    let recorder = swap(from: "not-in-catalog", to: "mistral", catalog: [])
    #expect(recorder.scheduled == ["not-in-catalog"])
  }

  // MARK: - The lookup must ask about the PREVIOUS model

  /// The decision is about what is being unloaded, never what is being armed.
  /// Asking about `new` would suppress eviction of a real local model whenever
  /// the user switched TO a cloud one, leaving it resident.
  @Test("a local previous model is evicted even when the NEW model is remote")
  func localPreviousEvictedWhenNewIsRemote() {
    let recorder = swap(
      from: "llama3.2", to: "gpt-oss:120b-cloud",
      catalog: [
        catalogRow("llama3.2", isRemote: false),
        catalogRow("gpt-oss:120b-cloud", isRemote: true),
      ])
    #expect(recorder.scheduled == ["llama3.2"])
  }

  // MARK: - No-op paths

  @Test("initial seeding performs no eviction")
  func seedingDoesNotEvict() {
    let (sync, settings, recorder) = makeSync(
      catalog: [catalogRow("llama3.2", isRemote: false)])
    settings.llmProvider = .ollama
    settings.ollamaModel = "llama3.2"
    sync.applyInitialSettings(settings)
    #expect(recorder.scheduled.isEmpty)
  }

  @Test("selecting the same effective model performs no eviction")
  func sameModelDoesNotEvict() {
    let recorder = swap(
      from: "llama3.2", to: "llama3.2",
      catalog: [catalogRow("llama3.2", isRemote: false)])
    #expect(recorder.scheduled.isEmpty)
  }

  // MARK: - The pure lookup itself

  @Test("canonical matching treats name and name:latest as one model")
  func canonicalMatching() {
    let catalog = [catalogRow("llama3.2:latest", isRemote: false)]
    #expect(PipelineSettingsSync.ollamaRemoteness(of: "llama3.2", in: catalog) == false)
    #expect(PipelineSettingsSync.ollamaRemoteness(of: "llama3.2:latest", in: catalog) == false)

    let remoteCatalog = [catalogRow("deepseek-v4-flash", isRemote: true)]
    #expect(
      PipelineSettingsSync.ollamaRemoteness(of: "deepseek-v4-flash:latest", in: remoteCatalog)
        == true)
  }

  /// `nil` is a THIRD answer, not a synonym for local. The callers branch on
  /// `== true` precisely so this stays distinguishable.
  @Test("an absent model returns nil, distinct from a proven-local false")
  func absentReturnsNil() {
    #expect(PipelineSettingsSync.ollamaRemoteness(of: "anything", in: []) == nil)
    #expect(
      PipelineSettingsSync.ollamaRemoteness(
        of: "absent", in: [catalogRow("present", isRemote: false)]) == nil)
    #expect(
      PipelineSettingsSync.ollamaRemoteness(
        of: "present", in: [catalogRow("present", isRemote: false)]) == false)
  }

  // MARK: - The production wiring

  /// The composition root passes `liveOllamaRemotenessLookup(setup.ollamaSetup)`,
  /// so this is the link between the live catalog and the decision.
  ///
  /// SCOPE, stated because the obvious reading overclaims it: this proves the
  /// closure reaches a real `OllamaSetupService` and answers `nil` — the
  /// fail-open direction — for a catalog that has not been populated yet, which
  /// is exactly the app's state before the first `/api/tags` refresh.
  ///
  /// The POPULATED case is covered separately below. Keeping both is the point:
  /// an empty catalog is the app's real state before the first `/api/tags`
  /// refresh, and answering `nil` there is what keeps eviction working.
  @Test("the production lookup reaches a live setup service and fails open when empty")
  func productionLookupFailsOpenOnEmptyCatalog() {
    let service = OllamaSetupService()
    let lookup = PipelineSettingsSync.liveOllamaRemotenessLookup(service)

    #expect(service.downloadedModels.isEmpty, "fixture premise: a fresh service has no rows")
    #expect(lookup("llama3.2") == nil)
    #expect(lookup("gpt-oss:120b-cloud") == nil, "an unrefreshed catalog cannot prove remoteness")
  }

  /// The link the empty-catalog test above CANNOT reach: real facts, in a real
  /// service, arriving at the decision.
  ///
  /// This exists because a mutation replacing `ollamaSetup.downloadedModels`
  /// with `[]` left every other test green — the gap was measured, not assumed,
  /// and closing it needed the `downloadedModelsForTesting` seam.
  @Test("the production lookup reads remoteness from a POPULATED live catalog")
  func productionLookupReadsPopulatedCatalog() {
    let service = OllamaSetupService(
      downloadedModelsForTesting: [
        catalogRow("deepseek-v4-flash:latest", isRemote: true),
        catalogRow("llama3.2:latest", isRemote: false),
      ])
    let lookup = PipelineSettingsSync.liveOllamaRemotenessLookup(service)

    // Canonical matching survives the trip through the live service, and the
    // remote row carries no `-cloud` suffix — the production shape.
    #expect(lookup("deepseek-v4-flash") == true)
    #expect(lookup("llama3.2") == false)
    #expect(lookup("absent") == nil)
  }

  /// Remoteness comes from the row's decoded facts, never from the NAME. A
  /// `-cloud` suffix is explicitly rejected as a classifier (plan §3 Decision
  /// 1) because the one production case, `deepseek-v4-flash:latest`, has none.
  @Test("a name that LOOKS local is remote when the catalog says so, and the reverse")
  func nameIsNeverTheClassifier() {
    #expect(
      PipelineSettingsSync.ollamaRemoteness(
        of: "deepseek-v4-flash:latest",
        in: [catalogRow("deepseek-v4-flash:latest", isRemote: true)]) == true,
      "a hosted model with no -cloud suffix must still read as remote")
    #expect(
      PipelineSettingsSync.ollamaRemoteness(
        of: "my-cloud-notes:7b",
        in: [catalogRow("my-cloud-notes:7b", isRemote: false)]) == false,
      "a LOCAL model whose name contains 'cloud' must not read as remote")
  }
}
