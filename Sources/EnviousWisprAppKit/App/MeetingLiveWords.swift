import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprWhisperPreviewAdapter
import Foundation
import Observation
import os

/// The meeting's Universal engine as `MeetingLiveWords` needs it: one recognizer whose transcript
/// sessions share one model, explicit preparation, and the physical release (#3973 plan §3.3).
protocol MeetingSharedEngine: Sendable {
  var recognizer: any LivePreviewEngine { get }
  func prepare() async throws
  /// `prepare` failed only because dictation's engine held the executor; a later try can work.
  func isTemporary(_ error: any Error) -> Bool
  /// On return nothing can load, open or decode again; the task completes once the model is
  /// physically freed.
  func beginRelease() async -> Task<Void, Never>
}

extension WhisperPreviewEngineResolver.MeetingEngine: MeetingSharedEngine {}

/// EnviousMeet's live words while a meeting records (#3973 plan §3.3, §3.4): which engine serves
/// the meeting, one transcript session per captured track, the assembled lines, and cleanup that
/// never holds up the recording.
///
/// **Live words are display only.** Nothing here touches the recording, Stop, Delete, the final
/// pass or Quit: each of those calls a synchronous method that invalidates the recording's
/// generation and hands its resources to a once-only cleanup, then returns. Delete closes event
/// admission there; Stop and Quit leave it to that cleanup, which applies what the ending
/// sessions still deliver to the kept lines (#4097).
///
/// **One generation per recording.** Every suspension point re-checks it; a result that arrives
/// for an older generation (a late preparation, a late open, a late event) goes straight to that
/// generation's cleanup and never touches the current recording's output.
///
/// **One ordered bridge per recording.** Both tracks' sessions post into one `LiveWordsBridge`,
/// so the main actor applies events in the order they arrived, across tracks.
///
/// **Cleanup outlives the recording.** It ends every session, joins every pump consumer and every
/// teardown already under way, then frees the Universal model and waits for the physical free.
/// Each piece runs on its own, so one hung end or feed never delays another session's end. Until
/// all of it finishes, a new recording that would need the same engine records normally with its
/// live words off (`.previousStillClosing`) and allocates nothing.
@MainActor
@Observable
final class MeetingLiveWords {

  // MARK: - Output

  enum OffReason: Equatable, Sendable {
    /// This track is not being recorded.
    case notCaptured
    /// #4105: no live words engine and language are chosen, and no ready one could be guessed.
    /// The note points to EnviousMeet > Models > Live words.
    case notSetUp
    /// #4105: the chosen engine has no model for the chosen language on this Mac; nothing is
    /// downloaded for it, and no other engine is used instead.
    case engineNotDownloaded(engine: EngineKind, languageName: String)
    /// The previous recording's resources for this engine are still being freed.
    case previousStillClosing
    /// The engine could not be prepared or the session could not open.
    case couldNotStart
    /// The Universal model is being removed (Dictation Settings, Live Preview).
    case modelBeingRemoved
    /// Any other refusal.
    case unavailable
  }

  enum StopReason: Equatable, Sendable {
    /// The engine ended the track on its own (`.ended(.failed)`).
    case engineFailed
    /// An Apple restart's old session did not finish within its deadline (decision 17).
    case restartTimedOut
    /// An Apple restart's replacement session could not open.
    case restartFailed
    /// The Universal model's removal began while this track ran on it.
    case modelRemoved
  }

  enum Status: Equatable, Sendable {
    case starting
    case running
    case off(OffReason)
    case stopped(StopReason)
  }

  struct TrackState: Equatable, Sendable {
    var status: Status
    /// Some live audio never reached the engine (a busy capture lock, or a slow engine whose
    /// oldest buffered audio was evicted).
    var droppedAudio = false
  }

  struct Transcript: Equatable {
    let meetingID: UUID
    var lines: [LiveWordsAssembler.Line] = []
    var tracks: [MeetingTrackKind: TrackState] = [:]
  }

  /// The recording meeting's live words, kept after Stop until its transcript is ready.
  private(set) var transcript: Transcript?

  // MARK: - Dependencies

  enum EngineKind: Hashable, Sendable {
    case apple
    case universal
  }

  /// The Universal route as the owner consumes it (`WhisperPreviewEngineResolver.resolveForMeeting`
  /// in the app; a fake in tests).
  enum UniversalResolution: Sendable {
    case ready(
      makeEngine: @Sendable (@escaping @Sendable () async throws -> Void) -> any MeetingSharedEngine
    )
    case blocked(LivePreviewUnavailability)
  }

  struct Dependencies {
    /// #4105: the meeting's live words choice, frozen once per recording: the stored engine and
    /// language (`MeetingLiveWordsChoice.Initializer`, which saves a first ready guess), or with an
    /// engine forced by the DEBUG door. Never downloads.
    var resolveChoice: @MainActor (_ forcing: LivePreviewEngineChoice?) async ->
      MeetingLiveWordsChoice.Resolution
    /// Apple's meeting module for an exact language tag
    /// (`ApplePreviewEngineResolver.resolveMeeting`).
    var resolveApple: @Sendable (String) async -> LivePreviewEngineResolution
    var resolveUniversal: @Sendable (LanguageMode) async -> UniversalResolution
    /// True while dictation's engine decodes continuously: each Universal decode then waits its
    /// turn (a temporary refusal the engine retries), never the meeting's readiness.
    var isHeartStreaming: @Sendable () async -> Bool
    var makePump: () -> MeetingLiveAudioPump = { MeetingLiveAudioPump() }
    /// How often the dropped-audio flag is refreshed while recording, events or not.
    var droppedCheckInterval: Duration = .milliseconds(500)
    /// Decision 17: an Apple session restarts after this much audio fed to it (600 s at 16 kHz),
    /// at the first 100 ms window quieter than `restartQuietRMS`.
    var appleRestartAfterSamples = 600 * 16_000
    var restartQuietRMS: Float = 0.001
    /// How long a restart waits for the old session's end before stopping the track instead.
    var restartEndDeadline: Double = 5
    /// Between Universal preparation tries while dictation's engine holds the executor.
    var universalRetryDelay: Duration = .seconds(2)
  }

