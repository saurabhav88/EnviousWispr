import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline
import EnviousWisprAppKitTestSupport

@Suite("EG-1 adapter server lifecycle (#3105)", .serialized, .tags(.driftGuard, .localParallel))
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
      root = TestTemporaryDirectory.url.appendingPathComponent(
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
                # #4319: /slots answers from slots.json when the test wrote one, and only with
                # the launch's bearer.
                slots = os.path.join(root, 'slots.json')
                if self.path == '/slots' and os.path.exists(slots):
                    token = args[args.index('--api-key') + 1] if '--api-key' in args else None
                    if token and self.headers.get('Authorization') != f'Bearer {token}':
                        self.send_response(401)
                        self.end_headers()
                        return
                    body = open(slots, 'rb').read()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(body)
                    return
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
      await coordinator.acquireLease(for: .egOne, purpose: .inference)
    }
    func releaseLocalServerLease(_ lease: LocalPolishServerLease) async {
      await coordinator.releaseLease(lease)
    }
    func beginPolishAttempt(takeID: String?) async -> LocalPolishAttempt {
      let (admission, availability) = await coordinator.admitPolish(for: .egOne, takeID: takeID)
      return LocalPolishAttempt(
        admission: admission, endpoint: availability.endpoint, missedOutsideStop: nil,
        recoveryOutsideStop: nil)
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
@Suite("Local polish server stopped from outside (#3988)", .serialized, .tags(.productOutcome, .localParallel))
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
    await manager.setStateObserver { recorder.record($0.lifecycle) }

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
    await manager.setStateObserver { recorder.record($0.lifecycle) }
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
    await manager.setStateObserver { recorder.record($0.lifecycle) }
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
    await manager.setStateObserver { recorder.record($0.lifecycle) }

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
    await manager.setStateObserver { recorder.record($0.lifecycle) }

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
    await manager.setStateObserver { recorder.record($0.lifecycle) }
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
    await coordinator.setStateObserver(for: .egOne) { egOne.record($0.lifecycle) }
    await coordinator.setStateObserver(for: .s1Mini) { s1Mini.record($0.lifecycle) }
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

/// #3988: the take's engine restarts when a recording starts after something
/// outside the app stopped it. When this fails, the user's next dictations go
/// out without AI polish until they restart the app or open Settings.
@MainActor
@Suite("Local polish restarts when a recording starts (#3988)", .serialized, .tags(.productOutcome))
struct EGOneRecordingRecoveryTests {
  fileprivate typealias Fixture = EGOneAdapterLifecycleTests.Fixture
  typealias Lifecycle = EGOneServerManager.Lifecycle

  /// Lifecycles the runtime has APPLIED, in order, from its own completion
  /// signal. A waiter parks until a matching one lands, or gives up.
  @MainActor
  final class AppliedRecorder {
    typealias Match = @MainActor (Lifecycle) -> Bool
    private(set) var applied: [Lifecycle] = []
    private var waiters: [UUID: (match: Match, resume: CheckedContinuation<Lifecycle?, Never>)] = [:]

    func record(_ lifecycle: Lifecycle) {
      applied.append(lifecycle)
      for (id, waiter) in waiters where waiter.match(lifecycle) {
        waiters[id] = nil
        waiter.resume.resume(returning: lifecycle)
      }
    }

    func first(
      from index: Int, deadline: Duration = .seconds(20),
      where match: @escaping Match
    ) async -> Lifecycle? {
      if let hit = applied.dropFirst(index).first(where: match) { return hit }
      let id = UUID()
      return await withCheckedContinuation { continuation in
        waiters[id] = (match, continuation)
        Task { @MainActor [weak self] in
          // deadline-fallback: give up so the test fails by name instead of hanging
          try? await Task.sleep(for: deadline)
          self?.waiters.removeValue(forKey: id)?.resume.resume(returning: nil)
        }
      }
    }
  }

  /// A runtime over the shared fake server with an admitted model, the same
  /// rig as `EGOneAdapterLifecycleTests.adapterFaultSkipsBaseRepair`.
  private struct Rig {
    let fixture: Fixture
    let runtime: EGOneRuntime
    let coordinator: LocalPolishServerCoordinator
    let recorder: AppliedRecorder
    let cleanup: () -> Void
  }

  private func makeRig() async throws -> Rig {
    let fixture = try Fixture()
    let suite = "eg1-recording-recovery-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    let install = fixture.root.appendingPathComponent("base-install", isDirectory: true)
    let metadata = fixture.root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    try Data(count: 1000).write(to: install.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(to: install.appendingPathComponent("eg-1-00002-of-00002.gguf"))
    let controller = ModelDeliveryController(defaults: TestDefaults.suite(suite)!)
    let delivery = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: nil, defaults: store)
    try #require(await delivery.adoptIfPresent(), "fixture model was not admitted")
    let manifest = EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded",
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
    let coordinator = LocalPolishServerCoordinator()
    let runtime = EGOneRuntime(
      manifest: manifest, serverBinaryURL: fixture.binary, delivery: delivery,
      defaults: store, coordinator: coordinator)
    let recorder = AppliedRecorder()
    runtime.onLifecycleAppliedForTesting = { recorder.record($0) }
    runtime.isActiveProvider = { true }
    // A take holds the engine: activation boots, the inference probe is skipped.
    runtime.isSharedEngineBusy = { true }
    return Rig(
      fixture: fixture, runtime: runtime, coordinator: coordinator, recorder: recorder,
      cleanup: {
        store.removePersistentDomain(forName: suite)
        fixture.cleanup()
      })
  }

  private static func isReady(_ lifecycle: Lifecycle) -> Bool {
    if case .ready = lifecycle.state { return true }
    return false
  }

  private func bringUp(_ rig: Rig) async throws {
    let mark = rig.recorder.applied.count
    let activation = try #require(rig.runtime.activateAndProbe())
    await activation.value
    try #require(await rig.recorder.first(from: mark, where: Self.isReady) != nil, "never ready")
  }

  private func stopFromOutside(_ rig: Rig) async throws -> Lifecycle? {
    let mark = rig.recorder.applied.count
    kill(try rig.fixture.lastPID(), SIGTERM)
    return await rig.recorder.first(from: mark) { $0.state == .stoppedOutside }
  }

  @Test("a recording restarts only an engine stopped from outside, and the take's own engine only")
  func recoversOnlyOutsideStop() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    var pressure: OutsideStopContext.MemoryPressure? = .warning
    rig.runtime.memoryPressureLevel = { pressure }
    try await bringUp(rig)
    await rig.runtime.recordingStarted()?.value
    #expect(try rig.fixture.launches().count == 1, "a ready engine needs no recovery")
    #expect(rig.runtime.health == .yellow(reason: "ready_unchecked"))

    #expect(try await stopFromOutside(rig) != nil)
    #expect(
      rig.runtime.unresolvedOutsideStop
        == OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .warning))
    #expect(rig.runtime.health == .yellow(reason: "stopped_outside"))

    // Neither selected nor pinned by the take: a recording does not bring it back.
    rig.runtime.isActiveProvider = { false }
    #expect(rig.runtime.recordingStarted() == nil)
    // The user switched engines mid-take, but this take pinned this engine.
    rig.runtime.isPinnedInFlight = { true }

    // Park the restart: the recording hook must return before it finishes.
    try Data().write(to: rig.fixture.root.appendingPathComponent("hold_ready"))
    pressure = .critical
    let mark = rig.recorder.applied.count
    let recovery = try #require(rig.runtime.recordingStarted())
    let starting = await rig.recorder.first(from: mark) { $0.state == .starting }
    #expect(starting?.outsideStopGeneration == 1)
    #expect(
      rig.runtime.unresolvedOutsideStop?.memoryPressure == .warning,
      "one sample per stop: the recovery start must not resample")
    try Data().write(to: rig.fixture.root.appendingPathComponent("release_ready"))
    await recovery.value
    _ = await rig.recorder.first(from: mark, where: Self.isReady)
    #expect(rig.runtime.unresolvedOutsideStop == nil)
    #expect(
      rig.runtime.health == .yellow(reason: "ready_unchecked"),
      "a probe skipped for a take must not leave Starting, nor claim a check passed")
    #expect(try rig.fixture.launches().count == 2)

    // The other engine's runtime is not resident and is not touched.
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: rig.coordinator,
      provider: .s1Mini)
    s1Mini.isActiveProvider = { true }
    await s1Mini.recordingStarted()?.value
    #expect(try rig.fixture.launches().count == 2)
    #expect(await rig.coordinator.residentModelForTesting == .egOne)
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("recovery reads the coordinator, not a display copy that has not caught up")
  func recoveryReadsAuthoritativeLifecycle() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    try await bringUp(rig)
    let readyEndpoint = try #require(await rig.runtime.activeEndpoint())
    #expect(try await stopFromOutside(rig) != nil)
    // Stage the window where the manager has stopped but the runtime's copy
    // still says ready: the recording must still recover.
    rig.runtime.applyServerStateForTesting(.ready(readyEndpoint))
    let mark = rig.recorder.applied.count
    await rig.runtime.recordingStarted()?.value
    _ = await rig.recorder.first(from: mark, where: Self.isReady)
    #expect(try rig.fixture.launches().count == 2)
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("a recovery request made before a switch away does not boot the engine")
  func staleRecoveryAfterDeactivation() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    try await bringUp(rig)
    #expect(try await stopFromOutside(rig) != nil)
    let recovery = try #require(rig.runtime.recordingStarted())
    rig.runtime.deactivate()
    await recovery.value
    #expect(try rig.fixture.launches().count == 1)
  }

  @Test("an engine that loses the process is told so with the stop's own revision")
  func evictionNoticeCarriesStopRevision() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    var s1Config = fixture.configuration()
    s1Config.extraArguments = EGOneRuntime.engineArguments(for: .s1Mini)
    let eventsBox = OSAllocatedUnfairLock(initialState: [LocalPolishLifecycleEvent]())
    await coordinator.setStateObserver(for: .egOne) { event in
      eventsBox.withLock { $0.append(event) }
    }
    await coordinator.transition(
      to: .run(LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())),
      intent: coordinator.claimIntent())
    await coordinator.transition(
      to: .run(LocalPolishTarget(provider: .s1Mini, configuration: s1Config)),
      intent: coordinator.claimIntent())
    let events = eventsBox.withLock { $0 }
    let lastStop = try #require(events.last { $0.lifecycle == .stopped })
    let lastReady = try #require(events.last { if case .ready = $0.lifecycle.state { true } else { false } })
    #expect(lastStop.order > lastReady.order, "the stop notice sorts after the ready it ended")
    // Every revision this engine saw names exactly one lifecycle.
    let byOrder = Dictionary(grouping: events, by: \.order)
    #expect(byOrder.values.allSatisfy { group in group.allSatisfy { $0.lifecycle == group[0].lifecycle } })
    await coordinator.transition(to: .idle(.s1Mini), intent: coordinator.claimIntent())
  }

  @Test("a probe verdict lands only on the server it measured")
  func probeVerdictBoundToEndpoint() {
    let manifest = EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded",
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
    let runtime = EGOneRuntime(manifest: manifest, serverBinaryURL: nil, delivery: nil)
    #expect(runtime.activationBlockers.isEmpty, "manifest must not block health")
    runtime.applyInstallStateForTesting(.installed(version: nil))
    let first = EGOneEndpoint(port: 1, authToken: "a", contextTokens: 1)
    let replacement = EGOneEndpoint(port: 2, authToken: "b", contextTokens: 1)
    runtime.receive(LocalPolishLifecycleEvent(lifecycle: Lifecycle(state: .ready(first)), order: 1))
    runtime.acceptProbeResult(.green, for: first)
    #expect(runtime.health == .green)
    // The replacement's ready arrives with its intermediate events skipped.
    runtime.receive(
      LocalPolishLifecycleEvent(lifecycle: Lifecycle(state: .ready(replacement)), order: 9))
    #expect(runtime.health == .yellow(reason: "ready_unchecked"))
    // The old probe finishing late must not mark the replacement green.
    runtime.acceptProbeResult(.green, for: first)
    #expect(runtime.health == .yellow(reason: "ready_unchecked"))
  }

  /// The runtime's own ordering and pressure decisions, delivered directly so
  /// a late event can be staged. Both engines, one representative branch each.
  @Test("late events never bring back a resolved stop, and each stop is sampled once", arguments: [LLMProvider.egOne, .s1Mini])
  func lateEventsAndOneSamplePerStop(provider: LLMProvider) {
    let runtime = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, provider: provider)
    var samples = 0
    var pressure: OutsideStopContext.MemoryPressure? = .normal
    runtime.memoryPressureLevel = {
      samples += 1
      return pressure
    }
    let stop1 = Lifecycle(state: .stoppedOutside, outsideStopGeneration: 1)
    let ready = Lifecycle(state: .ready(EGOneEndpoint(port: 1, authToken: "t", contextTokens: 1)))
    runtime.receive(LocalPolishLifecycleEvent(lifecycle: stop1, order: 1))
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .starting, outsideStopGeneration: 1), order: 2))
    #expect(runtime.unresolvedOutsideStop == OutsideStopContext(provider: provider, generation: 1, memoryPressure: .normal))
    #expect(samples == 1)

    runtime.receive(LocalPolishLifecycleEvent(lifecycle: ready, order: 3))
    #expect(runtime.unresolvedOutsideStop == nil)
    runtime.receive(LocalPolishLifecycleEvent(lifecycle: stop1, order: 1))
    #expect(runtime.unresolvedOutsideStop == nil, "a late old stop must not resurrect it")

    pressure = nil
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .stoppedOutside, outsideStopGeneration: 2), order: 5))
    #expect(runtime.unresolvedOutsideStop?.memoryPressure == nil, "unknown stays unknown")
    #expect(samples == 2)
    runtime.receive(LocalPolishLifecycleEvent(lifecycle: stop1, order: 4))
    #expect(runtime.unresolvedOutsideStop?.generation == 2, "an older stop never overwrites a newer one")

    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .failed(reason: "server_never_became_ready"), outsideStopGeneration: 2),
        order: 6))
    #expect(runtime.unresolvedOutsideStop?.generation == 2, "a failed recovery keeps its diagnosis")
    #expect(samples == 2)
    runtime.receive(LocalPolishLifecycleEvent(lifecycle: .stopped, order: 7))
    #expect(runtime.unresolvedOutsideStop == nil, "teardown clears live recovery")
  }

  @Test("each memory level is recorded as observed", arguments: [
    OutsideStopContext.MemoryPressure.normal, .warning, .critical,
  ])
  func pressureLevels(level: OutsideStopContext.MemoryPressure) {
    let runtime = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil)
    runtime.memoryPressureLevel = { level }
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .stoppedOutside, outsideStopGeneration: 3), order: 1))
    #expect(runtime.unresolvedOutsideStop?.memoryPressure == level)
  }

  // MARK: - What a take freezes at the polish step (#3988 Chunk 3)

  private static let longTake =
    "so i was thinking we could maybe ship the new thing some time next week or so"

  private struct CannedPolisher: TranscriptPolisher {
    let output: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: output)
    }
  }

  private struct CancelledPolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw CancellationError()
    }
  }

  /// Forwards to the real runtime and announces each lease release, so a test
  /// can wait for the step's deferred release instead of guessing.
  @MainActor
  final class ReleaseSignal: EGOneLeaseProviding {
    let runtime: EGOneRuntime
    private(set) var releases = 0
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ runtime: EGOneRuntime) { self.runtime = runtime }
    func activeEndpoint() async -> EGOneEndpoint? { await runtime.activeEndpoint() }
    func acquireLocalServerLease() async -> LocalPolishLeaseAdmission {
      await runtime.acquireLocalServerLease()
    }
    func releaseLocalServerLease(_ lease: LocalPolishServerLease) async {
      await runtime.releaseLocalServerLease(lease)
      releases += 1
      waiter?.resume()
      waiter = nil
    }
    func beginPolishAttempt(takeID: String?) async -> LocalPolishAttempt {
      await runtime.beginPolishAttempt(takeID: takeID)
    }
    /// True once `count` releases happened, false at the deadline.
    func waitForReleases(_ count: Int) async -> Bool {
      if releases >= count { return true }
      await withCheckedContinuation { continuation in
        waiter = continuation
        Task { @MainActor [weak self] in
          // deadline-fallback: give up so the test fails by name instead of hanging
          try? await Task.sleep(for: .seconds(20))
          self?.waiter?.resume()
          self?.waiter = nil
        }
      }
      return releases >= count
    }
  }

  private func step(
    _ runtime: any EGOneLeaseProviding, polisher: (any TranscriptPolisher)? = nil
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .egOne
    step.llmModel = LLMProvider.egOneModelName
    step.egOneRuntime = runtime
    if let polisher { step.makeEGOnePolisher = { _ in polisher } }
    return step
  }

  /// One live take through the real runner. `between` runs after the step
  /// returns or throws and before the runner settles the take's outcome.
  private func take(
    _ step: LLMPolishStep, id takeID: String,
    between: (@MainActor () async -> Void)? = nil
  ) async throws -> TextProcessingRunResult {
    let probe = PolishSetupTakeProbe(
      takeID: takeID,
      context: PolishSetupTakeContext(
        provider: .egOne, model: LLMProvider.egOneModelName, configurationRevision: 1,
        episode: nil),
      classify: { _ in nil }, recordTerminalProblem: { _, _ in }, now: { .now })
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: { _, _, _, _, _, _ in }, recordPolishFailed: { _, _, _, _, _ in },
        recordPolishSkipped: { _, _, _ in }),
      timeoutExecutor: { _, operation in
        do {
          let result = try await operation()
          await between?()
          return result
        } catch {
          await between?()
          throw error
        }
      })
    return try await runner.run(
      rawText: Self.longTake, evidence: .locked("en"), targetAppName: nil, steps: [step],
      polishSetup: probe, takeID: takeID)
  }

  @Test("only the next live take is a stop's recovery take; imports and the other engine never use it up")
  func recoveryTakeIsTheNextLiveTake() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.runtime.memoryPressureLevel = { .warning }
    try await bringUp(rig)
    #expect(try await stopFromOutside(rig) != nil)
    let stop = OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .warning)

    // A file import or replay asks without a take; the other engine asks for its own.
    let importRead = await rig.runtime.beginPolishAttempt(takeID: nil)
    if case .granted(let lease) = importRead.admission {
      await rig.runtime.releaseLocalServerLease(lease)
    }
    #expect(importRead.missedOutsideStop == stop)
    #expect(importRead.recoveryOutsideStop == nil)
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: rig.coordinator,
      provider: .s1Mini)
    let other = await s1Mini.beginPolishAttempt(takeID: "s1-take")
    if case .granted(let lease) = other.admission { await s1Mini.releaseLocalServerLease(lease) }
    #expect(other.endpoint == nil)
    #expect(other.missedOutsideStop == nil)
    #expect(other.recoveryOutsideStop == nil)

    let first = try #require(try await take(step(rig.runtime), id: "take-1").polishTakeOutcome)
    #expect(first.result == .skippedSilently)
    #expect(first.outsideStopMiss == stop)
    #expect(first.outsideStopRecovery == stop)
    // The same take asking again keeps it; the next take is only a miss.
    let again = await rig.runtime.beginPolishAttempt(takeID: "take-1")
    if case .granted(let lease) = again.admission { await rig.runtime.releaseLocalServerLease(lease) }
    #expect(again.recoveryOutsideStop == stop)
    let second = try #require(try await take(step(rig.runtime), id: "take-2").polishTakeOutcome)
    #expect(second.outsideStopMiss == stop)
    #expect(second.outsideStopRecovery == nil)

    // Recovered: a later ordinary take polishes and carries nothing of the stop.
    let mark = rig.recorder.applied.count
    await rig.runtime.activateAndProbe()?.value
    _ = await rig.recorder.first(from: mark, where: Self.isReady)
    let ordinary = try await take(
      step(rig.runtime, polisher: CannedPolisher(output: "Polished.")), id: "take-3")
    let outcome = try #require(ordinary.polishTakeOutcome)
    #expect(outcome.result == .polished)
    #expect(outcome.outsideStopMiss == nil)
    #expect(outcome.outsideStopRecovery == nil)
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("the first take on a restarted engine is polished and carries the stop it recovered from")
  func successfulRecoveryTake() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.runtime.memoryPressureLevel = { .critical }
    try await bringUp(rig)
    #expect(try await stopFromOutside(rig) != nil)
    let mark = rig.recorder.applied.count
    await rig.runtime.activateAndProbe()?.value
    _ = await rig.recorder.first(from: mark, where: Self.isReady)

    let result = try await take(
      step(rig.runtime, polisher: CannedPolisher(output: "So I was thinking we could maybe ship the new thing sometime next week or so.")), id: "take-r")
    let outcome = try #require(result.polishTakeOutcome)
    #expect(outcome.result == .polished)
    #expect(outcome.outsideStopMiss == nil)
    #expect(
      outcome.outsideStopRecovery
        == OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .critical))
    #expect(
      result.context.polishedText
        == "So I was thinking we could maybe ship the new thing sometime next week or so.")
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("the engine coming back between the miss and the take's result does not change what the take met")
  func readinessBetweenMissAndSettlement() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    var pressure: OutsideStopContext.MemoryPressure = .normal
    rig.runtime.memoryPressureLevel = { pressure }
    try await bringUp(rig)
    #expect(try await stopFromOutside(rig) != nil)

    // The recording's recovery is parked before ready, so the take misses.
    try Data().write(to: rig.fixture.root.appendingPathComponent("hold_ready"))
    let recovery = try #require(rig.runtime.recordingStarted())
    let result = try await take(step(rig.runtime), id: "take-m") {
      // Between the miss and settlement: the engine comes back and pressure rises.
      let mark = rig.recorder.applied.count
      try? Data().write(to: rig.fixture.root.appendingPathComponent("release_ready"))
      await recovery.value
      _ = await rig.recorder.first(from: mark, where: Self.isReady)
      pressure = .critical
    }
    let outcome = try #require(result.polishTakeOutcome)
    #expect(Self.isReady(await rig.runtime.serverCoordinator.lifecycle(for: .egOne)))
    #expect(outcome.result == .skippedSilently)
    #expect(
      outcome.outsideStopMiss
        == OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .normal))
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("a cancelled polish releases its hold, and a reused step starts each take clean")
  func cancellationReleasesAndReuseIsClean() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    try await bringUp(rig)
    #expect(try await stopFromOutside(rig) != nil)
    let signal = ReleaseSignal(rig.runtime)
    let reused = step(signal, polisher: CancelledPolisher())
    let missed = try await take(reused, id: "take-c1")
    #expect(missed.polishTakeOutcome?.outsideStopMiss != nil)
    #expect(await signal.waitForReleases(1), "the miss took a hold and must release it")

    let mark = rig.recorder.applied.count
    await rig.runtime.activateAndProbe()?.value
    _ = await rig.recorder.first(from: mark, where: Self.isReady)
    let cancelled = try await take(reused, id: "take-c2")
    let outcome = try #require(cancelled.polishTakeOutcome)
    #expect(outcome.result == .cancelled)
    #expect(outcome.outsideStopMiss == nil, "the reused step kept nothing from the last take")
    #expect(outcome.outsideStopRecovery == nil)
    #expect(await signal.waitForReleases(2), "a cancelled polish must release its hold")
    #expect(await rig.coordinator.hasLease(for: .egOne) == false)
    await rig.coordinator.transition(to: .idle(.egOne), intent: rig.coordinator.claimIntent())
  }

  @Test("a stop the main actor has not accepted yet is frozen with unknown pressure, never resampled")
  func unacceptedStopHasUnknownPressure() {
    let runtime = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil)
    var samples = 0
    runtime.memoryPressureLevel = {
      samples += 1
      return .critical
    }
    #expect(runtime.outsideStopContext(generation: 7).memoryPressure == nil)
    #expect(samples == 0)
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .stoppedOutside, outsideStopGeneration: 7), order: 1))
    // Accepted once: later reads reuse that sample, also after the stop resolves.
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: Lifecycle(state: .ready(EGOneEndpoint(port: 1, authToken: "t", contextTokens: 1))),
        order: 2))
    #expect(runtime.outsideStopContext(generation: 7).memoryPressure == .critical)
    #expect(samples == 1)
  }

  @Test("the applied-lifecycle waiter gives up at its deadline")
  func waiterDeadlineControl() async {
    let recorder = AppliedRecorder()
    recorder.record(.stopped)
    let none = await recorder.first(from: 0, deadline: .milliseconds(200)) { _ in false }
    #expect(none == nil)
  }
}

