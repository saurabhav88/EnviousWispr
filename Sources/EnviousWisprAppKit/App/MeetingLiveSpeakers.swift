import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLivePreview
import Foundation
import Observation
import os

/// What the meeting needs from a live speaker analysis (`LiveSpeakerSession` in production; a
/// fake in tests). Every call is nonisolated and returns at once.
protocol LiveSpeakerAnalysis: Sendable {
  func start()
  func submit(_ chunk: MeetingLiveAudioChunk)
  func reset()
  func close()
}

extension LiveSpeakerSession: LiveSpeakerAnalysis {}

/// Which live call pieces belong to which "Speaker N" (#4355 PR C plan §3.3), for the meeting
/// that is recording. Absent: every call piece is unresolved ("Speaker").
struct MeetingLiveSpeakerLabels: Sendable, Equatable {
  /// Settled remote pieces, by their written span, to their speaker number (1-based, by first
  /// settled appearance in this meeting; numbering continues across resets).
  var numbers: [MeetingAudioSpan: Int] = [:]
  /// Bumped once per applied batch that settled at least one piece to a speaker (the live view
  /// announces each bump once).
  var revision = 0

  func key(for piece: MeetingTimedPiece, track: MeetingTrackKind)
    -> LiveWordsAssembler.LiveSpeakerKey
  {
    switch track {
    case .microphone: return .you
    case .callSound:
      guard let span = piece.span, let number = numbers[span] else { return .unresolved }
      return .remote(String(number))
    }
  }
}

/// #4355 PR C: the recording meeting's live speaker labels. Owns the speaker analysis lifecycle
/// for one recording and the evidence it publishes; never transcription or DSP. The analysis
/// (`LiveSpeakerSession`) owns inference and the physical model release.
///
/// - Model: read once per meeting through the admitted-folder door; absent, it stays absent for
///   that meeting (a download that finishes mid-meeting is used by the next one). A Settings
///   check or the previous meeting's analysis that is still releasing is waited for first, so two
///   copies never load. Recording never waits for any of this.
/// - Audio: the call track's written audio reaches the analysis through its own bounded pump
///   (one consumer), fed once per bank whatever the live-words engine does. A writer run change
///   resets the analysis (new epoch).
/// - Dictation first: the analysis asks `admit` before each step; it answers from a lock-held
///   copy of "dictation is active" (recording, transcribing or polishing on either engine),
///   updated on the main actor.
/// - Labels: each finalized call piece is assigned by `LiveSpeakerJoiner`; a piece settles when
///   it is assigned, or when final evidence passed its end without assigning it. Settled pieces
///   never change; evidence no pending piece needs is pruned.
@MainActor
final class MeetingLiveSpeakers {
  enum ModelState: Equatable, Sendable {
    case absent
    case loading
    case ready
    case failed
  }

  struct Dependencies {
    /// The admitted model folder (`ModelDeliveryHome.admittedLiveSpeakerModelDirectory`).
    var admittedDirectory: @MainActor () async -> URL?
    /// "Dictation is active" on either engine, read on the main actor.
    var isDictationActive: @MainActor () -> Bool
    var makeAnalysis:
      (
        _ directory: URL, _ admit: @escaping @Sendable () -> Bool,
        _ publish: @escaping @Sendable (LiveSpeakerUpdate) -> Void,
        _ onReleased: @escaping @Sendable () -> Void
      ) -> any LiveSpeakerAnalysis = { directory, admit, publish, onReleased in
        LiveSpeakerSession(
          directory: directory, admit: admit, publish: publish, onReleased: onReleased)
      }
    var makePump: () -> MeetingLiveAudioPump = { MeetingLiveAudioPump() }
    /// Activity updates waiting for the main actor, at most (`Handoff`): about three minutes of
    /// the model's steps.
    var handoffActivityLimit = 256
  }

  /// What one recording's analysis did, frozen at its end (for meeting.ended in chunk 7).
  struct Facts: Equatable, Sendable {
    var modelState: ModelState
    /// Call audio the pump kept without a written position (`Accounting.unpositioned`).
    var unpositionedSamples: Int
    /// Emitted model frames whose audio had no written position.
    var unpositionedFrames: Int
    /// Activity updates dropped because the main actor fell behind (`Handoff`).
    var droppedActivityUpdates: Int
  }

  /// Ordered handoff from the analysis queue to the main actor, bounded. Activity updates beyond
  /// `activityLimit` waiting are dropped and counted: the joiner needs final coverage of a whole
  /// piece, so text over the missing evidence stays "Speaker" (settled once later evidence
  /// passes it), never a guess. Ready, reset and unavailable are never dropped (a handful per
  /// recording), so epochs stay exact. Capture never waits on it.
  final class Handoff: Sendable {
    private struct State: Sendable {
      var queue: [LiveSpeakerUpdate] = []
      var activities = 0
      var dropped = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let activityLimit: Int