  /// A Universal decode refused for now, retried by the engine.
  struct HeartStreaming: Error {}

  private let deps: Dependencies

  /// #4105: the one owner of the stored live words choice and its first guess. Meeting Start
  /// reaches it through `deps.resolveChoice`; the Live words row reads the same instance here.
  let choiceOwner: MeetingLiveWordsChoice.Initializer?

  init(dependencies: Dependencies, choiceOwner: MeetingLiveWordsChoice.Initializer? = nil) {
    self.deps = dependencies
    self.choiceOwner = choiceOwner
  }

  // MARK: - Recording state

  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var recording: Recording?
  /// Cleanups still running, by engine; their engine refuses a new recording until they finish.
  @ObservationIgnored private var closing: [EngineKind: Int] = [:]
  @ObservationIgnored private var cleanups: [ObjectIdentifier: Cleanup] = [:]
  /// Between `beginModelRemoval` and `endModelRemoval`: no Universal engine is made or opened.
  @ObservationIgnored private var removingUniversal = false
  /// Counts removals begun. A Universal readiness read before a removal began is stale after it,
  /// even once the removal has ended (the model it named may be gone).
  @ObservationIgnored private var removalEpoch = 0

  private final class TrackSlot {
    let pump: MeetingLiveAudioPump
    /// The current session's epoch in the bridge (0 before the first open).
    var epoch = 0
    var session: (any LivePreviewEngineSession)? {
      didSet { target.set(session, epoch: epoch) }
    }
    /// What the pump's consumer feeds: the current session and its epoch.
    let target = SessionTarget()
    /// Off or stopped: nothing more opens or runs on this track in this recording.
    var finished = false
    /// An Apple restart is between ending the old session and installing the replacement.
    var restarting = false
    /// Stop came during that restart (#4248): the restart still opens the replacement, outside
    /// the recording, so the sealed pump's held audio reaches it before it ends.
    var drainAfterStop = false
    init(pump: MeetingLiveAudioPump) { self.pump = pump }
  }

  private final class Recording {
    let generation: Int
    let meetingID: UUID
    var tracks: [MeetingTrackKind: TrackSlot]
    var bridge: LiveWordsBridge?
    var engine: EngineKind?
    /// #4105: the language the frozen choice runs in (DEBUG door, diagnostics).
    var language: String?
    var apple: [MeetingTrackKind: any LivePreviewEngine] = [:]
    var universal: (any MeetingSharedEngine)?
    var vocabulary: LivePreviewVocabulary?
    var assembler = LiveWordsAssembler()
    var start: Task<Leftovers, Never>?
    /// The start has returned: no open is pending, every handle it got is installed or ending.
    var startSettled = false
    /// Teardown already under way while the meeting continues (a failed track's end, a late
    /// handle's end, an unusable engine's release); cleanup joins every one.
    var endings: [Task<Void, Never>] = []
    /// Pump consumers retired before the recording ended; cleanup joins them.
    var consumers: [Task<Void, Never>] = []
    var drain: Task<Void, Never>?
    var monitor: Task<Void, Never>?
    init(generation: Int, meetingID: UUID, tracks: [MeetingTrackKind: TrackSlot]) {
      self.generation = generation
      self.meetingID = meetingID
      self.tracks = tracks
    }
  }

  /// What a start created but could not hand to its recording (it ended meanwhile).
  struct Leftovers: Sendable {
    var sessions: [any LivePreviewEngineSession] = []
    var universal: (any MeetingSharedEngine)?
  }

  // MARK: - Capture

  /// Builds both tracks' pumps for a new recording and returns the recorder's observer. Call
  /// before `MeetingRecorder.start()`, so live audio is buffered from the first sample; engines
  /// start only from `captureStarted`.
  func prepareCapture(meetingID: UUID) -> MeetingRecorder.LiveSamplesObserver {
    retireCurrent(clearOutput: false)
    generation += 1
    let mic = TrackSlot(pump: deps.makePump())
    let call = TrackSlot(pump: deps.makePump())
    recording = Recording(
      generation: generation, meetingID: meetingID,
      tracks: [.microphone: mic, .callSound: call])
    transcript = Transcript(
      meetingID: meetingID,
      tracks: [.microphone: .init(status: .starting), .callSound: .init(status: .starting)])
    let micPump = mic.pump
    let callPump = call.pump
    // Capture thread (call sound) or the microphone writer's queue: the pump copies and
    // returns; nothing else runs here. The chunk metadata (#4248) is not used: a session is fed
    // samples only (`LivePreviewEngineSession.feed`), and display times come from the meeting
    // clock (`LiveWordsAssembler`), so live words had no use for capture times or run breaks
    // before the hold either.
    return { track, samples, _ in
      switch track {
      case .microphone: micPump.admit(samples)
      case .callSound: callPump.admit(samples)
      }
    }
  }

  /// Capture could not start: retire the pumps; no engine is resolved.
  func captureFailed(meetingID: UUID) {
    guard let current = recording, current.meetingID == meetingID else { return }
    retireCurrent(clearOutput: true)
  }

