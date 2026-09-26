import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

@Suite("EG-1 adapter server lifecycle (#3105)", .serialized, .tags(.driftGuard))
struct EGOneAdapterLifecycleTests {
  /// A tiny HTTP server that records argv before answering /health. An
  /// adapter-failure marker makes only --lora launches exit before readiness.
  private struct Fixture {
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
        import http.server, json, os, sys, time
        args = sys.argv[1:]
        root = os.path.dirname(os.path.realpath(sys.argv[0]))
        adapter_root = os.path.dirname(args[args.index('--lora') + 1]) if '--lora' in args else None
        with open(os.path.join(root, 'launches.jsonl'), 'a') as log:
            log.write(json.dumps(args) + '\n')
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

    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  @MainActor
  @Test("provider is read for every boot configuration; S1 never reads it")
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
    let s1 = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, provider: .s1Mini,
      learnedWordAdapterProvider: {
        Issue.record("S1 consulted EG-1 adapter provider")
        return available
      })
    let s1Config = await s1.makeServerConfiguration(
      serverBinaryURL: binary, modelURL: model, contextTokens: 4096)
    #expect(s1Config.learnedWordAdapterURL == nil)
    #expect(s1Config.extraArguments == EGOneRuntime.engineArguments(for: .s1Mini))
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
      Array(try fixture.launches()[0].suffix(6)) == EGOneRuntime.engineArguments(for: .egOne))
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
    #expect(launches[0].contains("--lora"))
    #expect(!launches[1].contains("--lora"))
    await manager.stop()
  }

  @MainActor
  @Test("adapter startup fault does not call base shard repair")
  func adapterFaultSkipsBaseRepair() async throws {
    let fixture = try Fixture()
    let suite = "eg1-adapter-repair-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
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
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!)
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
    #expect(await coordinator.checkerFailureReason() == nil)

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
