import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Observation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview

/// #3973 plan §3.3, §3.4: the meeting's live-words owner. When one of these fails, a meeting
/// shows no live words when it could, shows them from the wrong engine or language, keeps a
/// model loaded after the meeting, or lets a stuck engine hold up Stop, Delete or the next
/// recording.
///
/// Only the boundaries are fake (engines, availability, the clock); the owner, the pumps, the
/// assembler and the mailbox are the production code.
@MainActor
@Suite("Meeting live words owner (#3973)", .serialized, .tags(.productOutcome))
struct MeetingLiveWordsTests {

  // MARK: - Fakes

  /// A pause a fake parks in until `open()`; `reached(n)` signals entries. Released by every
  /// wait's expiry.
  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entries = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(open: Bool = false) { isOpen = open }

    func pass() async {
      await withCheckedContinuation { c in
        let (now, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
          entries += 1
          let met = waiters.filter { $0.0 <= entries }.map(\.1)
          waiters.removeAll { $0.0 <= entries }
          if isOpen { return (true, met) }
          parked.append(c)
          return (false, met)
        }
        for w in ready { w.resume() }
        if now { c.resume() }
      }
    }

    @Sendable func open() {
      let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        isOpen = true
        defer { parked = [] }
        return parked
      }
      for c in all { c.resume() }
    }

    func reached(_ n: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if entries >= n { return true }
          waiters.append((n, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  final class FakeSession: LivePreviewEngineSession, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _fed: [Float] = []
    private var _ends = 0
    private var _endsCompleted = 0
    private var waiters: [(() -> Bool, CheckedContinuation<Void, Never>)] = []
    let onEvent: @Sendable (LiveWordsEvent) -> Void
    let endGate: Gate
    let feedGate: Gate
    init(
      onEvent: @escaping @Sendable (LiveWordsEvent) -> Void, endGate: Gate,
      feedGate: Gate = Gate(open: true)
    ) {
      self.onEvent = onEvent
      self.endGate = endGate
      self.feedGate = feedGate
    }
    var fed: [Float] { lock.withLock { _fed } }
    var ends: Int { lock.withLock { _ends } }
    /// Ends that have returned.
    var endsCompleted: Int { lock.withLock { _endsCompleted } }
    func feed(_ samples: [Float]) async {
      changed { _fed += samples }
      await feedGate.pass()
    }
    /// Like Apple's collector: an end delivers `.ended(.requested)` after the last event.
    func end() async {
      changed { _ends += 1 }
      await endGate.pass()
      onEvent(.ended(.requested))
      changed { _endsCompleted += 1 }
    }
    func emit(_ event: LiveWordsEvent) { onEvent(event) }

    /// Returns once `condition` holds; checked and registered in one lock step.
    func until(_ condition: @escaping () -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if condition() { return true }
          waiters.append((condition, c))
          return false
        }
        if now { c.resume() }
      }
    }

    private func changed(_ body: () -> Void) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        body()
        let met = waiters.filter { $0.0() }.map(\.1)
        waiters.removeAll { $0.0() }
        return met
      }
      for w in ready { w.resume() }
    }
  }

  struct Refused: Error {}

  /// One engine's gates; all open unless a test closes one.
  struct Gates {
    var prepare = Gate(open: true)
    var open = Gate(open: true)
    var end = Gate(open: true)
    var feed = Gate(open: true)
    /// Opens after the first one (an Apple restart's replacement).
    var reopen = Gate(open: true)
  }

  final class FakeEngine: LivePreviewEngine, @unchecked Sendable {
    let prepareGate: Gate
    let openGate: Gate
    let endGate: Gate
    let feedGate: Gate
    let reopenGate: Gate
    var failPrepare = false
    var failOpen = false
    /// Opens after the first one fail (an Apple restart's replacement).
    var failReopen = false
    private let lock = NSLock()
    private var _sessions: [FakeSession] = []
    private var _vocabularies: [LivePreviewVocabulary] = []
    private var _openEvents: [@Sendable (LiveWordsEvent) -> Void] = []
    /// Passed once per session this engine returns (a signal, never held).
    let opened = Gate(open: true)
    init(_ gates: Gates = Gates()) {
      self.prepareGate = gates.prepare
      self.openGate = gates.open
      self.endGate = gates.end
      self.feedGate = gates.feed
      self.reopenGate = gates.reopen
    }
    var sessions: [FakeSession] { lock.withLock { _sessions } }
    /// Each open's event callback, recorded as the open begins (before it can return).
    var openEvents: [@Sendable (LiveWordsEvent) -> Void] { lock.withLock { _openEvents } }
    var vocabularies: [LivePreviewVocabulary] { lock.withLock { _vocabularies } }
    func prepare() async throws {
      await prepareGate.pass()
      if failPrepare { throw Refused() }
    }
    func openSession(
      vocabulary: LivePreviewVocabulary, onText: @escaping @Sendable (String) -> Void
    ) async throws -> any LivePreviewEngineSession {
      Issue.record("the meeting never opens a display session")
      throw Refused()
    }
    func openTranscriptSession(
      vocabulary: LivePreviewVocabulary, onEvent: @escaping @Sendable (LiveWordsEvent) -> Void
    ) async throws -> any LivePreviewEngineSession {
      let first = lock.withLock { () -> Bool in
        _vocabularies.append(vocabulary)
        _openEvents.append(onEvent)
        return _openEvents.count == 1
      }
      await (first ? openGate : reopenGate).pass()
      if failOpen || (!first && failReopen) { throw Refused() }
      let session = FakeSession(onEvent: onEvent, endGate: endGate, feedGate: feedGate)
      lock.withLock { _sessions.append(session) }
      await opened.pass()
      return session
    }
  }

  final class FakeShared: MeetingSharedEngine, @unchecked Sendable {
    let engine: FakeEngine
    var recognizer: any LivePreviewEngine { engine }
    let releaseGate: Gate
    var failPrepare = false
    /// Prepares that fail as "dictation holds the executor" before one succeeds.
    var busyPrepares = 0
    private(set) var prepareCalls = 0
    struct Busy: Error {}
    func isTemporary(_ error: any Error) -> Bool { error is Busy }
    private let lock = NSLock()
    private var _releases = 0
    private var release: Task<Void, Never>?
    private var _endsCompletedAtRelease: [Int]?
    init(engine: FakeEngine, releaseGate: Gate) {
      self.engine = engine
      self.releaseGate = releaseGate
    }
    var releases: Int { lock.withLock { _releases } }
    /// Each session's completed ends when the release began: an ordering record.
    var endsCompletedAtRelease: [Int]? { lock.withLock { _endsCompletedAtRelease } }
    func prepare() async throws {
      await engine.prepareGate.pass()
      let busy = lock.withLock { () -> Bool in
        prepareCalls += 1
        return prepareCalls <= busyPrepares
      }
      if busy { throw Busy() }
      if failPrepare { throw Refused() }
    }
    func beginRelease() async -> Task<Void, Never> {
      lock.withLock { () -> Task<Void, Never> in
        if let release { return release }
        _releases += 1
        _endsCompletedAtRelease = engine.sessions.map(\.endsCompleted)
        let gate = releaseGate
        let task = Task { await gate.pass() }
        release = task
        return task
      }
    }
  }

  /// Everything the owner asks the outside world, recorded.
  final class World: @unchecked Sendable {
    private let lock = NSLock()
    var appleSupported = true
    var apple: LivePreviewEngineResolution?
    /// #4105: the frozen live words choice; nil derives the old shape (Apple when `apple` is
    /// ready on a supported Mac, else Universal) in `liveLanguage`.
    var choice: MeetingLiveWordsChoice.Resolution?
    var liveLanguage = "de"
    private var _forcings: [LivePreviewEngineChoice?] = []
    var forcings: [LivePreviewEngineChoice?] { lock.withLock { _forcings } }
    func resolveChoice(_ forcing: LivePreviewEngineChoice?) -> MeetingLiveWordsChoice.Resolution {
      lock.withLock { _forcings.append(forcing) }
      if let forcing { return .ready(engine: forcing, language: liveLanguage) }
      if let choice { return choice }
      if appleSupported, case .ready = apple { return .ready(engine: .apple, language: liveLanguage) }
      return .ready(engine: .universal, language: liveLanguage)
    }
    var universalBlocked: LivePreviewUnavailability?
    var universalPrepareFails = false
    /// The Universal engine's first prepares fail as "dictation holds the executor".
    var universalBusyPrepares = 0
    /// Apple engines, by creation order, whose transcript open fails.
    var appleOpenFails: Set<Int> = []
    /// Apple engines, by creation order, whose restart replacement fails to open.
    var appleReopenFails: Set<Int> = []
    var universalOpenFails = false
    /// The gates for the n-th engine this world makes (Apple recognizers and shared engines
    /// counted together, in creation order).
    var engineGates: (Int) -> Gates = { _ in Gates() }
    private var made = 0
    private func nextGates() -> Gates {
      let n = lock.withLock { () -> Int in
        defer { made += 1 }
        return made
      }
      return engineGates(n)
    }
    let releaseGate = Gate(open: true)
    /// Each Universal resolution passes it before it answers (held: the answer waits).
    var universalResolveGate = Gate(open: true)
    /// Held: the live words choice lookup at Start waits here.
    var choiceGate = Gate(open: true)
    var restartAfterSamples = 600 * 16_000
    var restartEndDeadline: Double = 5
    private var _appleEngines: [FakeEngine] = []
    private var _shared: [FakeShared] = []
    private var _languages: [LanguageMode] = []
    var appleEngines: [FakeEngine] { lock.withLock { _appleEngines } }
    var shared: [FakeShared] { lock.withLock { _shared } }
    var languages: [LanguageMode] { lock.withLock { _languages } }
    func noteLanguage(_ mode: LanguageMode) { lock.withLock { _languages.append(mode) } }

    func appleCandidate() -> LivePreviewEngineCandidate {
      LivePreviewEngineCandidate(key: .init(engine: "apple", commitment: "en-US")) {
        let engine = FakeEngine(self.nextGates())
        self.lock.withLock {
          engine.failOpen = self.appleOpenFails.contains(self._appleEngines.count)
          engine.failReopen = self.appleReopenFails.contains(self._appleEngines.count)
          self._appleEngines.append(engine)
        }
        return engine
      }
    }

    func makeShared() -> any MeetingSharedEngine {
      let shared = FakeShared(
        engine: FakeEngine(nextGates()),
        releaseGate: releaseGate)
      shared.failPrepare = universalPrepareFails
      shared.busyPrepares = universalBusyPrepares
      shared.engine.failOpen = universalOpenFails
      lock.withLock { _shared.append(shared) }
      return shared
    }
  }

  static func owner(
    _ world: World, choiceOwner: MeetingLiveWordsChoice.Initializer? = nil
  ) -> MeetingLiveWords {
    MeetingLiveWords(
      dependencies: .init(
        resolveChoice: { forcing in
          await world.choiceGate.pass()
          return world.resolveChoice(forcing)
        },
        resolveApple: { tag in
          world.noteLanguage(.locked(tag))
          return world.apple ?? .blocked(.unsupportedLanguage)
        },
        resolveUniversal: { mode in
          world.noteLanguage(mode)
          await world.universalResolveGate.pass()
          if let blocked = world.universalBlocked { return .blocked(blocked) }
          return .ready(makeEngine: { _ in world.makeShared() })
        },
        isHeartStreaming: { false },
        makePump: { MeetingLiveAudioPump(cadence: .milliseconds(1)) },
        droppedCheckInterval: .milliseconds(1),
        appleRestartAfterSamples: world.restartAfterSamples,
        restartEndDeadline: world.restartEndDeadline,
        universalRetryDelay: .milliseconds(1)),
      choiceOwner: choiceOwner)
  }

  static let vocabulary = LivePreviewVocabulary(
    lookups: nil, contextualPhrases: ["Envious"], dictionaryEnabled: true)

  /// Starts a recording on `tracks`; returns its observer.
  @discardableResult
  static func record(
    _ owner: MeetingLiveWords, _ id: UUID = UUID(),
    tracks: Set<MeetingTrackKind> = [.microphone, .callSound],
    clock: @escaping @Sendable () -> Int = { 1_000 }
  ) -> MeetingRecorder.LiveSamplesObserver {
    let observer = owner.prepareCapture(meetingID: id)
    owner.captureStarted(
      meetingID: id, captured: tracks, vocabulary: vocabulary, clock: clock)
    return observer
  }

  private static func id(of owner: MeetingLiveWords) throws -> UUID {
    try #require(owner.transcript?.meetingID)
  }

  /// Returns once `condition` holds, observing the owner's published transcript.
  static func until(
    _ what: String, _ owner: MeetingLiveWords, release: @escaping @Sendable () -> Void = {},
    _ condition: @escaping @MainActor (MeetingLiveWords) -> Bool
  ) async {
    await PreviewWait.within(what, onExpiry: release) { @MainActor in
      while !condition(owner) {
        // Checked and registered with no suspension between, on the main actor.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          withObservationTracking { _ = owner.transcript } onChange: { c.resume() }
        }
      }
    }
  }

  static func status(_ owner: MeetingLiveWords, _ track: MeetingTrackKind)
    -> MeetingLiveWords.Status?
  {
    owner.transcript?.tracks[track]?.status
  }

  static func bothRunning(_ owner: MeetingLiveWords) -> Bool {
    status(owner, .microphone) == .running && status(owner, .callSound) == .running
  }

  // MARK: - Resolution

  @Test("the chosen engine runs; a choice that cannot run leaves live words off, never another engine")
  func resolutionMatrix() async throws {
    // Apple chosen and ready: one Apple meeting recognizer per track, asked for the exact tag.
    do {
      let world = World()
      world.choice = .ready(engine: .apple, language: "de-DE")
      world.apple = .ready(world.appleCandidate())
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("both running on Apple", owner) { Self.bothRunning($0) }
      #expect(world.appleEngines.count == 2 && world.shared.isEmpty)
      #expect(world.languages == [.locked("de-DE")])
      #expect(owner.currentLanguage == "de-DE")
      owner.stop()
    }
    // Apple chosen, its model missing at Start: off naming the language; Universal is never asked.
    do {
      let world = World()
      world.choice = .ready(engine: .apple, language: "de-DE")
      world.apple = .blocked(.installRequired(languageName: "German"))
      let owner = Self.owner(world)
      Self.record(owner)
      let off = MeetingLiveWords.Status.off(.engineNotDownloaded(engine: .apple, languageName: "German"))
      await Self.until("off: Apple's German model", owner) { Self.status($0, .microphone) == off }
      #expect(Self.status(owner, .callSound) == off)
      #expect(world.shared.isEmpty && world.appleEngines.isEmpty)
      #expect(world.languages == [.locked("de-DE")], "Universal is never asked")
      owner.stop()
    }
    // Universal chosen: one engine for both tracks, asked for the base code.
    do {
      let world = World()
      world.choice = .ready(engine: .universal, language: "de")
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("both running on Universal", owner) { Self.bothRunning($0) }
      #expect(world.shared.count == 1 && world.appleEngines.isEmpty)
      #expect(world.shared.first?.engine.sessions.count == 2)
      #expect(world.languages == [.locked("de")])
      owner.stop()
    }
    // Universal chosen, model gone at Start: off; Apple is never used instead.
    do {
      let world = World()
      world.choice = .ready(engine: .universal, language: "de")
      world.apple = .ready(world.appleCandidate())
      world.universalBlocked = .modelNotInstalled
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("off: download the Universal engine", owner) {
        if case .off(.engineNotDownloaded(.universal, _)) = Self.status($0, .microphone) {
          return true
        }
        return false
      }
      #expect(world.appleEngines.isEmpty)
      owner.stop()
    }
    // Chosen but not downloaded (known before Start): off without asking any engine.
    do {
      let world = World()
      world.choice = .notDownloaded(engine: .apple, language: "fr-CA")
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("off: not downloaded", owner) {
        if case .off(.engineNotDownloaded(.apple, _)) = Self.status($0, .microphone) {
          return true
        }
        return false
      }
      #expect(world.languages.isEmpty)
      owner.stop()
    }
    // Nothing chosen: off, not set up.
    do {
      let world = World()
      world.choice = .notSetUp(suggestion: nil)
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("off: not set up", owner) {
        Self.status($0, .microphone) == .off(.notSetUp)
      }
      #expect(world.languages.isEmpty)
      owner.stop()
    }
    // Universal refuses for another reason: off, unavailable.
    do {
      let world = World()
      world.choice = .ready(engine: .universal, language: "de")
      world.universalBlocked = .engineUnavailableInThisBuild
      let owner = Self.owner(world)
      Self.record(owner)
      await Self.until("off: unavailable", owner) {
        Self.status($0, .microphone) == .off(.unavailable)
      }
      owner.stop()
    }
  }

  @Test("a choice lookup still running when its recording stops or is replaced opens nothing")
  func staleChoiceLookupOpensNothing() async throws {
    // Stopped while the lookup is held.
    do {
      let world = World()
      world.apple = .ready(world.appleCandidate())
      let held = Gate()
      world.choiceGate = held
      let owner = Self.owner(world)
      Self.record(owner)
      await PreviewWait.within("the lookup held", onExpiry: held.open) { await held.reached(1) }
      owner.stop()
      held.open()
      #expect(await owner.waitForCleanups(seconds: 10))
      #expect(world.appleEngines.isEmpty && world.shared.isEmpty)
      #expect(world.languages.isEmpty, "no engine was asked for the stopped recording")
    }
    // Replaced by a new recording while the first lookup is held.
    do {
      let world = World()
      world.apple = .ready(world.appleCandidate())
      let held = Gate()
      world.choiceGate = held
      let owner = Self.owner(world)
      Self.record(owner)
      await PreviewWait.within("the first lookup held", onExpiry: held.open) {
        await held.reached(1)
      }
      let second = UUID()
      Self.record(owner, second)
      await PreviewWait.within("the second lookup held", onExpiry: held.open) {
        await held.reached(2)
      }
      held.open()
      await Self.until("the second recording running", owner) { Self.bothRunning($0) }
      #expect(owner.transcript?.meetingID == second)
      #expect(world.appleEngines.count == 2, "one recognizer per track, for the second only")
      #expect(world.languages.count == 1, "the first lookup asked no engine")
      owner.stop()
      #expect(await owner.waitForCleanups(seconds: 10))
    }
  }

  @Test("the live words language and vocabulary reach the engines, frozen at start")
  func frozenInputs() async throws {
    let world = World()
    world.choice = .ready(engine: .apple, language: "ja-JP")
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    #expect(world.forcings.count == 1, "the choice is read once, at start")
    #expect(world.languages == [.locked("ja-JP")], "resolved once, with the chosen language")
    for engine in world.appleEngines {
      #expect(engine.vocabularies.map(\.contextualPhrases) == [["Envious"]])
    }
    owner.stop()
  }

  // MARK: - Capture and words

  @Test("pumps take audio before capture starts; engines start only after it did")
  func pumpsBeforeEngines() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let id = UUID()
    let observer = owner.prepareCapture(meetingID: id)
    let early: [Float] = (0..<1_600).map(Float.init)
    early.withUnsafeBufferPointer { observer(.microphone, $0) }
    #expect(world.languages.isEmpty && world.appleEngines.isEmpty, "nothing resolved yet")
    owner.captureStarted(
      meetingID: id, captured: [.microphone, .callSound], vocabulary: Self.vocabulary,
      clock: { 0 })
    await Self.until("running", owner) { Self.bothRunning($0) }
    let mic = try #require(world.appleEngines.first?.sessions.first)
    await PreviewWait.within("the buffered audio reaching the session") {
      await mic.until { mic.fed.count >= early.count }
    }
    #expect(mic.fed == early, "the audio from before the engine was ready")
    owner.stop()
  }

  @Test("failed capture retires the pumps and starts no engine")
  func captureFailureStartsNothing() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let id = UUID()
    _ = owner.prepareCapture(meetingID: id)
    owner.captureFailed(meetingID: id)
    owner.captureStarted(
      meetingID: id, captured: [.microphone], vocabulary: Self.vocabulary, clock: { 0 })
    #expect(owner.transcript == nil)
    #expect(world.languages.isEmpty && world.appleEngines.isEmpty)
  }

  @Test("words from both tracks are assembled in order; a track not captured is off")
  func bothTracksAssemble() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let engines = world.appleEngines
    let mic = try #require(engines[0].sessions.first)
    let call = try #require(engines[1].sessions.first)
    mic.emit(.update(finalized: "Hello", inProgress: " there"))
    mic.emit(.update(finalized: " there.", inProgress: ""))
    call.emit(.update(finalized: "Hi.", inProgress: ""))
    await Self.until("both tracks' words", owner) { o in
      let lines = o.transcript?.lines ?? []
      return lines.contains { $0.track == .microphone && $0.text == "Hello there." }
        && lines.contains { $0.track == .callSound && $0.text == "Hi." }
    }
    owner.stop()

    let single = World()
    single.apple = .ready(single.appleCandidate())
    let one = Self.owner(single)
    Self.record(one, tracks: [.microphone])
    await Self.until("mic only", one) { Self.status($0, .microphone) == .running }
    #expect(Self.status(one, .callSound) == .off(.notCaptured))
    #expect(single.appleEngines.count == 1, "no recognizer for a track not captured")
    one.stop()
  }

  // MARK: - Failures

  @Test("a failed preparation or open turns the track off and frees what it made")
  func preparationAndOpenFailures() async throws {
    // Universal preparation fails: both off, and cleanup frees the engine.
    let world = World()
    world.appleSupported = false
    world.universalPrepareFails = true
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("both off", owner) {
      Self.status($0, .microphone) == .off(.couldNotStart)
        && Self.status($0, .callSound) == .off(.couldNotStart)
    }
    // Freed while the meeting continues, not at Stop.
    await PreviewWait.within("the unusable engine's release") { await world.releaseGate.reached(1) }
    #expect(world.shared.first?.releases == 1)
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(world.shared.first?.releases == 1, "freed once")

    // One Apple open fails: that track is off, the other runs.
    let apple = World()
    apple.appleOpenFails = [0]
    apple.apple = .ready(apple.appleCandidate())
    let second = Self.owner(apple)
    Self.record(second)
    await Self.until("one off, one running", second) { o in
      let a = Self.status(o, .microphone)
      let b = Self.status(o, .callSound)
      return [a, b].contains(.off(.couldNotStart)) && [a, b].contains(.running)
    }
    #expect(apple.appleEngines.flatMap(\.sessions).count == 1, "one session opened")
    second.stop()
    #expect(await second.waitForCleanups(seconds: 10))
    #expect(apple.appleEngines.flatMap(\.sessions).map(\.ends) == [1])
  }

  @Test("one track's engine failing stops that track only; the other keeps going")
  func oneTrackFails() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let mic = try #require(world.appleEngines[0].sessions.first)
    let call = try #require(world.appleEngines[1].sessions.first)
    mic.emit(.update(finalized: "Before.", inProgress: ""))
    mic.emit(.ended(.failed("service")))
    await Self.until("mic stopped", owner) {
      Self.status($0, .microphone) == .stopped(.engineFailed)
    }
    #expect(Self.status(owner, .callSound) == .running)
    await PreviewWait.within("the failed session's end") { await mic.until { mic.ends == 1 } }
    call.emit(.update(finalized: "Still here.", inProgress: ""))
    await Self.until("the call track's words", owner) { o in
      (o.transcript?.lines ?? []).contains { $0.track == .callSound && $0.text == "Still here." }
    }
    #expect((owner.transcript?.lines ?? []).contains { $0.text == "Before." }, "its words stay")
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(mic.ends == 1 && call.ends == 1, "each session ended once")
  }

  // MARK: - Exits and cleanup

  @Test("Stop and Delete return at once while preparation or an end is held")
  func exitsNeverWait() async throws {
    // Preparation held: Stop returns; nothing opens afterwards; the engine is freed later.
    let world = World()
    world.appleSupported = false
    let prepare = Gate()
    world.engineGates = { _ in Gates(prepare: prepare) }
    let owner = Self.owner(world)
    Self.record(owner)
    await PreviewWait.within("preparation held", onExpiry: prepare.open) {
      await prepare.reached(1)
    }
    owner.stop()
    #expect(owner.closingEngines == [.universal], "its cleanup is still running")
    prepare.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(world.shared.first?.engine.sessions.isEmpty == true, "nothing opened after Stop")
    #expect(world.shared.first?.releases == 1)

    // An end held: Delete returns and clears the words; cleanup finishes when the end does.
    let held = World()
    let end = Gate()
    held.engineGates = { _ in Gates(end: end) }
    held.apple = .ready(held.appleCandidate())
    let other = Self.owner(held)
    Self.record(other)
    await Self.until("running", other) { Self.bothRunning($0) }
    let id = try Self.id(of: other)
    other.delete(meetingID: id)
    #expect(other.transcript == nil, "Delete clears the live words now")
    #expect(other.closingEngines == [.apple])
    end.open()
    #expect(await other.waitForCleanups(seconds: 10))
    #expect(other.closingEngines.isEmpty)
  }

  @Test("a session that opens after Stop is ended once and never installed")
  func lateOpenEndedOnce() async throws {
    let world = World()
    let open = Gate()
    world.engineGates = { _ in Gates(open: open) }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner, tracks: [.microphone])
    await PreviewWait.within("the open held", onExpiry: open.open) { await open.reached(1) }
    let observer = owner.prepareCapture(meetingID: UUID())  // a new recording replaces it
    open.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    let late = try #require(world.appleEngines.first?.sessions.first)
    #expect(late.ends == 1, "ended once by the old recording's cleanup")
    let samples: [Float] = [1, 2, 3]
    samples.withUnsafeBufferPointer { observer(.microphone, $0) }
    #expect(late.fed.isEmpty, "never fed: it was never the recording's session")
    owner.stop()
  }

  @Test("a cleanup waiter can give up while the free continues and completes")
  func waiterExpiryKeepsCleanup() async throws {
    let world = World()
    let release = Gate()
    let owner = MeetingLiveWords(
      dependencies: .init(
        resolveChoice: { _ in .ready(engine: .universal, language: "de") },
        resolveApple: { _ in .blocked(.unsupportedSystem) },
        resolveUniversal: { _ in
          .ready(makeEngine: { _ in
            let shared = FakeShared(engine: FakeEngine(), releaseGate: release)
            world.noteLanguage(.auto)
            return shared
          })
        },
        isHeartStreaming: { false }, makePump: { MeetingLiveAudioPump(cadence: .milliseconds(1)) }))
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    owner.stop()
    await PreviewWait.within("the free held", onExpiry: release.open) { await release.reached(1) }
    // deadline-fallback: the expiry IS the outcome under test (the free is held)
    #expect(await owner.waitForCleanups(seconds: 0.05) == false)
    #expect(owner.closingEngines == [.universal], "still closing after the waiter gave up")
    release.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(owner.closingEngines.isEmpty)
  }

  @Test("while a model is still being freed a new meeting has live words off and allocates none")
  func previousStillClosing() async throws {
    let world = World()
    world.appleSupported = false
    let release = Gate()
    let owner = MeetingLiveWords(
      dependencies: .init(
        resolveChoice: { _ in .ready(engine: .universal, language: "de") },
        resolveApple: { _ in .blocked(.unsupportedSystem) },
        resolveUniversal: { _ in
          .ready(makeEngine: { _ in
            let shared = FakeShared(engine: FakeEngine(), releaseGate: release)
            world.noteLanguage(.auto)
            return shared
          })
        },
        isHeartStreaming: { false }, makePump: { MeetingLiveAudioPump(cadence: .milliseconds(1)) }))
    Self.record(owner)
    await Self.until("first meeting running", owner) { Self.bothRunning($0) }
    owner.stop()
    await PreviewWait.within("the free held", onExpiry: release.open) { await release.reached(1) }
    Self.record(owner)
    await Self.until("second meeting off", owner) {
      Self.status($0, .microphone) == .off(.previousStillClosing)
    }
    #expect(Self.status(owner, .callSound) == .off(.previousStillClosing))
    #expect(world.languages.count == 1, "no second engine while the first is being freed")
    owner.stop()
    release.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    Self.record(owner)
    await Self.until("third meeting running", owner) { Self.bothRunning($0) }
    #expect(world.languages.count == 2, "a new engine once the first was physically freed")
    owner.stop()
  }

  @Test("events from both tracks keep the order they arrived in")
  func interleavingPreserved() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    // A clock that moves on with every event, so the call's words come after the mic line began
    // and the assembler closes that line: only the arrival order decides where "C." goes.
    let tick = OSAllocatedUnfairLock(initialState: 0)
    Self.record(owner, clock: { tick.withLock { $0 += 1; return $0 } })
    await Self.until("running", owner) { Self.bothRunning($0) }
    let mic = try #require(world.appleEngines[0].sessions.first)
    let call = try #require(world.appleEngines[1].sessions.first)
    // One main-actor turn: all three are queued before any drain runs.
    mic.emit(.update(finalized: "A.", inProgress: ""))
    call.emit(.update(finalized: "B.", inProgress: ""))
    mic.emit(.update(finalized: " C.", inProgress: ""))
    await Self.until("three lines", owner) { ($0.transcript?.lines.count ?? 0) == 3 }
    let seen = (owner.transcript?.lines ?? []).map { "\($0.track):\($0.text)" }
    #expect(seen == ["microphone:A.", "callSound:B.", "microphone:C."])
    owner.stop()
  }

  @Test("a final accepted just before Stop is kept in the lines")
  func finalBeforeStopKept() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    try #require(world.appleEngines[0].sessions.first).emit(
      .update(finalized: "Last words.", inProgress: ""))
    owner.stop()  // same main-actor turn: no drain ran in between
    #expect(owner.transcript?.lines.map(\.text) == ["Last words."])
  }

  @Test("a held feed keeps the cleanup open, but the session's end starts at once")
  func heldFeedKeepsCleanupOpen() async throws {
    let world = World()
    let feed = Gate()
    world.engineGates = { $0 == 0 ? Gates(feed: feed) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let mic = try #require(world.appleEngines[0].sessions.first)
    let samples: [Float] = (0..<1_600).map(Float.init)
    samples.withUnsafeBufferPointer { observer(.microphone, $0) }
    await PreviewWait.within("the feed held", onExpiry: feed.open) { await feed.reached(1) }
    owner.stop()
    await PreviewWait.within("the end started", onExpiry: feed.open) {
      await mic.until { mic.ends == 1 }
    }
    #expect(owner.closingEngines == [.apple], "still closing while the feed is held")
    feed.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(owner.closingEngines.isEmpty)
  }

  @Test("a handle whose track already failed is ended as soon as its open returns")
  func earlyTerminalEndsLateHandle() async throws {
    let world = World()
    let open = Gate()
    world.engineGates = { $0 == 0 ? Gates(open: open) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await PreviewWait.within("the mic open held", onExpiry: open.open) { await open.reached(1) }
    let mic = world.appleEngines[0]
    let onEvent = try #require(mic.openEvents.first)
    onEvent(.ended(.failed("service")))  // before the open returns
    await Self.until("mic stopped", owner, release: open.open) {
      Self.status($0, .microphone) == .stopped(.engineFailed)
    }
    open.open()
    await PreviewWait.within("the late handle") { await mic.opened.reached(1) }
    let handle = try #require(mic.sessions.first)
    await PreviewWait.within("its end, before Stop") { await handle.until { handle.ends == 1 } }
    await Self.until("the call track still starts and runs", owner) {
      Self.status($0, .callSound) == .running
    }
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(handle.ends == 1, "ended once")
  }

  @Test("an unusable Universal engine is freed while the meeting continues")
  func failedOpensReleaseEarly() async throws {
    let world = World()
    world.appleSupported = false
    world.universalOpenFails = true
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("both off", owner) {
      Self.status($0, .microphone) == .off(.couldNotStart)
        && Self.status($0, .callSound) == .off(.couldNotStart)
    }
    await PreviewWait.within("the release before Stop") { await world.releaseGate.reached(1) }
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(world.shared.first?.releases == 1)
  }

  @Test("a late open is ended while another session's end is still held")
  func lateOpenNotBehindHeldEnd() async throws {
    let world = World()
    let micEnd = Gate()
    let callOpen = Gate()
    world.engineGates = { $0 == 0 ? Gates(end: micEnd) : Gates(open: callOpen) }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("mic running", owner, release: callOpen.open) {
      Self.status($0, .microphone) == .running
    }
    await PreviewWait.within("the call open held", onExpiry: callOpen.open) {
      await callOpen.reached(1)
    }
    owner.stop()
    let mic = try #require(world.appleEngines[0].sessions.first)
    await PreviewWait.within("the mic end held", onExpiry: micEnd.open) {
      await mic.until { mic.ends == 1 }
    }
    callOpen.open()
    let call = world.appleEngines[1]
    await PreviewWait.within("the late call handle", onExpiry: micEnd.open) {
      await call.opened.reached(1)
    }
    let late = try #require(call.sessions.first)
    await PreviewWait.within("its end, though the mic end is still held", onExpiry: micEnd.open) {
      await late.until { late.ends == 1 }
    }
    #expect(owner.closingEngines == [.apple])
    micEnd.open()
    #expect(await owner.waitForCleanups(seconds: 10))
  }

  @Test("dropped live audio is flagged even when no words arrive")
  func droppedFlagWithoutEvents() async throws {
    let world = World()
    let feed = Gate()
    defer { feed.open() }
    world.engineGates = { $0 == 0 ? Gates(feed: feed) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    // The mic feed is held, so 40 s of audio overflows the 28.8 s the pump keeps.
    let second = [Float](repeating: 0.1, count: 16_000)
    for _ in 0..<40 { second.withUnsafeBufferPointer { observer(.microphone, $0) } }
    await Self.until("the dropped flag", owner, release: feed.open) {
      $0.transcript?.tracks[.microphone]?.droppedAudio == true
    }
    #expect(owner.transcript?.tracks[.callSound]?.droppedAudio == false)
    #expect(owner.transcript?.lines.isEmpty == true, "no events were needed")
    feed.open()
    owner.stop()
  }

  @Test("a post racing the final take is either in that batch or refused, never lost")
  func postRacingFinalTake() {
    for _ in 0..<50 {
      let bridge = LiveWordsBridge(clock: { 0 }, wake: {})
      bridge.openEpoch(1, for: .microphone)
      let accepted = OSAllocatedUnfairLock<[String]>(initialState: [])
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        started.signal()
        for i in 0..<2_000 {
          let text = "\(i) "
          if bridge.post(.update(finalized: text, inProgress: ""), track: .microphone, epoch: 1) {
            accepted.withLock { $0.append(text) }
          }
        }
        finished.signal()
      }
      // deadline-fallback: around the producer's own signals
      #expect(started.wait(timeout: .now() + 10) == .success)
      let batch = bridge.closeAllAndTake()
      // deadline-fallback: around the producer's own signals
      #expect(finished.wait(timeout: .now() + 10) == .success)
      let taken = batch.reduce(into: "") { text, entry in
        if case .update(let finalized, _) = entry.event { text += finalized }
      }
      #expect(taken == accepted.withLock { $0.joined() }, "every accepted post is in the batch")
      #expect(!bridge.post(.discontinuity, track: .microphone, epoch: 1), "closed afterwards")
    }
  }

  @Test("an early Universal release waits for the handle of an open that was still pending")
  func earlyReleaseWaitsForPendingOpen() async throws {
    for stopMidway in [false, true] {
      let world = World()
      world.appleSupported = false
      let open = Gate()
      let end = Gate()
      world.engineGates = { _ in Gates(open: open, end: end) }
      let owner = Self.owner(world)
      Self.record(owner, tracks: [.microphone])
      await PreviewWait.within("the open held", onExpiry: { open.open(); end.open() }) {
        await open.reached(1)
      }
      let shared = try #require(world.shared.first)
      let onEvent = try #require(shared.engine.openEvents.first)
      onEvent(.ended(.failed("service")))  // the only track fails while its open is pending
      await Self.until("mic stopped", owner, release: { open.open(); end.open() }) {
        Self.status($0, .microphone) == .stopped(.engineFailed)
      }
      open.open()
      await PreviewWait.within("the late handle", onExpiry: end.open) {
        await shared.engine.opened.reached(1)
      }
      let handle = try #require(shared.engine.sessions.first)
      await PreviewWait.within("its end begins", onExpiry: end.open) {
        await handle.until { handle.ends == 1 }
      }
      if stopMidway { owner.stop() }
      end.open()
      await PreviewWait.within("the release") { await world.releaseGate.reached(1) }
      #expect(shared.endsCompletedAtRelease == [1], "released only after the handle's end returned")
      owner.stop()
      #expect(await owner.waitForCleanups(seconds: 10))
      #expect(shared.releases == 1 && handle.ends == 1, "once each (stop midway: \(stopMidway))")
    }
  }

  // MARK: - Apple restart (decision 17)

  private static func voiced(_ count: Int, from start: Int = 0) -> [Float] {
    (0..<count).map { 0.1 + Float(start + $0) * 1e-6 }
  }
  private static let quiet = [Float](repeating: 0, count: 1_600)

  private static func speak(
    _ observer: MeetingRecorder.LiveSamplesObserver, _ track: MeetingTrackKind, _ samples: [Float]
  ) {
    samples.withUnsafeBufferPointer { observer(track, $0) }
  }

  @Test("no restart before the audio threshold, and voiced audio postpones it to the first quiet window")
  func restartWaitsForThresholdAndQuiet() async throws {
    let world = World()
    world.restartAfterSamples = 3_200
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let engine = world.appleEngines[0]
    let old = try #require(engine.sessions.first)
    Self.speak(observer, .microphone, Self.quiet)  // quiet, but before the threshold
    await PreviewWait.within("the quiet audio fed") { await old.until { old.fed.count == 1_600 } }
    Self.speak(observer, .microphone, Self.voiced(3_200))  // past the threshold, all voiced
    await PreviewWait.within("the voiced audio fed") { await old.until { old.fed.count == 4_800 } }
    #expect(engine.openEvents.count == 1, "no restart without a quiet window")
    Self.speak(observer, .microphone, Self.quiet)
    await PreviewWait.within("the restart's open") { await engine.opened.reached(2) }
    #expect(old.fed.count == 6_400, "the quiet window went to the old session")
    #expect(old.ends == 1)
    owner.stop()
  }

  @Test("a restart keeps the old finals, freezes words in progress, and feeds every sample once")
  func restartPreservesWordsAndAudio() async throws {
    let world = World()
    world.restartAfterSamples = 1_600
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let engine = world.appleEngines[0]
    let call = try #require(world.appleEngines[1].sessions.first)
    let old = try #require(engine.sessions.first)
    old.emit(.update(finalized: "Before.", inProgress: " maybe"))
    let first = Self.voiced(1_600)
    let after = Self.voiced(800, from: 5_000)
    Self.speak(observer, .microphone, first + Self.quiet + after)
    await PreviewWait.within("the replacement") { await engine.opened.reached(2) }
    let new = engine.sessions[1]
    await PreviewWait.within("the rest of the audio") {
      await new.until { new.fed.count == after.count }
    }
    #expect(old.fed == first + Self.quiet, "the old session got everything up to the quiet window")
    #expect(new.fed == after, "the replacement got the rest, once, in order")
    new.emit(.update(finalized: " After.", inProgress: ""))
    old.emit(.update(finalized: " Late.", inProgress: ""))  // the old epoch is closed
    call.emit(.update(finalized: "Call goes on.", inProgress: ""))
    await Self.until("the new and the call words", owner) { o in
      let texts = (o.transcript?.lines ?? []).map(\.text)
      return texts.contains("After.") && texts.contains("Call goes on.")
    }
    let lines = owner.transcript?.lines ?? []
    #expect(lines.contains { $0.text == "Before." && $0.kind == .confirmed })
    #expect(lines.contains { $0.text.contains("maybe") && $0.kind == .uncertain }, "frozen")
    #expect(!lines.contains { $0.text.contains("Late.") }, "late old-epoch words refused")
    #expect(world.appleEngines[1].openEvents.count == 1, "the call track did not restart")
    #expect(Self.bothRunning(owner))
    owner.stop()
  }

  @Test("an old end past the deadline stops that track: no second analyzer, words kept, end owned")
  func restartDeadlineStopsTrack() async throws {
    let world = World()
    world.restartAfterSamples = 1_600
    world.restartEndDeadline = 0.05  // the expiry is the outcome under test
    let end = Gate()
    defer { end.open() }
    world.engineGates = { $0 == 0 ? Gates(end: end) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let engine = world.appleEngines[0]
    try #require(engine.sessions.first).emit(.update(finalized: "Kept.", inProgress: ""))
    Self.speak(observer, .microphone, Self.voiced(1_600) + Self.quiet)
    await Self.until("mic stopped by the deadline", owner, release: end.open) {
      Self.status($0, .microphone) == .stopped(.restartTimedOut)
    }
    #expect(engine.openEvents.count == 1, "no second analyzer")
    #expect(Self.status(owner, .callSound) == .running)
    #expect((owner.transcript?.lines ?? []).contains { $0.text == "Kept." })
    owner.stop()
    #expect(owner.closingEngines == [.apple], "the old end is still owned")
    end.open()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(engine.sessions.first?.endsCompleted == 1)
  }

  enum Exit: CaseIterable { case stop, delete, quit }

  private static func exit(_ owner: MeetingLiveWords, _ exit: Exit) throws {
    switch exit {
    case .stop: owner.stop()
    case .delete: owner.delete(meetingID: try Self.id(of: owner))
    case .quit: owner.quit()
    }
  }

  @Test(
    "Stop, Delete or Quit during a restart's end or its replacement open installs nothing and ends late handles once",
    arguments: Exit.allCases)
  func exitDuringRestart(_ exit: Exit) async throws {
    // The old session is still ending.
    do {
      let world = World()
      world.restartAfterSamples = 1_600
      let end = Gate()
      world.engineGates = { $0 == 0 ? Gates(end: end) : Gates() }
      world.apple = .ready(world.appleCandidate())
      let owner = Self.owner(world)
      let observer = Self.record(owner)
      await Self.until("running", owner, release: end.open) { Self.bothRunning($0) }
      let engine = world.appleEngines[0]
      let old = try #require(engine.sessions.first)
      Self.speak(observer, .microphone, Self.voiced(1_600) + Self.quiet)
      await PreviewWait.within("the old end", onExpiry: end.open) { await old.until { old.ends == 1 } }
      try Self.exit(owner, exit)
      end.open()
      #expect(await owner.waitForCleanups(seconds: 10))
      #expect(engine.openEvents.count == 1, "no replacement after the exit")
      #expect(old.ends == 1)
    }
    // The replacement open is held.
    do {
      let world = World()
      world.restartAfterSamples = 1_600
      let reopen = Gate()
      world.engineGates = { $0 == 0 ? Gates(reopen: reopen) : Gates() }
      world.apple = .ready(world.appleCandidate())
      let owner = Self.owner(world)
      let observer = Self.record(owner)
      await Self.until("running", owner, release: reopen.open) { Self.bothRunning($0) }
      let engine = world.appleEngines[0]
      Self.speak(observer, .microphone, Self.voiced(1_600) + Self.quiet)
      await PreviewWait.within("the replacement open", onExpiry: reopen.open) {
        await reopen.reached(1)
      }
      try Self.exit(owner, exit)
      reopen.open()
      await PreviewWait.within("the late handle") { await engine.opened.reached(2) }
      let late = engine.sessions[1]
      #expect(await owner.waitForCleanups(seconds: 10))
      #expect(late.ends == 1, "ended once")
      #expect(late.fed.isEmpty, "never fed")
      #expect(engine.sessions[0].ends == 1)
    }
  }

  @Test("a replacement that cannot open stops the track; its words stay and the other track goes on")
  func replacementOpenFails() async throws {
    let world = World()
    world.restartAfterSamples = 1_600
    world.appleReopenFails = [0]
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let engine = world.appleEngines[0]
    let old = try #require(engine.sessions.first)
    old.emit(.update(finalized: "Said before.", inProgress: ""))
    Self.speak(observer, .microphone, Self.voiced(1_600) + Self.quiet)
    await Self.until("mic stopped", owner) {
      Self.status($0, .microphone) == .stopped(.restartFailed)
    }
    #expect(Self.status(owner, .callSound) == .running)
    #expect((owner.transcript?.lines ?? []).contains { $0.text == "Said before." })
    #expect(engine.openEvents.count == 2, "one replacement attempt, no retry")
    // The retired pump takes no more audio for this track.
    Self.speak(observer, .microphone, Self.voiced(1_600, from: 9_000))
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(engine.sessions.count == 1 && old.ends == 1, "the old session ended once")
    #expect(old.fed.count == 3_200, "nothing reached it after the restart point")
  }

  @Test("finals delivered while the old session is ending are kept before the epoch changes")
  func finalsDuringHeldEnd() async throws {
    let world = World()
    world.restartAfterSamples = 1_600
    let end = Gate()
    world.engineGates = { $0 == 0 ? Gates(end: end) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner, release: end.open) { Self.bothRunning($0) }
    let engine = world.appleEngines[0]
    let old = try #require(engine.sessions.first)
    Self.speak(observer, .microphone, Self.voiced(1_600) + Self.quiet)
    await PreviewWait.within("the old end", onExpiry: end.open) { await old.until { old.ends == 1 } }
    old.emit(.update(finalized: "Flushed at the end.", inProgress: ""))  // while ending
    end.open()
    await PreviewWait.within("the replacement") { await engine.opened.reached(2) }
    await Self.until("the flushed final", owner) { o in
      (o.transcript?.lines ?? []).contains { $0.text == "Flushed at the end." }
    }
    #expect(Self.status(owner, .microphone) == .running)
    owner.stop()
  }

  /// The per-session sample sequences `RestartFeeder` sends for `chunks`, restarting into a new
  /// session at each restart point.
  private static func sessions(
    _ chunks: [[Float]], threshold: Int
  ) async -> [[Float]] {
    let feeder = RestartFeeder(meter: RestartMeter(threshold: threshold, quietRMS: 0.001))
    let sent = OSAllocatedUnfairLock<[[Float]]>(initialState: [[]])
    for chunk in chunks {
      await feeder.run(
        chunk,
        send: { part in
          sent.withLock { $0[$0.count - 1] += part }
          return true
        },
        restart: { sent.withLock { $0.append([]) } })
    }
    return sent.withLock { $0 }
  }

  @Test("continuous quiet audio in chunks smaller than 100 ms still restarts")
  func quietAcrossSmallChunks() async {
    let audio = Self.voiced(1_600) + [Float](repeating: 0, count: 4_000)
    let chunks = stride(from: 0, to: audio.count, by: 400).map {
      Array(audio[$0..<min($0 + 400, audio.count)])
    }
    let sent = await Self.sessions(chunks, threshold: 1_600)
    #expect(sent.count >= 2, "a restart happened")
    #expect(sent[0] == Array(audio[0..<3_200]), "restart at the end of the first quiet window")
    #expect(sent.flatMap { $0 } == audio, "every sample once, in order")
  }

  @Test("how the audio is split never moves the restart point or the samples each session gets")
  func splitDoesNotMatter() async {
    // Each silent stretch is 200 ms, so a whole 100 ms window fits in it wherever the windows
    // start.
    let audio =
      Self.voiced(2_500) + Self.voiced(700, from: 3_000) + [Float](repeating: 0, count: 3_200)
      + Self.voiced(1_000, from: 9_000) + [Float](repeating: 0, count: 3_200)
      + Self.voiced(300, from: 20_000)
    let whole = await Self.sessions([audio], threshold: 2_000)
    for cuts in [[1_000, 2_300, 4_000], [1_999, 2_001, 4_799, 4_801], [7, 3_201, 6_400]] {
      var chunks: [[Float]] = []
      var from = 0
      for cut in cuts + [audio.count] {
        chunks.append(Array(audio[from..<cut]))
        from = cut
      }
      #expect(await Self.sessions(chunks, threshold: 2_000) == whole, "cuts \(cuts)")
    }
    #expect(whole.count >= 2, "at least one restart (threshold reached, then a quiet window)")
    #expect(whole.flatMap { $0 } == audio)
  }

  @Test("Universal sessions never restart")
  func universalNeverRestarts() async throws {
    let world = World()
    world.appleSupported = false
    world.restartAfterSamples = 1_600
    let owner = Self.owner(world)
    let observer = Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let shared = try #require(world.shared.first)
    let mic = try #require(shared.engine.sessions.first)
    let audio = Self.voiced(1_600) + Self.quiet + Self.quiet + Self.voiced(1_600)
    Self.speak(observer, .microphone, audio)
    await PreviewWait.within("all fed") { await mic.until { mic.fed.count == audio.count } }
    #expect(shared.engine.openEvents.count == 2, "one session per track, never a replacement")
    #expect(mic.ends == 0)
    owner.stop()
  }

  @Test("the bridge keeps arrival order, coalesces only a track's adjacent updates, and bounds each track")
  func bridgeOrderAndBudget() {
    let woken = OSAllocatedUnfairLock(initialState: 0)
    let bridge = LiveWordsBridge(clock: { 7 }, wake: { woken.withLock { $0 += 1 } })
    bridge.openEpoch(1, for: .microphone)
    bridge.openEpoch(1, for: .callSound)
    bridge.post(.update(finalized: "a", inProgress: "x"), track: .microphone, epoch: 1)
    bridge.post(.update(finalized: "b", inProgress: "y"), track: .microphone, epoch: 1)
    bridge.post(.update(finalized: "c", inProgress: ""), track: .callSound, epoch: 1)
    bridge.post(.update(finalized: "d", inProgress: ""), track: .microphone, epoch: 1)
    bridge.post(.update(finalized: "stale", inProgress: ""), track: .microphone, epoch: 2)
    #expect(
      bridge.take().map { "\($0.track):\($0.event)" } == [
        "microphone:\(LiveWordsEvent.update(finalized: "a b", inProgress: "y"))",
        "callSound:\(LiveWordsEvent.update(finalized: "c", inProgress: ""))",
        "microphone:\(LiveWordsEvent.update(finalized: "d", inProgress: ""))",
      ])
    // Barriers are charged; a track past its budget ends with one backlog, the other goes on.
    for _ in 0..<(LiveWordsBridge.budgetPerTrack / LiveWordsBridge.entryCost + 5) {
      bridge.post(.discontinuity, track: .microphone, epoch: 1)
    }
    bridge.post(.update(finalized: "after", inProgress: ""), track: .microphone, epoch: 1)
    bridge.post(.update(finalized: "call", inProgress: ""), track: .callSound, epoch: 1)
    let entries = bridge.take()
    let mic = entries.filter { $0.track == .microphone }
    #expect(mic.count == LiveWordsBridge.budgetPerTrack / LiveWordsBridge.entryCost + 1)
    #expect(mic.last?.event == .ended(.failed("backlog")))
    #expect(entries.last?.event == .update(finalized: "call", inProgress: ""))
    #expect(woken.withLock { $0 } > 0)
  }

  @Test("a Universal load refused while dictation holds the executor is tried again, then runs")
  func busyUniversalPrepareRetries() async throws {
    let world = World()
    world.appleSupported = false
    world.universalBusyPrepares = 3
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running after the busy tries", owner) { Self.bothRunning($0) }
    let shared = try #require(world.shared.first)
    #expect(shared.prepareCalls == 4, "three busy tries, then the one that worked")
    #expect(world.shared.count == 1, "the same engine, never a second runtime")
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(shared.releases == 1)
  }

  @Test("a Universal load that keeps failing for another reason stops at once")
  func otherUniversalPrepareFailureIsFinal() async throws {
    let world = World()
    world.appleSupported = false
    world.universalPrepareFails = true
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("off", owner) { Self.status($0, .microphone) == .off(.couldNotStart) }
    #expect(try #require(world.shared.first).prepareCalls == 1)
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
  }

  @Test("Stop during the busy retries ends them and frees the engine once")
  func stopDuringBusyRetries() async throws {
    let world = World()
    world.appleSupported = false
    world.universalBusyPrepares = Int.max
    // Open throughout; passed once per prepare, so its count is the subject's own signal.
    let tries = Gate(open: true)
    world.engineGates = { _ in Gates(prepare: tries) }
    let owner = Self.owner(world)
    Self.record(owner)
    await PreviewWait.within("two busy tries") { await tries.reached(2) }
    let shared = try #require(world.shared.first)
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    #expect(shared.releases == 1)
  }

  @Test(
    "a merged update shows the same text as the two updates applied one by one",
    arguments: [
      ("Hello world.", "How are you?"), (" Hello world.", " How are you?"), ("你好。", "再见。"),
      ("Hello", ", world"),
    ])
  func mergeMatchesSeparateUpdates(_ pair: (String, String)) {
    let bridge = LiveWordsBridge(clock: { 0 }, wake: {})
    bridge.openEpoch(1, for: .microphone)
    bridge.post(.update(finalized: pair.0, inProgress: "x"), track: .microphone, epoch: 1)
    bridge.post(.update(finalized: pair.1, inProgress: ""), track: .microphone, epoch: 1)
    let merged = bridge.take()
    #expect(merged.count == 1, "control: the two updates were merged")
    var viaMerge = LiveWordsAssembler()
    for entry in merged { viaMerge.apply(entry.event, track: .microphone, atMs: 0) }
    var oneByOne = LiveWordsAssembler()
    oneByOne.apply(.update(finalized: pair.0, inProgress: "x"), track: .microphone, atMs: 0)
    oneByOne.apply(.update(finalized: pair.1, inProgress: ""), track: .microphone, atMs: 0)
    #expect(viaMerge.lines.map(\.text) == oneByOne.lines.map(\.text))
  }

  @Test("lines stay after Stop until the transcript is ready; Delete clears them at once")
  func linesLifecycle() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    let id = try Self.id(of: owner)
    try #require(world.appleEngines[0].sessions.first).emit(
      .update(finalized: "Kept.", inProgress: ""))
    await Self.until("words", owner) { !($0.transcript?.lines.isEmpty ?? true) }
    owner.stop()
    #expect(owner.transcript?.lines.map(\.text) == ["Kept."], "kept after Stop")
    owner.transcriptReady(meetingID: id)
    #expect(owner.transcript == nil, "replaced by the final transcript")
  }

  @Test("Stop, a second Stop and Quit start one cleanup that ends each session once")
  func repeatedRetirement() async throws {
    let world = World()
    world.appleSupported = false
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("running", owner) { Self.bothRunning($0) }
    owner.stop()
    owner.stop()
    owner.quit()
    #expect(await owner.waitForCleanups(seconds: 10))
    let shared = try #require(world.shared.first)
    #expect(shared.releases == 1)
    #expect(shared.engine.sessions.map(\.ends) == [1, 1])
  }

  @Test("a stopped recording's late events never change the next recording's words")
  func staleEventsIgnored() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let owner = Self.owner(world)
    Self.record(owner)
    await Self.until("first running", owner) { Self.bothRunning($0) }
    let old = try #require(world.appleEngines[0].sessions.first)
    owner.stop()
    #expect(await owner.waitForCleanups(seconds: 10))
    Self.record(owner)
    await Self.until("second running", owner) { Self.bothRunning($0) }
    let current = try #require(world.appleEngines[2].sessions.first)
    old.emit(.update(finalized: "Old meeting.", inProgress: ""))
    current.emit(.update(finalized: "New meeting.", inProgress: ""))
    await Self.until("the new words", owner) { o in
      (o.transcript?.lines ?? []).contains { $0.text == "New meeting." }
    }
    #expect(!(owner.transcript?.lines ?? []).contains { $0.text == "Old meeting." })
    owner.stop()
  }
}
