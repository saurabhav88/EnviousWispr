import Foundation
import os

/// Where one launch of a bundled polish helper listens, and the bearer that authenticates the
/// app to it (#4493). The path is a Unix socket in that launch's private directory.
public struct LocalPolishHelperAddress: Sendable, Equatable {
  public let socketPath: String
  public let authToken: String

  public init(socketPath: String, authToken: String) {
    self.socketPath = socketPath
    self.authToken = authToken
  }
}

/// One HTTP request to a bundled polish helper. `timeout` bounds the WHOLE request, from the
/// call to `perform` to the last response byte.
public struct LocalPolishHelperRequest: Sendable, Equatable {
  public enum Method: String, Sendable {
    case get = "GET"
    case post = "POST"
  }

  public let method: Method
  public let path: String
  public let body: Data?
  public let timeout: Duration

  public init(method: Method, path: String, body: Data? = nil, timeout: Duration) {
    self.method = method
    self.path = path
    self.body = body
    self.timeout = timeout
  }
}

public struct LocalPolishHelperResponse: Sendable, Equatable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

/// Why a request to a bundled helper produced no response. A cancelled request throws
/// `CancellationError` instead.
public enum LocalPolishHelperClientError: Error, Equatable, Sendable {
  /// Nothing accepts connections at the socket path: the file is missing or nobody listens.
  case notConnectable
  /// The connection ended before a complete response arrived.
  case connectionLost
  /// The request's time limit passed.
  case timedOut
  /// Anything else, including a response that is not exactly one well-formed HTTP message
  /// with one `Content-Length` and a body of that length.
  case failed
}

/// The one owner of app-to-helper requests (#4493): it sends ONE HTTP/1.1 request to ONE bundled
/// polish helper over that helper's Unix socket and returns the status and body.
///
/// Why this is not `URLSession` or `NWConnection`: `URLSession` cannot carry a request over a
/// Unix socket on macOS 14, and `NWConnection` fails against llama-server's Unix socket
/// (measured 2026-11-11: 1 of 12 and 0 of 12 connections, while plain sockets worked every
/// time). So the carrier is a POSIX socket and the response parser is `CFHTTPMessage`.
///
/// One connection per request, `Connection: close`: both helpers answer that way, and closing
/// the connection is how a helper learns that a request was cancelled.
///
/// It holds no policy. Which route, which timeout, whether to retry and what an answer means
/// stay with each caller.
public enum LocalPolishHelperClient {

  /// Sends `request` to the helper at `address`.
  ///
  /// Throws `LocalPolishHelperClientError`, or `CancellationError` when the calling task is
  /// cancelled. Cancelling closes the connection, which is the disconnect the helper treats as
  /// "stop working on this request".
  public static func perform(
    _ request: LocalPolishHelperRequest, at address: LocalPolishHelperAddress
  ) async throws -> LocalPolishHelperResponse {
    try await perform(request, at: address, ioQueue: sharedIOQueue, observer: nil)
  }

  // MARK: - Resource accounting (tests only read this)

  /// The resources one request owns besides its timer and continuation.
  enum Resource: Sendable, Equatable {
    case socket
    case cancelReader
    case cancelWriter
  }

  /// What a request did with a resource. Production passes no observer; the client's tests use
  /// it to check that every descriptor is closed exactly once on every path.
  enum ResourceEvent: Sendable, Equatable {
    case opened(Resource)
    case closed(Resource)
    /// The I/O block has returned; nothing of this request is open any more.
    case ioFinished
  }

  typealias ResourceObserver = @Sendable (ResourceEvent) -> Void

  /// Blocking socket work runs here, never on the cooperative pool. Concurrent, because the
  /// llama word check sends eight requests at once and each blocks in `poll`.
  private static let sharedIOQueue = DispatchQueue(
    label: "com.enviouswispr.localpolish.helper-client", qos: .userInitiated,
    attributes: .concurrent)

