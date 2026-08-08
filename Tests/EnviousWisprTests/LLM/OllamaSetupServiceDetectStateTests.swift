import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1918: Ollama status goes stale in Settings — the detection/startup
/// concurrency guard (`statusMutationEpoch`, `pullEpoch`, `detectionToken`,
/// `isStartingServer`) that makes every direct writer of `setupState`/
/// `downloadedModels`/`lastKnownStateKey` safe against a background probe
/// (or the startup poll) suspended mid-flight and later committing stale data.
///
/// This suite is a SERIALIZED suite because these cases share
/// `UserDefaults.standard` key `OllamaSetupService.lastKnownReady`. Every test
/// that changes the key saves its prior value and restores it with `defer`.
@MainActor
@Suite("OllamaSetupService detectState/startServer concurrency guard (#1918)", .serialized)
struct OllamaSetupServiceDetectStateTests {

  // MARK: - Shared test infrastructure

  private static let lastKnownReadyKey = "OllamaSetupService.lastKnownReady"

  /// Signal-based release for a parked async closure — mirrors
  /// `OutputClassifierHolderStateTests.ReleaseGate` / `LLMPolishReentrancyTests.ReleaseGate`.
  private actor ReleaseGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  private nonisolated static func healthResponse(status: Int) -> (Data, URLResponse) {
    (
      Data(),
      HTTPURLResponse(
        url: URL(string: "http://localhost:11434")!, statusCode: status, httpVersion: nil,
        headerFields: nil)!
    )
  }

  private nonisolated static func tagsResponse(modelNames: [String]) -> (Data, URLResponse) {
    let json: [String: Any] = ["models": modelNames.map { ["name": $0] }]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return (
      data,
      HTTPURLResponse(
        url: URL(string: "http://localhost:11434/api/tags")!, statusCode: 200, httpVersion: nil,
        headerFields: nil)!
    )
  }

  private nonisolated static func tagsFailureResponse() -> (Data, URLResponse) {
    (
      Data(),
      HTTPURLResponse(
        url: URL(string: "http://localhost:11434/api/tags")!, statusCode: 500, httpVersion: nil,
        headerFields: nil)!
    )
  }