  /// Capture started on `captured` tracks. Resolves the engine (never a download), prepares it
  /// and opens one transcript session per captured track. The live words choice (read once in
  /// `start`), `vocabulary` and `clock` are this recording's, frozen: nothing re-reads a setting
  /// later.
  func captureStarted(
    meetingID: UUID, captured: Set<MeetingTrackKind>,
    vocabulary: LivePreviewVocabulary, clock: @escaping @Sendable () -> Int
  ) {
    guard let current = recording, current.meetingID == meetingID, current.start == nil else {
      return
    }
    for (kind, slot) in current.tracks where !captured.contains(kind) {
      retirePump(slot, in: current)
      setStatus(.off(.notCaptured), kind)
    }
    current.tracks = current.tracks.filter { captured.contains($0.key) }
    let (stream, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    current.bridge = LiveWordsBridge(clock: clock, wake: { wake.yield() })
    let gen = current.generation
    // A fixed order (microphone, then call sound), so engines and sessions are made predictably.
    let tracks = MeetingTrackKind.allCases.filter { current.tracks[$0] != nil }
    current.drain = Task { [weak self] in
      for await _ in stream { self?.drainEvents(generation: gen) }
    }
    let interval = deps.droppedCheckInterval
    current.monitor = Task { [weak self] in
      while !Task.isCancelled {
        self?.refreshDropped(generation: gen)
        try? await Task.sleep(for: interval)
      }
    }
    current.vocabulary = vocabulary
    var forcing: LivePreviewEngineChoice?
    #if DEBUG
      forcing = debugEngineOverrideNextRecording
      debugEngineOverrideNextRecording = nil
    #endif
    current.start = Task { [weak self, forcing] in
      guard let self else { return Leftovers() }
      let leftovers = await self.start(
        generation: gen, tracks: tracks, vocabulary: vocabulary, forcing: forcing)
      self.startSettled(generation: gen)
      return leftovers
    }
  }

  // MARK: - Exits

  /// Stop: applies the events already accepted, invalidates the recording and starts its
  /// cleanup. Returns at once. Call it after the recorder stopped, so the microphone's held tail
  /// is already in the pump (#4248): each track's pump is sealed and its consumer feeds every
  /// sample it holds, in order, before that track's session ends; tracks drain independently.
  /// What the sessions still deliver while they end (the Universal engine's queued finals, each
  /// session's terminal) is applied by that cleanup while these lines are still this meeting's
  /// (#4097); the cleanup then closes admission. The lines stay until `transcriptReady`.
  func stop() {
    retireCurrent(clearOutput: false, drainHeldAudio: true)
  }

  /// Delete: the same, and the live words go now.
  func delete(meetingID: UUID) {
    if recording?.meetingID == meetingID { retireCurrent(clearOutput: true) }
    if transcript?.meetingID == meetingID { transcript = nil }
  }

  /// Quit: the same retirement as Stop. The process exit frees any native model left
  /// (`TranscribeCppProcessExit`).
  func quit() {
    retireCurrent(clearOutput: false)
  }

  /// The meeting's final transcript replaced the live words.
  func transcriptReady(meetingID: UUID) {
    guard recording == nil || recording?.meetingID != meetingID else { return }
    if transcript?.meetingID == meetingID { transcript = nil }
  }

  // MARK: - Universal model removal (plan §3.2)

  /// Removal of the Universal model begins. Synchronous: from here no Universal engine is made,
  /// prepared or opened for a meeting, and a recording whose live words use it hands its
  /// sessions, pending start, pump consumers and model to a cleanup now. The recording goes on;
  /// its accepted words stay; Apple live words are untouched. Idempotent.
  func beginModelRemoval() {
    if !removingUniversal { removalEpoch += 1 }
    removingUniversal = true
    guard let current = recording, current.engine == .universal else { return }
    let final = current.bridge?.closeAllAndTake() ?? []
    apply(final, to: current)
    var sessions: [any LivePreviewEngineSession] = []
    for (track, slot) in current.tracks where !slot.finished {
      slot.finished = true
      // A pending open returns into a new epoch, so its handle goes to the start's leftovers,
      // which the cleanup ends.
      slot.epoch += 1
      retirePump(slot, in: current)
      if let session = slot.session { sessions.append(session) }
      slot.session = nil
      setStatus(.stopped(.modelRemoved), track)
    }
    hand(
      Cleanup(
        sessions: sessions, joins: current.endings + current.consumers, start: current.start,
        universal: current.universal),
      engine: .universal)
    current.endings = []
    current.consumers = []
    current.start = nil
    current.universal = nil
    // Everything Universal is in that cleanup; a later Stop of this recording holds nothing, so
    // it must not refuse the next recording's engine meanwhile.
    current.engine = nil
  }

  /// Returns once every meeting cleanup that holds the Universal engine has physically freed it
  /// (sessions ended, pending work joined, the model released). Never bounded: removal deletes
  /// the files only after this returns.
  func drainForModelRemoval() async {
    let tasks = cleanups.values.filter { $0.engine == .universal }.map(\.task)
    for task in tasks { await task.value }
  }

  /// Removal is over (the files are gone, or the delete was refused): a later recording resolves
  /// the Universal engine again from what is installed. The current recording keeps its state.
  func endModelRemoval() {
    removingUniversal = false
  }

  /// Waits for every running cleanup, at most `seconds`. True when all finished; false leaves
  /// them running (they still free everything, and their engines stay refused until then).
  func waitForCleanups(seconds: Double) async -> Bool {
    let tasks = cleanups.values.map(\.task)
    let finished = await withDeadline(seconds: seconds) {
      for task in tasks { await task.value }
      return true
    }
    return finished == true
  }

  /// The engine the recording meeting's live words use, once chosen (diagnostics, DEBUG door).
  var currentEngine: EngineKind? { recording?.engine }

  /// The language the recording meeting's live words run in, once chosen (DEBUG door).
  var currentLanguage: String? { recording?.language }

  #if DEBUG
    /// #4254 UAT evidence (DEBUG door): each captured track's session epoch and its speech
    /// detection report. Every entry is checked again after ALL reads: a recording that changed
    /// meanwhile gives no reports, and a track whose slot, epoch or session changed gives nil
    /// (unknown, never evidence). A session without detection also gives nil.
    func detectionReports() async -> [MeetingTrackKind: (epoch: Int, report: LiveDetectionReport?)] {
      guard let current = recording else { return [:] }
      var read: [(track: MeetingTrackKind, slot: TrackSlot, epoch: Int, session: ObjectIdentifier?,
        report: LiveDetectionReport?)] = []
      for (track, slot) in current.tracks {
        let epoch = slot.epoch
        guard let session = slot.session else {
          read.append((track, slot, epoch, nil, nil))
          continue
        }
        read.append(
          (track, slot, epoch, ObjectIdentifier(session as AnyObject), await session.detectionReport()))
      }
      guard recording === current else { return [:] }
      var reports: [MeetingTrackKind: (epoch: Int, report: LiveDetectionReport?)] = [:]
      for entry in read {
        let unchanged =
          current.tracks[entry.track] === entry.slot && entry.slot.epoch == entry.epoch
          && entry.slot.session.map { ObjectIdentifier($0 as AnyObject) } == entry.session
        reports[entry.track] = (entry.epoch, unchanged ? entry.report : nil)
      }
      return reports
    }
  #endif

  #if DEBUG
    /// DEBUG door only (`meeting start --live-engine apple|universal`, runtime UAT): the next
    /// recording uses this engine with the stored language matched to it, never storing it and
    /// never downloading. Consumed by that recording's `captureStarted`, and cleared by the door
    /// when a Start is refused, so it never outlives one attempt.
    var debugEngineOverrideNextRecording: LivePreviewEngineChoice?
  #endif

  /// A Universal model removal is in progress (tests and diagnostics).
  var isRemovingUniversal: Bool { removingUniversal }

  /// Engines a new recording cannot use yet (tests and diagnostics).
  var closingEngines: Set<EngineKind> { Set(closing.filter { $0.value > 0 }.keys) }

  // MARK: - Start

  private func isCurrent(_ gen: Int) -> Bool { recording?.generation == gen }

  private func start(
    generation gen: Int, tracks: [MeetingTrackKind],
    vocabulary: LivePreviewVocabulary, forcing: LivePreviewEngineChoice? = nil
  ) async -> Leftovers {
    var leftovers = Leftovers()
    // The removal state over the whole resolution: what it was when the read began, and the epoch
    // that any removal crossing the read changes.
    let removingAtResolve = removingUniversal
    let epochAtResolve = removalEpoch
    // #4105: the choice is frozen here, once, for both tracks and every restart of this recording.
    let frozen = await deps.resolveChoice(forcing)
    guard isCurrent(gen) else { return leftovers }
    let choice = await resolve(frozen)
    guard isCurrent(gen), let current = recording else { return leftovers }
    switch choice {
    case .off(let reason):
      for track in tracks { finishTrack(track, .off(reason), in: current) }
      return leftovers
    case .apple(let candidate):
      guard (closing[.apple] ?? 0) == 0 else {
        for track in tracks { finishTrack(track, .off(.previousStillClosing), in: current) }
        return leftovers
      }
      current.engine = .apple
      for track in tracks { current.apple[track] = candidate.makeEngine() }
      for track in tracks {
        guard let engine = current.apple[track] else { continue }
        do {
          try await engine.prepare()
        } catch {
          guard isCurrent(gen) else { return leftovers }
          finishTrack(track, .off(.couldNotStart), in: current)
          continue
        }
        guard isCurrent(gen) else { return leftovers }
        await open(
          track, on: engine, generation: gen, vocabulary: vocabulary,
          leftovers: &leftovers)
        guard isCurrent(gen) else { return leftovers }
      }
    case .universal(let makeEngine):
      // No engine from a readiness read that began during a removal, returned during one, or that
      // a removal crossed (the recording keeps its live words off; a later recording resolves
      // afresh). Checked in the same main-actor step that allocates.
      guard !removingAtResolve, !removingUniversal, removalEpoch == epochAtResolve else {
        for track in tracks { finishTrack(track, .off(.modelBeingRemoved), in: current) }
        return leftovers
      }
      guard (closing[.universal] ?? 0) == 0 else {
        for track in tracks { finishTrack(track, .off(.previousStillClosing), in: current) }
        return leftovers
      }
      let heart = deps.isHeartStreaming
      let engine = makeEngine { if await heart() { throw HeartStreaming() } }
      current.engine = .universal
      current.universal = engine
      // A load refused because dictation's engine holds the executor is tried again while this
      // recording lasts; the tracks stay starting meanwhile. Any other failure is final.
      while true {
        do {
          try await engine.prepare()
          break
        } catch {
          guard isCurrent(gen) else { return leftovers }
          guard engine.isTemporary(error) else {
            for track in tracks { finishTrack(track, .off(.couldNotStart), in: current) }
            return leftovers
          }
        }
        // settle: a backoff between tries; the executor signals nothing when the heart lets go.
        try? await Task.sleep(for: deps.universalRetryDelay)
        // A Stop, Delete, Quit or Universal removal meanwhile owns the engine now.
        guard isCurrent(gen), tracks.contains(where: { current.tracks[$0]?.finished == false })
        else { return leftovers }
      }
      guard isCurrent(gen) else { return leftovers }
      for track in tracks {
        await open(
          track, on: engine.recognizer, generation: gen, vocabulary: vocabulary,
          leftovers: &leftovers)
        guard isCurrent(gen) else { return leftovers }
      }
    }
    return leftovers
  }

  private enum Choice {
    case apple(LivePreviewEngineCandidate)
    case universal(
      @Sendable (@escaping @Sendable () async throws -> Void) -> any MeetingSharedEngine)
    case off(OffReason)
  }

  /// #4105: the frozen choice's engine, or off with the reason the note names. The chosen engine
  /// only: a choice that cannot run here leaves live words off (the recording continues), never
  /// another engine and never Apple's dictation module (founder, decisions file item 18).
  private func resolve(_ frozen: MeetingLiveWordsChoice.Resolution) async -> Choice {
    switch frozen {
    case .notSetUp:
      return .off(.notSetUp)
    case .notDownloaded(let engine, let language):
      return .off(
        .engineNotDownloaded(engine: Self.kind(engine), languageName: Self.languageName(language)))
    case .ready(.apple, let tag):
      recording?.language = tag
      switch await deps.resolveApple(tag) {
      case .ready(let candidate): return .apple(candidate)
      case .blocked(.installRequired(let name)):
        return .off(.engineNotDownloaded(engine: .apple, languageName: name))
      case .blocked(.unsupportedSystem), .blocked(.unsupportedLanguage):
        return .off(.notSetUp)
      case .blocked:
        return .off(.unavailable)
      }
    case .ready(.universal, let code):
      recording?.language = code
      switch await deps.resolveUniversal(.locked(code)) {
      case .ready(let makeEngine): return .universal(makeEngine)
      case .blocked(.modelNotInstalled):
        return .off(
          .engineNotDownloaded(engine: .universal, languageName: Self.languageName(code)))
      case .blocked:
        return .off(.unavailable)
      }
    }
  }

  private static func kind(_ engine: LivePreviewEngineChoice) -> EngineKind {
    switch engine {
    case .apple: .apple
    case .universal: .universal
    }
  }

  /// A language tag or code as the user reads it (`French (Canada)`, `German`).
  static func languageName(_ tag: String) -> String {
    ApplePackCatalog.localizedName(for: tag)
  }

  private func open(
    _ track: MeetingTrackKind, on engine: any LivePreviewEngine, generation gen: Int,
    vocabulary: LivePreviewVocabulary, leftovers: inout Leftovers
  ) async {
    guard let current = recording, let slot = current.tracks[track], let bridge = current.bridge,
      !slot.finished
    else { return }
    // The epoch opens before the session does, so events the engine sends before `open`
    // returns are this session's; anything posted under another epoch is refused.
    slot.epoch += 1
    let epoch = slot.epoch
    bridge.openEpoch(epoch, for: track)
    let session: any LivePreviewEngineSession
    do {
      session = try await engine.openTranscriptSession(
        vocabulary: vocabulary,
        onEvent: { event in bridge.post(event, track: track, epoch: epoch) })
    } catch {
      guard isCurrent(gen) else { return }
      finishTrack(track, .off(.couldNotStart), in: current)
      return
    }
    guard isCurrent(gen), recording?.tracks[track] === slot, slot.epoch == epoch else {
      leftovers.sessions.append(session)  // ended once by this generation's cleanup
      return
    }
    // The engine already ended this track (an early terminal event): end the handle now.
    guard !slot.finished else {
      endNow(session, in: current)
      return
    }
    slot.session = session
    let target = slot.target
    let feed: @Sendable ([Float]) async -> Void
    if current.engine == .apple {
      feed = restartingFeed(track, generation: gen, target: target)
    } else {
      feed = { chunk in
        if let session = target.current?.session { await session.feed(chunk) }
      }
    }
    guard slot.pump.startConsumer(feed: feed) else {
      slot.session = nil
      endNow(session, in: current)
      finishTrack(track, .off(.couldNotStart), in: current)
      return
    }
    setStatus(.running, track)
  }

  // MARK: - Apple restart (decision 17)

  /// The pump consumer's feed for an Apple track. It counts the audio fed to the current
  /// session; once that passes `appleRestartAfterSamples`, the first 100 ms window under
  /// `restartQuietRMS` ends that session's feeding there, the restart runs (this consumer waits,
  /// so the pump keeps buffering), and the rest of the chunk and everything after it goes to the
  /// replacement. Every sample is fed once, in order.
  private func restartingFeed(
    _ track: MeetingTrackKind, generation gen: Int, target: SessionTarget
  ) -> @Sendable ([Float]) async -> Void {
    let feeder = RestartFeeder(
      meter: RestartMeter(threshold: deps.appleRestartAfterSamples, quietRMS: deps.restartQuietRMS))
    return { [weak self] chunk in
      let owner = self
      await feeder.run(
        chunk,
        send: { part in
          guard let current = target.current else { return false }  // the track stopped
          await current.session.feed(part)
          return true
        },
        restart: {
          guard let epoch = target.current?.epoch else { return }
          await owner?.restartTrack(track, generation: gen, epoch: epoch)
        })
    }
  }

  /// Ends the track's session, waits for it at most `restartEndDeadline`, applies what it
  /// delivered (its `.ended` freezes the words still in progress as uncertain), then opens a
  /// new session on the same recognizer under a new epoch. A timeout closes the old epoch,
  /// freezes its words in progress and stops the track; the old end stays owned by the
  /// recording's teardown until it physically returns, and no second analyzer is opened.
  private func restartTrack(_ track: MeetingTrackKind, generation gen: Int, epoch: Int) async {
    guard isCurrent(gen), let current = recording, let slot = current.tracks[track],
      slot.epoch == epoch, !slot.finished, let old = slot.session,
      let engine = current.apple[track], let vocabulary = current.vocabulary,
      let bridge = current.bridge
    else { return }
    slot.session = nil  // nothing more is fed to the old session
    slot.restarting = true
    defer { slot.restarting = false }
    let ending = Task { await old.end() }
    current.endings.append(ending)
    let ended = await withDeadline(seconds: deps.restartEndDeadline) { await ending.value }
    // #4248: a Stop during the restart sealed this track's pump and waits for this consumer; the
    // held audio still needs a session. The replacement opens outside the recording and is
    // handed to the Stop's drain through the track's target, which ends it after the drain.
    if slot.drainAfterStop, slot.epoch == epoch {
      guard ended != nil else { return }  // the old end timed out: no second analyzer
      // The old session's finals are accepted by now: apply them before the epoch moves on,
      // and only while these lines are still this meeting's.
      let finalEntries = bridge.take()
      if transcript?.meetingID == current.meetingID {
        apply(finalEntries, to: current)
      }
      slot.epoch += 1
      let next = slot.epoch
      bridge.openEpoch(next, for: track)
      guard
        let session = try? await engine.openTranscriptSession(
          vocabulary: vocabulary, onEvent: { event in bridge.post(event, track: track, epoch: next) })
      else { return }
      slot.target.set(session, epoch: next)
      return
    }
    guard isCurrent(gen), recording?.tracks[track] === slot, slot.epoch == epoch, !slot.finished
    else { return }
    guard ended != nil else {
      bridge.close(track)  // late events from the old session are refused
      drainEvents(generation: gen)
      current.assembler.apply(.discontinuity, track: track, atMs: bridge.now())
      transcript?.lines = current.assembler.lines
      finishTrack(track, .stopped(.restartTimedOut), in: current)
      return
    }
    // The old session's finals (and its `.ended`) are all accepted by now: apply them before
    // the epoch moves on.
    drainEvents(generation: gen)
    guard !slot.finished else { return }
    slot.epoch += 1
    let next = slot.epoch
    bridge.openEpoch(next, for: track)
    let session: any LivePreviewEngineSession
    do {
      session = try await engine.openTranscriptSession(
        vocabulary: vocabulary,
        onEvent: { event in bridge.post(event, track: track, epoch: next) })
    } catch {
      // The track had been running: its live words stop here (no retry in this meeting).
      guard isCurrent(gen) else { return }
      finishTrack(track, .stopped(.restartFailed), in: current)
      return
    }
    guard isCurrent(gen), recording?.tracks[track] === slot, slot.epoch == next, !slot.finished
    else {
      // #4248: a Stop during this open drains the held audio into the replacement, which the
      // Stop's drain then ends.
      if slot.drainAfterStop {
        slot.target.set(session, epoch: next)
        return
      }
      // Stopped meanwhile: this consumer is joined by the recording's cleanup, so ending the
      // late handle here is owned until it returns.
      await session.end()
      return
    }
    slot.session = session
  }

  // MARK: - Track endings

  /// The track runs no more in this recording: its bridge epoch closes, its pump retires, its
  /// session (if any) is ended now, and once no track is live an unusable Universal engine is
  /// released while the meeting continues.
  private func finishTrack(_ track: MeetingTrackKind, _ status: Status, in current: Recording) {
    guard let slot = current.tracks[track], !slot.finished else { return }
    slot.finished = true
    current.bridge?.close(track)
    retirePump(slot, in: current)
    if let session = slot.session {
      slot.session = nil
      endNow(session, in: current)
    }
    current.apple[track] = nil
    setStatus(status, track)
    releaseIfNoTrackIsLive(current)
  }

  /// The start returned (no open pending): an early release may now account for everything.
  private func startSettled(generation gen: Int) {
    guard let current = recording, current.generation == gen else { return }
    current.startSettled = true
    releaseIfNoTrackIsLive(current)
  }

  private func endNow(_ session: any LivePreviewEngineSession, in current: Recording) {
    current.endings.append(Task { await session.end() })
  }

  private func retirePump(_ slot: TrackSlot, in current: Recording) {
    if let consumer = slot.pump.retire() { current.consumers.append(consumer) }
  }

  /// No track can use the Universal engine any more and no open is pending: free it after every
  /// session it served has ended and every pump consumer has exited. Only the start's own exit
  /// and `finishTrack` call this; a pending open returns into `open`, which ends a finished
  /// track's handle before the start settles, so that end is in `endings` here.
  private func releaseIfNoTrackIsLive(_ current: Recording) {
    guard current.startSettled, current.tracks.values.allSatisfy(\.finished),
      let engine = current.universal
    else { return }
    current.universal = nil
    let prior = current.endings + current.consumers
    current.endings.append(
      Task {
        for task in prior { await task.value }
        await engine.beginRelease().value
      })
  }

  private func setStatus(_ status: Status, _ track: MeetingTrackKind) {
    transcript?.tracks[track, default: .init(status: status)].status = status
  }

  // MARK: - Events

  /// Applies the events the bridge accepted, in arrival order across both tracks, for the
  /// current generation only.
  private func drainEvents(generation gen: Int) {
    guard let current = recording, current.generation == gen, let bridge = current.bridge else {
      return
    }
    apply(bridge.take(), to: current)
  }

  private func apply(_ entries: [LiveWordsBridge.Entry], to current: Recording) {
    guard !entries.isEmpty else { return }
    for entry in entries {
      guard let slot = current.tracks[entry.track], slot.epoch == entry.epoch else { continue }
      current.assembler.apply(entry.event, track: entry.track, atMs: entry.atMs)
      if case .ended(.failed) = entry.event {
        finishTrack(entry.track, .stopped(.engineFailed), in: current)
      }
    }
    transcript?.lines = current.assembler.lines
    refreshDropped(generation: current.generation)
  }

  /// Marks each track whose pump dropped live audio; also run on a timer, events or not.
  private func refreshDropped(generation gen: Int) {
    guard let current = recording, current.generation == gen else { return }
    for (track, slot) in current.tracks
    where slot.pump.accounting.dropped > 0 && transcript?.tracks[track]?.droppedAudio == false {
      transcript?.tracks[track]?.droppedAudio = true
    }
  }

  // MARK: - Retirement and cleanup

  /// Applies the accepted events, invalidates the generation and moves every resource into one
  /// cleanup. Synchronous: never waits for preparation, feeds, ends or the native release.
  /// Delete closes admission here; kept output (Stop, Quit) leaves it open for the cleanup,
  /// which applies what the ending sessions deliver and then closes it (#4097).
  ///
  /// `drainHeldAudio` (Stop only): a track with a session seals its pump instead of retiring it,
  /// and its session ends only after the consumer fed everything held. Delete and Quit discard.
  private func retireCurrent(clearOutput: Bool, drainHeldAudio: Bool = false) {
    guard let current = recording else {
      if clearOutput { transcript = nil }
      return
    }
    if clearOutput {
      // One atomic step closes admission and drops everything accepted.
      _ = current.bridge?.closeAllAndTake()
    } else {
      apply(current.bridge?.take() ?? [], to: current)
    }
    recording = nil
    generation += 1
    current.drain?.cancel()
    current.monitor?.cancel()
    var sessions: [any LivePreviewEngineSession] = []
    for slot in current.tracks.values {
      slot.finished = true
      if drainHeldAudio, slot.session != nil || slot.restarting,
        let consumer = slot.pump.seal()
      {
        // Admission closed now; the consumer feeds what is held, then the track's current
        // session ends: the one running now, or the replacement a restart in progress installs
        // in the target (`restartTrack`, #4248). The target stays set until then, so the drain
        // reaches the session.
        if slot.session == nil { slot.drainAfterStop = true }
        let target = slot.target
        current.endings.append(
          Task {
            await consumer.value
            let last = target.current?.session
            target.set(nil, epoch: 0)
            await last?.end()
          })
        continue
      }
      retirePump(slot, in: current)  // admission closed now; a held feed may still finish
      if let session = slot.session { sessions.append(session) }
      slot.session = nil
    }
    if clearOutput { transcript = nil }
    var late: (@MainActor (_ last: Bool) -> Void)?
    if !clearOutput, let bridge = current.bridge {
      late = { [weak self] last in
        // Always take, and close on the last call, even once the lines went (Delete, a ready
        // transcript, the next meeting): nothing reaches another meeting's words.
        let entries = last ? bridge.closeAllAndTake() : bridge.take()
        guard let self, self.transcript?.meetingID == current.meetingID else { return }
        self.apply(entries, to: current)
      }
    }
    hand(
      Cleanup(
        sessions: sessions, joins: current.endings + current.consumers, start: current.start,
        universal: current.universal, late: late),
      engine: current.engine)
    current.endings = []
    current.consumers = []
    current.start = nil
    current.universal = nil
    current.apple = [:]
  }

  /// Runs `cleanup`; its engine refuses a new recording (`.previousStillClosing`) until the
  /// cleanup physically finished.
  private func hand(_ cleanup: Cleanup, engine: EngineKind?) {
    cleanup.engine = engine
    if let engine { closing[engine, default: 0] += 1 }
    let key = ObjectIdentifier(cleanup)
    cleanups[key] = cleanup
    cleanup.run { [weak self] in
      guard let self else { return }
      self.cleanups[key] = nil
      if let engine { self.closing[engine, default: 1] -= 1 }
    }
  }

  /// One retired recording's resources until they are physically gone. The complete population:
  /// the sessions active at retirement, every teardown already under way (failed tracks' ends,
  /// late handles' ends, an early release), every retired pump consumer, the start task and the
  /// sessions it opens late, and the Universal engine (handed over, or created by the start).
  /// For kept output, `late` applies what the sessions deliver while they end: after each end or
  /// join returns, and once more (closing admission) after all of them, before any Universal
  /// release this cleanup starts (an earlier release already under way is joined).
  @MainActor
  final class Cleanup {
    private var sessions: [any LivePreviewEngineSession]
    private var joins: [Task<Void, Never>]
    private var start: Task<Leftovers, Never>?
    private var universal: (any MeetingSharedEngine)?
    private var late: (@MainActor (_ last: Bool) -> Void)?
    private(set) var task: Task<Void, Never> = Task {}
    /// The engine whose resources this cleanup frees (nil when none was chosen).
    fileprivate(set) var engine: EngineKind?

    init(
      sessions: [any LivePreviewEngineSession], joins: [Task<Void, Never>],
      start: Task<Leftovers, Never>?, universal: (any MeetingSharedEngine)?,
      late: (@MainActor (_ last: Bool) -> Void)? = nil
    ) {
      self.sessions = sessions
      self.joins = joins
      self.start = start
      self.universal = universal
      self.late = late
    }

    /// Ends and joins everything at once, each on its own, then frees the Universal model and
    /// waits for the physical free, then `finished`.
    func run(finished: @escaping @MainActor () -> Void) {
      let sessions = self.sessions
      let joins = self.joins
      let start = self.start
      let handed = self.universal
      let late = self.late
      self.sessions = []
      self.joins = []
      self.start = nil
      self.universal = nil
      self.late = nil
      task = Task { @MainActor in
        let created = await withTaskGroup(
          of: (any MeetingSharedEngine)?.self, returning: (any MeetingSharedEngine)?.self
        ) { group in
          // Each end and join is its own child: a hung feed or end never delays another end.
          for session in sessions {
            group.addTask {
              await session.end()
              return nil
            }
          }
          for join in joins {
            group.addTask {
              await join.value
              return nil
            }
          }
          if let start {
            group.addTask {
              let leftovers = await start.value
              await withTaskGroup(of: Void.self) { ends in
                for session in leftovers.sessions { ends.addTask { await session.end() } }
                // One late opening's end never withholds what another delivered.
                for await _ in ends { await late?(false) }
              }
              return leftovers.universal
            }
          }
          var created: (any MeetingSharedEngine)?
          // Every child, nil results included: each end or join may have delivered events.
          for await engine in group {
            if let engine { created = engine }
            late?(false)
          }
          return created
        }
        late?(true)
        if let engine = handed ?? created {
          await engine.beginRelease().value
        }
        finished()
      }
    }
  }
}

/// A recording's transcript events on their way to the main actor, in arrival order across both
/// tracks (#3973 plan §3.3).
///
/// Sessions post from their engines' tasks (one short lock step, never a wait); the owner's
/// single drain task takes everything queued when woken. An update merges into the entry before
/// it only when that entry is the same track's and epoch's update, so the observed interleaving
/// of the two tracks is kept. Each track has a 64 KB queued-text budget (64 bytes per entry plus
/// its UTF-8 text); past it the track's accepted entries stay, one `.ended(.failed("backlog"))`
/// follows them, and that track accepts nothing more. Only a track's open epoch is accepted.
final class LiveWordsBridge: @unchecked Sendable {
  static let budgetPerTrack = 64 * 1024
  static let entryCost = 64