  /// The same request with its I/O queue and resource observer supplied.
  static func perform(
    _ request: LocalPolishHelperRequest, at address: LocalPolishHelperAddress,
    ioQueue: DispatchQueue, observer: ResourceObserver?
  ) async throws -> LocalPolishHelperResponse {
    // The one deadline of this request, taken before anything else. The timer and every wait
    // measure against it, so set-up time and queue time come out of the caller's limit.
    let deadline = ContinuousClock.now + request.timeout
    try Task.checkCancellation()
    guard let message = serialize(request, authToken: address.authToken) else {
      throw LocalPolishHelperClientError.failed
    }
    // The cancel pipe exists before anything can cancel, so a cancellation at ANY moment has a
    // descriptor to wake the I/O block with.
    var pipeEnds: [Int32] = [-1, -1]
    guard pipe(&pipeEnds) == 0 else { throw LocalPolishHelperClientError.failed }
    let cancelReader = pipeEnds[0]
    let cancelWriter = pipeEnds[1]
    observer?(.opened(.cancelReader))
    observer?(.opened(.cancelWriter))
    for descriptor in pipeEnds {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    // A wake-up byte written after the I/O block closed its end must not raise SIGPIPE.
    _ = fcntl(cancelWriter, F_SETNOSIGPIPE, 1)

    let state = RequestState(cancelWriter: cancelWriter, observer: observer)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.install(continuation, deadline: deadline)
        // Always queued, even when the request is already finished: this block is the only
        // code that retires the request's descriptors.
        ioQueue.async {
          runExchange(
            state: state, message: message, socketPath: address.socketPath,
            cancelReader: cancelReader, deadline: deadline, observer: observer)
        }
      }
    } onCancel: {
      state.finish(.failure(CancellationError()))
    }
  }

  // MARK: - One request's state

  /// Owns the continuation, the deadline timer and the cancel pipe's write end of one request.
  /// The first `finish` wins; later ones do nothing.
  final class RequestState: Sendable {
    private struct Guarded {
      var continuation: CheckedContinuation<LocalPolishHelperResponse, any Error>?
      var pendingResult: Result<LocalPolishHelperResponse, any Error>?
      var finished = false
      var timer: (any DispatchSourceTimer)?
      var cancelWriter: Int32
    }
    private let guarded: OSAllocatedUnfairLock<Guarded>
    private let observer: ResourceObserver?
    private static let timerQueue = DispatchQueue(
      label: "com.enviouswispr.localpolish.helper-client.deadline")

    init(cancelWriter: Int32, observer: ResourceObserver?) {
      guarded = OSAllocatedUnfairLock(
        uncheckedState: Guarded(cancelWriter: cancelWriter))
      self.observer = observer
    }

    var isFinished: Bool { guarded.withLockUnchecked { $0.finished } }

    /// Hands over the continuation and arms the timer for what is left until `deadline`. A
    /// request that was cancelled before this point is resumed at once.
    func install(
      _ continuation: CheckedContinuation<LocalPolishHelperResponse, any Error>,
      deadline: ContinuousClock.Instant
    ) {
      let early = guarded.withLockUnchecked {
        state -> Result<LocalPolishHelperResponse, any Error>? in
        if state.finished {
          defer { state.pendingResult = nil }
          return state.pendingResult
        }
        state.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        timer.schedule(
          deadline: .now() + Self.dispatchInterval(deadline - ContinuousClock.now))
        timer.setEventHandler { [weak self] in
          self?.finish(.failure(LocalPolishHelperClientError.timedOut))
        }
        state.timer = timer
        timer.resume()
        return nil
      }
      if let early { continuation.resume(with: early) }
    }

    /// Ends the request with `result` unless it already ended, cancels the deadline and wakes
    /// the I/O block. Safe from any thread, any number of times.
    func finish(_ result: Result<LocalPolishHelperResponse, any Error>) {
      let (continuation, timer) = guarded.withLockUnchecked {
        state -> (
          CheckedContinuation<LocalPolishHelperResponse, any Error>?, (any DispatchSourceTimer)?
        ) in
        guard !state.finished else { return (nil, nil) }
        state.finished = true
        let continuation = state.continuation
        let timer = state.timer
        state.continuation = nil
        state.timer = nil
        if continuation == nil { state.pendingResult = result }
        // Wake the I/O block. Written under the lock that also guards retirement, so this can
        // never touch a descriptor that was closed or reused. Nonblocking; a full pipe or a
        // closed read end is fine, because one pending byte is all the reader needs.
        if state.cancelWriter >= 0 {
          var byte: UInt8 = 1
          _ = write(state.cancelWriter, &byte, 1)
        }
        return (continuation, timer)
      }
      timer?.cancel()
      continuation?.resume(with: result)
    }

    /// Closes the cancel pipe's write end, once. Called by the I/O block when it returns.
    func retireCancelWriter() {
      let closed = guarded.withLockUnchecked { state -> Bool in
        guard state.cancelWriter >= 0 else { return false }
        close(state.cancelWriter)
        state.cancelWriter = -1
        return true
      }
      if closed { observer?(.closed(.cancelWriter)) }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
      let nanoseconds = LocalPolishHelperClient.nanoseconds(duration)
      return .nanoseconds(Int(clamping: max(nanoseconds, 0)))
    }
  }

  // MARK: - The exchange (runs on the I/O queue)

  private enum Wait {
    case ready(Int16)
    case woken
    case deadline
    case failed
  }

  private static func runExchange(
    state: RequestState, message: Data, socketPath: String, cancelReader: Int32,
    deadline: ContinuousClock.Instant, observer: ResourceObserver?
  ) {
    defer {
      close(cancelReader)
      observer?(.closed(.cancelReader))
      state.retireCancelWriter()
      observer?(.ioFinished)
    }
    // Finished before it started (cancelled, or the timer fired while queued): do not connect.
    guard !state.isFinished else { return }
    // Out of time, whether or not the timer has run yet: do not connect.
    guard ContinuousClock.now < deadline else {
      state.finish(.failure(LocalPolishHelperClientError.timedOut))
      return
    }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      state.finish(.failure(LocalPolishHelperClientError.failed))
      return
    }
    observer?(.opened(.socket))
    defer {
      close(descriptor)
      observer?(.closed(.socket))
    }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    var on: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    let outcome = exchange(
      descriptor: descriptor, message: message, socketPath: socketPath,
      cancelReader: cancelReader, deadline: deadline, isFinished: { state.isFinished })
    state.finish(outcome.mapError { $0 as any Error })
  }

  /// Connects, sends the whole request and reads to end-of-file, all under one deadline. A
  /// wake-up on the cancel pipe ends it at once. `isFinished` is asked before the connect and
  /// before every write and read, so a request that was cancelled or timed out does no further
  /// work even when no call had to wait. Whoever finished the request already delivered its
  /// result, so the error returned for those cases is never delivered.
  private static func exchange(
    descriptor: Int32, message: Data, socketPath: String, cancelReader: Int32,
    deadline: ContinuousClock.Instant, isFinished: () -> Bool
  ) -> Result<LocalPolishHelperResponse, LocalPolishHelperClientError> {
    // Connect.
    guard var address = socketAddress(path: socketPath) else { return .failure(.failed) }
    guard !isFinished() else { return .failure(.failed) }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected != 0 {
      let code = errno
      guard code == EINPROGRESS || code == EINTR else { return .failure(connectError(code)) }
      // Still connecting: writable means "finished", not "succeeded". The result is SO_ERROR.
      switch wait(
        descriptor: descriptor, events: Int16(POLLOUT), cancelReader: cancelReader,
        deadline: deadline)
      {
      case .woken: return .failure(.failed)
      case .deadline: return .failure(.timedOut)
      case .failed: return .failure(.failed)
      case .ready:
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
          return .failure(.failed)
        }
        if socketError != 0 { return .failure(connectError(socketError)) }
      }
    }

    // Send the complete request.
    var sent = 0
    while sent < message.count {
      guard !isFinished() else { return .failure(.failed) }
      let written = message.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress! + sent, message.count - sent)
      }
      if written > 0 {
        sent += written
        continue
      }
      let code = errno
      if written < 0, code == EINTR { continue }
      if written < 0, code == EAGAIN || code == EWOULDBLOCK {
        switch wait(
          descriptor: descriptor, events: Int16(POLLOUT), cancelReader: cancelReader,
          deadline: deadline)
        {
        case .ready: continue
        case .woken: return .failure(.failed)
        case .deadline: return .failure(.timedOut)
        case .failed: return .failure(.failed)
        }
      }
      return .failure(code == EPIPE || code == ECONNRESET ? .connectionLost : .failed)
    }

    // Read to end-of-file. Readable bytes are drained before a hang-up decides anything: a
    // complete response followed by the helper closing is the normal, successful case.
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    reading: while true {
      guard !isFinished() else { return .failure(.failed) }
      let count = read(descriptor, &chunk, chunk.count)
      if count > 0 {
        received.append(chunk, count: count)
        continue
      }
      if count == 0 { break reading }
      let code = errno
      if code == EINTR { continue }
      if code == EAGAIN || code == EWOULDBLOCK {
        switch wait(
          descriptor: descriptor, events: Int16(POLLIN), cancelReader: cancelReader,
          deadline: deadline)
        {
        case .ready: continue  // readable, hung up, or both: the next `read` tells which
        case .woken: return .failure(.failed)
        case .deadline: return .failure(.timedOut)
        case .failed: return .failure(.failed)
        }
      }
      if code == ECONNRESET || code == EPIPE {
        // The peer reset the connection. What arrived before that may still be a whole response.
        break reading
      }
      return .failure(.failed)
    }
    return parseResponse(received)
  }

  /// Waits until `descriptor` reports one of `events` (or an error or hang-up), the cancel pipe
  /// has a byte, or the deadline passes. Every wait in the exchange goes through here, so every
  /// wait is cancellable and bounded.
  private static func wait(
    descriptor: Int32, events: Int16, cancelReader: Int32, deadline: ContinuousClock.Instant
  ) -> Wait {
    while true {
      let timeout = pollTimeoutMilliseconds(remaining: deadline - ContinuousClock.now)
      guard timeout > 0 else { return .deadline }
      var descriptors = [
        pollfd(fd: descriptor, events: events, revents: 0),
        pollfd(fd: cancelReader, events: Int16(POLLIN), revents: 0),
      ]
      let ready = poll(&descriptors, 2, timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        return .failed
      }
      if descriptors[1].revents != 0 { return .woken }
      if ready == 0 { continue }  // the loop re-reads the clock; a rounded-up wait is not a timeout
      if descriptors[0].revents != 0 { return .ready(descriptors[0].revents) }
    }
  }

  // MARK: - Pure pieces

  /// The time left, as a `poll` timeout: rounded UP to a whole millisecond so that a wait never
  /// returns before the deadline, and 0 when no time is left.
  static func pollTimeoutMilliseconds(remaining: Duration) -> Int32 {
    let nanoseconds = nanoseconds(remaining)
    guard nanoseconds > 0 else { return 0 }
    // Saturating: a time limit so large that its nanoseconds are already `Int64.max` must not
    // trap on the round-up.
    let (padded, overflow) = nanoseconds.addingReportingOverflow(999_999)
    let milliseconds = (overflow ? Int64.max : padded) / 1_000_000
    return Int32(clamping: milliseconds)
  }

  static func nanoseconds(_ duration: Duration) -> Int64 {
    let parts = duration.components
    let (scaled, overflow) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    if overflow { return parts.seconds > 0 ? .max : .min }
    let (total, overflowed) = scaled.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
    return overflowed ? (parts.seconds > 0 ? .max : .min) : total
  }

  /// What a failed `connect`, or a nonzero `SO_ERROR` after one, means.
  static func connectError(_ code: Int32) -> LocalPolishHelperClientError {
    switch code {
    case ENOENT, ECONNREFUSED: .notConnectable
    case ETIMEDOUT: .timedOut
    default: .failed
    }
  }

  /// A `sockaddr_un` for `path`, or nil when the path does not fit (`sun_path` holds 104 bytes
  /// with its terminator).
  static func socketAddress(path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  /// The request as bytes on the wire, or nil when the path or the token could break the
  /// request line or a header.
  static func serialize(_ request: LocalPolishHelperRequest, authToken: String) -> Data? {
    // Checked as BYTES. In Swift "\r\n" is one Character, so a Character test would let a
    // carriage-return-line-feed pair through, and with it a second header line.
    func isSafe(_ text: String) -> Bool {
      !text.utf8.contains { $0 == 13 || $0 == 10 || $0 == 32 || $0 == 0 }
    }
    guard request.path.hasPrefix("/"), isSafe(request.path), !authToken.isEmpty, isSafe(authToken)
    else { return nil }
    var head = "\(request.method.rawValue) \(request.path) HTTP/1.1\r\n"
    head += "Host: localhost\r\n"
    head += "Authorization: Bearer \(authToken)\r\n"
    head += "Connection: close\r\n"
    if let body = request.body {
      head += "Content-Type: application/json\r\n"
      head += "Content-Length: \(body.count)\r\n"
    }
    head += "\r\n"
    return Data(head.utf8) + (request.body ?? Data())
  }

  /// Everything the helper sent before it closed, as a response.
  ///
  /// Accepted: exactly one well-formed HTTP response with exactly one `Content-Length`, no
  /// `Transfer-Encoding`, and a body of exactly that length. A response cut off before that is
  /// `connectionLost`; anything else is `failed`. Both helpers answer these routes this way
  /// (measured for llama-server; `HelperHTTPServer.send` for envious-decode).
  static func parseResponse(
    _ received: Data
  ) -> Result<LocalPolishHelperResponse, LocalPolishHelperClientError> {
    let terminator = Data("\r\n\r\n".utf8)
    guard let headEnd = received.range(of: terminator) else {
      // No complete header block arrived before end-of-file.
      return .failure(.connectionLost)
    }
    // The platform parser reads the message. It is lenient: for a first line that is not an HTTP
    // status line it still reports status 200 with an empty status line (measured 2026-11-11), so
    // the status line and the version are required here before the status is believed.
    let message = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
    let appended = received.withUnsafeBytes { buffer in
      CFHTTPMessageAppendBytes(
        message, buffer.bindMemory(to: UInt8.self).baseAddress!, received.count)
    }
    guard appended, CFHTTPMessageIsHeaderComplete(message) else { return .failure(.failed) }
    let status = CFHTTPMessageGetResponseStatusCode(message)
    let statusLine =
      CFHTTPMessageCopyResponseStatusLine(message)?.takeRetainedValue() as String? ?? ""
    let version = CFHTTPMessageCopyVersion(message).takeRetainedValue() as String
    guard !statusLine.isEmpty, version == "HTTP/1.1" || version == "HTTP/1.0" else {
      return .failure(.failed)
    }
    guard (100...599).contains(status) else { return .failure(.failed) }

    // How many times a header appears is read from the wire, not from the parser: a header
    // dictionary joins repeated fields into one value, which cannot show that there were two.
    guard
      let head = String(data: received[received.startIndex..<headEnd.lowerBound], encoding: .utf8)
    else { return .failure(.failed) }
    var lengths: [String] = []
    for line in head.components(separatedBy: "\r\n").dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { return .failure(.failed) }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      if name == "transfer-encoding" { return .failure(.failed) }
      if name == "content-length" {
        lengths.append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }
    }
    guard lengths.count == 1, let declared = lengths.first,
      !declared.isEmpty, declared.allSatisfy({ $0.isASCII && $0.isNumber }),
      let length = Int(declared)
    else { return .failure(.failed) }

    let body = received[headEnd.upperBound...]
    if body.count < length { return .failure(.connectionLost) }
    guard body.count == length else { return .failure(.failed) }
    return .success(LocalPolishHelperResponse(status: status, body: Data(body)))
  }
}
