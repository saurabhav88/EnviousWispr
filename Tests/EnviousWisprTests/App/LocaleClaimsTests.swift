import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2145 — the whole locale-claim transaction, driven against a fake macOS inventory.
///
/// This suite used to test the lock and the use registry in isolation while the transaction they
/// existed for ran against Apple's static API, where nothing could reach it. That is exactly how
/// #2145 shipped: every release the app issued was a no-op for two releases, and a green suite said
/// nothing about it, because the only double available recorded that a closure had been CALLED.
///
/// So the seam moved. `LocaleInventory` is injected, the fake below behaves the way the real
/// inventory was MEASURED to behave — including the parts that bite — and the properties asserted
/// here are the ones a user feels: a claim comes back, a claim that is not ours is never taken, and
/// two callers never interleave.
struct LocaleClaimsTests {

  // MARK: - The fake macOS inventory

  /// Models `AssetInventory` as measured on macOS 26.5, including its unhelpful parts.
  ///
  /// **`reserve` returning false is not failure** — it means "did not newly claim", which is what
  /// the real one returns for a locale somebody already holds. **`release` reports only that macOS
  /// acted**, and `refuseRelease` reproduces #2145's actual shipped behaviour: the call returns
  /// false and the claim stays put.
  private actor FakeInventory {
    private(set) var reserved: [String] = []
    private(set) var releaseCalls: [String] = []
    private(set) var reserveCalls: [String] = []

    var maximum = 5
    /// Tags this fake refuses to release, the way the real API refused a mis-spelled `Locale`.
    var refuseRelease: Set<String> = []
    /// Tags `reserve` refuses as already-claimed while `reserved` shows nothing — the phantom that
    /// produced "On-screen preview is not ready yet" in the field.
    var phantom: Set<String> = []
    /// How many times each phantom refusal fires before the inventory settles. 1 models the
    /// transient disagreement seen in production; a large value models a stuck one.
    var phantomRefusals = Int.max
    /// Runs inside every `reserved()` read, so a test can observe who is inside the transaction.
    var onRead: (@Sendable () async -> Void)?
    /// Tags another process re-claims the instant ours is released — the ABA substitution no local
    /// ledger can see.
    var replaceAfterRelease: Set<String> = []

    init(reserved: [String] = []) { self.reserved = reserved }

    func setMaximum(_ n: Int) { maximum = n }
    func setRefuseRelease(_ tags: Set<String>) { refuseRelease = tags }
    func setPhantom(_ tags: Set<String>, refusals: Int = Int.max) {
      phantom = tags
      phantomRefusals = refusals
    }
    func setOnRead(_ hook: @escaping @Sendable () async -> Void) { onRead = hook }
    func setReplaceAfterRelease(_ tags: Set<String>) { replaceAfterRelease = tags }

    /// **Spelled the way the real inventory spells them: `en_US`, not `en-US`.** Measured —
    /// `reservedLocales` hands back objects whose `identifier` is the underscore form, and that
    /// spelling is the entire subject of #2145. A fake that returned the hyphenated form would let
    /// the shipped bug pass.
    func readReserved() async -> [Locale] {
      if let onRead { await onRead() }
      return reserved.map { Locale(identifier: Locale(identifier: $0).identifier(.icu)) }
    }

    func doReserve(_ locale: Locale) async throws -> Bool {
      let tag = locale.identifier(.bcp47)
      reserveCalls.append(tag)
      if phantom.contains(tag) {
        if phantomRefusals != Int.max {
          phantomRefusals -= 1
          if phantomRefusals <= 0 { phantom.remove(tag) }
        }
        return false
      }
      if reserved.contains(tag) { return false }
      guard reserved.count < maximum else {
        throw NSError(domain: "SFSpeechErrorDomain", code: 11)
      }
      reserved.append(tag)
      return true
    }

    func doRelease(_ locale: Locale) async -> Bool {
      // The identifier, not the tag: this is the distinction #2145 turned on, so the fake insists
      // on it. A caller that hands over a hyphenated `Locale` gets the shipped bug back.
      let identifier = locale.identifier
      releaseCalls.append(identifier)
      guard
        let index = reserved.firstIndex(where: {
          Locale(identifier: $0).identifier(.icu) == identifier
        })
      else { return false }
      let tag = reserved[index]
      if refuseRelease.contains(tag) { return false }
      reserved.remove(at: index)
      if replaceAfterRelease.contains(tag) { reserved.append(tag) }
      return true
    }

    func inventory() -> LocaleInventory {
      LocaleInventory(
        reserved: { await self.readReserved() },
        reserve: { try await self.doReserve($0) },
        release: { await self.doRelease($0) },
        maximumReserved: { await self.maximum }
      )
    }
  }