  struct Entry: Sendable, Equatable {
    var track: MeetingTrackKind
    var epoch: Int
    var event: LiveWordsEvent
    /// Meeting clock when it arrived.
    var atMs: Int
  }

  private struct State {
    var entries: [Entry] = []
    var bytes: [MeetingTrackKind: Int] = [:]
    var open: [MeetingTrackKind: Int] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let clock: @Sendable () -> Int
  private let wake: @Sendable () -> Void

  init(clock: @escaping @Sendable () -> Int, wake: @escaping @Sendable () -> Void) {
    self.clock = clock
    self.wake = wake
  }

  /// The meeting clock, as events are stamped with it.
  func now() -> Int { clock() }

  /// Accepts `epoch` for `track` from now on (closing the track's previous epoch).
  func openEpoch(_ epoch: Int, for track: MeetingTrackKind) {
    state.withLock { $0.open[track] = epoch }
  }

  func close(_ track: MeetingTrackKind) {
    state.withLock { $0.open[track] = nil }
  }

  /// Closes every track and returns everything accepted so far, in one lock step: an event is
  /// either in this batch or refused.
  func closeAllAndTake() -> [Entry] {
    state.withLock { s in
      s.open = [:]
      defer {
        s.entries = []
        s.bytes = [:]
      }
      return s.entries
    }
  }

