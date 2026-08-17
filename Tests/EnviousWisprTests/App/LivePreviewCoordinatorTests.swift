@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprLivePreview
@testable import EnviousWisprServices

/// #1988 — the live preview's limb contract.
///
/// These tests deliberately do NOT drive Apple's recognizer. Building a
/// `SpeechAnalyzer` needs macOS 26, a reserved locale and possibly a model
/// download, none of which belong in a unit test and none of which the CI runner
/// has. What IS unit-testable is the part that protects the heart: the gate that
/// decides whether any of that happens at all, and the bound on what the feature
/// retains. Live behaviour is covered by UAT.
/// Wraps a resolver in a route for the coordinator's `selectedRoute` provider.
///
/// These suites test the coordinator's POLICY, not an engine's OS capability, so
/// support defaults to true; suites that care pass `supported: false` explicitly.
/// Returning the PROVIDER rather than a route keeps every call site honest about
/// the fact that the coordinator reads it once per recording.
private func previewRoute(
  supported: Bool = true,
  _ resolve: @escaping LivePreviewEngineResolver
) -> () -> LivePreviewEngineRoute {
  { LivePreviewEngineRoute(telemetryEngineID: "universal", isSupportedOnThisSystem: { supported }, resolve: resolve) }
}

@MainActor
struct LivePreviewCoordinatorTests {

  // MARK: - #2123 F3: the removal barrier, tested at the coordinator

