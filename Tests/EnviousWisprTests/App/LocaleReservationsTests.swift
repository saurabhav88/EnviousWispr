import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2080 — who may hold a locale claim, and whose may be taken away.
///
/// Two callers share Apple's five slots: a recording claiming the language it is about to
/// transcribe, and the settings page claiming one it is about to download. Four review rounds
/// each found a different way for a claim to be lost, which is what moved this from a series of
/// patches to a type that models the missing idea — a claim being IN USE.
///
/// **These test the model, not Apple.** The inventory is static and uninjectable, so the testable
/// core is the two properties everything else rests on: the transaction stays exclusive across
/// suspensions, and eviction never takes a claim someone still needs.
struct LocaleReservationsTests {

  /// Counts how many tasks are inside the critical section at once, and remembers the worst case.
  private actor Occupancy {
    private(set) var inside = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func enter() {
      inside += 1
      peak = max(peak, inside)
    }
    func leave() {
      inside -= 1
      completed += 1
    }
  }

  @Test("Only one caller is inside the reservation transaction at a time")
  func lockExcludesAcrossSuspensions() async {
    // Its own instance, not `shared`: tests in a suite run in parallel, so measuring the
    // singleton would mean two tests contending for the very thing under measurement.
    let lock = LocaleReservations()
    let occupancy = Occupancy()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<12 {
        group.addTask {
          await lock.acquire()
          await occupancy.enter()
          // Suspend INSIDE the section, which is what the real transaction does three times over.
          // An actor-only guard would let a sibling in right here; a held lock must not.
          await Task.yield()
          await Task.yield()
          await occupancy.leave()
          await lock.release()
        }
      }
    }

