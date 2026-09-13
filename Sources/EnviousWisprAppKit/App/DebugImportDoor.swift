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
    /// The screen's own gate on Continue and Start (`FileImportPolishGate.readiness`),
    /// asked for the engine this import will use. The door walks the coordinator directly,
    /// which has no such gate of its own, so without this it would start a configuration
    /// the screen refuses and report `finished` over raw passages (cloud review, PR #2887).
    /// Async because the answer can need a probe the screen would have run on appear:
    /// Ollama's state stays `.detecting` from launch until something calls `detectState`,
    /// and the door has no screen (cloud review, PR #2887, round 7).
    private let polishReadiness: @MainActor () async -> FileImportPolishReadiness
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
      polishReadiness: @escaping @MainActor () async -> FileImportPolishReadiness,
      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
      pollInterval: Duration = .milliseconds(100),
      post: (@MainActor ([String: String]) -> Void)? = nil
    ) {
      self.coordinator = coordinator
      self.polishReadiness = polishReadiness
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

    /// Returns the cancelled walk, if one was in flight, so a caller that must know the
    /// cancellation LANDED (a test asserting "no reply") can await it rather than yield
    /// and hope. Cancellation is a flag; the task runs until its next check.
    @discardableResult
    func uninstall() -> Task<Void, Never>? {
      let pending = walkTask
      if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
      observer = nil
      pending?.cancel()
      walkTask = nil
      inFlight = nil
      return pending
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
        // Identity and the acceptance rule, answered at once. The polish gate is NOT asked
        // here: it can probe a daemon, and a discover that waits on a probe is a discover
        // that can time out; the `transcribe` reply carries the gate's verdict.
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
      // Reserved BEFORE the readiness probe suspends, so a second request arriving while
      // the probe runs reads busy rather than racing it.
      inFlight = request
      let deadline = ContinuousClock.now + .seconds(timeout)
      walkTask = Task { [weak self] in
        guard let self else { return }
        // The screen's Continue is disabled for this; the door refuses the same way, before
        // any file is chosen. Checked again before Start, because a key can be saved or a
        // daemon can stop during the decode.
        let readiness = await polishReadiness()
        // Everything below assumes the world of before the probe; the probe suspended.
        // Cancelled (uninstall) means no reply and no file; a deadline spent on the probe
        // means timeout, never a late `choose(url:)` nobody is watching.
        guard !Task.isCancelled else { return }
        guard ContinuousClock.now < deadline else {
          inFlight = nil
          walkTask = nil
          reply(request, ["status": "timeout", "reason": "probe"])
          return
        }
        if case .blocked(let block) = readiness {
          inFlight = nil
          walkTask = nil
          reply(request, ["status": "refused", "reason": "polishNotReady", "block": "\(block)"])
          return
        }
        // The coordinator may have moved meanwhile (a user picked a file). Re-asked with
        // the reservation excluded, since that reservation is ours.
        if let reason = acceptance(ignoringReservation: true) {
          inFlight = nil
          walkTask = nil
          reply(request, ["status": "busy", "reason": reason])
          return
        }
        reply(request, ["status": "accepted"])
        coordinator.choose(url: URL(fileURLWithPath: path))
        // Captured HERE, synchronously after `choose(url:)`, before any suspension: a
        // user's own `choose(url:)` after a suspension would be read as the door's
        // generation, so the door would walk and start the USER's file. Found by
        // `replacedDuringDecodeIsSuperseded`.
        let generation = coordinator.generation
        watchedGeneration = generation
        let observed = await walk(from: generation, deadline: deadline)
        guard !Task.isCancelled else { return }
        // The coordinator can move between the walk's last poll and this line; a reply
        // must describe the run it watched, never whatever is there now.
        let outcome = coordinator.generation == watchedGeneration ? observed : .superseded
        releaseOwnFileIfStillHeld()
        var fields = outcome.fields
        // Only a run this door started may claim a row; `superseded` names nothing, so a
        // caller can never read another import's History id as its own.
        if outcome.claimsRun, let id = coordinator.historyID {
          fields["history"] = id.uuidString
          // `.finished` follows a failed save too (`finishRun(savingDocument: false)`), so
          // persistence is its own field read from the coordinator's own answer, and the
          // caller validates the stored row itself. `choose(url:)` clears the row identity,
          // so a refusal before any persist carries neither field.
          fields["saved"] = coordinator.isSavedToHistory ? "true" : "false"
        }
        // `choose(url:)` clears `runConfiguration`, so a non-nil value here was minted by
        // THIS run's `beginRun()`: present on a finish and on a refusal raised after
        // Start (transcription threw, no speech, polisher not ready), absent on a refusal
        // before it (unreadable file, engine busy). Cloud review, PR #2887, rounds 2-3.
        if outcome.claimsRun, let model = coordinator.runConfiguration?.polishModel {
          fields["polisher"] = model
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
    func acceptance(ignoringReservation: Bool = false) -> String? {
      if !ignoringReservation, inFlight != nil { return "requestInFlight" }
      if coordinator.isRunning { return "running" }
      if coordinator.isSettlingTurns { return "settling" }
      // `isReadyToRun` is `.ready` OR a refusal about the ENGINE with the audio still in
      // hand (`canRetry`: the screen offers Try again). Both are a user's file the door
      // must not replace. A refusal about the FILE or the polisher leaves nothing the
      // door would take away, and `choose(url:)` clears it as the picker would (cloud
      // review, PR #2887).
      if coordinator.isReadyToRun { return "fileInHand" }
      if case .reading = coordinator.state { return "fileInHand" }
      // A finished document whose words are not in History (the raw write failed) exists
      // only on screen; `choose(url:)` clears the transcript, so the door would discard the
      // user's only copy. A saved document is replaceable exactly as the picker treats it.
      if coordinator.hasDocument, !coordinator.isSavedToHistory { return "unsavedDocument" }
      return nil
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
            let readiness = await polishReadiness()
            // The probe suspended. Before EITHER branch: a cancellation means no reply;
            // a moved generation means the user took the coordinator and this file is no
            // longer ours to start OR to clear; a spent deadline means timeout, with the
            // door's own file released below.
            if Task.isCancelled { return Outcome(status: "cancelled", detail: nil) }
            guard c.generation == generation else { return .superseded }
            guard ContinuousClock.now < deadline else { return .timeout }
            if case .blocked(let block) = readiness {
              return Outcome(status: "refused", detail: "polishNotReady:\(block)")
            }
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

    /// The ONE exit-side rule for the door's own file, applied after every walk, whatever
    /// its outcome: if the coordinator is still ours (generation unmoved) and holds audio
    /// in hand (`isReadyToRun`: `.ready`, or a refusal about the ENGINE with the decoded
    /// audio kept for the screen's Try again) or is still reading it, release it the way
    /// the screen releases its own (`startOver()`). Left there, that file reads as a
    /// user's file in hand and blocks every later request, and the door exposes no Try
    /// again. One rule at the exit instead of one per branch, because the branches kept
    /// growing (late block, timeout, then an engine refusal at Start: cloud review, PR
    /// #2887, rounds 5, 9 and 10). A finished or stopped run holds no audio and is left
    /// alone; a coordinator the user took is not ours to touch.
    private func releaseOwnFileIfStillHeld() {
      let c = coordinator
      guard c.generation == watchedGeneration else { return }
      var reading = false
      if case .reading = c.state { reading = true }
      guard c.isReadyToRun || reading else { return }
      c.startOver()
      // Our own write; the reply check must not read it as someone else's.
      watchedGeneration = c.generation
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
