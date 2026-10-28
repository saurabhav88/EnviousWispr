import Testing

@testable import EnviousWisprPipeline

/// #2648 — the exclusive claim on the shared ASR-and-polish resource.
///
/// **When this fails, the user starts a dictation in the middle of a file import, both land in the
/// one-slot polish server, and the dictation silently comes back unpolished.** That is the whole
/// reason the claim exists, so this suite is product coverage rather than a drift guard.
///
/// **It is raced, not driven single-threaded.** A single-threaded test passes identically against an
/// atomic claim and against a `if free { take }` that suspends in the middle, because one caller can
/// never open the window between the check and the write
/// (`validation-discipline.md` RULE: a-single-threaded-test-cannot-distinguish-atomic-from-check-then-act).
///
/// **What protects the claim is that `admit` contains no suspension point at all**; being on an
/// isolated executor is not by itself the protection, because an actor releases isolation at every
/// `await`. The positive control that raced a deliberately broken copy (one `await` between the read
/// and the write) was removed in #3784: whether its contenders interleave depends on the runner's
/// scheduling, so it failed at random on hosted CI while finding no real defect.
@Suite(.tags(.productOutcome))
@MainActor
struct EngineLeaseTests {

  /// How many callers pile onto one claim. 40 matched the measured `mv -n` race that exposed multiple
  /// simultaneous winners three times in eight rounds, so it is a size known to open real windows.
  private static let contenders = 40

  /// The granted token, or nil when the claim was refused. Every row below
  /// except the refusal ones cares only about which of the two it got.
  private func token(from admission: EngineLease.Admission) -> EngineLease.Token? {
    guard case .granted(let token) = admission else { return nil }
    return token
  }

  // MARK: - The race

  @Test("exactly one of many simultaneous callers gets the resource")
  func oneWinnerUnderRace() async {
    let lease = EngineLease()

    let tokens = await withTaskGroup(of: EngineLease.Token?.self) { group in
      for _ in 0..<Self.contenders {
        group.addTask { @MainActor [self] in token(from: lease.admit(.fileImport)) }
      }
      var collected: [EngineLease.Token?] = []
      for await token in group { collected.append(token) }
      return collected
    }

    // The attempt count is asserted first, so a group that silently ran fewer tasks than it was given
    // cannot make "exactly one winner" true by arithmetic.
    #expect(tokens.count == Self.contenders)
    #expect(tokens.compactMap { $0 }.count == 1)
    #expect(lease.isBusy)
  }

  // MARK: - Token identity

  @Test("a token from a finished claim cannot evict the live one")
  func aStaleTokenCannotRelease() throws {
    let lease = EngineLease()
    let stale = try #require(token(from: lease.admit(.fileImport)))
    #expect(lease.release(stale))

    #expect(token(from: lease.admit(.dictation)) != nil)

    #expect(lease.release(stale) == false)
    #expect(lease.isBusy)
    #expect(lease.currentHolder == .dictation)
  }

  @Test("releasing twice is a no-op the second time")
  func releaseIsIdempotent() throws {
    let lease = EngineLease()
    let claimed = try #require(token(from: lease.admit(.crashRecovery)))
    #expect(lease.release(claimed))
    #expect(lease.release(claimed) == false)
    #expect(lease.isBusy == false)
  }

  @Test("the resource is claimable again once it is released")
  func reusableAfterRelease() throws {
    let lease = EngineLease()
    let first = try #require(token(from: lease.admit(.fileImport)))
    #expect(token(from: lease.admit(.dictation)) == nil)

    #expect(lease.release(first))
    #expect(token(from: lease.admit(.dictation)) != nil)
    #expect(lease.currentHolder == .dictation)
  }

  @Test("a refusal names the holder, in the same answer")
  func aRefusalNamesTheHolder() throws {
    let lease = EngineLease()
    _ = try #require(token(from: lease.admit(.fileImport)))

    guard case .refused(let holder) = lease.admit(.dictation) else {
      Issue.record("a second claim on a held resource must be refused")
      return
    }
    // One answer, not a claim followed by a second "who has it" read: a refusal
    // that had to ask again would need a fallback for the answer coming back
    // empty, and that fallback would name a job to wait for that nobody runs.
    #expect(holder == .fileImport)
  }

  @Test("nobody holds it to begin with")
  func startsFree() {
    let lease = EngineLease()
    #expect(lease.isBusy == false)
    #expect(lease.currentHolder == nil)
  }

  @Test("every holder can take a free resource", arguments: EngineLease.Holder.allCases)
  func everyHolderCanClaim(_ holder: EngineLease.Holder) {
    let lease = EngineLease()
    let claimed = token(from: lease.admit(holder))
    #expect(claimed != nil)
    #expect(claimed?.holder == holder)
    #expect(lease.currentHolder == holder)
  }

  // MARK: - Counting visits, not sampling states

