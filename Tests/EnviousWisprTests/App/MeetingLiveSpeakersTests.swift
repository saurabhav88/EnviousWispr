import EnviousWisprAppKitTestSupport
import Foundation
import Observation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview

/// #4355 PR C: when this fails, live call text shows under the wrong speaker or a guessed one,
/// speaker analysis competes with dictation, or a meeting loads a second copy of the speaker
/// model while the last one is still releasing.
@MainActor
@Suite("Live speakers: labels, blocks and lifecycle", .tags(.productOutcome))
struct MeetingLiveSpeakersTests {
  final class FakeAnalysis: LiveSpeakerAnalysis, @unchecked Sendable {
    let publish: @Sendable (LiveSpeakerUpdate) -> Void
    let onReleased: @Sendable () -> Void
    let admit: @Sendable () -> Bool
    let closed = OSAllocatedUnfairLock(initialState: false)
    /// "submit(run)" and "reset", in call order.
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let submitted = BoundedWait.Signal()
    var expectedSubmits = 2
    init(
      publish: @escaping @Sendable (LiveSpeakerUpdate) -> Void,
      onReleased: @escaping @Sendable () -> Void, admit: @escaping @Sendable () -> Bool
    ) {
      self.publish = publish
      self.onReleased = onReleased
      self.admit = admit
    }
    func start() {}
    func submit(_ chunk: MeetingLiveAudioChunk) {
      let runs = Set(chunk.slices.map(\.span.run)).sorted().map(String.init).joined(separator: ",")
      let count = events.withLock { e -> Int in
        e.append("submit(\(runs))")
        return e.filter { $0.hasPrefix("submit") }.count
      }
      if count >= expectedSubmits { submitted.fire() }
    }
    func reset() { events.withLock { $0.append("reset") } }
    func end() { closed.withLock { $0 = true } }
    var droppedSamples: Int { 0 }
  }

  @Observable @MainActor final class Dictation { var active = false }

  @MainActor final class Rig {
    var directory: URL? = URL(fileURLWithPath: "/speaker-live-fixture")
    let dictation = Dictation()
    var analyses: [FakeAnalysis] = []
    var labelChanges: [MeetingLiveSpeakerLabels] = []
    var labelSignal = BoundedWait.Signal()
    var handoffActivityLimit = 256
    var namingInterval: Duration? = .seconds(2)
    /// The call-app log each meeting returns, and which meetings asked for one.
    var logs: [UUID: CallSpeakerLog] = [:]
    var logReads: [UUID] = []
    var anchor: UInt64?
    /// Fires each time the meeting reads whether the model is downloaded.
    var eligibilityRead = BoundedWait.Signal()
    lazy var speakers: MeetingLiveSpeakers = {
      let speakers = MeetingLiveSpeakers(
        dependencies: .init(
          admittedDirectory: { [unowned self] in
            defer { eligibilityRead.fire() }
            return directory
          },
          isDictationActive: { [dictation] in dictation.active },
          makeAnalysis: { [unowned self] _, admit, publish, onReleased in
            let analysis = FakeAnalysis(publish: publish, onReleased: onReleased, admit: admit)
            analyses.append(analysis)
            return analysis
          },
          namingInterval: namingInterval, handoffActivityLimit: handoffActivityLimit))
      speakers.currentAnchor = { [unowned self] _ in anchor }
      speakers.currentCallLog = { [unowned self] id in
        logReads.append(id)
        return logs[id]
      }
      speakers.onLabelsChanged = { [unowned self] _, labels in
        labelChanges.append(labels)
        labelSignal.fire()
      }
      return speakers
    }()

    /// Starts a recording with call sound and waits until its model start settled.
    func startMeeting(_ id: UUID = UUID()) async throws -> UUID {
      _ = speakers.prepareCapture(meetingID: id)
      speakers.captureStarted(meetingID: id, callSound: true)
      let start = try #require(speakers.startTaskForTests)
      _ = try await BoundedWait.result(of: start)
      return id
    }

    /// Publishes through the current analysis and waits for the labels to change (or, with
    /// `expectLabels: false`, for the update to be applied).
    func publishAndWait(_ update: LiveSpeakerUpdate, expectLabels: Bool = true) async throws {
      labelSignal = BoundedWait.Signal()
      let applied = BoundedWait.Signal()
      if !expectLabels { speakers.receivedForTests = { _ in applied.fire() } }
      try #require(analyses.last).publish(update)
      try await BoundedWait.until(expectLabels ? labelSignal : applied)
    }
  }

