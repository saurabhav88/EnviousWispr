import Testing

@testable import EnviousWisprPipeline

/// #2648 — the exclusive claim on the shared ASR-and-polish resource.
///
/// **When this fails, the user starts a dictation in the middle of a file import, both land in the
/// one-slot polish server, and the dictation silently comes back unpolished.** That is the whole
/// reason the claim exists, so this suite is product coverage rather than a drift guard.
///
/// **It is raced, not driven single-threaded, and that is not optional here.** A single-threaded test
/// passes identically against an atomic claim and against a `if free { take }` that suspends in the
/// middle, because one caller can never open the window between the check and the write
/// (`validation-discipline.md` RULE: a-single-threaded-test-cannot-distinguish-atomic-from-check-then-act).
/// `RacyLease` below is the two-way control: it is the broken shape — the same claim with one `await`
/// added between the read and the write — and the same race asserts that it really does hand the
/// resource to more than one caller. Without that control a green run here would be equally consistent
/// with the race never having happened.
///
/// **Being on an isolated executor is not by itself the protection**, which is what the control shows:
/// it is isolated too, and it still hands the resource to several callers. What protects the claim is
/// that `admit` contains no suspension point at all.
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

  // MARK: - The broken shape, kept as a control

  /// `EngineLease` with one suspension point added between the check and the write — the classic
  /// check-then-act hole that isolation does NOT close, because an actor and the main actor both
  /// release isolation at every `await`. Written as an actor here only because a non-Sendable
  /// `@MainActor` class cannot be handed to a task group; the defect being demonstrated is the
  /// `await`, not which executor it is on. Nothing in production uses this; it exists so the race
  /// below can be shown to detect the defect it is written to catch.
  private actor RacyLease {
    private var held = false

    func acquire() async -> Bool {
      guard !held else { return false }
      await Task.yield()
      held = true
      return true
    }
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

  @Test("the race harness can see a check-then-act hole")
  func theRaceDetectsTheBrokenShape() async {
    let racy = RacyLease()

    let winners = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<Self.contenders {
        group.addTask { await racy.acquire() }
      }
      var count = 0
      for await won in group where won { count += 1 }
      return count
    }

    #expect(
      winners > 1,
      """
      The control did not race: \(winners) winner(s) out of \(Self.contenders). \
      A control that cannot expose the broken shape makes the sibling test's green meaningless.
      """)
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
}
