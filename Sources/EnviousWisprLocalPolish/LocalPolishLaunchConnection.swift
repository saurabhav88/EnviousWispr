import Darwin
import Foundation
import os

/// Everything one launch of a bundled polish helper needs in order to talk to the app without a
/// network port (#4493), with one owner and one way out:
///
/// - a private folder for this launch, named after the app process that made it;
/// - the path where the helper will create its socket file, and where a key file may go;
/// - the "app is alive" pipe: the helper gets the reading end as its standard input and stops
///   itself when that end reports end-of-file, which happens when the app closes the writing
///   end or dies in any way;
/// - a watch on the folder, so that the app learns when the socket file is removed.
///
/// `release()` is the only code that takes these apart. It may run any number of times, from
/// any thread. This type knows no helper's command line.
public final class LocalPolishLaunchConnection: @unchecked Sendable {
  // `@unchecked`: every stored property is immutable, except `guarded`, which is a lock. `Pipe`
  // is not `Sendable`; its two handles are only closed here, each once, under that lock.

  /// What a helper's launch command is built from.
  public struct Inputs: Sendable, Equatable {
    /// Where the helper creates its socket file.
    public let socketPath: String
    /// Where the key file goes, for a helper that reads its secret from a file.
    public let keyFileURL: URL
    public let secret: String
  }

  public enum CreateError: Error, Equatable, Sendable {
    /// The socket path does not fit the system's limit. Nothing was created.
    case socketPathUnusable
    /// A folder with this launch's name already exists. It was not touched.
    case leafExists
    case failed
  }

  public enum WatchError: Error, Equatable, Sendable {
    /// The connection was released before the watch was in place.
    case released
    case alreadyWatching
    case failed
  }

  public enum WriteError: Error, Equatable, Sendable {
    case released
    case failed
  }

