#if DEBUG

  import EnviousWisprASR
  import EnviousWisprAudio
  import EnviousWisprCore
  import EnviousWisprPipeline
  import Foundation
  import Network

  /// V2 fault-injection control surface (issue #291).
  ///
  /// A tiny localhost command listener that exists only in DEBUG builds and
  /// only starts when the launching environment sets `EW_FAULT_INJECTION=1`.
  /// Production builds compile this entire file out — verified post-build via
  /// `nm` symbol grep against the release binary.
  ///
  /// **Security posture:**
  /// - `#if DEBUG` (entire file) — release binaries lack the symbols entirely.
  /// - Env-gated: must launch with `EW_FAULT_INJECTION=1` to start at all.
  /// - Loopback only: binds 127.0.0.1, refuses non-loopback peers.
  /// - Per-launch token: a 32-byte hex token is written atomically to
  ///   `~/Library/Logs/EnviousWispr/fault-token-<pid>` with `0600` perms.
  ///   Every command must carry the matching token in its first line.
  ///   Token file is deleted on `stop()`.
  /// - Fixed command set (no arbitrary RPC, no method invocation, no shell escape):
  ///   `force_proxy_buffer_drop(N)`, `force_cancel`, `force_xpc_kill`,
  ///   `force_audio_xpc_kill`, `query_state`.
  /// - Each command dispatches to `@MainActor` via `Task { @MainActor in ... }`
  ///   so command handling matches the actor isolation of the seams it drives.
  ///
  /// **Wire protocol** (text, line-delimited, single command per connection):
  /// ```
  /// <token>\n
  /// <command>\n
  /// ```
  /// Reply is one line: `OK\n`, `OK <state>\n` (for `query_state`), or
  /// `ERR <reason>\n`. Connection is closed by the listener after the reply.
  ///
  /// Drives Lane A scenarios in `Tests/RuntimeUAT/faultInjection.py`.
  @MainActor
  final class DebugFaultEndpoint {

    // MARK: - Dependencies (concrete proxy/pipeline types — DEBUG seams live here)

    private let audioProxy: AudioCaptureProxy?
    private let asrProxy: ASRManagerProxy?
    private let kernelDriver: KernelDictationDriver
    private let whisperKitKernelDriver: KernelDictationDriver
    private let activeBackend: () -> ASRBackendType

    // MARK: - Listener state

    private var listener: NWListener?
    private let port: UInt16
    private let token: String
    private let tokenPath: URL
    private let queue = DispatchQueue(label: "com.enviouswispr.debug.fault-endpoint")

    /// Construct the endpoint. The audio/ASR proxy refs are optional so the
    /// endpoint still functions in environments where the heart-path is
    /// stubbed out (preview/test app builds); commands targeting absent
    /// dependencies reply `ERR no_dependency`.
    init(
      audioProxy: AudioCaptureProxy?,
      asrProxy: ASRManagerProxy?,
      kernelDriver: KernelDictationDriver,
      whisperKitKernelDriver: KernelDictationDriver,
      activeBackend: @escaping () -> ASRBackendType,
      port: UInt16 = 8765
    ) {
      self.audioProxy = audioProxy
      self.asrProxy = asrProxy
      self.kernelDriver = kernelDriver
      self.whisperKitKernelDriver = whisperKitKernelDriver
      self.activeBackend = activeBackend
      self.port = port
      self.token = Self.generateToken()
      self.tokenPath = Self.tokenURL(pid: ProcessInfo.processInfo.processIdentifier)
    }

    /// Returns true when the launching environment has opted in.
    static var isRequested: Bool {
      ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1"
    }

    /// Bind the loopback listener and write the per-launch token file.
    /// Idempotent — calling twice is a no-op after the first successful start.
    func start() {
      guard listener == nil else { return }

      do {
        try writeTokenFile()
      } catch {
        Task {
          await AppLogger.shared.log(
            "[DebugFaultEndpoint] failed to write token file: \(error)",
            level: .info, category: "Debug"
          )
        }
        return
      }

      let params = NWParameters.tcp
      params.requiredInterfaceType = .loopback
      params.acceptLocalOnly = true

      do {
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
          // newConnectionHandler runs on `queue` (nonisolated). Hop to MainActor
          // before touching this @MainActor type.
          Task { @MainActor in
            self?.accept(connection: conn)
          }
        }
        listener.start(queue: queue)
        self.listener = listener
        Task {
          await AppLogger.shared.log(
            "[DebugFaultEndpoint] started on 127.0.0.1:\(port) (token at \(tokenPath.path))",
            level: .info, category: "Debug"
          )
        }
      } catch {
        Task {
          await AppLogger.shared.log(
            "[DebugFaultEndpoint] failed to bind: \(error)",
            level: .info, category: "Debug"
          )
        }
        try? FileManager.default.removeItem(at: tokenPath)
      }
    }

    /// Tear down the listener and remove the token file. Safe to call multiple
    /// times — wired into `applicationWillTerminate`.
    func stop() {
      listener?.cancel()
      listener = nil
      try? FileManager.default.removeItem(at: tokenPath)
    }

    // MARK: - Connection handling

    /// Maximum bytes for a single fault-injection request. Tokens are 64
    /// hex chars + "\n" + a short command + "\n" — well under 512.
    private nonisolated static let maxRequestBytes = 512

    private func accept(connection conn: NWConnection) {
      conn.start(queue: queue)
      readRequest(on: conn, accumulated: Data())
    }

    /// Drain the connection until we see the second newline (two-line
    /// request) or the buffer cap. TCP can split a small request across
    /// segments; the prior single `recv` parsed partial data as
    /// malformed/auth-failed and closed the connection, causing
    /// intermittent harness failures (Codex P2 feedback on PR #544).
    private func readRequest(on conn: NWConnection, accumulated: Data) {
      conn.receive(
        minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes
      ) { [weak self] data, _, isComplete, error in
        guard let self else {
          conn.cancel()
          return
        }
        guard error == nil else {
          conn.cancel()
          return
        }
        var buffer = accumulated
        if let data, !data.isEmpty {
          buffer.append(data)
        }

        let newlineCount = buffer.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let isFull = newlineCount >= 2 || buffer.count >= Self.maxRequestBytes

        if isFull || isComplete {
          guard !buffer.isEmpty else {
            conn.cancel()
            return
          }
          let request = String(decoding: buffer, as: UTF8.self)
          Task { @MainActor in
            let reply = await self.handle(request: request)
            let payload = (reply + "\n").data(using: .utf8) ?? Data()
            conn.send(
              content: payload,
              completion: .contentProcessed { _ in conn.cancel() }
            )
          }
        } else {
          // Need more data; keep draining.
          Task { @MainActor in
            self.readRequest(on: conn, accumulated: buffer)
          }
        }
      }
    }

    /// Parse a two-line request and dispatch to the matching seam. Returns the
    /// reply line (without trailing newline).
    private func handle(request: String) async -> String {
      let lines = request.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard lines.count == 2 else { return "ERR malformed" }
      guard String(lines[0]) == token else { return "ERR auth" }

      let cmd = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
      switch cmd {
      case "force_cancel":
        switch activeBackend() {
        case .parakeet: await kernelDriver.forceCancelNow()
        case .whisperKit: await whisperKitKernelDriver.forceCancelNow()
        }
        return "OK"

      case "force_xpc_kill":
        guard let asrProxy else { return "ERR no_dependency" }
        asrProxy.forceConnectionTerminationNow()
        return "OK"

      case "force_audio_xpc_kill":
        guard let audioProxy else { return "ERR no_dependency" }
        audioProxy.forceConnectionTerminationNow()
        return "OK"

      case "query_state":
        let p = kernelDriver.state
        let w = whisperKitKernelDriver.state
        return "OK parakeet=\(p) whisperkit=\(w) backend=\(activeBackend())"

      default:
        // force_proxy_buffer_drop(N) is the only parameterized command.
        // Drops the next N buffers inside `AudioCaptureProxy.audioBufferCaptured`
        // before they reach the app continuation. Tests the PROXY-side stall
        // watchdog (XPC-channel buffer drop), NOT real OS-level audio
        // interruption recovery in `AVAudioEngineSource.handleEngineConfigurationChange()`
        // or `AVCaptureSessionSource` interruption handlers — those run in the
        // service process and are not reachable from this host-process endpoint.
        // For real audio-stack interruption testing see `docs/LANE_B_AUDIO_TESTS.md`.
        if let n = parseForceProxyBufferDrop(cmd) {
          guard let audioProxy else { return "ERR no_dependency" }
          audioProxy.forceStallRemainingBuffers = n
          return "OK"
        }
        return "ERR unknown_command"
      }
    }

    private func parseForceProxyBufferDrop(_ cmd: String) -> Int? {
      let prefix = "force_proxy_buffer_drop("
      guard cmd.hasPrefix(prefix), cmd.hasSuffix(")") else { return nil }
      let inner = cmd.dropFirst(prefix.count).dropLast()
      return Int(inner)
    }

    // MARK: - Token file management

    private func writeTokenFile() throws {
      let dir = tokenPath.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true, attributes: nil)
      // Atomic write so partial token can never be observed by harness reader.
      try token.data(using: .utf8)?.write(to: tokenPath, options: [.atomic])
      // Tighten permissions to 0600 — owner read/write only.
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: tokenPath.path)
    }

    private static func tokenURL(pid: Int32) -> URL {
      let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("EnviousWispr", isDirectory: true)
      return logs.appendingPathComponent("fault-token-\(pid)")
    }

    private static func generateToken() -> String {
      var bytes = [UInt8](repeating: 0, count: 32)
      let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      precondition(result == errSecSuccess, "SecRandomCopyBytes failed in DebugFaultEndpoint")
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
  }

#endif
