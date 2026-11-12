import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprLlamaEngine
@testable import EnviousWisprLocalPolish
@testable import EnviousWisprModelDelivery

/// #4493 R2: the bundled `llama-server` with S1-mini, started by the process manager on the
/// private socket. When this fails, S1-mini polish is reachable on a network port or without
/// the bearer, the bearer is readable in the process list, or the server outlives an app that
/// let go of it (or leaves a crash report when it stops).
@Suite("Bundled llama-server on the private socket (#4493 R2)", .serialized, .tags(.productOutcome))
struct LlamaServerRealBoundaryTests {
  /// The `llama-server` inside the Dev app the build puts beside the test bundle; exactly one.
  static var serverCandidates: [URL] {
    guard let testBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") })
    else { return [] }
    let products = testBundle.bundleURL.deletingLastPathComponent()
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))
      ?? []
    return entries.filter { $0.pathExtension == "app" }
      .map { $0.appendingPathComponent("Contents/Resources/llama-server") }
      .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// S1-mini's weights: `EW_S1MINI_GGUF`, else the installed app's copy.
  static var s1MiniModel: URL {
    if let path = ProcessInfo.processInfo.environment["EW_S1MINI_GGUF"] {
      return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/EnviousWispr/Models/s1-mini/s1-mini-1.0.gguf")
  }

  static var canRun: Bool {
    serverCandidates.count == 1 && FileManager.default.fileExists(atPath: s1MiniModel.path)
  }

  /// The children of this test process that run `executable`. `pgrep` exits 1 when none
  /// matches; any other failure is an error.
  static func children(running executable: URL) throws -> [Int32] {
    let listed = try HelperProcessProbe.run("/usr/bin/pgrep", ["-P", String(getpid())])
    let lines = listed.text.split(separator: "\n")
    try #require(
      listed.status == 0 || (listed.status == 1 && lines.isEmpty), "pgrep failed: \(listed.status)")
    return try lines.compactMap { Int32($0) }.filter {
      try HelperProcessProbe.executable($0) == executable.path
    }
  }

  static func configuration(server: URL) -> LocalPolishProcessManager.Configuration {
    let identity = ModelIdentity(
      family: .s1Mini, name: "s1-mini", revision: "installed", variant: "gguf",
      runtimeABI: "llama")
    var configuration = LlamaServerEngine().makeLaunchConfiguration(
      .s1Mini, identity, server, s1MiniModel, 4096, nil)
    configuration.readinessBudgetSeconds = 120
    return configuration.inLaunchHome(TestLaunchHome.make().home)
  }

  @Test(
    "R2: llama-server with S1-mini serves only on its socket, guards /slots with the bearer, keeps the bearer out of its process list, and stops itself when its pipe writer closes",
    .tags(.realBoundary), .realBoundaryRun, .enabled(if: LlamaServerRealBoundaryTests.canRun))
  func theBundledServerIsPrivateAndStopsItself() async throws {
    let server = try #require(Self.serverCandidates.first)
    let reportsBefore = try HelperProcessProbe.crashReports("llama-server")
    let manager = LocalPolishProcessManager()
    defer { manager.terminateImmediately() }
    let records = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    let ended = BoundedWait.Signal()
    await manager.setProcessFailureObserver { record in
      records.withLock { $0.append(record) }
      ended.fire()
    }
    await manager.start(configuration: Self.configuration(server: server))
    let state = await manager.currentLifecycle().state
    let endpoint = try #require(await manager.activeEndpoint(), "llama-server is \(state)")
    let pids = try Self.children(running: server)
    try #require(pids.count == 1, "children running llama-server: \(pids)")
    let pid = pids[0]

    // Its /health is public (as today); /slots needs the bearer.
    let health = try await LocalPolishHelperExchange.perform(
      .init(method: .get, path: "/health", timeout: .seconds(10)), endpoint)
    #expect(health.status == 200)
    let slots = try await LocalPolishHelperExchange.perform(
      .init(method: .get, path: "/slots", timeout: .seconds(10)), endpoint)
    #expect(slots.status == 200)
    let refused = try await LocalPolishHelperClient.perform(
      .init(method: .get, path: "/slots", timeout: .seconds(10)),
      at: LocalPolishHelperAddress(socketPath: endpoint.socketPath, authToken: "wrong"))
    #expect(refused.status == 401)
    let chat = try JSONSerialization.data(withJSONObject: [
      "messages": [["role": "user", "content": "Say hello."]], "max_tokens": 8,
      "temperature": 0,
    ])
    let answer = try await LocalPolishTransport.send(endpoint: endpoint, body: chat)
    let parsed = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
    let message = (parsed["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
    let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(!(content ?? "").isEmpty, "no assistant text in the answer")

    #expect(try HelperProcessProbe.tcpSockets(pid, socketPath: endpoint.socketPath).isEmpty)
    let seen = try HelperProcessProbe.commandOrEnvironmentContains(pid, endpoint.authToken)
    #expect(!seen.command, "the bearer is in llama-server's command line")
    #expect(!seen.environment, "the bearer is in llama-server's environment")

    // Writer closed alone, as an app death closes it: the server stops itself, cleanly.
    #expect(await manager.closeLaunchWriterForTesting())
    try await BoundedWait.until(ended, deadline: .seconds(30))
    let record = try #require(records.withLock { $0.first })
    #expect(record.termination == .exit && record.status == 0, "\(record)")
    #expect(try HelperProcessProbe.executable(pid) == nil)
    #expect(try HelperProcessProbe.crashReports("llama-server").subtracting(reportsBefore).isEmpty)
  }

  @Test(
    "R2: a deliberate stop ends llama-server with no failure record and no crash report",
    .tags(.realBoundary), .realBoundaryRun, .enabled(if: LlamaServerRealBoundaryTests.canRun))
  func aDeliberateStopIsClean() async throws {
    let server = try #require(Self.serverCandidates.first)
    let reportsBefore = try HelperProcessProbe.crashReports("llama-server")
    let manager = LocalPolishProcessManager()
    defer { manager.terminateImmediately() }
    let records = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    await manager.setProcessFailureObserver { record in records.withLock { $0.append(record) } }
    await manager.start(configuration: Self.configuration(server: server))
    try #require(await manager.activeEndpoint() != nil)
    let pids = try Self.children(running: server)
    try #require(pids.count == 1, "children running llama-server: \(pids)")
    let child = try #require(await manager.launchProcessForTesting())
    try #require(child.processIdentifier == pids[0])

    await manager.stop()
    let exited = BoundedWait.Signal()
    DispatchQueue.global().async {
      child.waitUntilExit()
      exited.fire()
    }
    try await BoundedWait.until(exited, deadline: .seconds(15))
    try #require(!child.isRunning, "llama-server still runs after stop")
    #expect(child.terminationReason == .exit, "\(child.terminationReason.rawValue)")
    #expect(child.terminationStatus == 0, "\(child.terminationStatus)")
    #expect(try HelperProcessProbe.executable(pids[0]) == nil)
    #expect(records.withLock { $0 }.isEmpty, "\(records.withLock { $0 })")
    #expect(try HelperProcessProbe.crashReports("llama-server").subtracting(reportsBefore).isEmpty)
  }
}