  static let recording = UUID()
  static func span(_ start: Int, _ count: Int, run: Int = 0) -> MeetingAudioSpan {
    MeetingAudioSpan(
      recording: recording, track: .callSound, run: run, startSample: start, sampleCount: count)!
  }
  static func released(_ span: MeetingAudioSpan) -> MeetingReleasedChunk {
    MeetingReleasedChunk(
      span: span,
      acquired: MeetingAcquisitionTime(recording: recording, hostTicks: 1, provenance: .hardware),
      afterDrop: false, sourceBreak: false)
  }
    static func line(
    _ id: String, _ track: MeetingTrackKind, _ pieces: [MeetingTimedPiece]
  ) -> LiveWordsAssembler.Line {
    LiveWordsAssembler.Line(
      id: id, track: track, kind: .confirmed, startMs: 0, endMs: 1,
      text: MeetingTimedPiece.text(of: pieces), pieces: pieces)
  }
  static func activity(_ start: Int, _ count: Int, _ slots: [Int], epoch: Int = 0, run: Int = 0)
    -> LiveSpeakerActivity
  {
    LiveSpeakerActivity(epoch: epoch, span: span(start, count, run: run), activeSlots: slots)
  }

  @Test("with no downloaded model, call text appears at once under Speaker")
  func absentModelKeepsSpeaker() async throws {
    let rig = Rig()
    rig.directory = nil
    let id = try await rig.startMeeting()
    #expect(rig.speakers.modelState == .absent)
    #expect(rig.analyses.isEmpty, "nothing loads without an admitted model")
    let call = Self.line("c-1", .callSound, [MeetingTimedPiece(text: "Hello", span: Self.span(0, 100))])
    rig.speakers.linesChanged([call], meetingID: id)
    let blocks = MeetingsPresentation.liveBlocks([call], labels: rig.speakers.labels)
    #expect(blocks.map(\.speaker) == [.unresolved])
    #expect(MeetingsPresentation.liveSpeakerHeader(.unresolved) == "Speaker")
  }