  /// True when the event was accepted (it will be delivered or returned by `closeAllAndTake`).
  @discardableResult
  func post(_ event: LiveWordsEvent, track: MeetingTrackKind, epoch: Int) -> Bool {
    let atMs = clock()
    let accepted = state.withLock { s -> Bool in
      guard s.open[track] == epoch else { return false }
      let used = s.bytes[track, default: 0]
      if case .update(let finalized, let inProgress) = event,
        let last = s.entries.last, last.track == track, last.epoch == epoch,
        case .update(let earlier, let replaced) = last.event
      {
        // Joined as the assembler joins two updates' finals, so a merge never runs words together.
        let merged = LiveWordsAssembler.join(earlier, finalized)
        let bytes =
          used + merged.utf8.count - earlier.utf8.count + inProgress.utf8.count
          - replaced.utf8.count
        guard bytes <= Self.budgetPerTrack else {
          return Self.overflow(&s, track: track, epoch: epoch, atMs: atMs)
        }
        s.entries[s.entries.count - 1] = Entry(
          track: track, epoch: epoch,
          event: .update(finalized: merged, inProgress: inProgress), atMs: atMs)
        s.bytes[track] = bytes
        return true
      }
      let bytes = used + Self.cost(event)
      guard bytes <= Self.budgetPerTrack else {
        return Self.overflow(&s, track: track, epoch: epoch, atMs: atMs)
      }
      s.entries.append(Entry(track: track, epoch: epoch, event: event, atMs: atMs))
      s.bytes[track] = bytes
      if case .ended = event { s.open[track] = nil }
      return true
    }
    if accepted { wake() }
    return accepted
  }