  /// **Tested HERE, not through a stand-in for the delivery home.** The previous
  /// tests drove a fake callback, so none of them could see a coordinator holder
  /// left un-awaited — which is exactly where the barrier had holes.
  ///
  /// A preview stuck in preparation still holds a fresh engine. Removal must not
  /// return while that is true, or the files are deleted under a live mapping.
  @Test("removal does not return while a preparation still holds an engine")
  func removalAwaitsPreparation() async {
    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private(set) var entered = false
      func wait() async {
        mutex.withLock { entered = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let open: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if open { c.resume() }
        }
      }
      func open() {
        let w: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        w?.resume()
      }
      var hasEntered: Bool { mutex.withLock { entered } }
    }
    final class Flag: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = false
      var isSet: Bool { mutex.withLock { value } }
      func set() { mutex.withLock { value = true } }
    }

    let stuck = Gate()
    final class StuckEngine: LivePreviewEngine, @unchecked Sendable {
      let stuck: Gate
      init(stuck: Gate) { self.stuck = stuck }
      func prepare() async throws { await stuck.wait() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "universal", commitment: ""),
            makeEngine: { StuckEngine(stuck: stuck) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !stuck.hasEntered { await Task.yield() }
    #expect(stuck.hasEntered, "control: preparation must be in flight")

    let drained = Flag()
    async let removal: Void = {
      await coordinator.releaseAndDrainForRemoval()
      drained.set()
    }()

    for _ in 0..<200 { await Task.yield() }
    #expect(
      !drained.isSet,
      "removal returned while a preparation still held an engine, so the delete would race it")

    stuck.open()
    await removal
    #expect(drained.isSet)
    #expect(!coordinator.hasPreparedEngineForTests, "and the slot is empty afterwards")
  }

  /// The FOURTH holder, and the one I missed twice: a session between opening and
  /// registering its teardown is referenced only by `sessionTask`. Cancelling
  /// that task without awaiting it leaves an engine alive past the delete.
  ///
  /// Mutation control: drop `await session?.value` from the drain and this goes
  /// green while the holder is still alive — which is how it survived two passes.
  @Test("removal waits for a session still being opened")
  func removalAwaitsASessionBeingOpened() async {
    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private var entered = false
      var hasEntered: Bool { mutex.withLock { entered } }
      func wait() async {
        mutex.withLock { entered = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let open: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if open { c.resume() }
        }
      }
      func open() {
        let w: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        w?.resume()
      }
    }
    final class Flag: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = false
      var isSet: Bool { mutex.withLock { value } }
      func set() { mutex.withLock { value = true } }
    }

    let openingGate = Gate()
    final class SlowOpenEngine: LivePreviewEngine, @unchecked Sendable {
      let gate: Gate
      init(gate: Gate) { self.gate = gate }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        // Held INSIDE the open: past preparation, before the coordinator can
        // register a teardown for it.
        await gate.wait()
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "universal", commitment: ""),
            makeEngine: { SlowOpenEngine(gate: openingGate) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !openingGate.hasEntered { await Task.yield() }
    #expect(openingGate.hasEntered, "control: the session must be mid-open")
    #expect(
      !coordinator.hasLiveSessionForTests,
      "control: no teardown is registered yet — that is what makes this holder invisible")

    let drained = Flag()
    async let removal: Void = {
      await coordinator.releaseAndDrainForRemoval()
      drained.set()
    }()

    for _ in 0..<200 { await Task.yield() }
    #expect(!drained.isSet, "removal returned while a session was still being opened")

    openingGate.open()
    await removal
    #expect(drained.isSet)
  }

  /// Nothing may start a preview while removal is in flight: the admission marker
  /// still exists until the files are gone, so a recording would resolve as
  /// installed and load the model straight back onto the files being deleted.
  @Test("no preview starts while removal is in flight")
  func removalSuppressesNewPreviews() async {
    final class Opens: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = 0
      var count: Int { mutex.withLock { value } }
      func record() { mutex.withLock { value += 1 } }
    }
    let opens = Opens()
    final class CountingEngine: LivePreviewEngine, @unchecked Sendable {
      let opens: Opens
      init(opens: Opens) { self.opens = opens }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        opens.record()
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "universal", commitment: ""),
            makeEngine: { CountingEngine(opens: opens) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where opens.count < 1 { await Task.yield() }
    #expect(opens.count == 1, "control: a preview runs before removal")
    coordinator.setRecording(false)

    await coordinator.releaseAndDrainForRemoval()

    coordinator.setRecording(true)
    for _ in 0..<300 { await Task.yield() }
    #expect(opens.count == 1, "a preview started while the files were being removed")

    // And once removal ends, previews work again — otherwise this passes against
    // a feature that is simply broken from then on.
    coordinator.setRecording(false)
    coordinator.endRemovalSuppression()
    coordinator.setRecording(true)
    for _ in 0..<2000 where opens.count < 2 { await Task.yield() }
    #expect(opens.count == 2, "previews must resume once removal has finished")
  }

  // MARK: - #2123 G1: the outcome metric

  /// The event has to name the engine that ACTUALLY ran, and carry nothing else.
  ///
  /// A refusal produces no candidate, so the engine name comes from the route —
  /// which is why routes carry an id at all. And "blocked" is the outcome that
  /// matters most for the downloadable engine, since not-installed is its
  /// commonest refusal: an event that could not name the engine there would fail
  /// to answer the one question it exists for.
  ///
  /// The property COUNT is asserted, not just the values. An event that starts
  /// carrying a refusal reason, a language, or anything else about what the user
  /// was doing must fail this.
  @Test("a refused preview reports which engine refused, and nothing more")
  func blockedOutcomeNamesTheEngine() async throws {
    let waiter = TelemetryEventWaiter()
    TelemetryService.shared.testEventHook = { @Sendable event in
      MainActor.assumeIsolated { waiter.record(event) }
    }
    defer { TelemetryService.shared.testEventHook = nil }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: {
        LivePreviewEngineRoute(
          telemetryEngineID: "universal",
          isSupportedOnThisSystem: { true },
          resolve: { _ in .blocked(.modelNotInstalled) })
      }
    )

    coordinator.setRecording(true)
    let event = try await waiter.waitForEvent(named: "live_preview.outcome")

    // The CLOSED value, not the candidate key's `whisper_preview#<digest>`: a
    // per-revision engine string would be a high-cardinality property rather
    // than a dimension anyone can group by.
    #expect(event.stringProps["engine"] == "universal")
    #expect(event.stringProps["outcome"] == "blocked")
    #expect(
      event.stringProps.count == 2,
      "the event grew a property: \(event.stringProps.keys.sorted())")
  }

  /// A preview that RUNS reports started, exactly once, with the closed engine
  /// value. Testing only the refusal left three of four call sites unprotected —
  /// a mutation at any of them stayed green.
  @Test("a running preview reports started exactly once")
  func startedOutcomeIsReportedOnce() async throws {
    let waiter = TelemetryEventWaiter()
    TelemetryService.shared.testEventHook = { @Sendable event in
      MainActor.assumeIsolated { waiter.record(event) }
    }
    defer { TelemetryService.shared.testEventHook = nil }

    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "whisper_preview#abc123", commitment: ""),
            makeEngine: { ReadyEngine() }))
      }
    )

    coordinator.setRecording(true)
    let event = try await waiter.waitForEvent(named: "live_preview.outcome")
    #expect(event.stringProps["outcome"] == "started")
    // The candidate key here deliberately CARRIES a digest. The event must not.
    #expect(
      event.stringProps["engine"] == "universal",
      "the artifact identity leaked into the engine field")

    // **"Once" has to be ASSERTED.** Waiting for the first event proves one
    // arrived, not that a second did not — the name claimed a property the test
    // did not check, which is the shape of a test that reads as stronger than it is.
    for _ in 0..<300 { await Task.yield() }
    let outcomes = waiter.events.filter { $0.name == "live_preview.outcome" }
    #expect(outcomes.count == 1, "expected exactly one outcome, got \(outcomes.count)")
  }

  /// A session abandoned WHILE OPENING must report nothing at all.
  ///
  /// `openSession` suspends. If the recording ends in that window the session is
  /// torn down immediately and the user never saw a preview, so counting it as
  /// `started` would inflate the metric with previews that did not happen.
  ///
  /// Mutation control: remove the `isCurrent` guard around the `started` report
  /// and this fails on a non-zero count.
  @Test("a preview abandoned while opening reports nothing")
  func staleOpenReportsNothing() async throws {
    let waiter = TelemetryEventWaiter()
    TelemetryService.shared.testEventHook = { @Sendable event in
      MainActor.assumeIsolated { waiter.record(event) }
    }
    defer { TelemetryService.shared.testEventHook = nil }

    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiterC: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private var entered = false
      var hasEntered: Bool { mutex.withLock { entered } }
      func wait() async {
        mutex.withLock { entered = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let open: Bool = mutex.withLock {
            if isOpen { return true }
            waiterC = c
            return false
          }
          if open { c.resume() }
        }
      }
      func open() {
        let w: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiterC
          waiterC = nil
          return w
        }
        w?.resume()
      }
    }
    let opening = Gate()

    final class SlowOpenEngine: LivePreviewEngine, @unchecked Sendable {
      let gate: Gate
      init(gate: Gate) { self.gate = gate }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        await gate.wait()
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "whisper_preview#abc123", commitment: ""),
            makeEngine: { SlowOpenEngine(gate: opening) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !opening.hasEntered { await Task.yield() }
    #expect(opening.hasEntered, "control: the open must be in flight")

    // The recording ends while the open is still suspended.
    coordinator.setRecording(false)
    opening.open()
    for _ in 0..<500 { await Task.yield() }

    let outcomes = waiter.events.filter { $0.name == "live_preview.outcome" }
    #expect(
      outcomes.isEmpty,
      "a preview the user never saw was counted: \(outcomes.map { $0.stringProps })")
  }

  /// An engine that cannot prepare reports `prepare_failed` rather than nothing.
  @Test("a preview that cannot prepare reports prepare_failed")
  func prepareFailureIsReported() async throws {
    let waiter = TelemetryEventWaiter()
    TelemetryService.shared.testEventHook = { @Sendable event in
      MainActor.assumeIsolated { waiter.record(event) }
    }
    defer { TelemetryService.shared.testEventHook = nil }

    struct Boom: Error {}
    final class FailingEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws { throw Boom() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        throw Boom()
      }
    }
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "whisper_preview#abc123", commitment: ""),
            makeEngine: { FailingEngine() }))
      }
    )

    coordinator.setRecording(true)
    let event = try await waiter.waitForEvent(named: "live_preview.outcome")
    #expect(event.stringProps["outcome"] == "prepare_failed")
    #expect(event.stringProps["engine"] == "universal")
  }

  /// An engine that prepares but cannot open a session reports `open_failed` —
  /// a different outcome from failing to prepare, because they send you to
  /// different places when the graph moves.
  @Test("a preview that cannot open a session reports open_failed")
  func openFailureIsReported() async throws {
    let waiter = TelemetryEventWaiter()
    TelemetryService.shared.testEventHook = { @Sendable event in
      MainActor.assumeIsolated { waiter.record(event) }
    }
    defer { TelemetryService.shared.testEventHook = nil }

    struct Boom: Error {}
    final class OpenFailsEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        throw Boom()
      }
    }
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "whisper_preview#abc123", commitment: ""),
            makeEngine: { OpenFailsEngine() }))
      }
    )

    coordinator.setRecording(true)
    let event = try await waiter.waitForEvent(named: "live_preview.outcome")
    #expect(event.stringProps["outcome"] == "open_failed")
    #expect(event.stringProps["engine"] == "universal")
  }

  // MARK: - #2123: one engine decision per recording

  /// The selection itself: which route serves which choice, and what happens when
  /// the universal one could not be composed at all.
  ///
  /// A pure function on purpose — this is the one decision that must never
  /// silently substitute one engine for another, and burying it in the
  /// installer's closure would make it reachable only through a window, an audio
  /// capture and a delivery home.
  @Test("the chosen engine is the one that answers, and a missing one never becomes Apple")
  func routeSelectionNeverSubstitutesApple() async {
    let apple = LivePreviewEngineRoute(
      telemetryEngineID: "apple",
      isSupportedOnThisSystem: { true },
      resolve: { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "apple", commitment: "en"),
            makeEngine: { fatalError("not built in this test") }))
      })
    let universal = LivePreviewEngineRoute(
      telemetryEngineID: "universal",
      isSupportedOnThisSystem: { true },
      resolve: { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "universal", commitment: ""),
            makeEngine: { fatalError("not built in this test") }))
      })

    func engineID(_ route: LivePreviewEngineRoute) async -> String? {
      if case .ready(let candidate) = await route.resolve(.locked("en")) {
        return candidate.key.engine
      }
      return nil
    }
    func refusal(_ route: LivePreviewEngineRoute) async -> LivePreviewUnavailability? {
      if case .blocked(let reason) = await route.resolve(.locked("en")) { return reason }
      return nil
    }

    // Each choice reaches its OWN engine. The second half is the control: without
    // it, a selector hardwired to Apple passes the first assertion.
    let appleChoice = LivePreviewInstaller.route(for: .apple, apple: apple, universal: universal)
    let universalChoice = LivePreviewInstaller.route(
      for: .universal, apple: apple, universal: universal)
    #expect(await engineID(appleChoice) == "apple")
    #expect(await engineID(universalChoice) == "universal")

    // The build defect: universal chosen, universal not composable.
    let broken = LivePreviewInstaller.route(for: .universal, apple: apple, universal: nil)
    #expect(
      await engineID(broken) != "apple",
      "a missing universal engine silently ran Apple under a universal selection")
    #expect(
      await refusal(broken) == .engineUnavailableInThisBuild,
      "the build defect must say so rather than borrowing another engine's refusal")
    #expect(
      broken.isSupportedOnThisSystem(),
      "reporting unsupported would make the pill go quietly blank instead of saying why")
  }


  /// Switching engines releases the one being switched away from — while the
  /// preview is still ON, which is what makes this a separate entry point from
  /// the disabled path rather than a second caller of it.
  @Test("switching engines releases the engine switched away from")
  func switchingEnginesReleases() async {
    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "apple", commitment: "en"),
            makeEngine: { ReadyEngine() }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    #expect(coordinator.hasPreparedEngineForTests, "control: an engine must be cached first")

    // The user picks the other engine. The preview stays ON throughout.
    coordinator.releaseForEngineChange()
    #expect(!coordinator.hasPreparedEngineForTests, "the old engine's model must be released")
    #expect(coordinator.display == .off)
  }

  /// The engine-change release must NOT inherit the disabled path's guard.
  ///
  /// `releaseForDisabledSetting` returns early while the preview is on — correct
  /// for its own trigger, and fatal here: switching engines happens with the
  /// preview on by definition, so a shared guard would make this a no-op and the
  /// old model would stay resident for the rest of the session.
  @Test("the engine-change release fires even though the preview is still on")
  func engineChangeIsNotGuardedByTheToggle() async {
    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "apple", commitment: "en"),
            makeEngine: { ReadyEngine() }))
      }
    )
    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    #expect(coordinator.hasPreparedEngineForTests, "control: cached before the switch")

    // CONTROL: the disabled path is a no-op here, precisely because the preview
    // is on. If both behaved the same, the test below would prove nothing.
    coordinator.releaseForDisabledSetting()
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the disabled path must NOT release while the preview is on")

    coordinator.releaseForEngineChange()
    #expect(!coordinator.hasPreparedEngineForTests, "the engine-change path must release")
  }

  /// An IDLE switch — the commonest one, since a user changes engines in Settings
  /// between recordings, not during one. The mid-recording tests above say
  /// nothing about it: `isRunning` is false, so they exercise a different branch.
  @Test("switching engines while idle releases an engine cached by an earlier recording")
  func idleSwitchReleasesTheCachedEngine() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(probe: probe, key: key("apple", "en-US"))

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 }, "control: a session must have opened")
    coordinator.setRecording(false)
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the engine stays cached across recordings — that is why it needs releasing")

    coordinator.releaseForEngineChange()
    #expect(
      !coordinator.hasPreparedEngineForTests,
      "an idle engine switch left the previous engine's model cached")
  }

  /// **Teardown must COMPLETE, not merely be requested.**
  ///
  /// Clearing the cached slot and the display is what the eye sees; it is not
  /// what frees the model. A version of `releaseForEngineChange` that did only
  /// that — leaving the live session feeding and decoding — passes every other
  /// switch test here, which is exactly why this one counts ended sessions
  /// through the probe rather than reading `display`.
  @Test("switching engines mid-recording ends the live session, not just the cache")
  func switchingEndsTheLiveSession() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(
      probe: probe,
      key: key("apple", "en-US"),
      readSamples: { index in
        index == Int.max ? ([], 0) : (Array(repeating: Float(0.05), count: 160), 160)
      })

    coordinator.setRecording(true)
    #expect(await reach { await probe.samplesFed > 0 }, "control: the session must be live")
    #expect(await probe.sessionsEnded == 0, "control: nothing has ended yet")

    coordinator.releaseForEngineChange()

    #expect(
      await reach { await probe.sessionsEnded == 1 },
      "the switch cleared the cache but left the session running")
    #expect(await probe.sessionsEnded == 1, "and ended it exactly once")
  }

  /// Switching mid-recording must not start the NEW engine inside the recording
  /// that was already under way — the snapshot is what suppresses it, so this
  /// asserts the two behaviours are wired to one rule and not two.
  @Test("switching mid-recording does not start the new engine until the next recording")
  func switchingMidRecordingDoesNotRestart() async {
    final class Opens: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = 0
      var count: Int { mutex.withLock { value } }
      func record() { mutex.withLock { value += 1 } }
    }
    let opens = Opens()
    final class CountingEngine: LivePreviewEngine, @unchecked Sendable {
      let opens: Opens
      init(opens: Opens) { self.opens = opens }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        opens.record()
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "apple", commitment: "en"),
            makeEngine: { CountingEngine(opens: opens) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where opens.count < 1 { await Task.yield() }
    #expect(opens.count == 1, "control: the first session opened")

    coordinator.releaseForEngineChange()
    coordinator.setRecording(true)  // the overlay's duplicate intent push
    for _ in 0..<300 { await Task.yield() }
    #expect(opens.count == 1, "the new engine started inside the old recording")

    // Next recording: it does start, so this is suppression and not breakage.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    for _ in 0..<2000 where opens.count < 2 { await Task.yield() }
    #expect(opens.count == 2, "the next recording must use the newly chosen engine")
  }


  /// The pill's SIZE and the words in it must never disagree about the engine.
  ///
  /// Freezing only at the moment intent arrives is not enough on its own: the
  /// overlay reports intent synchronously but creates its panel on the next
  /// run-loop cycle and reads geometry inside that deferred work. So a switch
  /// landing in that gap must change neither half.
  ///
  /// Mutation control: read `selectedRoute()` live in `runSession` instead of the
  /// snapshot and this goes red on the engine identity.
  @Test("the engine chosen at the start of a recording is the one it uses throughout")
  func engineIsFrozenForTheRecording() async {
    final class Choice: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = "first"
      var current: String { mutex.withLock { value } }
      func switchIt() { mutex.withLock { value = "second" } }
    }
    final class Seen: @unchecked Sendable {
      private let mutex = NSLock()
      private var ids: [String] = []
      var all: [String] { mutex.withLock { ids } }
      func record(_ id: String) { mutex.withLock { ids.append(id) } }
    }
    let choice = Choice()
    let seen = Seen()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: {
        // A DIFFERENT route object each read, exactly as the real provider will
        // behave once it switches on a setting.
        let id = choice.current
        return LivePreviewEngineRoute(
          telemetryEngineID: "universal",
          isSupportedOnThisSystem: { true },
          resolve: { _ in
            seen.record(id)
            return .blocked(.unsupportedLanguage)
          })
      }
    )

    coordinator.setRecording(true)
    // Switch the choice immediately — before the session task has resolved.
    choice.switchIt()
    for _ in 0..<2000 where seen.all.isEmpty { await Task.yield() }

    #expect(seen.all.first == "first", "control: the recording must have resolved something")
    #expect(
      !seen.all.contains("second"),
      "the recording resolved the engine chosen after it started: \(seen.all)")

    // The NEXT recording gets the new choice — the freeze is per recording, not
    // permanent.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    for _ in 0..<2000 where !seen.all.contains("second") { await Task.yield() }
    #expect(seen.all.contains("second"), "a new recording must pick up the new choice")
  }

  /// A recording that began with the preview OFF stays off for its whole length.
  ///
  /// The overlay deliberately forwards duplicate intent pushes, and the disabled
  /// path never sets `isRunning` — so without the snapshot guard, enabling the
  /// preview mid-recording plus one duplicate push would start a preview in a
  /// recording that never began with one.
  @Test("enabling mid-recording cannot start a preview the recording began without")
  func enablingMidRecordingDoesNotStartIt() async {
    final class Toggle: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = false
      var isOn: Bool { mutex.withLock { value } }
      func turnOn() { mutex.withLock { value = true } }
    }
    final class Resolved: @unchecked Sendable {
      private let mutex = NSLock()
      private var count = 0
      var value: Int { mutex.withLock { count } }
      func bump() { mutex.withLock { count += 1 } }
    }
    let toggle = Toggle()
    let resolved = Resolved()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { toggle.isOn },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        resolved.bump()
        return .blocked(.unsupportedLanguage)
      }
    )

    coordinator.setRecording(true)  // begins OFF
    #expect(coordinator.display == .off, "control: it must start off")
    #expect(!coordinator.isEnabledForGeometry, "control: geometry must agree it is off")

    toggle.turnOn()
    coordinator.setRecording(true)  // the overlay's duplicate push
    for _ in 0..<300 { await Task.yield() }

    #expect(resolved.value == 0, "a preview started inside a recording that began without one")
    #expect(!coordinator.isEnabledForGeometry, "geometry must stay off for this recording")

    // And the next recording, begun with it on, DOES run — otherwise this test
    // would pass against a preview that never starts at all.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    for _ in 0..<2000 where resolved.value == 0 { await Task.yield() }
    #expect(resolved.value == 1, "the next recording must honour the new setting")
  }

  // MARK: - The gate

  @Test("Disabled: the preview stays off and never reads the audio buffer")
  func disabledNeverTouchesAudio() async {
    let capture = CountingAudioCapture()
    let coordinator = LivePreviewCoordinator(
      readSamples: { await capture.getSamplesSnapshot(fromIndex: $0) },
      isPreviewOn: { false },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )

    coordinator.setRecording(true)
    #expect(coordinator.display == .off)

    // This asserts a NEGATIVE (no feed loop was started), and there is no signal
    // to wait on for something that must never happen. The paired
    // `enabledStartsAndLeavesOff` test is the control proving the start path
    // works, so a vacuous pass here would be caught there.
    // settle: proving absence; a started loop polls every 100 ms so it could not hide inside this window
    try? await Task.sleep(for: .milliseconds(250))
    #expect(
      capture.snapshotCallCount == 0,
      "a disabled preview must not read captured audio at all")
    #expect(coordinator.display == .off)
  }

  /// The two-way control for the test above. Without it, `disabledNeverTouchesAudio`
  /// would pass just as happily against a coordinator whose start path was broken
  /// or deleted, which is the shape of a vacuous guard test.
  @Test("Enabled: the start path runs and the pill leaves the off state")
  func enabledStartsAndLeavesOff() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )

    coordinator.setRecording(true)
    // Set synchronously by `setRecording`, before any async work, so this holds on
    // every macOS version including ones where the recognizer cannot exist.
    #expect(coordinator.display == .waiting)
  }

  @Test("A new recording never opens showing the previous one's words")
  func startClearsPreviousText() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    // Stopping DISCARDS. This assertion used to read `.waiting`, which was
    // incidental to the old behaviour of keeping the last text until the next
    // recording. The settings copy now tells the user the preview is discarded
    // when the recording ends, so this is the contract that sentence depends on.
    #expect(coordinator.display == .off, "stopping must release the preview text")

    coordinator.setRecording(true)
    #expect(
      coordinator.display == .waiting,
      "the next press must reset the pill before its panel is created")
  }

  @Test("Stop is safe before any start, and start is safe twice")
  func lifecycleIsIdempotent() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )
    // Two call sites push recording intent (the first overlay push and every
    // state-driven one), and `hide()` reports a stop that may already have
    // happened. All the orders below occur in practice.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    coordinator.setRecording(false)
    // Settles OFF, and a redundant second stop does not disturb that. This read
    // `!= .off` when a stop left the last text in place; the discard makes the
    // stronger statement available, so assert the exact state rather than the
    // absence of one.
    #expect(coordinator.display == .off)
  }

  /// The claim in the settings description, asserted directly rather than as a
  /// side effect of another test: a user reads "discarded when the recording
  /// ends" before deciding to switch this on, so the discard is a contract, not
  /// an implementation detail that may drift.
  @Test("Stopping discards the preview text, matching what the setting promises")
  func stopDiscardsPreviewText() {
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )
    coordinator.setRecording(true)
    #expect(coordinator.display != .off, "control: a live recording is not off")

    coordinator.setRecording(false)
    #expect(coordinator.display == .off)
    #expect(
      LivePreviewSettingsCopy.toggleDescription.contains("discarded"),
      "if this sentence goes, the assertion above stops being the promise it pins")
  }

  // MARK: - Language policy
  //
  // This policy belongs to APPLE'S engine, not to the preview feature, which is why
  // these assert against `ApplePreviewEngineResolver`. Apple cannot detect language,
  // so it has to be told one before it hears anything and Auto has to become a
  // guess. An engine that detects language itself must not inherit that guess.

  @Test("A locked language previews in that language; Auto follows the system")
  func languagePolicy() {
    #expect(ApplePreviewEngineResolver.languageCode(for: .locked("de")) == "de")
    let auto = ApplePreviewEngineResolver.languageCode(for: .auto)
    #expect(auto == Locale.current.identifier(.bcp47))
    #expect(auto.isEmpty == false)
  }

  /// Auto must keep REGION and SCRIPT, not just language. Reducing to the language
  /// code sends a Traditional Chinese Mac to the Simplified model, Brazilian
  /// Portuguese to European, and Canadian French to Swiss — measured against
  /// Apple's real resolver, not inferred. This asserts the property that prevents
  /// it, on a fixed locale rather than the machine's, so it means the same thing
  /// on every runner.
  @Test("Auto preserves region and script, which is what picks the right model")
  func autoPreservesRegionAndScript() {
    // The reduction that caused it, applied to the cases it breaks. If
    // `ApplePreviewEngineResolver.languageCode(for: .auto)` ever goes back to a
    // bare language code, these are the users who silently get another region's
    // model.
    for id in ["zh-TW", "pt-BR", "fr-CA", "en-GB"] {
      let full = Locale(identifier: id)
      let bare = full.language.languageCode?.identifier
      #expect(
        full.identifier(.bcp47) != bare,
        "\(id) must not survive as a bare language code")
    }
  }

  // MARK: - The engine seam (#2077)
  //
  // None of these could be written before the seam existed. Driving the coordinator
  // meant driving Apple's recognizer, which needs macOS 26, a reserved locale and
  // possibly a model download — so the parts below were covered only by hand.
  //
  // Every wait here is on a SIGNAL the coordinator produces, with a deadline as the
  // fallback. A fixed sleep would encode this machine's speed into the assertion.

  @Test("Preparation is paid once, not on every recording")
  func preparationIsCachedAcrossRecordings() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(probe: probe, key: key("apple", "en-US"))

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 }, "first session never opened")
    coordinator.setRecording(false)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 2 }, "second session never opened")
    coordinator.setRecording(false)

    #expect(
      await probe.prepareCalls == 1,
      "a second press must reuse the prepared engine, not prepare again")
  }

  /// The reason the cache key carries the ENGINE as well as the language. A user
  /// switching engines must not keep talking to the previous one.
  @Test("A different engine key prepares again rather than reusing the old engine")
  func changingTheKeyRebuilds() async {
    let probe = PreviewEngineProbe()
    let keys = [key("apple", "en-US"), key("universal", "")]
    let resolutions = CountingBox()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        let nth = await resolutions.next()
        return .ready(
          LivePreviewEngineCandidate(
            key: keys[min(nth, keys.count - 1)],
            makeEngine: { FakePreviewEngine(probe: probe) }))
      }
    )

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 })
    coordinator.setRecording(false)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 2 })
    coordinator.setRecording(false)

    #expect(await probe.prepareCalls == 2, "a changed engine key must prepare the new engine")
  }

  @Test("Captured audio reaches the session, and stopping ends it exactly once")
  func audioReachesTheSessionAndStopEndsIt() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(
      probe: probe,
      key: key("apple", "en-US"),
      // A growing buffer, as a real recording looks from the read side.
      readSamples: { index in
        index == Int.max ? ([], 0) : (Array(repeating: Float(0.05), count: 160), 160)
      })

    coordinator.setRecording(true)
    #expect(await reach { await probe.samplesFed > 0 }, "the session received no audio")
    coordinator.setRecording(false)

    #expect(
      await reach { await probe.sessionsEnded == 1 },
      "every session must be ended, or the engine leaks its analyzer and model")
    #expect(await probe.sessionsEnded == 1, "and ended exactly once")
  }

  /// A blocked engine must cost nothing. This is the limb rule applied to the
  /// refusal path: if we cannot preview, we must not be reading audio anyway.
  @Test("A blocked engine reports its reason and never reads audio")
  func blockedEngineNeverReadsAudio() async {
    let reads = CountingBox()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in
        await reads.bump()
        return ([], 0)
      },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedLanguage) }
    )

    coordinator.setRecording(true)
    // The reason landing IS the signal that resolution finished, so this waits on
    // the outcome rather than on a duration.
    #expect(
      await reach { coordinator.display == .unavailable(LivePreviewCopy.languageUnsupported) },
      "a blocked engine must say why")
    #expect(await reads.value == 0, "a blocked preview must not read captured audio")
  }

  /// #1988's acceptance criterion, now assertable end to end: the user's own words
  /// reach the engine that renders them, rather than being applied somewhere later.
  @Test("Custom Words reach the session that will display the text")
  func customWordsReachTheSession() async {
    let probe = PreviewEngineProbe()
    let coordinator = makeCoordinator(probe: probe, key: key("apple", "en-US"))
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)

    coordinator.setRecording(true)
    #expect(await reach { await probe.sessionsOpened == 1 })
    coordinator.setRecording(false)

    #expect(
      await probe.sawNonNilLookups,
      "the session must open with the vocabulary snapshot, not without it")
  }

  /// Poll a signal until it holds, bounded by a deadline.
  ///
  /// The deadline is a failure bound, never the thing being measured: a correct
  /// implementation returns on the first poll that observes the signal, so a slow
  /// runner costs a few more polls rather than a false failure.
  /// `@MainActor` on the condition, deliberately: the coordinator's `display` is
  /// main-actor state and the whole point is to read it, so a nonisolated closure
  /// would force every caller to hop by hand.
  private func reach(
    within timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      // settle: poll interval inside a signal wait; the deadline above is the real bound
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  private func key(_ engine: String, _ commitment: String) -> LivePreviewEngineKey {
    LivePreviewEngineKey(engine: engine, commitment: commitment)
  }

  private func makeCoordinator(
    probe: PreviewEngineProbe,
    key: LivePreviewEngineKey,
    readSamples: @escaping LivePreviewSampleReader = { _ in ([], 0) }
  ) -> LivePreviewCoordinator {
    LivePreviewCoordinator(
      readSamples: readSamples,
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: key, makeEngine: { FakePreviewEngine(probe: probe) }))
      }
    )
  }

  // MARK: - Bounding

  @Test("Short text is returned untouched")
  func shortTextUnbounded() {
    let text = "the quick brown fox"
    #expect(LivePreviewTextBound.apply(text) == text)
  }

  @Test("Long text keeps the tail, drops the head, and does not cut a word in half")
  func longTextKeepsTail() {
    // The pill shows the newest words, so the END is the part that must survive.
    let long = String(repeating: "alpha ", count: 1000)  // 6000 characters
    let bounded = LivePreviewTextBound.apply(long)

    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(bounded.isEmpty == false)
    #expect(long.hasSuffix(bounded), "the retained text must be a suffix of the original")
    #expect(
      bounded.hasPrefix("alpha"),
      "trimming must land on a word boundary, not mid-word")
  }

  @Test("Bounding a string with no spaces still bounds it")
  func boundingWithoutWordBoundaries() {
    // A CJK sentence carries no spaces, and neither does a pathological URL. The
    // word-boundary step must not be able to turn the bound off.
    let long = String(repeating: "語", count: 5000)
    let bounded = LivePreviewTextBound.apply(long)
    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(long.hasSuffix(bounded))
  }

  /// The bound is idempotent, which is what lets the producer apply it on every
  /// update without the text creeping.
  @Test("Applying the bound twice changes nothing the second time")
  func boundIsIdempotent() {
    let long = String(repeating: "alpha ", count: 1000)
    let once = LivePreviewTextBound.apply(long)
    #expect(LivePreviewTextBound.apply(once) == once)
  }

  // MARK: - Shipped default

  @Test("Live preview ships off")
  func shipsOff() {
    // Off by default is the founder-approved shipped state: it costs screen
    // attention some users explicitly asked to be able to decline, and it needs
    // macOS 26, so on by default would read as broken on every older Mac.
    #expect(SettingsDefaultValues.livePreviewEnabled == false)
  }

  // MARK: - Custom Words on preview text (#1988 acceptance)

  private func makeCoordinator() -> LivePreviewCoordinator {
    LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in .blocked(.unsupportedSystem) }
    )
  }

  private func word(_ canonical: String) -> CustomWord {
    CustomWord(canonical: canonical)
  }

  /// **The seed arrives at generation 0, and so does the property's initial
  /// `.empty`.** Comparing an incoming generation against the PREVIOUS VALUE's
  /// would therefore treat a real vocabulary arriving at launch as an unchanged
  /// one and silently drop it, so Custom Words would reach the preview only after
  /// the user edited them — never, for anyone whose words were already saved.
  /// This is the exact collision, written as the case most likely to regress.
  @Test("A vocabulary seeded at generation 0 is picked up, not mistaken for empty")
  func generationZeroSeedIsNotDropped() {
    let coordinator = makeCoordinator()
    #expect(coordinator.correctorLookupBuilds == 0)
    #expect(coordinator.hasCorrectorLookupsForTesting == false)

    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 0)

    #expect(coordinator.correctorLookupBuilds == 1)
    #expect(
      coordinator.hasCorrectorLookupsForTesting,
      "a generation-0 seed carrying real terms must build lookups")
  }

  @Test("A new generation rebuilds; the same generation does not")
  func rebuildsOnlyOnGenerationChange() {
    let coordinator = makeCoordinator()
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)
    #expect(coordinator.correctorLookupBuilds == 1)

    // Same generation, different terms: the generation IS the identity, so this
    // must not rebuild. Building here would mean the cache key is not doing its
    // job and every settings write pays a full lookup build.
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics"), word("EnviousWispr")], generation: 1)
    #expect(coordinator.correctorLookupBuilds == 1)

    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics"), word("EnviousWispr")], generation: 2)
    #expect(coordinator.correctorLookupBuilds == 2)
  }

  /// An empty vocabulary stores `nil` rather than empty lookups, so the
  /// recognizer's guard short-circuits instead of running a correction pass that
  /// cannot match anything. Most users have no custom words, so this is the
  /// common path, not an edge case.
  @Test("Clearing the vocabulary drops the snapshot rather than keeping empty lookups")
  func emptyVocabularyStoresNoLookups() {
    let coordinator = makeCoordinator()
    coordinator.correctorVocabulary = CorrectorVocabulary(
      terms: [word("Qualtrics")], generation: 1)
    #expect(coordinator.hasCorrectorLookupsForTesting)

    coordinator.correctorVocabulary = CorrectorVocabulary(terms: [], generation: 2)
    #expect(coordinator.correctorLookupBuilds == 2)
    #expect(coordinator.hasCorrectorLookupsForTesting == false)
  }

  /// The correction the preview applies is the SAME function the pasted text goes
  /// through, so this pins the behaviour the acceptance criterion is about: a
  /// user's own name, misheard by Apple's recognizer, is repaired before display.
  @Test("The corrector repairs a custom term the way the preview will")
  func correctorRepairsACustomTerm() {
    let lookups = WordCorrector.buildLookups(words: [word("Qualtrics")])
    let corrected = WordCorrector().correct("i work at qualtrix today", using: lookups).corrected
    #expect(corrected.contains("Qualtrics"), "got: \(corrected)")
  }

  // MARK: - #2108: the prepared engine is released when preview is disabled

  /// The universal engine holds a loaded WhisperKit model, so the cached-engine
  /// slot now pins roughly 50-60 MB. It is otherwise cleared only when the
  /// candidate KEY changes, and turning the preview off changes no key — so an
  /// engine prepared before the user disabled it stayed cached for the life of
  /// the process. Cloud review caught it on #2113.
  ///
  /// Asserts the SLOT, not a weak reference to the engine. An earlier version did
  /// the latter and failed three times for three different reasons — the
  /// preparation task, then the draining session task, each holding the engine as
  /// a local. A weak-reference assertion cannot distinguish "the slot is still
  /// full" from "the observation was early", which makes it the wrong instrument
  /// for the property this fix changes.
  /// **The axis my own enumeration missed.**
  ///
  /// I swept WHICH entry points release the engine and closed all of them, but
  /// not WHEN — specifically, releasing while a recording is still running.
  /// Switching the preview off mid-dictation cleared the cache and left the
  /// session alive: still holding the model, still decoding, and still able to
  /// repaint over `.off` through a later `onText`. The worst version of the leak,
  /// because it is the visible one. Cloud review found the axis.
  @Test("disabling MID-RECORDING tears down the live session, not just the cache")
  func disablingMidRecordingTearsDownTheSession() async {
    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable { var enabled = true }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReadyEngine() }))
      }
    )

    // Start and leave the recording RUNNING — this is the whole point.
    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: an engine must be cached while the recording runs")
    #expect(coordinator.display != .off, "control: a live recording is not off")

    // The user turns the preview off WITHOUT stopping the recording.
    box.enabled = false
    coordinator.releaseForDisabledSetting()

    #expect(!coordinator.hasPreparedEngineForTests, "the cached engine must go")
    #expect(coordinator.display == .off, "and the pill must be off")

    // And it must STAY off: a session left running could repaint after the
    // disable. Stopping afterwards must also be safe rather than double-tearing.
    for _ in 0..<200 { await Task.yield() }
    #expect(coordinator.display == .off, "a torn-down session cannot repaint over off")
    coordinator.setRecording(false)
    #expect(coordinator.display == .off)
  }

  /// **The fourth axis, found by Codex validating my own enumeration rather than
  /// by another review round.** Three rounds swept WHICH entry point releases and
  /// WHEN it fires. All of them CANCELLED the session task and moved on — and a
  /// cancelled task still owns its engine and its session until it reaches
  /// `session.end()`. So the next recording could open a second session over the
  /// same cached WhisperKit instance while the previous one was still inside its
  /// final decode: the exact corruption the turnover lock and the joinable
  /// `end()` exist to prevent, reached from a layer above both.
  ///
  /// Mutation control: drop `drainingTeardown` and the second session opens
  /// immediately, so the mid-test assertion goes red.
  @Test("a new preview waits for the previous one to finish tearing down")
  func newSessionWaitsForThePreviousTeardown() async {
    /// Blocks `end()` until the test opens it. A continuation rather than a
    /// polled flag: `end()` runs inside a CANCELLED task, where `Task.sleep` and
    /// `Task.yield` both return immediately, so a poll would spin the main actor
    /// instead of waiting on it.
    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let alreadyOpen: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if alreadyOpen { c.resume() }
        }
      }
      func open() {
        let waiting: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        waiting?.resume()
      }
    }
    final class Opens: @unchecked Sendable {
      private let mutex = NSLock()
      private var value = 0
      var count: Int { mutex.withLock { value } }
      func record() { mutex.withLock { value += 1 } }
    }

    let gate = Gate()
    let opens = Opens()
    final class GatedEngine: LivePreviewEngine, @unchecked Sendable {
      let gate: Gate
      let opens: Opens
      init(gate: Gate, opens: Opens) {
        self.gate = gate
        self.opens = opens
      }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        opens.record()
        struct Gated: LivePreviewEngineSession {
          let gate: Gate
          func feed(_ samples: [Float]) async {}
          func end() async { await gate.wait() }
        }
        return Gated(gate: gate)
      }
    }
    final class Box: @unchecked Sendable { var enabled = true }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { GatedEngine(gate: gate, opens: opens) }))
      }
    )

    coordinator.setRecording(true)
    // Wait for the session to be REGISTERED, not merely opened. The full suite
    // caught the difference: waiting on `opens` alone can act inside the window
    // between `openSession` returning and the coordinator registering its
    // teardown, and this layer makes no promise there — the adapter's turnover
    // lock is what covers that window, because it records its handle before it
    // releases. Isolated runs passed; the loaded run did not.
    for _ in 0..<2000 where !coordinator.hasLiveSessionForTests { await Task.yield() }
    #expect(opens.count == 1, "control: the first session must have opened")
    #expect(
      coordinator.hasLiveSessionForTests,
      "control: the coordinator must have registered that session's teardown")

    // Turn the preview off mid-recording. The session task is cancelled and is
    // now sitting inside `end()`, still holding the engine.
    box.enabled = false
    coordinator.releaseForDisabledSetting()

    // Turn it back on and start another RECORDING immediately. #2123: the
    // recording has to end first, because a decision is frozen per recording and
    // a second preview belongs to a second recording.
    coordinator.setRecording(false)
    box.enabled = true
    coordinator.setRecording(true)
    for _ in 0..<200 { await Task.yield() }
    #expect(
      opens.count == 1,
      "a second session opened while the first was still tearing down")

    // Once teardown completes, the new session must actually open — otherwise
    // this test would pass just as well against a preview that never runs again.
    gate.open()
    for _ in 0..<2000 where opens.count < 2 { await Task.yield() }
    #expect(opens.count == 2, "the new session must open once the old one has drained")
  }

  /// The confirming round's own finding: a drain that waits for the WRONG unit
  /// wedges the feature it was added to protect.
  ///
  /// Model warm-up is an unstructured task on purpose, so a later recording can
  /// adopt it — which means cancelling the session task does NOT interrupt a
  /// preview suspended inside preparation. Draining the whole session task made
  /// every later preview wait on a warm-up that `releasePreparedEngine` had
  /// already invalidated by generation, so one disable/enable over a slow or hung
  /// load would stop previews for the rest of the process.
  ///
  /// Nothing needs draining before a session exists: no session, no decode to
  /// collide with. Mutation control: drain the whole session task instead of the
  /// post-open work and this test hangs at the second wait, then fails.
  @Test("a preview abandoned during preparation does not block the next one")
  func abandonedPreparationDoesNotBlockTheNextPreview() async {
    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let alreadyOpen: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if alreadyOpen { c.resume() }
        }
      }
      func open() {
        let waiting: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        waiting?.resume()
      }
    }
    final class Counts: @unchecked Sendable {
      private let mutex = NSLock()
      private var made = 0
      private var opened = 0
      var enginesMade: Int { mutex.withLock { made } }
      var sessionsOpened: Int { mutex.withLock { opened } }
      func recordEngine() -> Int { mutex.withLock { made += 1; return made } }
      func recordOpen() { mutex.withLock { opened += 1 } }
    }

    let stuck = Gate()
    let counts = Counts()

    /// First engine hangs in `prepare()`; every later one prepares instantly.
    final class MaybeStuckEngine: LivePreviewEngine, @unchecked Sendable {
      let hangs: Bool
      let counts: Counts
      let stuck: Gate
      init(hangs: Bool, counts: Counts, stuck: Gate) {
        self.hangs = hangs
        self.counts = counts
        self.stuck = stuck
      }
      func prepare() async throws {
        if hangs { await stuck.wait() }
      }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        counts.recordOpen()
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable { var enabled = true }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: {
              let ordinal = counts.recordEngine()
              return MaybeStuckEngine(hangs: ordinal == 1, counts: counts, stuck: stuck)
            }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where counts.enginesMade < 1 { await Task.yield() }
    #expect(counts.enginesMade == 1, "control: preparation must have started")
    #expect(counts.sessionsOpened == 0, "control: it must still be stuck in prepare()")

    // Abandon it: the warm-up keeps running because nothing can interrupt it.
    box.enabled = false
    coordinator.releaseForDisabledSetting()

    // The next preview must run, with the first warm-up still hung. #2123: the
    // next preview means the next RECORDING — a recording now freezes its
    // decision at its start, so ending this one is what makes the next one new.
    coordinator.setRecording(false)
    box.enabled = true
    coordinator.setRecording(true)
    for _ in 0..<2000 where counts.sessionsOpened < 1 { await Task.yield() }
    #expect(
      counts.sessionsOpened == 1,
      "the next preview waited on an abandoned warm-up that can never finish")

    // Release the hung warm-up so the test leaves nothing suspended behind it.
    stuck.open()
  }

  /// A session opened for a recording that is already over must not take the
  /// live registration away from the one that IS current.
  ///
  /// The window: disabling the preview while `openSession` is suspended releases
  /// the prepared engine, so the replacement preview builds a DIFFERENT
  /// recognizer with its own turnover lock — the adapter cannot close this from
  /// below. If the stale session registered anyway, finishing would clear the
  /// slot, leaving the current preview unregistered: a later stop could not
  /// cancel its feed loop, and it would keep decoding across later recordings.
  ///
  /// Mutation control: drop the `isCurrent` guard on the registration and the
  /// final assertion goes red, because the stale completion clears the slot.
  @Test("a session opened for an abandoned recording does not steal the registration")
  func staleSessionDoesNotStealTheRegistration() async {
    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let alreadyOpen: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if alreadyOpen { c.resume() }
        }
      }
      func open() {
        let waiting: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        waiting?.resume()
      }
    }
    final class Counts: @unchecked Sendable {
      private let mutex = NSLock()
      private var made = 0
      private var entered = 0
      var enginesMade: Int { mutex.withLock { made } }
      var opensEntered: Int { mutex.withLock { entered } }
      func recordEngine() -> Int { mutex.withLock { made += 1; return made } }
      func enterOpen() { mutex.withLock { entered += 1 } }
    }

    let slowOpen = Gate()
    let counts = Counts()

    /// The first engine hangs INSIDE `openSession`; later ones open instantly.
    final class MaybeSlowEngine: LivePreviewEngine, @unchecked Sendable {
      let hangs: Bool
      let counts: Counts
      let slowOpen: Gate
      init(hangs: Bool, counts: Counts, slowOpen: Gate) {
        self.hangs = hangs
        self.counts = counts
        self.slowOpen = slowOpen
      }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        counts.enterOpen()
        if hangs { await slowOpen.wait() }
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable { var enabled = true }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: {
              let ordinal = counts.recordEngine()
              return MaybeSlowEngine(hangs: ordinal == 1, counts: counts, slowOpen: slowOpen)
            }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where counts.opensEntered < 1 { await Task.yield() }
    #expect(counts.opensEntered == 1, "control: the first open must be in flight")
    #expect(
      !coordinator.hasLiveSessionForTests,
      "control: nothing can be registered while the open is still suspended")

    // Abandon it mid-open, then run a second preview to completion of its open.
    box.enabled = false
    coordinator.releaseForDisabledSetting()
    // #2123: end the recording before starting the next one — a decision is
    // frozen per recording, so a second preview belongs to a second recording.
    coordinator.setRecording(false)
    box.enabled = true
    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasLiveSessionForTests { await Task.yield() }
    #expect(
      coordinator.hasLiveSessionForTests,
      "control: the current preview must be registered before the stale one lands")

    // Now let the abandoned open finish. It must end its own session and leave
    // the current registration alone.
    slowOpen.open()
    for _ in 0..<2000 { await Task.yield() }
    #expect(
      coordinator.hasLiveSessionForTests,
      "a stale session replaced the live registration, leaving the current preview uncancellable")
  }

  /// **Found by enumerating the class, not by review.** Five of this PR's findings
  /// were "the bound is downstream of the growth" and three were "the release
  /// misses a path", so the remaining release paths were swept exhaustively
  /// rather than waiting for the next round.
  ///
  /// This is the path nobody had reached: use the preview once, then turn live
  /// transcription on. Every later recording resolves to `.blocked`, correctly —
  /// and the prepared engine, holding a loaded 217 MB model it can no longer use,
  /// stayed cached for the rest of the session. Invisible on Apple's engine,
  /// which holds a locale.
  @Test("a blocked resolution releases the engine instead of caching a model it cannot use")
  func blockedResolutionReleasesTheEngine() async {
    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable { var blocked = false }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        if box.blocked { return .blocked(.heartIsStreaming) }
        return .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReadyEngine() }))
      }
    )

    // Use it once so an engine is genuinely cached.
    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    coordinator.setRecording(false)
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the slot must be FULL before a blocked resolution can release anything")

    // The user turns live transcription on. The preview is still ENABLED — this
    // is not the disabled path — it simply cannot run.
    box.blocked = true
    coordinator.setRecording(true)
    for _ in 0..<2000 where coordinator.hasPreparedEngineForTests { await Task.yield() }
    coordinator.setRecording(false)

    #expect(
      !coordinator.hasPreparedEngineForTests,
      "a preview that cannot run must not keep a loaded model cached")
  }

  /// The COMMON order, and the one the first fix missed: finish a recording, turn
  /// the preview off, never record again. The release inside `setRecording(true)`
  /// is never reached, so the model stayed resident indefinitely. Cloud review
  /// caught it after the first fix passed a round.
  @Test("turning the setting off releases the engine without needing another recording")
  func disablingTheSettingReleasesWithoutAnotherRecording() async {
    final class ReleasableEngine: LivePreviewEngine, @unchecked Sendable {
      let onPrepared: @Sendable () -> Void
      init(onPrepared: @escaping @Sendable () -> Void) { self.onPrepared = onPrepared }
      func prepare() async throws { onPrepared() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable {
      var enabled = true
      var prepared = false
    }
    let box = Box()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReleasableEngine(onPrepared: { box.prepared = true }) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !box.prepared { await Task.yield() }
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    coordinator.setRecording(false)
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the slot must be FULL, and must SURVIVE a normal stop")

    // The user turns it off. No further recording happens — this is the whole
    // point of the test.
    box.enabled = false
    coordinator.releaseForDisabledSetting()

    #expect(
      !coordinator.hasPreparedEngineForTests,
      "the setting transition alone must release the engine")
  }

  /// The guard on that entry point matters: a spurious call while the preview is
  /// still ENABLED must not throw away a prepared engine and make the next
  /// recording pay preparation again.
  @Test("the setting-change release is a no-op while the preview is still enabled")
  func settingChangeReleaseIsANoOpWhileEnabled() async {
    final class ReadyEngine: LivePreviewEngine, @unchecked Sendable {
      let onPrepared: @Sendable () -> Void
      init(onPrepared: @escaping @Sendable () -> Void) { self.onPrepared = onPrepared }
      func prepare() async throws { onPrepared() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }
    final class Box: @unchecked Sendable { var prepared = false }
    let box = Box()
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReadyEngine(onPrepared: { box.prepared = true }) }))
      }
    )

    coordinator.setRecording(true)
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    coordinator.setRecording(false)
    #expect(coordinator.hasPreparedEngineForTests, "control: the slot must be full")

    coordinator.releaseForDisabledSetting()
    #expect(
      coordinator.hasPreparedEngineForTests,
      "an enabled preview must keep its engine — otherwise every settings change costs a reload")
  }

  @Test("disabling the preview releases the prepared engine, not just the display")
  func disablingReleasesThePreparedEngine() async {
    final class ReleasableEngine: LivePreviewEngine, @unchecked Sendable {
      let onPrepared: @Sendable () -> Void
      init(onPrepared: @escaping @Sendable () -> Void) { self.onPrepared = onPrepared }
      func prepare() async throws { onPrepared() }
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    // Boxed because Swift 6 forbids mutating a captured var from a concurrently
    // executing closure.
    final class Box: @unchecked Sendable {
      var enabled = true
      var prepared = false
    }
    let box = Box()

    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { box.enabled },
      languageMode: { .locked("en") },
      selectedRoute: previewRoute { _ in
        .ready(
          LivePreviewEngineCandidate(
            key: LivePreviewEngineKey(engine: "test", commitment: "en"),
            makeEngine: { ReleasableEngine(onPrepared: { box.prepared = true }) }))
      }
    )

    coordinator.setRecording(true)
    // Signal, not a clock: wait for preparation to COMPLETE. The slot is only
    // filled after that, so asserting earlier would test nothing.
    for _ in 0..<2000 where !box.prepared { await Task.yield() }
    for _ in 0..<2000 where !coordinator.hasPreparedEngineForTests { await Task.yield() }
    #expect(box.prepared, "control: preparation must have completed")
    #expect(
      coordinator.hasPreparedEngineForTests,
      "control: the slot must be FULL before a release can mean anything")
    coordinator.setRecording(false)

    // The user turns the preview off and presses record again.
    box.enabled = false
    coordinator.setRecording(true)

    #expect(coordinator.display == .off)
    #expect(
      !coordinator.hasPreparedEngineForTests,
      "a disabled preview must not keep an engine — and with it a loaded model — cached")
  }

}

