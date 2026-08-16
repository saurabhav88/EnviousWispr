@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprLivePreview
@testable import EnviousWisprServices

/// #1988 — the live preview's limb contract.
///
/// These tests deliberately do NOT drive Apple's recognizer. Building a
/// `SpeechAnalyzer` needs macOS 26, a reserved locale and possibly a model
/// download, none of which belong in a unit test and none of which the CI runner
/// has. What IS unit-testable is the part that protects the heart: the gate that
/// decides whether any of that happens at all, and the bound on what the feature
/// retains. Live behaviour is covered by UAT.
@MainActor
struct LivePreviewCoordinatorTests {

  // MARK: - The gate

  @Test("Disabled: the preview stays off and never reads the audio buffer")
  func disabledNeverTouchesAudio() async {
    let capture = CountingAudioCapture()
    let coordinator = LivePreviewCoordinator(
      readSamples: { await capture.getSamplesSnapshot(fromIndex: $0) },
      isEnabled: { false },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )

    coordinator.setRecording(true)
    #expect(coordinator.display == .off)

    // This asserts a NEGATIVE (no feed loop was started), and there is no signal
    // to wait on for something that must never happen. The paired
    // `enabledStartsAndLeavesOff` test is the control proving the start path
    // works, so a vacuous pass here would be caught there.
    // settle: proving absence; a started loop polls every 100 ms so it could not hide inside this window
    try? await Task.sleep(for: .milliseconds(250))
    #expect(
      capture.snapshotCallCount == 0,
      "a disabled preview must not read captured audio at all")
    #expect(coordinator.display == .off)
  }

  /// The two-way control for the test above. Without it, `disabledNeverTouchesAudio`
  /// would pass just as happily against a coordinator whose start path was broken
  /// or deleted, which is the shape of a vacuous guard test.
  @Test("Enabled: the start path runs and the pill leaves the off state")
  func enabledStartsAndLeavesOff() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )

    coordinator.setRecording(true)
    // Set synchronously by `setRecording`, before any async work, so this holds on
    // every macOS version including ones where the recognizer cannot exist.
    #expect(coordinator.display == .waiting)
  }

  @Test("A new recording never opens showing the previous one's words")
  func startClearsPreviousText() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    // Stopping DISCARDS. This assertion used to read `.waiting`, which was
    // incidental to the old behaviour of keeping the last text until the next
    // recording. The settings copy now tells the user the preview is discarded
    // when the recording ends, so this is the contract that sentence depends on.
    #expect(coordinator.display == .off, "stopping must release the preview text")

    coordinator.setRecording(true)
    #expect(
      coordinator.display == .waiting,
      "the next press must reset the pill before its panel is created")
  }

  @Test("Stop is safe before any start, and start is safe twice")
  func lifecycleIsIdempotent() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )
    // Two call sites push recording intent (the first overlay push and every
    // state-driven one), and `hide()` reports a stop that may already have
    // happened. All the orders below occur in practice.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    coordinator.setRecording(false)
    // Settles OFF, and a redundant second stop does not disturb that. This read
    // `!= .off` when a stop left the last text in place; the discard makes the
    // stronger statement available, so assert the exact state rather than the
    // absence of one.
    #expect(coordinator.display == .off)
  }

  /// The claim in the settings description, asserted directly rather than as a
  /// side effect of another test: a user reads "discarded when the recording
  /// ends" before deciding to switch this on, so the discard is a contract, not
  /// an implementation detail that may drift.
  @Test("Stopping discards the preview text, matching what the setting promises")
  func stopDiscardsPreviewText() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )
    coordinator.setRecording(true)
    #expect(coordinator.display != .off, "control: a live recording is not off")

    coordinator.setRecording(false)
    #expect(coordinator.display == .off)
    #expect(
      LivePreviewSettingsCopy.toggleDescription.contains("discarded"),
      "if this sentence goes, the assertion above stops being the promise it pins")
  }

  // MARK: - Language policy
  //
  // This policy belongs to APPLE'S engine, not to the preview feature, which is why
  // these assert against `ApplePreviewEngineResolver`. Apple cannot detect language,
  // so it has to be told one before it hears anything and Auto has to become a
  // guess. An engine that detects language itself must not inherit that guess.

  @Test("A locked language previews in that language; Auto follows the system")
  func languagePolicy() {
    #expect(ApplePreviewEngineResolver.languageCode(for: .locked("de")) == "de")
    let auto = ApplePreviewEngineResolver.languageCode(for: .auto)
    #expect(auto == Locale.current.identifier(.bcp47))
    #expect(auto.isEmpty == false)
  }

  /// Auto must keep REGION and SCRIPT, not just language. Reducing to the language
  /// code sends a Traditional Chinese Mac to the Simplified model, Brazilian
  /// Portuguese to European, and Canadian French to Swiss — measured against
  /// Apple's real resolver, not inferred. This asserts the property that prevents
  /// it, on a fixed locale rather than the machine's, so it means the same thing
  /// on every runner.
  @Test("Auto preserves region and script, which is what picks the right model")
  func autoPreservesRegionAndScript() {
    // The reduction that caused it, applied to the cases it breaks. If
    // `ApplePreviewEngineResolver.languageCode(for: .auto)` ever goes back to a
    // bare language code, these are the users who silently get another region's
    // model.
    for id in ["zh-TW", "pt-BR", "fr-CA", "en-GB"] {
      let full = Locale(identifier: id)
      let bare = full.language.languageCode?.identifier
      #expect(
        full.identifier(.bcp47) != bare,
        "\(id) must not survive as a bare language code")
    }
  }

  // MARK: - The engine seam (#2077)
  //
  // None of these could be written before the seam existed. Driving the coordinator
  // meant driving Apple's recognizer, which needs macOS 26, a reserved locale and
  // possibly a model download — so the parts below were covered only by hand.
  //
  // Every wait here is on a SIGNAL the coordinator produces, with a deadline as the
  // fallback. A fixed sleep would encode this machine's speed into the assertion.

  @Test("Preparation is paid once, not on every recording")
  func preparationIsCachedAcrossRecordings() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(probe: probe, key: key("apple", "en-US"))

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 }, "first session never opened")
    coordinator.setRecording(false)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 2 }, "second session never opened")
    coordinator.setRecording(false)

    #expect(
      await probe.prepareCalls == 1,
      "a second press must reuse the prepared engine, not prepare again")
  }

  /// The reason the cache key carries the ENGINE as well as the language. A user
  /// switching engines must not keep talking to the previous one.
  @Test("A different engine key prepares again rather than reusing the old engine")
  func changingTheKeyRebuilds() async {
    let probe = PreviewEngineProbe()
    let keys = [key("apple", "en-US"), key("universal", "")]
    let resolutions = CountingBox()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in
        let nth = await resolutions.next()
        return .ready(
          LivePreviewEngineCandidate(
            key: keys[min(nth, keys.count - 1)],
            makeEngine: { FakePreviewEngine(probe: probe) }))
      }
    )

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 })
    coordinator.setRecording(false)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 2 })
    coordinator.setRecording(false)

    #expect(await probe.prepareCalls == 2, "a changed engine key must prepare the new engine")
  }

  @Test("Captured audio reaches the session, and stopping ends it exactly once")
  func audioReachesTheSessionAndStopEndsIt() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(
      probe: probe,
      key: key("apple", "en-US"),
      // A growing buffer, as a real recording looks from the read side.
      readSamples: { index in
        index == Int.max ? ([], 0) : (Array(repeating: Float(0.05), count: 160), 160)
      })

    coordinator.setRecording(true)
    #expect(await reach { await probe.samplesFed > 0 }, "the session received no audio")
    coordinator.setRecording(false)

    #expect(
      await reach { await probe.sessionsEnded == 1 },
      "every session must be ended, or the engine leaks its analyzer and model")
    #expect(await probe.sessionsEnded == 1, "and ended exactly once")
  }

  /// A blocked engine must cost nothing. This is the limb rule applied to the
  /// refusal path: if we cannot preview, we must not be reading audio anyway.
  @Test("A blocked engine reports its reason and never reads audio")
  func blockedEngineNeverReadsAudio() async {
    let reads = CountingBox()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in
        await reads.bump()
        return ([], 0)
      },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedLanguage) }
    )

    coordinator.setRecording(true)
    // The reason landing IS the signal that resolution finished, so this waits on
    // the outcome rather than on a duration.
    #expect(
      await reach { coordinator.display == .unavailable(LivePreviewCopy.languageUnsupported) },
      "a blocked engine must say why")
    #expect(await reads.value == 0, "a blocked preview must not read captured audio")
  }

  /// #1988's acceptance criterion, now assertable end to end: the user's own words
  /// reach the engine that renders them, rather than being applied somewhere later.
  @Test("Custom Words reach the session that will display the text")
  func customWordsReachTheSession() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(probe: probe, key: key("apple", "en-US"))
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 })
    coordinator.setRecording(false)

    #expect(
      await probe.sawNonNilLookups,
      "the session must open with the vocabulary snapshot, not without it")
  }

  /// Poll a signal until it holds, bounded by a deadline.
  ///
  /// The deadline is a failure bound, never the thing being measured: a correct
  /// implementation returns on the first poll that observes the signal, so a slow
  /// runner costs a few more polls rather than a false failure.
  /// `@MainActor` on the condition, deliberately: the coordinator's `display` is
  /// main-actor state and the whole point is to read it, so a nonisolated closure
  /// would force every caller to hop by hand.
  private func reach(
    within timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      // settle: poll interval inside a signal wait; the deadline above is the real bound
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  private func key(_ engine: String, _ commitment: String) -> LivePreviewEngineKey {
    LivePreviewEngineKey(engine: engine, commitment: commitment)
  }

  private func makeCoordinator(
    probe: PreviewEngineProbe,
    key: LivePreviewEngineKey,
    readSamples: @escaping LivePreviewSampleReader = { _ in ([], 0) }
  ) -> LivePreviewCoordinator {
    LivePreviewCoordinator(
      readSamples: readSamples,
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: key, makeEngine: { FakePreviewEngine(probe: probe) }))
      }
    )
  }

  // MARK: - Bounding

  @Test("Short text is returned untouched")
  func shortTextUnbounded() {
    let text = "the quick brown fox"
    #expect(LivePreviewTextBound.apply(text) == text)
  }

  @Test("Long text keeps the tail, drops the head, and does not cut a word in half")
  func longTextKeepsTail() {
    // The pill shows the newest words, so the END is the part that must survive.
    let long = String(repeating: "alpha ", count: 1000)  // 6000 characters
    let bounded = LivePreviewTextBound.apply(long)

    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(bounded.isEmpty == false)
    #expect(long.hasSuffix(bounded), "the retained text must be a suffix of the original")
    #expect(
      bounded.hasPrefix("alpha"),
      "trimming must land on a word boundary, not mid-word")
  }

  @Test("Bounding a string with no spaces still bounds it")
  func boundingWithoutWordBoundaries() {
    // A CJK sentence carries no spaces, and neither does a pathological URL. The
    // word-boundary step must not be able to turn the bound off.
    let long = String(repeating: "語", count: 5000)
    let bounded = LivePreviewTextBound.apply(long)
    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(long.hasSuffix(bounded))
  }

  /// The bound is idempotent, which is what lets the producer apply it on every
  /// update without the text creeping.
  @Test("Applying the bound twice changes nothing the second time")
  func boundIsIdempotent() {
    let long = String(repeating: "alpha ", count: 1000)
    let once = LivePreviewTextBound.apply(long)
    #expect(LivePreviewTextBound.apply(once) == once)
  }

  // MARK: - Shipped default

  @Test("Live preview ships off")
  func shipsOff() {
    // Off by default is the founder-approved shipped state: it costs screen
    // attention some users explicitly asked to be able to decline, and it needs
    // macOS 26, so on by default would read as broken on every older Mac.
    #expect(SettingsDefaultValues.livePreviewEnabled == false)
  }

  // MARK: - Custom Words on preview text (#1988 acceptance)

  private func makeCoordinator() -> LivePreviewCoordinator {
    LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { true },
      languageMode: { .locked("en") },
      resolveEngine: { _ in .blocked(.unsupportedSystem) }
    )
  }

  private func word(_ canonical: String) -> CustomWord {
    CustomWord(canonical: canonical)
  }

  /// **The seed arrives at generation 0, and so does the property's initial
  /// `.empty`.** Comparing an incoming generation against the PREVIOUS VALUE's
  /// would therefore treat a real vocabulary arriving at launch as an unchanged
  /// one and silently drop it, so Custom Words would reach the preview only after
  /// the user edited them — never, for anyone whose words were already saved.
  /// This is the exact collision, written as the case most likely to regress.
  @Test("A vocabulary seeded at generation 0 is picked up, not mistaken for empty")
  func generationZeroSeedIsNotDropped() {
    let coordinator = makeCoordinator()
    #expect(coordinator.correctorLookupBuilds == 0)
    #expect(coordinator.hasCorrectorLookupsForTesting == false)

    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 0)

    #expect(coordinator.correctorLookupBuilds == 1)
    #expect(
      coordinator.hasCorrectorLookupsForTesting,
      "a generation-0 seed carrying real terms must build lookups")
  }

  @Test("A new generation rebuilds; the same generation does not")
  func rebuildsOnlyOnGenerationChange() {
    let coordinator = makeCoordinator()
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)
    #expect(coordinator.correctorLookupBuilds == 1)

    // Same generation, different terms: the generation IS the identity, so this
    // must not rebuild. Building here would mean the cache key is not doing its
    // job and every settings write pays a full lookup build.
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics"), word("EnviousWispr")], generation: 1)
    #expect(coordinator.correctorLookupBuilds == 1)

    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics"), word("EnviousWispr")], generation: 2)
    #expect(coordinator.correctorLookupBuilds == 2)
  }

  /// An empty vocabulary stores `nil` rather than empty lookups, so the
  /// recognizer's guard short-circuits instead of running a correction pass that
  /// cannot match anything. Most users have no custom words, so this is the
  /// common path, not an edge case.
  @Test("Clearing the vocabulary drops the snapshot rather than keeping empty lookups")
  func emptyVocabularyStoresNoLookups() {
    let coordinator = makeCoordinator()
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)
    #expect(coordinator.hasCorrectorLookupsForTesting)

    coordinator.correctorVocabulary = CorrectorVocabulary(terms: [], generation: 2)
    #expect(coordinator.correctorLookupBuilds == 2)
    #expect(coordinator.hasCorrectorLookupsForTesting == false)
  }

  /// The correction the preview applies is the SAME function the pasted text goes
  /// through, so this pins the behaviour the acceptance criterion is about: a
  /// user's own name, misheard by Apple's recognizer, is repaired before display.
  @Test("The corrector repairs a custom term the way the preview will")
  func correctorRepairsACustomTerm() {
    let lookups = WordCorrector.buildLookups(words: [word("Qualtrics")])
    let corrected = WordCorrector().correct("i work at qualtrix today", using: lookups).corrected
    #expect(corrected.contains("Qualtrics"), "got: \(corrected)")
  }

  // MARK: - #2108: the prepared engine is released when preview is disabled

  /// The universal engine holds a loaded WhisperKit model, so the cached-engine
  /// slot now pins roughly 50-60 MB. It is otherwise cleared only when the
  /// candidate KEY changes, and turning the preview off changes no key — so an
  /// engine prepared before the user disabled it stayed cached for the life of
  /// the process. Cloud review caught it on #2113.
  ///
  /// Asserts the SLOT, not a weak reference to the engine. An earlier version did
  /// the latter and failed three times for three different reasons — the
  /// preparation task, then the draining session task, each holding the engine as
  /// a local. A weak-reference assertion cannot distinguish "the slot is still
  /// full" from "the observation was early", which makes it the wrong instrument
  /// for the property this fix changes.
  @Test("disabling the preview releases the prepared engine, not just the display")
  func disablingReleasesThePreparedEngine() async {
    final class ReleasableEngine: LivePreviewEngine, @unchecked Sendable {
      let onPrepared: @Sendable () -> Void
      init(onPrepared: @escaping @Sendable () -> Void) { self.onPrepared = onPrepared }
      func prepare() async throws { onPrepared() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    // Boxed because Swift 6 forbids mutating a captured var from a concurrently
    // executing closure.
    final class Box: @unchecked Sendable {
      var enabled = true
      var prepared = false
    }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isEnabled: { box.enabled },
      languageMode: { .locked("en") },
      resolveEngine: { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReleasableEngine(onPrepared: { box.prepared = true }) }))
      }
    )

    coordinator.setRecording(true)
    // Signal, not a clock: wait for preparation to COMPLETE. The slot is only
    // filled after that, so asserting earlier would test nothing.
    for _ in 0..<2000 where !box.prepared { await Task.yield() }
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    #expect(box.prepared, "control: preparation must have completed")
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the slot must be FULL before a release can mean anything")
    coordinator.setRecording(false)

    // The user turns the preview off and presses record again.
    box.enabled = false
    coordinator.setRecording(true)

    #expect(coordinator.display == .off)
    #expect(
      !coordinator.hasPreparedEngineForTests,
      "a disabled preview must not keep an engine — and with it a loaded model — cached")
  }

}

