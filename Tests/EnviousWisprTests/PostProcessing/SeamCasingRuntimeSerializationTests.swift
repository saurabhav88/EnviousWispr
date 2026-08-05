import Foundation
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