  private func claims(_ fake: FakeInventory) async -> LocaleClaims {
    LocaleClaims(inventory: await fake.inventory())
  }

  // MARK: - The property the whole issue is about

  @Test("A claim this process took is actually returned to macOS when the work ends")
  func claimIsReturned() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)

    try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    #expect(await fake.reserved == ["en-US"], "the claim must be taken")

    await subject.finish(Locale(identifier: "en-US"))

    #expect(await fake.reserved.isEmpty, "the claim must come back — this is #2145")
    #expect(
      await fake.releaseCalls == ["en_US"],
      "macOS matches on Locale.identifier, so the underscore form is the only one that releases")
  }

  @Test("Nothing accumulates across repeated recordings")
  func repeatedSessionsDoNotAccumulate() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)

    for _ in 0..<8 {
      try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
      await subject.finish(Locale(identifier: "en-US"))
    }

    #expect(await fake.reserved.isEmpty)
    #expect(await subject.ownsClaim("en-US") == false)
  }

  // MARK: - Ownership: the hazard that fixing the release arms

  @Test("A claim another process already holds is never released by us")
  func piggybackedClaimIsNeverReleased() async throws {
    // Measured for #2145: one process CAN release another live process's claim, and the holder
    // loses it silently. Riding on someone else's claim must therefore not end with us handing it
    // back on their behalf.
    let fake = FakeInventory(reserved: ["en-US"])
    let subject = await claims(fake)

    let result = try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    #expect(result == .alreadyHeld)
    #expect(await subject.ownsClaim("en-US") == false, "we did not take it, so it is not ours")

    await subject.finish(Locale(identifier: "en-US"))

    #expect(await fake.reserved == ["en-US"], "the other process still holds its claim")
    #expect(await fake.releaseCalls.isEmpty, "we must not even attempt the release")
  }

  @Test("At capacity, a table holding nothing of ours is left alone")
  func capacityWithNoOwnedClaimEvictsNothing() async throws {
    let fake = FakeInventory(reserved: ["a-AA", "b-BB", "c-CC", "d-DD", "e-EE"])
    let subject = await claims(fake)

    await #expect(throws: (any Error).self) {
      try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    }

    #expect(
      await fake.releaseCalls.isEmpty,
      "a refused download is better than silently breaking another app's dictation")
    #expect(await fake.reserved.count == 5, "nobody else's claim may be taken")
  }

  @Test("At capacity, our own idle claim is the one evicted")
  func capacityEvictsOurIdleClaim() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)
    await fake.setMaximum(2)

    // Take one and finish it, so it is ours and idle... but the fake keeps it reserved to model a
    // release that macOS refused, which is the only way an owned-but-idle claim survives.
    await fake.setRefuseRelease(["de-DE"])
    try await subject.claim(Locale(identifier: "de-DE"), purpose: "prepare")
    await subject.finish(Locale(identifier: "de-DE"))
    #expect(await subject.ownsClaim("de-DE"), "a refused release keeps the claim ours to retry")

    try await subject.claim(Locale(identifier: "fr-FR"), purpose: "session")
    await fake.setRefuseRelease([])

    // Table is full (de-DE, fr-FR) and fr-FR is in use, so de-DE is the only legal victim.
    try await subject.claim(Locale(identifier: "en-US"), purpose: "session")

    #expect(await fake.reserved.contains("en-US"))
    #expect(await fake.reserved.contains("de-DE") == false, "the idle owned claim is the victim")
    #expect(await fake.reserved.contains("fr-FR"), "a claim in use is never evicted")
  }

  @Test("A claim still in use is never evicted, even when it is ours")
  func evictionSkipsClaimsInUse() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)
    await fake.setMaximum(1)

    try await subject.claim(Locale(identifier: "de-DE"), purpose: "session")

    await #expect(throws: (any Error).self) {
      try await subject.claim(Locale(identifier: "fr-FR"), purpose: "session")
    }
    #expect(await fake.reserved == ["de-DE"], "the in-use claim survives")
  }

  // MARK: - The phantom refusal that produced the pill

  @Test("A refusal with no visible claim is retried once and never released")
  func phantomRefusalRetriesWithoutReleasing() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)
    // Refuses once, then settles: the transient inventory disagreement measured in production.
    await fake.setPhantom(["en-US"], refusals: 1)

    let result = try await subject.claim(Locale(identifier: "en-US"), purpose: "session")

    #expect(result == .recovered)
    #expect(await fake.reserveCalls == ["en-US", "en-US"], "exactly one retry, never a loop")
    #expect(
      await fake.releaseCalls.isEmpty,
      """
      The recovery must not release. Between the read that said "absent" and a release, another \
      process can claim that tag, and our release would silently take it — the exact harm the \
      ownership ledger exists to prevent, and a window no lock of ours can close.
      """)
  }

  @Test("A refusal that survives the retry throws rather than looping")
  func persistentPhantomThrows() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)
    await fake.setPhantom(["en-US"])

    await #expect(throws: LivePreviewError.self) {
      try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    }
    #expect(await fake.reserveCalls.count == 2, "one attempt, one retry, then stop")
    #expect(await fake.releaseCalls.isEmpty)
  }

  // MARK: - A refused release is not a freed slot

  @Test("A release macOS refuses keeps the claim ours instead of reading as success")
  func refusedReleaseKeepsOwnership() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)
    await fake.setRefuseRelease(["en-US"])

    try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    await subject.finish(Locale(identifier: "en-US"))

    #expect(await fake.reserved == ["en-US"], "macOS refused, so the claim is still there")
    #expect(
      await subject.ownsClaim("en-US"),
      "keeping ownership is what lets a later finish or eviction try again")
  }

  @Test("An acknowledged release forgets ownership even if another process replaces the tag")
  func acknowledgedReleaseForgetsReplacedClaim() async throws {
    // The plan promises this and the suite did not test it — found by the confirming review. macOS
    // ACKNOWLEDGING the release is what settles it; a tag visible immediately afterwards may be
    // somebody else's brand-new claim, and holding ownership over that would put us one `finish`
    // away from releasing a claim we do not own. Distinct from `refusedReleaseKeepsOwnership`, where
    // macOS refuses and the claim genuinely is still ours.
    let fake = FakeInventory()
    let subject = await claims(fake)
    await fake.setReplaceAfterRelease(["en-US"])

    try await subject.claim(Locale(identifier: "en-US"), purpose: "session")
    await subject.finish(Locale(identifier: "en-US"))

    #expect(await fake.reserved == ["en-US"], "control: the replacement is visible")
    #expect(
      await subject.ownsClaim("en-US") == false,
      "a visible claim after an acknowledged release is not ours")
  }

  // MARK: - Use counting

  @Test("Two users of one language must both finish before the claim goes back")
  func usesAreCountedNotFlagged() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)

    try await subject.claim(Locale(identifier: "de-DE"), purpose: "session")
    try await subject.claim(Locale(identifier: "de-DE"), purpose: "download")
    #expect(await subject.useCount("de-DE") == 2)

    await subject.finish(Locale(identifier: "de-DE"))
    #expect(await fake.reserved == ["de-DE"], "one consumer is still working")

    await subject.finish(Locale(identifier: "de-DE"))
    #expect(await fake.reserved.isEmpty)
  }

  @Test("An unbalanced finish cannot drive the count negative or release twice")
  func unbalancedFinishIsHarmless() async throws {
    let fake = FakeInventory()
    let subject = await claims(fake)

    await subject.finish(Locale(identifier: "de-DE"))
    await subject.finish(Locale(identifier: "de-DE"))

    #expect(await subject.useCount("de-DE") == 0)
    #expect(await fake.releaseCalls.isEmpty, "nothing was ever ours to release")
  }

  // MARK: - Exclusivity, now asserted on the real transaction

  @Test("Only one caller is inside the claim transaction at a time")
  func transactionExcludesAcrossSuspensions() async throws {
    // An actor alone does NOT give this: it serialises calls but is reentrant at every await, and
    // the transaction suspends at every step. Measured before the lock existed: 12 callers inside
    // a section meant for 1. Driven through `claim` rather than through the lock primitive, so the
    // test fails if the transaction ever stops holding the lock across its suspensions.
    let occupancy = Occupancy()
    let fake = FakeInventory()
    let subject = await claims(fake)
    let hook: @Sendable () async -> Void = {
      await occupancy.enter()
      await Task.yield()
      await occupancy.leave()
    }
    await fake.setOnRead(hook)

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          try? await subject.claim(Locale(identifier: "l\(index)-XX"), purpose: "session")
        }
      }
    }

    #expect(await occupancy.peak == 1, "peak occupancy inside the transaction must be 1")
    #expect(await occupancy.completed == 12, "and every caller must actually have run")
  }

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

  // MARK: - Structural guard, retargeted

  /// Replaces the source guard that used to read `acquireLocaleForSession`, deleted with that
  /// method. What it protected — warm-up taking a claim and handing it back on EVERY exit — still
  /// needs protecting, and `prepare()` reaches the real Speech stack, so a behavioural test cannot
  /// see it. The exits are counted here instead.
  @Test("Warm-up claims and hands back on every path")
  func prepareBalancesItsClaim() throws {
    // **Comments stripped first.** A guard over source that cannot tell code from prose ABOUT code is
    // the precision failure this repo keeps hitting — the shipped no-download guard once matched its
    // own doc comment and reported the method as an installer. This is a presence-and-count question
    // about distinctive call text, not a lexical one (no literal or wrapped expression in this body
    // contains it), so the line-level stripper the sibling guard already uses is the right weight;
    // swift-patterns.md RULE: scan-swift-source-with-swiftparser draws the line at lexical precision,
    // and if this ever needs that, it goes to SwiftParser rather than growing a lexer.
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprLivePreview/Engines/ApplePreviewRecognizer.swift"),
        encoding: .utf8))
    guard let start = source.range(of: "func prepare() async throws {"),
      let end = source.range(
        of: "private func performPrepare()", range: start.upperBound..<source.endIndex)
    else {
      Issue.record("prepare() not found — retarget this guard rather than deleting it")
      return
    }
    let body = String(source[start.upperBound..<end.lowerBound])
    #expect(body.components(separatedBy: "LocaleClaims.shared.claim(").count - 1 == 1)
    #expect(
      body.components(separatedBy: "LocaleClaims.shared.finish(").count - 1 == 2,
      "one hand-back on the throwing path, one on the success path")
  }

  /// Retargeted from `ApplePackCatalogTests.releaseIsInsideTheTransactionLock`, deleted with the
  /// catalogue's own copy of the release path (#2145). The property it protected is unchanged and
  /// still needs protecting: the use check and the system release must be ONE locked step, because
  /// unlocked, a recording can claim between them and then lose the claim it just took.
  ///
  /// **Asserted at SOURCE, deliberately.** The obvious behavioural test — have the fake's release
  /// read the use count — passes identically with and without the lock, because nothing in it
  /// competes for the interleaving. Driving a real interleaving pins a scheduling order rather
  /// than the property.
  @Test("finish() holds the lock across the whole release decision")
  func finishHoldsTheLockAcrossTheReleaseDecision() throws {
    // Comments stripped, for the reason given on `prepareBalancesItsClaim`: this body carries a log
    // line and several comments that name the release, and a raw text search would read those as the
    // code they describe.
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprLivePreview/Engines/LocaleClaims.swift"),
        encoding: .utf8))

    guard let start = source.range(of: "package func finish(_ locale: Locale) async {") else {
      Issue.record("finish() not found; it was renamed or moved — retarget, do not delete")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(body.contains("decrementUse"), "control: this is the real release path")
    guard
      let locked = body.range(of: "await lock()")?.lowerBound,
      let checked = body.range(of: "decrementUse")?.lowerBound,
      let released = body.range(of: "releaseSystemClaim")?.lowerBound,
      let unlocked = body.range(of: "unlock()", options: .backwards)?.lowerBound
    else {
      Issue.record("could not locate the lock boundaries")
      return
    }
    #expect(locked < checked, "the lock must be taken BEFORE the use count is read")
    #expect(checked < released, "and the release decided inside it")
    #expect(released < unlocked, "and held until after the release has been acted on")
  }
}
