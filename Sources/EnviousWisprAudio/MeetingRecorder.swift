import AVFoundation
import CoreAudio
import EnviousWisprCore
import Foundation
import os

/// The microphone a meeting records from (#3972 C2b). Production is `HALMeetingMicrophone`, a
/// meeting's OWN `HALDeviceInputSource`; tests use a fake.
@MainActor
protocol MeetingMicrophoneSource: AnyObject {
  /// Called on a capture thread with 16 kHz mono samples and their level.
  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)? { get set }
  var onInterrupted: ((EngineInterruptionCause) -> Void)? { get set }
  /// The device was opened but delivers no buffers (HAL's capture-stall signal).
  var onStalled: (() -> Void)? { get set }
  /// Opens the device (`targetUID` nil = the system default input). Returns the UID actually
  /// bound, or nil when it could not be read.
  func open(targetUID: String?, inputChannelByDeviceUID: [String: Int]) async throws -> String?
  /// Starts delivering samples. Audio captured before this call may be handed over inside it.
  func beginDelivery() async throws
  /// Stops and releases the device at once. Repeatable.
  func stopNow()
}

/// The call sound a meeting records (#3972 C2b). Production is `SystemAudioTap`.
protocol MeetingCallSoundSource: AnyObject {
  func start() throws
  func stop()
  var currentLevel: Float { get }
  /// #4121: the start facts and counts for the meeting's terminal telemetry row.
  var summary: CallSoundSummary { get }
}

@available(macOS 14.2, *)
extension SystemAudioTap: MeetingCallSoundSource {}

/// Records one EnviousMeet meeting as two tracks (#3972 §3.2, R2, R14, R27).
///
/// Owns its OWN microphone client (never dictation's `AudioCaptureManager`) and, on macOS 14.2+,
/// a `SystemAudioTap`. Each track feeds a `MeetingTrackWriter`. The microphone is required; the
/// call sound is best effort and its status says why it is absent. A failure here ends the
/// meeting recording, never a dictation.
///
/// **One-shot lifecycle.** `start` once, then `stop` or `stopForQuit`. Every step after an await
/// re-checks that this start is still current, so a start or reopen that completes after a stop
/// releases what it opened and never installs a live source.
///
/// **Microphone timing (R27).** The HAL source carries no acquisition time, so each chunk is
/// stamped with its arrival time minus its duration. That clock is approximate; the writer
/// starts a new segment only when arrival jumps more than 1.5 s ahead of the samples. Audio the
/// source hands over from before `beginDelivery` returned (its pre-roll) is not recorded, so
/// nothing is backdated before the meeting started. Call sound uses the tap's acquisition time.
@MainActor
public final class MeetingRecorder {
  public typealias SegmentHandler = @Sendable (MeetingTrackKind, MeetingSegmentInfo) -> Void
  public typealias FailureHandler = @MainActor (MeetingTrackKind, Error) -> Void
  /// See `liveSamples`.
  public typealias LiveSamplesObserver = @Sendable (MeetingTrackKind, UnsafeBufferPointer<Float>)
    -> Void

  public struct Configuration: Sendable {
    public let meetingID: UUID
    public let folder: URL
    public let captureCallSound: Bool
    /// Nil follows the system default input, as dictation's Auto does.
    public let microphoneUID: String?
    public let inputChannelByDeviceUID: [String: Int]

    public init(
      meetingID: UUID, folder: URL, captureCallSound: Bool, microphoneUID: String?,
      inputChannelByDeviceUID: [String: Int]
    ) {
      self.meetingID = meetingID
      self.folder = folder
      self.captureCallSound = captureCallSound
      self.microphoneUID = microphoneUID
      self.inputChannelByDeviceUID = inputChannelByDeviceUID
    }
  }

  public struct StartResult: Sendable, Equatable {
    public let microphone: MeetingTrackStatus
    public let callSound: MeetingTrackStatus
  }

  /// How each track's file ended. Nil: that track never had a writer.
  public struct StopReport: Sendable, Equatable {
    public var microphone: MeetingTrackWriter.CloseOutcome?
    public var callSound: MeetingTrackWriter.CloseOutcome?
    /// #4121: the call-sound capture's summary, frozen when capture stopped. Nil when no
    /// call-sound source was running then (off, unsupported, failed to start, or a Stop that
    /// won before its start finished).
    public var callSoundSummary: CallSoundSummary? = nil
  }

