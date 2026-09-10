import EnviousWisprPipeline

/// #2648 — the narrow seam onto `EngineLease`, so nothing that COMPETES for the
/// shared ASR-and-polish resource has to know the authority that arbitrates it.
///
/// The same shape and the same reason as `RecoveryEngineClaim` wrapping
/// `EngineRecoveryGate`: the composition root owns the one lease and hands each
/// participant a pair of closures bound to it.
///
/// **The holder is bound at wiring time, not passed at the call site.** A start
/// path that could name its own holder could claim the resource AS the file
/// import, and nothing in the type system would notice. Each participant gets an
/// instance that can only ever claim as itself.
@MainActor
struct EngineAdmissionAccess {
  /// Claims the shared resource for THIS participant. A refusal carries the
  /// current holder with it, in one answer, so a caller never has to ask a
  /// second question and invent a fallback when it comes back empty.
  let claim: @MainActor () -> EngineLease.Admission

  /// Hands the claim back. Only the matching token releases, so a late call from
  /// an abandoned attempt cannot evict a live one.
  let release: @MainActor (EngineLease.Token) -> Void

  /// Who holds the resource right now, WITHOUT taking it.
  ///
  /// **A peek, for refusing early.** File import has to warm the engine the user
  /// picked before it can claim, and that takes seconds; asking the user to
  /// watch "Getting the engine ready" and only then telling them a dictation is
  /// running is a worse answer than telling them at the press. `claim()` is
  /// still what decides — this only refuses sooner in the case that is already
  /// certain.
  let currentHolder: @MainActor () -> EngineLease.Holder?

  /// Binds a participant to the one live lease.
  static func live(lease: EngineLease, as holder: EngineLease.Holder) -> Self {
    Self(
      claim: { lease.admit(holder) },
      release: { lease.release($0) },
      currentHolder: { lease.currentHolder })
  }

  /// Same structural mitigation as `RecoveryEngineClaim.alwaysAllowedForTesting`
  /// and `EngineMutationScope.alwaysAllowedForTesting` — zero production
  /// references, enforced by the same freeze test
  /// (`EngineMutationInventoryFreezeTests`, test 5).
  ///
  /// A test that is not exercising admission gets a claim that always succeeds.
  /// A test that IS exercising it builds a real `EngineLease` and calls
  /// `live(lease:as:)`, which is what the record-trigger audit does.
  internal static let alwaysAllowedForTesting = Self(
    claim: { EngineLease().admit(.dictation) },
    release: { _ in },
    currentHolder: { nil })
}
