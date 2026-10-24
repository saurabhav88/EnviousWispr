import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

@Suite("EG-1 adapter server lifecycle (#3105)", .serialized, .tags(.driftGuard))
struct EGOneAdapterLifecycleTests {
  /// A tiny HTTP server that records argv before answering /health. An
  /// adapter-failure marker makes only --lora-scaled launches exit before readiness.
  /// Shared with `EGOneOutsideStopRecoveryTests` below, which needs the same
  /// fake server to be stopped from outside once it is ready (#3988).
  fileprivate struct Fixture {
    let root: URL
    let binary: URL
    let model: URL
    let adapter: URL
    let log: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "eg1-adapter-lifecycle-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      binary = root.appendingPathComponent("fake-server")
      model = root.appendingPathComponent("base.gguf")
      adapter = root.appendingPathComponent("checker.gguf")
      log = root.appendingPathComponent("launches.jsonl")
      try Data("base".utf8).write(to: model)
      try Data("checker".utf8).write(to: adapter)
      let script = #"""
        #!/usr/bin/env python3
        import http.server, json, os, signal, sys, time
        args = sys.argv[1:]
        root = os.path.dirname(os.path.realpath(sys.argv[0]))
        with open(os.path.join(root, 'pids.txt'), 'a') as pids:
            pids.write(f'{os.getpid()}\n')
        # #3988: SIGUSR1 = a clean exit, SIGUSR2 = a nonzero exit, on cue.
        signal.signal(signal.SIGUSR1, lambda *_: os._exit(0))
        signal.signal(signal.SIGUSR2, lambda *_: os._exit(3))
        adapter_root = (os.path.dirname(args[args.index('--lora-scaled') + 1].rsplit(':', 1)[0])
                        if '--lora-scaled' in args else None)
        with open(os.path.join(root, 'launches.jsonl'), 'a') as log:
            log.write(json.dumps(args) + '\n')
        if os.path.exists(os.path.join(root, 'exit_on_start')):
            sys.exit(0)
        if os.path.exists(os.path.join(root, 'hold_ready')):
            while not os.path.exists(os.path.join(root, 'release_ready')):
                # test-fixture-timer: park startup until the test releases it
                time.sleep(0.05)
        if adapter_root and os.path.exists(os.path.join(adapter_root, 'fail_adapter')):
            sys.exit(2)
        if adapter_root and os.path.exists(os.path.join(adapter_root, 'hang_adapter')):
            while True:
                # test-fixture-timer: hold the child alive past the readiness deadline
                time.sleep(0.1)
        port = int(args[args.index('--port') + 1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == '/health' else 404)
                self.end_headers()
            def log_message(self, *args):
                pass
        http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """#
      try Data(script.utf8).write(to: binary)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    func configuration(adapterURL: URL? = nil) -> EGOneServerManager.Configuration {
      EGOneServerManager.Configuration(
        serverBinaryURL: binary, modelURL: model, contextTokens: 4096,
        extraArguments: EGOneRuntime.engineArguments(for: .egOne),
        readinessBudgetSeconds: 4,
        learnedWordAdapterURL: adapterURL,
        learnedWordAdapterArguments: adapterURL.map {
          Array(
            EGOneRuntime.launchArguments(
              for: .egOne, learnedWordAdapterURL: $0
            ).dropFirst(6))
        } ?? [])
    }

    func launches() throws -> [[String]] {
      guard FileManager.default.fileExists(atPath: log.path) else { return [] }
      return try String(contentsOf: log, encoding: .utf8)
        .split(separator: "\n").map { line in
          try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String])
        }
    }

    /// The newest child's process ID, written by the child itself.
    func lastPID() throws -> Int32 {
      let lines = try String(
        contentsOf: root.appendingPathComponent("pids.txt"), encoding: .utf8
      ).split(separator: "\n")
      return try #require(lines.last.flatMap { Int32($0) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  @MainActor
  @Test("each runtime reads its own adapter provider on every boot configuration")
  func providerPerBoot() async {
    var calls = 0
    var available: URL? = nil
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      learnedWordAdapterProvider: {
        calls += 1
        return available
      })
    let binary = URL(fileURLWithPath: "/fake/server")
    let model = URL(fileURLWithPath: "/fake/base.gguf")
    let first = await egOne.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    available = URL(fileURLWithPath: "/fake/checker.gguf")
    let second = await egOne.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    #expect(calls == 2)
    #expect(first.learnedWordAdapterURL == nil)
    #expect(second.learnedWordAdapterURL == available)
    // #3105: S1-mini boots with its own D5 adapter from its own provider.
    let d5 = URL(fileURLWithPath: "/fake/s1-d5.gguf")
    let s1 = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, provider: .s1Mini,
      learnedWordAdapterProvider: { d5 })
    let s1Config = await s1.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    #expect(s1Config.learnedWordAdapterURL == d5)
    #expect(s1Config.extraArguments == EGOneRuntime.engineArguments(for: .s1Mini))
    // A runtime built without a provider boots bare.
    let bare = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, provider: .s1Mini)
    let bareConfig = await bare.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    #expect(bareConfig.learnedWordAdapterURL == nil)
    #expect(bareConfig.learnedWordAdapterArguments.isEmpty)
    // A path the server cannot split boots without the checker, and the endpoint
    // does not claim an adapter the requests would name.
    let unsplittable = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, provider: .s1Mini,
      learnedWordAdapterProvider: { URL(fileURLWithPath: "/fake/a,b/s1-d5.gguf") })
    let refused = await unsplittable.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    #expect(refused.learnedWordAdapterURL == nil)
    #expect(refused.learnedWordAdapterArguments.isEmpty)
  }

  @Test("adapter-free polish bodies keep the original bytes across inputs")
  func adapterFreePolishBodyParity() throws {
    for (system, user, cap) in [
      ("", "", 1),
      ("System\nline two", "Tuist and café 👋", 128),
      ("<TRANSCRIPT>", "a\n\nb", 2048),
    ] {
      let config = LLMProviderConfig(
        model: LLMProvider.egOneModelName, apiKeyKeychainId: nil,
        outputTokens: .capped(cap), temperature: 0, thinking: nil)
      let expected: [String: Any] = [
        "model": LLMProvider.egOneModelName,
        "messages": [
          ["role": "system", "content": system],
          ["role": "user", "content": user],
        ],
        "max_tokens": cap,
        "temperature": 0,
      ]
      let actual = try EGOneConnector.makeRequestBody(
        system: system, user: user, config: config, hasLearnedWordAdapter: false)
      #expect(
        try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys)
          == JSONSerialization.data(withJSONObject: expected, options: .sortedKeys))
    }
  }

  @Test("ready process waits for a take or import pin before changing adapter")
  func deferredRestartAndEndpointFlag() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    let bare = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration())
    let adapted = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration(adapterURL: fixture.adapter))
    await coordinator.transition(to: .run(bare), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(
      Array(try fixture.launches()[0].suffix(EGOneRuntime.engineArguments(for: .egOne).count))
        == EGOneRuntime.engineArguments(for: .egOne))
    let admission = await coordinator.acquireLease(for: .egOne)
    let lease: LocalPolishServerLease
    switch admission {
    case .granted(let granted): lease = granted
    case .changing:
      Issue.record("ready server refused a lease")
      return
    }
    await coordinator.transition(to: .run(adapted), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 1)
    await coordinator.releaseLease(lease)
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == true)
    #expect(try fixture.launches().count == 2)

    await coordinator.transition(to: .run(bare), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 3)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  @Test("adapter startup fault retries the admitted base with no adapter")
  func failedAdapterFallsBack() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("fail_adapter"))
    await manager.start(configuration: fixture.configuration(adapterURL: fixture.adapter))
    #expect(await manager.activeEndpoint()?.hasLearnedWordAdapter == false)
    #expect(await manager.checkerFailureReason == .adapterServerExited)
    let launches = try fixture.launches()
    #expect(launches.count == 2)
    #expect(launches[0].contains("--lora-scaled"))
    #expect(!launches[1].contains("--lora-scaled"))
    await manager.stop()
  }

  @MainActor
  @Test("adapter startup fault does not call base shard repair")
  func adapterFaultSkipsBaseRepair() async throws {
    let fixture = try Fixture()
    let suite = "eg1-adapter-repair-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer {
      store.removePersistentDomain(forName: suite)
      fixture.cleanup()
    }
    let install = fixture.root.appendingPathComponent("base-install", isDirectory: true)
    let metadata = fixture.root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    try Data(count: 1000).write(
      to: install.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(
      to: install.appendingPathComponent("eg-1-00002-of-00002.gguf"))
    let controller = ModelDeliveryController(defaults: TestDefaults.suite(suite)!)
    let delivery = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: nil, defaults: store)
    #expect(await delivery.adoptIfPresent())
    try Data().write(to: fixture.root.appendingPathComponent("fail_adapter"))
    var repairCalls = 0
    delivery.onRepairForTesting = { repairCalls += 1 }
    let manifest = EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded",
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
    let coordinator = LocalPolishServerCoordinator()
    let runtime = EGOneRuntime(
      manifest: manifest, serverBinaryURL: fixture.binary, delivery: delivery,
      defaults: store, coordinator: coordinator,
      learnedWordAdapterProvider: { fixture.adapter })
    let activation = try #require(runtime.activateAndProbe())
    await activation.value
    #expect(await runtime.activeEndpoint()?.hasLearnedWordAdapter == false)
    #expect(await runtime.checkerFailureReason() == .adapterServerExited)
    #expect(repairCalls == 0)
    #expect(await controller.isAdmitted(registration))
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  @Test("adapter that never becomes ready falls back with a closed reason")
  func unreadyAdapterFallsBack() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("hang_adapter"))
    var configuration = fixture.configuration(adapterURL: fixture.adapter)
    configuration.readinessBudgetSeconds = 3
    await manager.start(configuration: configuration)
    #expect(await manager.activeEndpoint()?.hasLearnedWordAdapter == false)
    #expect(await manager.checkerFailureReason == .adapterServerNeverReady)
    #expect(try fixture.launches().count == 2)
    await manager.stop()
  }

  @Test("a bare-base fallback reboots with the adapter only when delivery says it changed")
  func fallbackRetriesOnlyOnAdapterSignal() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    let marker = fixture.root.appendingPathComponent("fail_adapter")
    try Data().write(to: marker)
    let adapted = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration(adapterURL: fixture.adapter))
    await coordinator.transition(to: .run(adapted), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 2)

    // A restatement (launch, switch, settings open) leaves the fallback alone.
    try FileManager.default.removeItem(at: marker)
    await coordinator.transition(to: .run(adapted), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 2)

    let signalled = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration(adapterURL: fixture.adapter),
      retriesAdapterFallback: true)
    await coordinator.transition(to: .run(signalled), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == true)
    #expect(try fixture.launches().count == 3)
    #expect(await coordinator.checkerFailureReason(for: .egOne) == nil)

    // Once the adapter is live, the same signal is an ordinary restatement.
    await coordinator.transition(to: .run(signalled), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 3)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  /// The lease seam `EGOneRuntime` provides, over a bare coordinator.
  @MainActor
  private final class CoordinatorServer: EGOneLeaseProviding {
    let coordinator: LocalPolishServerCoordinator
    init(_ coordinator: LocalPolishServerCoordinator) { self.coordinator = coordinator }
    func activeEndpoint() async -> EGOneEndpoint? { await coordinator.endpoint(for: .egOne) }
    func acquireLocalServerLease() async -> LocalPolishLeaseAdmission {
      await coordinator.acquireLease(for: .egOne)
    }
    func releaseLocalServerLease(_ lease: LocalPolishServerLease) async {
      await coordinator.releaseLease(lease)
    }
  }

  @MainActor
  @Test("a running word check holds the server: an adapter change waits for its release")
  func checkerHoldDefersAdapterChange() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    let bare = LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())
    let adapted = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration(adapterURL: fixture.adapter))
    await coordinator.transition(to: .run(adapted), intent: coordinator.claimIntent())
    let hold = try #require(
      await EGOneLearnedWordChecker.hold(on: CoordinatorServer(coordinator)))
    #expect(hold.endpoint.hasLearnedWordAdapter)
    #expect(try fixture.launches().count == 1)

    await coordinator.transition(to: .run(bare), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) == hold.endpoint)
    #expect(try fixture.launches().count == 1)

    await hold.release()
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 2)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  @Test("switching to S1 and back boots EG-1 with the latest adapter set")
  func switchToS1AndBack() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    let bare = LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())
    let adapted = LocalPolishTarget(
      provider: .egOne, configuration: fixture.configuration(adapterURL: fixture.adapter))
    var s1Config = fixture.configuration()
    s1Config.extraArguments = EGOneRuntime.engineArguments(for: .s1Mini)
    let s1 = LocalPolishTarget(provider: .s1Mini, configuration: s1Config)
    await coordinator.transition(to: .run(bare), intent: coordinator.claimIntent())
    await coordinator.transition(to: .run(s1), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) == nil)
    #expect(await coordinator.endpoint(for: .s1Mini)?.hasLearnedWordAdapter == false)
    await coordinator.transition(to: .run(adapted), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == true)
    #expect(try fixture.launches().count == 3)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }
}

/// #3988: a READY local polish server stopped from outside the app (macOS under
/// memory pressure, Activity Monitor, `kill`) waits idle for the next
/// activation instead of spending the crash restart and giving up for the
/// session. When this fails, the user loses AI polish silently until they
/// restart the app.
@Suite("Local polish server stopped from outside (#3988)", .serialized, .tags(.productOutcome))
struct EGOneOutsideStopRecoveryTests {
  fileprivate typealias Fixture = EGOneAdapterLifecycleTests.Fixture
  typealias State = EGOneServerManager.Lifecycle

  /// Every state the manager emits, in emission order. The manager calls its
  /// observer synchronously on its actor, so recording under a lock keeps
  /// that order; a waiter parks until a matching state lands.
  final class StateRecorder: Sendable {
    private struct Box {
      var states: [State] = []
      var waiters: [UUID: (match: @Sendable (State) -> Bool, resume: CheckedContinuation<State?, Never>)] =
        [:]
    }
    private let box = OSAllocatedUnfairLock(initialState: Box())

    var count: Int { box.withLock { $0.states.count } }
    var states: [State] { box.withLock { $0.states } }

    func record(_ state: State) {
      let hits = box.withLock { box -> [CheckedContinuation<State?, Never>] in
        box.states.append(state)
        let matched = box.waiters.filter { $0.value.match(state) }
        for key in matched.keys { box.waiters[key] = nil }
        return matched.values.map(\.resume)
      }
      hits.forEach { $0.resume(returning: state) }
    }

    /// The first state at or after `index` that matches, or nil at the deadline.
    func first(
      from index: Int, deadline: Duration = .seconds(20),
      where match: @escaping @Sendable (State) -> Bool
    ) async -> State? {
      let id = UUID()
      return await withCheckedContinuation { continuation in
        let found = box.withLock { box -> State? in
          if let hit = box.states.dropFirst(index).first(where: match) { return hit }
          box.waiters[id] = (match, continuation)
          return nil
        }
        if let found {
          continuation.resume(returning: found)
          return
        }
        Task { [box] in
          // deadline-fallback: give up so the test fails by name instead of hanging
          try? await Task.sleep(for: deadline)
          box.withLock { $0.waiters.removeValue(forKey: id) }?.resume.resume(returning: nil)
        }
      }
    }
  }

  /// How the ready child is ended. Outside stops are the closed allowlist;
  /// every other ending keeps crash policy.
  enum Ending: Sendable, CustomTestStringConvertible {
    case signal(Int32)
    case cleanExit
    case nonzeroExit

    var testDescription: String {
      switch self {
      case .signal(let number): "signal \(number)"
      case .cleanExit: "exit 0"
      case .nonzeroExit: "exit 3"
      }
    }

    func apply(to pid: Int32) {
      switch self {
      case .signal(let number): kill(pid, number)
      case .cleanExit: kill(pid, SIGUSR1)
      case .nonzeroExit: kill(pid, SIGUSR2)
      }
    }
  }

  static let outsideStops: [Ending] = [
    .signal(SIGTERM), .signal(SIGKILL), .signal(SIGINT), .signal(SIGHUP), .cleanExit,
  ]
  /// Crash-policy endings that macOS does not treat as a crash. A real SIGSEGV
  /// or SIGABRT makes macOS write a Python crash report and show a "Python quit
  /// unexpectedly" alert on the developer's screen for every test run. The
  /// classification test covers those values without a process.
  static let crashEndings: [Ending] = [.signal(SIGALRM), .signal(SIGPROF), .nonzeroExit]

  static func isReady(_ state: State) -> Bool {
    if case .ready = state.state { return true }
    return false
  }

  static func outsideStop(_ generation: Int) -> State {
    State(state: .stoppedOutside, outsideStopGeneration: generation)
  }

  /// Ends the newest child and returns the first state the manager settles on.
  private func end(
    _ fixture: Fixture, with ending: Ending, recorder: StateRecorder
  ) async throws -> State? {
    let mark = recorder.count
    ending.apply(to: try fixture.lastPID())
    return await recorder.first(from: mark) { state in
      switch state.state {
      case .ready, .stoppedOutside, .failed, .stopped, .pausedForMemoryPressure: true
      case .starting: false
      }
    }
  }

  @Test("an outside stop waits idle, keeps no endpoint, and the next start brings it back", arguments: outsideStops)
  func outsideStopIsStartableIdle(ending: Ending) async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }

    await manager.start(configuration: fixture.configuration())
    try #require(await manager.activeEndpoint() != nil, "fake server never became ready")
    let first = try await end(fixture, with: ending, recorder: recorder)
    #expect(first == Self.outsideStop(1))
    #expect(await manager.activeEndpoint() == nil)
    #expect(try fixture.launches().count == 1, "an outside stop must not restart on its own")
    #expect(
      await manager.probeHealth(promptFamily: .egOneFixed, spec: .egOne)
        == .yellow(reason: "stopped_outside"))

    // Repeated outside stops never reach the session give-up.
    await manager.start(configuration: fixture.configuration())
    #expect(await manager.activeEndpoint() != nil)
    let second = try await end(fixture, with: ending, recorder: recorder)
    #expect(second == Self.outsideStop(2))
    await manager.start(configuration: fixture.configuration())
    #expect(await manager.activeEndpoint() != nil)
    #expect(try fixture.launches().count == 3)

    // A deliberate stop stays a plain stop.
    await manager.stop()
    #expect(recorder.states.last == .stopped)
  }

  @Test("recovery keeps the stop's identity until ready; a deliberate stop clears it")
  func identityOutlivesRecoveryStartUntilReady() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }
    await manager.start(configuration: fixture.configuration())
    try #require(await manager.activeEndpoint() != nil, "fake server never became ready")
    #expect(try await end(fixture, with: .signal(SIGTERM), recorder: recorder) == Self.outsideStop(1))

    // Park the replacement before it answers /health: a take landing now must
    // still find the stop it missed polish because of.
    try Data().write(to: fixture.root.appendingPathComponent("hold_ready"))
    let mark = recorder.count
    let recovery = Task { await manager.start(configuration: fixture.configuration()) }
    let starting = await recorder.first(from: mark) { $0.state == .starting }
    #expect(starting == State(state: .starting, outsideStopGeneration: 1))
    #expect(await manager.currentLifecycle() == State(state: .starting, outsideStopGeneration: 1))
    try Data().write(to: fixture.root.appendingPathComponent("release_ready"))
    await recovery.value
    let ready = await manager.currentLifecycle()
    #expect(Self.isReady(ready))
    #expect(ready.outsideStopGeneration == nil)

    // A second stop, then a deliberate stop during the outstanding window.
    #expect(try await end(fixture, with: .signal(SIGTERM), recorder: recorder) == Self.outsideStop(2))
    await manager.stop()
    #expect(await manager.currentLifecycle() == .stopped)
  }

  @Test("a recovery that fails keeps the stop for diagnosis and says it failed")
  func failedRecoveryKeepsDiagnosis() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }
    await manager.start(configuration: fixture.configuration())
    try #require(await manager.activeEndpoint() != nil, "fake server never became ready")
    #expect(try await end(fixture, with: .signal(SIGKILL), recorder: recorder) == Self.outsideStop(1))

    try Data().write(to: fixture.root.appendingPathComponent("exit_on_start"))
    let mark = recorder.count
    await manager.start(configuration: fixture.configuration())
    let failed = await recorder.first(from: mark) {
      if case .failed = $0.state { true } else { false }
    }
    #expect(failed?.outsideStopGeneration == 1)
    #expect(failed.map(Self.isReady) == false)
    await manager.stop()
    #expect(await manager.currentLifecycle() == .stopped)
  }

  @Test("the state waiter gives up at its deadline instead of hanging")
  func waiterDeadlineControl() async {
    let recorder = StateRecorder()
    recorder.record(.stopped)
    let none = await recorder.first(from: 0, deadline: .milliseconds(200)) { _ in false }
    #expect(none == nil)
  }

  @Test("a crash still restarts once, then gives up; an explicit start resets that budget", arguments: crashEndings)
  func crashPolicyUnchanged(ending: Ending) async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }

    await manager.start(configuration: fixture.configuration())
    try #require(await manager.activeEndpoint() != nil, "fake server never became ready")
    let restarted = try await end(fixture, with: ending, recorder: recorder)
    #expect(restarted.map(Self.isReady) == true)
    #expect(try fixture.launches().count == 2)
    let gaveUp = try await end(fixture, with: ending, recorder: recorder)
    #expect(gaveUp == State(state: .failed(reason: "crashed_twice")))
    #expect(try fixture.launches().count == 2)

    await manager.start(configuration: fixture.configuration())
    #expect(await manager.activeEndpoint() != nil)
    let again = try await end(fixture, with: ending, recorder: recorder)
    #expect(again.map(Self.isReady) == true, "start() must reset the restart budget")
    await manager.stop()
  }

  @Test("an outside stop after a crash restart is still an outside stop, not a give-up")
  func outsideStopAfterCrashRestart() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }

    await manager.start(configuration: fixture.configuration())
    try #require(await manager.activeEndpoint() != nil, "fake server never became ready")
    let restarted = try await end(fixture, with: .signal(SIGALRM), recorder: recorder)
    #expect(restarted.map(Self.isReady) == true)
    // The identity names the stopped child (generation 2), not the next one.
    let stopped = try await end(fixture, with: .signal(SIGTERM), recorder: recorder)
    #expect(stopped == Self.outsideStop(2))
    // Recovery is an explicit activation, so it gets a fresh crash budget:
    // the next crash restarts once instead of giving up.
    await manager.start(configuration: fixture.configuration())
    #expect(await manager.activeEndpoint() != nil)
    let restartedAgain = try await end(fixture, with: .signal(SIGALRM), recorder: recorder)
    #expect(restartedAgain.map(Self.isReady) == true)
    await manager.stop()
  }

  @Test("a clean exit during startup is a startup failure, not an outside stop")
  func startupCleanExitStaysStartupFailure() async throws {
    let fixture = try Fixture()
    let manager = EGOneServerManager()
    let recorder = StateRecorder()
    defer { fixture.cleanup() }
    await manager.setStateObserver { recorder.record($0) }
    try Data().write(to: fixture.root.appendingPathComponent("exit_on_start"))

    await manager.start(configuration: fixture.configuration())
    let settled = await recorder.first(from: 0) { state in
      if case .failed = state.state { return true }
      return false
    }
    #expect(
      settled == State(state: .failed(reason: "crashed_during_start"))
        || settled == State(state: .failed(reason: "server_never_became_ready")))
    #expect(recorder.states.contains { $0.state == .stoppedOutside || $0.outsideStopGeneration != nil } == false)
    #expect(try fixture.launches().count == 1)
  }

  @Test("the coordinator restarts the stopped engine on its next run and tells only that engine")
  func coordinatorRecoveryIsProviderScoped() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    let egOne = StateRecorder()
    let s1Mini = StateRecorder()
    defer { fixture.cleanup() }
    await coordinator.setStateObserver(for: .egOne) { egOne.record($0) }
    await coordinator.setStateObserver(for: .s1Mini) { s1Mini.record($0) }
    let target = LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())

    await coordinator.transition(to: .run(target), intent: coordinator.claimIntent())
    try #require(await coordinator.endpoint(for: .egOne) != nil, "fake server never became ready")
    let mark = egOne.count
    kill(try fixture.lastPID(), SIGTERM)
    let stopped = await egOne.first(from: mark) { $0.state == .stoppedOutside }
    #expect(stopped == Self.outsideStop(1))
    #expect(await coordinator.endpoint(for: .egOne) == nil)
    #expect(await coordinator.lifecycle(for: .egOne) == Self.outsideStop(1))
    #expect(await coordinator.lifecycle(for: .s1Mini) == .stopped)
    #expect(await coordinator.residentModelForTesting == .egOne)

    await coordinator.transition(to: .run(target), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) != nil)
    #expect(try fixture.launches().count == 2)
    #expect(await coordinator.lifecycle(for: .egOne).outsideStopGeneration == nil)
    #expect(s1Mini.states == [.stopped], "the other engine heard nothing about this stop")
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  @Test("only a ready server's exit 0 or stop signal is an outside stop")
  func classificationAllowlist() {
    func record(
      _ phase: ChildProcessFailure.Phase, _ termination: ChildProcessFailure.Termination?,
      _ status: Int32?, role: ChildProcessFailure.Role = .server
    ) -> ChildProcessFailure {
      ChildProcessFailure(
        role: role, provider: .egOne, generation: 1, phase: phase,
        termination: termination, status: status, pid: 10,
        launchErrorCode: termination == nil ? 2 : nil)
    }
    for status in [SIGHUP, SIGINT, SIGKILL, SIGTERM] {
      #expect(EGOneServerManager.classify(record(.ready, .signal, status)) == .outsideStop)
    }
    #expect(EGOneServerManager.classify(record(.ready, .exit, 0)) == .outsideStop)
    for status in [SIGQUIT, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV, SIGUSR1, Int32(64)] {
      #expect(EGOneServerManager.classify(record(.ready, .signal, status)) == .crashPolicy)
    }
    for status: Int32 in [1, 2, 9, 15, 137] {
      #expect(EGOneServerManager.classify(record(.ready, .exit, status)) == .crashPolicy)
    }
    #expect(EGOneServerManager.classify(record(.starting, .exit, 0)) == .crashPolicy)
    #expect(EGOneServerManager.classify(record(.starting, .signal, SIGTERM)) == .crashPolicy)
    #expect(EGOneServerManager.classify(record(.ready, .exit, 0, role: .sweep)) == .crashPolicy)
    #expect(EGOneServerManager.classify(record(.ready, nil, nil)) == .crashPolicy)
  }
}
