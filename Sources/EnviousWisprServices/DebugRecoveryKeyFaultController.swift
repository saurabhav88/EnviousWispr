#if DEBUG

  import Foundation
  import Security

  /// #1707 Phase 3 (§11.1): DEBUG-only, environment-gated fault-injection seam
  /// for the Keychain transient-vs-terminal fix's Live UAT leg — arms the NEXT
  /// `RecoveryKeyStore.retrieve()` call to throw a named
  /// `RecoveryKeyStoreError.retrieveFailed(status)`, simulating a locked-
  /// keychain-state read failure without a real signed-release Data-
  /// Protection-Keychain (architecturally a different backend,
  /// `RecoveryKeyStore.swift:17-20`, out of scope for this automated
  /// harness). Whole-file `#if DEBUG`: the release build has no runtime
  /// environment check, no optional dependency, no protocol conformance
  /// slot, and no command-string literal referencing this feature at all —
  /// it is not merely disabled at runtime, the code does not exist in a
  /// release compilation. Release validation: `nm`/`strings` absence checks.
  ///
  /// A singleton (not injected through `RecoveryKeyStore`'s init) because
  /// `RecoveryKeyStore` is a value type constructed fresh at many call
  /// sites; every instance must observe the SAME armed fault regardless of
  /// which one a given code path happened to construct. `RecoveryKeyStore`
  /// itself is off-MainActor by design (`keychain-not-mainactor`), so this
  /// type is lock-protected, not actor-isolated.
  public final class DebugRecoveryKeyFaultController: @unchecked Sendable {
    public static let shared = DebugRecoveryKeyFaultController()

    private let lock = NSLock()
    private var armed: (sessionID: String?, status: OSStatus)?

    private init() {}

    /// Arm the NEXT `retrieve()` call to fail with `status`. One-shot —
    /// consumed by the first read that observes it, so a Live UAT scenario
    /// staging a single deferred attempt cannot leak into a later real read.
    ///
    /// `sessionID`, when provided, scopes the fault to that EXACT recovery
    /// session — a `retrieve()` for any other id passes through untouched
    /// (GitHub cloud review, PR #1732): the full Swift Testing suite runs
    /// suites in parallel, and this controller is a process-wide singleton,
    /// so an un-scoped one-shot fault could be consumed by an unrelated
    /// concurrent `RecoveryKeyStore.retrieve()` call in a different test
    /// suite (`RecoveryKeyStoreTests`, `RecoveryCoordinatorTests`) instead of
    /// the specific replay this test armed it for. `nil` preserves the
    /// original "fire on whichever call comes next" behavior the Live UAT
    /// fault-injection endpoint uses, where there is no concurrent-suite
    /// contention to worry about.
    public func arm(status: OSStatus, forSessionID sessionID: String? = nil) {
      lock.lock()
      defer { lock.unlock() }
      armed = (sessionID, status)
    }

    /// Consume the armed status for `recoverySessionID` (if any and if it
    /// matches — a `nil`-scoped arm matches any id), clearing it. Called by
    /// `RecoveryKeyStore.retrieve()` before every real read.
    func consumeArmedStatus(forSessionID recoverySessionID: String) -> OSStatus? {
      lock.lock()
      defer { lock.unlock() }
      guard let armed, armed.sessionID == nil || armed.sessionID == recoverySessionID else {
        return nil
      }
      self.armed = nil
      return armed.status
    }
  }

#endif
