import EnviousWisprCore
import Foundation
import os

// MARK: - Crash-recovery spool writer (#1063 PR0)
//
// Runs in the audio helper process. While recording, it encrypts each chunk of
// captured samples and appends it to a single `.ewrec` file on a DEDICATED
// background queue — never the heart-critical `xpcSendQueue`, never the
// real-time audio thread. It is a strict LIMB: every failure path (open fails,
// disk full, encryption error, queue backed up) drops recovery and leaves
// capture / transcription byte-identical. The authoritative samples it is fed
// (PR1 wiring) are the same buffer `stopCapture` returns, so the spool equals
// exactly what ASR would have received.

/// Low-level append target. Abstracted so tests can inject a failing sink to
/// exercise the fail-open path without a real disk-full.
public protocol RecoverySpoolFileSink {
  func open() throws
  func write(_ data: Data) throws
  /// Durably flush to stable storage (`F_FULLFSYNC` on macOS).
  func sync() throws
  func close()
}

public enum RecoverySpoolWriterError: Error, Equatable {
  case openFailed(Int32)
  case notOpen
  case syncFailed(Int32)
}

/// Encrypts and appends captured audio to a per-session spool file, fail-open.
///
/// Concurrency: all file + frame-counter state is confined to the serial
/// `writeQueue`; only the `healthy`/`pendingBytes` backpressure flags are read
/// off-queue, behind a lock. Hence `@unchecked Sendable` — mutable state is
/// either serial-queue-confined or lock-protected.
public final class RecoverySpoolWriter: @unchecked Sendable {
  private struct BackpressureState {
    var healthy = true
    var pendingBytes = 0
  }

