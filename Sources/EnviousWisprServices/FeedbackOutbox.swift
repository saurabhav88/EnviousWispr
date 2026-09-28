import EnviousWisprCore
import EnviousWisprObservabilityCore
import Foundation

/// The app-owned outbox for bug reports (#3269). A report is saved here at Send and removed only
/// after Sentry accepts it AND the removal is on disk, so it survives restarts, network loss and
/// either privacy switch changing (founder, 2026-09-28: "a feedback submitted is feedback
/// submitted and sits in an outbox waiting for internet"). Delivery is retry-until-accepted, so an
/// interrupted acceptance can send one report twice (same event id); it is never exactly-once.
///
/// One actor owns every change; one send is in flight at a time, oldest pending report first.
/// Every change re-reads the file under the store's cross-process lock and writes it atomically,
/// so a second app process cannot overwrite a report. A file that exists but cannot be read, or
/// does not decode, blocks every change rather than being replaced.
actor FeedbackOutbox {
  static let maxRecords = 50
  static let maxEncodedBytes = 20_000_000
  static let fileName = "outbox.json"

  enum EnqueueResult: Equatable, Sendable {
    /// On disk. `offline` is the path state at Send, for the confirmation line.
    case saved(offline: Bool)
    /// 50 reports or 20 MB are already waiting; nothing was saved.
    case full
    /// The outbox could not be read or written; nothing was saved.
    case unavailable
  }

  struct Document: Codable, Equatable {
    var schemaVersion = 1
    var records: [FeedbackRecord] = []
    /// A rate limit that holds every feedback send until this time, across launches.
    var notBefore: Date?

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case records
      case notBefore = "not_before"
    }
  }

  private let fileURL: URL
  private let directory: URL
  private let sender: FeedbackSender?
  private let path: any FeedbackPathMonitoring
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let writeData: @Sendable (Data, URL) throws -> Void
  private let readData: @Sendable (URL) throws -> Data

  /// The latest requested pass. Each request chains a new pass after it, so a report saved
  /// during a pass is never skipped and only one send is ever in flight.
  private var drainTask: Task<Void, Never>?
  /// Set by a configuration failure (bad DSN, 401/403/404); cleared only by a new launch.
  private(set) var isPaused: Bool
  private var wakeTask: Task<Void, Never>?
  /// A retry deadline kept in memory when the deadline itself could not be written.
  private var memoryNotBefore: [UUID: Date] = [:]

  /// - Parameter sender: nil when the DSN is missing or malformed; reports are kept, not sent.
  init(
    directory: URL,
    sender: FeedbackSender?,
    path: any FeedbackPathMonitoring,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
      try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
    },
    readData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
  ) {
    self.directory = directory
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.sender = sender
    self.path = path
    self.now = now
    self.sleep = sleep
    self.writeData = writeData
    self.readData = readData
    self.isPaused = sender == nil
  }

  // MARK: - Production

  static var productionDirectory: URL {
    StorageRoot.live.dataDirectory
      .appendingPathComponent("Feedback", isDirectory: true)
      .appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "com.enviouswispr.app", isDirectory: true)
  }

  /// The shared outbox, built at first use from the app's DSN and a real network path monitor.
  static let shared: FeedbackOutbox = {
    let dsn = KeyResolver.resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn")
      .flatMap(FeedbackDSN.init)
    let sender = dsn.map { FeedbackSender(dsn: $0, http: FeedbackHTTP.live, now: { Date() }) }
    return FeedbackOutbox(
      directory: productionDirectory, sender: sender, path: FeedbackPathMonitor())
  }()

  // MARK: - Lifecycle

  /// Launch: watch the network and try to send whatever is waiting.
  func start() {
    path.start { [weak self] satisfied in
      guard satisfied, let self else { return }
      Task { await self.drain() }
    }
    Task { await drain() }
  }

  /// Shutdown: stop the scheduled wake and the network watcher. Nothing on disk changes.
  func stop() {
    wakeTask?.cancel()
    wakeTask = nil
    path.cancel()
  }

  // MARK: - Enqueue

  func enqueue(_ record: FeedbackRecord) async -> EnqueueResult {
    let offline = !path.isSatisfied
    let result: EnqueueResult =
      mutate { document in
        guard document.records.count < Self.maxRecords else { return .full }
        var next = document
        next.records.append(record)
        guard let encoded = try? Self.encode(next), encoded.count <= Self.maxEncodedBytes else {
          return .full
        }
        document = next
        return .saved(offline: offline)
      } ?? .unavailable
    if case .saved = result { Task { await drain() } }
    return result
  }

  /// Whether any report was refused by Sentry and is kept here unsent, for the form's notice.
  func hasRejectedReports() -> Bool {
    (try? load())?.records.contains { $0.state == .rejected } ?? false
  }

  // MARK: - Drain

  /// Sends eligible reports, oldest first, one at a time, until none is eligible; then schedules
  /// one wake for the earliest deadline. Never bypasses a persisted deadline.
  func drain() async {
    // Chain, never poll: awaiting an already-finished task does not suspend, so a waiter that
    // looped on a finished pass would hold the actor and the pass's owner could never clear it.
    let previous = drainTask
    let task = Task {
      await previous?.value
      await self.runPass()
    }
    drainTask = task
    await task.value
  }

  private func runPass() async {
    guard !isPaused, let sender, path.isSatisfied else { return }
    while true {
      guard let document = try? load() else { return }
      let current = now()
      if let notBefore = document.notBefore, notBefore > current {
        scheduleWake(at: notBefore)
        return
      }
      guard let record = document.records.first(where: { isEligible($0, at: current) }) else {
        if let next = document.records.compactMap(deadline(of:)).min() { scheduleWake(at: next) }
        return
      }
      let result = await sender.send(record)
      switch result {
      case .accepted:
        let removed: Bool =
          mutate { doc in
            doc.records.removeAll { $0.id == record.id }
            return true
          } ?? false
        if removed {
          memoryNotBefore[record.id] = nil
        } else {
          memoryNotBefore[record.id] = now().addingTimeInterval(Self.backoff(record.attempts + 1))
        }
      case .retry(let notBefore):
        let backoff = now().addingTimeInterval(Self.backoff(record.attempts + 1))
        let deadline = max(backoff, notBefore ?? backoff)
        let saved: Bool =
          mutate { doc in
            if let notBefore { doc.notBefore = max(doc.notBefore ?? notBefore, notBefore) }
            guard let index = doc.records.firstIndex(where: { $0.id == record.id }) else {
              return true
            }
            doc.records[index].attempts += 1
            doc.records[index].nextAttemptAt = deadline
            return true
          } ?? false
        if !saved { memoryNotBefore[record.id] = deadline }
        // A failed attempt means the network or Sentry is not taking reports right now.
        scheduleWake(at: deadline)
        return
      case .rejected(let status):
        let saved: Bool =
          mutate { doc in
            guard let index = doc.records.firstIndex(where: { $0.id == record.id }) else {
              return true
            }
            doc.records[index].state = .rejected
            doc.records[index].rejectedStatus = status
            return true
          } ?? false
        if !saved { memoryNotBefore[record.id] = .distantFuture }
      case .configurationFailure:
        isPaused = true
        return
      }
    }
  }

  private func isEligible(_ record: FeedbackRecord, at time: Date) -> Bool {
    guard record.state == .pending else { return false }
    guard let deadline = deadline(of: record) else { return true }
    return deadline <= time
  }

  private func deadline(of record: FeedbackRecord) -> Date? {
    guard record.state == .pending else { return nil }
    return [record.nextAttemptAt, memoryNotBefore[record.id]].compactMap { $0 }.max()
  }

  private func scheduleWake(at date: Date) {
    wakeTask?.cancel()
    let delay = max(date.timeIntervalSince(now()), 1)
    let sleep = self.sleep
    wakeTask = Task { [weak self] in
      guard (try? await sleep(delay)) != nil, !Task.isCancelled else { return }
      await self?.drain()
    }
  }

  /// One minute, doubling per attempt, capped at six hours.
  static func backoff(_ attempt: Int) -> TimeInterval {
    min(60 * pow(2, Double(max(attempt - 1, 0))), 6 * 60 * 60)
  }

  // MARK: - Storage

  /// Reads the file under the cross-process lock, applies `change`, writes it back when changed.
  /// Nil when the file cannot be read, decoded or written, or the lock cannot be taken.
  private func mutate<T>(_ change: (inout Document) -> T) -> T? {
    DurableJSONFile.prepareDirectory(at: directory)
    DurableJSONFile.tightenFileIfPresent(at: fileURL)
    return try? DurableJSONFile.withExclusiveLock(on: fileURL, blocking: true) {
      var document = try load()
      let before = document
      let value = change(&document)
      if document != before { try writeData(try Self.encode(document), fileURL) }
      return value
    }
  }

  /// Missing file = empty outbox. Throws for a file that exists but cannot be read or decoded,
  /// so no caller can mistake it for empty and overwrite the reports in it.
  private func load() throws -> Document {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document() }
    let data = try readData(fileURL)
    let decoder = JSONDecoder()
    let document = try decoder.decode(Document.self, from: data)
    guard document.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
    return document
  }

  static func encode(_ document: Document) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
  }
}

/// The production HTTP call: an ephemeral session that refuses redirects, so a report never
/// follows a redirect to another host.
enum FeedbackHTTP {
  static let live: FeedbackSender.HTTP = { request in
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String, let value = value as? String { headers[key] = value }
    }
    return (http.statusCode, headers)
  }

  private static let session = URLSession(
    configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

  private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
      nil
    }
  }
}
