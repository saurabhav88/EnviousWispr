import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Which real runtime entry points put the word check in memory (#3289). When this fails, a Mac
/// loads about 500 MB at launch, after a settings change, after setup or when the model finishes
/// downloading, with nobody dictating (Sentry ENVIOUSWISPR-5Y); or an Apple Intelligence user's
/// dictation starts without loading the check it needs. The policy table alone does not bind its
/// callers; these tests drive the runtime itself and count the load tasks it creates.
@MainActor
@Suite(
  "WordCheckRuntime: background triggers never load, work does (#3289)", .tags(.productOutcome))
struct WordCheckRuntimeResidencyTests {
  /// The runtime's inputs, changeable mid-test so a trigger can be isolated from admission.
  @MainActor final class Inputs {
    var dictionary = true
    var needed = true
    var onboarding = true
    var statusChanges = 0
  }

  private static let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/EnviousWispr/Resources")

  /// A runtime over a real `ModelDeliveryHome` in a temp folder (as `LearnedWordCheckerEligibilityTests`
  /// builds it). No model files exist there, so any load that starts fails at once; the tests count
  /// load tasks created, which is the decision under test.
  private func makeRuntime() throws -> (WordCheckRuntime, Inputs) {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-3289-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let flags = try #require(UserDefaults(suiteName: "ew-3289-\(UUID().uuidString)"))
    let delivery = ModelDeliveryHome(
      engineMutationScope: .live(tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try #require(Bundle(url: Self.resources)), appSupportOverride: temp,
      deliveryFlagDefaults: flags)
    #expect(delivery.wordCheckHandle != nil, "fixture: the word check registration must exist")
    let inputs = Inputs()
    let runtime = WordCheckRuntime(
      delivery: delivery,
      isDictionaryEnabled: { inputs.dictionary },
      someEngineLacksOwnChecker: { inputs.needed },
      isOnboardingComplete: { inputs.onboarding })
    runtime.onStatusChange = { inputs.statusChanges += 1 }
    return (runtime, inputs)
  }

  /// Admitted on disk, but reached while nothing wanted it, so admission itself loads nothing on
  /// either side of the fix; the trigger under test is then the only thing that could load.
  private func admittedIdle() throws -> (WordCheckRuntime, Inputs) {
    let (runtime, inputs) = try makeRuntime()
    inputs.needed = false
    runtime.deliveryStateChangedForTests(.admitted)
    inputs.needed = true
    #expect(runtime.loadAttemptsForTests == 0, "fixture: admission while unwanted loads nothing")
    return (runtime, inputs)
  }

  /// Every trigger, work ones included: `refresh` decides the download and unloads, and never
  /// loads (#3289); only the work entry points load.
  @Test(
    "an admitted refresh loads nothing, whatever the trigger",
    arguments: WordCheckResidencyPolicy.Trigger.allCases)
  func backgroundRefreshLoadsNothing(trigger: WordCheckResidencyPolicy.Trigger) throws {
    let (runtime, inputs) = try admittedIdle()
    let before = inputs.statusChanges
    runtime.refresh(trigger: trigger)
    #expect(runtime.loadAttemptsForTests == 0, "\(trigger) created a load task")
    #expect(inputs.statusChanges > before, "an admitted refresh still updates the Dictionary row")
  }

  @Test("the model finishing its download while wanted loads nothing when no work needs it")
  func admissionLoadsNothing() throws {
    let (runtime, _) = try makeRuntime()
    runtime.deliveryStateChangedForTests(.admitted)
    #expect(runtime.loadAttemptsForTests == 0)
  }

  /// A dictation or import that started while the model was still downloading could not preload
  /// it; the download finishing during that work loads it once.
  @Test("the model finishing its download during work that needs it loads it")
  func admissionDuringWorkLoads() throws {
    let (runtime, _) = try makeRuntime()
    runtime.inFlightWorkNeedsWordCheck = { true }
    runtime.deliveryStateChangedForTests(.admitted)
    #expect(runtime.loadAttemptsForTests == 1)
  }

  /// A recovery that started while the model was still downloading could not preload it; the
  /// download finishing before the replay ends loads it, and not after the replay has ended.
  @Test("the model finishing its download during a recovery that needs it loads it")
  func admissionDuringRecoveryLoads() throws {
    let (during, _) = try makeRuntime()
    during.recoveryStarted(needsWordCheck: true)  // not admitted yet: nothing to load
    #expect(during.loadAttemptsForTests == 0)
    during.deliveryStateChangedForTests(.admitted)
    #expect(during.loadAttemptsForTests == 1)
    let (after, _) = try makeRuntime()
    after.recoveryStarted(needsWordCheck: true)
    after.recoveryFinished(needsWordCheck: true)
    after.deliveryStateChangedForTests(.admitted)
    #expect(after.loadAttemptsForTests == 0, "loaded for a recovery that had already ended")
  }

  @Test("a crash-recovery replay loads for an engine without its own check, never for EG-1")
  func recoveryStart() throws {
    let (withCheck, _) = try admittedIdle()
    withCheck.recoveryStarted(needsWordCheck: true)
    #expect(withCheck.loadAttemptsForTests == 1)
    let (ownCheck, _) = try admittedIdle()
    ownCheck.recoveryStarted(needsWordCheck: LearnedWordCheckerEngine(provider: .egOne) == nil)
    #expect(ownCheck.loadAttemptsForTests == 0)
  }

  /// The bootstrapper passes `LearnedWordCheckerEngine(provider:) == nil` for the take's frozen
  /// provider (`WisprBootstrapper` `onRecordingStarted`); the same expression decides here.
  @Test(
    "record start loads for an engine without its own check, never for EG-1 or S1-mini",
    arguments: [
      (LLMProvider.appleIntelligence, 1), (.egOne, 0), (.s1Mini, 0),
    ])
  func recordStart(provider: LLMProvider, loads: Int) throws {
    let (runtime, _) = try admittedIdle()
    runtime.recordingStarted(
      needsWordCheckForRecording: LearnedWordCheckerEngine(provider: provider) == nil)
    #expect(runtime.loadAttemptsForTests == loads, "\(provider)")
  }

  @Test("a file import start loads for an engine without its own check, never for EG-1")
  func fileImportStart() throws {
    let (withCheck, _) = try admittedIdle()
    withCheck.fileImportStarted(needsWordCheck: true)
    #expect(withCheck.loadAttemptsForTests == 1)
    let (ownCheck, _) = try admittedIdle()
    ownCheck.fileImportStarted(needsWordCheck: LearnedWordCheckerEngine(provider: .egOne) == nil)
    #expect(ownCheck.loadAttemptsForTests == 0)
  }

  @Test("record start loads nothing while the Dictionary is off")
  func recordStartDictionaryOff() throws {
    let (runtime, inputs) = try admittedIdle()
    inputs.dictionary = false
    runtime.recordingStarted(needsWordCheckForRecording: true)
    #expect(runtime.loadAttemptsForTests == 0)
  }

  @Test("Try again and a take's selection still load")
  func workStillLoads() async throws {
    let (retry, _) = try admittedIdle()
    retry.retryDownload()
    #expect(retry.loadAttemptsForTests == 1)
    let (take, _) = try admittedIdle()
    _ = await take.selection()
    #expect(take.loadAttemptsForTests == 1)
  }

  // MARK: - #3289: work in flight, dictation or an engine-held import

  @Test("the idle timer defers under work in flight and keeps a model a take is waiting on")
  func idleExpiry() {
    #expect(WordCheckRuntime.idleExpiry(activeSelections: 0, workNeedsCheck: false) == .release)
    #expect(WordCheckRuntime.idleExpiry(activeSelections: 0, workNeedsCheck: true) == .reschedule)
    #expect(WordCheckRuntime.idleExpiry(activeSelections: 1, workNeedsCheck: false) == .keep)
    #expect(WordCheckRuntime.idleExpiry(activeSelections: 1, workNeedsCheck: true) == .keep)
  }

  @Test("a held import keeps needing the check its frozen engine selects, whatever the settings say")
  func importNeedIsFrozen() {
    let need = WordCheckRuntime.workNeedsWordCheck
    #expect(need([], true, .appleIntelligence), "a held Apple Intelligence import needs the check")
    #expect(need([], true, .openAI), "a held cloud import needs the check")
    #expect(need([], false, .appleIntelligence) == false, "a finished import needs nothing")
    #expect(need([], true, .egOne) == false, "an EG-1 import uses its own check")
    #expect(need([], true, nil) == false, "an import never frozen needs nothing")
    #expect(need([.appleIntelligence], false, nil), "a dictation's own need still counts")
    #expect(need([.s1Mini, .egOne], false, nil) == false)
  }

  @Test("a file import start still loads after the settings stop needing the check, while the held run does")
  func fileImportStartUsesFrozenNeed() throws {
    let (runtime, inputs) = try admittedIdle()
    inputs.needed = false
    runtime.inFlightWorkNeedsWordCheck = { true }
    runtime.fileImportStarted(needsWordCheck: true)
    #expect(runtime.loadAttemptsForTests == 1)
    let (unheld, unheldInputs) = try admittedIdle()
    unheldInputs.needed = false
    unheld.fileImportStarted(needsWordCheck: true)
    #expect(unheld.loadAttemptsForTests == 0, "nothing in flight and nothing chosen needs it")
  }
}
