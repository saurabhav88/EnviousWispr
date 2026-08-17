import EnviousWisprCore
import Foundation

/// macOS's locale-claim table, as four narrow async calls over Foundation values.
///
/// **Injectable because the real one is `Speech.AssetInventory`, whose API is entirely static.**
/// Without a seam the transaction in `LocaleClaims` cannot be driven from a test at all, and #2145 is
/// what that costs: every release the app has ever issued was a no-op, for as long as the feature has
/// shipped, and no test could have noticed — the only double available recorded that a closure had
/// been CALLED, never that a claim went away.
///
/// `Locale` rather than a tag string, deliberately: which `Locale` object `release` is given IS the
/// defect (`AppleLocaleClaim.releaseTarget`), so that decision has to live inside the tested owner
/// rather than inside the live adapter nothing can reach. No Speech type crosses this boundary, so
/// the LivePreview target keeps its Core + PostProcessing dependency list.
package struct LocaleInventory: Sendable {
  /// Every claim macOS currently holds. **Machine-wide** — measured for #2145: other processes'
  /// claims appear here, and a claim outlives the process that took it, even under `SIGKILL`.
  package var reserved: @Sendable () async -> [Locale]

  /// True when this call NEWLY claimed the locale. False means "did not newly claim", which covers
  /// the healthy already-held case, so it is not a failure flag. Throws at the cap
  /// (`SFSpeechErrorDomain` 11) and for an unsupported locale (15).
  package var reserve: @Sendable (Locale) async throws -> Bool

  /// macOS's acknowledgement that it released something. Not proof the claim is gone.
  package var release: @Sendable (Locale) async -> Bool

  package var maximumReserved: @Sendable () async -> Int

  package init(
    reserved: @escaping @Sendable () async -> [Locale],
    reserve: @escaping @Sendable (Locale) async throws -> Bool,
    release: @escaping @Sendable (Locale) async -> Bool,
    maximumReserved: @escaping @Sendable () async -> Int
  ) {
    self.reserved = reserved
    self.reserve = reserve
    self.release = release
    self.maximumReserved = maximumReserved
  }
}

/// How a claim was obtained. A closed set, so the log line has a vocabulary rather than a sentence.
package enum ClaimResult: String, Sendable {
  /// Somebody already held it — possibly us, possibly another process. We are riding on it.
  case alreadyHeld = "already_held"
  /// This process took it. Only this outcome makes the claim ours to give back.
  case reserved
  /// Refused as already-claimed while the table showed nothing; a second attempt succeeded.
  case recovered
}