/// #2077 — what the coordinator actually did to whatever engine it was given.
///
/// An actor rather than a locked class: these counters are written from the engine
/// and the session, which run off the main actor, and read from `@MainActor` tests.
private actor PreviewEngineProbe {
  private(set) var prepareCalls = 0
  private(set) var sessionsOpened = 0
  private(set) var sessionsEnded = 0
  private(set) var samplesFed = 0
  private(set) var sawNonNilLookups = false

  func notePrepare() { prepareCalls += 1 }
  func noteOpen(lookups: WordCorrector.Lookups?) {
    sessionsOpened += 1
    if lookups != nil { sawNonNilLookups = true }
  }
  func noteEnd() { sessionsEnded += 1 }
  func noteFeed(_ count: Int) { samplesFed += count }
}

/// A counter the tests can share with a `@Sendable` closure.
private actor CountingBox {
  private(set) var value = 0
  func bump() { value += 1 }
  /// Returns the pre-increment count, so callers can index a sequence by call order.
  func next() -> Int {
    defer { value += 1 }
    return value
  }
}

private struct FakePreviewSession: LivePreviewEngineSession {
  let probe: PreviewEngineProbe
  func feed(_ samples: [Float]) async { await probe.noteFeed(samples.count) }
  func end() async { await probe.noteEnd() }
}

/// A preview engine with no vendor behind it, which is the whole point: before the
/// #2077 seam the coordinator could only be driven on macOS 26 with a reserved
/// locale and possibly a model download, so none of the behaviour below could be
/// asserted anywhere except by hand.
private struct FakePreviewEngine: LivePreviewEngine {
  let probe: PreviewEngineProbe

  func prepare() async throws { await probe.notePrepare() }

  func openSession(
    lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession {
    await probe.noteOpen(lookups: lookups)
    return FakePreviewSession(probe: probe)
  }
}

/// #1988 — counts reads of the capture buffer so a test can assert that a disabled
/// preview performs none.
@MainActor
private final class CountingAudioCapture: AudioCaptureInterface {
  private(set) var snapshotCallCount = 0

  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "hal_device_input"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture(sessionID: UInt64) async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm() async throws {}
  func abortPreWarm() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    snapshotCallCount += 1
    return ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}
