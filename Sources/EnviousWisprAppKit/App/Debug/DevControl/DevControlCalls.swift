#if DEBUG
  import EnviousWisprAudio
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation

  /// #4012: call detection through the DEBUG control door. `call.simulate` replaces the
  /// microphone watcher's holders and the Accessibility evidence with faked ones; the rules,
  /// the panel, every Start and every Stop run as in production. A faked holder carries no
  /// address or title beyond the meeting URL the caller passes, which is classified and never
  /// logged.
  @MainActor
  final class DevControlCalls {
    typealias Result = DevControlDispatcher.Result

    struct Sources {
      let coordinator: @MainActor () -> CallDetectionCoordinator?
    }

    /// Fake pids start here, far above real ones on macOS.
    static let firstFakePID: Int32 = 900_000
    static let buttons: Set<String> = [
      "yes", "no", "keepRecording", "startNewRecording", "openSettings", "close",
    ]

    private let sources: Sources

    init(sources: Sources) {
      self.sources = sources
    }

    static func unwired() -> DevControlCalls {
      DevControlCalls(sources: Sources(coordinator: { nil }))
    }

    /// `{}` reads the state. `{holders: [...]}` starts or replaces a simulation; each holder is
    /// `{bundleID, input: active|inactive|unknown, evidence: call|none|unknown, url?, pid?}`.
    /// `{clear: true}` ends it. `{press: <button>}` presses a button the panel shows.
    func simulate(_ args: [String: Any]) -> Result {
      guard Set(args.keys).isSubset(of: ["holders", "clear", "press"]), args.count <= 1 else {
        return .failure(.badArgs, "call.simulate takes one of holders, clear or press")
      }
      guard let coordinator = sources.coordinator() else {
        return .failure(.notWired, "call detection is not wired")
      }
      var pressed: Bool?
      if let value = args["clear"] {
        guard DevControlSettings.Codec.bool(value) == true else {
          return .failure(.badArgs, "clear must be true")
        }
        coordinator.simulate(nil)
      } else if let value = args["press"] {
        guard let button = value as? String, Self.buttons.contains(button) else {
          return .failure(.badArgs, "press must name a panel button")
        }
        pressed = coordinator.press(button)
      } else if let value = args["holders"] {
        guard let rows = value as? [[String: Any]] else {
          return .failure(.badArgs, "holders must be a list of objects")
        }
        var list: [CallDetectionCoordinator.SimulatedHolder] = []
        for (index, row) in rows.enumerated() {
          switch Self.holder(row, defaultPID: Self.firstFakePID + Int32(index)) {
          case .failure(let message): return .failure(.badArgs, message)
          case .success(let holder): list.append(holder)
          }
        }
        coordinator.simulate(list)
      }
      return .ok(Self.state(coordinator, pressed: pressed))
    }

    private enum HolderParse {
      case success(CallDetectionCoordinator.SimulatedHolder)
      case failure(String)
    }

    private static func holder(_ row: [String: Any], defaultPID: Int32) -> HolderParse {
      guard Set(row.keys).isSubset(of: ["bundleID", "input", "evidence", "url", "pid"]) else {
        return .failure("a holder takes bundleID, input, evidence, url and pid only")
      }
      guard let bundleID = row["bundleID"] as? String,
        let rule = CallAppCatalog.rule(forBundleID: bundleID)
      else { return .failure("bundleID must be a call app in the catalog") }
      let input: CallMicrophoneWatcher.Input
      switch row["input"] as? String {
      case "active": input = .active
      case "inactive": input = .inactive
      case "unknown": input = .unknown
      default: return .failure("input must be active, inactive or unknown")
      }
      var pid = defaultPID
      if let value = row["pid"] {
        guard let number = value as? Int, number >= Int(firstFakePID), number < Int(Int32.max)
        else { return .failure("pid must be a whole number from \(firstFakePID)") }
        pid = Int32(number)
      }
      let evidence: CallEvidenceReader.Evidence
      switch row["evidence"] as? String {
      case "unknown": evidence = .unknown
      case "none": evidence = .none
      case "call":
        switch rule {
        case .callApp(let family), .callWindow(let family):
          evidence = .call(family: family, room: "pid-\(pid)")
        case .browser:
          guard let url = row["url"] as? String, let match = CallMeetingURL.classify(url) else {
            return .failure("a browser call needs a url the meeting rules recognise")
          }
          evidence = .call(family: match.family, room: match.room)
        }
      default: return .failure("evidence must be call, none or unknown")
      }
      return .success(
        .init(
          holder: .init(pid: pid, bundleID: bundleID.lowercased(), input: input), evidence: evidence
        ))
    }

    private static func state(_ coordinator: CallDetectionCoordinator, pressed: Bool?) -> [String:
      Any]
    {
      var reply: [String: Any] = [
        "simulating": coordinator.simulation != nil,
        "watching": coordinator.isWatching,
        "panel": NSNull(), "panelApp": NSNull(), "secondsLeft": NSNull(),
      ]
      if let pressed { reply["pressed"] = pressed }
      switch coordinator.panelContent {
      case nil: break
      case .ask(let app):
        reply["panel"] = "ask"
        reply["panelApp"] = app
      case .switchMeeting(let app):
        reply["panel"] = "switchMeeting"
        reply["panelApp"] = app
      case .countdown(let seconds):
        reply["panel"] = "countdown"
        reply["secondsLeft"] = seconds
      case .stopped: reply["panel"] = "stopped"
      case .switchNotConfirmed: reply["panel"] = "switchNotConfirmed"
      case .needsAttention: reply["panel"] = "needsAttention"
      case .couldNotStart: reply["panel"] = "couldNotStart"
      case .firstTip: reply["panel"] = "firstTip"
      case .lastTip(let app):
        reply["panel"] = "lastTip"
        reply["panelApp"] = app
      }
      return reply
    }
  }
#endif
