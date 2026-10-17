import EnviousWisprASR
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// Serializes the OPEN-A-SESSION transaction, which suspends at every step.
///
/// **An actor is not enough for this, and the first attempt proved it.**
/// `WhisperPreviewRecognizer` is an actor, so `openSession` calls are serialized
/// — but an actor is reentrant at every `await`, and that method awaits three
/// times before it records the new session. A second call arriving during any of
/// those suspensions also read `previousSession == nil`, so both proceeded and
/// both started decode loops over the same cached WhisperKit instance (before #3735): exactly
/// the concurrent-transcribe corruption the retired WhisperKit streaming session's `cancel()`
/// documents. Cloud review caught it after the serialization was added.
///
/// The lock is held ACROSS the suspensions instead. This is the repo's own
/// pattern, not a new invention: `LocaleClaims` exists for the identical
/// reason on a different subject, and its doc records that four rounds of
/// one-defect-per-round were the signal that patching was the problem.
///
/// FIFO hand-off ported WHOLE from that primitive — `release()` keeps `held`
/// true and passes ownership straight to the next waiter, so there is no gap for
/// a third caller and no starvation. That doc also records that porting it
/// PARTIALLY is what caused its own first defect, so this is a complete copy
/// rather than a simplification.
package actor PreviewSessionTurnover {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  package init() {}

  package func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  package func release() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}

/// The Live Preview engine backed by the downloadable universal model
/// (#2108, epic #2077 chunk 4), on transcribe.cpp whisper-small since #3735.
///
/// Apple's engine needs macOS 26 and only recognises languages Apple has already
/// installed — measured at 7 of 54 locales on a US-English Mac, and not by
/// region. This one has no OS floor and carries its own languages, which is the
/// entire reason it exists.
///
/// Shaped like `ApplePreviewRecognizer` on purpose: the actor owns preparation
/// that outlives a recording, and a separate handle carries each session's own
/// resources. That split is not style — #1988 produced seven defects of one shape
/// from session state living on the engine actor, where reentrancy let a
/// suspended operation resume onto fields a newer session had replaced.
///
/// **Every native call stays behind `TranscribeCppPreviewRuntime` in the ASR
/// module**, which decodes on the executor's preview lane, so the allowlist that
/// keeps this limb away from capture and the recording path never has to be
/// widened for a decoding option.
package actor WhisperPreviewRecognizer: LivePreviewEngine {

  /// Stable identity for this engine in a `LivePreviewEngineKey`.
  package static let engineID = "whisper_preview"

  private let runtime: TranscribeCppPreviewRuntime
  private let language: String?

  /// The session most recently opened, so the NEXT `openSession` can wait for it
  /// to finish tearing down before starting another decode loop over the SAME
  /// cached model.
  ///
  /// This is not belt-and-braces. An aborted native run still returns on its own
  /// schedule, and the rolling session's `cancel()` waits for that return. The
  /// coordinator cancels its session task WITHOUT awaiting `end()`, so on a rapid
  /// stop/start the old session can still be inside that wait when a new one
  /// opens. The executor would queue the second run rather than overlap it, but a
  /// session that has not finished tearing down could still publish into the new
  /// recording's pill. Apple's engine has no equivalent hazard because each of its
  /// sessions owns its own analyzer; ours share one model.
  private var previousSession: TranscribeCppPreviewSession?

  /// Held across the whole open transaction. See `PreviewSessionTurnover`.
  private let turnover = PreviewSessionTurnover()

  /// `language` is the already-resolved decode language, or nil for auto —
  /// resolved by the resolver, which owns what `.auto` means for THIS engine.
  package init(runtime: TranscribeCppPreviewRuntime, language: String?) {
    self.runtime = runtime
    self.language = language
  }

  /// Claim the model. Throws rather than downloading: a display-only limb must
  /// not be able to start a model fetch, and the runtime refuses an unadmitted
  /// artifact before it touches the filesystem.
  package func prepare() async throws {
    try await runtime.ensureLoaded()
  }

  /// Open a session and start delivering text.
  ///
  /// `vocabulary.lookups` is this recording's Custom Words snapshot, passed IN rather than
  /// read from engine state — the stored-property version was racy, and a session
  /// opened straight after preparation could capture nil and mangle a user's own
  /// names for a whole recording.
  package func openSession(
    vocabulary: LivePreviewVocabulary,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession {
    // #3457: Apple-only hints/application controls do not change Universal (#3839).
    let lookups = vocabulary.lookups
    // Hold the lock across the ENTIRE transaction — end the old session, build
    // the new one, attach it, record it. Every one of those steps suspends, and
    // actor isolation alone lets a second caller in at any of them.
    await turnover.acquire()
    do {
      await previousSession?.end()

      let handle = TranscribeCppPreviewSession(lookups: lookups, onText: onText)
      let session: any WhisperIncrementalSession
      do {
        session = try await runtime.makeSession(
          language: language,
          // The retention cap the rolling core applies before it stores or
          // publishes anything. The word-boundary-aware trim still runs
          // downstream; this stops the ASR actor holding a long transcript at all.
          hypothesisRetentionLimit: LivePreviewTextBound.maxCharacters,
          onHypothesis: handle.enqueue)
      } catch {
        // The handle already started its publisher task: end it, or a refused
        // open leaves that task waiting on a stream nothing will ever finish.
        await handle.end()
        throw error
      }
      await handle.attach(session)
      previousSession = handle
      await turnover.release()
      return handle
    } catch {
      // Release on the throwing path too: a lock that leaks on failure wedges
      // every later recording, which is worse than the failure that caused it.
      await turnover.release()
      throw error
    }
  }
}
