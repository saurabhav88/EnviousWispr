import EnviousWisprCore
import Foundation
import os

/// Endpoint of a ready local inference server: where to send requests and
/// the per-launch bearer token that authenticates the app to it.
public struct EGOneEndpoint: Sendable, Equatable {
  public let port: UInt16
  public let authToken: String
  /// Context window the server was launched with — the polish step's
  /// input-size preflight reads this so an over-budget dictation skips
  /// whole (silent raw fallback), never truncates silently.
  public let contextTokens: Int
  public var chatCompletionsURL: URL {
    URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
  }
}

/// Health of the EG-1 limb as shown in settings. ADVISORY DISPLAY ONLY —
/// the pipeline never reads it (the polish call at dictation time is the
/// truth; a stale green can never mask a dead server).
public enum EGOneHealth: Sendable, Equatable {
  case green
  case yellow(reason: String)
  case red(reason: String)
}

/// Spawns, monitors, and terminates the local polish inference server (#1271).
///
/// Single authority for server RUNTIME (process lifecycle + health).
/// Distribution (download/verify/admit) is the shared
/// `EnviousWisprModelDelivery` engine's concern, reached via
/// `EGOneDeliveryAdapter` (#1348 Phase 3, formerly `EGOneModelStore`).
///
/// Heart & Limbs: this whole subsystem is a limb. The server is a separate
/// process (a crash can never take the app down), it is terminated under
/// critical memory pressure (it may never starve heart-path ASR — the
/// #286/#295 Ollama dual-residency incident is the precedent), and every
/// failure surfaces to dictation as a silent raw-text fallback.
public actor EGOneServerManager {
  public enum ServerState: Sendable, Equatable {
    case stopped
    case starting
    case ready(EGOneEndpoint)
    /// Terminated by the memory-pressure source; reactivation is a user
    /// action (settings) or next launch.
    case pausedForMemoryPressure
    /// Spawn or crash-restart failed twice this session.
    case failed(reason: String)
  }

  /// Filesystem + process seams, injectable so lifecycle tests can run a
  /// fake server binary (plan §11: spawn/crash/restart-once/port-conflict/
  /// memory-pressure tests without a 2.7 GB model).
  public struct Configuration: Sendable {
    public var serverBinaryURL: URL
    public var modelURL: URL
    public var contextTokens: Int
    /// Extra launch arguments appended after the standard set.
    public var extraArguments: [String]
    /// Seconds to wait for the HTTP surface after spawn (model load takes
    /// seconds on a real machine). Tests shrink this so a fake server that
    /// never binds fails fast instead of stalling the suite.
    public var readinessBudgetSeconds: Int

    public init(
      serverBinaryURL: URL, modelURL: URL, contextTokens: Int,
      extraArguments: [String] = [], readinessBudgetSeconds: Int = 60
    ) {
      self.serverBinaryURL = serverBinaryURL
      self.modelURL = modelURL
      self.contextTokens = contextTokens
      self.extraArguments = extraArguments
      self.readinessBudgetSeconds = readinessBudgetSeconds
    }
  }

  private(set) var state: ServerState = .stopped
  /// Monotonic spawn token (#1271 matrix gap 1): `stop()` / memory-pressure
  /// pause / a newer spawn bump it, so a spawn whose readiness await resumes
  /// AFTER its generation ended can neither tear down a successor's process
  /// nor promote/fail over the successor's `.starting` state. (Same race
  /// shape as the crash-restart guard — this covers the normal start path.)
  private var launchGeneration = 0
  private var process: Process? {
    didSet {
      let current = process
      quitKillBox.withLock { $0 = current }
    }
  }
  private var restartedOnceThisGeneration = false
  private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
  private var onStateChange: (@Sendable (ServerState) -> Void)?
  /// Mirror of `process` reachable WITHOUT actor isolation, exclusively for
  /// the synchronous app-quit path (#1271 Codex r1 P1): `Process` children
  /// are NOT killed when the parent exits, and `applicationWillTerminate`
  /// cannot await into this actor.
  private let quitKillBox = OSAllocatedUnfairLock<Process?>(initialState: nil)

  public init() {}

  public func setStateObserver(_ observer: @escaping @Sendable (ServerState) -> Void) {
    onStateChange = observer
    observer(state)
  }

  private func transition(to newState: ServerState) {
    state = newState
    onStateChange?(newState)
  }

  /// Current endpoint iff ready. Fast, never boots the server — dictation
  /// during boot silently falls back (never blocks paste).
  public func activeEndpoint() -> EGOneEndpoint? {
    if case .ready(let endpoint) = state { return endpoint }
    return nil
  }

  // MARK: - Lifecycle

  /// Start the server. Idempotent behind actor isolation: no-ops while
  /// starting or ready. Resets the restart-once latch (explicit user or
  /// launch activation = a fresh generation).
  public func start(configuration: Configuration) async {
    switch state {
    case .starting, .ready: return
    case .stopped, .pausedForMemoryPressure, .failed: break
    }
    restartedOnceThisGeneration = false
    await spawn(configuration: configuration)
  }

  public func stop() {
    launchGeneration += 1
    tearDownProcess()
    transition(to: .stopped)
  }

  /// Synchronous kill for `applicationWillTerminate` — actor state is left
  /// as-is (the app is exiting); the only job is not orphaning the child.
  public nonisolated func terminateImmediately() {
    quitKillBox.withLock { proc in
      if let proc, proc.isRunning {
        proc.terminationHandler = nil
        proc.terminate()
      }
      proc = nil
    }
  }

  /// Kill any STALE server left by a crashed previous instance (a crash
  /// bypasses `applicationWillTerminate`, orphaning a multi-GB child).
  /// Exact-path match: only processes running OUR bundled binary die; runs
  /// BEFORE this generation's spawn so it can never hit our own child.
  static func killStaleServers(binaryPath: String) {
    let sweep = Process()
    sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    // pkill -f is an unanchored REGEX over the whole command line — escape
    // metacharacters and anchor to argv[0] so only processes actually
    // RUNNING this binary die, never one whose command line merely mentions
    // the path (e.g. codesign signing it mid-build) (#1271 seam review).
    let escaped = NSRegularExpression.escapedPattern(for: binaryPath)
    sweep.arguments = ["-f", "^\(escaped)( |$)"]
    sweep.standardOutput = FileHandle.nullDevice
    sweep.standardError = FileHandle.nullDevice
    try? sweep.run()
    sweep.waitUntilExit()
  }

  /// Ordered orphan reap for paths where spawn will NOT run (EG-1 selected
  /// but model missing / manifest blocked, or EG-1 not selected at all).
  /// Actor-isolated AND idle-gated, so it can never kill a child this
  /// manager owns or is mid-starting — callable from anywhere without the
  /// sweep-vs-fresh-spawn ordering concerns of a detached pkill (#1271 r11;
  /// retires the r10 race class rather than patching another call site).
  func reapOrphansIfIdle(binaryPath: String) {
    switch state {
    case .stopped, .failed, .pausedForMemoryPressure:
      Self.killStaleServers(binaryPath: binaryPath)
    case .starting, .ready:
      break
    }
  }

  private func tearDownProcess() {
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
    if let process, process.isRunning {
      process.terminationHandler = nil
      process.terminate()
    }
    process = nil
  }

  private func spawn(configuration: Configuration) async {
    launchGeneration += 1
    let generation = launchGeneration
    transition(to: .starting)

    guard FileManager.default.fileExists(atPath: configuration.serverBinaryURL.path) else {
      transition(to: .failed(reason: "server_binary_missing"))
      return
    }
    // A previous app instance that CRASHED (bypassing applicationWillTerminate)
    // may have orphaned its server; reap it before spawning ours.
    Self.killStaleServers(binaryPath: configuration.serverBinaryURL.path)
    guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
      transition(to: .failed(reason: "model_missing"))
      return
    }

    // App-chosen free port (bind-probe then release). llama-server's
    // `--port 0` self-report is NOT assumed (plan §11 port strategy).
    guard let port = Self.findFreePort() else {
      transition(to: .failed(reason: "no_free_port"))
      return
    }
    let token = UUID().uuidString + UUID().uuidString

    let proc = Process()
    proc.executableURL = configuration.serverBinaryURL
    proc.arguments =
      [
        "-m", configuration.modelURL.path,
        "--host", "127.0.0.1",
        "--port", String(port),
        "-c", String(configuration.contextTokens),
        "--api-key", token,
      ] + configuration.extraArguments
    // The server's stdout/stderr are noise for us; route to null so the
    // pipe buffers can never fill and wedge the child.
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    proc.terminationHandler = { [weak self] _ in
      Task { [weak self] in
        await self?.handleTermination(configuration: configuration, generation: generation)
      }
    }

    do {
      try proc.run()
    } catch {
      transition(to: .failed(reason: "spawn_failed"))
      await AppLogger.shared.log(
        "EG-1 server spawn failed: \(error.localizedDescription)",
        level: .info, category: "LLM")
      return
    }
    process = proc
    installMemoryPressureSource()

    let endpoint = EGOneEndpoint(
      port: port, authToken: token, contextTokens: configuration.contextTokens)
    // Wait for the HTTP surface to come up (model load can take seconds;
    // poll /health until 200, the process dying, or budget exhausted).
    let healthy = await Self.awaitServerUp(
      endpoint: endpoint,
      budgetSeconds: configuration.readinessBudgetSeconds,
      processIsAlive: { [weak proc] in proc?.isRunning ?? false }
    )
    // A start/stop/start interleave leaves state `.starting` for the NEW
    // spawn when THIS spawn's await resumes — the `.starting` check alone
    // cannot distinguish generations, so a stale failure here would tear
    // down the successor's process (#1271 matrix gap 1).
    guard generation == launchGeneration else { return }
    guard healthy else {
      // The termination handler may have already routed a startup death to
      // `.failed(crashed_during_start)`; do not overwrite its diagnosis.
      if case .starting = state {
        tearDownProcess()
        transition(to: .failed(reason: "server_never_became_ready"))
      }
      return
    }
    // Same race on the success side: only a still-starting spawn may
    // promote to ready.
    guard case .starting = state else { return }
    transition(to: .ready(endpoint))
    await AppLogger.shared.log(
      "EG-1 server ready on 127.0.0.1:\(port)", level: .info, category: "LLM")
  }

  private func handleTermination(configuration: Configuration, generation: Int) async {
    // A callback QUEUED for an old child can land after stop()+start()
    // moved this manager to a fresh generation — it must not nil the new
    // process, mark the new launch crashed, or trigger a rogue restart
    // (#1271 Codex r12; nulling the handler only covers teardowns WE
    // initiate, not an already-queued crash callback).
    guard generation == launchGeneration else { return }
    // Deliberate teardown paths null the handler first; reaching here
    // means the child died underneath us.
    guard case .ready = state else {
      if case .starting = state { transition(to: .failed(reason: "crashed_during_start")) }
      return
    }
    process = nil
    if restartedOnceThisGeneration {
      transition(to: .failed(reason: "crashed_twice"))
      await AppLogger.shared.log(
        "EG-1 server crashed twice this session — staying down", level: .info, category: "LLM")
      return
    }
    restartedOnceThisGeneration = true
    // Go honest IMMEDIATELY: the child is dead, so `.ready` must not
    // survive the await below — `activeEndpoint()` would hand out a dead
    // endpoint and `start()` would no-op against a lie (#1271 seam review).
    transition(to: .starting)
    await AppLogger.shared.log(
      "EG-1 server crashed — restarting once", level: .info, category: "LLM")
    // Actor reentrancy: `stop()` / memory-pressure pause / a fresh `start()`
    // may have run during the await above — only the crashed generation
    // (still `.starting`, no new process; this handler nulled `process`
    // before the await) may restart, or a deactivated provider gets its
    // multi-GB server resurrected (#1271 Codex r4).
    guard case .starting = state, process == nil else { return }
    await spawn(configuration: configuration)
  }

  /// The limb may never starve the heart: on CRITICAL memory pressure the
  /// server is terminated and the provider silently skips until the user
  /// reactivates (or next launch).
  private func installMemoryPressureSource() {
    memoryPressureSource?.cancel()
    let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical)
    source.setEventHandler { [weak self] in
      Task { [weak self] in await self?.pauseForMemoryPressure() }
    }
    source.activate()
    memoryPressureSource = source
  }

  private func pauseForMemoryPressure() async {
    // `.starting` is INCLUDED: model load is exactly when the child's
    // footprint ramps, so critical pressure mid-start must kill it too
    // (#1271 Codex r6). The in-flight spawn self-heals: awaitServerUp bails
    // when the process dies, and its resume is generation-gated.
    switch state {
    case .ready, .starting: break
    case .stopped, .pausedForMemoryPressure, .failed: return
    }
    launchGeneration += 1
    tearDownProcess()
    transition(to: .pausedForMemoryPressure)
    await AppLogger.shared.log(
      "EG-1 server paused: critical memory pressure", level: .info, category: "LLM")
  }

  // MARK: - Health probe

  /// Real activation test: a FIXED filler-and-self-correction transcript
  /// through the real prompt path; GREEN requires the expected
  /// TRANSFORMATION (contains "Friday", drops "um"), not merely HTTP 200 —
  /// a model that echoes raw text must read yellow, never green.
  public func probeHealth(promptFamily: PromptFamily) async -> EGOneHealth {
    switch state {
    case .stopped:
      return .red(reason: "not_running")
    case .starting:
      return .yellow(reason: "starting")
    case .pausedForMemoryPressure:
      return .yellow(reason: "paused_for_memory")
    case .failed(let reason):
      return .red(reason: reason)
    case .ready(let endpoint):
      let probeTranscript = "so um move the meeting to thursday no wait friday"
      let connector = EGOneConnector(endpoint: endpoint)
      let builder = DefaultPromptPlanner.builder(for: promptFamily)
      let input = PromptBuildInput(
        transcript: probeTranscript,
        provider: .egOne,
        modelID: LLMProvider.egOneModelName,
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0)
      )
      let envelope = builder.build(input: input, mode: .message)
      let config = LLMProviderConfig(
        model: LLMProvider.egOneModelName,
        apiKeyKeychainId: nil,
        outputTokens: .capped(128),
        temperature: 0,
        thinkingBudget: nil,
        reasoningEffort: nil,
        detectedLanguage: nil
      )
      let start = ContinuousClock.now
      do {
        let result = try await connector.polish(envelope: envelope, config: config, onToken: nil)
        let elapsed = ContinuousClock.now - start
        let output = (result.polishedText ?? "").lowercased()
        // GREEN requires the FULL transformation: filler dropped AND the
        // self-correction applied (rejected day + correction phrase gone).
        // "Move the meeting to Thursday, no wait, Friday." must read
        // yellow, not Live (#1271 Codex r13).
        let transformed =
          output.contains("friday")
          && output.range(of: "\\bum\\b", options: .regularExpression) == nil
          && !output.contains("thursday") && !output.contains("no wait")
        if !transformed {
          return .yellow(reason: "probe_output_unexpected")
        }
        if elapsed > .seconds(5) {
          return .yellow(reason: "probe_slow")
        }
        return .green
      } catch {
        return .red(reason: "probe_failed")
      }
    }
  }

  // MARK: - Helpers

  /// Bind port 0, read the kernel-assigned port, release it. A race with
  /// another process grabbing the port between release and spawn is
  /// possible but self-healing (spawn fails → failed state → user retry).
  static func findFreePort() -> UInt16? {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { return nil }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        getsockname(sock, sockaddrPtr, &len)
      }
    }
    guard nameResult == 0 else { return nil }
    return UInt16(bigEndian: bound.sin_port)
  }

  static func awaitServerUp(
    endpoint: EGOneEndpoint, budgetSeconds: Int,
    processIsAlive: @escaping @Sendable () -> Bool = { true }
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(budgetSeconds)
    guard let healthURL = URL(string: "http://127.0.0.1:\(endpoint.port)/health") else {
      return false
    }
    while ContinuousClock.now < deadline {
      // A dead child can never become healthy — bail immediately instead
      // of burning the whole budget (also keeps fake-binary tests fast).
      guard processIsAlive() else { return false }
      var request = URLRequest(url: healthURL)
      request.timeoutInterval = 2
      request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
      if let (_, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    return false
  }
}