    init(activityLimit: Int) { self.activityLimit = activityLimit }

    func put(_ update: LiveSpeakerUpdate) {
      state.withLock { s in
        if case .activity = update {
          guard s.activities < activityLimit else {
            s.dropped += 1
            return
          }
          s.activities += 1
        }
        s.queue.append(update)
      }
    }

    func takeAll() -> [LiveSpeakerUpdate] {
      state.withLock { s in
        defer {
          s.queue = []
          s.activities = 0
        }
        return s.queue
      }
    }

    var droppedActivities: Int { state.withLock { $0.dropped } }
  }

  private final class Recording {
    let generation: Int
    let meetingID: UUID
    let pump: MeetingLiveAudioPump
    var analysis: (any LiveSpeakerAnalysis)?
    var state: ModelState = .loading
    var epoch = 0
    var activities: [LiveSpeakerActivity] = []
    /// Per writer run, the end of the furthest final evidence of the current epoch.
    var reach: [Int: Int] = [:]
    var unpositionedFrames = 0
    var start: Task<Void, Never>?
    /// The ordered update handoff, its wake (finished at retirement) and its main-actor consumer.
    var handoff: Handoff?
    var wake: AsyncStream<Void>.Continuation?
    var consumer: Task<Void, Never>?
    /// The writer run each reset sent to the analysis starts, in order (the consumer appends, the
    /// matching `.reset` publication takes the first).
    let resetRuns = OSAllocatedUnfairLock<[Int]>(initialState: [])
    init(generation: Int, meetingID: UUID, pump: MeetingLiveAudioPump) {
      self.generation = generation
      self.meetingID = meetingID
      self.pump = pump
    }
  }

  private let deps: Dependencies
  /// Set by the bootstrapper: waits until a Settings check of the model has released it.
  var waitForCheckRelease: @MainActor () async -> Void = {}
  /// Called with the current labels whenever they change, for the recording's meeting.
  var onLabelsChanged: (@MainActor (UUID, MeetingLiveSpeakerLabels) -> Void)?

  private var generation = 0
  private var recording: Recording?
  private(set) var labels = MeetingLiveSpeakerLabels()
  private var nextNumber = 1
  private var numberOf: [LiveSpeakerKeyID: Int] = [:]
  /// Call pieces of the current meeting not yet settled, in transcript order.
  private var pending: [MeetingAudioSpan] = []
  private var settled: Set<MeetingAudioSpan> = []
  /// Per writer run, the end of the furthest call text seen. Evidence beyond it belongs to text
  /// that has not finalized yet and is kept for it.
  private var textEnd: [Int: Int] = [:]
  /// Evidence kept at most (merged activity entries); the oldest goes first beyond it.
  static let evidenceLimit = 4_096
  /// Ends once every analysis started so far has physically released its model.
  private var released: Task<Void, Never>?
  /// The meeting the current labels belong to.
  private var labelsMeetingID: UUID?
  private let dictationActive = OSAllocatedUnfairLock(initialState: false)
  private(set) var lastFacts: Facts?

  private struct LiveSpeakerKeyID: Hashable {
    let epoch: Int
    let slot: Int
  }

  init(dependencies: Dependencies) {
    self.deps = dependencies
    observeDictation()
  }

  var modelState: ModelState? { recording?.state }

  /// The current recording's model start, for tests.
  package var startTaskForTests: Task<Void, Never>? { recording?.start }

  // MARK: - Dictation priority

  /// Keeps the lock-held copy current: the analysis reads it on its own queue, never the main
  /// actor (the re-arming observation pattern of `MeetingIdleObserver`).
  private func observeDictation() {
    let active = withObservationTracking {
      deps.isDictationActive()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeDictation() }
    }
    dictationActive.withLock { $0 = active }
    dictationReadForTests?(active)
  }

  /// Called after each read of "dictation is active", for tests.
  package var dictationReadForTests: (@MainActor (Bool) -> Void)?

  private var admit: @Sendable () -> Bool {
    let flag = dictationActive
    return { !flag.withLock { $0 } }
  }

  // MARK: - Recording lifecycle (called by MeetingLiveWords)

  /// A new recording: its call audio is buffered from the first sample. Returns the feed for the
  /// call track's written audio.
  func prepareCapture(meetingID: UUID) -> @Sendable (UnsafeBufferPointer<Float>, MeetingAudioSpan)
    -> Void
  {
    retire(clearLabels: true)
    generation += 1
    let pump = deps.makePump()
    recording = Recording(generation: generation, meetingID: meetingID, pump: pump)
    labelsMeetingID = meetingID
    return { samples, span in pump.admit(samples, span: span) }
  }