// MARK: - #4319: a summary's reservation waits for a health probe already running

/// A probe connector that parks until the test lets it answer, and says when it has started.
private actor ParkedProbe {
  private var started: CheckedContinuation<Void, Never>?
  private var hasStarted = false
  private var release: CheckedContinuation<Void, Never>?
  private var released = false

  func enter() async {
    hasStarted = true
    started?.resume()
    started = nil
    guard !released else { return }
    await withCheckedContinuation { release = $0 }
  }

  /// True once the probe has started, false at the deadline.
  func waitUntilStarted() async -> Bool {
    guard !hasStarted else { return true }
    await withCheckedContinuation { continuation in
      started = continuation
      Task {
        // deadline-fallback: give up so the test fails by name instead of hanging
        try? await Task.sleep(for: .seconds(20))
        await self.expireStartWait()
      }
    }
    return hasStarted
  }

  private func expireStartWait() {
    started?.resume()
    started = nil
  }

  func letAnswer() {
    released = true
    release?.resume()
    release = nil
  }
}

private struct ParkedProbePolisher: TranscriptPolisher {
  let gate: ParkedProbe
  func polish(
    text: String, instructions: PolishInstructions, config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    await gate.enter()
    return LLMResult(polishedText: "Move the meeting to Friday.")
  }
  func polish(
    envelope: PromptEnvelope, config: LLMProviderConfig, onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    await gate.enter()
    return LLMResult(polishedText: "Move the meeting to Friday.")
  }
}