  @Test("final evidence assigns each piece, and consecutive text of one speaker shares a block")
  func evidenceAssignsAndGroups() async throws {
    let rig = Rig()
    let id = try await rig.startMeeting()
    let lines = [
      Self.line("m-1", .microphone, [MeetingTimedPiece(text: "Can we ship?", span: nil)]),
      Self.line(
        "c-1", .callSound,
        [
          MeetingTimedPiece(text: "Yes,", span: Self.span(0, 100)),
          MeetingTimedPiece(text: " and no.", span: Self.span(100, 100)),
        ]),
      Self.line("c-2", .callSound, [MeetingTimedPiece(text: "Right.", span: Self.span(200, 100))]),
    ]
    rig.try_publishReady()
    rig.speakers.linesChanged(lines, meetingID: id)
    #expect(
      MeetingsPresentation.liveBlocks(lines, labels: rig.speakers.labels).map(\.speaker)
        == [.you, .unresolved], "before evidence, call text waits under Speaker")
    try await rig.publishAndWait(
      .activity(
        [Self.activity(0, 100, [4]), Self.activity(100, 200, [1])], unpositionedFrames: 0))
    let blocks = MeetingsPresentation.liveBlocks(lines, labels: rig.speakers.labels)
    #expect(blocks.map(\.speaker) == [.you, .remote("1"), .remote("2")])
    #expect(blocks.map { $0.runs.map(\.text) } == [["Can we ship?"], ["Yes,"], ["and no.", "Right."]])
    #expect(blocks.map(\.id) == ["m-1#0", "c-1#0", "c-1#1"], "runs keep their line's identity")
    #expect(
      blocks.map(\.startMs) == [0, 0, 6],  // sample 100 at 16 kHz is 6.25 ms
      "a second speaker inside one line is stamped from its own first word, not the line's start")
    // The view draws one row per live line, before and after the labels arrived, so no line's
    // text row is removed or reparented; the second speaker inside "c-1" is a header within it.
    let before = MeetingsPresentation.liveRows(
      MeetingsPresentation.liveBlocks(lines, labels: MeetingLiveSpeakerLabels()))
    let rows = MeetingsPresentation.liveRows(blocks)
    #expect(before.map(\.id) == ["m-1", "c-1", "c-2"])
    #expect(rows.map(\.id) == ["m-1", "c-1", "c-2"])
    #expect(rows.map { $0.header?.speaker } == [.you, .remote("1"), nil])
    #expect(rows[1].segments.map(\.text) == ["Yes,", "and no."])
    #expect(rows[1].segments.map { $0.header?.speaker } == [nil, .remote("2")])
    #expect(rows[2].segments.map(\.text) == ["Right."], "continues Speaker 2's block, no header")
  }

  @Test("untimed text, a reset and stale results never produce a label")
  func noGuessedOrStaleLabels() async throws {
    let rig = Rig()
    let id = try await rig.startMeeting()
    rig.try_publishReady()
    let untimed = MeetingTimedPiece(text: "Mm-hm", span: nil)
    let waiting = MeetingTimedPiece(text: "Wait", span: Self.span(300, 100))
    // `waiting` is in run 0; the reset starts run 1, where `anchor` is.
    let anchor = MeetingTimedPiece(text: "Ok", span: Self.span(500, 100, run: 1))
    let lines = [Self.line("c-1", .callSound, [untimed, waiting, anchor])]
    rig.speakers.linesChanged(lines, meetingID: id)
    // A reset invalidates the evidence `waiting` needed; the new epoch cannot claim it.
    rig.analyses[0].publish(.reset(epoch: 1))
    try await rig.publishAndWait(
      .activity(
        [Self.activity(300, 100, [0], epoch: 1), Self.activity(500, 100, [0], epoch: 1, run: 1)],
        unpositionedFrames: 0))
    let keys = lines[0].pieces.map { rig.speakers.labels.key(for: $0, track: .callSound) }
    #expect(keys == [.unresolved, .unresolved, .remote("1")])
    // The next meeting (after the first analysis released): its late results are ignored.
    rig.analyses[0].onReleased()
    let next = try await rig.startMeeting()
    rig.analyses[0].publish(.activity([Self.activity(0, 100, [3], epoch: 1)], unpositionedFrames: 0))
    rig.analyses[1].publish(.ready(epoch: 0))
    let fresh = Self.line("c-9", .callSound, [MeetingTimedPiece(text: "Hi", span: Self.span(0, 100))])
    rig.speakers.linesChanged([fresh], meetingID: next)
    try await rig.publishAndWait(.activity([Self.activity(0, 100, [7])], unpositionedFrames: 0))
    #expect(rig.speakers.labels.numbers == [Self.span(0, 100): 1], "numbering starts again; no stale label")
  }

  @Test("speaker analysis yields while dictation records or transcribes")
  func dictationGoesFirst() async throws {
    let rig = Rig()
    _ = try await rig.startMeeting()
    let admit = try #require(rig.analyses.first).admit
    #expect(admit())
    let read = BoundedWait.Signal()
    rig.speakers.dictationReadForTests = { if $0 { read.fire() } }
    rig.dictation.active = true
    try await BoundedWait.until(read)
    #expect(!admit(), "the analysis is refused while dictation is active")
  }

  @Test("Stop closes the analysis, and the next meeting loads only after it released")
  func nextMeetingWaitsForRelease() async throws {
    let rig = Rig()
    _ = try await rig.startMeeting()
    rig.speakers.stop()
    #expect(rig.analyses[0].closed.withLock { $0 })
    let next = UUID()
    _ = rig.speakers.prepareCapture(meetingID: next)
    rig.speakers.captureStarted(meetingID: next, callSound: true)
    let start = try #require(rig.speakers.startTaskForTests)
    #expect(rig.analyses.count == 1, "no second copy while the first is still releasing")
    rig.analyses[0].onReleased()
    _ = try await BoundedWait.result(of: start)
    #expect(rig.analyses.count == 2)
  }

  @Test("finished analysis skips active recordings and joins only retired cleanup",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4424", "do not wait for an unrelated call"))
  func finishedAnalysisDoesNotWaitForActiveRecording() async throws {
    let rig = Rig()
    _ = try await rig.startMeeting()
    let analysis = try #require(rig.analyses.first)
    defer { rig.speakers.stop(); analysis.onReleased() }
    let active = Task { await rig.speakers.prepareForFinishedAnalysis() }
    #expect(try await BoundedWait.result(of: active).get() == false,
      "an active recording must not be awaited until Stop")
    #expect(analysis.closed.withLock { $0 } == false, "optional work must not stop the recording")

    rig.speakers.stop()
    let entered = BoundedWait.Signal()
    var returned = false
    let retired = Task {
      entered.fire()  // Start signal only; completion is awaited from the subject task below.
      defer { returned = true }
      return await rig.speakers.prepareForFinishedAnalysis()
    }
    try await BoundedWait.until(entered)
    #expect(returned == false, "retired native cleanup is still physically held")
    _ = rig.speakers.prepareCapture(meetingID: UUID())
    analysis.onReleased()
    #expect(try await BoundedWait.result(of: retired).get() == false,
      "a new recording while cleanup drains takes priority")
    rig.speakers.stop()
    #expect(await rig.speakers.prepareForFinishedAnalysis(), "retired cleanup has now completed")
  }

  @Test("evidence that arrives before the text is kept for two later finals")
  func evidenceAheadOfTextIsKept() async throws {
    let rig = Rig()
    let id = try await rig.startMeeting()
    let applied = BoundedWait.Signal()
    rig.speakers.receivedForTests = { if case .activity = $0 { applied.fire() } }
    rig.try_publishReady()
    rig.analyses[0].publish(
      .activity([Self.activity(0, 100, [0]), Self.activity(100, 100, [1])], unpositionedFrames: 0))
    try await BoundedWait.until(applied)
    let first = MeetingTimedPiece(text: "One", span: Self.span(0, 100))
    let second = MeetingTimedPiece(text: " two", span: Self.span(100, 100))
    rig.speakers.linesChanged([Self.line("c-1", .callSound, [first])], meetingID: id)
    rig.speakers.linesChanged([Self.line("c-1", .callSound, [first, second])], meetingID: id)
    #expect(rig.speakers.labels.numbers == [Self.span(0, 100): 1, Self.span(100, 100): 2])
  }

  @Test("a bank holding two writer runs resets the analysis before the second run's audio")
  func runChangeInsideABank() async throws {
    let rig = Rig()
    let id = UUID()
    let feed = rig.speakers.prepareCapture(meetingID: id)
    rig.speakers.captureStarted(meetingID: id, callSound: true)
    let start = try #require(rig.speakers.startTaskForTests)
    _ = try await BoundedWait.result(of: start)
    let samples = [Float](repeating: 0.1, count: 200)
    samples.withUnsafeBufferPointer { buffer in
      feed(UnsafeBufferPointer(rebasing: buffer[0..<100]), Self.released(Self.span(0, 100, run: 0)))
      feed(UnsafeBufferPointer(rebasing: buffer[100..<200]), Self.released(Self.span(0, 100, run: 1)))
    }
    try await BoundedWait.until(rig.analyses[0].submitted)
    #expect(rig.analyses[0].events.withLock { $0 } == ["submit(0)", "reset", "submit(1)"])
  }

  @Test("a download that finishes while the last copy releases waits for the next meeting")
  func eligibilityIsFrozenAtStart() async throws {
    let rig = Rig()
    _ = try await rig.startMeeting()
    rig.speakers.stop()
    rig.directory = nil  // not downloaded when the next meeting starts
    let next = UUID()
    rig.eligibilityRead = BoundedWait.Signal()
    _ = rig.speakers.prepareCapture(meetingID: next)
    rig.speakers.captureStarted(meetingID: next, callSound: true)
    let start = try #require(rig.speakers.startTaskForTests)
    // The meeting reads eligibility at its start, while the first copy still releases.
    try await BoundedWait.until(rig.eligibilityRead)
    rig.directory = URL(fileURLWithPath: "/speaker-live-fixture")  // the download finishes
    rig.analyses[0].onReleased()
    _ = try await BoundedWait.result(of: start)
    #expect(rig.speakers.modelState == .absent)
    #expect(rig.analyses.count == 1, "the new model is not used in this meeting")
  }

  @Test("when the main actor falls behind, extra evidence is dropped and counted, never a reset")
  func boundedHandoffKeepsResets() async throws {
    let rig = Rig()
    rig.handoffActivityLimit = 2
    let id = try await rig.startMeeting()
    var applied: [LiveSpeakerUpdate] = []
    let resetApplied = BoundedWait.Signal()
    rig.speakers.receivedForTests = { update in
      applied.append(update)
      if case .reset = update { resetApplied.fire() }
    }
    // All published before the main actor runs the consumer.
    let analysis = rig.analyses[0]
    analysis.publish(.ready(epoch: 0))
    analysis.publish(.activity([Self.activity(0, 100, [0])], unpositionedFrames: 0))
    analysis.publish(.activity([Self.activity(100, 100, [0])], unpositionedFrames: 0))
    analysis.publish(.activity([Self.activity(200, 100, [0])], unpositionedFrames: 0))  // over
    analysis.publish(.reset(epoch: 1))
    try await BoundedWait.until(resetApplied)
    #expect(applied.count == 4, "ready, two activities, reset")
    #expect(applied.last == .reset(epoch: 1))
    rig.speakers.stop()
    #expect(rig.speakers.frozenSummary(for: id)?.updateDrops == 1)
  }

  @Test("Stop freezes the meeting's speaker summary; the next meeting cannot change it")
  func summaryIsFrozenAtStop() async throws {
    let rig = Rig()
    let id = try await rig.startMeeting()
    rig.try_publishReady()
    let lines = [
      Self.line("m-1", .microphone, [MeetingTimedPiece(text: "not counted here", span: nil)]),
      Self.line(
        "c-1", .callSound,
        [
          MeetingTimedPiece(text: "one two three", span: Self.span(0, 100)),
          MeetingTimedPiece(text: " four", span: nil),
        ]),
    ]
    rig.speakers.linesChanged(lines, meetingID: id)
    try await rig.publishAndWait(.activity([Self.activity(0, 100, [0])], unpositionedFrames: 0))
    rig.speakers.stop(lines: lines, liveWordsUnpositionedSamples: 16_000)
    let frozen = try #require(rig.speakers.frozenSummary(for: id))
    #expect(frozen.liveWordsUnpositionedMs == 1_000, "the live-words pumps' count, in ms")
    #expect(frozen.unpositionedMs == 0, "kept apart from the speaker pump's")
    #expect(frozen.state == .ready)
    #expect(frozen.remoteWords == 4, "untimed call words count; microphone words never do")
    #expect(frozen.attributedWords == 3)
    #expect(frozen.namedSpeakers == 0)
    rig.analyses[0].onReleased()
    let next = try await rig.startMeeting()
    rig.speakers.stop(lines: [])
    #expect(rig.speakers.frozenSummary(for: id) == nil, "the summary belongs to its own meeting")
    #expect(rig.speakers.frozenSummary(for: next)?.remoteWords == 0)
    #expect(frozen.attributedShare == 0.75)
  }

  @Test("call audio the speaker pump drops while the model loads counts as skipped; with no model, nothing does")
  func pumpDropsCountAsSkipped() async throws {
    // More than the pump holds (about 28.8 s), fed before the model start runs.
    let bank = [Float](repeating: 0, count: MeetingLiveAudioPump.bankSamples)
    func overfill(_ feed: @Sendable (UnsafeBufferPointer<Float>, MeetingReleasedChunk) -> Void) {
      for index in 0..<(MeetingLiveAudioPump.queuedBanks + 4) {
        let span = Self.span(index * bank.count, bank.count)
        bank.withUnsafeBufferPointer { feed($0, Self.released(span)) }
      }
    }
    let rig = Rig()
    let loading = UUID()
    overfill(rig.speakers.prepareCapture(meetingID: loading))
    rig.speakers.stop(lines: [])
    let skipped = try #require(rig.speakers.frozenSummary(for: loading))
    #expect(skipped.state == .loading)
    #expect(skipped.backlogSkippedMs > 0, "evicted call audio is reported, not zero")

    rig.directory = nil
    let absent = UUID()
    let feed = rig.speakers.prepareCapture(meetingID: absent)
    rig.speakers.captureStarted(meetingID: absent, callSound: true)
    _ = try await BoundedWait.result(of: try #require(rig.speakers.startTaskForTests))
    overfill(feed)
    rig.speakers.stop(lines: [])
    let none = try #require(rig.speakers.frozenSummary(for: absent))
    #expect(none.state == .absent)
    #expect(none.backlogSkippedMs == 0, "audio refused on purpose without a model is not skipped")
  }
}

extension MeetingLiveSpeakersTests.Rig {
  /// The model loaded (epoch 0); no label changes, so nothing to wait for beyond ordering.
  func try_publishReady() {
    analyses.last?.publish(.ready(epoch: 0))
  }
}