  /// Capture started. With call sound, loads the model (if admitted) once any earlier copy is
  /// released, then starts feeding. Without it, nothing loads.
  func captureStarted(meetingID: UUID, callSound: Bool) {
    guard let current = recording, current.meetingID == meetingID, current.start == nil else {
      return
    }
    guard callSound else {
      current.state = .absent
      _ = current.pump.retire()
      return
    }
    let gen = current.generation
    let earlier = released
    let admittedDirectory = deps.admittedDirectory
    current.start = Task { [weak self] in
      // Eligibility is frozen at meeting start, before any wait: a download that finishes while
      // an earlier copy releases is used by the next meeting, not this one.
      let directory = await admittedDirectory()
      guard let directory else {
        self?.markAbsent(generation: gen)
        return
      }
      await earlier?.value
      await self?.waitForCheckRelease()
      self?.open(directory: directory, generation: gen)
    }
  }

  /// Stop, Quit: closes the analysis now (its release follows on its own queue). The labels stay
  /// until the transcript replaces the live words.
  func stop() { retire(clearLabels: false) }

  /// Delete, or the transcript replaced the live words: the labels go too.
  func clear(meetingID: UUID) {
    if recording?.meetingID == meetingID { retire(clearLabels: true) }
    if labelsMeetingID == meetingID { resetLabels() }
  }

  /// Waits until every analysis this owner started has released its model (model removal).
  func waitForRelease() async {
    await released?.value
  }

  /// The live words changed: new call pieces become pending.
  func linesChanged(_ lines: [LiveWordsAssembler.Line], meetingID: UUID) {
    guard let current = recording, current.meetingID == meetingID,
      current.state == .loading || current.state == .ready
    else { return }
    var known = Set(pending)
    for line in lines where line.track == .callSound {
      for piece in line.pieces {
        guard let span = piece.span, !settled.contains(span), !known.contains(span) else {
          continue
        }
        pending.append(span)
        known.insert(span)
      }
      for piece in line.pieces {
        guard let span = piece.span else { continue }
        textEnd[span.run] = max(textEnd[span.run] ?? 0, span.endSample)
      }
    }
    refresh()
  }

  // MARK: - Analysis

  private func markAbsent(generation gen: Int) {
    guard let current = recording, current.generation == gen else { return }
    current.state = .absent
    _ = current.pump.retire()
  }

  private func open(directory: URL, generation gen: Int) {
    guard let current = recording, current.generation == gen else { return }
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    // Ordered, bounded handoff to one main-actor consumer (`Handoff`). The consumer drains every
    // queued update in publication order on each wake.
    let handoff = Handoff(activityLimit: deps.handoffActivityLimit)
    let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    current.handoff = handoff
    current.wake = wake
    current.consumer = Task { @MainActor [weak self] in
      for await _ in wakes {
        for update in handoff.takeAll() { self?.receive(update, generation: gen) }
      }
    }
    let analysis = deps.makeAnalysis(
      directory, admit,
      { update in
        handoff.put(update)  // short: never waits for the main actor
        wake.yield()
      },
      {
        signal.continuation.yield()
        signal.continuation.finish()
      })
    let earlier = released
    released = Task {
      await earlier?.value
      for await _ in signal.stream { break }
    }
    current.analysis = analysis
    analysis.start()
    // One consumer: each bank once, in order; a writer run change starts a new epoch first.
    let lastRun = OSAllocatedUnfairLock<Int?>(initialState: nil)
    let resetRuns = current.resetRuns
    current.pump.startConsumer { chunk in
      for group in Self.runGroups(chunk) {
        if let run = group.run {
          let changed = lastRun.withLock { last -> Bool in
            defer { last = run }
            return last != nil && last != run
          }
          if changed {
            resetRuns.withLock { $0.append(run) }
            analysis.reset()
          }
        }
        analysis.submit(group.chunk)
      }
    }
  }

  /// Splits a bank at writer-run boundaries, so a reset lands before the first sample of a new
  /// run. Audio before the first slice (no position) stays with the first group.
  nonisolated static func runGroups(_ chunk: MeetingLiveAudioChunk) -> [(
    run: Int?, chunk: MeetingLiveAudioChunk
  )] {
    let slices = chunk.slices
    guard let first = slices.first else { return [(nil, chunk)] }
    var groups: [(run: Int?, chunk: MeetingLiveAudioChunk)] = []
    var groupStart = 0
    var run = first.span.run
    for slice in slices.dropFirst() where slice.span.run != run {
      groups.append((run, chunk.subrange(groupStart..<slice.offset)))
      groupStart = slice.offset
      run = slice.span.run
    }
    groups.append((run, chunk.subrange(groupStart..<chunk.samples.count)))
    return groups
  }

