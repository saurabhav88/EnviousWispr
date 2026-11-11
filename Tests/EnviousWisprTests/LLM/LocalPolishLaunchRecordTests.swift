import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprLlamaEngine
@testable import EnviousWisprLocalPolish

/// #4493: every launch of a polish helper owns one private folder (socket, key file, the "app
/// is alive" pipe and a watch on the folder), and every way a launch ends gives all of it back.
/// A removed socket file under a ready helper restarts it once.
///
/// Customer harm when it is wrong: a launch folder or pipe that is never released keeps a helper
/// alive after the app stopped using it, or fills the cache folder; a socket file that a cleaner
/// removed leaves local polish silently off while the helper still looks ready; an old launch's
/// late event stops the launch that replaced it. Rig: the lifecycle fixture's fake helper (a
/// real child process on the private socket) and the process manager.
@Suite("Local polish launch record (#4493)", .serialized, .tags(.productOutcome))
struct LocalPolishLaunchRecordTests {
  typealias Fixture = EGOneAdapterLifecycleTests.Fixture
  typealias State = LocalPolishProcessManager.Lifecycle
  typealias Recorder = EGOneOutsideStopRecoveryTests.StateRecorder

  static func isReady(_ state: State) -> Bool {
    if case .ready = state.state { return true }
    return false
  }

  static func isSettled(_ state: State) -> Bool {
    switch state.state {
    case .ready, .stoppedOutside, .failed, .stopped, .pausedForMemoryPressure: true
    case .starting: false
    }
  }

