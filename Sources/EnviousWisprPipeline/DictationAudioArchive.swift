import Foundation

#if DEBUG
  /// #1230 diagnostic instrument — DEBUG builds only, opt-in via
  /// `EW_KEEP_DICTATION_AUDIO=1`. Generalizes the former empty-only
  /// `ASREmptyCaptureDump` (#979/#1040) into a per-dictation audio library.
  ///
  /// End-of-dictation clipping (#1099/#1237) is intermittent and timing-
  /// dependent — re-reading the exact words that dropped does NOT reproduce it
  /// (verified live 2026-06-28), so a synthetic script can't summon it. The only
  /// dependable repro is to retain the real audio of real dictations on the
  /// founder's dogfood machine, then replay the one that clipped.
  ///
  /// Every dictation that reaches the post-decode outcome switch with captured
  /// samples is saved as a directory named by its History `Transcript.id`:
  ///
  ///   dictation-audio/<transcript-id>/
  ///       raw.wav      captured buffer ("did the mic get my last words?")
  ///       fed.wav      engine-fed/conditioned buffer (the #1237 chunk replay)
  ///       meta.json    metadata ONLY — never any transcript text
  ///
  /// `meta.json` carries NO transcript text (telemetry-privacy-boundary); text
  /// lives only in the existing History store. So a clipped/failed dictation
  /// with no History row stays discoverable via its outcome + time, without
  /// duplicating any dictated words.
  ///
  /// Privacy: never compiled into release; default-off even in DEBUG so a
  /// public-repo cloner never silently records their mic; audio never leaves the
  /// local disk; the archive root is backup-excluded.
  enum DictationAudioArchive {
    /// Archive root. One subdirectory per dictation, named by `Transcript.id`.
    static let directoryURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/EnviousWispr/dictation-audio", isDirectory: true)

    /// Opt-in env var; capture is OFF unless this is exactly "1". Chosen over a
    /// sticky default so capture can never be silently left on.
    static let optInEnvVar = "EW_KEEP_DICTATION_AUDIO"

    /// Max retained dictation DIRECTORIES; oldest pruned first by mtime. 500 ≈
    /// weeks of dogfooding (raw 16 kHz mono 16-bit ≈ 1.9 MB/min). File-count
    /// over byte-count avoids a recursive stat on every prune.
    static let maxRetainedDirectories = 500

    /// The terminal outcome label written to `meta.json`. `CaseIterable` so the
    /// coverage freeze test can lock the set — a new terminal label is a
    /// conscious test change, never a silent gap.
    enum Outcome: String, CaseIterable, Sendable {
      case completed
      /// ASR produced a transcript but finalization failed before saving History
      /// (empty after polish, or superseded mid-finalize) — NOT a real
      /// completion, so it stays distinct from `.completed` in the metadata.
      case finalizationFailed
      case asrEmpty
      case noSpeech
      case cancelled
      case wedged
      case failed
    }

    /// `meta.json` schema — metadata ONLY, never any transcript text.
    struct Meta: Codable, Equatable, Sendable {
      let id: String
      let sid: String
      let createdAt: Date
      let outcome: String
      let classification: String
      let durationMs: Int
      let sampleCount: Int
      let hasFed: Bool
      let backend: String
    }

    /// The single archive entry point — invoked once per dictation from the
    /// kernel's post-decode region (off the hot path, in a detached task, after
    /// delivery). Returns the written directory path for logging, or nil when
    /// gated off / no samples / on any failure (diagnostic limb: never throws
    /// past itself).
    ///
    /// `directory` overrides the archive root for tests; passing it also
    /// bypasses the env + XCTest gates (the same seam the old dumper exposed).
    @discardableResult
    static func archive(
      transcriptID: UUID,
      sid: String,
      raw: [Float],
      fed: [Float],
      outcome: Outcome,
      classification: String,
      backend: String,
      now: Date = Date(),
      directory: URL? = nil,
      maxRetained: Int = DictationAudioArchive.maxRetainedDirectories
    ) async -> String? {
      guard !raw.isEmpty else { return nil }
      // Production/contributor builds: off unless explicitly opted in. Tests
      // pass an explicit `directory:` and bypass both gates.
      if directory == nil {
        guard ProcessInfo.processInfo.environment[optInEnvVar] == "1" else { return nil }
        // Full-suite kernel tests exercise the real terminals; without this the
        // dogfood corpus would be contaminated by synthetic buffers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
          || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        {
          return nil
        }
      }
      let root = directory ?? directoryURL
      let meta = Meta(
        id: transcriptID.uuidString,
        sid: sid,
        createdAt: now,
        outcome: outcome.rawValue,
        classification: classification,
        durationMs: raw.count / 16,  // 16 kHz mono → samples / 16 = ms
        sampleCount: raw.count,
        hasFed: !fed.isEmpty,
        backend: backend)
      return await Writer.shared.write(
        root: root, meta: meta, raw: raw, fed: fed, maxRetained: maxRetained)
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

    /// Serializes write + prune so two overlapping detached archive tasks can't
    /// cross-prune each other's freshly written directory.
    private actor Writer {
      static let shared = Writer()

      func write(root: URL, meta: Meta, raw: [Float], fed: [Float], maxRetained: Int) -> String? {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(meta.id, isDirectory: true)
        do {
          try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          // Owner-only (0700) on both the archive root and the per-dictation dir,
          // matching the transcript/recovery stores' privacy posture — this is
          // retained mic audio. Re-enforced each write so a pre-existing root
          // created with a looser umask is tightened (TranscriptStore.swift:79).
          try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
          try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
          excludeFromBackup(root)
          try writeAtomically(
            DictationAudioArchive.wavData(samples: raw),
            to: dir.appendingPathComponent("raw.wav"), fm: fm)
          if !fed.isEmpty {
            try writeAtomically(
              DictationAudioArchive.wavData(samples: fed),
              to: dir.appendingPathComponent("fed.wav"), fm: fm)
          }
          try writeAtomically(
            Self.encoder.encode(meta),
            to: dir.appendingPathComponent("meta.json"), fm: fm)
          prune(root: root, fm: fm, maxRetained: maxRetained)
          return dir.path
        } catch {
          return nil
        }
      }

      /// temp-write + rename so an app-kill/disk-full mid-write can't leave a
      /// truncated file masquerading as valid; stale `.tmp` is swept on rewrite.
      private func writeAtomically(_ data: Data, to url: URL, fm: FileManager) throws {
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try data.write(to: tmp)
        // Owner-only (0600) before the rename inherits it — retained mic audio,
        // matching TranscriptStore/RecoverySpoolStore (TranscriptStore.swift:50).
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
      }

      /// Keep the newest N directories by modification time; delete the rest.
      /// Deletes swallow file-not-found so a concurrent prune can't throw.
      private func prune(root: URL, fm: FileManager, maxRetained: Int) {
        guard maxRetained > 0 else { return }
        guard
          let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }
        let dirs = entries.filter {
          (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard dirs.count > maxRetained else { return }
        let sorted = dirs.sorted { lhs, rhs in
          let l =
            (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
          let r =
            (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
          return l < r  // oldest first
        }
        for dir in sorted.prefix(dirs.count - maxRetained) {
          try? fm.removeItem(at: dir)
        }
      }

      private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
      }

      private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
      }()
    }
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
