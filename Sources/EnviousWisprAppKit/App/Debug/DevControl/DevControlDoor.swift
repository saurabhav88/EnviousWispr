#if DEBUG
  import Darwin
  import EnviousWisprASR
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

    let launchID: UUID
    let pid: Int32
    let executablePath: String
    let socketPath: String

    private(set) var state: State = .idle
    /// True once the listener has reported `.cancelled` after uninstall (or never existed),
    /// so its pathname cleanup has run. Tests wait on it.
    private(set) var listenerHasStopped = false

    /// Socket pathnames reserved until their owning listener has stopped.
    private static var claimedPaths: Set<String> = []

    typealias Handler =
      @MainActor (DevControlDispatcher.Command?, [String: Any]) async -> DevControlDispatcher.Result

    /// Answers admitted requests. Production passes the dispatcher's `handle`; tests pass a
    /// handler that can suspend, to exercise shutdown during a request.
    private let handler: Handler
    /// Runs at uninstall, after admission closes: production closes the dispatcher's
    /// dictation receipts so no late callback updates them.
    private let onUninstall: @MainActor () -> Void
    private let queue = DispatchQueue(label: "com.enviouswispr.dev.control")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    /// Bumped by `uninstall()`. A callback captured under an older generation does nothing.
    private var generation = 0
    private var readyContinuation: CheckedContinuation<InstallResult, Never>?

    convenience init(
      dispatcher: DevControlDispatcher,
      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
      executablePath: String = Bundle.main.executablePath ?? ""
    ) {
      self.init(
        handler: { command, args in await dispatcher.handle(command, args: args) },
        launchID: dispatcher.launchID, onUninstall: { dispatcher.dictation.shutDown() },
        pid: pid, executablePath: executablePath)
    }

    init(
      handler: @escaping Handler,
      launchID: UUID = UUID(),
      onUninstall: @escaping @MainActor () -> Void = {},
      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
      executablePath: String = Bundle.main.executablePath ?? ""
    ) {
      self.handler = handler
      self.launchID = launchID
      self.onUninstall = onUninstall
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
      // One door per pathname per process. Only tests build a second door with the same
      // PID, and a late cleanup from a cancelled listener must not unlink its socket.
      guard !Self.claimedPaths.contains(socketPath) else {
        state = .closed
        listenerHasStopped = true
        return .refused("pathInUse")
      }
      if let reason = Self.unsafePathReason(socketPath) {
        log("refused reason=\(reason)")
        state = .closed
        listenerHasStopped = true
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
        listenerHasStopped = true
        return .failed("construct")
      }
      state = .starting
      self.listener = listener
      Self.claimedPaths.insert(socketPath)
      let owningGeneration = generation
      let path = socketPath

      listener.stateUpdateHandler = { [weak self] newState in
        Task { @MainActor in
          if case .cancelled = newState {
            // The listener may bind after an uninstall that ran while it was starting, so
            // the pathname is removed again once the listener has really stopped, and only
            // then released for another door in this process.
            Self.removeOwnedSocket(at: path)
            Self.claimedPaths.remove(path)
            self?.listenerHasStopped = true
            return
          }
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
        onListenerStarted?()
      }
    }

    /// Closes admission, invalidates the generation (so a late callback or a request still
    /// suspended in its handler sends nothing and dispatches nothing more), closes every
    /// session and cancels its task, cancels the listener, and removes the socket pathname
    /// this process owns. Safe to call more than once and while install is still starting.
    func uninstall() {
      guard state != .closed else { return }
      state = .closed
      generation += 1
      onUninstall()
      for (key, session) in sessions {
        close(session, key: key)
      }
      sessions.removeAll()
      if let listener {
        listener.cancel()
        Self.removeOwnedSocket(at: socketPath)
      } else {
        listenerHasStopped = true
      }
      listener = nil
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

    private static func removeOwnedSocket(at path: String) {
      var info = stat()
      guard lstat(path, &info) == 0 else { return }
      guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { return }
      unlink(path)
    }

    // MARK: - Connections

    /// One accepted connection. Requests on it are answered strictly in order: the door
    /// stops reading while a request is being answered, so `buffer` holds at most one
    /// receive chunk beyond a frame: `process` refuses a buffer over `maxFrameBytes` with no
    /// newline, and no further receive is issued until the buffered frames are answered.
    @MainActor
    final class Session {
      let connection: NWConnection
      var buffer = Data()
      /// The peer finished sending (EOF). Buffered complete frames are still answered.
      var peerFinished = false
      /// False once the session is closed for any reason; nothing is dispatched or sent after.
      var isOpen = true
      /// The task answering this session's buffered frames, owned so uninstall can cancel it.
      var task: Task<Void, Never>?
      init(connection: NWConnection) { self.connection = connection }
    }

    nonisolated static let receiveChunkBytes = 65_536

    /// Open sessions, for tests that wait for a connection to close.
    var openSessionCount: Int { sessions.count }

    /// Receives each request-outcome log line as it is written, so a test can read what the
    /// log says about the reply that was actually sent.
    var onOutcomeLogged: ((String) -> Void)?
    /// Called synchronously right after the listener is started, while the door is still
    /// `.starting`, so a test can act in that state without relying on scheduling.
    var onListenerStarted: (() -> Void)?
    /// Called when a session's processing task returns, on every exit path.
    var onProcessingFinished: (() -> Void)?

    private func accept(_ connection: NWConnection) {
      let key = ObjectIdentifier(connection)
      sessions[key] = Session(connection: connection)
      let owning = generation
      connection.stateUpdateHandler = { [weak self] newState in
        switch newState {
        case .cancelled, .failed:
          Task { @MainActor in
            guard let self, self.generation == owning, let session = self.sessions[key] else {
              return
            }
            self.close(session, key: key)
          }
        default:
          return
        }
      }
      connection.start(queue: queue)
      receive(connection, key: key, generation: owning)
    }

    /// The receive callback runs on the door's queue and carries only Sendable values;
    /// the session is touched on the main actor.
    private func receive(_ connection: NWConnection, key: ObjectIdentifier, generation owning: Int) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) {
        [weak self] data, _, isComplete, error in
        Task { @MainActor in
          guard let self, self.generation == owning, self.state == .ready,
            let session = self.sessions[key], session.isOpen
          else {
            connection.cancel()
            return
          }
          if error != nil {
            self.close(session, key: key)
            return
          }
          if let data, !data.isEmpty { session.buffer.append(data) }
          if isComplete { session.peerFinished = true }
          session.task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.onProcessingFinished?() }
            await self.process(session, key: key, generation: owning)
          }
        }
      }
    }

    /// Answers every complete buffered frame in order, each reply fully sent before the next
    /// frame is decoded, then either closes the session or reads more.
    private func process(_ session: Session, key: ObjectIdentifier, generation owning: Int) async {
      while let newline = session.buffer.firstIndex(of: 0x0A) {
        guard isLive(session, owning) else { return }
        let frame = Data(session.buffer[session.buffer.startIndex..<newline])
        session.buffer.removeSubrange(session.buffer.startIndex...newline)
        let correlation = UUID()
        guard frame.count <= Self.maxFrameBytes else {
          _ = await send(
            Self.errorReply(id: nil, code: "tooLarge", message: "request frame over limit"),
            correlation: correlation, command: "none", on: session)
          close(session, key: key)
          return
        }
        let (reply, command, forced) = await answer(frame)
        guard isLive(session, owning) else { return }
        guard
          await send(
            reply, correlation: correlation, command: command, forced: forced, on: session)
        else {
          close(session, key: key)
          return
        }
      }
      guard isLive(session, owning) else { return }
      if session.buffer.count > Self.maxFrameBytes {
        _ = await send(
          Self.errorReply(id: nil, code: "tooLarge", message: "request frame over limit"),
          correlation: UUID(), command: "none", on: session)
        close(session, key: key)
        return
      }
      if session.peerFinished {
        if !session.buffer.isEmpty {
          _ = await send(
            Self.errorReply(id: nil, code: "incompleteFrame", message: "no newline before EOF"),
            correlation: UUID(), command: "none", on: session)
        }
        close(session, key: key)
        return
      }
      session.task = nil
      receive(session.connection, key: key, generation: owning)
    }

    private func isLive(_ session: Session, _ owning: Int) -> Bool {
      generation == owning && state == .ready && session.isOpen && !Task.isCancelled
    }

    private func close(_ session: Session, key: ObjectIdentifier) {
      guard session.isOpen else { return }
      session.isOpen = false
      session.buffer.removeAll()
      session.task?.cancel()
      session.task = nil
      session.connection.cancel()
      sessions[key] = nil
    }

    /// One request frame to one reply object (identity fields are added by `send`) and the
    /// command label the log may carry: an admitted command name, `unknown`, or `none`.
    private func answer(_ frame: Data) async -> (reply: [String: Any], command: String, forced: Bool) {
      guard let text = String(data: frame, encoding: .utf8) else {
        return (Self.errorReply(id: nil, code: "malformed", message: "not UTF-8"), "none", false)
      }
      guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        let request = object as? [String: Any]
      else {
        return (Self.errorReply(id: nil, code: "malformed", message: "not a JSON object"), "none", false)
      }
      let rawID = request["id"]
      let id = rawID as? String
      let idIsValid = rawID == nil || (id.map { $0.count <= 128 } ?? false)
      guard idIsValid else {
        return (
          Self.errorReply(id: nil, code: "malformed", message: "id must be a short string"), "none",
          false
        )
      }
      guard let name = request["cmd"] as? String else {
        return (Self.errorReply(id: id, code: "malformed", message: "cmd must be a string"), "none", false)
      }
      let rawArgs = request["args"]
      guard rawArgs == nil || rawArgs is [String: Any] else {
        return (Self.errorReply(id: id, code: "malformed", message: "args must be an object"), "none", false)
      }
      let args = rawArgs as? [String: Any] ?? [:]
      let command = DevControlDispatcher.Command(rawValue: name)
      let label = command?.rawValue ?? "unknown"
      if let line = Self.detectionWitness(command, args: args, id: id) { log(line) }
      switch await handler(command, args) {
      case .ok(let payload, let forced):
        return (["id": Self.idValue(id), "ok": true, "result": payload], label, forced)
      case .error(let code, let message):
        return (Self.errorReply(id: id, code: code, message: message), label, false)
      case .errorWithReceipt(let code, let message, let receipt):
        var reply = Self.errorReply(id: id, code: code, message: message)
        var error = reply["error"] as? [String: Any] ?? [:]
        error["receipt"] = receipt
        reply["error"] = error
        return (reply, label, false)
      }
    }

    /// #4254 runtime checkpoint: which meeting speech detections were running when a dictation
    /// start, a meeting delete or an engine (`selectedBackend`) write was RECEIVED, read before
    /// the command runs, with the client's request id so the line matches that exact request.
    /// Ids, tokens and clock readings only; no argument values.
    nonisolated static func detectionWitness(
      _ command: DevControlDispatcher.Command?, args: [String: Any], id: String?
    ) -> String? {
      switch command {
      case .dictationStart, .meetingDelete: break
      case .settingsSet where (args["key"] as? String) == "selectedBackend": break
      default: return nil
      }
      let (tokens, uptime) = MeetingSpeechDetectionActivity.snapshot()
      let list = tokens.isEmpty ? "none" : tokens.map(String.init).joined(separator: ",")
      let kind = command == .settingsSet ? "engine_switch" : command?.rawValue ?? "unknown"
      return "whisper_meeting_vad_active request=\(kind) id=\(id ?? "none") tokens=\(list) uptime_raw_ns=\(uptime)"
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

    /// Encodes, logs the outcome of the reply ACTUALLY chosen, and sends it. True when the
    /// send completed without error.
    private func send(
      _ reply: [String: Any], correlation: UUID, command: String, forced: Bool = false,
      on session: Session
    ) async -> Bool {
      var chosen = reply
      var payload = encode(reply)
      if payload == nil {
        chosen = Self.errorReply(
          id: reply["id"] as? String, code: "responseTooLarge",
          message: "reply over limit or not encodable")
        payload = encode(chosen)
      }
      let ok = (chosen["ok"] as? Bool) == true
      let code = ((chosen["error"] as? [String: Any])?["code"] as? String) ?? "none"
      // `forced` is the operation's fact from the dispatcher: a forced write that completed
      // stays forced even when its reply is replaced by `responseTooLarge`.
      let outcome = "corr=\(correlation) cmd=\(command) ok=\(ok) forced=\(forced) code=\(code)"
      onOutcomeLogged?(outcome)
      log(outcome)
      guard var bytes = payload else { return false }
      bytes.append(0x0A)
      return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        session.connection.send(
          content: bytes,
          completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
      }
    }

    private func log(_ message: String) {
      Task {
        await AppLogger.shared.log("[DevControl] \(message)", level: .info, category: "Debug")
      }
    }
  }
#endif
