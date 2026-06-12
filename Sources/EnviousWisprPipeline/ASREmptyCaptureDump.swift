import Foundation

#if DEBUG
  /// #979 diagnostic instrument — DEBUG builds only (founder dogfood machine).
  ///
  /// Production telemetry shows the asr_empty_result class (ENVIOUSWISPR-14:
  /// VAD found a single short speech segment, the engine returned empty) but
  /// metadata cannot answer THE fork: was the audio a real short word the
  /// pipeline lost, or a non-speech transient (cough/door/keyboard) that fooled
  /// the voice detector? This dumper saves the audio pair for exactly that
  /// terminal so the next local occurrence is fully diagnosable offline
  /// (listen + re-decode via fluidaudiocli, per docs/vad-investigation-2026-06-03.md).
  ///
  /// Privacy: never compiled into release builds; audio never leaves the local
  /// disk; the directory rides the same `~/Library/Logs/EnviousWispr/` home as
  /// the (also DEBUG-gated) app.log.
  enum ASREmptyCaptureDump {
    static let directoryURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/EnviousWispr/asr-empty-captures", isDirectory: true)

    /// Keep the newest N files (raw+fed pairs count as 2). ~1 occurrence/day
    /// locally, so 40 files = ~3 weeks of evidence with bounded disk use.
    static let maxRetainedFiles = 40

    /// Write the raw capture and the engine-fed (conditioned) buffers as
    /// 16 kHz mono WAVs. Returns the pair's shared path prefix for logging,
    /// or nil on any failure (diagnostic limb: never throws past itself).
    @discardableResult
    static func dump(
      raw: [Float],
      fed: [Float],
      sessionID: String,
      now: Date = Date(),
      directory: URL? = nil
    ) -> String? {
      // Kernel tests exercise the real .failed(.asrEmpty) path, so without
      // this gate every full-suite run writes synthetic buffers into the
      // dogfood evidence directory and contaminates the corpus this
      // instrument exists to collect (caught live: first "organic" dump was
      // the 15:17 test run). Unit tests pass `directory:` explicitly and are
      // unaffected.
      if directory == nil,
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
          || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
      {
        return nil
      }
      let dir = directory ?? directoryURL
      let fm = FileManager.default
      do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: now)
        let sid8 = String(sessionID.replacingOccurrences(of: "-", with: "").prefix(8))
        let prefix = "\(stamp)-\(sid8)"
        try wavData(samples: raw).write(to: dir.appendingPathComponent("\(prefix)-raw.wav"))
        try wavData(samples: fed).write(to: dir.appendingPathComponent("\(prefix)-fed.wav"))
        prune(directory: dir)
        return dir.appendingPathComponent(prefix).path
      } catch {
        return nil
      }
    }

    /// 16 kHz mono 16-bit PCM WAV container around Float32 samples in [-1, 1].
    static func wavData(samples: [Float], sampleRate: Int = 16000) -> Data {
      var pcm = Data(capacity: samples.count * 2)
      for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        var i = Int16(clamped * Float(Int16.max))
        withUnsafeBytes(of: &i) { pcm.append(contentsOf: $0) }
      }
      let byteRate = sampleRate * 2
      var header = Data()
      header.append(contentsOf: Array("RIFF".utf8))
      header.append(uint32: UInt32(36 + pcm.count))
      header.append(contentsOf: Array("WAVE".utf8))
      header.append(contentsOf: Array("fmt ".utf8))
      header.append(uint32: 16)  // PCM fmt chunk size
      header.append(uint16: 1)  // PCM
      header.append(uint16: 1)  // mono
      header.append(uint32: UInt32(sampleRate))
      header.append(uint32: UInt32(byteRate))
      header.append(uint16: 2)  // block align
      header.append(uint16: 16)  // bits per sample
      header.append(contentsOf: Array("data".utf8))
      header.append(uint32: UInt32(pcm.count))
      return header + pcm
    }

    /// Delete the oldest files beyond `maxRetainedFiles` (by name — the
    /// timestamp prefix sorts lexicographically).
    static func prune(directory: URL) {
      let fm = FileManager.default
      guard
        let names = try? fm.contentsOfDirectory(atPath: directory.path)
          .filter({ $0.hasSuffix(".wav") })
          .sorted()
      else { return }
      guard names.count > maxRetainedFiles else { return }
      for name in names.prefix(names.count - maxRetainedFiles) {
        try? fm.removeItem(at: directory.appendingPathComponent(name))
      }
    }

    private static let timestampFormatter: DateFormatter = {
      let f = DateFormatter()
      f.dateFormat = "yyyyMMdd'T'HHmmss"
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone.current
      return f
    }()
  }

  extension Data {
    fileprivate mutating func append(uint32 v: UInt32) {
      var le = v.littleEndian
      Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    fileprivate mutating func append(uint16 v: UInt16) {
      var le = v.littleEndian
      Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
  }
#endif
