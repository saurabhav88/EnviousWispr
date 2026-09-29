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

  @Test("the model finishing its download while wanted loads nothing")
  func admissionLoadsNothing() throws {
    let (runtime, _) = try makeRuntime()
    runtime.deliveryStateChangedForTests(.admitted)
    #expect(runtime.loadAttemptsForTests == 0)
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
}
