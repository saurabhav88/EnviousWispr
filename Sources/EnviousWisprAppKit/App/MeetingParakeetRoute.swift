import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// Which Parakeet one EnviousMeet final pass decodes on (#4052), and the claim, decode and
/// release that choice needs. Built per pass by `MeetingWiring.makeJob`; implements the job's
/// engine dependencies, so `MeetingTranscriptionJob` keeps its shape.
///
/// **Same engine, one copy.** When dictation's selected and active engine is Parakeet (the
/// meeting engine is always Parakeet until #3973 adds a choice), the pass borrows dictation's
/// loaded Parakeet under the shared engine lease as `.meeting`, exactly as Transcribe a File
/// does: dictation is refused ("Transcribing a meeting. Please wait.") until the lease is
/// released, and no second Parakeet is loaded. When dictation runs Whisper, the pass keeps
/// its own `MeetingParakeetEngine`, as before #4052.
///
/// **No wait for engine ownership runs under the lease.** Readiness and the install claim are
/// taken with nothing held; the lease is taken in one synchronous main-actor step that
/// re-checks everything (`acquire()`); the release of the lease is synchronous. Under the lease
/// only the pass's own work runs (decode, audio reads, checkpoint writes). This is what closed
/// the acquisition-across-waits findings of the plan's review rounds 1-4.
@MainActor
final class MeetingParakeetRoute {
  enum Route: Equatable {
    case shared
    case own
  }

  /// The answer of dictation's readiness drive (the same drive Transcribe a File uses).
  enum Readiness: Equatable {
    case ready
    case notInstalled
    case notReady
  }

  struct Dependencies {
    /// The final-pass admission: dictation idle and no local summary call running
    /// (`MeetingWiring.admission(.finalPass, ...)`).
    var isAdmitted: @MainActor () -> Bool
    /// Dictation alone (no summary term), for "Paused while you dictate".
    var isDictationIdle: @MainActor () -> Bool
    var selectedBackend: @MainActor () -> ASRBackendType
    var activeBackend: @MainActor () -> ASRBackendType
    /// Poked on every lease release and engine-switch completion.
    var wakes: MeetingWakeSignal
    /// The shared engine lease, bound as `.meeting`.
    var admission: EngineAdmissionAccess
    var ensureDictationReady: @MainActor () async -> Readiness
    var isModelLoaded: @MainActor () -> Bool
    var isLoadOrUnloadInFlight: @MainActor () -> Bool
    var publishedSelection: @MainActor () -> ParakeetModelSelection?
    var transcribeShared: @MainActor ([Float]) async throws -> ASRResult
    var disarmEngineTimers: @MainActor () -> Void
    var rearmEngineTimers: @MainActor () -> Void
    var recoveryRecheck: @MainActor () -> Void
    /// The install claim that resolves dictation's published selection.
    var sharedClaim: MeetingModelClaim
    /// The install claim that resolves the meeting's own cache-only selection.
    var ownClaim: MeetingModelClaim
    var ownLoad: @MainActor (ParakeetModelSelection) async throws -> Void
    var ownTranscribe: @MainActor ([Float]) async throws -> ASRResult
    var ownUnload: @MainActor () async -> Void
    var ownWaitForAvailability: @MainActor () async throws -> Void
    /// Told when the own route gives its residency back outside `endModelUse` (an acquisition
    /// that failed or that a pending switch overtook), so a switch it held can proceed.
    var ownResidencyEnded: @MainActor () -> Void
    var log: @MainActor (String) -> Void
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
  }

  private let deps: Dependencies
  private(set) var route: Route?
  private var token: EngineLease.Token?
  private var claimedAt: ContinuousClock.Instant?
  private var heldTotal: Duration = .zero
  /// From the moment this pass chooses its own Parakeet until that copy is unloaded and its
  /// claim released (acquisition, load and decode included), so gate 6d holds a switch into
  /// Parakeet for the whole window, not only once the load has finished.
  private var ownActive = false
  private var meetingID = "-"
  private var meetingSeconds: Int?
  private var reportingDictationWait = false

  /// Told true while acquisition waits for a dictation, false when it goes on (#3972 C5's
  /// "Paused while you dictate"). The wiring binds it to the job after building the job.
  var onWaitingForDictation: (@MainActor (Bool) -> Void)?

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  /// Names the pass in the route's log lines: its meeting and its recorded duration (the
  /// longest track), the denominator of the pause per meeting hour. Called by the job when a
  /// pass starts.
  func beginPass(meetingID: UUID?, meetingSeconds: Int) {
    self.meetingID = meetingID?.uuidString ?? "-"
    self.meetingSeconds = meetingSeconds
  }

