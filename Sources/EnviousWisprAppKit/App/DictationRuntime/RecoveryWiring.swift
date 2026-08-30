import Foundation

/// How the recovery seams are bound to the coordinator that answers them.
///
/// **Its own namespace rather than a method on `DictationRuntime`, and that is a
/// constraint rather than taste.** `DictationRuntimeCeilingsTests` caps the
/// runtime's non-private `func` count at 8, and raising it requires an
/// architecture entry. The wiring needed to be reachable from a test (#2356);
/// the ceiling is what decided it should not live on the runtime to get there.
enum RecoveryWiring {

  /// The five recovery seams, bound to one collaborator.
  ///
  /// **Extracted so a test can reach the WIRE, which nothing did** (#2356). Both
  /// halves were well covered and the line between them was not:
  /// `RecoveryCoordinatorTests` drives `discardActiveRecovery()` directly, and
  /// `RecordingStarterStartPathTests` builds its own `RecoveryAccess` with a probe
  /// closure — so the composition root's binding was the one site no test named.
  /// Replacing `discardActive:` with `{}` here left every suite green, which is
  /// the whole failure: Discard would reach nobody and crash recovery would keep
  /// the engine while the user watched a button do nothing.
  ///
  /// A source-text guard was the alternative and was rejected: this repo has
  /// spent several rounds learning that a check over spelling is evadable, and
  /// the honest repair for an untested site is to make it REACHABLE rather than
  /// to assert what it looks like.
  ///
  /// Every closure below binds the SAME coordinator; they were five separate
  /// arguments until the architectural ceiling caught the accretion. Still bare
  /// closures, so the starter stays off its collaborator cap and the kernel never
  /// sees the coordinator.
  static func access(
    binding recoveryCoordinator: RecoveryCoordinator
  ) -> RecordingStarter.RecoveryAccess {
    RecordingStarter.RecoveryAccess(
    // #1063 PR1: arm crash recovery for this start.
    makeDirective: { settings, backend, lid in
      await recoveryCoordinator.makeDirective(
        settings: settings, backendType: backend, supportsLanguageDetection: lid)
    },
    // #1063 PR1 (Codex r3): a PTT release or concurrent-toggle stop landing in
    // the arm window mints no session, so the lifecycle coordinator sees no
    // terminal state — the starter cleans the armed spool/key directly. #1464:
    // a pre-start abort has no `RecordingOutcome`, so it routes to the
    // dedicated coordinator entry point (always a discard — nothing was
    // captured).
    cleanupArm: { id in
      recoveryCoordinator.handlePreStartAbort(recoverySessionID: id)
    },
    // #1063 PR2: the recording gate — a press while recovery holds the shared
    // engine mints no session (shows the "recovering" pill).
    isRecovering: { recoveryCoordinator.isRecovering },
    // #1707 Phase 3 (§3.1): a refused press yields the engine BETWEEN a
    // multi-item recovery scan's items, not only after the whole scan.
    signalPendingLiveStart: { recoveryCoordinator.pendingLiveStartSignal = true },
    // #2292 C4b: the recovery notice's Discard button, bound at its own
    // presentation rather than routed through a settable overlay sink.
    discardActive: { recoveryCoordinator.discardActiveRecovery() })
  }
}
