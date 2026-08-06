import Foundation
import NaturalLanguage
import Testing
import os

@testable import EnviousWisprPostProcessing

// #1922: the runtime became PER-LANGUAGE, and that is what put its concurrency
// proof at risk.
//
// The type's one-lock argument holds only because preparation and decisions never
// overlap in the single shared `NSSpellChecker`. With one language that was true
// by construction — prewarm ran once at launch and nothing else prepared. With
// twelve, any dictation in a new language can start a preparation at any moment,
// and rev 2 of the plan did exactly that with independent per-language warmers,
// which grounded review round 2 correctly killed.
//
// Two guards replaced it, and each closes a window the other does not:
//
//  1. A global drain: one builder at a time, never on the paste path.
//  2. A decision LEASE: the drain also waits for decisions already in flight.
//     Refusing new snapshots is necessary and NOT sufficient — a snapshot taken
//     microseconds before preparation begins is already out, and its system call
//     would land inside the preparation window.
//
// Both are asserted here against the real `drain()`, with the system preparation
// replaced by a builder this suite can hold open. Every case runs under the
// cross-suite exclusion because the runtime is process-global.
@Suite("Seam casing runtime serialization (#1922)", .serialized)
struct SeamCasingRuntimeSerializationTests {

  static func ready(_ ordinary: Set<String>) -> SeamCasingOracle {
    SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { ordinary.contains($0) ? .ordinary : .notOrdinary },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in false })
  }

  /// Availability without stranding a lease. See `SeamCasingOracleTests.probe`.
  static func probe(_ base: String) -> SeamCasingOracle {
    let oracle = SeamCasingOracleRuntime.snapshot(for: base)
    if oracle.isAvailable { SeamCasingOracleRuntime.releaseDecisionLease() }
    return oracle
  }

  /// Wait for a semaphore the runtime signals, without blocking the test's thread.
  static func awaitSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      DispatchQueue.global().async {
        // deadline-fallback: the semaphore is the signal; this bound is the fail-safe
        continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
      }
    }
  }

  /// Wait for an observable state change in the runtime.
  ///
  /// The drain publishes from a DETACHED task, so there is no handle to await and
  /// no callback to hook — the published state IS the signal, and this reads it.
  /// The interval below is how often that signal is sampled, not how long the
  /// test waits for it; the deadline is a fail-safe against a hang and is never
  /// the mechanism.
  static func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      // settle: poll interval for the published-state signal, not a fixed wait
      try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
  }

  // MARK: - One builder at a time

  @Test("#1922 Two unbuilt languages prepare ONE AT A TIME, never concurrently")
  func preparationIsSerialized() async throws {
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      // Installed BEFORE any preparation starts, deliberately. `installForTesting`
      // bumps the epoch, and a preparation already in flight refuses to publish
      // across an epoch change — so arranging this later would strand the very
      // preparation the case is measuring.
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")

      let inside = OSAllocatedUnfairLock(initialState: 0)
      let peak = OSAllocatedUnfairLock(initialState: 0)
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)

      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        let now = inside.withLock { value -> Int in
          value += 1
          return value
        }
        peak.withLock { $0 = max($0, now) }
        entered.signal()
        // deadline-fallback: `release` is the signal; this bound only stops a defect hanging the suite
        _ = release.wait(timeout: .now() + 5)
        inside.withLock { $0 -= 1 }
        return Self.ready(["tack", "danke"])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      // Two languages neither of which has ever been requested.
      #expect(Self.probe("sv").unavailableReason == .oracleWarming, "first request warms")
      #expect(Self.probe("da").unavailableReason == .oracleWarming, "second request warms too")

      #expect(
        await Self.awaitSignal(entered),
        "the drain must have started a preparation off the paste path")

      // While a builder is inside, an ALREADY-READY language must ALSO refuse.
      // This is the invariant rev 2 broke: independent per-language warmers would
      // have let English keep deciding while another language was inside the one
      // shared checker, which is exactly what the one-lock proof forbids.
      #expect(
        Self.probe("en").unavailableReason == .oracleWarming,
        "a ready language must also refuse while any preparation is running")

      release.signal()
      release.signal()

      #expect(
        await Self.waitUntil { Self.probe("sv").isAvailable && Self.probe("da").isAvailable },
        "both languages must eventually publish")

      let observed = peak.withLock { $0 }
      #expect(
        observed == 1,
        "at most ONE builder may ever be inside the shared checker, saw \(observed)")
    }
  }

  // MARK: - The lease

  @Test("#1922 A decision lease blocks preparation until it is released")
  func leaseBlocksPreparation() async throws {
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")

      let builderRan = OSAllocatedUnfairLock(initialState: false)
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        builderRan.withLock { $0 = true }
        return Self.ready(["gestern"])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      // Take a decision lease, as the repair does, and DO NOT release it.
      let leased = SeamCasingOracleRuntime.snapshot(for: "en")
      #expect(leased.isAvailable, "precondition: English must be ready to lease")
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 1)

      // Request a language that has never been prepared. It must enqueue, and the
      // drain must decline to start while the lease is out.
      #expect(SeamCasingOracleRuntime.snapshot(for: "de").unavailableReason == .oracleWarming)

      // Give the detached drain a real chance to misbehave. A negative assertion
      // taken instantly would pass even if the gate were missing entirely.
      let started = await Self.waitUntil(timeout: .milliseconds(300)) {
        builderRan.withLock { $0 }
      }
      #expect(started == false, "no preparation may begin while a decision holds a lease")
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 1)

      // Releasing must re-poke the drain, or the queued language would stay
      // warming forever — a stranded queue is the failure mode this design has to
      // avoid, and it would be invisible in the field.
      SeamCasingOracleRuntime.releaseDecisionLease()
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0)

      #expect(
        await Self.waitUntil { Self.probe("de").isAvailable },
        "and release must let the queued language prepare")
      #expect(builderRan.withLock { $0 })
    }
  }

  @Test("#1922 A ready language DOES decide once preparation has published")
  func readyLanguageActsAfterPublication() async throws {
    // The two-way control for both cases above. Everything else here asserts a
    // REFUSAL, and a runtime that refused permanently would satisfy all of it
    // while shipping a dead feature.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in Self.ready(["gestern"]) }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      #expect(Self.probe("de").unavailableReason == .oracleWarming, "first request warms")
      #expect(
        await Self.waitUntil { Self.probe("de").isAvailable }, "preparation must complete")

      let oracle = SeamCasingOracleRuntime.snapshot(for: "de")
      defer { SeamCasingOracleRuntime.releaseDecisionLease() }
      let payloads = CursorInsertionRepair.repair(
        text: "Gestern war es besser.",
        context: CursorInsertionRepair.CaretText(left: "Ich sagte dass ", right: ""),
        protectedWords: [], language: "de", oracle: oracle)

      #expect(
        payloads.repairedText == "gestern war es besser. ",
        "a published language must actually act, or the whole feature is inert")
    }
  }

  @Test("#1922 A lease is issued ONLY when a language is ready")
  func leasesAreIssuedOnlyWhenReady() async throws {
    // A lease taken on a refusal would never be released — the repair releases in
    // `defer`, but only on the path that took one — and a stranded lease stops
    // every future language preparing, silently and permanently.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        .unavailable(.dictionaryUnavailable)
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      _ = SeamCasingOracleRuntime.snapshot(for: "fi")
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0, "warming must not lease")

      #expect(
        await Self.waitUntil {
          SeamCasingOracleRuntime.snapshot(for: "fi").unavailableReason == .dictionaryUnavailable
        })
      #expect(
        SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0,
        "an unavailable language must not lease either")

      _ = SeamCasingOracleRuntime.snapshot(for: nil)
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0, "nil must not lease")

      SeamCasingOracleRuntime.disableAfterTimeout()
      _ = SeamCasingOracleRuntime.snapshot(for: "en")
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0, "latched must not lease")
    }
  }

  @Test("#1922 An unmatched release cannot steal a lease another decision holds")
  func unmatchedReleaseCannotStealALease() async throws {
    // Grounded review r3 (MED). Leases carry no identity, so `releaseDecisionLease()`
    // called by a decision that never took one decrements whichever decision
    // currently holds the count — and the drain then starts preparing while that
    // decision is still inside the shared spell checker, which is exactly the race
    // the lease exists to close.
    //
    // The production fix is at the CALL SITE: release only if the snapshot was
    // ready. This freezes the property that makes the fix necessary — an extra
    // release does real damage — so nobody restores the unconditional form
    // believing it harmless.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")

      // Decision A: ready, so it leases.
      let a = SeamCasingOracleRuntime.snapshot(for: "en")
      #expect(a.isAvailable)
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 1)

      // Decision B: a language with no policy. It gets no lease — and if it
      // releases anyway, it takes A's.
      let b = SeamCasingOracleRuntime.snapshot(for: nil)
      #expect(b.isAvailable == false, "an unsupported language must not be ready")
      #expect(
        SeamCasingOracleRuntime.outstandingLeasesForTesting() == 1,
        "and it must not have taken a lease of its own")

      // What the old unconditional `defer` did.
      SeamCasingOracleRuntime.releaseDecisionLease()
      #expect(
        SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0,
        "THIS is the damage: A conceptually still holds its lease, the count says zero, and the drain is now free to prepare while A is inside the checker"
      )

      // Clean up A's real lease. The count is already zero, so this is a no-op —
      // which is the other half of the same defect: the accounting cannot recover.
      SeamCasingOracleRuntime.releaseDecisionLease()
      #expect(SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0)
    }
  }

  @Test("#1922 A regional tag reaches the SAME cache entry as its base code")
  func regionalTagSharesTheBaseEntry() async throws {
    // Whole-diff review, P2. The caller passes whatever the resolver produced;
    // `repair` keys off the NORMALISED base code. If the runtime keyed off the
    // raw tag instead, `de-DE` would build a phantom entry, ask the spell checker
    // for a dictionary named `de-DE`, find none, and mark that key permanently
    // unavailable — silently, and only for users whose language carries a region.
    //
    // Latent today (every producer emits a base code) and cheap to make
    // impossible, which is the bar for fixing an unproven defect: trivial fix,
    // silent failure.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["gestern"]), for: "de")

      for raw in ["de", "de-DE", "de_AT", "de-CH"] {
        let oracle = SeamCasingOracleRuntime.snapshot(for: raw)
        #expect(oracle.isAvailable, "\(raw) must resolve to the prepared German entry")
        if oracle.isAvailable { SeamCasingOracleRuntime.releaseDecisionLease() }
      }
    }
  }

  @Test("#1922 A language with no casing policy never enters the preparation drain")
  func unsupportedLanguageNeverPrepares() async throws {
    // Whole-diff review, P2, and this one is reachable today: dictating Japanese
    // queued a real spell-checker preparation that `repair` could never use, and
    // while it ran EVERY ready language refused with `oracleWarming`. Pure waste
    // plus a self-inflicted global refusal window.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")

      let builderRan = OSAllocatedUnfairLock(initialState: false)
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        builderRan.withLock { $0 = true }
        return Self.ready([])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      for unsupported in ["ja", "zh", "pl", "cs", "hu", "th"] {
        let oracle = SeamCasingOracleRuntime.snapshot(for: unsupported)
        #expect(
          oracle.unavailableReason == .languageNotSupported,
          "\(unsupported) must refuse immediately, not warm")
      }

      // Give the drain a real chance to misbehave; an instant assertion would
      // pass even with the guard missing.
      let started = await Self.waitUntil(timeout: .milliseconds(300)) {
        builderRan.withLock { $0 }
      }
      #expect(started == false, "no preparation may be queued for a language that will abstain")

      // Two-way control: a SUPPORTED language must still prepare, or this test
      // would also pass against a runtime that prepares nothing at all.
      #expect(SeamCasingOracleRuntime.snapshot(for: "sv").unavailableReason == .oracleWarming)
      #expect(
        await Self.waitUntil { builderRan.withLock { $0 } },
        "a supported language must still reach the builder")
    }
  }

  @Test("#1922 Saving state for the exclusion helper must not START anything")
  func stateCaptureIsReadOnly() async throws {
    // Confirming whole-diff review, P2. `withSeamCasingOracleExclusion` saves the
    // prior English oracle so it can hand it back. Doing that with
    // `snapshot(for:)` enqueued English and started a real preparation, which
    // `resetForTesting()` cannot cancel — so the helper could manufacture the
    // very overlap the suites it guards exist to disprove.
    //
    // This asserts the read is inert on the hardest case: a runtime where English
    // has NEVER been prepared, which is exactly when `snapshot` would enqueue.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()

      let builderRan = OSAllocatedUnfairLock(initialState: false)
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        builderRan.withLock { $0 = true }
        return Self.ready(["the"])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      #expect(
        SeamCasingOracleRuntime.installedOracleForTesting("en") == nil,
        "nothing is prepared, so there is nothing to hand back")
      #expect(
        SeamCasingOracleRuntime.outstandingLeasesForTesting() == 0,
        "and a read must not take a lease")

      let started = await Self.waitUntil(timeout: .milliseconds(300)) {
        builderRan.withLock { $0 }
      }
      #expect(started == false, "reading prior state must not queue a preparation")

      // Two-way control: it must still SEE a prepared oracle, or the helper would
      // silently stop restoring anything and this test would pass on a stub.
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")
      #expect(
        SeamCasingOracleRuntime.installedOracleForTesting("en") != nil,
        "and it must return a READY oracle when one exists")
    }
  }

  @Test("#1922 A request made DURING another preparation is queued, not dropped")
  func requestDuringPreparationIsQueued() async throws {
    // Confirming whole-diff review r3, P2, and it is a real first-run cost: the
    // `preparing` early return used to sit above the enqueue, so a German
    // dictation arriving while English was still building was refused AND
    // forgotten. German casing then could not work until the THIRD dictation —
    // once at launch for every user whose second language is not English.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let built = OSAllocatedUnfairLock(initialState: [String]())
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { base in
        built.withLock { $0.append(base) }
        entered.signal()
        // deadline-fallback: `release` is the signal; this bound only stops a defect hanging the suite
        _ = release.wait(timeout: .now() + 5)
        return Self.ready(["the", "gestern"])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      // English starts building and is held open.
      #expect(Self.probe("en").unavailableReason == .oracleWarming)
      #expect(await Self.awaitSignal(entered), "English must be inside the builder")

      // German arrives DURING that build. It must refuse — one builder at a time —
      // AND be remembered.
      #expect(
        SeamCasingOracleRuntime.snapshot(for: "de").unavailableReason == .oracleWarming,
        "German must refuse while another language is inside the checker")

      release.signal()
      release.signal()

      // READ-ONLY from here, and that is the whole point of the case.
      //
      // The first draft waited on `probe("de")`, which calls `snapshot(for:)` —
      // so the wait itself re-requested German, queued it, and the language
      // became ready no matter what. The test passed against the defect it was
      // written to catch, and only the mutation control exposed it. An assertion
      // must never be able to repair the state it is inspecting.
      #expect(
        await Self.waitUntil {
          SeamCasingOracleRuntime.installedOracleForTesting("de") != nil
        },
        "German must prepare from the request made DURING English's build, with no second ask")
      #expect(
        built.withLock { $0 }.sorted() == ["de", "en"],
        "both languages built exactly once, got \(built.withLock { $0 })")
    }
  }

  @Test("#1922 An early English request and prewarm do not queue English twice")
  func prewarmDoesNotDoubleQueueEnglish() async throws {
    // Confirming whole-diff review r3, P2. `prewarm()` is launched
    // asynchronously, so a dictation can request English first. That request
    // marks English warming and queues it while leaving `prewarmStarted` false,
    // so an unconditional append in `prewarm()` queued English a second time —
    // and during the pointless second build every ready language refused.
    try await withSeamCasingOracleExclusion {
      // `prewarmStarted: false` is REQUIRED, not incidental. The default reset
      // marks prewarm as already run — correct for every other case, because it
      // stops a real prewarm racing the test — but it makes `prewarm()` return at
      // its first guard, so a case aimed at its body reaches nothing and passes
      // against any implementation. The first draft did exactly that and the
      // mutation control caught it.
      SeamCasingOracleRuntime.resetForTesting(prewarmStarted: false)

      let builds = OSAllocatedUnfairLock(initialState: 0)
      SeamCasingOracleRuntime.setPreparationOverrideForTesting { _ in
        builds.withLock { $0 += 1 }
        return Self.ready(["the"])
      }
      defer { SeamCasingOracleRuntime.setPreparationOverrideForTesting(nil) }

      // The dictation wins the race to English.
      #expect(SeamCasingOracleRuntime.snapshot(for: "en").unavailableReason == .oracleWarming)
      // Then launch prewarm, exactly as `WisprBootstrapper` does.
      await SeamCasingOracleRuntime.prewarm()

      // Read-only, for the same reason as the case above: probing would re-request.
      #expect(await Self.waitUntil { SeamCasingOracleRuntime.installedOracleForTesting() != nil })
      #expect(
        builds.withLock { $0 } == 1,
        "English must be built ONCE, got \(builds.withLock { $0 })")
    }
  }

  // MARK: - The latch is still process-wide

  @Test("#1922 One language's timeout latches EVERY language, not just its own")
  func timeoutLatchIsStillProcessWide() async throws {
    // A hung spell service is hung for all of them — it is one shared checker —
    // so per-language state must not have quietly made the latch per-language.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")
      SeamCasingOracleRuntime.installForTesting(Self.ready(["gestern"]), for: "de")
      #expect(Self.probe("en").isAvailable && Self.probe("de").isAvailable, "precondition")

      SeamCasingOracleRuntime.disableAfterTimeout()

      for base in ["en", "de", "sv", "tr", "fi"] {
        #expect(
          Self.probe(base).unavailableReason == .oracleTimedOut,
          "\(base) must be latched off by another language's timeout")
      }
    }
  }

  @Test("#1922 A missing dictionary is scoped to ITS language and no other")
  func unavailabilityIsPerLanguage() async throws {
    // The opposite direction, and it must NOT be process-wide: a Mac with no
    // Danish dictionary says nothing about its English one, and demoting all of
    // them would turn one language's outage into a whole-feature outage.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.ready(["the"]), for: "en")
      SeamCasingOracleRuntime.installForTesting(.unavailable(.dictionaryUnavailable), for: "da")

      #expect(Self.probe("da").unavailableReason == .dictionaryUnavailable)
      #expect(Self.probe("en").isAvailable, "one language's outage must not disable another")
    }
  }

  // MARK: - The tagger's ordering contract

  /// Is German word-class tagging actually available here? CI's hosted runner
  /// may not carry the assets, and a missing model must SKIP rather than fail.
  static var germanWordClassAvailable: Bool {
    NLTagger.availableTagSchemes(for: .word, language: .german).contains(.lexicalClass)
  }

  @Test(
    "#1922 The tagger is pinned AFTER its string, or the pin is silently discarded",
    .enabled(if: SeamCasingRuntimeSerializationTests.germanWordClassAvailable))
  func taggerLanguagePinSurvivesTheStringAssignment() {
    // Cloud review, P2. Assigning `NLTagger.string` RESETS the tagger, so calling
    // `setLanguage` first threw the pin away — and the shipped comment claimed the
    // pin was load-bearing, which made a false claim look deliberate.
    //
    // This asserts the API contract directly rather than through the runtime,
    // because the runtime's closure only exists after a real `NSSpellChecker`
    // preparation and this question is purely about `NLTagger`.
    //
    // SINGLE WORDS, deliberately. A first probe of eight multi-word German
    // sentences found ZERO differences — auto-detection gets German right when it
    // has a sentence to work with — so a test built from those would have frozen
    // nothing. The divergence is on one-word payloads, which is exactly the
    // dictation this feature serves.
    func tag(_ payload: String, pinFirst: Bool) -> NLTag? {
      let tagger = NLTagger(tagSchemes: [.lexicalClass])
      if pinFirst {
        tagger.setLanguage(.german, range: payload.startIndex..<payload.endIndex)
        tagger.string = payload
      } else {
        tagger.string = payload
        tagger.setLanguage(.german, range: payload.startIndex..<payload.endIndex)
      }
      return tagger.tag(at: payload.startIndex, unit: .word, scheme: .lexicalClass).0
    }

    // Ordinary German nouns. Each MUST tag as a noun so the veto keeps its
    // capital; pinned-first they came back `OtherWord` and were lowercased.
    for noun in ["Hut", "Bad", "Boot"] {
      #expect(
        tag(noun, pinFirst: false) == .noun,
        "\(noun) must tag as a noun when the language is pinned AFTER the string")
    }

    // The two-way control. Without it this passes on a machine where BOTH orders
    // happen to answer `.noun`, which would prove nothing about the ordering.
    let divergent = ["Hut", "Bad", "Boot"].filter { tag($0, pinFirst: true) != .noun }
    #expect(
      divergent.isEmpty == false,
      "at least one word must differ between the orderings, or this test cannot fail")
  }

  @Test(
    "#1922 The SHIPPED German veto answers noun for a one-word noun",
    .enabled(if: SeamCasingRuntimeSerializationTests.germanWordClassAvailable))
  func shippedGermanVetoTagsAOneWordNoun() async throws {
    // The case above freezes an `NLTagger` FACT and is therefore blind to the
    // shipped call site — reverting the ordering in `prepare` left it green, which
    // the mutation control exposed. This one drives the REAL closure the product
    // uses, so it fails when that ordering regresses.
    //
    // No preparation override: the point is to exercise the real
    // `NSSpellChecker` + `NLTagger` build. Gated on German word-class
    // availability so a runner without the assets SKIPS rather than fails.
    try await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()

      // The read-only seam, so waiting cannot itself re-request — and so the
      // closure stays `@Sendable` without capturing a mutable local.
      _ = await Self.waitUntil(timeout: .seconds(30)) {
        SeamCasingOracleRuntime.installedOracleForTesting("de") != nil
          || SeamCasingOracleRuntime.snapshot(for: "de").unavailableReason != .oracleWarming
      }

      guard let german = SeamCasingOracleRuntime.installedOracleForTesting("de") else {
        // A machine without a usable German dictionary cannot answer this, and a
        // fabricated pass would be worse than no coverage.
        Issue.record(
          "German did not become available; skipping is correct but the case ran anyway")
        return
      }

      for noun in ["Hut", "Bad", "Boot"] {
        #expect(
          german.isNoun(noun),
          "the shipped veto must read `\(noun)` as a noun, or German loses its capital")
      }
      // Two-way control: the veto must NOT answer noun to everything, or it would
      // pass here while disabling German entirely.
      #expect(
        german.isNoun("gestern") == false,
        "and it must still answer NOT-a-noun for an ordinary adverb")
    }
  }

  // MARK: - Capability profiles

  @Test(
    "#1922 Each language asks macOS only for what its rule actually needs",
    arguments: [
      // Getting this wrong is SILENT. The shipped code required name detection
      // unconditionally; it exists for exactly en/fr/de/it, so the eight
      // dictionary-only languages would have resolved unavailable and the release
      // would have shipped four languages while claiming twelve — with every test
      // green, because refusing without name detection is correct ENGLISH
      // behaviour. Found while writing the runtime and independently by grounded
      // review round 2.
      ("de", true, true),
      ("en", true, false),
      ("fr", true, false),
      ("it", true, false),
      ("sv", false, false),
      ("nl", false, false),
      ("es", false, false),
      ("pt", false, false),
      ("da", false, false),
      ("fi", false, false),
      ("tr", false, false),
      ("ru", false, false),
    ])
  func capabilityProfilesMatchTheRule(
    _ base: String, _ needsNameType: Bool, _ needsLexicalClass: Bool
  ) {
    let profile = SeamCasingOracleRuntime.CapabilityProfile.forLanguage(base)
    #expect(profile.needsNameType == needsNameType, "\(base): name detection requirement")
    #expect(profile.needsLexicalClass == needsLexicalClass, "\(base): word class requirement")
  }

  @Test("#1922 Only German requires the word-class scheme, because only German vetoes")
  func onlyGermanNeedsWordClass() {
    // A requirement and the rule that consumes it must agree. German's entire rule
    // IS the noun veto, so a missing scheme makes it unavailable rather than
    // merely weaker; any other language requiring it would be demanding something
    // it never consults, and would go dark on machines for no reason.
    for (code, policy) in CursorInsertionRepair.LanguageRules.casingPolicies {
      let profile = SeamCasingOracleRuntime.CapabilityProfile.forLanguage(code)
      #expect(
        profile.needsLexicalClass == policy.nounVeto,
        "\(code): the word-class requirement must match whether the veto is used")
    }
  }
}
