#if DEBUG
  import EnviousWisprCore
  import Foundation

  /// #2885: a DEBUG-only door through which a local process hands a RUNNING dev build a
  /// file for Transcribe a File, without activating the app, opening the picker, or typing.
  ///
  /// Live UAT drove the wizard over the accessibility API and took the founder's keyboard
  /// and mouse for the whole walk. This door takes a distributed notification naming the
  /// target instance by PID and per-launch id, runs the wizard's own steps
  /// (`FileImportCoordinator.choose(url:)`, then `advance()` to `start()`) with whatever
  /// Settings hold, exactly as the screen would, and replies with a terminal status and the
  /// History row it attempted. Release builds compile none of this: no receiver, no plist
  /// key, no URL scheme.
  ///
  /// **Every dev build shares one bundle id, so every instance receives every post.** A
  /// request names a PID; an instance ignores any other PID silently, and answers a
  /// `transcribe` only when the request also carries the per-launch id it handed out to a
  /// prior `discover`, so a PID reused by another process between resolve and post is never
  /// handed a file (Codex, #2885 plan review).
  @MainActor
  final class DebugImportDoor {
    static let requestName = Notification.Name("com.enviouswispr.dev.import.request")
    static let replyName = Notification.Name("com.enviouswispr.dev.import.reply")

    /// The longest a caller may ask the door to watch. The run itself is not bounded by this;
    /// only the watching is.
    static let maxTimeoutSeconds: Double = 3600
    static let defaultTimeoutSeconds: Double = 900

    let launchID = UUID()

    private let coordinator: FileImportCoordinator
    private let pid: Int32
    private let pollInterval: Duration
    private let post: @MainActor ([String: String]) -> Void
    private var inFlight: String?
    /// The generation the in-flight walk is about: set after the door's own `choose(url:)`
    /// and again after its own Start. Re-read when the walk returns, because the
    /// coordinator can move between the walk's last poll and the reply.
    private var watchedGeneration = 0
    private var seenRequests: Set<String> = []
    private var walkTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - pollInterval: how often the walk re-reads the coordinator. The coordinator is
    ///     `@Observable`; a poll is the simplest correct observer for a DEBUG door and
    ///     needs no re-arm bookkeeping (`swift-concurrency-patterns.md`
    ///     observation-not-lossless-queue). Tests shorten it.
    ///   - post: where a reply goes. The live door posts a distributed notification and a
    ///     log line; tests capture the dictionary.
    init(
      coordinator: FileImportCoordinator,
      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
      pollInterval: Duration = .milliseconds(100),
      post: (@MainActor ([String: String]) -> Void)? = nil
    ) {
      self.coordinator = coordinator
      self.pid = pid
      self.pollInterval = pollInterval
      self.post = post ?? Self.postLive
    }

    // MARK: - Lifecycle

    func install() {
      guard observer == nil else { return }
      observer = DistributedNotificationCenter.default().addObserver(
        forName: Self.requestName, object: nil, queue: .main
      ) { [weak self] note in
        // Extracted BEFORE entering the isolated block: the closure's `Notification` is
        // task-isolated and cannot be read from inside `assumeIsolated`
        // (`swift-concurrency-patterns.md` extract-before-assumeisolated).
        let info = Self.strings(from: note.userInfo)
        MainActor.assumeIsolated { self?.handle(info) }
      }
    }

    func uninstall() {
      if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
      observer = nil
      walkTask?.cancel()
      walkTask = nil
      inFlight = nil
    }

    // MARK: - Requests

    /// Handles one request. Public for tests; the observer is the live caller.
    func handle(_ info: [String: String]) {
      // Every instance receives every post. Another instance's request is not ours to
      // answer, not even with a refusal: two answers to one request is the confusion the
      // PID is there to prevent.
      guard let pidField = info["pid"], Int32(pidField) == pid else { return }
      let request = info["request"] ?? ""
      let kind = info["kind"] ?? ""
      switch kind {
      case "discover":
        reply(request, ["status": "alive", "acceptance": acceptance() ?? "accept"])
      case "transcribe":
        handleTranscribe(request: request, info: info)
      default:
        reply(request, ["status": "malformed", "reason": "kind"])
      }
    }

    private func handleTranscribe(request: String, info: [String: String]) {
      guard !request.isEmpty, UUID(uuidString: request) != nil else {
        reply(request, ["status": "malformed", "reason": "request"])
        return
      }
      guard !seenRequests.contains(request) else {
        reply(request, ["status": "duplicate"])
        return
      }
      seenRequests.insert(request)
      guard info["launch"] == launchID.uuidString else {
        reply(request, ["status": "wrongLaunch"])
        return
      }
      guard let path = info["path"], path.hasPrefix("/") else {
        reply(request, ["status": "malformed", "reason": "path"])
        return
      }
      let timeout: Double
      if let raw = info["timeout"] {
        guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
          reply(request, ["status": "malformed", "reason": "timeout"])
          return
        }
        timeout = min(seconds, Self.maxTimeoutSeconds)
      } else {
        timeout = Self.defaultTimeoutSeconds
      }
      // Refused BEFORE `choose(url:)`, which refuses silently while a run is in flight and,
      // during a decode, silently supersedes the user's file. Neither must read as
      // acceptance.
      if let reason = acceptance() {
        reply(request, ["status": "busy", "reason": reason])
        return
      }
      // Reserved before the reply so a second request arriving between the two reads busy.
      inFlight = request
      reply(request, ["status": "accepted"])
      coordinator.choose(url: URL(fileURLWithPath: path))
      // Captured HERE, synchronously after `choose(url:)`, never inside the task: the task
      // runs after the caller's next suspension, and a user's own `choose(url:)` in
      // between would be read as the door's generation, so the door would walk and
      // start the USER's file. Found by `replacedDuringDecodeIsSuperseded`.
      let generation = coordinator.generation
      watchedGeneration = generation
      let deadline = ContinuousClock.now + .seconds(timeout)
      walkTask = Task { [weak self] in
        guard let self else { return }
        let observed = await walk(from: generation, deadline: deadline)
        guard !Task.isCancelled else { return }
        // The coordinator can move between the walk's last poll and this line; a reply
        // must describe the run it watched, never whatever is there now.
        let outcome = coordinator.generation == watchedGeneration ? observed : .superseded
        var fields = outcome.fields
        // Only a run this door started may claim a row; `superseded` names nothing, so a
        // caller can never read another import's History id as its own.
        if outcome.claimsRun {
          if let id = coordinator.historyID { fields["history"] = id.uuidString }
          if let model = coordinator.runConfiguration?.polishModel { fields["polisher"] = model }
          // `.finished` follows a failed save too (`finishRun(savingDocument: false)`), and a
          // refusal before any save has no failure to report, so persistence is its own
          // field read from the coordinator's own answer, and the caller validates the
          // stored row itself.
          fields["saved"] = coordinator.isSavedToHistory ? "true" : "false"
        }
        inFlight = nil
        walkTask = nil
        reply(request, fields)
      }
    }

    /// Why a `transcribe` would be refused right now, or nil to accept. Asked by `discover`
    /// too, so a caller can see a busy door before it posts work.
    ///
    /// A separate policy from the coordinator's own gates, on purpose: `canGo` governs
    /// navigation and `hasDocument` would refuse a FINISHED document, which is exactly the
    /// case `choose(url:)` replaces cleanly. What this refuses is a user's file in hand
    /// (`.reading`, `.ready`) that a second `choose` would silently supersede.
    func acceptance() -> String? {
      if inFlight != nil { return "requestInFlight" }
      if coordinator.isRunning { return "running" }
      if coordinator.isSettlingTurns { return "settling" }
      switch coordinator.state {
      case .reading, .ready: return "fileInHand"
      case .idle, .transcribing, .polishing, .finished, .rejected, .stopped: return nil
      }
    }

    // MARK: - The walk

    struct Outcome: Equatable, Sendable {
      let status: String
      let detail: String?
      var fields: [String: String] {
        var out = ["status": status]
        if let detail { out["reason"] = detail }
        return out
      }
      /// Whether the run this outcome describes is one the door started, so its History
    /// row, polisher and save status belong in the reply.
    var claimsRun: Bool { ["finished", "refused"].contains(status) }
    static let superseded = Outcome(status: "superseded", detail: nil)
      static let timeout = Outcome(status: "timeout", detail: nil)
      static func unexpected(_ what: String) -> Outcome {
        Outcome(status: "unexpected", detail: what)
      }
    }

    /// Watches the coordinator from the decode to the settled document and returns what
    /// happened. `chosenGeneration` is the coordinator's generation as read synchronously
    /// after the door's own `choose(url:)`; if it moves before our own Start, the user
    /// picked another file during the decode and the door reports `superseded` without
    /// claiming that import's row.
    func walk(from chosenGeneration: Int, deadline: ContinuousClock.Instant) async -> Outcome {
      let c = coordinator
      var generation = chosenGeneration
      var started = false
      while ContinuousClock.now < deadline {
        if Task.isCancelled { return Outcome(status: "cancelled", detail: nil) }
        // Strict, before and after Start. Before it, the only other writer is a user's
        // `choose(url:)` during the decode. After it, `stop()`, `rePolish()` and a new
        // `choose(url:)` each bump the generation, and each makes what follows a
        // different run: a replacement that reaches Done between two polls must never be
        // reported as this request's result (Codex, code review round 1).
        guard c.generation == generation else { return .superseded }
        if !started {
          switch c.state {
          case .ready:
            guard c.step == .upload else { return .unexpected("step=\(c.step)") }
            for target in [FileImportCoordinator.Step.transcription, .polish, .review] {
              c.advance()
              guard c.step == target else { return .unexpected("step=\(c.step)") }
            }
            // Start. `advance()` at `.review` with no transcript in hand calls `start()`,
            // which bumps the generation itself; re-captured so the guard above keeps
            // watching THIS run.
            c.advance()
            generation = c.generation
            watchedGeneration = generation
            started = true
          case .rejected(let reason):
            return Outcome(status: "refused", detail: Self.name(of: reason))
          case .idle:
            return .unexpected("state=idle")
          case .reading, .transcribing, .polishing, .finished, .stopped:
            break
          }
        } else {
          switch c.state {
          case .finished where !c.isSettlingTurns:
            return Outcome(status: "finished", detail: nil)
          case .rejected(let reason) where !c.isSettlingTurns:
            return Outcome(status: "refused", detail: Self.name(of: reason))
          case .idle:
            return .unexpected("state=idle")
          // `.stopped` is unreachable under the guard above: `stop()` bumps the
          // generation first, so a stopped run reads `superseded`.
          case .reading, .ready, .transcribing, .polishing, .finished, .stopped, .rejected:
            break
          }
        }
        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          return Outcome(status: "cancelled", detail: nil)
        }
      }
      return .timeout
    }

    // MARK: - Replies

    private func reply(_ request: String, _ fields: [String: String]) {
      var out = fields
      out["request"] = request
      out["pid"] = String(pid)
      out["launch"] = launchID.uuidString
      post(out)
    }

    private static func postLive(_ fields: [String: String]) {
      DistributedNotificationCenter.default().postNotificationName(
        replyName, object: nil, userInfo: fields, deliverImmediately: true)
      let line = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
      // The category already renders as `[DebugImportDoor]`; the message carries only the
      // fields, so the line the UAT reader greps is `[DebugImportDoor] request=… status=…`.
      Task { await AppLogger.shared.log(line, category: "DebugImportDoor") }
    }

    nonisolated private static func strings(from userInfo: [AnyHashable: Any]?) -> [String: String] {
      var out: [String: String] = [:]
      for (key, value) in userInfo ?? [:] {
        guard let key = key as? String else { continue }
        out[key] = String(describing: value)
      }
      return out
    }

    private static func name(of reason: FileImportCoordinator.FileImportRejection) -> String {
      switch reason {
      case .cannotRead: return "cannotRead"
      case .noAudio: return "noAudio"
      case .noSpeechFound: return "noSpeechFound"
      case .engineBusy: return "engineBusy"
      case .engineNotInstalled: return "engineNotInstalled"
      case .engineNotReady: return "engineNotReady"
      case .polisherNotReady: return "polisherNotReady"
      case .failed(let message): return "failed:\(message)"
      }
    }
  }
#endif
