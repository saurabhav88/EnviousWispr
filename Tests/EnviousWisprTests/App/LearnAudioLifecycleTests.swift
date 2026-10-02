import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing
import os

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #3338 PR-4 chunk 5: the learn wiring owns the take audio hold, installs it on the
/// Parakeet driver on the watcher's own clock, and drops every held take on the events
/// the plan names (recording start, toggle off, sleep, wake, memory pressure, quit).
/// When these fail, a recording outlives the moment it must be dropped, or a dictation
/// in flight puts audio back into the hold after Self-Learning was turned off.
///
/// FIXTURE values: the sample cap and drain margin here are test-only; production
/// passes neither (both unqualified), so it captures nothing and leases nothing.
@MainActor
@Suite("Learn audio lifecycle (#3338)", .tags(.productOutcome), .serialized)
struct LearnAudioLifecycleTests {

  private static let fixtureCap = 16_000 * 120
  private static let fixtureMarginMs = 5_000

  /// Scripted system events.
  @MainActor
  final class EventsFake: LearnAudioLifecycleEvents {
    private var handler: (@MainActor (LearnAudioLifecycleEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start(_ handler: @escaping @MainActor (LearnAudioLifecycleEvent) -> Void) {
      starts += 1
      self.handler = handler
    }
    func stop() {
      stops += 1
      handler = nil
    }
    func fire(_ event: LearnAudioLifecycleEvent) { handler?(event) }
    var isRegistered: Bool { handler != nil }
  }

  private struct Fixture {
    let settings: SettingsManager
    let wiring: LearnFromEditsWiring
    let events: EventsFake
    let clock: ObserverClock
    let driver: KernelDictationDriver
    let kernel: RecordingSessionKernel
  }

  private func fixture(cap: Int? = fixtureCap, margin: Int? = fixtureMarginMs) -> Fixture {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-learn-audio-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "ew.learn.audio.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    settings.learnFromEdits = true
    let customWords = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let packs = VocabularyPackManager(defaults: defaults)
    let overlay = OverlayDirector(
      host: WindowlessOverlayHost(),
      scheduler: .manual { _ in },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    let clock = ObserverClock()
    let events = EventsFake()
    let wiring = LearnFromEditsWiring(
      settings: settings, customWords: customWords, packs: packs, overlay: overlay,
      pasteCompletionRegistry: PasteCompletionRegistry(), telemetry: LearnTelemetrySpy(),
      legacyLedgerDirectory: dir, observer: ObserverFake(), scheduler: clock,
      frontmost: { nil }, selectJudgeForTests: { nil }, debugExportPath: nil,
      learnAudioSampleCap: cap, learnAudioDrainMarginMs: margin, learnAudioLifecycleEvents: events)
    let (driver, kernel) = Self.makeDriver()
    return Fixture(
      settings: settings, wiring: wiring, events: events, clock: clock, driver: driver,
      kernel: kernel)
  }

  private static func makeDriver() -> (KernelDictationDriver, RecordingSessionKernel) {
    let steps = LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep())
    let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    let kernel = RecordingSessionKernel(
      adapter: adapter, audioCapture: FakeAudioCapture(), vad: FakeVADSignalSource(),
      currentTick: { 0 }, sleepTicks: { _ in },
      processText: { raw, _ in raw }, store: { _, _, _ in }, deliver: { _, _ in .pasted },
      engineMutationScope: .alwaysAllowedForTesting, minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(),
      context: KernelSessionContext(), steps: steps, adapter: adapter,
      engineMutationScope: .alwaysAllowedForTesting)
    return (driver, kernel)
  }

  private func record(_ id: String) -> LearnTakeAudio {
    LearnTakeAudio(
      takeID: id, samples: [0.1, 0.2], decodePath: .conditionedBatch, sampleOrigin: .kernelASRInput,
      decodeLanguage: nil, rawText: "text", wordTimings: nil)!
  }

  /// One held, pasted take.
  private func hold(_ f: Fixture, _ id: String = "a") {
    f.wiring.learnAudioHold.retain(takeID: id, record: record(id))
    f.wiring.learnAudioHold.markPasted(takeID: id, atMs: f.clock.nowMs)
  }

  @Test(
    "installation: the hold is the sink, the clock is the watcher's, the cap needs Self-Learning on"
  )
  func installation() throws {
    let f = fixture()
    #expect(f.wiring.installLearnAudio(on: f.driver))
    f.clock.now = 4_321
    let on = f.kernel.learnAudioDeliveryForTesting()
    #expect((on.sink as AnyObject?) === f.wiring.learnAudioHold)
    #expect(on.cap == Self.fixtureCap)
    #expect(on.nowMs == 4_321, "the watcher's scheduler, not another epoch")
    f.settings.learnFromEdits = false
    #expect(f.kernel.learnAudioDeliveryForTesting().cap == nil)
  }

  @Test(
    "production defaults: no qualified cap or margin, so nothing is captured and nothing is leased")
  func productionDefaults() async {
    let f = fixture(cap: nil, margin: nil)
    #expect(f.wiring.installLearnAudio(on: f.driver))
    #expect(f.kernel.learnAudioDeliveryForTesting().cap == nil)
    hold(f)
    #expect(await f.wiring.learnAudioHold.lease(takeID: "a") == nil)
  }

  @Test("toggle off: held takes go and the current take keeps no audio")
  func toggleOff() {
    let f = fixture()
    #expect(f.wiring.installLearnAudio(on: f.driver))
    hold(f)
    f.settings.learnFromEdits = false
    f.wiring.settingChanged(.learnFromEdits, settings: f.settings)
    #expect(f.wiring.learnAudioHold.heldTakeIDsForTesting.isEmpty)
    #expect(f.kernel.learnAudioDeliveryForTesting().invalidated)
  }

  @Test("sleep, wake and memory pressure each drop every held take and invalidate the current take")
  func systemEvents() {
    for event in [LearnAudioLifecycleEvent.willSleep, .didWake, .memoryPressure] {
      let f = fixture()
      #expect(f.wiring.installLearnAudio(on: f.driver))
      #expect(f.events.isRegistered)
      hold(f, "a")
      hold(f, "b")
      f.events.fire(event)
      #expect(f.wiring.learnAudioHold.heldTakeIDsForTesting.isEmpty, "\(event)")
      #expect(f.kernel.learnAudioDeliveryForTesting().invalidated, "\(event)")
    }
  }

  @Test("recording start drops earlier takes without disabling the new one")
  func recordingStart() {
    let f = fixture()
    #expect(f.wiring.installLearnAudio(on: f.driver))
    hold(f)
    f.wiring.recordingStarted()
    #expect(f.wiring.learnAudioHold.heldTakeIDsForTesting.isEmpty)
    #expect(f.kernel.learnAudioDeliveryForTesting().invalidated == false)
  }

  @Test("quit: observers unregister once, every take goes, repeated shutdown is harmless")
  func shutdown() {
    let f = fixture()
    #expect(f.wiring.installLearnAudio(on: f.driver))
    hold(f)
    f.wiring.shutdownLearnAudio()
    f.wiring.shutdownLearnAudio()
    #expect(f.events.stops == 1)
    #expect(!f.events.isRegistered)
    #expect(f.wiring.learnAudioHold.heldTakeIDsForTesting.isEmpty)
    #expect(f.kernel.learnAudioDeliveryForTesting().invalidated)
  }

  @Test("a system event cancels a running lease, signals its work, and the audio is released")
  func eventCancelsLeaseAndReleases() async throws {
    let f = fixture()
    #expect(f.wiring.installLearnAudio(on: f.driver))
    hold(f)
    weak var storage = f.wiring.learnAudioHold.storageForTesting(takeID: "a")
    let lease = try #require(await f.wiring.learnAudioHold.lease(takeID: "a"))
    let signalled = OSAllocatedUnfairLock(initialState: false)
    await lease.onCancel { signalled.withLock { $0 = true } }
    f.events.fire(.memoryPressure)
    #expect(signalled.withLock { $0 })
    #expect(await lease.read() == nil)
    await lease.end()
    #expect(storage == nil)
  }

  @Test("observation end stops new leases while a running lease keeps reading")
  func observationEnd() async throws {
    let f = fixture()
    hold(f)
    let lease = try #require(await f.wiring.learnAudioHold.lease(takeID: "a"))
    f.wiring.learnAudioHold.observationEnded(takeID: "a")
    #expect(await f.wiring.learnAudioHold.lease(takeID: "a") == nil)
    #expect(await lease.read() != nil)
    await lease.end()
  }
}