  /// A transport that routes by path: `/api/tags` gets `tags`, everything else
  /// (the bare health-check root) gets `health`. Mirrors how `resolveState`
  /// and the redesigned `startServer` poll both share one injected transport
  /// across `probeServer`/`fetchDownloadedModels`.
  private nonisolated static func routedTransport(
    health: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    tags: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
      if request.url?.path == "/api/tags" {
        return try await tags(request)
      }
      return try await health(request)
    }
  }

  /// Thread-safe counter/flag for asserting invocation state from inside a
  /// `@Sendable` transport closure, where a plain captured `var` is rejected
  /// under Swift 6 strict concurrency.
  private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private func setLastKnownReady(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: Self.lastKnownReadyKey)
  }

  private func withRestoredLastKnownReady(_ body: () async throws -> Void) async rethrows {
    // Preserves true ABSENCE, not just the Bool default — a genuinely fresh
    // machine has this key unset entirely, and restoring to `false` would
    // silently create a persisted entry that was never there before.
    let prior = UserDefaults.standard.object(forKey: Self.lastKnownReadyKey)
    defer {
      if let prior {
        UserDefaults.standard.set(prior, forKey: Self.lastKnownReadyKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.lastKnownReadyKey)
      }
    }
    try await body()
  }

  // MARK: - Silent vs non-silent triggers

  @Test("a background trigger never shows .detecting")
  func silentTriggerNeverObservesDetecting() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    // First establish `.error` through the public wrapper with a canned
    // non-200 response — a state `allowsSilentBackgroundRefresh`.
    _ = await service.isServerRunning(transport: { _ in Self.healthResponse(status: 503) })
    #expect(
      service.setupState
        == .error("Another app is using Ollama's port (11434). Close it and try again."))

    // Start a silent detection with its first transport request parked;
    // assert the state remains `.error`, not `.detecting`.
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "visible_poll",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)
        })
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // proves the transport was actually invoked

    #expect(
      service.setupState
        == .error("Another app is using Ollama's port (11434). Close it and try again."))

    await gate.release()
    _ = await task.value
  }

  @Test("a non-background trigger still shows .detecting immediately")
  func nonBackgroundTriggerStillShowsDetecting() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    // First establish a non-detecting state through a completed public call.
    _ = await service.isServerRunning(transport: { _ in Self.healthResponse(status: 503) })
    #expect(service.setupState != .detecting)

    // Start the second, non-background detection with its transport parked;
    // assert `.detecting` before releasing the response.
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "manual_refresh",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)
        })
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    #expect(service.setupState == .detecting)

    await gate.release()
    _ = await task.value
  }

  // MARK: - Overlapping detections

  @Test("overlapping calls: older starts first, resolves last -> newer result wins")
  func newerCallWinsOverStaleSlowerCall() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let olderGate = ReleaseGate()
    let olderStarted = AsyncStream.makeStream(of: Void.self)
    let olderStartedContinuation = olderStarted.continuation

    let olderTask = Task { @MainActor in
      await service.detectState(
        trigger: "manual_refresh",
        transport: { request in
          olderStartedContinuation.yield(())
          olderStartedContinuation.finish()
          await olderGate.wait()
          return Self.healthResponse(status: 503)  // would resolve to .installedNotRunning
        })
    }

    var olderIterator = olderStarted.stream.makeAsyncIterator()
    _ = await olderIterator.next()  // older call's probe is in flight

    // Newer call resolves fully before the older one is released.
    await service.detectState(
      trigger: "manual_refresh",
      transport: { _ in Self.healthResponse(status: 200) })

    #expect(
      service.setupState == .installedNotRunning || service.setupState == .runningNoModels
        || service.setupState == .ready)
    let afterNewer = service.setupState

    await olderGate.release()
    _ = await olderTask.value

    // The older, now-stale call must not have overwritten the newer result.
    #expect(service.setupState == afterNewer)
  }

  // MARK: - Pull contention

  @Test("detectState refuses to even START while a pull is already active")
  func detectStateNoOpsWhileAlreadyPulling() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })
    service.pullModel("llama3.2")
    #expect(service.currentPullingModel == "llama3.2")

    let counter = CallCounter()
    await service.detectState(
      trigger: "manual_refresh",
      transport: { request in
        await counter.increment()
        return Self.healthResponse(status: 200)
      })

    #expect(await counter.count == 0)
    service.cancelPull()
  }

  @Test(
    "a pull starts WHILE a probe is in flight, and FINISHES before the probe resolves — the case rev 2's guard structurally could not catch"
  )
  func pullStartingAndFinishingMidProbeIsNeverClobbered() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "visible_poll",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)  // stale "ready"-ish response
        })
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // proves the probe is in flight

    service.pullModel("llama3.2")
    service.cancelPull()  // both starts AND finishes the pull before the probe resolves

    let stateAfterPull = service.setupState

    await gate.release()
    _ = await task.value

    // The discarded probe must not have overwritten the pull's outcome.
    #expect(service.setupState == stateAfterPull)
  }

  // MARK: - Single-authority: isServerRunning's retained direct write

  @Test(
    "port-conflict .error surfaces through probeServer -> resolveState, with NO direct write outside detectState's commit"
  )
  func portConflictSurfacesAsErrorThroughSingleCommit() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "manual_refresh",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 503)  // port conflict
        })
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    // While the probe is parked, `setupState` must still be `.detecting`
    // (the entry write), not already `.error` — proving no direct write
    // happened outside the eventual commit.
    #expect(service.setupState == .detecting)

    await gate.release()
    _ = await task.value

    #expect(
      service.setupState
        == .error("Another app is using Ollama's port (11434). Close it and try again."))
  }

  @Test(
    "isServerRunning() (the public wrapper) still writes .error directly, for its ONE remaining caller, AND bumps statusMutationEpoch before that write"
  )
  func isServerRunningStillWritesErrorAndInvalidatesDetection() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let running = await service.isServerRunning(
      transport: { _ in Self.healthResponse(status: 503) })

    #expect(!running)
    #expect(
      service.setupState
        == .error("Another app is using Ollama's port (11434). Close it and try again."))

    // A detection parked BEFORE this call must back off rather than
    // overwrite it — proving the epoch bump actually took effect.
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "visible_poll",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)
        })
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    // Land a second isServerRunning() error WHILE the detection is parked.
    _ = await service.isServerRunning(transport: { _ in Self.healthResponse(status: 503) })

    await gate.release()
    _ = await task.value

    // The parked detection's stale "running" result must not have won.
    #expect(
      service.setupState
        == .error("Another app is using Ollama's port (11434). Close it and try again."))
  }

  // MARK: - deleteModel / startServer race coverage

  @Test(
    "a deleteModel() success lands entirely within a probe's network wait — a case pullEpoch cannot see at all"
  )
  func deleteModelDuringProbeIsNeverClobbered() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let task = Task { @MainActor in
      await service.detectState(
        trigger: "visible_poll",
        transport: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 503)  // stale "not running"
        })
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    await service.deleteModel(
      name: "llama3.2", transport: { _ in Self.healthResponse(status: 200) })
    let stateAfterDelete = service.setupState

    await gate.release()
    _ = await task.value

    #expect(service.setupState == stateAfterDelete)
  }

  @Test(
    "a startServer() write lands entirely within a probe's network wait, same shape as the delete case"
  )
  func startServerDuringProbeIsNeverClobbered() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/test/ollama" })

      let gate = ReleaseGate()
      let started = AsyncStream.makeStream(of: Void.self)
      let startedContinuation = started.continuation

      let task = Task { @MainActor in
        await service.detectState(
          trigger: "visible_poll",
          transport: { request in
            startedContinuation.yield(())
            startedContinuation.finish()
            await gate.wait()
            return Self.healthResponse(status: 503)  // stale "not running"
          })
      }

      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()

      service.startServer(
        launch: { true },
        pollDelay: {},
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))

      // Let the startup poll's own Task run to completion.
      for _ in 0..<200 where service.setupState == .detecting {
        await Task.yield()
      }
      let stateAfterStartup = service.setupState

      await gate.release()
      _ = await task.value

      #expect(service.setupState == stateAfterStartup)
    }
  }

  // MARK: - Resolution mutation guards (grounded review r3, required)

  @Test(
    "a rejected resolution (superseded, pull-invalidated, or cancelled) must not mutate downloadedModels or lastKnownStateKey"
  )
  func rejectedResolutionNeverMutatesModelsOrDefaults() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/opt/homebrew/bin/ollama" })
      setLastKnownReady(false)  // force FULL detection, not the fast path

      let gate = ReleaseGate()
      let started = AsyncStream.makeStream(of: Void.self)
      let startedContinuation = started.continuation

      let priorModels = service.downloadedModels
      let priorDefault = UserDefaults.standard.bool(forKey: Self.lastKnownReadyKey)

      let task = Task { @MainActor in
        await service.detectState(
          trigger: "manual_refresh",
          transport: Self.routedTransport(
            health: { request in
              startedContinuation.yield(())
              startedContinuation.finish()
              await gate.wait()
              return Self.healthResponse(status: 200)
            },
            tags: { _ in Self.tagsResponse(modelNames: ["new-model"]) }))
      }

      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()

      // Invalidate via a pull starting mid-probe.
      service.pullModel("llama3.2")

      await gate.release()
      _ = await task.value

      #expect(service.downloadedModels.count == priorModels.count)
      #expect(UserDefaults.standard.bool(forKey: Self.lastKnownReadyKey) == priorDefault)

      service.cancelPull()
    }
  }

  @Test("a same-state valid resolution (setupState unchanged) still applies a changed model list")
  func sameStateResolutionStillUpdatesModels() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/opt/homebrew/bin/ollama" })
      setLastKnownReady(false)

      // Establish `.ready` through one completed public detection.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))
      #expect(service.setupState == .ready)

      // Run a second detection returning a DIFFERENT model list while
      // remaining `.ready`; assert the model list changes.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2", "mistral"]) }))

      #expect(service.setupState == .ready)
      #expect(service.downloadedModels.count == 2)
    }
  }

  @Test(
    "a failed model-list fetch retains the STARTING list for the state decision, matching refreshDownloadedModels's original no-op-on-failure"
  )
  func failedFetchRetainsStartingModelsForStateDecision() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/test/ollama" })
      setLastKnownReady(true)  // reach the fast path directly

      // Seed a non-empty list via a successful detection first.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))
      #expect(service.setupState == .ready)
      let seededCount = service.downloadedModels.count
      #expect(seededCount > 0)

      // Now a fetch that succeeds for the server probe but fails /api/tags.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsFailureResponse() }))

      // Resulting state is `.ready` (not `.runningNoModels`), because the
      // retained starting list was non-empty, and the committed
      // downloadedModels is unchanged.
      #expect(service.setupState == .ready)
      #expect(service.downloadedModels.count == seededCount)
    }
  }

  @Test(
    "a fast-path port conflict followed by a second probe reporting .unavailable resolves to .installedNotRunning, a deliberate divergence from the original's stale-.error-retention readback"
  )
  func staleFastPathErrorClearsWhenSecondProbeRecovers() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/opt/homebrew/bin/ollama" })
      setLastKnownReady(true)  // reach the fast path

      let counter = CallCounter()
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { request in
            await counter.increment()
            if await counter.count == 1 {
              return Self.healthResponse(status: 503)  // fast-path port-conflict-shaped failure
            }
            throw URLError(.cannotConnectToHost)  // full-detection probe: connection failure
          },
          tags: { _ in Self.tagsResponse(modelNames: []) }))

      #expect(service.setupState == .installedNotRunning)
    }
  }

  // MARK: - startServer

  @Test(
    "startServer is single-flight: a second call while starting is a no-op, not a second launch/poll"
  )
  func repeatedStartServerIsSingleFlight() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation
    var launchCount = 0

    service.startServer(
      launch: {
        launchCount += 1
        return true
      },
      pollDelay: {
        startedContinuation.yield(())
        await gate.wait()
      },
      transport: { _ in Self.healthResponse(status: 503) })

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // first poll tick is parked

    var secondLaunchCount = 0
    service.startServer(
      launch: {
        secondLaunchCount += 1
        return true
      },
      pollDelay: {},
      transport: { _ in Self.healthResponse(status: 200) })

    #expect(launchCount == 1)
    #expect(secondLaunchCount == 0)
    #expect(service.setupState != .ready)  // second call's transport never ran

    await gate.release()
    for _ in 0..<200 where service.setupState == .detecting {
      await Task.yield()
    }
  }

  @Test(
    "startup reaches the server but /api/tags fails -- must retain the existing model list, matching refreshDownloadedModels's own no-op-on-failure contract, not erase it"
  )
  func startServerFailedFetchRetainsStartingModels() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/test/ollama" })
      setLastKnownReady(true)

      // Seed a non-empty model list.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))
      let seededCount = service.downloadedModels.count
      #expect(seededCount > 0)

      service.startServer(
        launch: { true },
        pollDelay: {},
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsFailureResponse() }))

      for _ in 0..<200 where service.setupState != .ready && service.setupState != .runningNoModels
      {
        await Task.yield()
      }

      #expect(service.setupState == .ready)
      #expect(service.downloadedModels.count == seededCount)
    }
  }

  @Test("injected launch failure commits the existing error and releases single-flight")
  func startServerLaunchFailureCommitsErrorAndAllowsRetry() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    service.startServer(
      launch: { false }, pollDelay: {}, transport: { _ in Self.healthResponse(status: 200) })

    #expect(
      service.setupState
        == .error("Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."))

    var secondLaunchRan = false
    service.startServer(
      launch: {
        secondLaunchRan = true
        return false
      }, pollDelay: {}, transport: { _ in Self.healthResponse(status: 200) })

    #expect(secondLaunchRan)  // single-flight released after the first failure
  }

  @Test("twenty unsuccessful probes commit timeout and release single-flight")
  func startServerTimeoutCommitsErrorAndAllowsRetry() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    service.startServer(
      launch: { true },
      pollDelay: {},
      transport: { _ in Self.healthResponse(status: 503) })

    for _ in 0..<500
    where service.setupState
      != .error("Couldn't start Ollama automatically. Try running `ollama serve` in Terminal.")
    {
      await Task.yield()
    }

    #expect(
      service.setupState
        == .error("Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."))

    var secondLaunchRan = false
    service.startServer(
      launch: {
        secondLaunchRan = true
        return true
      }, pollDelay: {}, transport: { _ in Self.healthResponse(status: 200) })
    #expect(secondLaunchRan)
  }

  @Test("a port-conflict probe surfaces its error right away but polling continues")
  func startServerPortConflictSurfacesImmediatelyAndKeepsPolling() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/test/ollama" })
      setLastKnownReady(false)

      // Deterministic ordering: park the SECOND health request behind a
      // gate. Waiting for "second request started" proves the first
      // conflict was already committed — a plain `Task.yield()` poll cannot
      // guarantee interception of that transient `.error` state, since
      // nothing forces the startup Task to yield between committing `.error`
      // and immediately looping into its next (trivial, no real delay)
      // attempt.
      let counter = CallCounter()
      let gate = ReleaseGate()
      let secondRequestStarted = AsyncStream.makeStream(of: Void.self)
      let secondRequestStartedContinuation = secondRequestStarted.continuation

      service.startServer(
        launch: { true },
        pollDelay: {},
        transport: Self.routedTransport(
          health: { _ in
            await counter.increment()
            if await counter.count == 1 {
              return Self.healthResponse(status: 503)
            }
            secondRequestStartedContinuation.yield(())
            secondRequestStartedContinuation.finish()
            await gate.wait()
            return Self.healthResponse(status: 200)
          },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))

      var iterator = secondRequestStarted.stream.makeAsyncIterator()
      _ = await iterator.next()  // proves the first conflict was already committed

      #expect(
        service.setupState
          == .error("Another app is using Ollama's port (11434). Close it and try again."))

      await gate.release()
      for _ in 0..<200 where service.setupState != .ready { await Task.yield() }
      #expect(service.setupState == .ready)
    }
  }

  @Test(
    "a pull that starts during startup's probe or fetch await must not be clobbered by startup's later, now-stale commit"
  )
  func startServerDoesNotClobberPullStartedDuringPoll() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    service.startServer(
      launch: { true },
      pollDelay: {},
      transport: Self.routedTransport(
        health: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)
        },
        tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    // `pullModel` has no transport seam and calls the real network for its
    // own streaming pull, so leaving it active here would race the real
    // connection outcome against this test's gated mock (fast-refuses in a
    // sandboxed CI runner with no Ollama daemon, unlike a dev machine running
    // one; CI failure on PR #1984, 2026-08-08). Cancelling immediately
    // settles setupState synchronously and bumps pullEpoch, so the pull
    // task's own eventual real-network completion is a guaranteed no-op
    // regardless of how fast or slow it resolves -- matching
    // `startServerDoesNotClobberDeleteDuringPoll`'s already-deterministic
    // pattern of settling the competing write before capturing the snapshot.
    service.pullModel("mistral")
    service.cancelPull()
    let stateAfterPull = service.setupState

    await gate.release()
    for _ in 0..<200 { await Task.yield() }

    #expect(service.setupState == stateAfterPull)
  }

  @Test(
    "the symmetric case: a delete that lands during startup's probe or fetch await must not be clobbered by startup's later, now-stale commit"
  )
  func startServerDoesNotClobberDeleteDuringPoll() async {
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient(),
      findOllamaBinaryOverride: { "/test/ollama" })

    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    service.startServer(
      launch: { true },
      pollDelay: {},
      transport: Self.routedTransport(
        health: { request in
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
          return Self.healthResponse(status: 200)
        },
        tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()

    await service.deleteModel(
      name: "llama3.2", transport: { _ in Self.healthResponse(status: 200) })
    let stateAfterDelete = service.setupState

    await gate.release()
    for _ in 0..<200 { await Task.yield() }

    #expect(service.setupState == stateAfterDelete)
  }

  @Test(
    "an explicit detection landing during startup's fetch await must not be clobbered by startup's later, now-stale commit"
  )
  func startServerDoesNotClobberExplicitDetectionDuringFetch() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/opt/homebrew/bin/ollama" })
      setLastKnownReady(false)

      let gate = ReleaseGate()
      let started = AsyncStream.makeStream(of: Void.self)
      let startedContinuation = started.continuation

      service.startServer(
        launch: { true },
        pollDelay: {},
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { request in
            startedContinuation.yield(())
            startedContinuation.finish()
            await gate.wait()
            return Self.tagsFailureResponse()
          }))

      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()  // startup's fetch is now in flight

      // Explicit detection completes and commits `.installedNotRunning`.
      // `probeServer` maps a THROWN transport error (connection refused) to
      // `.unavailable` -> `.installedNotRunning`; a non-200 HTTP response
      // maps to `.portConflict` instead, which is a different case.
      await service.detectState(
        trigger: "manual_refresh",
        transport: Self.routedTransport(
          health: { _ in throw URLError(.cannotConnectToHost) },
          tags: { _ in Self.tagsFailureResponse() }))
      #expect(service.setupState == .installedNotRunning)

      await gate.release()
      for _ in 0..<200 { await Task.yield() }

      // Startup must have backed off, not overwritten the detection's result.
      #expect(service.setupState == .installedNotRunning)
    }
  }

  @Test(
    "while isStartingServer is true, a passive trigger no-ops but an explicit trigger still runs, and cannot beat a startup terminal commit that lands after it"
  )
  func startingServerGateDistinguishesTriggers() async {
    await withRestoredLastKnownReady {
      let service = OllamaSetupService(
        cloudCatalogClient: OllamaCloudCatalogClient(),
        findOllamaBinaryOverride: { "/test/ollama" })

      let gate = ReleaseGate()
      let started = AsyncStream.makeStream(of: Void.self)
      let startedContinuation = started.continuation

      // Hold the startup overload inside its poll.
      service.startServer(
        launch: { true },
        pollDelay: {
          startedContinuation.yield(())
          startedContinuation.finish()
          await gate.wait()
        },
        transport: Self.routedTransport(
          health: { _ in Self.healthResponse(status: 200) },
          tags: { _ in Self.tagsResponse(modelNames: ["llama3.2"]) }))

      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()  // isStartingServer is now true

      // Invoke visible_poll and assert its transport is untouched.
      let passiveCounter = CallCounter()
      await service.detectState(
        trigger: "visible_poll",
        transport: { _ in
          await passiveCounter.increment()
          return Self.healthResponse(status: 200)
        })
      #expect(await passiveCounter.count == 0)

      // Invoke manual_refresh and assert its transport starts.
      let explicitCounter = CallCounter()
      let explicitGate = ReleaseGate()
      let explicitStarted = AsyncStream.makeStream(of: Void.self)
      let explicitStartedContinuation = explicitStarted.continuation

      let explicitTask = Task { @MainActor in
        await service.detectState(
          trigger: "manual_refresh",
          transport: { request in
            await explicitCounter.increment()
            explicitStartedContinuation.yield(())
            explicitStartedContinuation.finish()
            await explicitGate.wait()
            return Self.healthResponse(status: 503)  // stale, would-be .installedNotRunning
          })
      }
      var explicitIterator = explicitStarted.stream.makeAsyncIterator()
      _ = await explicitIterator.next()
      #expect(await explicitCounter.count > 0)

      // Complete startup — its terminal commit lands while the explicit
      // detection is still parked.
      await gate.release()
      for _ in 0..<200 where service.setupState != .ready { await Task.yield() }
      #expect(service.setupState == .ready)

      // Release the stale explicit detection; it must not overwrite startup's
      // fresher, already-landed result.
      await explicitGate.release()
      _ = await explicitTask.value
      #expect(service.setupState == .ready)
    }
  }
}

/// Exhaustive coverage of `OllamaSetupState.allowsSilentBackgroundRefresh`:
/// `.error` IS eligible; `.detecting`/`.pullingModel` are NOT. A new
/// `OllamaSetupState` case fails to compile here until classified.
@Suite("OllamaSetupState background-refresh eligibility (#1918)")
struct OllamaSetupStateBackgroundRefreshEligibilityTests {
  @Test("every case's eligibility is exhaustively classified")
  func exhaustiveEligibility() {
    #expect(OllamaSetupState.ready.allowsSilentBackgroundRefresh)
    #expect(OllamaSetupState.installedNotRunning.allowsSilentBackgroundRefresh)
    #expect(OllamaSetupState.runningNoModels.allowsSilentBackgroundRefresh)
    #expect(OllamaSetupState.notInstalled.allowsSilentBackgroundRefresh)
    #expect(OllamaSetupState.error("x").allowsSilentBackgroundRefresh)
    #expect(!OllamaSetupState.detecting.allowsSilentBackgroundRefresh)
    #expect(!OllamaSetupState.pullingModel(progress: 0, status: "x").allowsSilentBackgroundRefresh)
  }
}