    let peak = await occupancy.peak
    let completed = await occupancy.completed
    #expect(completed == 12, "control: every task ran, so the peak below means something")
    #expect(
      peak == 1,
      "\(peak) callers were inside the reservation transaction at once; it must be exclusive")
  }

  /// Ownership passes straight from `release()` to the next waiter, so the lock is reusable and
  /// nobody is stranded. A hand-off that cleared `held` first would leave a gap; a hand-off that
  /// forgot to resume would deadlock, and this test would hang rather than fail — which is why
  /// the count above is asserted too.
  @Test("The lock is reusable and every waiter is eventually served")
  func lockHandsOffToEveryWaiter() async {
    // Its own instance, not `shared`: tests in a suite run in parallel, so measuring the
    // singleton would mean two tests contending for the very thing under measurement.
    let lock = LocaleReservations()
    let occupancy = Occupancy()

    for _ in 0..<3 {
      await lock.acquire()
      await occupancy.enter()
      await occupancy.leave()
      await lock.release()
    }

    #expect(await occupancy.completed == 3, "a released lock must be acquirable again")
    #expect(await occupancy.inside == 0, "and must not be left held")
  }

  // MARK: - Eviction respects who is still using a claim

  @Test("Eviction never chooses a claim that is still in use")
  func evictionSkipsClaimsInUse() async {
    let reservations = LocaleReservations()
    let reserved = ["de-DE", "fr-FR", "it-IT", "ja-JP", "en-US"]

    // A recording is transcribing French; a download is fetching Italian.
    await reservations.beginUse("fr-FR")
    await reservations.beginUse("it-IT")

    let candidates = await reservations.evictable(from: reserved)

    #expect(!candidates.contains("fr-FR"), "evicting this kills the recording in flight")
    #expect(!candidates.contains("it-IT"), "evicting this fails the download in flight")
    #expect(candidates == ["de-DE", "ja-JP", "en-US"], "and the rest stay available, in order")
  }

  @Test("A claim becomes evictable again once its user is done")
  func endUseReleasesTheClaim() async {
    let reservations = LocaleReservations()
    await reservations.beginUse("fr-FR")
    #expect(await reservations.evictable(from: ["fr-FR", "de-DE"]) == ["de-DE"])

    await reservations.endUse("fr-FR")
    #expect(
      await reservations.evictable(from: ["fr-FR", "de-DE"]) == ["fr-FR", "de-DE"],
      "a finished recording must not keep a slot locked for the rest of the process")
  }

  /// A recording and a download can legitimately need the same language at once, so this is a
  /// COUNT and not a flag. With a flag, whichever finished first would free the other's claim.
  @Test("Two users of one language must both finish before it can be evicted")
  func usesAreCountedNotFlagged() async {
    let reservations = LocaleReservations()
    await reservations.beginUse("fr-FR")
    await reservations.beginUse("fr-FR")
    #expect(await reservations.useCount("fr-FR") == 2)

    await reservations.endUse("fr-FR")
    #expect(
      await reservations.evictable(from: ["fr-FR"]) == ["fr-FR"],
      "control: with only one user left, the soft fallback returns it as the sole candidate")
    #expect(await reservations.useCount("fr-FR") == 1, "one user remains, so the claim is needed")

    await reservations.endUse("fr-FR")
    #expect(await reservations.useCount("fr-FR") == 0)
  }

  /// Deliberate design choice, and the reason it is not an assertion failure: if some abandoned
  /// path ever misses an `endUse`, refusing every future download would be a far worse and far
  /// less diagnosable failure than falling back to the old behaviour.
  @Test("When every claim is spoken for, eviction falls back rather than refusing")
  func evictionFailsSoftWhenEverythingIsInUse() async {
    let reservations = LocaleReservations()
    for tag in ["de-DE", "fr-FR"] { await reservations.beginUse(tag) }

    let candidates = await reservations.evictable(from: ["de-DE", "fr-FR"])

    #expect(
      candidates == ["de-DE", "fr-FR"],
      "a leaked registration must degrade to the old behaviour, never deadlock downloads")
  }

  @Test("An unbalanced endUse cannot drive the count negative")
  func endUseWithoutBeginIsHarmless() async {
    let reservations = LocaleReservations()
    await reservations.endUse("fr-FR")
    #expect(await reservations.useCount("fr-FR") == 0)

    await reservations.beginUse("fr-FR")
    #expect(
      await reservations.evictable(from: ["fr-FR"]) == ["fr-FR"],
      "control: the fallback still applies; the count did not go negative and cancel this out")
    #expect(await reservations.useCount("fr-FR") == 1)
  }

  // MARK: - The registration must happen inside the locked section

  /// The whole point of registering a use is defeated if it lands AFTER the lock is dropped: for
  /// as long as that window is open the claim reads as unused, and the next caller through the
  /// lock evicts it. Asserted at source because the window is a scheduling property with no seam.
  @Test("Reserving registers the use before it unlocks the transaction")
  func reservationRegistersUseUnderTheLock() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprLivePreview/Engines/ApplePreviewRecognizer.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: url, encoding: .utf8))

    guard let start = source.range(of: "package static func acquireLocaleForSession(") else {
      Issue.record("acquireLocaleForSession not found; it was renamed or moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(body.contains("acquire()"), "control: the extracted body is the locked transaction")
    #expect(
      body.contains("beginUse"),
      "the session variant must register the use, or the claim is evictable the moment it is taken")

    guard
      let registered = body.range(of: "beginUse")?.lowerBound,
      let unlocked = body.range(of: "release()", options: .backwards)?.lowerBound
    else {
      Issue.record("could not locate both the registration and the unlock")
      return
    }
    #expect(
      registered < unlocked,
      "registering after the unlock leaves a window where the claim reads as unused")
  }

  /// Warm-up must PROTECT its claim, and must balance it on every exit.
  ///
  /// This test previously asserted the opposite — that `prepare()` used the non-registering
  /// variant — because registering had leaked one claim per prepared language when the balance
  /// was spread across five exit points. Review then found the cost of not registering: with the
  /// table full, a download could evict the locale while warm-up was still suspended on it, and
  /// preparation failed for a pack that is present.
  ///
  /// So both are required: register it, AND balance it through a single wrapper so the five exits
  /// funnel into two paths. That is what makes the leak unexpressible rather than merely avoided.
  @Test("Warm-up protects its claim and hands it back on every path")
  func prepareRegistersAndBalancesItsClaim() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprLivePreview/Engines/ApplePreviewRecognizer.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: url, encoding: .utf8))

    guard let start = source.range(of: "func prepare() async throws {") else {
      Issue.record("prepare() not found; it was renamed or moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(
      body.contains("acquireLocaleForSession"),
      """
      warm-up must REGISTER its claim, or a download can evict the locale while preparation is \
      still suspended on it and the preview fails for a pack that is present
      """)
    // Balanced on BOTH paths, which is what stops the registration leaking. Counting them is the
    // point: one `endUse` would mean only the success path gives the claim back.
    let handBacks = body.components(separatedBy: "endUse(claimedTag)").count - 1
    #expect(
      handBacks == 2,
      """
      the claim must be handed back on the throwing path AND the succeeding one, or every failed \
      warm-up leaks one; found \(handBacks)
      """)
    #expect(
      body.contains("catch"),
      "the balance has to come from one wrapper, not from repeating cleanup at five exits")
  }

  /// Registering without a matching release is the leak; this pins the pairing at the seam that
  /// can actually be driven, so a future caller cannot quietly add a second unbalanced site.
  @Test("Every registration has exactly one release")
  func registrationsBalance() async {
    let reservations = LocaleReservations()
    await reservations.beginUse("fr-FR")
    await reservations.beginUse("fr-FR")
    #expect(await reservations.useCount("fr-FR") == 2)
    await reservations.endUse("fr-FR")
    await reservations.endUse("fr-FR")
    #expect(
      await reservations.useCount("fr-FR") == 0,
      "an unbalanced registration is a slot locked for the life of the process")
    #expect(
      await reservations.evictable(from: ["fr-FR"]) == ["fr-FR"],
      "and the locale is evictable again once nobody holds it")
  }
}