extension EGOneAdapterLifecycleTests {
  @Test("a summary's reservation waits for a health probe that is already running (#4319)")
  func reservationDrainsAdmittedProbe() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(
      to: .run(LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())),
      intent: coordinator.claimIntent())
    let gate = ParkedProbe()
    let spec = EGOneServerManager.ProbeSpec(
      provider: .egOne, modelID: "eg-1", makeConnector: { _ in ParkedProbePolisher(gate: gate) })
    let probing = Task {
      await coordinator.probeHealth(.egOne, promptFamily: .egOneEnvelope, spec: spec)
    }
    defer { probing.cancel() }
    guard await gate.waitUntilStarted() else {
      await gate.letAnswer()
      Issue.record("the health probe never reached the server")
      await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
      return
    }
    let reserving = Task { await coordinator.reserveForSummary(.egOne) }
    let waiting = await coordinator.awaitDrainWaitForTesting()
    #expect(waiting, "the reservation waits for the running probe")
    #expect(await coordinator.isReservedForSummary(), "admission closed while the probe runs")
    await gate.letAnswer()
    _ = await probing.value
    guard case .granted(let reservation) = await reserving.value else {
      Issue.record("the reservation was not granted after the probe finished")
      return
    }
    await coordinator.releaseSummaryReservation(reservation)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }
}

