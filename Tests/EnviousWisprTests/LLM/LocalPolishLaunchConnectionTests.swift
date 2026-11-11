import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprLocalPolish

/// The private folder, key file, "app is alive" pipe and folder watch of one helper launch
/// (#4493). When these fail, local polish never starts, a helper keeps its memory after the app
/// is gone, the app deletes the folder of another running copy of itself, or polish stays
/// silently off after a cleaning tool removed the socket file.
///
/// Folders live under `TestTemporaryDirectory`. That root is about 73 bytes long, so a socket
/// path with a real process identity (a 32-byte folder name) would pass the system's 103-byte
/// limit. Tests that create a connection therefore use a short made-up identity and check the
/// length first; the real cache folder and the longest real name are checked without creating
/// anything.
@Suite("Local polish launch connection (#4493)", .tags(.productOutcome))
struct LocalPolishLaunchConnectionTests {
  typealias Connection = LocalPolishLaunchConnection

  // MARK: - Fixtures

  final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Connection.ResourceEvent] = []
    let watchOpened = BoundedWait.Signal()
    let watchClosed = BoundedWait.Signal()

    var observer: Connection.ResourceObserver {
      { [self] event in
        lock.withLock { events.append(event) }
        if event == .watchDescriptorOpened { watchOpened.fire() }
        if case .watchDescriptorClosed = event { watchClosed.fire() }
      }
    }

    var all: [Connection.ResourceEvent] { lock.withLock { events } }
    func count(_ event: Connection.ResourceEvent) -> Int { all.filter { $0 == event }.count }
    /// Every close of the watch's descriptor, with what `close` returned.
    var watchCloses: [Connection.ResourceEvent] {
      all.filter {
        if case .watchDescriptorClosed = $0 { return true }
        return false
      }
    }
  }

  static let shortIdentity = Connection.ProcessIdentity(
    pid: 7, startSeconds: 1, startMicroseconds: 1)
  static let suffix = "abcdef01"
  private static let counter = OSAllocatedCounter()

  /// A parent folder path that does not exist yet, as short as this test process can make it.
  static func freshParent() -> String {
    TestTemporaryDirectory.url.appending(path: "c\(String(counter.next(), radix: 36))").path
  }

  /// A connection in a fresh parent, after proving that its socket path fits.
  static func makeConnection(
    parent: String = freshParent(), ledger: Ledger = Ledger()
  ) throws -> Connection {
    let socketPath =
      parent + "/" + Connection.leafName(identity: shortIdentity, suffix: suffix) + "/s.sock"
    try #require(
      socketPath.utf8.count <= 103,
      "the test folder is too long for a socket path: \(socketPath.utf8.count) bytes")
    return try Connection.create(
      secret: "secret-0123456789", parent: parent, identity: shortIdentity, suffix: suffix,
      observer: ledger.observer)
  }

  static func mode(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : nil
  }

  static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  static func makeFile(_ path: String) {
    #expect(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
  }

  /// `/bin/cat` with the connection's pipe as its standard input: it ends when, and only when,
  /// every writing end of that pipe is closed. `ended` fires from its termination handler.
  static func startReader(of connection: Connection) throws -> (Process, Pipe, BoundedWait.Signal) {
    let reader = Process()
    reader.executableURL = URL(fileURLWithPath: "/bin/cat")
    reader.standardInput = connection.standardInput
    let output = Pipe()
    reader.standardOutput = output
    reader.standardError = FileHandle.nullDevice
    let ended = BoundedWait.Signal()
    reader.terminationHandler = { _ in ended.fire() }
    try reader.run()
    return (reader, output, ended)
  }

  // MARK: - Names, paths and the real cache folder

  @Test("the real cache folder and the longest possible folder name fit the socket path limit")
  func realPathFits() throws {
    let cache = try #require(Connection.userCacheDirectory())
    #expect(cache.hasPrefix("/") && cache.hasSuffix("/"))
    let longest = Connection.leafName(
      identity: .init(pid: 99999, startSeconds: 9_999_999_999, startMicroseconds: 999_999),
      suffix: "ffffffff")
    #expect(longest.utf8.count == 32)
    #expect(Connection.randomSuffix().utf8.count == 8)
    #expect(Connection.parseLeafName(longest) != nil)
    let path = try Connection.validatedSocketPath(leaf: cache + "ewlp/" + longest)
    #expect(path.utf8.count <= 103)
  }

  @Test("this process is found, with a start time that names it")
  func ownIdentity() throws {
    guard case .running(let me) = Connection.lookUp(getpid()) else {
      Issue.record("this process was not found")
      return
    }
    #expect(me.pid == getpid())
    let now = UInt64(Date().timeIntervalSince1970)
    #expect(me.startSeconds > 1_600_000_000 && me.startSeconds <= now)
    #expect(me.startMicroseconds < 1_000_000)
  }

  @Test("a socket path of 103 bytes is accepted and one of 104 bytes is refused")
  func pathBoundary() throws {
    // "/s.sock" is 7 bytes, so a 96-byte folder path gives 103.
    let fits = "/" + String(repeating: "a", count: 95)
    #expect(try Connection.validatedSocketPath(leaf: fits).utf8.count == 103)
    #expect(throws: Connection.CreateError.socketPathUnusable) {
      try Connection.validatedSocketPath(leaf: fits + "a")
    }
    // Bytes count, not characters: 94 characters after the slash, one of them 2 bytes long.
    let accented = "/" + String(repeating: "a", count: 94) + "é"
    #expect(accented.count == 96 && accented.utf8.count == 97)
    #expect(throws: Connection.CreateError.socketPathUnusable) {
      try Connection.validatedSocketPath(leaf: accented)
    }
  }

  @Test("a path that is too long is refused before anything is created")
  func tooLongCreatesNothing() throws {
    let ledger = Ledger()
    let parent = TestTemporaryDirectory.url.appending(path: String(repeating: "p", count: 60)).path
    #expect(throws: Connection.CreateError.socketPathUnusable) {
      try Connection.create(
        secret: "s", parent: parent, identity: Self.shortIdentity, suffix: Self.suffix,
        observer: ledger.observer)
    }
    #expect(!Self.exists(parent))
    #expect(ledger.all.isEmpty)
  }

  static let leafNames: [(String, Bool)] = [
    ("1-0-0-00000000", true),
    ("99999-9999999999-999999-ffffffff", true),
    ("7-1-1-abcdef01", true),
    ("", false),
    ("notaleaf", false),
    ("0-1-1-aaaaaaaa", false),  // no process has number 0
    ("100000-1-1-aaaaaaaa", false),  // 6-digit pid
    ("1-10000000000-1-aaaaaaaa", false),  // 11-digit seconds
    ("1-1-1000000-aaaaaaaa", false),  // 7-digit microseconds
    ("1-1-1-aaaaaaa", false),  // 7 hex
    ("1-1-1-aaaaaaaaa", false),  // 9 hex
    ("1-1-1-AAAAAAAA", false),
    ("1-1-1-aaaaaaag", false),
    ("+1-1-1-aaaaaaaa", false),
    (" 1-1-1-aaaaaaaa", false),
    ("01-1-1-aaaaaaaa", false),  // not the spelling this type writes
    ("1-01-1-aaaaaaaa", false),
    ("1--1-aaaaaaaa", false),
    ("1-1-1", false),
    ("1-1-1-aaaaaaaa-x", false),
    ("١-1-1-aaaaaaaa", false),  // a digit that is not ASCII
  ]

  @Test("which folder names are launch names", arguments: leafNames)
  func leafNameParsing(name: String, isLaunchName: Bool) {
    let owner = Connection.parseLeafName(name)
    #expect((owner != nil) == isLaunchName)
    if let owner {
      #expect(Connection.leafName(identity: owner, suffix: String(name.suffix(8))) == name)
    }
  }

  // MARK: - Creation

  @Test("folders are private, the key file is private, and release removes all of it")
  func createAndRelease() throws {
    let ledger = Ledger()
    let parent = Self.freshParent()
    let connection = try Self.makeConnection(parent: parent, ledger: ledger)
    let leaf = parent + "/7-1-1-abcdef01"
    #expect(connection.inputs.socketPath == leaf + "/s.sock")
    #expect(connection.inputs.keyFileURL.path == leaf + "/k")
    #expect(connection.inputs.secret == "secret-0123456789")
    #expect(Self.mode(parent) == 0o700)
    #expect(Self.mode(leaf) == 0o700)

    let writeEnd = connection.standardInput.fileHandleForWriting.fileDescriptor
    #expect(fcntl(writeEnd, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
    #expect(fcntl(writeEnd, F_GETNOSIGPIPE) == 1)

    try connection.writeKeyFile()
    #expect(Self.mode(leaf + "/k") == 0o600)
    #expect(try Data(contentsOf: connection.inputs.keyFileURL) == Data("secret-0123456789\n".utf8))
    // A second write must not replace a file that is already there.
    #expect(throws: Connection.WriteError.failed) { try connection.writeKeyFile() }
    #expect(Self.exists(leaf + "/k"))
    Self.makeFile(connection.inputs.socketPath)
    #expect(connection.socketFilePresent)

    connection.release()
    connection.release()
    #expect(!Self.exists(leaf))
    #expect(Self.exists(parent))
    #expect(!connection.socketFilePresent)
    #expect(ledger.count(.leafCreated) == 1)
    #expect(ledger.count(.leafRemoved) == 1)
    #expect(ledger.count(.writeEndClosed) == 1)
    #expect(ledger.count(.readEndClosed) == 1)
    #expect(throws: Connection.WriteError.released) { try connection.writePreamble(Data("x".utf8)) }
  }

  @Test("the key file can be removed early, and release still succeeds")
  func keyFileRemovedEarly() throws {
    let connection = try Self.makeConnection()
    try connection.writeKeyFile()
    connection.removeKeyFile()
    connection.removeKeyFile()
    #expect(!Self.exists(connection.inputs.keyFileURL.path))
    connection.release()
    #expect(!Self.exists(connection.leafPath))
  }

  @Test("an existing parent folder is made private; a link or a file in its place is refused")
  func existingParent() throws {
    let open = Self.freshParent()
    #expect(mkdir(open, 0o755) == 0 && chmod(open, 0o755) == 0)
    let connection = try Self.makeConnection(parent: open)
    #expect(Self.mode(open) == 0o700)
    connection.release()

    let target = Self.freshParent()
    #expect(mkdir(target, 0o700) == 0)
    let link = Self.freshParent()
    #expect(symlink(target, link) == 0)
    #expect(throws: Connection.CreateError.failed) { try Self.makeConnection(parent: link) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)

    let file = Self.freshParent()
    Self.makeFile(file)
    #expect(throws: Connection.CreateError.failed) { try Self.makeConnection(parent: file) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data("x".utf8))
  }

  @Test("a launch folder that already exists is refused and left as it was")
  func collision() throws {
    let parent = Self.freshParent()
    let first = try Self.makeConnection(parent: parent)
    try first.writeKeyFile()
    let ledger = Ledger()
    #expect(throws: Connection.CreateError.leafExists) {
      try Self.makeConnection(parent: parent, ledger: ledger)
    }
    #expect(ledger.all.isEmpty)
    #expect(Self.exists(first.inputs.keyFileURL.path))
    first.release()
    #expect(!Self.exists(first.leafPath))
  }

  @Test("release removes only the two known files; anything else stays, and so does the folder")
  func releaseIsNotRecursive() throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    try connection.writeKeyFile()
    Self.makeFile(connection.inputs.socketPath)
    let stranger = connection.leafPath + "/other"
    Self.makeFile(stranger)
    connection.release()
    #expect(!Self.exists(connection.inputs.socketPath))
    #expect(!Self.exists(connection.inputs.keyFileURL.path))
    #expect(Self.exists(stranger))
    #expect(Self.exists(connection.leafPath))
    #expect(ledger.count(.leafRemoved) == 0)
    // The folder is still there, so a late key file would stay for good: it is refused.
    #expect(throws: Connection.WriteError.released) { try connection.writeKeyFile() }
    #expect(!Self.exists(connection.inputs.keyFileURL.path))
  }

  // MARK: - The "app is alive" pipe

  @Test("the helper gets the preamble, and ends when the app releases, with another child alive")
  func releaseEndsTheReaderDespiteAnUnrelatedChild() async throws {
    let connection = try Self.makeConnection()
    // An unrelated child started the plain way inherits every descriptor that is not marked
    // close-on-exec. It is started AFTER the pipe exists and outlives this test's release.
    var sibling: pid_t = 0
    let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
    defer { arguments.forEach { free($0) } }
    try #require(posix_spawn(&sibling, "/bin/sleep", nil, nil, arguments, environ) == 0)
    defer {
      kill(sibling, SIGKILL)
      var status: Int32 = 0
      waitpid(sibling, &status, 0)
    }

    let (reader, output, ended) = try Self.startReader(of: connection)
    connection.closeParentReadEnd()
    try connection.writePreamble(Data("the-secret\n".utf8))
    #expect(reader.isRunning)

    connection.release()
    try await BoundedWait.until(ended)
    #expect(kill(sibling, 0) == 0, "the unrelated child must still be alive at this moment")
    #expect(reader.terminationStatus == 0)
    #expect(output.fileHandleForReading.readDataToEndOfFile() == Data("the-secret\n".utf8))
  }

  @Test("closing the reading end again, after Foundation closed it, touches no other file")
  func readEndClosedOnce() async throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    let readEnd = connection.standardInput.fileHandleForReading.fileDescriptor
    let (reader, _, ended) = try Self.startReader(of: connection)
    // Foundation closed the app's reading end when it started the child.
    // A decoy takes the lowest free number from there up: the same number, unless another
    // test took it in this instant, in which case the check below is weaker but still true.
    let null = open("/dev/null", O_RDONLY)
    let decoy = fcntl(null, F_DUPFD, readEnd)
    defer {
      close(null)
      close(decoy)
    }
    connection.closeParentReadEnd()
    connection.closeParentReadEnd()
    connection.release()
    connection.release()
    #expect(fcntl(decoy, F_GETFD) != -1, "a descriptor that is not the connection's was closed")
    #expect(ledger.count(.readEndClosed) == 1)
    #expect(ledger.count(.writeEndClosed) == 1)
    try await BoundedWait.until(ended)
    #expect(reader.terminationStatus == 0)
  }

  @Test("writing to a helper that is already gone is an error, not a signal")
  func preambleToNobody() throws {
    let connection = try Self.makeConnection()
    defer { connection.release() }
    connection.closeParentReadEnd()  // no reader is left
    #expect(throws: Connection.WriteError.failed) {
      try connection.writePreamble(Data("the-secret\n".utf8))
    }
  }

  // MARK: - Folders left behind

  @Test("only a launch folder whose app process is gone, holding only known files, is removed")
  func leftovers() throws {
    let parent = Self.freshParent()
    #expect(mkdir(parent, 0o700) == 0)
    func leaf(_ name: String, files: [String]) {
      #expect(mkdir(parent + "/" + name, 0o700) == 0)
      for file in files { Self.makeFile(parent + "/" + name + "/" + file) }
    }
    leaf("101-5-6-aaaaaaaa", files: ["s.sock", "k"])  // process gone
    leaf("102-5-6-aaaaaaaa", files: ["s.sock"])  // the number belongs to a later process
    leaf("103-5-6-aaaaaaaa", files: ["s.sock", "k"])  // the same process is alive
    leaf("104-5-6-aaaaaaaa", files: ["s.sock"])  // the question has no answer
    leaf("105-5-6-aaaaaaaa", files: ["s.sock", "other"])  // gone, but holds something unknown
    leaf("106-5-6-aaaaaaaa", files: [])  // gone, empty
    leaf("0107-5-6-aaaaaaaa", files: ["s.sock"])  // not a launch name
    leaf("notaleaf", files: ["s.sock"])
    Self.makeFile(parent + "/108-5-6-aaaaaaaa")  // a file, not a folder
    let elsewhere = Self.freshParent()
    #expect(mkdir(elsewhere, 0o700) == 0)
    Self.makeFile(elsewhere + "/s.sock")
    #expect(symlink(elsewhere, parent + "/109-5-6-aaaaaaaa") == 0)  // a link to a folder

    let removed = Connection.removeLeftovers(parent: parent) { pid in
      switch pid {
      case 102: .running(.init(pid: 102, startSeconds: 5, startMicroseconds: 7))
      case 103: .running(.init(pid: 103, startSeconds: 5, startMicroseconds: 6))
      case 104: .unknown
      default: .absent
      }
    }
    #expect(removed == ["101-5-6-aaaaaaaa", "102-5-6-aaaaaaaa", "106-5-6-aaaaaaaa"])
    let left = try FileManager.default.contentsOfDirectory(atPath: parent).sorted()
    #expect(
      left == [
        "0107-5-6-aaaaaaaa", "103-5-6-aaaaaaaa", "104-5-6-aaaaaaaa", "105-5-6-aaaaaaaa",
        "108-5-6-aaaaaaaa", "109-5-6-aaaaaaaa", "notaleaf",
      ])
    #expect(Self.exists(parent + "/103-5-6-aaaaaaaa/k"))
    #expect(Self.exists(parent + "/105-5-6-aaaaaaaa/s.sock"))
    #expect(Self.exists(parent + "/105-5-6-aaaaaaaa/other"))
    #expect(Self.exists(elsewhere + "/s.sock"))
    // A parent that does not exist is not an error.
    #expect(Connection.removeLeftovers(parent: Self.freshParent()) { _ in .absent }.isEmpty)
  }

  @Test("with the real process question: this live process is kept, a reused number is not")
  func leftoversOfRealProcesses() throws {
    guard case .running(let me) = Connection.lookUp(getpid()) else {
      Issue.record("this process was not found")
      return
    }
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run()
    ended.waitUntilExit()
    let gone = Connection.ProcessIdentity(
      pid: ended.processIdentifier, startSeconds: me.startSeconds, startMicroseconds: 0)
    let reused = Connection.ProcessIdentity(
      pid: me.pid, startSeconds: me.startSeconds - 1, startMicroseconds: me.startMicroseconds)

    let parent = Self.freshParent()
    #expect(mkdir(parent, 0o700) == 0)
    let mine = Connection.leafName(identity: me, suffix: "aaaaaaaa")
    let theirs = Connection.leafName(identity: gone, suffix: "bbbbbbbb")
    let earlier = Connection.leafName(identity: reused, suffix: "cccccccc")
    for name in [mine, theirs, earlier] {
      #expect(mkdir(parent + "/" + name, 0o700) == 0)
      Self.makeFile(parent + "/" + name + "/s.sock")
    }
    let removed = Connection.removeLeftovers(parent: parent, lookUp: Connection.lookUp)
    #expect(Set(removed) == [theirs, earlier])
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent) == [mine])
  }

  // MARK: - The watch on the launch folder

  @Test("the watch is confirmed before it is reported, and sees the socket file removed")
  func watchSeesSocketRemoval() async throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    Self.makeFile(connection.inputs.socketPath)
    let changed = BoundedWait.Signal()
    try await connection.startWatch { changed.fire() }
    #expect(ledger.count(.watchRegistered) == 1)
    #expect(!changed.hasFired)
    #expect(connection.socketFilePresent)
    await #expect(throws: Connection.WatchError.alreadyWatching) {
      try await connection.startWatch {}
    }
    #expect(ledger.count(.watchDescriptorOpened) == 1)

    unlink(connection.inputs.socketPath)
    try await BoundedWait.until(changed)
    #expect(!connection.socketFilePresent)

    connection.release()
    try await BoundedWait.until(ledger.watchClosed)
    connection.release()
    // The watch was asked to stop before the pipe's writing end was closed.
    let order = ledger.all.filter { $0 == .watchCancelRequested || $0 == .writeEndClosed }
    #expect(order == [.watchCancelRequested, .writeEndClosed])
    // Exactly one close, and it closed a descriptor that was open.
    #expect(ledger.watchCloses == [.watchDescriptorClosed(0)])
    #expect(!Self.exists(connection.leafPath))
  }

  @Test("the watch sees the launch folder itself removed")
  func watchSeesFolderRemoval() async throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    let changed = BoundedWait.Signal()
    try await connection.startWatch { changed.fire() }
    #expect(rmdir(connection.leafPath) == 0)
    try await BoundedWait.until(changed)
    connection.release()
    try await BoundedWait.until(ledger.watchClosed)
    #expect(ledger.watchCloses == [.watchDescriptorClosed(0)])
  }

  @Test("release while the watch is not yet confirmed: the wait ends, and one descriptor closes")
  func releaseWhileWatchIsPending() async throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    // A queue that runs nothing yet: the system cannot confirm the watch, or cancel it.
    let parked = DispatchQueue(
      label: "launch-connection-tests.parked", attributes: .initiallyInactive)
    let task = Task { try await connection.startWatch(queue: parked) {} }
    try await BoundedWait.until(ledger.watchOpened)
    connection.release()
    let result = try await BoundedWait.result(of: task, onExpiry: { parked.activate() })
    #expect(throws: Connection.WatchError.released) { try result.get() }
    #expect(ledger.watchCloses.isEmpty)
    parked.activate()
    try await BoundedWait.until(ledger.watchClosed)
    #expect(ledger.watchCloses == [.watchDescriptorClosed(0)])
    #expect(ledger.count(.watchRegistered) == 0)
  }

  @Test("a watch cannot start on a released connection, and opens nothing")
  func watchAfterRelease() async throws {
    let ledger = Ledger()
    let connection = try Self.makeConnection(ledger: ledger)
    connection.release()
    await #expect(throws: Connection.WatchError.released) {
      try await connection.startWatch {}
    }
    #expect(ledger.count(.watchDescriptorOpened) == 0)
    #expect(ledger.watchCloses.isEmpty)
  }
}

/// Hands out 1, 2, 3, … to tests that run at the same time.
private final class OSAllocatedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
