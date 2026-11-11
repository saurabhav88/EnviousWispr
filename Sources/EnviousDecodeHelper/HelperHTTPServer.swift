import Foundation
import Network

/// One request, read whole. Header names are lowercased.
struct HelperRequest: Sendable {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
}

/// One answer. `nil` from a handler means "send nothing": the request was cancelled.
struct HelperResponse: Sendable {
  let status: Int
  let body: Data

  static func error(_ status: Int, type: String, message: String) -> HelperResponse {
    let body =
      (try? JSONSerialization.data(
        withJSONObject: ["error": ["type": type, "message": message]], options: [.sortedKeys]))
      ?? Data()
    return HelperResponse(status: status, body: body)
  }
}

/// A small HTTP/1.1 server for the app's own two requests, on the loopback address only.
///
/// It is not a general server, on purpose. One request per connection: the request is read
/// whole (headers up to `maxHeaderBytes`, then exactly `Content-Length` bytes up to
/// `maxBodyBytes`, in however many pieces they arrive), answered, and the connection is
/// closed. A chunked or otherwise encoded body and `Expect` are refused. If the client goes
/// away while its request is being worked on, the work is cancelled.
final class HelperHTTPServer: @unchecked Sendable {
  static let maxHeaderBytes = 16 * 1024
  static let maxBodyBytes = 8 * 1024 * 1024

  typealias Handler = @Sendable (HelperRequest) async -> HelperResponse?

  private let listener: NWListener
  private let handler: Handler
  /// Every callback of the listener and of its connections runs here, so the state below needs
  /// no other guard.
  private let queue = DispatchQueue(label: "com.enviouswispr.envious-decode.http")
  private var work: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var stopped = false

  /// Listens on the Unix socket at `socketPath` and nothing else (#4493): no network port
  /// exists. The path is in the launch's private folder, which only this user can enter.
  init(socketPath: String, handler: @escaping Handler) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: socketPath)
    listener = try NWListener(using: parameters)
    self.handler = handler
  }

  /// Starts listening. Returns when the socket is bound; throws when it cannot be.
  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // The state handler runs on `queue` only; the box lets it answer the continuation once.
      let answered = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if answered.first() { continuation.resume() }
        case .failed(let error):
          if answered.first() { continuation.resume(throwing: error) }
        case .cancelled:
          if answered.first() { continuation.resume(throwing: CancellationError()) }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
    }
  }

  private final class Once: @unchecked Sendable {
    private var used = false
    func first() -> Bool {
      defer { used = true }
      return !used
    }
  }

  /// Takes no more connections and cancels the work in progress. `whenIdle` runs once no
  /// request is being worked on (at once when none is).
  func stop(whenIdle: @escaping @Sendable () -> Void) {
    queue.async {
      self.stopped = true
      self.listener.cancel()
      for task in self.work.values { task.cancel() }
      self.idleHandler = whenIdle
      self.reportIdleIfDone()
    }
  }

  private var idleHandler: (@Sendable () -> Void)?

  private func reportIdleIfDone() {
    guard stopped, work.isEmpty, let idleHandler else { return }
    self.idleHandler = nil
    idleHandler()
  }

  // MARK: - One connection

  private func accept(_ connection: NWConnection) {
    guard !stopped else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  /// Reads until the headers are complete, then until the body is.
  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      switch Self.parse(buffer) {
      case .request(let request):
        self.serve(request, on: connection)
      case .refuse(let response):
        self.send(response, on: connection)
      case .needMore:
        if isComplete || error != nil {
          connection.cancel()  // the client left before it finished its request
        } else {
          self.read(connection, buffer: buffer)
        }
      }
    }
  }

  private func serve(_ request: HelperRequest, on connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    let handler = self.handler
    work[id] = Task { [weak self] in
      let response = await handler(request)
      // Read inside the task: a cancelled request gets no answer, even a finished one.
      let answer = Task.isCancelled ? nil : response
      guard let self else { return }
      self.queue.async {
        self.work[id] = nil
        if let answer {
          self.send(answer, on: connection)
        } else {
          connection.cancel()
        }
        self.reportIdleIfDone()
      }
    }
    // While the request is worked on, the only thing the client can do is go away. Anything
    // read here means that: the end of its stream, an error, or bytes it had no reason to send.
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
      self?.work[id]?.cancel()
    }
  }

  private func send(_ response: HelperResponse, on connection: NWConnection) {
    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + response.body,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 411: "Length Required"
    case 413: "Content Too Large"
    case 417: "Expectation Failed"
    case 431: "Request Header Fields Too Large"
    case 501: "Not Implemented"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
  }

  // MARK: - Parsing

  enum Parsed {
    case needMore
    case request(HelperRequest)
    case refuse(HelperResponse)
  }

  /// What the bytes read so far are: not yet a whole request, a whole request, or a request
  /// this server does not take.
  static func parse(_ buffer: Data) -> Parsed {
    let terminator = Data("\r\n\r\n".utf8)
    guard let headEnd = buffer.range(of: terminator) else {
      return buffer.count > maxHeaderBytes
        ? .refuse(.error(431, type: "invalid_request_error", message: "headers too large"))
        : .needMore
    }
    guard headEnd.lowerBound <= maxHeaderBytes,
      let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8)
    else {
      return .refuse(.error(431, type: "invalid_request_error", message: "headers too large"))
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
      return .refuse(.error(400, type: "invalid_request_error", message: "malformed request line"))
    }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else {
        return .refuse(.error(400, type: "invalid_request_error", message: "malformed header"))
      }
      let name = line[..<colon].lowercased()
      guard headers[name] == nil else {
        return .refuse(
          .error(400, type: "invalid_request_error", message: "repeated header \(name)"))
      }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil {
      return .refuse(
        .error(501, type: "invalid_request_error", message: "transfer encodings are not served"))
    }
    if headers["expect"] != nil {
      return .refuse(.error(417, type: "invalid_request_error", message: "Expect is not served"))
    }
    let method = String(requestLine[0])
    var length = 0
    if let declared = headers["content-length"] {
      guard let value = Int(declared), value >= 0 else {
        return .refuse(.error(400, type: "invalid_request_error", message: "bad Content-Length"))
      }
      length = value
    } else if method != "GET" {
      return .refuse(.error(411, type: "invalid_request_error", message: "Content-Length required"))
    }
    guard length <= maxBodyBytes else {
      return .refuse(.error(413, type: "invalid_request_error", message: "body too large"))
    }
    let bodyStart = headEnd.upperBound
    guard buffer.endIndex - bodyStart >= length else { return .needMore }
    return .request(
      HelperRequest(
        method: method, path: String(requestLine[1]), headers: headers,
        body: Data(buffer[bodyStart..<(bodyStart + length)])))
  }
}
