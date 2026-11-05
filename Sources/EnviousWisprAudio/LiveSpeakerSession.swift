import CoreML
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import os

// MARK: - Output

/// What `LiveSpeakerSession` publishes, in order, on its own executor.
package enum LiveSpeakerUpdate: Sendable, Equatable {
  /// The model loaded; activity for `epoch` follows.
  case ready(epoch: Int)
  /// Newly emitted, final activity (the model never revises an emitted frame).
  /// `unpositionedFrames` counts emitted 10 ms frames whose audio has no written position;
  /// they carry no activity and stay unresolved.
  case activity([LiveSpeakerActivity], unpositionedFrames: Int)
  /// Slot numbering restarted: every activity of an earlier epoch is stale.
  case reset(epoch: Int)
  /// The model cannot run in this session (missing, corrupt or failing bytes). Final.
  case unavailable(LiveSpeakerUnavailable)
}

package enum LiveSpeakerUnavailable: Sendable, Equatable {
  case loadFailed
  case inferenceFailed
}

// MARK: - Runtime seam

/// One streaming speaker model. Used only on `LiveSpeakerSession`'s serial executor, so it
/// need not be thread-safe (the FluidAudio diarizer and its models are not).
package protocol LiveSpeakerRuntime: AnyObject {
  /// Samples per streaming step: feeding this many at a time lets the session ask for
  /// admission before each model step.
  var stepSamples: Int { get }
  /// Model slots per output frame.
  var slotCount: Int { get }
  func append(_ samples: [Float])
  /// Runs every step the buffered audio completes; per-frame slot probabilities in emit order.
  func process() throws -> LiveSpeakerFrames
  func reset()
}

/// Successive 10 ms frames: `probabilities[frame * slots + slot]`.
package struct LiveSpeakerFrames: Sendable, Equatable {
  package let probabilities: [Float]
  package let frameCount: Int

  package init(probabilities: [Float], frameCount: Int) {
    self.probabilities = probabilities
    self.frameCount = frameCount
  }
}

/// Loads a runtime from the admitted model directory. Production: `nemotron3Low`.
package typealias LiveSpeakerRuntimeLoader =
  @Sendable (URL) async throws -> sending any LiveSpeakerRuntime

/// The pinned FluidAudio Nemotron3 diarizer, preset `low` (8 slots, 0.72 s step, 1.04 s
/// latency): the one model the founder chose (#4355 plan §3.0 step 4).
package final class Nemotron3LiveSpeakerRuntime: LiveSpeakerRuntime {
  /// Phase 0 ran this model with `.all`; it is not the CPU-only path that corrupts memory on
  /// macOS 14 (#4376), so one policy serves every supported macOS.
  package static let computeUnits: MLComputeUnits = .all

  private let diarizer: Nemotron3Diarizer
  package let stepSamples: Int
  package let slotCount: Int

  init(diarizer: Nemotron3Diarizer) {
    self.diarizer = diarizer
    stepSamples = Int((diarizer.config.chunkSeconds * Double(diarizer.config.sampleRate)).rounded())
    slotCount = diarizer.config.numSpeakers
  }

  /// Loads ONLY `directory` (the admitted install folder): `Nemotron3Diarizer_low.mlmodelc`
  /// plus `learnable_sil_emb.bin`. Never downloads.
  package static let nemotron3Low: LiveSpeakerRuntimeLoader = { directory in
    let config = Nemotron3Config.low
    let models = try await Nemotron3Models.load(
      config: config, directory: directory, computeUnits: computeUnits)
    return Nemotron3LiveSpeakerRuntime(diarizer: Nemotron3Diarizer(config: config, models: models))
  }

  package func append(_ samples: [Float]) { diarizer.appendAudio(samples) }

  package func process() throws -> LiveSpeakerFrames {
    var probabilities: [Float] = []
    var frames = 0
    for chunk in try diarizer.processBufferedAudio() {
      probabilities.append(contentsOf: chunk.probabilities)
      frames += chunk.frameCount
    }
    return LiveSpeakerFrames(probabilities: probabilities, frameCount: frames)
  }

  package func reset() { diarizer.reset() }
}

// MARK: - Session

