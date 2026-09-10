import Foundation

/// #2648 — the single arbiter of workload overlap on the shared ASR-and-polish
/// resource.
///
/// EG-1's server is launched with no `-np`, so it has ONE slot and serialises
/// every inference request. A file import sends a 500-word part into that slot
/// for roughly twelve seconds; live dictation's polish budget is fifteen. A
/// dictation arriving mid-part would queue behind it and silently lose its
/// polish. The founder's call (2026-09-04) is to LOCK dictation for the
/// duration of an import rather than hand the engine back and forth mid-flight.
///
/// **This is not `EngineRecoveryGate`, and the deciding property is that gate's
/// `mutationCount`** (`EngineRecoveryGate.swift:56-59`): it deliberately admits
/// several non-recovery mutations at once, because its job is to keep recovery
/// away from engine MUTATION, not to admit one workload. This type admits
/// exactly one holder. The two answer different questions and both stay.
///
/// **`@MainActor` rather than an actor, matching `EngineRecoveryGate`.** Every
/// real participant — the record-start paths, the dictation lifecycle, crash
/// recovery, the file import coordinator — is already `@MainActor`, so a claim
/// is a synchronous, non-suspending turn on an isolation they are all on
/// already. MainActor permits synchronous admission and release for current
/// callers. **Atomicity comes from having no suspension between checking and
/// storing ownership; a non-suspending actor method would also be atomic**
/// (`swift-concurrency-patterns.md`
/// an-actor-is-not-a-mutex-for-a-multi-step-transaction). So the thing to
/// preserve is not the isolation but the absence of the `await`: **do not add
/// one to `admit`.**
///
/// The one participant that is NOT on the main actor is EG-1's health probe,
/// which lives a module below and must not import upward. **Health-probe
/// integration is deferred and must land before file import is enabled**: it
/// will read this through an injected `@Sendable () async -> Bool` closure that
/// hops here, and it will never take a token.
///
/// **This is a refusal lock, not a queue.** There is no waiter list: a caller
/// that cannot have the resource is told so immediately and shows the user why.
/// Queueing would make a record press appear to do nothing for minutes.
///
/// **Only the matching token releases.** A stale holder handing back a token
/// from a run that already ended cannot evict the current one.
@MainActor
package final class EngineLease {
  /// The workloads that can occupy the shared resource. Defined once as
  /// `SharedEngineHolder` in `PipelineVocabulary.swift`, because a refusal
  /// names the holder to the user and `RecordingWarningReason` carries it.
  package typealias Holder = SharedEngineHolder

  /// Opaque proof of the claim. The identity is private so a caller cannot
  /// forge one, and equality is by identity so two claims by the same holder
  /// are still two different claims.
  package struct Token: Sendable, Equatable {
    fileprivate let id: UUID
    package let holder: Holder

    fileprivate init(holder: Holder) {
      self.id = UUID()
      self.holder = holder
    }
  }

  /// The answer to one claim: the proof, or WHO refused it.
  ///
  /// One value rather than a claim followed by a second "who has it" read,
  /// because a refusal that has to ask a second question needs a fallback for
  /// the answer coming back empty, and a plausible fallback is indistinguishable
  /// from a real answer downstream — here it would name a job to wait for that
  /// nobody is running.
  package enum Admission: Sendable {
    case granted(Token)
    case refused(by: Holder)
  }

  private var held: Token?

  package init() {}

  /// Claims the resource, or refuses and names the holder.
  ///
  /// No suspension point: see the type's note on atomicity.
  package func admit(_ holder: Holder) -> Admission {
    if let held { return .refused(by: held.holder) }
    let token = Token(holder: holder)
    held = token
    return .granted(token)
  }

  /// Releases the claim if `token` is the live one. Returns whether it was.
  ///
  /// Safe to call more than once, and safe to call with a token from a run that
  /// has already ended — both are no-ops.
  @discardableResult
  package func release(_ token: Token) -> Bool {
    guard held == token else { return false }
    held = nil
    return true
  }

  /// Who holds the resource right now, so a refusal can name it.
  package var currentHolder: Holder? { held?.holder }

  /// What EG-1's health probe reads before it builds a connector. A health
  /// check that reports failure because something else is legitimately using
  /// the engine is worse than no health check.
  package var isBusy: Bool { held != nil }
}
