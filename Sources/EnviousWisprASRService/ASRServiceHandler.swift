@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation

/// XPC service handler for ASR transcription.
///
/// Owns ParakeetBackend. All inference runs in this XPC service process — model
/// memory is isolated from the main app.
///
/// Parakeet-only, structurally, since #1386 PR-2: WhisperKit loads in-process
/// behind its relocation gate and never crosses this boundary.
final class ASRServiceHandler: NSObject, ASRServiceProtocol, @unchecked Sendable {
  weak var connection: NSXPCConnection?  // periphery:ignore - XPC connection lifecycle; set by delegate, prevents premature release

  /// The active ASR backend — only one loaded at a time.
  private var parakeetBackend: ParakeetBackend?
  private var activeBackendType: String?  // periphery:ignore - tracks loaded backend for diagnostics and unload routing

  /// Streaming state flag — only Parakeet supports streaming.
  private var isStreamingActive = false

  /// Reusable audio format for buffer reconstruction in feedAudioBuffer.
  private let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
  )!

  // MARK: - Diagnostics

  func ping(reply: @escaping (String) -> Void) {
    let fluidAudioPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
    let fluidAccess = FileManager.default.isReadableFile(atPath: fluidAudioPath.path)
    // #1386 PR-2 dropped the WhisperKit probe: it reached into ~/Documents from
    // the helper — a TCC toucher reporting on a folder the app no longer uses.
    reply("pong — modelAccess: FluidAudio=\(fluidAccess)")
  }

  // MARK: - Model Lifecycle

  func loadModel(backendType: String, cacheOnly: Bool, reply: @escaping (NSError?) -> Void) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      do {
        // Unload previous backend before loading new one
        self.parakeetBackend = nil

        switch backendType {
        case "parakeet":
          let backend = ParakeetBackend()

          // Decoupled push model for progress reporting:
          // The URLSession delegate callback (from FluidAudio) must NEVER call XPC directly —
          // Mach port queue exhaustion blocks the delegate thread, stalling the download.
          // Instead: callback writes to a thread-safe snapshot, a DispatchSource timer
          // samples it at 4 Hz and sends XPC messages from its own thread.
          // Progress via shared file — bypasses XPC entirely.
          // XPC serializes replies, so getDownloadProgress replies are blocked
          // behind the pending loadModel reply. Writing to a file that the app
          // reads on a timer is the only reliable cross-process progress path.
          let progressFile = ProgressFile.shared
          progressFile.clear()

          // #1348 Phase 2: cacheOnly = delivery-managed — the host admitted a
          // verified cache before this call; FluidAudio's offline switch is
          // armed inside prepare so this process can never download. The
          // progress callback still feeds the shared file for the COMPILE/
          // LOAD phase (the download phase is host-fed under delivery mode).
          try await backend.prepare(cacheOnly: cacheOnly) { fraction, phase, detail in
            // Hot path — runs on URLSession delegate thread. File write is fast.
            progressFile.write(fraction: fraction, phase: phase, detail: detail)
          }

          progressFile.write(fraction: 1.0, phase: "", detail: "")

          self.parakeetBackend = backend
        // #1386 PR-2 deleted the "whisperKit" branch. Its old note claimed the
        // branch was unreachable; that was wrong — crash recovery and Diagnostics
        // reached it through the default `ASRManagerProxy`, and it built a
        // WhisperKit model inside THIS process, where the in-process relocation
        // gate cannot reach. WhisperKit now loads only in-process behind that
        // gate, so a whisperKit request here is a caller on a retired route and
        // falls through to the unknown-backend refusal below.
        default:
          safeReply(
            NSError(
              domain: "ASRService", code: -1,
              userInfo: [NSLocalizedDescriptionKey: "Unknown backend: \(backendType)"]))
          return
        }
        self.activeBackendType = backendType
        safeReply(nil)
      } catch {
        // XPC error sanitization boundary.
        safeReply(XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  func unloadModel(reply: @escaping () -> Void) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      self.parakeetBackend = nil
      self.activeBackendType = nil
      safeReply()
    }
  }

  func getModelState(reply: @escaping (Bool, Bool) -> Void) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      let isLoaded = self.parakeetBackend != nil
      safeReply(isLoaded, self.isStreamingActive)
    }
  }

  // MARK: - Batch Transcription

  func transcribeSamples(
    _ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool,
    speechSegmentsData: Data?,
    reply: @escaping (Data?, NSError?) -> Void
  ) {
    nonisolated(unsafe) let safeReply = reply

    // Validate input. Stays exactly here — synchronous, before the Task —
    // only its payload normalizes (#1525 PR I-B, Codex r2: moving this into
    // the `do` block would delay the reply onto the main actor, a real
    // scheduling change this PR must not make).
    guard data.count == sampleCount * MemoryLayout<Float>.size else {
      let error = XPCASRTransportError.invalidSamplePayload(
        "Data size mismatch: expected \(sampleCount * MemoryLayout<Float>.size), got \(data.count)"
      )
      // XPC error sanitization boundary.
      safeReply(nil, XPCErrorSanitizer.sanitizeForXPC(error))
      return
    }

    Task { @MainActor in
      do {
        // Convert Data → [Float]
        let samples = data.withUnsafeBytes { raw -> [Float] in
          guard raw.count > 0 else { return [] }
          return Array(raw.bindMemory(to: Float.self))
        }

        let speechSegments: [SpeechSegment]
        if let speechSegmentsData {
          do {
            speechSegments = try JSONDecoder().decode(
              [SpeechSegment].self, from: speechSegmentsData)
          } catch {
            // #1525 PR I-B: a request-decoding failure, not a transcription
            // failure — belongs on the transport authority.
            throw XPCASRTransportError.requestDecodingFailed(error.localizedDescription)
          }
        } else {
          speechSegments = []
        }
        let options = TranscriptionOptions(
          language: language.isEmpty ? nil : language,
          enableTimestamps: enableTimestamps,
          speechSegments: speechSegments
        )

        // Route to the active backend. Already inside the `do` block, so
        // converting this to a throw is a legitimate in-place normalization
        // — no scheduling change (#1525 PR I-B).
        guard let parakeet = self.parakeetBackend else {
          throw XPCASRTransportError.modelNotLoaded
        }
        let result = try await parakeet.transcribe(audioSamples: samples, options: options)

        // Encode ASRResult → Data via PropertyListEncoder
        let encoded: Data
        do {
          encoded = try PropertyListEncoder().encode(result)
        } catch {
          // #1525 PR I-B: a response-encoding failure, not a transcription
          // failure — belongs on the transport authority.
          throw XPCASRTransportError.responseEncodingFailed(error.localizedDescription)
        }
        safeReply(encoded, nil)
      } catch {
        // XPC error sanitization boundary.
        safeReply(nil, XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  // MARK: - Streaming

  func startStreaming(
    operationID: String,
    language: String,
    enableTimestamps: Bool,
    reply: @escaping (NSError?) -> Void
  ) {
    let signal = XPCOperationSignalFile.asr.makeEmitter(operationID: operationID)
    signal.emit(stage: "asr.start_streaming.received")
    guard let parakeet = parakeetBackend else {
      signal.emit(stage: "asr.start_streaming.failed", detail: "no_parakeet_model")
      // #1525 PR I-B (Codex cloud review): same "no model loaded" condition
      // transcribeSamples already normalizes — reuse its pinned identity
      // rather than a raw NSError.
      reply(XPCErrorSanitizer.sanitizeForXPC(XPCASRTransportError.modelNotLoaded))
      return
    }

    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      signal.emit(stage: "asr.start_streaming.main_actor")
      do {
        var options = TranscriptionOptions()
        options.language = language.isEmpty ? nil : language
        options.enableTimestamps = enableTimestamps
        signal.emit(stage: "asr.start_streaming.backend_entered")
        try await parakeet.startStreaming(options: options)
        signal.emit(stage: "asr.start_streaming.backend_completed")
        self.isStreamingActive = true
        safeReply(nil)
      } catch {
        signal.emit(stage: "asr.start_streaming.failed", detail: error.localizedDescription)
        // XPC error sanitization boundary.
        safeReply(XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  func feedAudioBuffer(_ data: Data, frameCount: Int) {
    guard isStreamingActive, let parakeet = parakeetBackend else { return }
    guard data.count == frameCount * MemoryLayout<Float>.size else { return }

    // Reconstruct AVAudioPCMBuffer from raw Float32 data
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else { return }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    data.withUnsafeBytes { raw in
      guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
      buffer.floatChannelData![0].update(from: src, count: frameCount)
    }

    nonisolated(unsafe) let unsafeBuffer = buffer
    Task { try? await parakeet.feedAudio(unsafeBuffer) }
  }

  func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void) {
    guard isStreamingActive, let parakeet = parakeetBackend else {
      // #1525 PR I-B (Codex cloud review): reuse the same pinned "no model
      // loaded" identity as transcribeSamples/startStreaming — a caller
      // reaching this guard has no active session to finalize either way.
      reply(nil, XPCErrorSanitizer.sanitizeForXPC(XPCASRTransportError.modelNotLoaded))
      return
    }

    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      do {
        let result = try await parakeet.finalizeStreaming()
        self.isStreamingActive = false
        let encoded: Data
        do {
          encoded = try PropertyListEncoder().encode(result)
        } catch {
          // #1525 PR I-B (Codex cloud review): a response-encoding failure,
          // not a transcription failure — belongs on the transport authority,
          // same as transcribeSamples's encode site.
          throw XPCASRTransportError.responseEncodingFailed(error.localizedDescription)
        }
        safeReply(encoded, nil)
      } catch {
        self.isStreamingActive = false
        // XPC error sanitization boundary.
        safeReply(nil, XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  func cancelStreaming() {
    guard isStreamingActive, let parakeet = parakeetBackend else { return }
    isStreamingActive = false
    Task { await parakeet.cancelStreaming() }
  }

  // MARK: - Capability

  func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void) {
    reply(backendType == "parakeet")
  }
}
