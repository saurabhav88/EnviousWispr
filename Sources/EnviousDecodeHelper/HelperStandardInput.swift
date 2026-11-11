import Foundation

/// The helper's standard input (#4493): the app's pipe. Its first line is the bearer token;
/// after that, the app never writes again, and end-of-file means the app has let go of the
/// helper (released it, quit, or died). One raw `read` loop serves both, so no second buffer
/// can hold bytes the other one needs.
enum HelperStandardInput {
  /// The longest token line accepted. The app sends 72 characters.
  static let maxSecretBytes = 4096

  /// Reads the first line. Nil when input ends first, the line is empty or too long. The value
  /// is never printed.
  static func readSecret() -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let count = read(STDIN_FILENO, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else { return nil }
      if byte == UInt8(ascii: "\n") { break }
      bytes.append(byte)
      guard bytes.count <= maxSecretBytes else { return nil }
    }
    guard !bytes.isEmpty, let secret = String(bytes: bytes, encoding: .utf8) else { return nil }
    return secret
  }

  /// Blocks on standard input on its own thread and calls `onEnd` once, when input ends (or
  /// cannot be read any more). Bytes after the secret line are read and dropped.
  static func watchForEnd(_ onEnd: @escaping @Sendable () -> Void) {
    let thread = Thread {
      var buffer = [UInt8](repeating: 0, count: 256)
      while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { break }
      }
      onEnd()
    }
    thread.name = "envious-decode stdin"
    thread.start()
  }
}

/// The helper's one stop request (#4493). End of standard input and SIGTERM both enter here,
/// in either order and any number of times. Before the server exists there is no model work to
/// cancel, so the process exits at once; after it, the server's stop runs once.
final class HelperStopRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var server: HelperHTTPServer?
  private var stopping = false

  /// Turns SIGTERM into this request, on a background queue, from now on. Built here, outside
  /// the main file's top-level code: a closure written there belongs to the main actor, and
  /// running it on a background queue traps (measured: SIGTRAP on SIGTERM, #4493 C5b). The
  /// returned source must be kept.
  func stopOnSIGTERM() -> any DispatchSourceSignal {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    source.setEventHandler { [self] in request() }
    source.resume()
    return source
  }

  /// Called once the server exists. A stop requested before it was set has already exited.
  func attach(_ server: HelperHTTPServer) {
    lock.withLock { self.server = server }
  }

  func request() {
    let (first, server): (Bool, HelperHTTPServer?) = lock.withLock {
      guard !stopping else { return (false, nil) }
      stopping = true
      return (true, self.server)
    }
    guard first else { return }
    guard let server else {
      // Nothing is loaded that needs a clean end.
      _exit(0)
    }
    helperLog("stopping")
    DispatchQueue.global().asyncAfter(deadline: .now() + shutdownBoundSeconds) { _exit(0) }
    server.stop { _exit(0) }
  }
}