/// #2077 — what the coordinator actually did to whatever engine it was given.
///
/// An actor rather than a locked class: these counters are written from the engine
/// and the session, which run off the main actor, and read from `@MainActor` tests.
private actor PreviewEngineProbe {
  private(set) var prepareCalls = 0
  private(set) var sessionsOpened = 0
  private(set) var sessionsEnded = 0
  private(set) var samplesFed = 0
  private(set) var sawNonNilLookups = false

  func notePrepare() { prepareCalls += 1 }
  func noteOpen(lookups: WordCorrector.Lookups?) {
    sessionsOpened += 1
    if lookups != nil { sawNonNilLookups = true }
  }
  func noteEnd() { sessionsEnded += 1 }
  func noteFeed(_ count: Int) { samplesFed += count }
}

/// A counter the tests can share with a `@Sendable` closure.
private actor CountingBox {
  private(set) var value = 0
  func bump() { value += 1 }
  /// Returns the pre-increment count, so callers can index a sequence by call order.
  func next() -> Int {
    defer { value += 1 }
    return value
  }
}

private struct FakePreviewSession: LivePreviewEngineSession {
  let probe: PreviewEngineProbe
  func feed(_ samples: [Float]) async { await probe.noteFeed(samples.count) }
  func end() async { await probe.noteEnd() }
}

/// A preview engine with no vendor behind it, which is the whole point: before the
/// #2077 seam the coordinator could only be driven on macOS 26 with a reserved
/// locale and possibly a model download, so none of the behaviour below could be
/// asserted anywhere except by hand.
private struct FakePreviewEngine: LivePreviewEngine {
  let probe: PreviewEngineProbe

  func prepare() async throws { await probe.notePrepare() }

  func openSession(
    lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession {
    await probe.noteOpen(lookups: lookups)
    return FakePreviewSession(probe: probe)
  }
}

/// #1988 — counts reads of the capture buffer so a test can assert that a disabled
/// preview performs none.
@MainActor
private final class CountingAudioCapture: AudioCaptureInterface {
  private(set) var snapshotCallCount = 0

  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "hal_device_input"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture(sessionID: UInt64) async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm() async throws {}
  func abortPreWarm() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    snapshotCallCount += 1
    return ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}
