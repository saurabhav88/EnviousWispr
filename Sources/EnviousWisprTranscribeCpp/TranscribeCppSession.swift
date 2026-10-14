import CTranscribe
import Foundation
import os

/// #3735: the native boundary to transcribe.cpp (our fork `saurabhav88/transcribe.cpp`,
/// release `ew-3735-v0.4.0.3`). Mechanism only: no app policy lives in this module.
///
/// One `TranscribeCppSession` owns one native session, which owns its model
/// (`transcribe_open`). transcribe.cpp 0.x session calls are single-thread-at-a-time and
/// allow one `transcribe_run` in flight per model (`transcribe.h` threading notes), so
/// callers must serialize every call on a session. `requestAbort()` is the one method
/// that may be called from another thread while a run is in flight.
public final class TranscribeCppSession: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let abortFlag = TranscribeCppAbortFlag()
  /// The model file this session loaded, for identity checks by callers.
  public let modelPath: String

  /// Loads the GGUF at `modelPath` on Metal and opens a session that owns the model.
  public init(modelPath: String) throws {
    self.modelPath = modelPath
    var loadParams = transcribe_model_load_params()
    transcribe_model_load_params_init(&loadParams)
    loadParams.backend = TRANSCRIBE_BACKEND_METAL
    var session: OpaquePointer?
    let status = modelPath.withCString { path in
      transcribe_open(path, &loadParams, nil, &session)
    }
    guard status == TRANSCRIBE_OK, let session else {
      throw TranscribeCppError(status: status)
    }
    handle = session
    // Abort is polled by the native run loop on the running thread; the flag is
    // lock-protected so `requestAbort()` may be called from any thread.
    transcribe_set_abort_callback(
      session,
      { userData in
        guard let userData else { return false }
        return Unmanaged<TranscribeCppAbortFlag>.fromOpaque(userData)
          .takeUnretainedValue().isRequested
      },
      Unmanaged.passUnretained(abortFlag).toOpaque())
  }

  deinit {
    close()
  }

  /// Frees the native session and its model. Callers must ensure no call is in flight.
  public func close() {
    guard let session = handle else { return }
    handle = nil
    transcribe_session_free(session)
  }

  /// Asks an in-flight run to stop at its next poll point. Safe from any thread.
  public func requestAbort() {
    abortFlag.set(true)
  }

  /// Clears a previous abort request before the next run.
  public func clearAbort() {
    abortFlag.set(false)
  }

  /// Language identification with a confidence (fork API `transcribe_whisper_detect_language`):
  /// the first 30 s window only (trimmed natively before preprocessing), log-softmax of the
  /// winner over the language tokens.
  public func detectLanguage(samples: [Float]) throws -> TranscribeCppLanguageObservation {
    let session = try liveHandle()
    guard !samples.isEmpty else { throw TranscribeCppError(status: TRANSCRIBE_ERR_INVALID_ARG) }
    var code = [CChar](repeating: 0, count: 16)
    var logProb: Float = 0
    // The native API trims to one model window itself, before preprocessing.
    let count = Int64(samples.count)
    let status = samples.withUnsafeBufferPointer { pcm in
      code.withUnsafeMutableBufferPointer { out in
        transcribe_whisper_detect_language(
          session, pcm.baseAddress, count, out.baseAddress, out.count, &logProb)
      }
    }
    guard status == TRANSCRIBE_OK else { throw TranscribeCppError(status: status) }
    let language = String(
      decoding: code.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return TranscribeCppLanguageObservation(code: language, logProb: Double(logProb))
  }

  /// Transcribes 16 kHz mono Float32 audio in one native long-form run.
  /// - Parameters:
  ///   - language: ISO code to force, or nil for the model's own detection.
  ///   - onProgress: optional seek-progress observer (fork API), called on the running
  ///     thread with (advanced frames, total frames); installed only for this run.
  public func run(
    samples: [Float],
    language: String?,
    onProgress: ((Int64, Int64) -> Void)? = nil
  ) throws -> TranscribeCppRunResult {
    let session = try liveHandle()
    guard !samples.isEmpty else { throw TranscribeCppError(status: TRANSCRIBE_ERR_INVALID_ARG) }
    let progressBox = onProgress.map(TranscribeCppProgressBox.init)
    if let progressBox {
      let installed = transcribe_whisper_set_progress_callback(
        session,
        { advanced, total, userData in
          guard let userData else { return }
          Unmanaged<TranscribeCppProgressBox>.fromOpaque(userData)
            .takeUnretainedValue().handler(advanced, total)
        },
        Unmanaged.passUnretained(progressBox).toOpaque())
      guard installed == TRANSCRIBE_OK else { throw TranscribeCppError(status: installed) }
    }
    // The box must outlive the run: cleared here before it is released.
    defer {
      if progressBox != nil {
        _ = transcribe_whisper_set_progress_callback(session, nil, nil)
      }
      withExtendedLifetime(progressBox) {}
    }

    var params = transcribe_run_params()
    transcribe_run_params_init(&params)
    let count = Int32(clamping: samples.count)
    let status: transcribe_status = samples.withUnsafeBufferPointer { pcm in
      if let language {
        return language.withCString { code in
          params.language = code
          return transcribe_run(session, pcm.baseAddress, count, &params)
        }
      }
      params.language = nil
      return transcribe_run(session, pcm.baseAddress, count, &params)
    }
    guard status == TRANSCRIBE_OK else { throw TranscribeCppError(status: status) }
    return copyResult(session)
  }

  // MARK: - Private

  private func liveHandle() throws -> OpaquePointer {
    guard let handle else { throw TranscribeCppError(status: TRANSCRIBE_ERR_INVALID_ARG) }
    return handle
  }

  /// Copies every borrowed native string before returning: they are valid only until
  /// the next run or `transcribe_session_free` on this session.
  private func copyResult(_ session: OpaquePointer) -> TranscribeCppRunResult {
    let text = Self.repairedString(transcribe_full_text(session))
    let detected = Self.repairedString(transcribe_detected_language(session))
    var segments: [TranscribeCppSegment] = []
    let segmentCount = transcribe_n_segments(session)
    if segmentCount > 0 {
      segments.reserveCapacity(Int(segmentCount))
      for index in 0..<segmentCount {
        var segment = transcribe_segment()
        transcribe_segment_init(&segment)
        guard transcribe_get_segment(session, index, &segment) == TRANSCRIBE_OK else { continue }
        segments.append(
          TranscribeCppSegment(
            startMs: segment.t0_ms, endMs: segment.t1_ms,
            text: Self.repairedString(segment.text)))
      }
    }
    return TranscribeCppRunResult(
      text: text, detectedLanguage: detected.isEmpty ? nil : detected, segments: segments)
  }

  /// transcribe.cpp can emit invalid UTF-8 mid-string (#3705: 58 of 1,836 rows, mostly
  /// bn/hi), so decode with replacement and drop the replacement characters.
  static func repairedString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    let length = strlen(pointer)
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    let decoded = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    return decoded.replacingOccurrences(of: "\u{FFFD}", with: "")
  }
}

