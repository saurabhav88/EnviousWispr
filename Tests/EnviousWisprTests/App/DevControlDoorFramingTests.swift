#if DEBUG
  import Darwin
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// #3765: the dev control door, driven by the real Python client over a real Unix socket.
  ///
  /// Harness Contract: the door is the instrument agents drive the dev build through. When
  /// this fails, a UAT script reaches no app, the wrong app, or an app another user could
  /// reach; no customer sees any of it.
  @Suite(.serialized, .tags(.harnessContract))
  @MainActor
  struct DevControlDoorFramingTests {
    private static var repoRoot: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // App
        .deletingLastPathComponent()  // EnviousWisprTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    }

    struct ChildOutput: Sendable {
      let stdout: Data
      let stderr: Data
      let status: Int32
      let exitedNormally: Bool
    }

    /// Runs the child to completion off the main actor, so the door can answer.
    /// `@concurrent` offloads the blocking subprocess work without a detached task.
    /// Stderr goes to a file so a full stderr pipe cannot block stdout draining.
    @concurrent
    nonisolated private static func runPython(_ script: String) async throws -> ChildOutput {
      let process = Process()
      let pipe = Pipe()
      let errorsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ewdc-stderr-\(UUID().uuidString)")
      guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      defer { try? FileManager.default.removeItem(at: errorsURL) }
      let errors = try FileHandle(forWritingTo: errorsURL)
      defer { try? errors.close() }

      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["python3", "-I", "-c", script]
      process.standardOutput = pipe
      process.standardError = errors
      try process.run()
      let stdout = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return ChildOutput(
        stdout: stdout, stderr: try Data(contentsOf: errorsURL),
        status: process.terminationStatus, exitedNormally: process.terminationReason == .exit)
    }

    /// A real dispatcher over isolated settings, with no discovered models, no connected
    /// input devices, plain status facts, the given History rows and word library.
    private static func dispatcher(
      status: DevControlFixtures.StatusFake = DevControlFixtures.StatusFake(),
      rows: [Transcript] = [],
      words: CustomWordsCoordinator = DevControlFixtures.unwrittenWords(),
      models: DevControlFixtures.ModelFake = DevControlFixtures.ModelFake()
    ) -> DevControlDispatcher {
      let defaults = TestDefaults.suite("ew.tests.3765.framing.\(UUID().uuidString)")!
      return DevControlDispatcher(
        settings: SettingsManager(defaults: defaults),
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          connectedInputUIDs: { [] }),
        status: status.sources,
        history: DevControlFixtures.history(rows),
        models: models.actions,
        words: words)
    }

    /// The Python source for a child that has imported `Tests/RuntimeUAT/dev_control.py`
    /// and then runs `body`.
    private static func clientScript(_ body: String) -> String {
      let runtimeUAT = repoRoot.appendingPathComponent("Tests/RuntimeUAT").path
      return """
        import json, sys
        sys.path.insert(0, \(String(reflecting: runtimeUAT)))
        import dev_control
        \(body)
        """
    }

    /// The child must exit 0 with empty stderr and print one JSON object as its last
    /// stdout line.
    private func parse(_ captured: ChildOutput) throws -> [String: Any] {
      let diagnostics = String(decoding: captured.stderr, as: UTF8.self)
      try #require(
        captured.exitedNormally && captured.status == 0,
        "Python child failed: \(captured.status), \(diagnostics)")
      try #require(captured.stderr.isEmpty, "Python stderr: \(diagnostics)")
      let text = String(decoding: captured.stdout, as: UTF8.self)
      let line = try #require(
        text.split(separator: "\n").last.map(String.init), "client printed nothing: \(text)")
      let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
      return try #require(object as? [String: Any], "client output is not an object: \(text)")
    }

    /// Runs `body` in a Python client child to completion. The client's socket timeout
    /// bounds each socket operation.
    private func runClient(_ body: String) async throws -> [String: Any] {
      try parse(try await Self.runPython(Self.clientScript(body)))
    }

    /// Uninstalls and waits until the listener has really stopped, so the next test's door
    /// may claim the same pathname (the door keeps its claim until then).
    private func stop(_ door: DevControlDoor) async throws {
      door.uninstall()
      try #require(
        await settleUntilObserved { door.listenerHasStopped }, "listener never reported stopped")
    }

    /// Python for "this connection was closed by the door": no buffered reply, then EOF or
    /// reset. A timeout or unexpected bytes fail the child instead of passing as "closed".
    /// Ends with a newline so a body can follow it directly.
    private static let requireClosed = #"""
      def require_closed(c):
          assert not c._buffer, "unexpected buffered reply"
          try:
              assert c._sock.recv(1) == b"", "unexpected bytes after closure"
          except ConnectionResetError:
              pass

      """#

    @Test("a real Python client pings the real door and reads its identity")
    func realPythonClientPingsTheRealDoor() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      let installed = await door.install()
      try #require(installed == .ready, "install returned \(installed)")

      #expect(door.socketPath.utf8.count + 1 <= DevControlDoor.sunPathCapacity)
      var dirInfo = stat()
      try #require(lstat(DevControlDoor.socketDirectory(), &dirInfo) == 0)
      #expect((dirInfo.st_mode & 0o777) == 0o700)
      #expect(dirInfo.st_uid == geteuid())
      #expect(DevControlDoor.socketModeIsPrivate(door.socketPath))

      let reply = try await runClient(
        "print(json.dumps(dev_control.ping(\(door.pid))))")
      #expect(reply["ok"] as? Bool == true)
      #expect(reply["door"] as? Int == DevControlDoor.protocolVersion)
      #expect(reply["pid"] as? Int == Int(door.pid))
      #expect(reply["launch"] as? String == door.launchID.uuidString)
      #expect(reply["executable"] as? String == door.executablePath)
      let result = try #require(reply["result"] as? [String: Any])
      #expect(result["pong"] as? Bool == true)

      try await stop(door)
      var gone = stat()
      let goneStatus = lstat(door.socketPath, &gone)
      let goneErrno = errno  // read before any other call can overwrite it
      #expect(goneStatus == -1)
      #expect(goneErrno == ENOENT)

      let afterwards = try await runClient(
        """
        try:
            dev_control.ping(\(door.pid), timeout=2)
            print(json.dumps({"reached": True}))
        except dev_control.DoorError as error:
            print(json.dumps({"reached": False, "error": str(error)}))
        """)
      #expect(afterwards["reached"] as? Bool == false)
    }

    @Test("two requests on one connection are answered in order")
    func sequentialRequestsOnOneConnection() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        """
        with dev_control.Connection(\(door.pid)) as c:
            a = c.request("ping", request_id="first")
            b = c.request("nope", request_id="second")
        print(json.dumps({"a": a, "b": b}))
        """)
      let first = try #require(reply["a"] as? [String: Any])
      let second = try #require(reply["b"] as? [String: Any])
      #expect(first["id"] as? String == "first")
      #expect(first["ok"] as? Bool == true)
      #expect(second["id"] as? String == "second")
      #expect(second["ok"] as? Bool == false)
      let error = try #require(second["error"] as? [String: Any])
      #expect(error["code"] as? String == "unknownCommand")
      try await stop(door)
    }

    @Test("an unsafe directory or a foreign entry at the socket path is refused")
    func unsafePathsRefuse() throws {
      let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("ewdc-\(UUID().uuidString.prefix(8))")
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: base) }

      let open = base.appendingPathComponent("open")
      try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
      chmod(open.path, 0o755)
      #expect(
        DevControlDoor.unsafePathReason(open.appendingPathComponent("1.sock").path) == "dirUnsafe")

      let real = base.appendingPathComponent("real")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
      chmod(real.path, 0o700)
      let link = base.appendingPathComponent("link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
      #expect(
        DevControlDoor.unsafePathReason(link.appendingPathComponent("1.sock").path) == "dirUnsafe")

      let file = real.appendingPathComponent("2.sock")
      FileManager.default.createFile(atPath: file.path, contents: Data())
      #expect(DevControlDoor.unsafePathReason(file.path) == "socketUnsafe")
      #expect(FileManager.default.fileExists(atPath: file.path))

      #expect(DevControlDoor.unsafePathReason(real.appendingPathComponent("3.sock").path) == nil)
    }

    // MARK: - Chunk 2: framing, bounds, ordering, shutdown, logging

    /// A handler that records each call and holds it until `open()`: the subject's own
    /// entry is the signal tests wait on.
    @MainActor
    final class Gate {
      private(set) var entered = 0
      private var isOpen = false
      private var waiters: [CheckedContinuation<Void, Never>] = []

      func pass() async {
        entered += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
      }

      func open() {
        isOpen = true
        let held = waiters
        waiters.removeAll()
        for waiter in held { waiter.resume() }
      }
    }

    private func gatedDoor(_ gate: Gate) -> DevControlDoor {
      DevControlDoor(handler: { _, _ in
        await gate.pass()
        return .ok(["pong": true])
      })
    }

    @Test("coalesced frames and a frame split inside a multibyte character are each answered")
    func framesSurviveCoalescingAndSplits() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        c.send_raw(b'{"id":"a","cmd":"ping"}\n{"id":"b","cmd":"ping"}\n')
        r1 = c.read_reply(); r2 = c.read_reply()
        raw = ('{"id":"caf' + chr(0xE9) + '","cmd":"ping"}' + chr(10)).encode("utf-8")
        cut = raw.index(b"\xc3") + 1
        c.send_raw(raw[:cut]); c.send_raw(raw[cut:])
        r3 = c.read_reply()
        print(json.dumps({"ids": [r1["id"], r2["id"], r3["id"]], "oks": [r1["ok"], r2["ok"], r3["ok"]]}))
        """#)
      #expect(reply["ids"] as? [String] == ["a", "b", "caf\u{E9}"])
      #expect(reply["oks"] as? [Bool] == [true, true, true])
      try await stop(door)
    }

    @Test("malformed frames are refused in order and the connection keeps working")
    func malformedFramesAreRefusedInOrder() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        frames = [
            b'\xff\xfe\n',
            b'[1,2]\n',
            b'{"cmd":5}\n',
            b'{"id":7,"cmd":"ping"}\n',
            b'{"id":"' + b'x' * 129 + b'","cmd":"ping"}\n',
            b'{"id":"k","cmd":"ping","args":[1]}\n',
        ]
        codes = []
        for frame in frames:
            c.send_raw(frame)
            codes.append(c.read_reply()["error"]["code"])
        last = c.request("ping", request_id="after")
        print(json.dumps({"codes": codes, "after": last["ok"]}))
        """#)
      #expect(reply["codes"] as? [String] == Array(repeating: "malformed", count: 6))
      #expect(reply["after"] as? Bool == true)
      try await stop(door)
    }

    @Test("a frame cut off by EOF is answered incompleteFrame, then the door closes")
    func incompleteFrameAtEOF() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        Self.requireClosed
          + #"""
          c = dev_control.Connection(\#(door.pid), timeout=5)
          c.send_raw(b'{"cmd":"ping"')
          c.finish_sending()
          code = c.read_reply()["error"]["code"]
          require_closed(c)
          print(json.dumps({"code": code, "closed": True}))
          """#)
      #expect(reply["code"] as? String == "incompleteFrame")
      #expect(reply["closed"] as? Bool == true)
      try await stop(door)
    }

    @Test("a frame of exactly the limit is accepted; one byte over, or no newline past it, is refused")
    func requestFrameLimit() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        Self.requireClosed
          + #"""
          def frame(pad):
              return json.dumps({"id": "x", "cmd": "ping", "args": {"pad": "a" * pad}}, separators=(",", ":")).encode()
          base = len(frame(0))
          limit = dev_control.MAX_FRAME_BYTES
          exact = frame(limit - base)
          assert len(exact) == limit
          c = dev_control.Connection(\#(door.pid), timeout=5)
          c.send_raw(exact + b"\n")
          at_limit = c.read_reply()["ok"]
          c.send_raw(frame(limit - base + 1) + b"\n")
          over = c.read_reply()["error"]["code"]
          require_closed(c)
          d = dev_control.Connection(\#(door.pid), timeout=5)
          d.send_raw(b"a" * (limit + 10))
          runaway = d.read_reply()["error"]["code"]
          require_closed(d)
          print(json.dumps({"at_limit": at_limit, "over": over, "runaway": runaway, "closed": True}))
          """#)
      #expect(reply["at_limit"] as? Bool == true)
      #expect(reply["over"] as? String == "tooLarge")
      #expect(reply["runaway"] as? String == "tooLarge")
      #expect(reply["closed"] as? Bool == true)
      try await stop(door)
    }

    @Test("an oversized reply is replaced whole by responseTooLarge carrying identity, and the log says so")
    func oversizedReplyIsRefusedWhole() async throws {
      let door = DevControlDoor(handler: { _, _ in
        .ok(["blob": String(repeating: "a", count: 2 << 20)])
      })
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        r = dev_control.request(\#(door.pid), "ping", {"note": "client-secret-arg"})
        print(json.dumps(r))
        """#)
      #expect(reply["ok"] as? Bool == false)
      let error = try #require(reply["error"] as? [String: Any])
      #expect(error["code"] as? String == "responseTooLarge")
      #expect(reply["pid"] as? Int == Int(door.pid))
      #expect(reply["launch"] as? String == door.launchID.uuidString)
      #expect(reply["executable"] as? String == door.executablePath)
      #expect(reply["door"] as? Int == DevControlDoor.protocolVersion)

      try #require(outcomes.count == 1, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=ping ok=false forced=false code=responseTooLarge"))
      #expect(outcomes[0].contains("client-secret-arg") == false)
      let clientID = try #require(reply["id"] as? String)
      #expect(outcomes[0].contains(clientID) == false)
      try await stop(door)
    }

    @Test("a forced write whose reply is too large still logs forced=true")
    func forcedWriteKeepsAttributionWhenReplyOverflows() async throws {
      let door = DevControlDoor(handler: { _, _ in
        .ok(["blob": String(repeating: "a", count: 2 << 20)], forced: true)
      })
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        print(json.dumps(dev_control.request(\#(door.pid), "ping")))
        """#)
      #expect((reply["error"] as? [String: Any])?["code"] as? String == "responseTooLarge")
      try #require(outcomes.count == 1, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=ping ok=false forced=true code=responseTooLarge"))
      try await stop(door)
    }

    @Test("framing refusals log cmd=none and never the client's id or command text")
    func refusalsLogSanitizedOutcomes() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      _ = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        c.send_raw(b'{"id":"client-id-zzz","cmd":5}\n')
        c.read_reply()
        c.send_raw(b'{"id":"client-id-yyy","cmd":"drop-tables"}\n')
        c.read_reply()
        print(json.dumps({}))
        """#)
      #expect(outcomes.count == 2)
      #expect(outcomes.first?.contains("cmd=none ok=false forced=false code=malformed") == true)
      #expect(outcomes.last?.contains("cmd=unknown ok=false forced=false code=unknownCommand") == true)
      for line in outcomes {
        #expect(line.contains("client-id") == false)
        #expect(line.contains("drop-tables") == false)
      }
      try await stop(door)
    }

    @Test("a real socket settings.set reaches the table, and the forced log carries no value")
    func settingsSetOverTheSocket() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        forced = c.request("settings.set", {"key": "toggleKeyCode", "value": 4321, "force": True})
        plain = c.request("settings.set", {"key": "toggleKeyCode", "value": 4322})
        got = c.request("settings.get", {"key": "toggleKeyCode"})
        listed = c.request("settings.list")
        print(json.dumps({"forced": forced, "plain": plain, "got": got, "count": len(listed["result"]["settings"])}))
        """#)
      let forced = try #require(reply["forced"] as? [String: Any])
      #expect(forced["ok"] as? Bool == true)
      #expect((forced["result"] as? [String: Any])?["forced"] as? Bool == true)
      let plain = try #require(reply["plain"] as? [String: Any])
      #expect((plain["error"] as? [String: Any])?["code"] as? String == "checkNotYetShared")
      let got = try #require(reply["got"] as? [String: Any])
      #expect((got["result"] as? [String: Any])?["value"] as? Int == 4321)
      #expect(reply["count"] as? Int == 70)

      try #require(outcomes.count == 4, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=settings.set ok=true forced=true code=none"))
      #expect(outcomes[1].contains("cmd=settings.set ok=false forced=false code=checkNotYetShared"))
      #expect(outcomes[2].contains("cmd=settings.get ok=true forced=false code=none"))
      for line in outcomes {
        #expect(line.contains("4321") == false)
        #expect(line.contains("4322") == false)
        #expect(line.contains("toggleKeyCode") == false)
      }
      try await stop(door)
    }

    @Test("status and History over the socket; a History row too large to send is refused whole")
    func statusAndHistoryOverTheSocket() async throws {
      let small = Transcript(text: "small row", polishedText: "Small row.")
      let huge = Transcript(text: String(repeating: "a", count: 2 << 20))
      let fake = DevControlFixtures.StatusFake()
      fake.engine = DevControlFixtures.engine(selected: .whisper, active: .parakeet)
      fake.driverStates = [.parakeet: .transcribing, .whisper: .idle]
      let door = DevControlDoor(dispatcher: Self.dispatcher(status: fake, rows: [huge, small]))
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        status = c.request("status")
        listed = c.request("history.list", {"limit": 5})
        got = c.request("history.get", {"id": "\#(small.id.uuidString)"})
        big = c.request("history.get", {"id": "\#(huge.id.uuidString)"})
        bad = c.request("history.list", {"limit": True})
        print(json.dumps({"status": status, "listed": listed, "got": got, "big": big, "bad": bad}))
        """#)
      let status = try #require((reply["status"] as? [String: Any])?["result"] as? [String: Any])
      #expect(status["selectedBackend"] as? String == "parakeet")
      #expect((status["engine"] as? [String: Any])?["selected"] as? String == "whisper")
      #expect((status["activeDriver"] as? [String: Any])?["state"] as? String == "transcribing")

      let listed = try #require((reply["listed"] as? [String: Any])?["result"] as? [String: Any])
      let ids = (listed["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
      #expect(ids == [huge.id.uuidString, small.id.uuidString])
      #expect((listed["rows"] as? [[String: Any]])?.first?["textBytes"] as? Int == 2 << 20)

      let got = try #require((reply["got"] as? [String: Any])?["result"] as? [String: Any])
      #expect((got["row"] as? [String: Any])?["polishedText"] as? String == "Small row.")

      let big = try #require(reply["big"] as? [String: Any])
      #expect(big["ok"] as? Bool == false)
      #expect((big["error"] as? [String: Any])?["code"] as? String == "responseTooLarge")
      #expect(big["launch"] as? String == door.launchID.uuidString)
      #expect(big["pid"] as? Int == Int(door.pid))
      #expect(big["result"] == nil)
      let bad = try #require(reply["bad"] as? [String: Any])
      #expect((bad["error"] as? [String: Any])?["code"] as? String == "badArgs")

      try #require(outcomes.count == 5, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=status ok=true forced=false code=none"))
      #expect(outcomes[2].contains("cmd=history.get ok=true forced=false code=none"))
      #expect(outcomes[3].contains("cmd=history.get ok=false forced=false code=responseTooLarge"))
      for line in outcomes {
        #expect(line.contains(small.id.uuidString) == false)
        #expect(line.contains(huge.id.uuidString) == false)
        #expect(line.contains("small row") == false)
      }
      try await stop(door)
    }

    @Test("each model command over the socket presses only its own button and reads that engine after")
    func modelCommandsOverTheSocket() async throws {
      let status = DevControlFixtures.StatusFake()
      let models = DevControlFixtures.ModelFake()
      models.onPress = { action in
        switch action {
        case "parakeetDownload":
          status.parakeet = .downloading(fractionCompleted: 0, bytesWritten: 0, totalBytes: 10)
        case "whisperKitDownload":
          status.whisperKit = .downloading(progress: 0, status: "Starting download...")
        default: break
        }
      }
      let door = DevControlDoor(dispatcher: Self.dispatcher(status: status, models: models))
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        out = {}
        for cmd in ["models.parakeet.download", "models.parakeet.cancel",
                    "models.whisperkit.download", "models.whisperkit.cancel"]:
            out[cmd] = c.request(cmd)
        out["extra"] = c.request("models.parakeet.download", {"model": "x"})
        print(json.dumps(out))
        """#)
      #expect(models.pressed == [
        "parakeetDownload", "parakeetCancel", "whisperKitDownload", "whisperKitCancel",
      ])
      func result(_ cmd: String) throws -> [String: Any] {
        try #require((reply[cmd] as? [String: Any])?["result"] as? [String: Any])
      }
      let parakeet = try result("models.parakeet.download")
      #expect(parakeet["backend"] as? String == "parakeet")
      #expect(parakeet["action"] as? String == "download")
      #expect((parakeet["state"] as? [String: Any])?["state"] as? String == "downloading")
      let whisper = try result("models.whisperkit.cancel")
      #expect(whisper["backend"] as? String == "whisperKit")
      #expect(whisper["action"] as? String == "cancel")
      #expect((whisper["state"] as? [String: Any])?["state"] as? String == "downloading")
      let extra = try #require(reply["extra"] as? [String: Any])
      #expect((extra["error"] as? [String: Any])?["code"] as? String == "badArgs")

      try #require(outcomes.count == 5, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=models.parakeet.download ok=true"))
      #expect(outcomes[3].contains("cmd=models.whisperkit.cancel ok=true"))
      #expect(outcomes[4].contains("cmd=models.parakeet.download ok=false forced=false code=badArgs"))
      try await stop(door)
    }

    @Test("words CRUD over the socket logs no word content; a list too large to send is refused whole")
    func wordsOverTheSocket() async throws {
      let temp = DevControlFixtures.TempWords()
      defer { temp.cleanUp() }
      let door = DevControlDoor(dispatcher: Self.dispatcher(words: temp.coordinator))
      var outcomes: [String] = []
      door.onOutcomeLogged = { outcomes.append($0) }
      defer { door.uninstall() }
      try #require(await door.install() == .ready)

      let reply = try await runClient(
        #"""
        c = dev_control.Connection(\#(door.pid))
        added = c.request("words.add", {"word": "Fooflux", "aliases": ["foo flux"]})
        wid = added["result"]["word"]["id"]
        listed = c.request("words.list")
        updated = c.request("words.update", {"id": wid, "aliases": ["fu flux"]})
        removed = c.request("words.remove", {"id": wid})
        missing = c.request("words.remove", {"id": wid})
        print(json.dumps({"added": added, "listed": listed, "updated": updated,
                          "removed": removed, "missing": missing}))
        """#)
      let added = try #require((reply["added"] as? [String: Any])?["result"] as? [String: Any])
      #expect(added["outcome"] as? String == "created")
      let id = try #require((added["word"] as? [String: Any])?["id"] as? String)
      let listed = try #require((reply["listed"] as? [String: Any])?["result"] as? [String: Any])
      #expect((listed["words"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
      let updated = try #require((reply["updated"] as? [String: Any])?["result"] as? [String: Any])
      #expect((updated["word"] as? [String: Any])?["aliases"] as? [String] == ["fu flux"])
      #expect((reply["removed"] as? [String: Any])?["ok"] as? Bool == true)
      #expect(
        ((reply["missing"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
          == "notFound")
      #expect(temp.coordinator.customWords.contains { $0.id.uuidString == id } == false)

      // In memory only: enough long rows that the list passes the reply limit.
      let alias = String(repeating: "x", count: 200)
      temp.coordinator.customWords = (0..<6_000).map {
        CustomWord(canonical: "Word\($0)", aliases: [alias])
      }
      let big = try await runClient(
        #"""
        print(json.dumps(dev_control.request(\#(door.pid), "words.list")))
        """#)
      #expect(big["ok"] as? Bool == false)
      #expect((big["error"] as? [String: Any])?["code"] as? String == "responseTooLarge")
      #expect(big["launch"] as? String == door.launchID.uuidString)
      #expect(big["result"] == nil)

      try #require(outcomes.count == 6, "outcomes: \(outcomes)")
      #expect(outcomes[0].contains("cmd=words.add ok=true forced=false code=none"))
      #expect(outcomes[4].contains("cmd=words.remove ok=false forced=false code=notFound"))
      #expect(outcomes[5].contains("cmd=words.list ok=false forced=false code=responseTooLarge"))
      for line in outcomes {
        #expect(line.lowercased().contains("flux") == false)
        #expect(line.contains(id) == false)
      }
      try await stop(door)
    }

    @Test("uninstall while a request is suspended sends nothing and dispatches no buffered request")
    func uninstallDuringSuspendedDispatch() async throws {
      let gate = Gate()
      defer { gate.open() }
      let door = gatedDoor(gate)
      defer { door.uninstall() }
      var processingFinished = false
      door.onProcessingFinished = { processingFinished = true }
      try #require(await door.install() == .ready)

      async let child = Self.runPython(
        Self.clientScript(
          Self.requireClosed
            + #"""
            c = dev_control.Connection(\#(door.pid), timeout=5)
            c.send_raw(b'{"id":"1","cmd":"ping"}\n{"id":"2","cmd":"ping"}\n')
            require_closed(c)
            print(json.dumps({"closed": True}))
            """#))
      try #require(await settleUntilObserved { gate.entered == 1 }, "handler never entered")
      door.uninstall()
      gate.open()
      let reply = try parse(try await child)
      #expect(reply["closed"] as? Bool == true)
      try #require(await settleUntilObserved { processingFinished }, "processing did not finish")
      #expect(gate.entered == 1)
      try await stop(door)
      var gone = stat()
      let status = lstat(door.socketPath, &gone)
      #expect(status == -1)
    }

    @Test("a peer that leaves before its reply stops the buffered requests behind it")
    func peerGoneStopsBufferedRequests() async throws {
      let gate = Gate()
      defer { gate.open() }
      let door = gatedDoor(gate)
      defer { door.uninstall() }
      try #require(await door.install() == .ready)
      // The child closes only after the door is inside the first request, signalled by
      // this file, so the close lands while a buffered second request is waiting.
      let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("ewdc-peer-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: marker) }

      async let child = Self.runPython(
        Self.clientScript(
          #"""
          import os, time
          c = dev_control.Connection(\#(door.pid))
          c.send_raw(b'{"id":"1","cmd":"ping"}\n{"id":"2","cmd":"ping"}\n')
          for _ in range(1000):  # bounded wait for the test's signal; a settle tick, not the mechanism
              if os.path.exists(\#(String(reflecting: marker.path))):
                  break
              time.sleep(0.01)
          else:
              raise SystemExit("never signalled")
          c.close()
          print(json.dumps({}))
          """#))
      try #require(await settleUntilObserved { gate.entered == 1 }, "handler never entered")
      try #require(FileManager.default.createFile(atPath: marker.path, contents: Data()))
      _ = try parse(try await child)
      gate.open()
      try #require(await settleUntilObserved { door.openSessionCount == 0 }, "session stayed open")
      #expect(gate.entered == 1)
      try await stop(door)
    }

    @Test("uninstall while starting resolves install as failed; the path stays reserved until the listener stops")
    func uninstallWhileStarting() async throws {
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      defer { door.uninstall() }
      var stateAtStart: DevControlDoor.State?
      door.onListenerStarted = { [weak door] in
        stateAtStart = door?.state
        door?.uninstall()
      }
      #expect(await door.install() == .failed("uninstalled"))
      #expect(stateAtStart == .starting)
      door.uninstall()
      #expect(door.state == .closed)
      #expect(await door.install() == .refused("alreadyInstalled"))
      // The listener can bind after an uninstall that ran while it was starting; the
      // pathname must be gone once the listener has really stopped.
      try #require(
        await settleUntilObserved { door.listenerHasStopped }, "listener never reported stopped")
      var gone = stat()
      let status = lstat(door.socketPath, &gone)
      let goneErrno = errno  // read before any other call can overwrite it
      #expect(status == -1)
      #expect(goneErrno == ENOENT)
    }

    @Test("quit before the launch install runs: the install refuses and nothing listens")
    func quitBeforeInstallLeavesNoListener() async throws {
      // The bootstrapper's order at quit: cancel the install task, then uninstall. A task
      // that had not reached `install()` yet must not open the door afterwards.
      let door = DevControlDoor(dispatcher: Self.dispatcher())
      let install = Task { await door.install() }
      install.cancel()
      door.uninstall()
      #expect(await install.value == .refused("alreadyInstalled"))
      #expect(door.state == .closed)
      #expect(door.listenerHasStopped)
      #expect(FileManager.default.fileExists(atPath: door.socketPath) == false)

      let replacement = DevControlDoor(dispatcher: Self.dispatcher())
      defer { replacement.uninstall() }
      #expect(await replacement.install() == .ready)
      try await stop(replacement)
    }

    @Test("an idle door's uninstall leaves an installed door alone; a replacement waits for the stop")
    func pathReservationAcrossDoors() async throws {
      let first = DevControlDoor(dispatcher: Self.dispatcher())
      defer { first.uninstall() }
      try #require(await first.install() == .ready)

      let idle = DevControlDoor(dispatcher: Self.dispatcher())
      idle.uninstall()
      #expect(DevControlDoor.socketModeIsPrivate(first.socketPath))
      let reached = try await runClient("print(json.dumps(dev_control.ping(\(first.pid))))")
      #expect(reached["ok"] as? Bool == true)

      let early = DevControlDoor(dispatcher: Self.dispatcher())
      #expect(await early.install() == .refused("pathInUse"))

      first.uninstall()
      let beforeStop = DevControlDoor(dispatcher: Self.dispatcher())
      // No suspension between the uninstall above and this check, so the listener's
      // cancellation cannot have been processed yet.
      #expect(await beforeStop.install() == .refused("pathInUse"))
      try #require(
        await settleUntilObserved { first.listenerHasStopped }, "listener never reported stopped")

      let replacement = DevControlDoor(dispatcher: Self.dispatcher())
      defer { replacement.uninstall() }
      #expect(await replacement.install() == .ready)
      try await stop(replacement)
    }

    @Test("the Python reader refuses bad reply frames and keeps the bytes after a boundary")
    func clientRefusesBadReplies() async throws {
      let reply = try await runClient(
        #"""
        class Feed:
            def __init__(self, chunks):
                self.chunks = iter(chunks)
            def recv(self, maximum):
                value = next(self.chunks, b"")
                if isinstance(value, BaseException):
                    raise value
                return value

        def refuses(operation):
            try:
                operation()
            except dev_control.DoorError:
                return 1
            raise AssertionError("expected DoorError")

        count = 0
        for frame in (b"\xff", b"{", b"[]", b'{"door":2}'):
            count += refuses(lambda frame=frame: dev_control.decode_reply(frame))
        limit = dev_control.MAX_FRAME_BYTES
        count += refuses(lambda: dev_control._read_frame(Feed([b"x" * limit, b"x\n"]), b""))
        count += refuses(lambda: dev_control._read_frame(Feed([TimeoutError("test timeout")]), b""))
        count += refuses(lambda: dev_control._read_frame(Feed([]), b"partial"))
        frame, rest = dev_control._read_frame(Feed([b"x" * limit, b"\nnext\n"]), b"")
        print(json.dumps({"rejections": count, "boundary_and_remainder": len(frame) == limit and rest == b"next\n"}))
        """#)
      #expect(reply["rejections"] as? Int == 7)
      #expect(reply["boundary_and_remainder"] as? Bool == true)
    }
  }
#endif