  /// The final pass's own Parakeet is loaded (gate 6d: a switch of dictation into Parakeet
  /// waits until it is gone, so two copies never coexist).
  var isOwnParakeetResident: Bool { ownActive }

  /// Whether this route holds the engine lease now.
  var holdsSharedEngine: Bool { token != nil }

  var engineIdentity: String? {
    switch route {
    case .shared: deps.sharedClaim.engineIdentity
    case .own: deps.ownClaim.engineIdentity
    case nil: nil
    }
  }

  // MARK: - Job dependencies

  /// The job's `beginModelUse`. Runs inside the job's cancellable wait, so a cancel cancels
  /// this task; every wait below is followed by a cancellation check. Throws only terminal
  /// causes: `CancellationError`, or `JobError.engineUnavailable`.
  func acquire() async throws {
    var publicationLosses = 0
    while true {
      // 1. Admission, lease and engine settled. Nothing is held here.
      let ready: @MainActor () -> Bool = {
        [isAdmitted = deps.isAdmitted, holder = deps.admission.currentHolder,
        selected = deps.selectedBackend, active = deps.activeBackend] in
        isAdmitted() && holder() == nil && selected() == active()
      }
      try await wait(until: ready)

      // 2. The route for this attempt.
      guard deps.activeBackend() == .parakeet else {
        if try await acquireOwn(settled: ready) { return }
        publicationLosses = 0
        continue
      }

      // 3. Dictation's Parakeet ready, with no lease held (its own convergence wait cannot
      // then wait on this meeting).
      switch await deps.ensureDictationReady() {
      case .ready: break
      case .notInstalled:
        throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_installed")
      case .notReady:
        throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_ready")
      }
      try Task.checkCancellation()

      // 4. The install claim on the model dictation serves, with no lease held.
      try await acquireClaim(deps.sharedClaim)

      // 5. One synchronous step: re-check everything, then take the lease. Each cause that is
      // not yet true releases the claim and waits for its own progress; only a published
      // model that is missing or different with nothing in flight counts toward giving up.
      if !ready() || deps.activeBackend() != .parakeet {
        await deps.sharedClaim.release()
        publicationLosses = 0
        continue
      }
      if deps.isLoadOrUnloadInFlight() {
        await deps.sharedClaim.release()
        publicationLosses = 0
        let inFlight = deps.isLoadOrUnloadInFlight
        try await wait(until: { !inFlight() })
        continue
      }
      let selection = deps.publishedSelection()
      guard deps.isModelLoaded(), selection != nil, selection == deps.sharedClaim.selection else {
        await deps.sharedClaim.release()
        publicationLosses += 1
        if publicationLosses >= 2 {
          throw MeetingTranscriptionJob.JobError.engineUnavailable("model_unstable")
        }
        try Task.checkCancellation()
        continue
      }
      guard case .granted(let granted) = deps.admission.claim() else {
        // Not reachable: the lease was read free in this same step. Released all the same.
        await deps.sharedClaim.release()
        continue
      }
      token = granted
      route = .shared
      claimedAt = deps.now()
      deps.disarmEngineTimers()
      deps.log("meeting engine route=shared claimed meeting=\(meetingID)")
      return
    }
  }

  func loadEngine() async throws {
    switch route {
    case .shared:
      // The model was readied in `acquire()`; the lease keeps it there.
      guard token != nil else {
        throw MeetingTranscriptionJob.JobError.engineUnavailable("lease_lost")
      }
    case .own:
      guard let selection = deps.ownClaim.selection else { throw MeetingWiringError.noModelClaim }
      try await deps.ownLoad(selection)
    case nil:
      throw MeetingWiringError.noModelClaim
    }
  }

  func transcribe(_ samples: [Float]) async throws -> ASRResult {
    switch route {
    case .shared: try await deps.transcribeShared(samples)
    case .own: try await deps.ownTranscribe(samples)
    case nil: throw MeetingWiringError.noModelClaim
    }
  }

  /// The job's `unloadEngine`: the shared route gives the engine back (the model stays
  /// dictation's, under its unload setting); the own route unloads its own copy.
  func unloadEngine() async {
    switch route {
    case .shared: await releaseShared()
    case .own:
      await deps.ownUnload()
    case nil: break
    }
  }