  public typealias CallSoundReportHandler = @Sendable (CallSoundChangeReport) -> Void

  public enum RecorderError: Error, Equatable {
    case microphoneUnavailable(String)
    /// `start` was called twice.
    case alreadyStarted
    /// A stop arrived while the start was still opening the microphone.
    case stoppedDuringStart
  }

  /// Counters for status and telemetry. Content-free.
  public struct MicrophoneHealth: Sendable, Equatable {
    public var reopens = 0
    public var reopenFailures = 0
    /// Times the open microphone delivered no audio and was replaced.
    public var stalls = 0
    /// Samples not recorded because they arrived while no microphone was admitted: pre-roll
    /// handed over inside `beginDelivery`, or audio after a stop or a loss.
    public var framesNotAdmitted = 0
  }

  /// Seams for tests; production uses `.live`.
  struct Sources {
    var makeMicrophone: @MainActor () -> MeetingMicrophoneSource
    /// Nil when this Mac cannot capture the call sound.
    var makeCallSound:
      @MainActor (
        @escaping CallSoundPipeline.SampleHandler, @escaping @Sendable (String) -> Void,
        @escaping CallSoundReportHandler
      ) -> MeetingCallSoundSource?
    var hostTime: @Sendable () -> UInt64
    /// The pause before reopening a lost microphone.
    var reopenDelay: @Sendable () async -> Void

    static var live: Sources {
      Sources(
        makeMicrophone: { HALMeetingMicrophone() },
        makeCallSound: { onSamples, onFailure, onReport in
          guard #available(macOS 14.2, *) else { return nil }
          return SystemAudioTap(
            onSamples: onSamples,
            onEvent: { event in
              switch event {
              case .rebuildFailed(let reason): onFailure(reason)
              case .report(let report): onReport(MeetingRecorder.changeReport(from: report))
              case .rebuilt: break
              }
            })
        },
        hostTime: { mach_absolute_time() },
        reopenDelay: { try? await Task.sleep(for: .seconds(1)) })
    }
  }

  private enum Lifecycle {
    case idle, starting, running, stopping, stopped
  }

  private let config: Configuration
  private let sources: Sources
  private let anchorHostTime: UInt64
  private let onSegment: SegmentHandler
  private let onFailure: FailureHandler
  private let onCallSoundReport: CallSoundReportHandler

  private var lifecycle = Lifecycle.idle
  /// Bumped by every stop and every microphone reopen; work resumed after an await carries the
  /// value it started with and gives up when it no longer matches.
  private var generation = 0
  private var microphone: MeetingMicrophoneSource?
  private var micWriter: MeetingTrackWriter?
  private var callSound: MeetingCallSoundSource?
  private var callWriter: MeetingTrackWriter?
  private var reopenTask: Task<Void, Never>?
  private var reportedFailure: Set<MeetingTrackKind> = []
  /// Why the microphone being opened by `start` was lost before the start finished.
  private var lostDuringStart: String?
  private var stopReport: StopReport?
  /// #4121: the call-sound summary, frozen by the first `stopCapture` (nil inside when no source
  /// was running). Later and overlapping stops reuse it.
  private var frozenCallSoundSummary: CallSoundSummary??
  private let micLevelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
  private let micHealthBox = OSAllocatedUnfairLock(initialState: MicrophoneHealth())
  /// Whether the current microphone's samples are recorded; false while `beginDelivery` runs.
  private let micAdmission = OSAllocatedUnfairLock<Int?>(initialState: nil)
  /// `liveSamples`, read by both capture threads. `closed` once capture stopped for good.
  private let liveBox = LiveObserverBox()

  /// The observer behind one unfair lock, in a stored property of its own concrete type.
  ///
  /// **Not a tuple in `OSAllocatedUnfairLock`'s generic state** (#3973 UAT crash, 2026-10-25):
  /// reading a closure out of that generic storage on every chunk made the Debug build wrap it in
  /// one more reabstraction thunk each time, so after about 5,500 call-sound chunks one call of it
  /// overflowed the tap thread's stack (SIGBUS on its guard page).
  /// `MeetingRecorderTests.liveSamplesDepthStaysFlat` pins the depth.
  private final class LiveObserverBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var observer: LiveSamplesObserver?
    private var closed = false

