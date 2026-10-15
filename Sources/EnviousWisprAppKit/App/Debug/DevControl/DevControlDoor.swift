#if DEBUG
  import Darwin
  import EnviousWisprCore
  import Foundation
  import Network

  /// #3765: a DEBUG-only Unix-socket door through which a local CLI or MCP drives a RUNNING
  /// dev build: settings, words, history, status (and, later, dictation and models).
  ///
  /// The door owns transport only: the listener, the launch identity, the connections and
  /// their buffers. Every command is answered by `DevControlDispatcher`, which calls the
  /// owner the UI calls.
  ///
  /// **Trust boundary is the same effective uid, nothing more.** The socket lives in
  /// `/tmp/ew-dev-control-<uid>/`, a directory this process creates 0700 and refuses to use
  /// unless it is a real directory owned by our uid with no group or other bits. The socket
  /// itself is chmod 0600 before any request is admitted. Other processes running as the
  /// same user are trusted; peers are not authenticated, and this is not authenticated IPC.
  ///
  /// **Several dev builds run at once and share one bundle id**, so the socket is named by
  /// PID and every reply carries `pid`, `launch` (a per-launch UUID) and `executable`. The
  /// CLI resolves exactly one instance from its worktree and checks all three on a `ping`
  /// before it sends anything that mutates.
  ///
  /// Release builds compile none of this.
  @MainActor
  final class DevControlDoor {
    /// Wire protocol version, echoed as `door` in every reply.
    nonisolated static let protocolVersion = 1
    /// Bound on one encoded request frame and one encoded reply, newline excluded.
    nonisolated static let maxFrameBytes = 1 << 20
    /// Darwin's `sockaddr_un.sun_path` capacity, terminating NUL included.
    nonisolated static let sunPathCapacity = 104

    enum InstallResult: Equatable {
      case ready
      case refused(String)
      case failed(String)
    }

    enum State: Equatable {
      case idle
      case starting
      case ready
      case closed
    }

    let launchID = UUID()
    let pid: Int32
    let executablePath: String
    let socketPath: String

    private(set) var state: State = .idle

    private let dispatcher: DevControlDispatcher
    private let queue = DispatchQueue(label: "com.enviouswispr.dev.control")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    /// Bumped by `uninstall()`. A callback captured under an older generation does nothing.
    private var generation = 0
    private var readyContinuation: CheckedContinuation<InstallResult, Never>?

    init(
      dispatcher: DevControlDispatcher,
      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
      executablePath: String = Bundle.main.executablePath ?? ""
    ) {
      self.dispatcher = dispatcher
      self.pid = pid
      self.executablePath = executablePath
      self.socketPath = Self.socketPath(pid: pid)
    }

    nonisolated static func socketDirectory(uid: uid_t = geteuid()) -> String {
      "/tmp/ew-dev-control-\(uid)"
    }

    nonisolated static func socketPath(pid: Int32, uid: uid_t = geteuid()) -> String {
      "\(socketDirectory(uid: uid))/\(pid).sock"
    }

    // MARK: - Install / uninstall

    /// Prepares the directory, binds the socket, and returns once the listener has reached
    /// `.ready` and the socket is 0600, or once it has failed. Requests are admitted only
    /// after `.ready`.
    func install() async -> InstallResult {
      guard state == .idle else { return .refused("alreadyInstalled") }
      if let reason = Self.unsafePathReason(socketPath) {
        log("refused reason=\(reason)")
        state = .closed
        return .refused(reason)
      }

      let params = NWParameters.tcp
      params.requiredLocalEndpoint = .unix(path: socketPath)
      let listener: NWListener
      do {
        listener = try NWListener(using: params)
      } catch {
        log("listener failed reason=construct")
        state = .closed
        return .failed("construct")
      }
      state = .starting
      self.listener = listener
      let owningGeneration = generation

      listener.stateUpdateHandler = { [weak self] newState in
        Task { @MainActor in
          self?.listenerStateChanged(newState, generation: owningGeneration)
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          guard let self, self.generation == owningGeneration, self.state == .ready else {
            connection.cancel()
            return
          }
          self.accept(connection)
        }
      }

      return await withCheckedContinuation { continuation in
        readyContinuation = continuation
        listener.start(queue: queue)
      }
    }

    /// Closes admission, cancels every connection and the listener, and removes the socket
    /// pathname this process owns. Safe to call more than once.
    func uninstall() {
      guard state != .closed else { return }
      state = .closed
      generation += 1
      for session in sessions.values {
        session.connection.cancel()
      }
      sessions.removeAll()
      listener?.cancel()
      listener = nil
      removeOwnedSocket()
      resolveInstall(.failed("uninstalled"))
      log("uninstalled")
    }

    private func listenerStateChanged(_ newState: NWListener.State, generation owning: Int) {
      guard owning == generation else { return }
      switch newState {
      case .ready:
        guard state == .starting else { return }
        guard chmod(socketPath, 0o600) == 0, Self.socketModeIsPrivate(socketPath) else {
          log("refused reason=socketMode")
          uninstall()
          return
        }
        state = .ready
        log("ready path=\(socketPath)")
        resolveInstall(.ready)
      case .failed:
        log("listener failed reason=state")
        uninstall()
      case .cancelled, .setup, .waiting:
        return
      @unknown default:
        return
      }
    }

    private func resolveInstall(_ result: InstallResult) {
      guard let continuation = readyContinuation else { return }
      readyContinuation = nil
      continuation.resume(returning: result)
    }

    // MARK: - Path safety

    /// Nil when the directory is (or has just been made) a private directory owned by our
    /// effective uid AND the socket pathname is absent or an owned socket we may replace.
    /// Otherwise the reason to refuse. Anything indeterminate refuses.
    nonisolated static func unsafePathReason(_ path: String) -> String? {
      guard path.utf8.count + 1 <= sunPathCapacity else { return "pathTooLong" }
      let directory = (path as NSString).deletingLastPathComponent
      if mkdir(directory, 0o700) != 0, errno != EEXIST { return "dirCreate" }
      var dirInfo = stat()
      guard lstat(directory, &dirInfo) == 0 else { return "dirStat" }
      guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else { return "dirUnsafe" }
      guard dirInfo.st_uid == geteuid() else { return "dirUnsafe" }
      guard (dirInfo.st_mode & 0o077) == 0 else { return "dirUnsafe" }

      var entry = stat()
      if lstat(path, &entry) != 0 {
        return errno == ENOENT ? nil : "socketStat"
      }
      // Our PID is unique among live processes, so an owned socket at our exact pathname
      // is a leftover from a dead process that once had this PID. Anything else refuses.
      guard (entry.st_mode & S_IFMT) == S_IFSOCK, entry.st_uid == geteuid() else {
        return "socketUnsafe"
      }
      guard unlink(path) == 0 else { return "socketUnlink" }
      return nil
    }

    nonisolated static func socketModeIsPrivate(_ path: String) -> Bool {
      var info = stat()
      guard lstat(path, &info) == 0 else { return false }
      return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == geteuid()
        && (info.st_mode & 0o777) == 0o600
    }

    private func removeOwnedSocket() {
      var info = stat()
      guard lstat(socketPath, &info) == 0 else { return }
      guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { return }
      unlink(socketPath)
    }

    // MARK: - Connections

    @MainActor
    private final class Session {
      let connection: NWConnection
      var buffer = Data()
      init(connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
      let key = ObjectIdentifier(connection)
      sessions[key] = Session(connection: connection)
      let owning = generation
      connection.stateUpdateHandler = { [weak self] newState in
        switch newState {
        case .cancelled, .failed:
          Task { @MainActor in
            guard let self, self.generation == owning else { return }
            self.sessions[key] = nil
          }
        default:
          return
        }
      }
      connection.start(queue: queue)
      receive(connection, key: key, generation: owning)
    }

    /// The receive callback runs on the door's queue and carries only Sendable values
    /// (the connection and its key); the session's buffer is touched on the main actor.
    private func receive(_ connection: NWConnection, key: ObjectIdentifier, generation owning: Int) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
        [weak self] data, _, isComplete, error in
        Task { @MainActor in
          guard let self, self.generation == owning, self.state == .ready,
            let session = self.sessions[key]
          else {
            connection.cancel()
            return
          }
          if let data, !data.isEmpty { session.buffer.append(data) }
          await self.drain(session, generation: owning)
          guard self.generation == owning else { return }
          if error != nil || isComplete {
            connection.cancel()
            return
          }
          if session.buffer.count > Self.maxFrameBytes {
            await self.send(
              Self.errorReply(id: nil, code: "tooLarge", message: "request frame over limit"),
              on: session)
            connection.cancel()
            return
          }
          self.receive(connection, key: key, generation: owning)
        }
      }
    }

    /// Answers every complete frame in the buffer, one at a time, each reply fully sent
    /// before the next request is decoded.
    private func drain(_ session: Session, generation owning: Int) async {
      while generation == owning, let newline = session.buffer.firstIndex(of: 0x0A) {
        let frame = session.buffer[session.buffer.startIndex..<newline]
        session.buffer.removeSubrange(session.buffer.startIndex...newline)
        guard frame.count <= Self.maxFrameBytes else {
          await send(
            Self.errorReply(id: nil, code: "tooLarge", message: "request frame over limit"),
            on: session)
          continue
        }
        let reply = await answer(Data(frame))
        guard generation == owning else { return }
        await send(reply, on: session)
      }
    }

    /// One request frame to one reply object, both without identity fields.
    private func answer(_ frame: Data) async -> [String: Any] {
      let correlation = UUID()
      guard let text = String(data: frame, encoding: .utf8),
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        let request = object as? [String: Any]
      else {
        log("corr=\(correlation) cmd=none ok=false code=malformed")
        return Self.errorReply(id: nil, code: "malformed", message: "not a JSON object")
      }
      let id = request["id"] as? String
      guard id.map({ $0.count <= 128 }) ?? true, let name = request["cmd"] as? String else {
        log("corr=\(correlation) cmd=none ok=false code=malformed")
        return Self.errorReply(id: nil, code: "malformed", message: "id or cmd invalid")
      }
      let args = request["args"] as? [String: Any] ?? [:]
      let command = DevControlDispatcher.Command(rawValue: name)
      let result = await dispatcher.handle(command, args: args)
      switch result {
      case .ok(let payload):
        log("corr=\(correlation) cmd=\(command?.rawValue ?? "unknown") ok=true code=none")
        return ["id": Self.idValue(id), "ok": true, "result": payload]
      case .error(let code, let message):
        log("corr=\(correlation) cmd=\(command?.rawValue ?? "unknown") ok=false code=\(code)")
        return Self.errorReply(id: id, code: code, message: message)
      }
    }

    nonisolated static func errorReply(id: String?, code: String, message: String) -> [String: Any]
    {
      ["id": idValue(id), "ok": false, "error": ["code": code, "message": message]]
    }

    /// JSON has no Optional: an absent client id is `null`.
    nonisolated static func idValue(_ id: String?) -> Any { id ?? NSNull() }

    /// The reply with identity fields, encoded, or nil when it is not encodable JSON or
    /// is over the frame limit. `isValidJSONObject` first, because `JSONSerialization`
    /// raises an Objective-C exception (a crash, not a thrown error) on a non-JSON value.
    private func encode(_ reply: [String: Any]) -> Data? {
      var full = reply
      full["pid"] = Int(pid)
      full["launch"] = launchID.uuidString
      full["executable"] = executablePath
      full["door"] = Self.protocolVersion
      guard JSONSerialization.isValidJSONObject(full),
        let data = try? JSONSerialization.data(withJSONObject: full, options: [.sortedKeys]),
        data.count <= Self.maxFrameBytes
      else { return nil }
      return data
    }

    private func send(_ reply: [String: Any], on session: Session) async {
      let fallback = Self.errorReply(
        id: reply["id"] as? String, code: "responseTooLarge",
        message: "reply over limit or not encodable")
      guard var payload = encode(reply) ?? encode(fallback) else {
        session.connection.cancel()
        return
      }
      payload.append(0x0A)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        session.connection.send(
          content: payload,
          completion: .contentProcessed { _ in continuation.resume() })
      }
    }

    private func log(_ message: String) {
      Task {
        await AppLogger.shared.log("[DevControl] \(message)", level: .info, category: "Debug")
      }
    }
  }
#endif
