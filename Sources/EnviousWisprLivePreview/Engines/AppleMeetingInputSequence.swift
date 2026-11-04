import AVFoundation
import EnviousWisprCore
import Foundation
import Speech

/// One Apple meeting session's input queue and bookkeeping (#4355 plan §3.1, PR A chunk 6a).
///
/// Apple reports result times on the concatenation of the input its analyzer CONSUMED, and
/// `AnalyzerInput(buffer:)` carries no start time. So a buffer becomes timeline only at the
/// moment the analyzer takes it. `AnalyzerInput` copies its buffer (its `buffer` is not the
/// object given to it), so identity cannot connect what was fed to what was taken. Meeting
/// sessions therefore queue an `Envelope` (the converted buffer plus its frames and written
/// slices) in their own bounded `AsyncStream`, and build the `AnalyzerInput` only when the
/// analyzer takes the envelope:
///
/// - `push` yields an envelope. When the stream is full it drops the OLDEST waiting envelope
///   (`.bufferingNewest`, the policy the session's stream always had): never heard, never
///   timeline. The stream owns buffering, cancellation and termination.
/// - The analyzer's iterator (`Sequence`) takes the next envelope and commits it to the map at
///   the absolute input frame where it begins, under the lock `project` and `prune` take.
/// Strong buffer references live only in queued envelopes' boxes (at most `capacity`); a box
/// is emptied when its envelope is taken, dropped or cleared. Committed records hold frame
/// counts and spans, never audio.
@available(macOS 26.0, *)
final class AppleMeetingInputRecorder: @unchecked Sendable {
  /// Holds one queued buffer until it is taken, dropped or released by `clear()`.
  final class BufferBox: @unchecked Sendable {
    fileprivate var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  }

  struct Envelope: @unchecked Sendable {
    let box: BufferBox
    let frames: Int
    /// Nil when this input's correspondence with written samples is not established.
    let slices: [MeetingLiveAudioSlice]?
  }

  let capacity: Int
  private let stream: AsyncStream<Envelope>
  private let continuation: AsyncStream<Envelope>.Continuation
  private let lock = NSLock()
  private var map: MeetingAudioFeedMap
  /// Set once an input could not be shown to correspond one to one with its written samples
  /// (a mismatched or failed conversion): a converter that buffers would shift every later
  /// frame, so exact mapping never resumes.
  private var correspondenceLost: Bool
  /// Boxes of envelopes still in the stream (at most `capacity`), so `clear()` can release
  /// their buffers at once even though the stream still holds the envelopes.
  private var queued: [BufferBox] = []
  /// Set by `clear()`: nothing more is delivered or committed.
  private var cleared = false

  /// `exact`: the session's input rate and channel count equal the written audio's, so one
  /// converted frame is one written sample. Otherwise every input is unpositioned time.
  init(sampleRate: Double, exact: Bool, capacity: Int) {
    map = MeetingAudioFeedMap(sampleRate: sampleRate)
    correspondenceLost = !exact
    self.capacity = max(1, capacity)
    (stream, continuation) = AsyncStream<Envelope>.makeStream(
      bufferingPolicy: .bufferingNewest(self.capacity))
  }

  /// Queues `buffer` (what the analyzer will get), its `frames`, and the written slices of the
  /// `sourceFrames` samples it was converted from. A conversion that did not return exactly one
  /// frame per source sample loses correspondence for good. Returns the stream's verdict.
  @discardableResult
  func push(
    _ buffer: AVAudioPCMBuffer, frames: Int, sourceFrames: Int,
    slices: [MeetingLiveAudioSlice]
  ) -> AsyncStream<Envelope>.Continuation.YieldResult {
    let box = BufferBox(buffer)
    let positioned: [MeetingLiveAudioSlice]?? = lock.withLock {
      guard !cleared else { return nil }
      if frames != sourceFrames { correspondenceLost = true }
      queued.append(box)
      return .some(correspondenceLost ? nil : slices)
    }
    guard let positioned else { return .terminated }
    let result = continuation.yield(Envelope(box: box, frames: frames, slices: positioned))
    lock.withLock {
      switch result {
      case .enqueued: break
      case .dropped(let gone): forget(gone.box)
      case .terminated: forget(box)
      @unknown default: forget(box)
      }
    }
    return result
  }

  /// `box` left the stream: its buffer is released. Caller holds the lock.
  private func forget(_ box: BufferBox) {
    box.buffer = nil
    queued.removeAll { $0 === box }
  }

  /// A conversion ran and its outcome is unknown (an error, or no output for input it may have
  /// buffered): no later input can be shown to correspond, so exact mapping stops for good.
  func loseCorrespondence() {
    lock.withLock { correspondenceLost = true }
  }

  /// No more input: queued envelopes still drain, then the analyzer sees the end.
  func finish() {
    continuation.finish()
  }

  /// The session ended for good and its accepted results were delivered: nothing more is
  /// queued, delivered or committed, queued buffers are released now, and the map is emptied.
  func clear() {
    lock.withLock {
      cleared = true
      for box in queued { box.buffer = nil }
      queued.removeAll()
      map = MeetingAudioFeedMap(sampleRate: map.sampleRate)
    }
    continuation.finish()
  }

  /// Commits `envelope` as the next stretch of input time and wraps it for the analyzer; nil
  /// once cleared (the analyzer then sees the end).
  fileprivate func take(_ envelope: Envelope) -> AnalyzerInput? {
    let buffer: AVAudioPCMBuffer? = lock.withLock {
      guard !cleared, let buffer = envelope.box.buffer else { return nil }
      forget(envelope.box)
      map.commit(frames: envelope.frames, slices: envelope.slices)
      return buffer
    }
    guard let buffer else { return nil }
    nonisolated(unsafe) let input = buffer
    return AnalyzerInput(buffer: input)
  }

  /// The written span of a result's session-local range, or nil.
  func project(startSeconds: Double, endSeconds: Double) -> MeetingAudioSpan? {
    lock.withLock { map.project(startSeconds: startSeconds, endSeconds: endSeconds) }
  }

  /// Forgets committed input that ends at or before `seconds`; offsets stay absolute.
  func prune(beforeSeconds seconds: Double) {
    lock.withLock { map.prune(before: map.frame(atSeconds: seconds, roundingUp: false)) }
  }

  /// Storage held now, for reports and tests.
  var storage: (queuedBuffers: Int, records: Int, slices: Int, consumedFrames: Int) {
    lock.withLock { (queued.count, map.recordCount, map.sliceCount, map.consumedFrames) }
  }

  /// The analyzer's input sequence. One iterator per session (the analyzer's).
  var sequence: Sequence { Sequence(base: stream, recorder: self) }

  struct Sequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let base: AsyncStream<Envelope>
    let recorder: AppleMeetingInputRecorder

    struct AsyncIterator: AsyncIteratorProtocol {
      var base: AsyncStream<Envelope>.AsyncIterator
      let recorder: AppleMeetingInputRecorder

      /// A cancelled analyzer gets the end and commits nothing more.
      mutating func next() async -> AnalyzerInput? {
        guard !Task.isCancelled, let envelope = await base.next(), !Task.isCancelled else {
          return nil
        }
        return recorder.take(envelope)
      }
    }

    func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(base: base.makeAsyncIterator(), recorder: recorder)
    }
  }
}