    /// The observer now (capture threads; never waits beyond the unfair lock).
    func current() -> LiveSamplesObserver? {
      lock.lock()
      defer { lock.unlock() }
      return observer
    }

    func set(_ newValue: LiveSamplesObserver?) {
      lock.lock()
      defer { lock.unlock() }
      if !closed { observer = newValue }
    }

    func close() {
      lock.lock()
      defer { lock.unlock() }
      observer = nil
      closed = true
    }
  }

  #if DEBUG
    /// The current microphone reopen, so a test can wait for it to end.
    var reopenTaskForTesting: Task<Void, Never>? { reopenTask }
    /// #4121: the microphone writer, so a test can hold its close and stop again meanwhile.
    var microphoneWriterForTesting: MeetingTrackWriter? { micWriter }
  #endif

  /// The device the microphone actually bound, as the source reported it.
  public private(set) var boundMicrophoneUID: String?

  /// Hands each recorded chunk to a live consumer (#3973, EnviousMeet's live words), on the
  /// capture thread, right AFTER the writer took it: the microphone's admitted samples and the
  /// call sound's. Never pre-roll or a stale microphone's audio (the same admission the writer
  /// gets). A delivery does not prove the samples reached the file; the writer stays first and
  /// nothing here changes what it records.
  ///
  /// The pointer is borrowed for the duration of the call only. The observer copies what it
  /// keeps into storage it already owns and returns: no waiting, locking that can block, task
  /// creation, dispatch, allocation that grows or recognition work, since it runs on the
  /// real-time capture path.
  ///
  /// Set it before `start()` to see the first samples; it survives a microphone reopen. Nil
  /// detaches: later chunks are not delivered, but a call already running on a capture thread
  /// may still finish (there is no join), so the consumer closes its own admission first. Stop,
  /// Quit and a failed start end deliveries for good; setting it afterwards has no effect.
  public var liveSamples: LiveSamplesObserver? {
    get { liveBox.current() }
    set { liveBox.set(newValue) }
  }

  /// `onCallSoundReport` receives each call-sound change row (#4121), on the tap's queue.
  public convenience init(
    configuration: Configuration, onSegment: @escaping SegmentHandler,
    onFailure: @escaping FailureHandler,
    onCallSoundReport: @escaping CallSoundReportHandler = { _ in }
  ) {
    self.init(
      configuration: configuration, sources: .live, onSegment: onSegment, onFailure: onFailure,
      onCallSoundReport: onCallSoundReport)
  }

  init(
    configuration: Configuration, sources: Sources, onSegment: @escaping SegmentHandler,
    onFailure: @escaping FailureHandler,
    onCallSoundReport: @escaping CallSoundReportHandler = { _ in }
  ) {
    self.config = configuration
    self.sources = sources
    self.anchorHostTime = sources.hostTime()
    self.onSegment = onSegment
    self.onFailure = onFailure
    self.onCallSoundReport = onCallSoundReport
  }

  /// #4121: a tap change row in the closed vocabulary the telemetry row carries.
  @available(macOS 14.2, *)
  nonisolated static func changeReport(from report: SystemAudioTap.CaptureReport)
    -> CallSoundChangeReport
  {
    CallSoundChangeReport(
      outcome: report.outcome.rawValue, reason: report.reason?.telemetryValue,
      configuredRateHz: report.configuredRateHz, nominalRateHz: report.nominalRateHz,
      measuredRateBucket: report.measuredRateBucket, outputTransport: report.outputTransport)
  }

  /// Host time the meeting's timeline is measured from.
  public var anchor: UInt64 { anchorHostTime }

  public var microphoneLevel: Float { micLevelBox.withLock { $0 } }
  public var callSoundLevel: Float { callSound?.currentLevel ?? 0 }
  public var microphoneHealth: MeetingTrackWriter.Health? { micWriter?.currentHealth }
  public var callSoundHealth: MeetingTrackWriter.Health? { callWriter?.currentHealth }
  public var microphoneSourceHealth: MicrophoneHealth { micHealthBox.withLock { $0 } }

  // MARK: - Start

  /// Starts both tracks. Throws when the microphone cannot start, with everything it opened
  /// released and its writer closed.
  public func start() async throws -> StartResult {
    guard lifecycle == .idle else { throw RecorderError.alreadyStarted }
    lifecycle = .starting
    let startGeneration = generation
    let micWriter = makeWriter(.microphone)
    self.micWriter = micWriter
    do {
      try await openMicrophone(
        targetUID: config.microphoneUID, writer: micWriter, generation: startGeneration)
    } catch {
      closeLiveSamples()
      self.micWriter = nil
      _ = await micWriter.finish()
      if lifecycle == .starting { lifecycle = .stopped }
      if let recorderError = error as? RecorderError { throw recorderError }
      throw RecorderError.microphoneUnavailable(String(describing: error))
    }
    guard lifecycle == .starting, generation == startGeneration else {
      throw RecorderError.stoppedDuringStart
    }

    var callStatus: MeetingTrackStatus = .off
    if config.captureCallSound {
      let writer = makeWriter(.callSound)
      let live = liveBox
      let source = sources.makeCallSound(
        { samples, hostTime, startsNewRun in
          writer.append(samples, hostTime: hostTime, startsNewRun: startsNewRun)
          // Borrowed for this call only; read under the lock, invoked outside it.
          if let observe = live.current() { observe(.callSound, samples) }
        },
        { [weak self] reason in
          Task { @MainActor in
            self?.trackFailed(.callSound, CallSoundError.captureStopped(reason))
          }
        },
        onCallSoundReport)
      if let source {
        // The writer is the recorder's before the wait: a stop or quit during it closes the
        // file and its admission, so audio the late tap delivers (its start or its stop tail)
        // is refused, never written after Stop.
        callWriter = writer
        // Off the main actor: building the tap waits inside Core Audio until the user answers
        // macOS's first system-audio prompt, and the app must keep working meanwhile (dictation,
        // menu, window). Found by Live UAT: the whole app froze while the prompt was open.
        switch await Self.startOffMain(source) {
        case .success:
          callSound = source
          callStatus = .captured
        case .failure:
          // Never "denied": a tap error does not say macOS refused permission.
          callStatus = .failed
          if lifecycle == .starting { callWriter = nil }
          _ = await writer.finish()
        }
      } else {
        callStatus = .unsupported
      }
    }
    // The call-sound start suspends (it runs off the main actor), and so can the writer finish
    // above: a stop or a microphone loss can come in meanwhile. A stop owns teardown of what it
    // saw; a source that started after it is stopped here; a loss during start fails the start.
    if lifecycle != .starting {
      callSound?.stop()
      throw RecorderError.stoppedDuringStart
    }
    if generation != startGeneration {
      let reason = lostDuringStart ?? "microphone_lost"
      lostDuringStart = nil
      await stop()
      throw RecorderError.microphoneUnavailable(reason)
    }
    lifecycle = .running
    return StartResult(microphone: .captured, callSound: callStatus)
  }

  /// Starts the call-sound source on a background thread and resumes with its result. The
  /// source is safe to start from any thread (`SystemAudioTap` serializes on its own queue).
  private static func startOffMain(_ source: MeetingCallSoundSource) async -> Result<Void, Error> {
    let box = UncheckedSource(source)
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try box.source.start()
          continuation.resume(returning: .success(()))
        } catch {
          continuation.resume(returning: .failure(error))
        }
      }
    }
  }

  private struct UncheckedSource: @unchecked Sendable {
    let source: MeetingCallSoundSource
    init(_ source: MeetingCallSoundSource) { self.source = source }
  }

  /// Opens a microphone source and admits its samples, re-checking after every await that
  /// `generation` is still current; otherwise the source it opened is released.
  ///
  /// `startsNewRun`: a reopen after a lost microphone (#3998). Its first admitted
  /// buffer does not continue the audio before the loss, so the writer starts a new segment
  /// at its arrival time; without this a reopen inside the writer's 1.5 s jitter allowance
  /// joined the two stretches and pulled the microphone timeline earlier than the call track.
  private func openMicrophone(
    targetUID: String?, writer: MeetingTrackWriter, generation openGeneration: Int,
    startsNewRun: Bool = false
  ) async throws {
    lostDuringStart = nil
    let source = sources.makeMicrophone()
    let level = micLevelBox
    let admission = micAdmission
    let health = micHealthBox
    let hostTime = sources.hostTime
    let live = liveBox
    // Read and cleared by the first admitted buffer only (audio thread; no allocation).
    let pendingRunBreak = OSAllocatedUnfairLock(initialState: startsNewRun)
    source.onSamples = { samples, audioLevel in
      guard !samples.isEmpty else { return }
      guard admission.withLock({ $0 }) == openGeneration else {
        health.withLock { $0.framesNotAdmitted += samples.count }
        return
      }
      let duration = Double(samples.count) / MeetingAudioFormat.sampleRate
      let firstSampleHost = hostTime() &- MeetingRecorder.hostTicks(forSeconds: duration)
      let runBreak = pendingRunBreak.withLock { pending -> Bool in
        defer { pending = false }
        return pending
      }
      samples.withUnsafeBufferPointer {
        writer.append($0, hostTime: firstSampleHost, startsNewRun: runBreak)
        // After the writer, inside the borrow: the live consumer copies and returns.
        if let observe = live.current() { observe(.microphone, $0) }
      }
      level.withLock { $0 = audioLevel }
    }
    source.onInterrupted = { [weak self] cause in
      self?.microphoneLost(reason: cause.rawValue, stall: false, generation: openGeneration)
    }
    source.onStalled = { [weak self] in
      self?.microphoneLost(reason: "no_buffers", stall: true, generation: openGeneration)
    }
    admission.withLock { $0 = nil }
    let bound: String?
    do {
      bound = try await source.open(
        targetUID: targetUID, inputChannelByDeviceUID: config.inputChannelByDeviceUID)
      guard self.generation == openGeneration, lifecycle == .starting || lifecycle == .running
      else { throw RecorderError.stoppedDuringStart }
      try await source.beginDelivery()
      guard self.generation == openGeneration, lifecycle == .starting || lifecycle == .running
      else { throw RecorderError.stoppedDuringStart }
    } catch {
      source.onSamples = nil
      source.onInterrupted = nil
      source.onStalled = nil
      source.stopNow()
      if let reason = lostDuringStart, case RecorderError.stoppedDuringStart = error {
        lostDuringStart = nil
        throw RecorderError.microphoneUnavailable(reason)
      }
      throw error
    }
    admission.withLock { $0 = openGeneration }
    boundMicrophoneUID = bound
    microphone = source
  }

  // MARK: - Microphone loss

  /// The device went away, its engine was lost, or it delivers nothing.
  ///
  /// During `start`: the pending start is invalidated (it releases the source and throws
  /// `microphoneUnavailable`), so a lost microphone is never reported as captured. While
  /// recording: reopen on the system default after a pause (#3972 §3.2); the writer places
  /// the gap from the arrival clock.
  private func microphoneLost(reason: String, stall: Bool, generation lost: Int) {
    guard generation == lost else { return }
    if lifecycle == .starting {
      lostDuringStart = reason
      generation += 1
      return
    }
    guard lifecycle == .running, let writer = micWriter else { return }
    if stall { micHealthBox.withLock { $0.stalls += 1 } }
    generation += 1
    let reopenGeneration = generation
    admissionOff()
    microphone?.onSamples = nil
    microphone?.onInterrupted = nil
    microphone?.onStalled = nil
    microphone?.stopNow()
    microphone = nil
    reopenTask?.cancel()
    let delay = sources.reopenDelay
    reopenTask = Task { [weak self] in
      await delay()
      guard let self, !Task.isCancelled, self.lifecycle == .running,
        self.generation == reopenGeneration
      else { return }
      do {
        try await self.openMicrophone(
          targetUID: nil, writer: writer, generation: reopenGeneration, startsNewRun: true)
        self.micHealthBox.withLock { $0.reopens += 1 }
      } catch RecorderError.stoppedDuringStart {
        return
      } catch {
        self.micHealthBox.withLock { $0.reopenFailures += 1 }
        self.trackFailed(.microphone, error)
      }
    }
  }

  // MARK: - Stop

  /// Stops capture on both tracks, then closes both files. Repeatable: later calls return the
  /// first report.
  @discardableResult
  public func stop() async -> StopReport {
    if let stopReport { return stopReport }
    stopCapture()
    async let mic = micWriter?.finish()
    async let call = callWriter?.finish()
    let report = StopReport(
      microphone: await mic, callSound: await call,
      callSoundSummary: frozenCallSoundSummary ?? nil)
    stopReport = report
    lifecycle = .stopped
    return report
  }

  /// Quit path (#3972 R18): synchronous. Stops both sources, then closes both files against
  /// ONE shared `deadline`. A `.timedOut` file is still owned by its queued close; launch
  /// recovery handles whatever it leaves.
  @discardableResult
  public func stopForQuit(deadline: DispatchTime) -> StopReport {
    if let stopReport { return stopReport }
    stopCapture()
    let report = StopReport(
      microphone: micWriter?.close(until: deadline), callSound: callWriter?.close(until: deadline),
      callSoundSummary: frozenCallSoundSummary ?? nil)
    stopReport = report
    lifecycle = .stopped
    return report
  }

  /// Admission off and both sources stopped, before any file is closed.
  private func stopCapture() {
    lifecycle = .stopping
    generation += 1
    reopenTask?.cancel()
    reopenTask = nil
    admissionOff()
    closeLiveSamples()
    microphone?.onSamples = nil
    microphone?.onInterrupted = nil
    microphone?.onStalled = nil
    microphone?.stopNow()
    microphone = nil
    callSound?.stop()
    // #4121: frozen once, after the source stopped and before it is released; a stop that
    // re-enters while the first one awaits its files keeps this value.
    if frozenCallSoundSummary == nil { frozenCallSoundSummary = .some(callSound?.summary) }
    callSound = nil
  }

  private func admissionOff() { micAdmission.withLock { $0 = nil } }

  /// No live deliveries from here on, and `liveSamples` can no longer be set.
  private func closeLiveSamples() { liveBox.close() }

  // MARK: - Failures and writers

  private func trackFailed(_ track: MeetingTrackKind, _ error: Error) {
    guard !reportedFailure.contains(track) else { return }
    reportedFailure.insert(track)
    onFailure(track, error)
  }

  private func makeWriter(_ track: MeetingTrackKind) -> MeetingTrackWriter {
    let onSegment = self.onSegment
    return MeetingTrackWriter(
      configuration: MeetingTrackWriter.Configuration(
        meetingID: config.meetingID, track: track, folder: config.folder,
        anchorHostTime: anchorHostTime,
        // Microphone: arrival time is approximate (R27). Call sound: the pipeline marks each
        // run break itself (`startsNewRun`), so the writer never infers one; 250 ms only
        // catches a jump the pipeline could not see.
        gapThresholdMs: track == .microphone ? 1_500 : 250),
      onSegmentFinalized: { info in onSegment(track, info) },
      onFailure: { [weak self] error in
        Task { @MainActor in self?.trackFailed(track, error) }
      })
  }

  public enum CallSoundError: Error, Equatable {
    case captureStopped(String)
  }

  nonisolated static func hostTicks(forSeconds seconds: Double) -> UInt64 {
    AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1_000_000_000))
  }
}

