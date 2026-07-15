import Foundation

/// Cross-process operation progress for XPC calls whose reply may wedge.
///
/// XPC replies serialize behind the pending request, so a proxy cannot ask the
/// service for progress while it is already waiting for that request's reply.
/// This file mirrors `ProgressFile`: the service writes state-transition ticks
/// to `/tmp`, and the host polls those ticks outside XPC.
///
/// The host watcher intentionally keeps `LoadProgressWatcher`'s observed-gap
/// gate. A single service tick followed by 800ms of silence is not enough
/// evidence of a wedge: cold AVFoundation/CoreAudio phases and large stop
/// replies can be healthy while quiet. Once at least one inter-signal cadence
/// exists, later silence still fires through the normal floor + 5x-gap rule.
public final class XPCOperationSignalFile: Sendable {
  public static let asr = XPCOperationSignalFile(
    filePath: "/tmp/com.enviouswispr.asr-operation-signal")

  private let filePath: String

  private init(filePath: String) {
    self.filePath = filePath
  }

  public func makeEmitter(operationID: String) -> XPCOperationSignalEmitter {
    XPCOperationSignalEmitter(file: self, operationID: operationID)
  }

  public func write(_ state: XPCOperationSignalState) {
    guard let data = try? PropertyListEncoder().encode(state) else { return }
    do {
      try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    } catch {
      // Signal write failure is non-fatal. The caller's XPC reply/error path
      // remains the primary completion path.
    }
  }

  public func read() -> XPCOperationSignalState? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
    return try? PropertyListDecoder().decode(XPCOperationSignalState.self, from: data)
  }

  public func clear() {
    try? FileManager.default.removeItem(atPath: filePath)
  }
}

public struct XPCOperationSignalState: Codable, Sendable {
  public let operationID: String
  public let sequence: Int
  public let stage: String
  public let detail: String
  public let uptimeNanoseconds: UInt64

  public init(
    operationID: String,
    sequence: Int,
    stage: String,
    detail: String = "",
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    self.operationID = operationID
    self.sequence = sequence
    self.stage = stage
    self.detail = detail
    self.uptimeNanoseconds = uptimeNanoseconds
  }
}

public final class XPCOperationSignalEmitter: @unchecked Sendable {
  private let file: XPCOperationSignalFile
  private let operationID: String
  private let lock = NSLock()
  private var sequence = 0

  fileprivate init(file: XPCOperationSignalFile, operationID: String) {
    self.file = file
    self.operationID = operationID
  }

  public func emit(stage: String, detail: String = "") {
    lock.lock()
    sequence += 1
    let next = sequence
    lock.unlock()

    file.write(
      XPCOperationSignalState(
        operationID: operationID,
        sequence: next,
        stage: stage,
        detail: detail
      )
    )
  }
}

@MainActor
public final class XPCOperationSignalWatcher {
  public let progressWatcher: LoadProgressWatcher

  private let file: XPCOperationSignalFile
  private let operationID: String
  private var pollTimer: Timer?

  public init(file: XPCOperationSignalFile, operationID: String) {
    self.file = file
    self.operationID = operationID
    self.progressWatcher = LoadProgressWatcher()
  }

  public func start() {
    stopPollingOnly()
    file.clear()
    progressWatcher.start()
    let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.poll()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  public func stop() {
    stopPollingOnly()
    progressWatcher.stop()
    file.clear()
  }

  public var snapshot: WatcherSnapshot { progressWatcher.snapshot }

  private func stopPollingOnly() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  private func poll() {
    guard let state = file.read(), state.operationID == operationID else {
      progressWatcher.observeTick(observedMtime: nil, observedPhase: "")
      return
    }

    // Use the service-written monotonic sequence as the signal token. This avoids
    // filesystem mtime precision hiding rapid state transitions.
    let signalToken = Date(timeIntervalSince1970: Double(state.sequence))
    progressWatcher.observeTick(observedMtime: signalToken, observedPhase: state.stage)
  }
}

public struct XPCOperationSignalWedgeError: LocalizedError, Sendable {
  public let service: String
  public let stage: String
  public let observedPhase: String

  public init(service: String, stage: String, observedPhase: String) {
    self.service = service
    self.stage = stage
    self.observedPhase = observedPhase
  }

  public var errorDescription: String? {
    "\(service) XPC operation wedged during \(stage) after signal phase \(observedPhase)"
  }
}

/// #1525 PR G. Pins this struct's exact measured current wire identity
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1). A plain
/// non-switching property matches this one-shape struct and the shipped
/// `ModelLoadWatchdog.WedgeError` pattern. Its stored diagnostic fields
/// (`service`/`stage`/`observedPhase`) do not enter the descriptor. This
/// descriptor has 2 live production issues riding on it (ENVIOUSWISPR-22,
/// ENVIOUSWISPR-1B, 3 users total) from a producer
/// (`AudioCaptureProxy.swift`) deleted the same day this PR was drafted
/// (`f1b2a331`, #1546) — the surviving ASR-side throw site
/// (`ASRManagerProxy.swift:660`) reaches only a breadcrumb today, not a
/// Sentry issue, so this pin preserves dormant history against bridging
/// changes rather than protecting an active path. NEVER change this string
/// once shipped.
extension XPCOperationSignalWedgeError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprCore.XPCOperationSignalWedgeError#1"
  }

  public var sentrySemanticID: String { "xpc.operation_signal_wedge" }
}