/// Owns Apple's locale claims: who holds one, which are OURS, and which may be taken away.
///
/// ## Why this type exists at all
///
/// Review found four separate defects in this area, one per round, and each was patchable on its
/// own: eviction was missing, then a cached engine lost its claim, then two callers interleaved
/// inside the transaction, then a claim was evicted between being taken and being used. Four rounds
/// of the same subject is the signal that the patches were the problem.
///
/// The common root was that nothing modelled a claim being IN USE. Apple's inventory answers
/// "reserved or not"; it cannot answer "still needed", so every eviction was a guess. Two consumers
/// register their need — a recording, for as long as it is transcribing, and a download, for as long
/// as it is fetching — and eviction only ever takes a claim nobody registered.
///
/// ## #2145 added the second missing idea: OWNERSHIP, and moved the transaction here
///
/// The table is machine-wide, and one process can release another LIVE process's claim silently —
/// measured, the holder's own next read came back empty. So "nobody in this process needs it" was
/// never sufficient grounds to hand a claim back. `owned` records the tags this process actually
/// took, and nothing else is ever released or evicted. That hazard was inert only because the release
/// call itself was broken; repairing the release arms it, so the two land together.
///
/// **Ownership is best-effort and says so.** `owned` records tags whose reserve call THIS process
/// completed successfully; release and eviction are attempted only for those. That is a conservative
/// local gate, not proof of current ownership — another process can release and replace a tag
/// afterwards, and no local ledger can observe that ABA substitution. The ledger is therefore only
/// ever used to WITHHOLD an action, never to authorise a forceful one, so the worst case is a claim
/// we decline to free rather than one we take from somebody.
///
/// The transaction moved here from `ApplePreviewRecognizer`'s static methods in the same change.
/// Splitting reservation, use-counting and release across three owners is what let them make
/// incompatible decisions.
///
/// ## The lock is separate from the need
///
/// The lock serialises the read → maybe-evict → reserve → verify TRANSACTION, which suspends at every
/// step. **An actor is not enough for that**: it serialises calls but is reentrant at every `await`,
/// so two callers interleave inside one method — measured at 12 callers inside a section meant for 1.
/// The lock is held ACROSS the suspensions instead.
///
/// It is NOT held while the claim is used. A download takes ~30 s, and holding a global lock across
/// it would stall every preview that started meanwhile; the use registry protects the claim for that
/// span instead, which costs nothing and blocks nobody.
///
/// FIFO hand-off ported WHOLE from the shipped `AppLoggerTestExclusion` — `unlock()` keeps `held` true
/// and passes ownership straight to the next waiter, so there is no gap for a third caller and no
/// starvation. Porting a proven primitive partially is what caused the first defect in this list.
///
/// **The lock protects this process only.** Nothing here can serialise against another app, which is
/// why the recovery path below refuses to release rather than racing it.
package actor LocaleClaims {
  package static let shared = LocaleClaims(
    inventory: .live,
    log: { await AppLogger.shared.log("LIVE_PREVIEW \($0)", category: "LivePreview") })

  private let inventory: LocaleInventory
  private let log: @Sendable (String) async -> Void

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Tag -> how many consumers currently depend on this claim. A count, not a flag: a recording and a
  /// download can legitimately need the same language at once.
  private var uses: [String: Int] = [:]

  /// Tags THIS process claimed itself. Never contains a claim we merely found already held — riding
  /// on somebody else's claim must not end with us releasing it.
  private var owned: Set<String> = []

  /// Not private, so a test can exercise this on its OWN instance rather than on the process-wide
  /// `shared`. Tests inside one suite run in parallel, so asserting against the singleton would make
  /// two tests contend for the thing they are measuring.
  package init(
    inventory: LocaleInventory,
    log: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    self.inventory = inventory
    self.log = log
  }

  // MARK: - One way in, one way out

  /// Claim `locale` and register one unit of work on it, in ONE locked step.
  ///
  /// **Claiming and registering must not be two calls.** Between an unlocked reserve and a later
  /// register the claim reads as unused, and the next caller through the lock can evict it — the same
  /// defect as having no registration at all, only harder to see.
  ///
  /// **Every caller MUST pair this with `finish(_:)`.**
  /// `purpose` names the caller in the log line — `prepare`, `session`, `download`. Two callers
  /// share these slots and a claim line with no purpose cannot say which one is holding.
  @discardableResult
  package func claim(_ locale: Locale, purpose: String) async throws -> ClaimResult {
    let tag = locale.identifier(.bcp47)
    await lock()
    let result: ClaimResult
    do {
      result = try await performClaim(locale)
    } catch {
      unlock()
      throw error
    }
    uses[tag, default: 0] += 1
    unlock()
    await log("claim \(purpose) tag=\(tag) result=\(result.rawValue)")
    return result
  }

  /// Give up one consumer's interest, returning the system claim when nobody is left AND it is ours.
  ///
  /// **The zero check is the point.** A recording ending must not drop a claim a download is still
  /// using, and vice versa — they legitimately overlap on the same language. The ownership check
  /// beside it is #2145's: a claim we never took is not ours to hand back.
  package func finish(_ locale: Locale) async {
    let tag = locale.identifier(.bcp47)
    await lock()
    let remaining = decrementUse(tag)
    var outcome = "still_in_use"
    if remaining == 0 {
      if !owned.contains(tag) {
        outcome = "not_ours"
      } else if await releaseSystemClaim(tag) {
        owned.remove(tag)
        outcome = "released"
      } else {
        // Keep ownership: the claim is still ours and still there, so a later `finish` or an eviction
        // can try again.
        outcome = "release_refused"
      }
    }
    unlock()
    // **Logged on EVERY path, including the successful one.** #2145 was invisible for two releases
    // partly because a release that did nothing looked exactly like a release that worked: silence.
    // A silent failure needs a feedback path, not just a fix, so the closed vocabulary here is what
    // makes "did the claim actually go back" answerable from one grep instead of an SDK probe.
    // It is also the only receipt available: `AssetInventory.reservedLocales` read from a separate
    // process does NOT show this app's claims (measured — 18 samples across a live recording, all
    // empty, while the app was mid-session), so an external prober cannot verify this and the app
    // has to say so itself.
    await log("claim finish tag=\(tag) outcome=\(outcome) remaining=\(remaining)")
  }

  /// Test-only view of the registrations.
  package func useCount(_ tag: String) -> Int { uses[tag] ?? 0 }

  /// Test-only view of what this process took.
  package func ownsClaim(_ tag: String) -> Bool { owned.contains(tag) }

  // MARK: - The transaction, always under the lock

  private func performClaim(_ locale: Locale) async throws -> ClaimResult {
    let tag = locale.identifier(.bcp47)
    let already = await inventory.reserved()
    if already.contains(where: { $0.identifier(.bcp47) == tag }) { return .alreadyHeld }

    if already.count >= (await inventory.maximumReserved()) {
      await makeRoom(reserved: already)
    }

    var recoveryTried = false
    while true {
      let newly = try await inventory.reserve(locale)
      // Only read back when the reserve did NOT newly claim: `true` is already the answer, and the
      // steady state should cost one inventory call per recording, not two.
      var heldAfter = newly
      if !newly {
        heldAfter = (await inventory.reserved()).contains { $0.identifier(.bcp47) == tag }
      }
      switch AppleLocaleClaim.outcome(
        reserveReturned: newly, heldAfter: heldAfter, recoveryAlreadyTried: recoveryTried)
      {
      case .proceed:
        // Ours only if WE took it. Finding it already held makes it somebody else's to release.
        if newly { owned.insert(tag) }
        return recoveryTried ? .recovered : (newly ? .reserved : .alreadyHeld)
      case .recover:
        // **Retry, never release.** macOS refused as already-claimed while reporting no such claim.
        // Releasing to clear the phantom is what a first draft did, and it is unsafe: between the
        // read that said "absent" and the release, another process can take that tag, and our
        // release would silently take it away — the exact harm the ownership ledger exists to
        // prevent. There is no cross-process lock to close that window with, so per
        // close-the-window-never-handle-it we do not open it.
        recoveryTried = true
        await log("claim reserve_refused_absent tag=\(tag) retrying_once")
      case .refuse:
        await log(
          "claim refused tag=\(tag) reserved=\((await inventory.reserved()).map { $0.identifier(.bcp47) })"
        )
        throw LivePreviewError.localeUnavailable
      }
    }
  }

  /// Free one slot, or leave the table alone and let macOS's own refusal surface.
  ///
  /// A refused download is a bad outcome; silently breaking another app's live dictation is a worse
  /// one. When nothing is ours to give up, this does nothing and `reserve` throws its own `Code=11`.
  private func makeRoom(reserved: [Locale]) async {
    let tags = reserved.map { $0.identifier(.bcp47) }
    guard
      let victim = AppleLocaleClaim.evictionVictim(
        reserved: tags, owned: owned, inUse: Set(uses.keys))
    else {
      await log("claim capacity held=\(tags.count) none_evictable")
      return
    }
    if await releaseSystemClaim(victim, visible: reserved) {
      owned.remove(victim)
    } else {
      await log("claim eviction_refused tag=\(victim)")
    }
  }

  /// Ask macOS to drop `tag`, and report whether we may stop considering it ours.
  ///
  /// Two answers, in order, because they mean different things. macOS ACKNOWLEDGING the release is
  /// enough: a tag visible afterwards may be another process's replacement, and treating that as our
  /// failure would make us hold ownership over somebody else's claim. Only when macOS refuses do we
  /// re-read — a refusal also covers "there was nothing held", which is a success from here.
  ///
  /// The `release` Bool alone was never enough, and reading it was not the bug either: #2145 handed
  /// macOS a `Locale` it could not match, so the call returned false AND nothing happened, and no
  /// caller looked.
  private func releaseSystemClaim(_ tag: String, visible: [Locale]? = nil) async -> Bool {
    let reserved: [Locale]
    if let visible {
      reserved = visible
    } else {
      reserved = await inventory.reserved()
    }
    let acknowledged = await inventory.release(
      AppleLocaleClaim.releaseTarget(tag: tag, reserved: reserved))
    if acknowledged { return true }
    return !(await inventory.reserved()).contains { $0.identifier(.bcp47) == tag }
  }

  private func decrementUse(_ tag: String) -> Int {
    guard let count = uses[tag] else { return 0 }
    if count <= 1 {
      uses.removeValue(forKey: tag)
      return 0
    }
    uses[tag] = count - 1
    return count - 1
  }

  // MARK: - The transaction lock

  private func lock() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  private func unlock() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}
