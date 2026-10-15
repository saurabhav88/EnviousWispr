#if DEBUG
  import Darwin
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

    /// Runs `body` in a Python child that has imported `Tests/RuntimeUAT/dev_control.py`.
    /// The client's socket timeout bounds each socket operation; the child must exit 0 with
    /// empty stderr and print one JSON object as its last stdout line.
    private func runClient(_ body: String) async throws -> [String: Any] {
      let runtimeUAT = Self.repoRoot.appendingPathComponent("Tests/RuntimeUAT").path
      let script = """
        import json, sys
        sys.path.insert(0, \(String(reflecting: runtimeUAT)))
        import dev_control
        \(body)
        """
      let captured = try await Self.runPython(script)
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

    @Test("a real Python client pings the real door and reads its identity")
    func realPythonClientPingsTheRealDoor() async throws {
      let door = DevControlDoor(dispatcher: DevControlDispatcher())
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

      door.uninstall()
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
      let door = DevControlDoor(dispatcher: DevControlDispatcher())
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
  }
#endif