extension EGOneAdapterLifecycleTests {
  @MainActor
  @Test("activateForSummary loads EG-1 for the summary's reservation and hands back its endpoint (#4319)")
  func activateForSummaryLoadsOwnedServer() async throws {
    let fixture = try Fixture()
    let suite = "eg1-summary-activation-\(UUID().uuidString)"
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
    try Data(count: 1000).write(to: install.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(to: install.appendingPathComponent("eg-1-00002-of-00002.gguf"))
    let controller = ModelDeliveryController(defaults: TestDefaults.suite(suite)!)
    let delivery = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: nil, defaults: store)
    let manifest = EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded",
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
    let coordinator = LocalPolishServerCoordinator()
    let runtime = EGOneRuntime(
      manifest: manifest, serverBinaryURL: fixture.binary, delivery: delivery,
      defaults: store, coordinator: coordinator)

    guard case .granted(let reservation) = await runtime.reserveServerForSummary() else {
      Issue.record("an idle server refused the summary's reservation")
      return
    }
    let endpoint = await runtime.activateForSummary(reservation)
    #expect(endpoint != nil, "the summary's load came up")
    #expect(await coordinator.residentModelForTesting == .egOne)
    #expect(await runtime.activeEndpoint() == endpoint, "the endpoint is the server it owns")
    // Anyone else's admission is still refused while the summary holds it.
    guard case .changing = await runtime.acquireLocalServerLease() else {
      Issue.record("a word check was admitted during the summary")
      return
    }
    await runtime.releaseServerReservation(reservation)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == nil)
  }
}