  /// Everything queued, in arrival order.
  func take() -> [Entry] {
    state.withLock { s in
      defer {
        s.entries = []
        s.bytes = [:]
      }
      return s.entries
    }
  }

  private static func cost(_ event: LiveWordsEvent) -> Int {
    switch event {
    case .update(let finalized, let inProgress):
      entryCost + finalized.utf8.count + inProgress.utf8.count
    case .discontinuity, .ended: entryCost
    }
  }

  private static func overflow(
    _ s: inout State, track: MeetingTrackKind, epoch: Int, atMs: Int
  ) -> Bool {
    s.entries.append(
      Entry(track: track, epoch: epoch, event: .ended(.failed("backlog")), atMs: atMs))
    s.open[track] = nil
    return true
  }
}

/// What a track's pump consumer feeds: the current session and its bridge epoch.
final class SessionTarget: @unchecked Sendable {
  struct Current {
    let session: any LivePreviewEngineSession
    let epoch: Int
  }
  private let state = OSAllocatedUnfairLock<Current?>(initialState: nil)
  var current: Current? { state.withLock { $0 } }
  func set(_ session: (any LivePreviewEngineSession)?, epoch: Int) {
    let value = session.map { Current(session: $0, epoch: epoch) }
    state.withLock { $0 = value }
  }
}

/// Decision 17's trigger for one track, used only by that track's pump consumer. It counts the
/// samples fed to the current session and, from the threshold on, measures consecutive 100 ms
/// windows across feeds (a window may span several chunks), so the restart point does not depend
/// on how the pump happens to divide the audio.
final class RestartMeter: @unchecked Sendable {
  static let window = 1_600  // 100 ms at 16 kHz
  private let threshold: Int
  private let quietRMS: Float
  private var fedSamples = 0
  private var windowFill = 0
  private var windowSquares: Float = 0