/// Separates remote voices on the live call track (#4355 plan §3.3). An optional limb: it
/// never blocks capture or dictation, and its failure leaves the live view on one "Speaker".
///
/// Ownership. The session is an actor whose executor is its own serial dispatch queue, so model
/// loading's bookkeeping, every model step, reset and release run one at a time, off the main
/// actor and off the cooperative pool. Every model step is a synchronous actor method body
/// with no suspension, so nothing interleaves with a step, and reset or release can never touch
/// the model while a step runs. The one suspension is the load itself: calls arriving during it
/// see `.loading` and only queue work; the load re-reads the state when it resumes and releases
/// the model at once if the session closed meanwhile.
///
/// Input. `submit` is nonisolated and never waits: it appends to a lock-held FIFO and asks the
/// actor to drain. The FIFO is bounded by `backlogLimitSamples` (oldest audio dropped first);
/// dropped audio is never fed, so it is counted, not analyzed, and positions never shift. Audio
/// reaches the model one step at a time, with `admit()` asked before each step; a refusal leaves
/// the rest queued for the next drain (the next submit), and a step already running finishes.
///
/// Time. Output frames are 10 ms on the concatenation of audio actually fed; a feed map from
/// those frames to written spans (`MeetingAudioFeedMap`) turns each frame into a span or, for
/// unpositioned audio, into a counted unresolved frame. The map is pruned behind emitted frames.
///
/// Terminal policy. `close()` stops admission at once (logical closure) and discards queued
/// audio; physical release (dropping the model) runs on the executor after any step in flight,
/// then `onReleased` fires exactly once. Nothing is published after `close()`, and a released
/// session never reloads. The caller that stops waiting keeps no handle; the queued release task
/// retains the session until it runs.
package actor LiveSpeakerSession {
  /// The probability above which a slot counts as talking (FluidAudio's `segments` default,
  /// the value Phase 0 scored).
  package static let activityThreshold: Float = 0.5
  /// Samples per output frame (10 ms at 16 kHz).
  package static let frameSamples = 160
  /// 30 s of 16 kHz audio (about 1.9 MB): enough to ride out a long dictation, small enough
  /// that a stalled model never grows memory.
  package static let defaultBacklogLimitSamples = 30 * 16_000

  private enum Phase {
    case idle
    case loading
    case ready(any LiveSpeakerRuntime)
    case failed
    case released
  }

  private enum Pending: Sendable {
    case audio(MeetingLiveAudioChunk)
    case reset
  }

  private struct Inbox: Sendable {
    var items: [Pending] = []
    var samples = 0
    var closed = false
    var drainScheduled = false
    var droppedSamples = 0
  }

  private let queue: DispatchSerialQueue
  nonisolated package var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  private let directory: URL
  private let loader: LiveSpeakerRuntimeLoader
  private let admit: @Sendable () -> Bool
  private let publish: @Sendable (LiveSpeakerUpdate) -> Void
  private let onReleased: @Sendable () -> Void
  private let backlogLimitSamples: Int
  private let inbox = OSAllocatedUnfairLock(initialState: Inbox())
  private let publication = PublicationGate()

  private var phase: Phase = .idle
  /// `release()` ran while the load was suspended; the load finishes the release when it
  /// resumes, because only then is the model actually dropped.
  private var releaseAfterLoad = false
  private var epoch = 0
  private var feedMap = MeetingAudioFeedMap(sampleRate: 16_000)
  private var emittedFrames = 0
  /// Audio taken from the inbox but not yet fed (a step's worth or less waits for admission).
  private var carry: MeetingLiveAudioChunk?

  package init(
    directory: URL,
    admit: @escaping @Sendable () -> Bool,
    backlogLimitSamples: Int = LiveSpeakerSession.defaultBacklogLimitSamples,
    loader: @escaping LiveSpeakerRuntimeLoader = Nemotron3LiveSpeakerRuntime.nemotron3Low,
    publish: @escaping @Sendable (LiveSpeakerUpdate) -> Void,
    onReleased: @escaping @Sendable () -> Void = {}
  ) {
    self.queue = DispatchSerialQueue(label: "com.enviouswispr.meeting.live-speakers", qos: .utility)
    self.directory = directory
    self.admit = admit
    self.backlogLimitSamples = max(backlogLimitSamples, 0)
    self.loader = loader
    self.publish = publish
    self.onReleased = onReleased
  }

  // MARK: Nonisolated entry points (never wait)

  /// Starts loading the model. Idempotent; ignored after `close()`.
  nonisolated package func start() {
    guard !inbox.withLock({ $0.closed }) else { return }
    Task { await self.load() }
  }

  /// Queues call-track audio in order. Never blocks; drops the oldest queued audio past the
  /// backlog limit.
  nonisolated package func submit(_ chunk: MeetingLiveAudioChunk) {
    guard !chunk.samples.isEmpty else { return }
    let schedule = inbox.withLock { box -> Bool in
      guard !box.closed else { return false }
      box.items.append(.audio(chunk))
      box.samples += chunk.samples.count
      Self.trim(&box, limit: backlogLimitSamples)
      return Self.claimDrain(&box)
    }
    if schedule { Task { await self.drain() } }
  }

  /// Restarts slot numbering at this point in the input order (a capture discontinuity).
  nonisolated package func reset() {
    let schedule = inbox.withLock { box -> Bool in
      guard !box.closed else { return false }
      box.items.append(.reset)
      return Self.claimDrain(&box)
    }
    if schedule { Task { await self.drain() } }
  }

  /// Logical closure: admission stops now and queued audio is discarded. Physical release
  /// follows on the executor after any step in flight.
  ///
  /// When `close()` returns, no update will be published any more: it waits only for a
  /// publication already inside `publish` (the callback is short and must not block on the
  /// caller of `close()`; a callback that calls `close()` itself does not deadlock).
  nonisolated package func close() {
    let first = inbox.withLock { box -> Bool in
      guard !box.closed else { return false }
      box.closed = true
      box.items.removeAll()
      box.samples = 0
      return true
    }
    publication.close()
    if first { Task { await self.release() } }
  }

  /// Queued audio dropped for the backlog bound so far (counts only).
  nonisolated package var droppedSamples: Int { inbox.withLock { $0.droppedSamples } }

  private static func claimDrain(_ box: inout Inbox) -> Bool {
    guard !box.drainScheduled else { return false }
    box.drainScheduled = true
    return true
  }

  /// Drops whole oldest audio items, then the front of the oldest, until the queue fits.
  private static func trim(_ box: inout Inbox, limit: Int) {
    while box.samples > limit,
      let index = box.items.firstIndex(where: {
        if case .audio = $0 { return true } else { return false }
      })
    {
      guard case .audio(let chunk) = box.items[index] else { break }
      let excess = box.samples - limit
      if chunk.samples.count <= excess {
        box.items.remove(at: index)
        box.samples -= chunk.samples.count
        box.droppedSamples += chunk.samples.count
      } else {
        box.items[index] = .audio(chunk.subrange(excess..<chunk.samples.count))
        box.samples -= excess
        box.droppedSamples += excess
      }
    }
  }

  // MARK: Executor work

  private var isClosed: Bool { inbox.withLock { $0.closed } }

  private func load() async {
    guard case .idle = phase, !isClosed else { return }
    phase = .loading
    var loaded: (any LiveSpeakerRuntime)?
    do { loaded = try await loader(directory) } catch { loaded = nil }
    // Re-read after the suspension: close() may have run meanwhile.
    if releaseAfterLoad {
      loaded = nil  // dropped unused, before release is reported
      finishRelease()
      return
    }
    guard case .loading = phase else { return }
    guard let runtime = loaded else {
      phase = .failed
      discardQueue()
      send(.unavailable(.loadFailed))
      return
    }
    if isClosed {
      // close() ran but its release task has not yet: drop the model now; release() still
      // fires `onReleased` when it runs.
      phase = .failed
      return
    }
    phase = .ready(runtime)
    send(.ready(epoch: epoch))
    drain()
  }

  private func drain() {
    inbox.withLock { $0.drainScheduled = false }
    guard case .ready(let runtime) = phase else { return }
    while !isClosed {
      // Admission is asked before each model step. Queued audio leaves the inbox only once a
      // step is admitted, so refused audio always stays under the backlog bound.
      var admitted = false
      if carry == nil {
        // Every look-and-take is one lock region with the closed check, so close() can never
        // empty the queue between them. `admit` runs OUTSIDE the lock (it is the caller's
        // closure); audio leaves the queue only after it said yes, so refused audio always
        // stays under the bound.
        enum Front { case none, reset, audio }
        let front = inbox.withLock { box -> Front in
          guard !box.closed, let first = box.items.first else { return .none }
          if case .reset = first {
            box.items.removeFirst()
            return .reset
          }
          return .audio
        }
        switch front {
        case .none:
          return
        case .reset:
          restart(runtime)
          continue
        case .audio:
          guard admit() else { return }  // the next submit retries
          admitted = true
          // The front may have changed meanwhile (trimmed, or closed): take whatever audio
          // is first now, or stop.
          carry = inbox.withLock { box -> MeetingLiveAudioChunk? in
            guard !box.closed, case .audio(let chunk) = box.items.first else { return nil }
            box.items.removeFirst()
            box.samples -= chunk.samples.count
            return chunk
          }
        }
      }
      guard let pending = carry else { continue }
      let take = min(runtime.stepSamples, pending.samples.count)
      guard admitted || admit() else {
        // Mid-chunk refusal: the rest goes back to the FRONT, in order, under the bound.
        inbox.withLock { box in
          guard !box.closed else { return }  // close() discarded the queue; so is this
          box.items.insert(.audio(pending), at: 0)
          box.samples += pending.samples.count
          Self.trim(&box, limit: backlogLimitSamples)
        }
        carry = nil
        return
      }
      let piece = pending.subrange(0..<take)
      carry = take < pending.samples.count ? pending.subrange(take..<pending.samples.count) : nil
      feedMap.commit(frames: piece.samples.count, slices: piece.slices)
      runtime.append(piece.samples)
      let frames: LiveSpeakerFrames
      do { frames = try runtime.process() } catch {
        phase = .failed
        carry = nil
        discardQueue()
        send(.unavailable(.inferenceFailed))
        return
      }
      guard frames.frameCount > 0 else { continue }
      let update = activities(frames, slots: runtime.slotCount)
      send(update)
    }
  }

  private func restart(_ runtime: any LiveSpeakerRuntime) {
    runtime.reset()
    epoch += 1
    feedMap = MeetingAudioFeedMap(sampleRate: 16_000)
    emittedFrames = 0
    carry = nil
    send(.reset(epoch: epoch))
  }

  /// Turns emitted frames into written-span activity: one entry per run of frames with the
  /// same active slots over contiguous audio of one recording, track and run.
  private func activities(_ frames: LiveSpeakerFrames, slots: Int) -> LiveSpeakerUpdate {
    var result: [LiveSpeakerActivity] = []
    var unpositioned = 0
    for frame in 0..<frames.frameCount {
      let index = emittedFrames + frame
      let base = frame * slots
      var active: [Int] = []
      for slot in 0..<slots where frames.probabilities[base + slot] > Self.activityThreshold {
        active.append(slot)
      }
      guard
        let span = feedMap.project(
          startFrame: index * Self.frameSamples, endFrame: (index + 1) * Self.frameSamples)
      else {
        unpositioned += 1
        continue
      }
      if let last = result.last, last.activeSlots == active, last.span.recording == span.recording,
        last.span.track == span.track, last.span.run == span.run,
        last.span.endSample == span.startSample,
        let merged = MeetingAudioSpan(
          recording: span.recording, track: span.track, run: span.run,
          startSample: last.span.startSample, sampleCount: last.span.sampleCount + span.sampleCount)
      {
        result[result.count - 1] = LiveSpeakerActivity(
          epoch: epoch, span: merged, activeSlots: active)
      } else {
        result.append(LiveSpeakerActivity(epoch: epoch, span: span, activeSlots: active))
      }
    }
    emittedFrames += frames.frameCount
    feedMap.prune(before: emittedFrames * Self.frameSamples)
    return .activity(result, unpositionedFrames: unpositioned)
  }

  /// Every publication goes through the gate: after `close()` returns, none starts.
  private func send(_ update: LiveSpeakerUpdate) {
    publication.publish { publish(update) }
  }

  private func discardQueue() {
    inbox.withLock { box in
      box.items.removeAll()
      box.samples = 0
    }
  }

  /// Runs once, after any step in flight (steps never suspend). During a suspended load the
  /// model is not ours yet, so the load completes the release when it resumes.
  private func release() {
    if case .loading = phase {
      releaseAfterLoad = true
      return
    }
    finishRelease()
  }

  private func finishRelease() {
    phase = .released
    carry = nil
    feedMap = MeetingAudioFeedMap(sampleRate: 16_000)
    onReleased()
  }
}

/// Orders publication against `close()`: a publication runs entirely before the closing or not
/// at all. Recursive so a `publish` callback that calls `close()` on its own thread does not
/// deadlock.
// @unchecked Sendable: `closed` is read and written only while holding `lock`.
private final class PublicationGate: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var closed = false

  func publish(_ body: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    body()
  }

  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }
}