  /// Starts a manager on `fixture` and waits until it is ready.
  static func ready(
    _ fixture: Fixture, configuration: LocalPolishProcessManager.Configuration? = nil
  ) async throws -> (LocalPolishProcessManager, Recorder, LocalPolishEndpoint) {
    let manager = LocalPolishProcessManager()
    let recorder = Recorder()
    await manager.setStateObserver { recorder.record($0.lifecycle) }
    await manager.start(configuration: configuration ?? fixture.configuration())
    let endpoint = try #require(
      await manager.activeEndpoint(), "the fake helper never became ready")
    return (manager, recorder, endpoint)
  }

  /// A configuration whose folder watch registers on an inactive queue, and the launch
  /// connection's own signal that the watch's descriptor and source exist (registration is then
  /// pending until the queue is activated).
  static func parked(_ fixture: Fixture) -> (
    configuration: LocalPolishProcessManager.Configuration, queue: DispatchQueue,
    watchPending: BoundedWait.Signal
  ) {
    let queue = DispatchQueue(label: "launch-record.parked", attributes: .initiallyInactive)
    let watchPending = BoundedWait.Signal()
    var configuration = fixture.configuration().inLaunchHome(
      fixture.launchHome(observer: { event in
        if event == .watchDescriptorOpened { watchPending.fire() }
      }))
    configuration.watchQueue = queue
    return (configuration, queue, watchPending)
  }

  // MARK: - Resources of one launch

  @Test("a ready launch has its socket in its own folder, no key file, and stop removes all of it")
  func readyThenStopReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, _, endpoint) = try await Self.ready(fixture)
    let folders = fixture.launchFolders()
    try #require(folders.count == 1)
    let leaf = fixture.launchParent + "/" + folders[0]
    #expect(endpoint.socketPath == leaf + "/s.sock")
    #expect(endpoint.socketPath.utf8.count <= 103, "\(endpoint.socketPath.utf8.count) bytes")
    #expect(FileManager.default.fileExists(atPath: endpoint.socketPath))
    #expect(!FileManager.default.fileExists(atPath: leaf + "/k"), "the key file outlived ready")
    var info = stat()
    try #require(lstat(leaf, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o700)
    // The launch arguments name the socket and the key file, never the secret.
    let arguments = try #require(try fixture.launches().last)
    #expect(arguments.contains(endpoint.socketPath))
    #expect(!arguments.contains { $0.contains(endpoint.authToken) })

    await manager.stop()
    #expect(fixture.launchFolders().isEmpty, "stop left \(fixture.launchFolders())")
  }

  @Test("a memory-pressure pause releases the launch folder")
  func pauseReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, _, _) = try await Self.ready(fixture)
    await manager.pauseForMemoryPressure()
    #expect(await manager.state == .pausedForMemoryPressure)
    #expect(fixture.launchFolders().isEmpty)
  }

  @Test("a helper that never becomes ready leaves no launch folder")
  func neverReadyReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("hold_ready"))
    let manager = LocalPolishProcessManager()
    await manager.start(configuration: fixture.configuration(readinessBudgetSeconds: 1))
    #expect(await manager.state == .failed(reason: "server_never_became_ready"))
    #expect(fixture.launchFolders().isEmpty)
    try Data().write(to: fixture.root.appendingPathComponent("release_ready"))
  }

  @Test("a helper that exits while starting leaves no launch folder")
  func startupDeathReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("exit_on_start"))
    let manager = LocalPolishProcessManager()
    let recorder = Recorder()
    await manager.setStateObserver { recorder.record($0.lifecycle) }
    await manager.start(configuration: fixture.configuration(readinessBudgetSeconds: 2))
    let settled = await recorder.first(from: 0) { Self.isSettled($0) && $0.state != .stopped }
    #expect(
      settled?.state == .failed(reason: "crashed_during_start")
        || settled?.state == .failed(reason: "server_never_became_ready"),
      "\(String(describing: settled))")
    #expect(fixture.launchFolders().isEmpty)
  }

  @Test("an adapter launch that never becomes ready falls back with the first folder released")
  func adapterFallbackReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try Data().write(
      to: fixture.adapter.deletingLastPathComponent().appendingPathComponent("hang_adapter"))
    let (manager, _, endpoint) = try await Self.ready(
      fixture,
      configuration: fixture.configuration(adapterURL: fixture.adapter, readinessBudgetSeconds: 1))
    #expect(!endpoint.hasLearnedWordAdapter)
    #expect(fixture.launchFolders().count == 1, "\(fixture.launchFolders())")
    await manager.stop()
    #expect(fixture.launchFolders().isEmpty)
  }

  @Test("a binary that cannot be started fails as a spawn failure with no launch folder")
  func runThrowsReleases() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let notExecutable = fixture.root.appendingPathComponent("not-executable")
    try Data("x".utf8).write(to: notExecutable)
    var configuration = fixture.configuration()
    configuration.spec = .fixture(
      serverBinaryURL: notExecutable, modelURL: fixture.model, contextTokens: 4096)
    let manager = LocalPolishProcessManager()
    await manager.start(configuration: configuration)
    #expect(await manager.state == .failed(reason: "spawn_failed"))
    #expect(fixture.launchFolders().isEmpty)
  }

  @Test("a launch folder whose socket path is too long is refused before anything exists")
  func socketPathTooLong() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let long = fixture.launchParent + "/" + String(repeating: "p", count: 60)
    let configuration = fixture.configuration().inLaunchHome(
      LocalPolishLaunchHome(
        parent: long, identity: .init(pid: 7, startSeconds: 1, startMicroseconds: 1)))
    let manager = LocalPolishProcessManager()
    await manager.start(configuration: configuration)
    #expect(await manager.state == .failed(reason: "socket_path_unusable"))
    #expect(!FileManager.default.fileExists(atPath: long))
    #expect(try fixture.launches().isEmpty, "a helper was started")
  }

  @Test(
    "an outside stop and a crash restart each release the old folder; the restart gets a new one")
  func outsideStopAndRestartRelease() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, recorder, first) = try await Self.ready(fixture)

    var mark = recorder.count
    EGOneOutsideStopRecoveryTests.Ending.nonzeroExit.apply(to: try fixture.lastPID())
    let restarted = await recorder.first(from: mark) {
      Self.isReady($0) || $0.state == .failed(reason: "crashed_twice")
    }
    guard case .ready(let second) = restarted?.state else {
      Issue.record("no restart: \(String(describing: restarted))")
      return
    }
    #expect(second.socketPath != first.socketPath)
    #expect(!FileManager.default.fileExists(atPath: first.socketPath))
    #expect(fixture.launchFolders().count == 1)

    mark = recorder.count
    kill(try fixture.lastPID(), SIGTERM)
    let stopped = await recorder.first(from: mark) { $0.state == .stoppedOutside }
    #expect(stopped != nil)
    #expect(fixture.launchFolders().isEmpty)
    await manager.stop()
  }

  @Test("an app quit leaves the folder to the next run, which keeps it while this process lives")
  func quitLeavesALeftover() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, _, endpoint) = try await Self.ready(fixture)
    manager.terminateImmediately()
    #expect(
      FileManager.default.fileExists(
        atPath: (endpoint.socketPath as NSString).deletingLastPathComponent))
    // The next manager's first spawn sweeps; the folder names a live owner, so it stays.
    let next = LocalPolishProcessManager()
    await next.start(configuration: fixture.configuration())
    #expect(fixture.launchFolders().count == 2)
    await next.stop()
    #expect(fixture.launchFolders().count == 1)
  }

  // MARK: - §3.7 a socket file removed while the helper is ready

  @Test("a removed socket file restarts the helper once on a new socket; a second removal stops it")
  func removedSocketRestartsOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, recorder, first) = try await Self.ready(fixture)

    var mark = recorder.count
    try #require(unlink(first.socketPath) == 0)
    let restarted = await recorder.first(from: mark) {
      Self.isSettled($0)
    }
    guard case .ready(let second) = restarted?.state else {
      Issue.record("no restart: \(String(describing: restarted))")
      return
    }
    #expect(second.socketPath != first.socketPath)
    #expect(try fixture.launches().count == 2)
    #expect(fixture.launchFolders().count == 1)

    mark = recorder.count
    try #require(unlink(second.socketPath) == 0)
    let gaveUp = await recorder.first(from: mark) {
      $0.state == .failed(reason: "socket_removed_twice")
    }
    #expect(gaveUp != nil)
    #expect(fixture.launchFolders().isEmpty)
    #expect(try fixture.launches().count == 2)
    await manager.stop()
  }

  @Test("another entry changing in the launch folder changes nothing")
  func otherEntryIsIgnored() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, recorder, endpoint) = try await Self.ready(fixture)
    let leaf = (endpoint.socketPath as NSString).deletingLastPathComponent
    let mark = recorder.count
    try Data("x".utf8).write(to: URL(fileURLWithPath: leaf + "/other"))
    // The event was delivered and judged: the manager's own check runs on the actor, so a
    // later actor turn sees its outcome.
    await manager.launchFolderChanged(generation: 1)
    #expect(recorder.count == mark)
    #expect(await manager.activeEndpoint() == endpoint)
    try FileManager.default.removeItem(atPath: leaf + "/other")
    await manager.stop()
  }

  @Test(
    "a late folder event for a launch that is no longer the ready one does nothing",
    arguments: ["stopped", "paused", "failed", "stoppedOutside", "superseded"])
  func lateEventsDoNothing(ending: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (manager, recorder, _) = try await Self.ready(fixture)
    switch ending {
    case "stopped": await manager.stop()
    case "paused": await manager.pauseForMemoryPressure()
    case "failed":
      let mark = recorder.count
      try Data().write(to: fixture.root.appendingPathComponent("exit_on_start"))
      EGOneOutsideStopRecoveryTests.Ending.nonzeroExit.apply(to: try fixture.lastPID())
      _ = await recorder.first(from: mark) { if case .failed = $0.state { true } else { false } }
    case "stoppedOutside":
      let mark = recorder.count
      kill(try fixture.lastPID(), SIGTERM)
      _ = await recorder.first(from: mark) { $0.state == .stoppedOutside }
    default:
      await manager.stop()
      await manager.start(configuration: fixture.configuration())
      try #require(await manager.activeEndpoint() != nil)
    }
    let before = await manager.currentLifecycle()
    let launches = try fixture.launches().count
    let mark = recorder.count
    await manager.launchFolderChanged(generation: 1)
    #expect(await manager.currentLifecycle() == before)
    #expect(recorder.count == mark)
    #expect(try fixture.launches().count == launches)
    await manager.stop()
  }

  // MARK: - The watch, around its registration

  @Test("a launch folder gone before the watch opens it fails the launch and releases it")
  func watchOpenFails() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("vanish_on_health"))
    let manager = LocalPolishProcessManager()
    await manager.start(configuration: fixture.configuration())
    #expect(await manager.state == .failed(reason: "spawn_failed"))
    #expect(fixture.launchFolders().isEmpty)
    #expect(await manager.activeEndpoint() == nil)
  }

  @Test("a socket removed after health and before the watch registers is found right after ready")
  func removedBeforeRegistration() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (configuration, parked, watchPending) = Self.parked(fixture)
    defer { parked.activate() }
    let manager = LocalPolishProcessManager()
    let recorder = Recorder()
    await manager.setStateObserver { recorder.record($0.lifecycle) }
    let starting = Task { await manager.start(configuration: configuration) }
    try await BoundedWait.until(watchPending)
    let leaf = try #require(fixture.launchFolders().first)
    let socket = fixture.launchParent + "/" + leaf + "/s.sock"
    // The fake helper binds its socket before it answers health.
    try #require(FileManager.default.fileExists(atPath: socket))
    try #require(unlink(socket) == 0)
    parked.activate()
    await starting.value
    // The first launch was promoted, found without its socket, and restarted once.
    let ready = await recorder.first(from: 0) { state in
      guard case .ready(let endpoint) = state.state else { return false }
      return endpoint.socketPath != socket
    }
    #expect(ready != nil, "\(recorder.states)")
    #expect(try fixture.launches().count == 2)
    await manager.stop()
  }

  @Test("a launch replaced while its watch registration is pending leaves the successor alone")
  func replacedWhileRegistrationIsPending() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (parkedConfiguration, parked, watchPending) = Self.parked(fixture)
    defer { parked.activate() }
    let manager = LocalPolishProcessManager()
    let starting = Task { await manager.start(configuration: parkedConfiguration) }
    try await BoundedWait.until(watchPending)
    let firstLeaf = try #require(fixture.launchFolders().first)
    await manager.stop()
    await starting.value
    await manager.start(configuration: fixture.configuration())
    let successor = try #require(await manager.activeEndpoint())
    parked.activate()
    #expect(await manager.activeEndpoint() == successor)
    #expect(!fixture.launchFolders().contains(firstLeaf))
    #expect(fixture.launchFolders().count == 1)
    await manager.stop()
  }

  @Test("a helper that dies while its watch registration is pending takes its own startup exit")
  func diesWhileRegistrationIsPending() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let (configuration, parked, watchPending) = Self.parked(fixture)
    defer { parked.activate() }
    let manager = LocalPolishProcessManager()
    let recorder = Recorder()
    await manager.setStateObserver { recorder.record($0.lifecycle) }
    let starting = Task { await manager.start(configuration: configuration) }
    try await BoundedWait.until(watchPending)
    EGOneOutsideStopRecoveryTests.Ending.nonzeroExit.apply(to: try fixture.lastPID())
    let failed = await recorder.first(from: 0) {
      if case .failed = $0.state { true } else { false }
    }
    #expect(
      failed?.state == .failed(reason: "crashed_during_start"), "\(String(describing: failed))")
    parked.activate()
    await starting.value
    #expect(await manager.activeEndpoint() == nil)
    #expect(recorder.states.contains { Self.isReady($0) } == false)
    #expect(fixture.launchFolders().isEmpty)
  }

  @Test("a termination accepted before the socket recovery runs keeps its own handling")
  func terminationAcceptedFirstWins() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    // The failure observer runs after the termination was accepted and before the manager's
    // own callback; holding it there opens exactly that window. A launch takes the observer
    // when it starts, so it is set first and armed once the helper is ready.
    let accepted = BoundedWait.Signal()
    let gate = DispatchSemaphore(value: 0)
    let armed = OSAllocatedUnfairLock(initialState: false)
    defer { gate.signal() }
    let manager = LocalPolishProcessManager()
    let recorder = Recorder()
    await manager.setStateObserver { recorder.record($0.lifecycle) }
    await manager.setProcessFailureObserver { _ in
      guard armed.withLock({ $0 }) else { return }
      accepted.fire()
      gate.wait()
    }
    await manager.start(configuration: fixture.configuration())
    let endpoint = try #require(await manager.activeEndpoint(), "the fake helper never became ready")
    armed.withLock { $0 = true }
    let mark = recorder.count
    kill(try fixture.lastPID(), SIGTERM)
    try await BoundedWait.until(accepted)
    try #require(unlink(endpoint.socketPath) == 0)
    await manager.launchFolderChanged(generation: 1)
    // The recovery found the accepted termination and did nothing.
    #expect(await manager.activeEndpoint() == endpoint)
    #expect(try fixture.launches().count == 1)
    gate.signal()
    let stopped = await recorder.first(from: mark) { $0.state == .stoppedOutside }
    #expect(stopped != nil, "\(recorder.states)")
    #expect(try fixture.launches().count == 1, "the recovery started a helper")
    #expect(fixture.launchFolders().isEmpty)
  }
}