  /// **The instrument a health probe needs, and the reason it is a COUNTER.**
  ///
  /// "Is the engine busy" answers about an instant. A probe needs to know
  /// whether anything used the engine while its request was in flight, and a
  /// workload that claims and releases inside that window — a one-part re-polish
  /// does exactly that — leaves a before sample and an after sample both reading
  /// false while the probe queued behind it the whole time. Two rounds of review
  /// each moved a sample; this replaced the instrument.
  ///
  /// **The falsification condition, published with the claim:** a further finding
  /// of the shape "the probe published a verdict measured under contention" means
  /// the epoch is the wrong instrument, not that it needs a third sample.
  @Test("a claim taken and released between two readings still moves the counter")
  func theEpochCountsAVisitTooBriefToSample() {
    let lease = EngineLease()

    let before = lease.admissionEpoch
    #expect(!lease.isBusy, "the fixture did not start idle")

    // The whole visit, between the two samples a probe would take.
    guard case .granted(let token) = lease.admit(.fileImport) else {
      Issue.record("the lease refused an idle claim")
      return
    }
    lease.release(token)

    #expect(!lease.isBusy, "both samples a probe takes read idle, which is the point")
    #expect(
      lease.admissionEpoch != before,
      "a workload came and went between the samples and the counter did not notice")
  }

  /// The other direction, so a counter that only ever increased would fail too:
  /// nothing happening must leave it alone.
  @Test("a quiet interval does not move the counter")
  func theEpochIsStillWhenNothingHappens() {
    let lease = EngineLease()
    let before = lease.admissionEpoch
    #expect(lease.admissionEpoch == before)
  }

  /// A REFUSED claim is not a visit: the workload never reached the engine.
  @Test("a refused claim does not move the counter")
  func aRefusalIsNotAVisit() {
    let lease = EngineLease()
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("the lease refused an idle claim")
      return
    }
    let afterFirst = lease.admissionEpoch

    guard case .refused = lease.admit(.fileImport) else {
      Issue.record("the lease admitted two workloads")
      return
    }

    #expect(
      lease.admissionEpoch == afterFirst,
      "a refusal counted as a visit, so a probe would discard a clean verdict")
  }

  // MARK: - #3973 C1 Dictation's reserved turn

  /// Parks a dictation wait behind `holder` and returns its task and reservation once the
  /// reservation exists (handed out synchronously, before the wait suspends).
  private func parkDictation(_ lease: EngineLease) async -> (
    task: Task<EngineLease.Token?, Never>, reservation: EngineLease.Reservation
  )? {
    // The subject's own signal: `onReserved` fires in the step that reserves, and this resumes
    // only after that step suspends in its wait. Bounded: a wait that never reserves fails the
    // test after 5 s instead of hanging it, and its parked task is cancelled.
    let signal = ReservationSignal()
    let task = Task { @MainActor in
      await lease.waitForReservedTurn { signal.deliver($0) }
    }
    guard let reserved = await signal.value() else {
      task.cancel()
      Issue.record("the wait never reserved")
      return nil
    }
    return (task, reserved)
  }

  @Test("a waiting dictation keeps every other claim out, then gets the turn at the release")
  func aReservedTurnIsHandedOverAtTheRelease() async {
    let lease = EngineLease()
    guard case .granted(let meeting) = lease.admit(.meeting),
      let parked = await parkDictation(lease)
    else { return }
    #expect(lease.hasPendingReservation)
    let epoch = lease.admissionEpoch

    #expect(lease.release(meeting))
    // Same step as the release: nothing can claim in between, the meeting included.
    #expect(lease.currentHolder == .dictation)
    #expect(lease.admissionEpoch == epoch + 1)
    for holder in [SharedEngineHolder.meeting, .fileImport, .crashRecovery, .dictation] {
      guard case .refused(by: .dictation) = lease.admit(holder) else {
        Issue.record("\(holder) took the reserved turn")
        return
      }
    }
    let token = await parked.task.value
    #expect(token?.holder == .dictation)
    #expect(!lease.hasPendingReservation)
    if let token { #expect(lease.release(token)) }
    #expect(!lease.isBusy)
  }

  @Test("a withdrawn reservation gets nothing and the next release frees the engine")
  func aWithdrawnReservationIsNotGranted() async {
    let lease = EngineLease()
    guard case .granted(let meeting) = lease.admit(.meeting),
      let parked = await parkDictation(lease)
    else { return }

    #expect(lease.cancelReservation(parked.reservation))
    #expect(await parked.task.value == nil)
    #expect(!lease.cancelReservation(parked.reservation), "a second withdrawal is a no-op")
    #expect(lease.release(meeting))
    #expect(!lease.isBusy)
  }

  @Test("cancelling the waiting task withdraws its reservation")
  func aCancelledWaitWithdrawsItsReservation() async {
    let lease = EngineLease()
    guard case .granted(let meeting) = lease.admit(.meeting),
      let parked = await parkDictation(lease)
    else { return }

    parked.task.cancel()
    #expect(await parked.task.value == nil)
    #expect(!lease.hasPendingReservation)
    #expect(lease.release(meeting))
    #expect(!lease.isBusy)
  }

  @Test("a free engine grants at once; a second waiter while one waits is refused")
  func oneReservationAtATime() async {
    let lease = EngineLease()
    let free = await lease.waitForReservedTurn { _ in Issue.record("a free engine reserved") }
    #expect(free?.holder == .dictation)
    guard let free, lease.release(free), case .granted(let meeting) = lease.admit(.meeting),
      let parked = await parkDictation(lease)
    else { return }

    let second = await lease.waitForReservedTurn { _ in Issue.record("a second reservation") }
    #expect(second == nil)
    #expect(lease.cancelReservation(parked.reservation))
    _ = await parked.task.value
    #expect(lease.release(meeting))
  }
}

/// One reservation handed from the subject's `onReserved` to the waiting test, or nil after a
/// 5 s deadline (#3973 C1).
@MainActor
private final class ReservationSignal {
  private var delivered: EngineLease.Reservation?
  private var waiter: CheckedContinuation<EngineLease.Reservation?, Never>?

  func deliver(_ reservation: EngineLease.Reservation) {
    delivered = reservation
    waiter?.resume(returning: reservation)
    waiter = nil
  }

  func value() async -> EngineLease.Reservation? {
    if let delivered { return delivered }
    return await withCheckedContinuation { continuation in
      waiter = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
        guard let self, let waiter = self.waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
      }
    }
  }
}