  /// Called after each applied update, for tests (subject-fired completion signal).
  package var receivedForTests: (@MainActor (LiveSpeakerUpdate) -> Void)?

  private func receive(_ update: LiveSpeakerUpdate, generation gen: Int) {
    guard let current = recording, current.generation == gen else { return }
    defer { receivedForTests?(update) }
    switch update {
    case .ready(let epoch):
      current.state = .ready
      current.epoch = epoch
    case .activity(let activities, let unpositioned):
      current.unpositionedFrames += unpositioned
      for activity in activities where activity.epoch == current.epoch {
        current.activities.append(activity)
        let run = activity.span.run
        current.reach[run] = max(current.reach[run] ?? 0, activity.span.endSample)
      }
      refresh()
    case .reset(let epoch):
      // A reset starts a new writer run: evidence of the old epoch is stale, and pieces of earlier
      // runs that waited on it will never be covered. Pieces of the new run keep waiting.
      current.epoch = epoch
      current.activities.removeAll()
      current.reach.removeAll()
      let recorded = current.resetRuns.withLock { runs in runs.isEmpty ? nil : runs.removeFirst() }
      // Production always records the run; without one, the newest pending run is kept when
      // pieces of several runs wait, else everything waiting settles.
      let runs = Set(pending.map(\.run))
      let boundary = recorded ?? (runs.count > 1 ? runs.max() ?? .max : .max)
      for span in pending where span.run < boundary { settled.insert(span) }
      pending.removeAll { settled.contains($0) }
    case .unavailable:
      current.state = .failed
      current.activities.removeAll()
      settleAllPendingUnresolved()
    }
  }

  /// Assigns what the evidence now settles; prunes evidence no pending piece needs.
  private func refresh() {
    guard let current = recording, current.state == .ready else { return }
    guard !pending.isEmpty else {
      prune(current)
      return
    }
    var changed = false
    var stillPending: [MeetingAudioSpan] = []
    for span in pending {
      let piece = MeetingTimedPiece(text: "", span: span)
      let assignment = LiveSpeakerJoiner.assign(
        piece, track: .callSound, activities: current.activities, currentEpoch: current.epoch)
      if case .remote(let epoch, let slot) = assignment {
        let id = LiveSpeakerKeyID(epoch: epoch, slot: slot)
        let number: Int
        if let known = numberOf[id] {
          number = known
        } else {
          number = nextNumber
          numberOf[id] = number
          nextNumber += 1
        }
        labels.numbers[span] = number
        settled.insert(span)
        changed = true
      } else if span.endSample <= current.reach[span.run] ?? 0 {
        settled.insert(span)  // final evidence passed it without an owner: "Speaker" for good
      } else {
        stillPending.append(span)
      }
    }
    pending = stillPending
    prune(current)
    if changed {
      labels.revision += 1
      onLabelsChanged?(current.meetingID, labels)
    }
  }

  /// Drops evidence only settled pieces used: per run, evidence ending at or before the earliest
  /// pending piece, or (with nothing pending there) before the furthest text seen. Evidence for
  /// audio whose text has not finalized is kept, within `evidenceLimit`.
  private func prune(_ current: Recording) {
    var earliest: [Int: Int] = [:]
    for span in pending { earliest[span.run] = min(earliest[span.run] ?? .max, span.startSample) }
    current.activities.removeAll { activity in
      let run = activity.span.run
      let frontier = earliest[run] ?? textEnd[run] ?? 0
      return activity.span.endSample <= frontier
    }
    let excess = current.activities.count - Self.evidenceLimit
    if excess > 0 { current.activities.removeFirst(excess) }
  }

  private func settleAllPendingUnresolved() {
    for span in pending { settled.insert(span) }
    pending.removeAll()
  }

  private func retire(clearLabels: Bool) {
    if let current = recording {
      current.start?.cancel()
      current.analysis?.close()
      current.wake?.finish()  // the consumer ends; anything still queued is this stale meeting's
      _ = current.pump.retire()
      lastFacts = Facts(
        modelState: current.state, unpositionedSamples: current.pump.accounting.unpositioned,
        unpositionedFrames: current.unpositionedFrames,
        droppedActivityUpdates: current.handoff?.droppedActivities ?? 0)
      recording = nil
      generation += 1
    }
    if clearLabels { resetLabels() }
  }

  private func resetLabels() {
    if let id = labelsMeetingID, !labels.numbers.isEmpty {
      labels = MeetingLiveSpeakerLabels()
      onLabelsChanged?(id, labels)
    }
    labels = MeetingLiveSpeakerLabels()
    numberOf = [:]
    nextNumber = 1
    pending = []
    settled = []
    textEnd = [:]
  }
}