  /// The job's `endModelUse`. Idempotent; also reached without `unloadEngine` when a load
  /// fails.
  func endModelUse() async {
    switch route {
    case .shared:
      await releaseShared()
      let ms = Self.milliseconds(heldTotal)
      let seconds = meetingSeconds.map(String.init) ?? "unknown"
      deps.log(
        "meeting engine route=shared total meeting=\(meetingID) heldMs=\(ms) meetingSeconds=\(seconds)"
      )
    case .own:
      await deps.ownClaim.release()
      ownActive = false
    case nil: break
    }
    route = nil
  }

  func waitForEngineAvailability() async throws {
    try await deps.ownWaitForAvailability()
  }

  // MARK: - Internals

  /// The own route's acquisition. `ownActive` is set before the claim's wait, so an engine
  /// switch into Parakeet requested during it is held by gate 6d. When the selection moved
  /// meanwhile (the user picked Parakeet), the claim is given back and the deferred switch is
  /// woken; returns false so `acquire()` waits for the switch and takes the shared route.
  private func acquireOwn(settled: @MainActor () -> Bool) async throws -> Bool {
    ownActive = true
    do {
      try await acquireClaim(deps.ownClaim)
    } catch {
      ownActive = false
      deps.ownResidencyEnded()
      throw error
    }
    guard settled(), deps.activeBackend() != .parakeet else {
      await deps.ownClaim.release()
      ownActive = false
      deps.ownResidencyEnded()
      return false
    }
    route = .own
    deps.log("meeting engine route=own meeting=\(meetingID)")
    return true
  }

  /// `MeetingModelClaim.acquire`, with its terminal errors mapped as the job reports them.
  private func acquireClaim(_ claim: MeetingModelClaim) async throws {
    do {
      try await claim.acquire()
    } catch let error as MeetingWiringError {
      throw MeetingTranscriptionJob.JobError.engineUnavailable(String(describing: error))
    }
  }

  /// Waits, with nothing held, until `condition` holds. Reports "Paused while you dictate"
  /// while (and only while) the wait is for a dictation, re-reading that as it changes, and
  /// clears it however the wait ends. Cancellation ends the wait with `CancellationError`.
  private func wait(until condition: @escaping @MainActor () -> Bool) async throws {
    defer { reportDictationWait(false) }
    while !condition() {
      let dictating = !deps.isDictationIdle()
      reportDictationWait(dictating)
      let isDictationIdle = deps.isDictationIdle
      waitEnteredForTesting()
      await MeetingWorkAdmission.waitUntil(
        { condition() || isDictationIdle() == dictating }, wakes: deps.wakes)
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
  }

  private func reportDictationWait(_ waiting: Bool) {
    guard waiting != reportingDictationWait else { return }
    reportingDictationWait = waiting
    onWaitingForDictation?(waiting)
  }

  /// Gives the lease back: timers re-armed, then the token (synchronous, the order Transcribe
  /// a File uses), then the install claim (it awaits the gate, after the lease is already
  /// free), then recovery's own wake for a scan this hold deferred. Repeatable.
  private func releaseShared() async {
    let held = token != nil
    if let token {
      deps.rearmEngineTimers()
      deps.admission.release(token)
      self.token = nil
      if let claimedAt {
        let duration = deps.now() - claimedAt
        heldTotal += duration
        self.claimedAt = nil
        deps.log(
          "meeting engine route=shared released meeting=\(meetingID) heldMs=\(Self.milliseconds(duration))"
        )
      }
    }
    await deps.sharedClaim.release()
    if held { deps.recoveryRecheck() }
  }

  // MARK: - Test seam

  /// Waits entered so far, and a signal for a test that must act only once `acquire()` is
  /// parked in a wait (a release, a switch or a cancel before that would prove nothing).
  private(set) var waitsEntered = 0
  private var waitEnteredWaiters:
    [(id: UUID, count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

  private func waitEnteredForTesting() {
    waitsEntered += 1
    let ready = waitEnteredWaiters.filter { $0.count <= waitsEntered }
    waitEnteredWaiters.removeAll { $0.count <= waitsEntered }
    ready.forEach { $0.continuation.resume(returning: true) }
  }

  /// True once `acquire()` has entered its `count`th wait; false after a 5 s deadline, so a
  /// test that never gets there fails instead of hanging.
  // periphery:ignore - test seam
  func waitForWaitEnteredForTesting(count: Int = 1) async -> Bool {
    guard waitsEntered < count else { return true }
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let id = UUID()
      waitEnteredWaiters.append((id, count, c))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
        guard let self, let index = self.waitEnteredWaiters.firstIndex(where: { $0.id == id })
        else { return }
        self.waitEnteredWaiters.remove(at: index).continuation.resume(returning: false)
      }
    }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