/// A meeting's own `HALDeviceInputSource` (#3972 R14): its own AUHAL client on the device,
/// never dictation's. Its capture stream keeps nothing (`.bufferingNewest(0)`); samples arrive
/// only through `onSamples`.
@MainActor
final class HALMeetingMicrophone: MeetingMicrophoneSource {
  private let source = HALDeviceInputSource()

  var onSamples: (@Sendable ([Float], Float) -> Void)? {
    get { source.onSamples }
    set { source.onSamples = newValue }
  }

  var onInterrupted: ((EngineInterruptionCause) -> Void)? {
    get { source.onInterrupted }
    set { source.onInterrupted = newValue }
  }

  /// HAL's existing capture-stall watchdog (no buffers after start), routed to the meeting.
  /// Dictation's handling of the same signal is untouched: this is the meeting's own source.
  var onStalled: (() -> Void)? {
    didSet {
      guard let handler = onStalled else {
        source.onCaptureStalled = nil
        return
      }
      source.onCaptureStalled = { _ in handler() }
    }
  }

  func open(targetUID: String?, inputChannelByDeviceUID: [String: Int]) async throws -> String? {
    source.targetDeviceUID = targetUID
    source.inputChannelByDeviceUID = inputChannelByDeviceUID
    source.captureStreamBufferingPolicy = .bufferingNewest(0)
    return try await source.prepare().deviceUID
  }

  func beginDelivery() async throws {
    // The stream is never read; with `.bufferingNewest(0)` it holds nothing.
    _ = try await source.startCapture()
  }

  func stopNow() { source.stopSynchronously() }
}