  init(threshold: Int, quietRMS: Float) {
    self.threshold = threshold
    self.quietRMS = quietRMS
  }

  /// A new session: count from zero again.
  func reset() {
    fedSamples = 0
    windowFill = 0
    windowSquares = 0
  }

  /// Consumes `chunk[start...]` and returns the index just past the first quiet window that
  /// completes in it (the restart point), or nil when none does. Everything up to the returned
  /// index (or the whole rest) counts as fed.
  func advance(through chunk: [Float], from start: Int) -> Int? {
    var i = start
    while i < chunk.count {
      if fedSamples < threshold {
        let n = min(threshold - fedSamples, chunk.count - i)
        fedSamples += n
        i += n
        continue
      }
      windowSquares += chunk[i] * chunk[i]
      windowFill += 1
      fedSamples += 1
      i += 1
      if windowFill == Self.window {
        let quiet = (windowSquares / Float(Self.window)).squareRoot() < quietRMS
        windowFill = 0
        windowSquares = 0
        if quiet { return i }
      }
    }
    return nil
  }
}

/// Feeds one Apple track's chunks: up to the meter's restart point to the current session, then
/// the restart, then the rest to whichever session is current afterwards. Every sample is sent
/// once, in order; `send` returns false once the track has no session (it stopped).
final class RestartFeeder: @unchecked Sendable {
  private let meter: RestartMeter

  init(meter: RestartMeter) { self.meter = meter }

  func run(
    _ chunk: [Float], send: @Sendable ([Float]) async -> Bool,
    restart: @Sendable () async -> Void
  ) async {
    var start = 0
    while start < chunk.count {
      let quietEnd = meter.advance(through: chunk, from: start)
      let end = quietEnd ?? chunk.count
      if end > start {
        guard await send(Array(chunk[start..<end])) else { return }
      }
      start = end
      guard quietEnd != nil else { return }
      meter.reset()
      await restart()
    }
  }
}