  /// One process, told apart from a later process that got the same number.
  struct ProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt32
  }

  enum ProcessLookup: Equatable, Sendable {
    case running(ProcessIdentity)
    /// The system says no process has this number.
    case absent
    /// The question could not be answered (for example, another user's process).
    case unknown
  }

  /// What this connection did with a resource. Tests account for every one.
  enum ResourceEvent: Equatable, Sendable {
    case leafCreated
    case leafRemoved
    case readEndClosed
    case writeEndClosed
    case watchDescriptorOpened
    case watchRegistered
    /// `release()` asked the system to stop the watch.
    case watchCancelRequested
    /// The watch's descriptor was closed; the value is what `close` returned (0 = it was open).
    case watchDescriptorClosed(Int32)
  }

  typealias ResourceObserver = @Sendable (ResourceEvent) -> Void

  static let parentName = "ewlp"
  static let socketFileName = "s.sock"
  static let keyFileName = "k"
  /// `sockaddr_un.sun_path` holds 104 bytes, the terminating NUL included.
  static let maxSocketPathBytes = 103

  public let inputs: Inputs
  /// The helper's standard input. Give it to `Process.standardInput` unchanged.
  public let standardInput: Pipe

  let leafPath: String
  private let observer: ResourceObserver?

  private enum Watch {
    case none
    case pending(any DispatchSourceFileSystemObject, CheckedContinuation<Void, any Error>)
    case active(any DispatchSourceFileSystemObject)
    case ended
  }

  private struct Guarded {
    var released = false
    var readEndClosed = false
    var writeEndClosed = false
    var watch = Watch.none
  }
  private let guarded = OSAllocatedUnfairLock(uncheckedState: Guarded())

  private static let watchQueue = DispatchQueue(
    label: "com.enviouswispr.localpolish.launch-connection.watch")

  // MARK: - Creation

  /// Makes the launch folder and the pipe for one launch by this app process.
  public static func create(secret: String) throws -> LocalPolishLaunchConnection {
    guard let cache = userCacheDirectory(), case .running(let me) = lookUp(getpid()) else {
      throw CreateError.failed
    }
    return try create(
      secret: secret, parent: cache + parentName, identity: me, suffix: randomSuffix(),
      observer: nil)
  }

  static func create(
    secret: String, parent: String, identity: ProcessIdentity, suffix: String,
    observer: ResourceObserver?
  ) throws -> LocalPolishLaunchConnection {
    let leaf = parent + "/" + leafName(identity: identity, suffix: suffix)
    // Checked before anything exists, so a path that cannot work leaves nothing behind.
    let socketPath = try validatedSocketPath(leaf: leaf)

    if mkdir(parent, 0o700) != 0, errno != EEXIST { throw CreateError.failed }
    guard makePrivate(directory: parent) else { throw CreateError.failed }
    if mkdir(leaf, 0o700) != 0 {
      throw errno == EEXIST ? CreateError.leafExists : CreateError.failed
    }
    observer?(.leafCreated)
    guard makePrivate(directory: leaf) else {
      rmdir(leaf)
      observer?(.leafRemoved)
      throw CreateError.failed
    }

    let pipe = Pipe()
    let writeEnd = pipe.fileHandleForWriting.fileDescriptor
    // Without close-on-exec, any other child this app starts with a plain `posix_spawn` would
    // inherit the writing end and keep the helper alive after the app is gone (#4493 P7).
    // Without no-SIGPIPE, writing to a helper that already died would kill the app.
    guard fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0
    else {
      try? pipe.fileHandleForWriting.close()
      try? pipe.fileHandleForReading.close()
      rmdir(leaf)
      observer?(.leafRemoved)
      throw CreateError.failed
    }
    return LocalPolishLaunchConnection(
      inputs: Inputs(
        socketPath: socketPath, keyFileURL: URL(fileURLWithPath: leaf + "/" + keyFileName),
        secret: secret),
      standardInput: pipe, leafPath: leaf, observer: observer)
  }

  private init(
    inputs: Inputs, standardInput: Pipe, leafPath: String, observer: ResourceObserver?
  ) {
    self.inputs = inputs
    self.standardInput = standardInput
    self.leafPath = leafPath
    self.observer = observer
  }

  // MARK: - Before and after the helper starts

  /// Writes the secret to the key file, readable by this user only. Fails if the file exists.
  public func writeKeyFile() throws {
    // Under the lock that `release()` takes, so that a key file can never appear after release
    // removed it: nothing would remove it again.
    try guarded.withLockUnchecked { state in
      guard !state.released else { throw WriteError.released }
      let path = inputs.keyFileURL.path
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw WriteError.failed }
      // `fchmod` because the process umask can only take bits away, and must not decide this.
      let written =
        fchmod(descriptor, 0o600) == 0
        && Self.writeAll(descriptor, Data((inputs.secret + "\n").utf8))
      close(descriptor)
      guard written else {
        unlink(path)
        throw WriteError.failed
      }
    }
  }

  /// Removes the key file. The helper has read it once it is ready.
  public func removeKeyFile() {
    unlink(inputs.keyFileURL.path)
  }

  /// Sends `bytes` to the helper's standard input. A helper that is already gone is an error,
  /// never a signal to the app.
  public func writePreamble(_ bytes: Data) throws {
    try guarded.withLockUnchecked { state in
      guard !state.released, !state.writeEndClosed else { throw WriteError.released }
      guard Self.writeAll(standardInput.fileHandleForWriting.fileDescriptor, bytes) else {
        throw WriteError.failed
      }
    }
  }

  /// Closes the app's copy of the pipe's reading end. Call it once the helper was started, or
  /// could not be. Foundation closes that handle itself when it starts a process; closing the
  /// handle object again is then a no-op (measured on macOS 14.8 and 27.2, #4493 C2), which a
  /// plain `close` of the descriptor number would not be.
  public func closeParentReadEnd() {
    let first = guarded.withLockUnchecked { state -> Bool in
      guard !state.readEndClosed else { return false }
      state.readEndClosed = true
      try? standardInput.fileHandleForReading.close()
      return true
    }
    if first { observer?(.readEndClosed) }
  }

  /// Closes only the app's writing end of the "app is alive" pipe, once: the helper then sees
  /// end-of-file as it would if the app died. Nothing else is released. Real-boundary tests
  /// use it; the app releases the whole launch instead.
  func closeWriteEnd() {
    let first = guarded.withLockUnchecked { state -> Bool in
      guard !state.writeEndClosed else { return false }
      state.writeEndClosed = true
      try? standardInput.fileHandleForWriting.close()
      return true
    }
    if first { observer?(.writeEndClosed) }
  }

  // MARK: - The watch on the launch folder

  /// True while the helper's socket file exists.
  public var socketFilePresent: Bool {
    var info = stat()
    return lstat(inputs.socketPath, &info) == 0
  }

  /// Starts watching the launch folder and returns once the system has CONFIRMED the watch, so
  /// that a caller who then looks at the folder cannot miss a change. `onChange` runs when an
  /// entry of the folder is added or removed, or the folder itself is removed or renamed; it
  /// says only "look again". Throws `.released` if the connection is released first.
  public func startWatch(onChange: @escaping @Sendable () -> Void) async throws {
    try await startWatch(queue: Self.watchQueue, onChange: onChange)
  }

  func startWatch(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let started = guarded.withLockUnchecked {
        state -> Result<any DispatchSourceFileSystemObject, WatchError> in
        guard !state.released else { return .failure(.released) }
        guard case .none = state.watch else { return .failure(.alreadyWatching) }
        // Event-only: this descriptor does not keep the folder's volume busy.
        let descriptor = open(leafPath, O_EVTONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else { return .failure(.failed) }
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setRegistrationHandler { [weak self] in self?.watchRegistered() }
        // The ONLY place this descriptor is closed. The system runs it once, after the source
        // was cancelled and can deliver nothing more.
        let observer = self.observer
        source.setCancelHandler {
          let result = close(descriptor)
          observer?(.watchDescriptorClosed(result))
        }
        state.watch = .pending(source, continuation)
        return .success(source)
      }
      switch started {
      case .success(let source):
        observer?(.watchDescriptorOpened)
        source.activate()
      case .failure(let error): continuation.resume(throwing: error)
      }
    }
  }

  private func watchRegistered() {
    let waiting = guarded.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
      guard case .pending(let source, let continuation) = state.watch else { return nil }
      state.watch = .active(source)
      return continuation
    }
    guard let waiting else { return }
    observer?(.watchRegistered)
    waiting.resume()
  }

  // MARK: - Release

  /// Takes the launch apart: stops the watch, closes both ends of the pipe, removes the socket
  /// file and the key file, then removes the folder if it is empty. Never deletes recursively:
  /// anything else in the folder stays, and so does the folder.
  public func release() {
    // `steps` records what was done, in the order it was done; the observer hears it after the
    // lock is released.
    let (first, waiting, steps) = guarded.withLockUnchecked {
      state -> (Bool, CheckedContinuation<Void, any Error>?, [ResourceEvent]) in
      guard !state.released else { return (false, nil, []) }
      state.released = true
      var steps: [ResourceEvent] = []
      var waiting: CheckedContinuation<Void, any Error>?
      // The watch first. Cancelling only asks; the descriptor is closed by the cancellation
      // handler, not here.
      switch state.watch {
      case .pending(let source, let continuation):
        source.cancel()
        steps.append(.watchCancelRequested)
        waiting = continuation
      case .active(let source):
        source.cancel()
        steps.append(.watchCancelRequested)
      case .none, .ended: break
      }
      state.watch = .ended
      if !state.writeEndClosed {
        state.writeEndClosed = true
        try? standardInput.fileHandleForWriting.close()
        steps.append(.writeEndClosed)
      }
      return (true, waiting, steps)
    }
    guard first else { return }
    waiting?.resume(throwing: WatchError.released)
    if let observer { steps.forEach(observer) }
    closeParentReadEnd()
    unlink(inputs.socketPath)
    unlink(inputs.keyFileURL.path)
    if rmdir(leafPath) == 0 { observer?(.leafRemoved) }
  }

  // MARK: - Folders that an earlier app process left behind

  /// Removes launch folders whose app process is gone. Returns the names it removed.
  @discardableResult
  public static func removeLeftovers() -> [String] {
    guard let cache = userCacheDirectory() else { return [] }
    return removeLeftovers(parent: cache + parentName, lookUp: lookUp)
  }

  /// A folder is removed only when ALL hold: its name is a launch name; the process it names
  /// does not exist, or is a different process with the same number (another start time); it is
  /// a real folder of this user; and it holds nothing but the two known files. Anything else is
  /// left alone, including when the process question cannot be answered.
  @discardableResult
  static func removeLeftovers(
    parent: String, lookUp: (Int32) -> ProcessLookup
  ) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
      return []
    }
    var removed: [String] = []
    for name in names.sorted() {
      guard let owner = parseLeafName(name) else { continue }
      switch lookUp(owner.pid) {
      case .unknown: continue
      case .running(let live) where live == owner: continue
      case .running, .absent: break
      }
      let leaf = parent + "/" + name
      var info = stat()
      guard lstat(leaf, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
        let entries = try? FileManager.default.contentsOfDirectory(atPath: leaf),
        entries.allSatisfy({ $0 == socketFileName || $0 == keyFileName })
      else { continue }
      for entry in entries { unlink(leaf + "/" + entry) }
      if rmdir(leaf) == 0 { removed.append(name) }
    }
    return removed
  }

  // MARK: - Names and paths

  static func leafName(identity: ProcessIdentity, suffix: String) -> String {
    "\(identity.pid)-\(identity.startSeconds)-\(identity.startMicroseconds)-\(suffix)"
  }

  /// The owner a launch folder's name states, or nil when the name is not a launch name:
  /// `<pid 1-5 digits>-<seconds 1-10 digits>-<microseconds 1-6 digits>-<8 lowercase hex>`.
  static func parseLeafName(_ name: String) -> ProcessIdentity? {
    let parts = name.utf8.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
    guard parts.count == 4,
      let pid = number(parts[0], maxDigits: 5), pid > 0,
      let seconds = number(parts[1], maxDigits: 10),
      let microseconds = number(parts[2], maxDigits: 6),
      parts[3].count == 8,
      parts[3].allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      })
    else { return nil }
    let owner = ProcessIdentity(
      pid: Int32(pid), startSeconds: seconds, startMicroseconds: UInt32(microseconds))
    // Only the exact spelling this type writes (no leading zeros) is a launch name.
    let suffix = String(decoding: parts[3], as: UTF8.self)
    return leafName(identity: owner, suffix: suffix) == name ? owner : nil
  }

  /// ASCII digits only (no sign, no space), at most `maxDigits` of them.
  private static func number(_ digits: Substring.UTF8View, maxDigits: Int) -> UInt64? {
    guard (1...maxDigits).contains(digits.count),
      digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
    else { return nil }
    return digits.reduce(UInt64(0)) { $0 * 10 + UInt64($1 - UInt8(ascii: "0")) }
  }

  /// The socket path inside `leaf`, or `socketPathUnusable` when its UTF-8 form is too long.
  static func validatedSocketPath(leaf: String) throws -> String {
    let path = leaf + "/" + socketFileName
    guard path.utf8.count <= maxSocketPathBytes else { throw CreateError.socketPathUnusable }
    return path
  }

  static func randomSuffix() -> String {
    String(format: "%08x", UInt32.random(in: .min ... .max))
  }

  /// This user's cache folder, with its trailing slash.
  static func userCacheDirectory() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
    guard length > 1, length <= buffer.count else { return nil }
    let path = String(cString: buffer)
    return path.hasSuffix("/") ? path : path + "/"
  }

  /// Who has this process number now, with the start time that tells a reused number apart.
  static func lookUp(_ pid: Int32) -> ProcessLookup {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return errno == ESRCH ? .absent : .unknown
    }
    return .running(
      ProcessIdentity(
        pid: pid, startSeconds: info.pbi_start_tvsec,
        startMicroseconds: UInt32(clamping: info.pbi_start_tvusec)))
  }

  /// True when `directory` is a real folder (not a link) of this user with mode 0700, after
  /// setting that mode if it differed.
  private static func makePrivate(directory: String) -> Bool {
    var info = stat()
    guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
    else { return false }
    if info.st_mode & 0o7777 == 0o700 { return true }
    guard chmod(directory, 0o700) == 0, lstat(directory, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o7777 == 0o700
  }

  private static func writeAll(_ descriptor: Int32, _ bytes: Data) -> Bool {
    var sent = 0
    while sent < bytes.count {
      let written = bytes.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress! + sent, bytes.count - sent)
      }
      if written > 0 {
        sent += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        return false
      }
    }
    return true
  }
}