#if DEBUG
  extension EGOneAdapterLifecycleTests {
    static let processingSlots = Data(
      """
      [{"id":0,"is_processing":false,"n_ctx":4096,"speculative":false},
       {"id":1,"id_task":7,"is_processing":true,"n_ctx":4096,"speculative":false,
        "params":{"prompt":"SECRET TRANSCRIPT TEXT"},
        "next_token":[{"has_next_token":true,"n_remain":1101,"n_decoded":399}]}]
      """.utf8)

    @Test("the DEBUG slot reader reads only whitelisted fields from the owned server, with its bearer (#4319)")
    func slotObservationReadsOwnedServer() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try Self.processingSlots.write(to: fixture.root.appendingPathComponent("slots.json"))
      let coordinator = LocalPolishServerCoordinator()
      await coordinator.transition(
        to: .run(LocalPolishTarget(provider: .egOne, configuration: fixture.configuration())),
        intent: coordinator.claimIntent())
      guard case .observed(let snapshot) = await coordinator.observeSlotsForDebug(for: .egOne)
      else {
        Issue.record("the owned server's slots were not observed")
        return
      }
      #expect(snapshot.slots.count == 2)
      #expect(snapshot.slots[0] == .init(id: 0, isProcessing: false, taskID: nil, decodedTokens: nil, remainingTokens: nil))
      #expect(snapshot.slots[1] == .init(id: 1, isProcessing: true, taskID: 7, decodedTokens: 399, remainingTokens: 1101))
      #expect(String(describing: snapshot).contains("SECRET") == false, "no request content")
      // Another model's slots are not this model's.
      #expect(await coordinator.observeSlotsForDebug(for: .s1Mini) == .unavailable)
      // A control request: still answered while a summary holds the server, and admits nothing.
      guard case .granted(let reservation) = await coordinator.reserveForSummary(.egOne) else {
        Issue.record("reservation refused")
        return
      }
      guard case .observed = await coordinator.observeSlotsForDebug(for: .egOne) else {
        Issue.record("the slot reader was held back by the summary")
        return
      }
      #expect(await coordinator.hasLease(for: .egOne) == false)
      await coordinator.releaseSummaryReservation(reservation)
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("slots.json"))
      #expect(await coordinator.observeSlotsForDebug(for: .egOne) == .unsupported)
      await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
      #expect(await coordinator.observeSlotsForDebug(for: .egOne) == .unavailable)
    }

    @Test("a slot answer from a replaced server is never reported, and errors stay errors (#4319)")
    func slotObservationFailuresStayHonest() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manager = EGOneServerManager()
      #expect(await manager.observeSlotsForDebug() == .unavailable, "no server is not idle")
      await manager.start(configuration: fixture.configuration())
      let replaced = await manager.observeSlotsForDebug { request in
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.url?.path == "/slots")
        await manager.stop()
        let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Self.processingSlots, ok)
      }
      #expect(replaced == .replaced)
      await manager.start(configuration: fixture.configuration())
      #expect(
        await manager.observeSlotsForDebug { _ in throw URLError(.timedOut) } == .transportFailed)
      #expect(
        await manager.observeSlotsForDebug { request in
          (Data("not json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        } == .malformed)
      #expect(
        await manager.observeSlotsForDebug { request in
          (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        } == .httpStatus(500))
      await manager.stop()
    }
  }
#endif
