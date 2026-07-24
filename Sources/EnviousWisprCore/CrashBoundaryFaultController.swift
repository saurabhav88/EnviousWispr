#if DEBUG
  import Foundation

  /// #1755 chunk 6 — the closed crash-boundary vocabulary for the Bible Open
  /// decision #5 Live UAT matrix (plan §11.1 leg 5). Exactly these five; a new
  /// boundary is a plan change, not a string.
  public enum CrashBoundary: String, CaseIterable, Sendable {
    case retryExhaustionDecided = "retry_exhaustion_decided"
    case liveTerminalPublished = "live_terminal_published"
    case beforeSpoolDelete = "before_spool_delete"
    case beforeKeyDelete = "before_key_delete"
    case destructionAPIReturn = "destruction_api_return"
  }

  /// The exact on-disk record for both the arm and the reached artifacts —
  /// trial identity + boundary only. Never a recovery ID, path, transcript,
  /// or error text.
  public struct CrashBoundarySignalRecord: Codable, Sendable, Equatable {
    public let trialID: String
    public let boundary: String
    public init(trialID: String, boundary: String) {
      self.trialID = trialID
      self.boundary = boundary
    }
  }

  /// #1755 chunk 6 — DEBUG-only crash-boundary holds (plan §10). Mirrors the
  /// `BatchDecodeFaultSnapshotFile` atomic-plist signal pattern with one
  /// controller owning arm/consume/publish/hold under a single lock:
  ///
  /// - **Arm** is IN-PROCESS state established only by the acknowledged arm
  ///   command; the arm artifact is external evidence/cleanup material. A
  ///   fresh process never activates a stale on-disk arm.
  /// - **One-shot consumption:** the first matching hit claims the live arm,
  ///   removes the arm artifact, and only then publishes the reached
  ///   artifact — all under the lock. A wrong-boundary hit leaves the arm
  ///   intact; a second matching hit finds no arm and passes through. If the
  ///   reached publication fails, the hit fails CLOSED: no reached claim, no
  ///   hold.
  /// - **Real holds:** after publishing, the execution path parks on a
  ///   semaphore until the app is killed or a test release fires. No clocks.
  /// - **`destruction_api_return` gate:** while that boundary is armed, the
  ///   key-delete pre-point is GATED (parked without consuming or
  ///   publishing) in BOTH schedules; only the caller-side hook that runs
  ///   after `handleRecordingEndedWithoutDurableSave(...)` returned may
  ///   consume and publish.
  /// - **External query:** the reached artifact is a plain plist read —
  ///   usable from another process while a hold deliberately stops the
  ///   MainActor. Missing, malformed, wrong-trial, or wrong-boundary records
  ///   all read as "not reached."
  ///
  /// Comments describe practical limits: the lock serializes THIS
  /// controller's state; it does not make unrelated concurrent writers to the
  /// shared `/tmp` paths impossible.
  public final class CrashBoundaryFaultController: @unchecked Sendable {
    public static let shared = CrashBoundaryFaultController(
      armFilePath: "/tmp/com.enviouswispr.crash-boundary-arm",
      reachedFilePath: "/tmp/com.enviouswispr.crash-boundary-reached")

    private let armFilePath: String
    private let reachedFilePath: String
    private let lock = NSLock()
    private var liveArm: (trialID: String, boundary: CrashBoundary)?
    private var released = false
    private var parkedHolds: [DispatchSemaphore] = []
    /// Persistent E-gate: once `destruction_api_return` publishes (consuming
    /// the arm), the key-delete pre-point must STILL gate until release/clear
    /// — the process is meant to be frozen for the kill.
    private var destructionAPIReturnGateActive = false

    /// Test-only publication observer: invoked synchronously AFTER the
    /// reached artifact is written and BEFORE the path parks — the
    /// deterministic signal tests release on. Production never sets it.
    public var onPublishForTesting: (@Sendable (CrashBoundary) -> Void)?

    /// Test-only gate-decision observer for the `.beforeKeyDelete` pre-point:
    /// `true` when the hit was gated, `false` when it passed. Fires before
    /// the park. Production never sets it.
    public var onKeyDeleteGateDecisionForTesting: (@Sendable (Bool) -> Void)?

    /// Isolated instances (tests) take their own file paths; production uses
    /// `.shared`. A new controller NEVER reads the on-disk artifacts to
    /// activate an arm.
    public init(armFilePath: String, reachedFilePath: String) {
      self.armFilePath = armFilePath
      self.reachedFilePath = reachedFilePath
    }

    // MARK: - Commands

    /// Arm exactly one `(trialID, boundary)`. Returns true ONLY after the
    /// in-process arm is live AND the arm artifact is durably written — the
    /// acknowledgement the endpoint replies OK on. An empty trial ID fails.
    public func arm(trialID: String, boundary: CrashBoundary) -> Bool {
      guard !trialID.isEmpty else { return false }
      let record = CrashBoundarySignalRecord(trialID: trialID, boundary: boundary.rawValue)
      guard let data = try? PropertyListEncoder().encode(record) else { return false }
      lock.lock()
      defer { lock.unlock() }
      do {
        try data.write(to: URL(fileURLWithPath: armFilePath), options: .atomic)
      } catch {
        return false
      }
      liveArm = (trialID, boundary)
      released = false
      destructionAPIReturnGateActive = false
      return true
    }

    /// Remove both artifacts, drop the live arm, and release every parked
    /// hold/gate (the external harness also clears before each arm and after
    /// each relaunch, because `kill -9` prevents in-process cleanup).
    public func clear() {
      let parked: [DispatchSemaphore] = lock.withLock {
        liveArm = nil
        released = true
        destructionAPIReturnGateActive = false
        let p = parkedHolds
        parkedHolds = []
        return p
      }
      for hold in parked { hold.signal() }
      try? FileManager.default.removeItem(atPath: armFilePath)
      try? FileManager.default.removeItem(atPath: reachedFilePath)
    }

    /// Test-only release: unblock every parked hold/gate WITHOUT touching the
    /// artifacts (the test still wants to read the reached record). Never a
    /// production escape hatch — nothing in production calls this.
    public func releaseHeldForTesting() {
      let parked: [DispatchSemaphore] = lock.withLock {
        released = true
        destructionAPIReturnGateActive = false
        let p = parkedHolds
        parkedHolds = []
        return p
      }
      for hold in parked { hold.signal() }
    }

    // MARK: - Queries

    /// The authoritative post-hold query: a direct file read of the reached
    /// artifact requiring the EXACT pair. Static + file-based so an external
    /// process can use it while a hold stops the MainActor.
    public static func readReached(
      trialID: String, boundary: CrashBoundary, reachedFilePath: String
    ) -> Bool {
      guard !trialID.isEmpty,
        let data = try? Data(contentsOf: URL(fileURLWithPath: reachedFilePath)),
        let record = try? PropertyListDecoder().decode(CrashBoundarySignalRecord.self, from: data)
      else { return false }
      return record.trialID == trialID && record.boundary == boundary.rawValue
    }

    /// Instance convenience over this controller's own reached path.
    public func isReached(trialID: String, boundary: CrashBoundary) -> Bool {
      Self.readReached(trialID: trialID, boundary: boundary, reachedFilePath: reachedFilePath)
    }

    /// Whether an arm is live in THIS process (diagnostics; never evidence of
    /// "reached").
    public var hasLiveArmForTesting: Bool { lock.withLock { liveArm != nil } }

    // MARK: - The hook

    /// Called from the five production hook sites. Unarmed or wrong-boundary
    /// calls return immediately (pre-chunk behavior). A matching hit consumes
    /// the arm, publishes the reached record, and PARKS the calling path until
    /// kill/clear/test-release. While `destruction_api_return` is armed, a
    /// `.beforeKeyDelete` hit is gated (parked, NOT consumed/published) so the
    /// caller-side hook can prove the API returned first — in either schedule.
    public func boundaryReached(_ boundary: CrashBoundary) {
      enum Role { case none, consumed, gated(DispatchSemaphore) }
      var role = Role.none
      lock.lock()
      if !released {
        let mustGateKey =
          boundary == .beforeKeyDelete
          && (liveArm?.boundary == .destructionAPIReturn || destructionAPIReturnGateActive)
        if mustGateKey {
          // The E-gate: park the key path without consuming or publishing —
          // in BOTH schedules (armed-not-yet-published, and already
          // published via the persistent gate flag).
          let gate = DispatchSemaphore(value: 0)
          parkedHolds.append(gate)
          role = .gated(gate)
        } else if let arm = liveArm, arm.boundary == boundary {
          // One-shot: claim the arm, consume its artifact, then publish.
          liveArm = nil
          try? FileManager.default.removeItem(atPath: armFilePath)
          let record = CrashBoundarySignalRecord(
            trialID: arm.trialID, boundary: boundary.rawValue)
          if let data = try? PropertyListEncoder().encode(record),
            (try? data.write(to: URL(fileURLWithPath: reachedFilePath), options: .atomic)) != nil
          {
            if boundary == .destructionAPIReturn {
              destructionAPIReturnGateActive = true
            }
            role = .consumed
          }
          // Publication failure falls through with no reached claim and no
          // hold — fail closed, never a permanent unobservable park.
        }
      }
      lock.unlock()
      switch role {
      case .none:
        if boundary == .beforeKeyDelete { onKeyDeleteGateDecisionForTesting?(false) }
        return
      case .gated(let gate):
        onKeyDeleteGateDecisionForTesting?(true)
        gate.wait()
      case .consumed:
        // Publication signal fires BEFORE the park so a test can release
        // deterministically (and a released/cleared controller skips the
        // park entirely — no lost-wakeup window).
        onPublishForTesting?(boundary)
        let hold: DispatchSemaphore? = lock.withLock {
          if released { return nil }
          let h = DispatchSemaphore(value: 0)
          parkedHolds.append(h)
          return h
        }
        hold?.wait()
      }
    }
  }
#endif
