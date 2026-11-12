import EnviousWisprAppKitTestSupport
import Foundation
import Testing

/// A stand-in for a bundled polish helper on a Unix socket (#4493): it accepts connections on a
/// socket file, reads one HTTP request per connection, and then does what its script says.
///
/// It is written with plain sockets and its own request reader on purpose. It shares no code
/// with `LocalPolishHelperClient`, so the bytes it records and the bytes it sends are an
/// independent check of what the client puts on the wire and how it reads an answer.
final class LocalPolishAFUnixFakeHelper: @unchecked Sendable {
  enum Script: Sendable {
    /// Send exactly these bytes, then close the connection.
    case reply(Data)
    /// Never answer. Wait until the client closes the connection.
    case hold
    /// Hold every request until `count` of them are waiting at the same time, then answer each
    /// with a 200 whose body is that request's own path.
    case answerTogether(count: Int)
  }

  let socketPath: String
  /// Fires when a whole request has been read.
  let requestReceived = BoundedWait.Signal()
  /// Fires when a client closed a connection this helper was holding open.
  let peerDisconnected = BoundedWait.Signal()

  private let script: Script
  private let listener: Int32
  private let condition = NSCondition()
  private var recorded: [Data] = []
  private var waiting = 0
  private var accepted = 0
  private var stopped = false

  /// Every request read so far, as the bytes that arrived.
  var requests: [Data] { condition.withLock { recorded } }
  /// How many connections were accepted so far. Connections are accepted one at a time in
  /// arrival order, so once a later connection was answered, every earlier one is counted.
  var acceptedConnections: Int { condition.withLock { accepted } }

  init(script: Script) throws {
    self.script = script
    socketPath = Self.freshSocketPath()
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    try #require(Self.bind(listener, to: socketPath) == 0)
    try #require(listen(listener, 16) == 0)
    Thread.detachNewThread { [self] in acceptLoop() }
  }

  /// A socket file that nothing listens on: it was bound and then its listener was closed
  /// without removing the file. Connecting to it is refused.
  static func deadSocketPath() throws -> String {
    let path = freshSocketPath()
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    try #require(bind(descriptor, to: path) == 0)
    close(descriptor)
    return path
  }

  /// A path for a socket file that does not exist yet, short enough for `sun_path`.
  static func freshSocketPath() -> String {
    TestTemporaryDirectory.url
      .appending(path: "hc-\(UUID().uuidString.prefix(8)).sock").path
  }

  func stop() {
    condition.withLock {
      stopped = true
      condition.broadcast()
    }
    close(listener)
    unlink(socketPath)
  }

  // MARK: - Serving

  private func acceptLoop() {
    while true {
      let connection = accept(listener, nil, nil)
      guard connection >= 0 else { return }
      condition.withLock { accepted += 1 }
      var on: Int32 = 1
      _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      Thread.detachNewThread { [self] in serve(connection) }
    }
  }

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    guard let request = Self.readRequest(connection) else { return }
    condition.withLock { recorded.append(request) }
    requestReceived.fire()

    switch script {
    case .reply(let bytes):
      Self.writeAll(connection, bytes)
    case .hold:
      // The only thing a client can do now is go away; `read` returns 0 when it does.
      var byte: UInt8 = 0
      while read(connection, &byte, 1) > 0 {}
      peerDisconnected.fire()
    case .answerTogether(let count):
      condition.lock()
      waiting += 1
      condition.broadcast()
      while waiting < count, !stopped { condition.wait() }
      condition.unlock()
      let path = Self.path(of: request)
      let body = Data(#"{"path":"\#(path)"}"#.utf8)
      let head =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
      Self.writeAll(connection, Data(head.utf8) + body)
    }
  }

  // MARK: - This fake's own wire helpers (not the client's)

  private static func bind(_ descriptor: Int32, to path: String) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  /// Reads one request: everything up to the blank line, then as many body bytes as the
  /// `Content-Length` line says. Nil when the client went away first.
  private static func readRequest(_ connection: Int32) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let blankLine = Data("\r\n\r\n".utf8)
    var headEnd: Range<Data.Index>?
    while headEnd == nil {
      let count = read(connection, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(chunk, count: count)
      headEnd = buffer.range(of: blankLine)
    }
    guard let headEnd, let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8)
    else { return nil }
    var bodyLength = 0
    for line in head.components(separatedBy: "\r\n") where line.hasPrefix("Content-Length: ") {
      bodyLength = Int(line.dropFirst("Content-Length: ".count)) ?? 0
    }
    while buffer.count - headEnd.upperBound < bodyLength {
      let count = read(connection, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(chunk, count: count)
    }
    return buffer
  }

  private static func path(of request: Data) -> String {
    let firstLine = String(data: request.prefix(while: { $0 != 13 }), encoding: .utf8) ?? ""
    let parts = firstLine.split(separator: " ")
    return parts.count > 1 ? String(parts[1]) : ""
  }

  private static func writeAll(_ connection: Int32, _ bytes: Data) {
    var sent = 0
    while sent < bytes.count {
      let written = bytes.withUnsafeBytes {
        write(connection, $0.baseAddress! + sent, bytes.count - sent)
      }
      guard written > 0 else { return }
      sent += written
    }
  }
}
