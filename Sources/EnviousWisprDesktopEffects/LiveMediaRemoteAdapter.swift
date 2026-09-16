import Foundation

/// #1413 v1.1 — the "pause whatever is playing" route. FRAGILE BY DESIGN.
///
/// macOS 15.4+ refuses third-party apps the private `MediaRemote.framework`,
/// the only system-wide "what is playing, pause it" surface. The community
/// `mediaremote-adapter` (Jonas van den Berg, BSD 3-Clause; the framework in
/// `Contents/Frameworks`, its perl script, licence and provenance in
/// `Contents/Resources`) is a tiny framework that `/usr/bin/perl`, which still
/// carries the entitlement, loads for us. We never link it. Superwhisper,
/// Spokenly and VoiceInk ship the same adapter.
///
/// Any macOS update can turn this off. Every failure here is `unavailable`, and
/// `LiveMediaPlaybackEffects` then falls back to the scripted Music/Spotify
/// route; nothing else in the app depends on the adapter. The one thing this
/// file must never enable is STARTING playback the user did not have playing:
/// `play` is only ever sent after a fresh `.paused` read of the SAME source.
///
/// Upstream facts this parser rests on (v0.7.7, `src/adapter/get.m`, `keys.m`):
/// `get` prints the literal `null` with exit 0 when nothing is registered AND
/// when its internal 2 s wait expires, in which case it also writes
/// `Reading now playing information timed out` to stderr. So "nothing playing"
/// and "the adapter is broken" are told apart by stderr and exit status, never
/// by stdout alone.
package struct MediaRemoteAdapter: Sendable {
  package static let perl = "/usr/bin/perl"
  package static let scriptName = "mediaremote-adapter.pl"
  package static let frameworkName = "MediaRemoteAdapter.framework"
  /// The adapter's own wait is 2 s; this bounds the whole process.
  package static let budget: TimeInterval = 3.0
  /// `send` command ids (`src/adapter/send.m`): `kMRPlay` = 0, `kMRPause` = 1.
  package static let playCommand = "0"
  package static let pauseCommand = "1"

  /// Raw result of one adapter process; nil status means it was killed at the budget.
  package struct RunResult: Equatable, Sendable {
    package var status: Int32?
    package var stdout: String
    package var stderr: String
    package init(status: Int32?, stdout: String, stderr: String) {
      self.status = status
      self.stdout = stdout
      self.stderr = stderr
    }
  }

  /// Bounded reason classes, the values `other_audio_adapter_failure` can take.
  package enum Failure: String, Equatable, Sendable {
    case load, timeout, exit, parse, send
  }

  /// What the now-playing source looked like at one read. `identity` is the
  /// track/item the source reported (`contentItemIdentifier`, else `title`), so a
  /// resume can tell OUR paused item from a different one the user paused in the
  /// same app (another browser tab; council 2026-09-15).
  package struct Source: Equatable, Sendable {
    package var bundleID: String
    package var identity: String?
    package init(bundleID: String, identity: String?) {
      self.bundleID = bundleID
      self.identity = identity
    }
  }

  package enum NowPlayingRead: Equatable, Sendable {
    case playing(Source)
    case paused(Source)
    case nothing
    case unavailable(Failure)
  }

  /// The string a hold record keeps for an adapter-paused source, so an orphan
  /// resume after a crash has the same gate as a live one. Bundle ids never
  /// contain `|`; an identity may, so only the FIRST `|` splits.
  package static let targetPrefix = "adapter:"

  package static func target(for source: Source) -> String {
    targetPrefix + source.bundleID + (source.identity.map { "|" + $0 } ?? "")
  }

  package static func source(fromTarget target: String) -> Source? {
    guard target.hasPrefix(targetPrefix) else { return nil }
    let body = target.dropFirst(targetPrefix.count)
    guard let bar = body.firstIndex(of: "|") else {
      return body.isEmpty ? nil : Source(bundleID: String(body), identity: nil)
    }
    let bundle = String(body[..<bar])
    guard !bundle.isEmpty else { return nil }
    return Source(bundleID: bundle, identity: String(body[body.index(after: bar)...]))
  }

  package let scriptURL: URL
  package let frameworkURL: URL

  package init(scriptURL: URL, frameworkURL: URL) {
    self.scriptURL = scriptURL
    self.frameworkURL = frameworkURL
  }

  /// Where the build puts the two halves. Always resolved: a missing file is
  /// `unavailable(.load)` at run time (a broken install, which the terminal row
  /// then names), never a silent "not bundled". `build-dev-app.sh` and
  /// `build-release-dmg.sh` fail closed when either is absent.
  package static let bundled = MediaRemoteAdapter(
    scriptURL: (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
      .appendingPathComponent(scriptName),
    frameworkURL: (Bundle.main.privateFrameworksURL ?? URL(fileURLWithPath: "/nonexistent"))
      .appendingPathComponent(frameworkName))

  package var getArguments: [String] {
    // `--no-artwork`: a cover image is hundreds of KB of base64 per read.
    // `--allow-missing-title`: untitled audio (a voice note) is still paused.
    [scriptURL.path, frameworkURL.path, "get", "--no-artwork", "--allow-missing-title"]
  }

  package func sendArguments(_ command: String) -> [String] {
    [scriptURL.path, frameworkURL.path, "send", command]
  }

  // MARK: - Parsing (pure; tested by rows)

  package static func parseGet(_ result: RunResult) -> NowPlayingRead {
    guard let status = result.status else { return .unavailable(.timeout) }
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard status == 0 else {
      return .unavailable(stderr.contains("Failed to load framework") ? .load : .exit)
    }
    if !stderr.isEmpty {
      return .unavailable(stderr.contains("timed out") ? .timeout : .exit)
    }
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if stdout == "null" { return .nothing }
    guard let data = stdout.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dict = object as? [String: Any],
      let playing = dict["playing"] as? Bool
    else { return .unavailable(.parse) }
    // A source with no bundle id cannot be re-identified at resume, so it is
    // never paused: the resume gate could not tell it from a different app.
    guard let bundleID = dict["bundleIdentifier"] as? String, !bundleID.isEmpty else {
      return .nothing
    }
    let identity = (dict["contentItemIdentifier"] as? String) ?? (dict["title"] as? String)
    let source = Source(bundleID: bundleID, identity: identity.flatMap { $0.isEmpty ? nil : $0 })
    return playing ? .playing(source) : .paused(source)
  }

  package static func sendSucceeded(_ result: RunResult) -> Bool {
    result.status == 0 && result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Live process (off the main actor; the caller's serial queue)

  /// Runs one adapter command and waits at most `budget`; a process still alive
  /// at the budget is killed and reported as `status: nil`.
  package static func liveRun(_ arguments: [String]) -> RunResult {
    // The script and framework paths are the first two arguments; a missing
    // half is the `load` class, reported before perl is even spawned.
    for path in arguments.prefix(2) where !FileManager.default.fileExists(atPath: path) {
      return RunResult(status: 1, stdout: "", stderr: "Failed to load framework: missing \(path)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: perl)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    // The bound is on the PROCESS, not on the pipes: a child that closes both
    // streams and then hangs would otherwise never be killed (Codex chunk r1).
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return RunResult(status: 127, stdout: "", stderr: "Failed to load framework: \(error)")
    }
    // Drain both pipes on background reads so a large payload cannot deadlock
    // the child against a full pipe while we wait on it.
    final class Captured: @unchecked Sendable {
      let lock = NSLock()
      var stdout = Data()
      var stderr = Data()
    }
    let captured = Captured()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      let data = out.fileHandleForReading.readDataToEndOfFile()
      captured.lock.withLock { captured.stdout = data }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      let data = err.fileHandleForReading.readDataToEndOfFile()
      captured.lock.withLock { captured.stderr = data }
      group.leave()
    }
    let deadline = DispatchTime.now() + budget
    var killed = false
    if exited.wait(timeout: deadline) == .timedOut {
      killed = true
      if process.isRunning { process.terminate() }
      // A child that ignores SIGTERM is reaped with SIGKILL after a short grace,
      // so this call is bounded whatever perl does.
      if exited.wait(timeout: .now() + 1.0) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    group.wait()
    let (o, e) = captured.lock.withLock { (captured.stdout, captured.stderr) }
    return RunResult(
      status: killed ? nil : process.terminationStatus,
      stdout: String(decoding: o, as: UTF8.self),
      stderr: String(decoding: e, as: UTF8.self))
  }
}