/// Native status mapped into Swift. `isAborted` distinguishes a requested stop.
public struct TranscribeCppError: Error, Equatable, Sendable, CustomStringConvertible {
  public let status: Int32
  public let message: String

  init(status: transcribe_status) {
    self.status = Int32(status.rawValue)
    self.message = String(cString: transcribe_status_string(Int32(status.rawValue)))
  }

  public var isAborted: Bool { status == Int32(TRANSCRIBE_ERR_ABORTED.rawValue) }
  public var description: String { "transcribe.cpp status \(status): \(message)" }
}

/// One timed segment from the model's timestamp tokens, in run-relative milliseconds.
public struct TranscribeCppSegment: Sendable, Equatable {
  public let startMs: Int64
  public let endMs: Int64
  public let text: String
}

public struct TranscribeCppRunResult: Sendable, Equatable {
  public let text: String
  /// Native auto-detected language; nil whenever a language was forced.
  public let detectedLanguage: String?
  public let segments: [TranscribeCppSegment]
}

public struct TranscribeCppLanguageObservation: Sendable, Equatable {
  public let code: String
  /// Log-probability over the language tokens; `exp(logProb)` is in 0...1.
  public let logProb: Double
}

final class TranscribeCppAbortFlag: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: false)
  var isRequested: Bool { lock.withLock { $0 } }
  func set(_ value: Bool) { lock.withLock { $0 = value } }
}

final class TranscribeCppProgressBox: @unchecked Sendable {
  let handler: (Int64, Int64) -> Void
  init(_ handler: @escaping (Int64, Int64) -> Void) { self.handler = handler }
}
