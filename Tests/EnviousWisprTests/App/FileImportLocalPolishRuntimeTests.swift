import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #2772 chunk 2 — the file import owns a bundled polish server for the length of its run.
///
/// **Why these are runtime rows and not settings rows.** Chunk-2 review round 1 rejected a
/// Boolean-helper assertion for exactly this: asking a predicate whether an engine "counts
/// as selected" is not the same as the engine being started, protected, and handed back.
/// The two failures these pin are both silent — the user sees an import that came back
/// uncleaned, or a dictation that stopped being polished, with nothing on screen either way.
///
/// **What these rows are, and what they are NOT.** The observable is the coordinator's
/// intent stamp, and with no manifest and no binary `activateAndProbe` returns before
/// claiming one — so every stamp counted here is a STOP. That makes these DEFERRAL tests:
/// they establish that reconciliation is entered, or correctly deferred, and nothing more.
///
/// They do NOT establish that the import's polisher actually STARTED, that it was ready
/// when the first part was polished, or that dictation's engine was restored afterwards.
/// `forced > 0` below would still pass against a restoration that stops EG-1 and never
/// starts S1-mini. A stamp count is a PROXY for the runtime outcome, and chunk-2 review
/// round 3 ruled — correctly, after three rounds on this same class — that the proxy must
/// not be extended a fourth time to carry that weight.
///
/// The startup and restoration outcome is established by LIVE UAT against the real app
/// with both bundled models installed, attributing each polish request to the runtime that
/// served it rather than to the card the user clicked. See the chunk-2 UAT record.
@MainActor
@Suite("File-import local polish runtime (#2772)", .tags(.productOutcome))
struct FileImportLocalPolishRuntimeTests {

  private func makeSync(
    importPin: @escaping @MainActor () -> LLMProvider?
  ) -> (PipelineSettingsSync, SettingsManager, LocalPolishServerCoordinator) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager(
      defaults: UserDefaults(suiteName: "SM-2772-runtime-\(UUID().uuidString)")!)
    let coordinator = LocalPolishServerCoordinator()
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
      provider: .egOne)
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
      provider: .s1Mini)
    let sync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKit,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
      egOneRuntime: egOne,
      s1MiniRuntime: s1Mini,
      ollamaRemotenessLookup: { _ in nil },
      importPinnedLocalProvider: importPin
    )
    return (sync, settings, coordinator)
  }

  private func stampsClaimed(
    by body: () -> Void, on coordinator: LocalPolishServerCoordinator
  ) -> Int {
    let before = coordinator.claimIntent()
    body()
    let after = coordinator.claimIntent()
    return after - before - 1
  }

  /// An import holding EG-1 must not have it stopped underneath by a dictation change.
  /// Stopping it mid-run degrades that import's polish to raw, which is the same cost
  /// #2649 records for a dictation session.
  @Test("a dictation switch does not stop the engine an import is holding")
  func aDictationSwitchDoesNotStopThePinnedImportEngine() {
    let (sync, settings, coordinator) = makeSync(importPin: { .egOne })
    settings.llmProvider = .s1Mini

    let stamps = stampsClaimed(
      by: { sync.handleSettingChanged(.llmProvider, settings: settings) },
      on: coordinator)

    #expect(
      stamps == 0,
      "the pin must defer the whole reconciliation, claimed \(stamps) stamps instead")
  }

  /// The inverse, and the one that makes the row above meaningful: with NO import holding
  /// anything, the same change does reconcile. Without this the row above would pass
  /// against a reconciler that never does anything at all.
  @Test("with no import holding it, the same switch does reconcile")
  func withoutAPinTheSwitchReconciles() {
    let (sync, settings, coordinator) = makeSync(importPin: { nil })
    settings.llmProvider = .s1Mini

    let stamps = stampsClaimed(
      by: { sync.handleSettingChanged(.llmProvider, settings: settings) },
      on: coordinator)

    #expect(stamps > 0, "an unpinned switch must reconcile, claimed \(stamps) stamps")
  }

  /// #2772 chunk-2 review round 2, blocking finding 1. An import that runs start to finish
  /// with no settings change arms nothing, so the unforced release path returned without
  /// reconciling and the import's engine stayed resident in place of dictation's.
  @Test("releasing the engine reconciles back even when nothing was deferred")
  func releaseReconcilesWithoutAPendingFlag() {
    let (sync, settings, coordinator) = makeSync(importPin: { nil })
    settings.llmProvider = .s1Mini

    let unforced = stampsClaimed(
      by: { sync.retryDeferredEGOneDeactivation(settings: settings) },
      on: coordinator)
    #expect(
      unforced == 0,
      "nothing was deferred, so the unforced path is correctly a no-op")

    let forced = stampsClaimed(
      by: {
        sync.retryDeferredEGOneDeactivation(settings: settings, forceReconciliation: true)
      },
      on: coordinator)
    #expect(
      forced > 0,
      "the release must reconcile back to dictation's engine, claimed \(forced) stamps")
  }

  /// Forcing must not override the pin: a release that arrives while ANOTHER import still
  /// holds an engine has to stay off it.
  @Test("forcing does not override a live pin")
  func forcingRespectsThePin() {
    let (sync, settings, coordinator) = makeSync(importPin: { .egOne })
    settings.llmProvider = .s1Mini

    let forced = stampsClaimed(
      by: {
        sync.retryDeferredEGOneDeactivation(settings: settings, forceReconciliation: true)
      },
      on: coordinator)
    #expect(forced == 0, "a live pin outranks the force, claimed \(forced) stamps")
  }
}