  private let recoverySessionID: String
  private let cipher: RecoverySpoolCipher
  private let settings: RecordingSettingsSnapshot
  private let appVersion: String
  private let createdAt: Date
  private let maxPendingBytes: Int
  private let writeQueue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: BackpressureState())

  // Serial-queue-confined state.
  private nonisolated(unsafe) var sink: any RecoverySpoolFileSink
  private nonisolated(unsafe) var chunkIndex: UInt32 = 0
  private nonisolated(unsafe) var nextStartSample: UInt64 = 0
  private nonisolated(unsafe) var nextNonceCounter: UInt64 = RecoveryConstants
    .firstFrameNonceCounter
  /// Set once the terminal marker is written + the sink closed. Makes `finalize`
  /// idempotent: PR1 can race a clean-stop `finalize(.cleanFinalized)` against a
  /// best-effort XPC-invalidation `finalize(.interrupted)`, and a second marker
  /// write would corrupt the spool's single-terminal-marker contract.
  private nonisolated(unsafe) var finalized = false

  /// - Parameters:
  ///   - maxPendingBytes: backpressure cap. When more than this many bytes of
  ///     un-written audio queue up (the disk can't keep pace), spooling stops
  ///     so the audio path is never throttled. Default ~4 MB (~60 s at 64 KB/s).
  public init(
    recoverySessionID: String,
    cipher: RecoverySpoolCipher,
    settings: RecordingSettingsSnapshot,
    appVersion: String = AppConstants.appVersion,
    createdAt: Date = Date(),
    sink: any RecoverySpoolFileSink,
    maxPendingBytes: Int = 4_000_000,
    queue: DispatchQueue? = nil
  ) {
    self.recoverySessionID = recoverySessionID
    self.cipher = cipher
    self.settings = settings
    self.appVersion = appVersion
    self.createdAt = createdAt
    self.sink = sink
    self.maxPendingBytes = maxPendingBytes
    self.writeQueue =
      queue
      ?? DispatchQueue(label: "com.enviouswispr.recovery.spool-writer", qos: .utility)
  }

  /// Convenience initializer writing to a real file at `spoolURL` (0600).
  public convenience init(
    recoverySessionID: String,
    spoolURL: URL,
    cipher: RecoverySpoolCipher,
    settings: RecordingSettingsSnapshot,
    appVersion: String = AppConstants.appVersion,
    createdAt: Date = Date(),
    maxPendingBytes: Int = 4_000_000,
    queue: DispatchQueue? = nil
  ) {
    self.init(
      recoverySessionID: recoverySessionID,
      cipher: cipher,
      settings: settings,
      appVersion: appVersion,
      createdAt: createdAt,
      sink: FileHandleSpoolSink(url: spoolURL),
      maxPendingBytes: maxPendingBytes,
      queue: queue)
  }

  /// True until the first unrecoverable failure (open/write/encrypt error or
  /// backpressure shed). Once false, the spool stops and the prefix on disk is
  /// final.
  public var isHealthy: Bool { state.withLock { $0.healthy } }

  /// Open the file and write the header (magic + encrypted settings block).
  public func start() {
    writeQueue.async { [self] in
      do {
        let encryptedSettings = try cipher.sealSettings(settings)
        let header = RecoverySpoolHeader(
          cipher: cipher.mode,
          recoverySessionID: recoverySessionID,
          createdAt: createdAt,
          appVersion: appVersion,
          encryptedSettings: encryptedSettings)
        let headerData = try RecoverySpoolFileFormat.encodeHeader(header)
        try sink.open()
        try sink.write(headerData)
      } catch {
        markFailed()
      }
    }
  }

  /// Encrypt and append a chunk of captured samples. Fail-open and
  /// load-shedding: returns immediately, never throws, never blocks the caller.
  public func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    let size = samples.count * MemoryLayout<Float>.size

    let admitted = state.withLock { backpressure -> Bool in
      guard backpressure.healthy else { return false }
      if backpressure.pendingBytes + size > maxPendingBytes {
        // Disk can't keep up: drop recovery, never audio. Spool stops here.
        backpressure.healthy = false
        return false
      }
      backpressure.pendingBytes += size
      return true
    }
    guard admitted else { return }

    writeQueue.async { [self] in
      defer { state.withLock { $0.pendingBytes -= size } }
      guard isHealthy else { return }
      do {
        let frame = try cipher.encodeAudioFrame(
          samples: samples,
          chunkIndex: chunkIndex,
          startSample: nextStartSample,
          nonceCounter: nextNonceCounter)
        try sink.write(frame)
        chunkIndex += 1
        nextStartSample += UInt64(samples.count)
        nextNonceCounter += 1
      } catch {
        markFailed()
      }
    }
  }

  /// Durably flush the bytes written so far (the durable-checkpoint cadence in
  /// PR1 calls this). Best-effort.
  public func flush() {
    writeQueue.async { [self] in
      guard isHealthy else { return }
      try? sink.sync()
    }
  }

  /// Write the terminal marker frame, fsync, and close. After this the spool is
  /// complete and the host may recover (or, on a clean stop, delete) it.
  /// `completion` runs on the write queue after close.
  public func finalize(
    reason: RecoverySpoolTerminationReason, completion: (@Sendable () -> Void)? = nil
  ) {
    writeQueue.async { [self] in
      // Idempotent: a second finalize (clean-stop vs invalidation race) must not
      // write a second terminal marker. The first caller wins; later callers
      // no-op but still get their completion so nothing awaiting it hangs.
      guard !finalized else {
        completion?()
        return
      }
      finalized = true
      if isHealthy {
        do {
          let marker = try cipher.encodeMarkerFrame(
            reason: reason,
            chunkIndex: chunkIndex,
            startSample: nextStartSample,
            nonceCounter: nextNonceCounter)
          try sink.write(marker)
          try sink.sync()
        } catch {
          markFailed()
        }
      }
      sink.close()
      completion?()
    }
  }

  private func markFailed() {
    state.withLock { $0.healthy = false }
  }
}

/// Production sink: appends to a real file opened at 0600, flushed with
/// `F_FULLFSYNC` (the only durable flush on macOS).
public final class FileHandleSpoolSink: RecoverySpoolFileSink {
  private let url: URL
  private var handle: FileHandle?
  private var fileDescriptor: Int32 = -1

  public init(url: URL) {
    self.url = url
  }

  public func open() throws {
    let descriptor = Foundation.open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard descriptor >= 0 else { throw RecoverySpoolWriterError.openFailed(errno) }
    fileDescriptor = descriptor
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  public func write(_ data: Data) throws {
    guard let handle else { throw RecoverySpoolWriterError.notOpen }
    try handle.write(contentsOf: data)
  }

  public func sync() throws {
    guard fileDescriptor >= 0 else { throw RecoverySpoolWriterError.notOpen }
    if fcntl(fileDescriptor, F_FULLFSYNC) == -1 {
      throw RecoverySpoolWriterError.syncFailed(errno)
    }
  }

  public func close() {
    try? handle?.close()
    handle = nil
    fileDescriptor = -1
  }
}
