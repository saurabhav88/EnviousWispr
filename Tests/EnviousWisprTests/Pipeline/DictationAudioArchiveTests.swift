import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

#if DEBUG
  /// #1230 — the DEBUG-only per-dictation audio library that replaces the
  /// empty-only `ASREmptyCaptureDump`. Pure file IO + WAV encoding + a
  /// no-transcript-text metadata sidecar; tests run against a temp dir via the
  /// `directory:` seam (which also bypasses the env + XCTest gates).
  @MainActor
  @Suite("DictationAudioArchive")
  struct DictationAudioArchiveTests {

    private func tempDir() throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictation-audio-tests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    @Test("WAV container: header fields and payload size are correct for 16kHz mono 16-bit")
    func wavHeader() {
      let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0]  // incl. out-of-range
      let data = DictationAudioArchive.wavData(samples: samples)

      #expect(data.count == 44 + samples.count * 2)
      #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
      #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
      #expect(String(data: data[36..<40], encoding: .ascii) == "data")
      let sampleRate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
      #expect(UInt32(littleEndian: sampleRate) == 16000)
      let channels = data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
      #expect(UInt16(littleEndian: channels) == 1)
      let dataLen = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
      #expect(UInt32(littleEndian: dataLen) == UInt32(samples.count * 2))
      // Out-of-range floats clamp instead of wrapping (no Int16 overflow trap).
      let lastTwo = data.suffix(4)
      let positives = lastTwo.prefix(2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
      #expect(Int16(littleEndian: positives) == Int16.max)
    }

    @Test("archive writes a folder named by the transcript id with raw + fed + meta")
    func writesDirectoryPerId() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let id = UUID()

      let path = await DictationAudioArchive.archive(
        transcriptID: id, sid: "session-1", raw: [0.1, 0.2, 0.3], fed: [0.1],
        outcome: .completed, classification: "asr_complete", backend: "parakeet",
        now: Date(timeIntervalSince1970: 1_750_000_000), directory: dir)

      let written = try #require(path)
      // Folder name == transcript id, so History grep → id → this folder.
      #expect(URL(fileURLWithPath: written).lastPathComponent == id.uuidString)
      let folder = dir.appendingPathComponent(id.uuidString)
      #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("raw.wav").path))
      #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fed.wav").path))
      #expect(
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path))
      // Owner-only privacy posture (0700 dir, 0600 files) — retained mic audio.
      let dirPerms =
        try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions]
        as? Int
      #expect(dirPerms == 0o700)
      let rawPerms =
        try FileManager.default.attributesOfItem(
          atPath: folder.appendingPathComponent("raw.wav").path)[.posixPermissions] as? Int
      #expect(rawPerms == 0o600)
    }

    @Test("fed.wav is omitted and hasFed=false when there is no fed buffer")
    func noFedBuffer() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let id = UUID()

      _ = await DictationAudioArchive.archive(
        transcriptID: id, sid: "s", raw: [0.1], fed: [],
        outcome: .noSpeech, classification: "notEvaluated", backend: "whisperKit",
        directory: dir)

      let folder = dir.appendingPathComponent(id.uuidString)
      #expect(
        !FileManager.default.fileExists(atPath: folder.appendingPathComponent("fed.wav").path))
      let meta = try decodeMeta(folder)
      #expect(meta.hasFed == false)
    }

    @Test("meta.json carries metadata only — never transcript text — and all fields populate")
    func metaHasNoText() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let id = UUID()

      _ = await DictationAudioArchive.archive(
        transcriptID: id, sid: "abc", raw: Array(repeating: 0.0, count: 16000), fed: [0.1],
        outcome: .completed, classification: "suspected_asr_drop", backend: "parakeet",
        now: Date(timeIntervalSince1970: 1_750_000_000), directory: dir)

      let folder = dir.appendingPathComponent(id.uuidString)
      let raw = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
      let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
      // Exactly the nine metadata keys — no key that could carry dictated words.
      #expect(
        Set(json.keys) == [
          "id", "sid", "createdAt", "outcome", "classification",
          "durationMs", "sampleCount", "hasFed", "backend",
        ])

      let meta = try decodeMeta(folder)
      #expect(meta.id == id.uuidString)
      #expect(meta.sid == "abc")
      #expect(meta.outcome == "completed")
      #expect(meta.classification == "suspected_asr_drop")
      #expect(meta.sampleCount == 16000)
      #expect(meta.durationMs == 1000)  // 16000 samples / 16 = 1000 ms
      #expect(meta.hasFed == true)
      #expect(meta.backend == "parakeet")
    }

    @Test("classification is always present — 'notEvaluated' on non-transcript outcomes")
    func classificationAlwaysPresent() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let id = UUID()

      _ = await DictationAudioArchive.archive(
        transcriptID: id, sid: "s", raw: [0.1], fed: [0.1],
        outcome: .asrEmpty, classification: "notEvaluated", backend: "parakeet",
        directory: dir)

      let meta = try decodeMeta(dir.appendingPathComponent(id.uuidString))
      #expect(meta.classification == "notEvaluated")
    }

    @Test("no samples → nothing written, returns nil")
    func noSamplesNoop() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      let path = await DictationAudioArchive.archive(
        transcriptID: UUID(), sid: "s", raw: [], fed: [],
        outcome: .completed, classification: "x", backend: "parakeet", directory: dir)

      #expect(path == nil)
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("real-path writes are gated off (opt-in unset) under the test harness")
    func realPathGatedOff() async {
      // No explicit directory + no opt-in env → must refuse, so kernel tests
      // exercising real terminals never contaminate the dogfood library.
      let path = await DictationAudioArchive.archive(
        transcriptID: UUID(), sid: "GATE", raw: [0.1], fed: [0.1],
        outcome: .completed, classification: "x", backend: "parakeet")
      #expect(path == nil)
    }

    @Test("prune keeps the newest N directories by modification time")
    func pruneByTime() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let fm = FileManager.default

      // Three pre-existing dirs with ascending mtimes (oldest → newest).
      let old = ["old-1", "old-2", "old-3"]
      for (i, name) in old.enumerated() {
        let d = dir.appendingPathComponent(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try fm.setAttributes(
          [.modificationDate: Date(timeIntervalSince1970: Double(1000 + i * 100))],
          ofItemAtPath: d.path)
      }

      // A fresh archive (newest mtime) with cap 2 prunes down to the 2 newest.
      let fresh = UUID()
      _ = await DictationAudioArchive.archive(
        transcriptID: fresh, sid: "s", raw: [0.1], fed: [0.1],
        outcome: .completed, classification: "x", backend: "parakeet",
        directory: dir, maxRetained: 2)

      let remaining = Set(try fm.contentsOfDirectory(atPath: dir.path))
      #expect(remaining.contains(fresh.uuidString))  // newest
      #expect(remaining.contains("old-3"))  // next newest
      #expect(!remaining.contains("old-1"))  // oldest pruned
      #expect(!remaining.contains("old-2"))
      #expect(remaining.filter { !$0.hasPrefix(".") }.count == 2)
    }

    @Test("two concurrent archives don't cross-prune each other's fresh folder")
    func concurrentNoCrossPrune() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let ids = (0..<8).map { _ in UUID() }

      await withTaskGroup(of: Void.self) { group in
        for id in ids {
          group.addTask {
            _ = await DictationAudioArchive.archive(
              transcriptID: id, sid: "s", raw: [0.1], fed: [0.1],
              outcome: .completed, classification: "x", backend: "parakeet",
              directory: dir, maxRetained: 100)
          }
        }
      }

      let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
      for id in ids { #expect(remaining.contains(id.uuidString)) }
    }

    @Test("a re-write replaces files via temp+rename, leaving no stale .tmp")
    func atomicRewriteNoStaleTmp() async throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let id = UUID()

      for _ in 0..<2 {
        _ = await DictationAudioArchive.archive(
          transcriptID: id, sid: "s", raw: [0.1, 0.2], fed: [0.1],
          outcome: .completed, classification: "x", backend: "parakeet", directory: dir)
      }

      let entries = try FileManager.default.contentsOfDirectory(
        atPath: dir.appendingPathComponent(id.uuidString).path)
      #expect(Set(entries) == ["raw.wav", "fed.wav", "meta.json"])
      #expect(!entries.contains { $0.hasSuffix(".tmp") })
    }

    private func decodeMeta(_ folder: URL) throws -> DictationAudioArchive.Meta {
      let data = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(DictationAudioArchive.Meta.self, from: data)
    }
  }

  /// Coverage freeze (#1230 §5): the kernel archives at ONE call site after the
  /// `ASREngineOutcome` switch, so every post-decode outcome maps to a terminal
  /// label and pre-decode terminals (which return before the switch) never reach
  /// it. The mapping is compiler-exhaustive over `ASREngineOutcome`; this suite
  /// locks the mapping + the label set so a new outcome is a conscious change.
  @Suite("DictationAudioArchiveCoverage")
  struct DictationAudioArchiveCoverageTests {

    private func result() -> ASRResult {
      ASRResult(text: "x", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
    }

    @Test("every post-decode ASR outcome maps to the expected archive label")
    func outcomeMapping() {
      typealias K = RecordingSessionKernel
      #expect(
        K.dictationArchiveOutcome(for: .transcript(result()), effectiveSpeechEvidence: false)
          == .completed)
      #expect(
        K.dictationArchiveOutcome(
          for: .empty(hadSpeechEvidence: true), effectiveSpeechEvidence: true)
          == .asrEmpty)
      #expect(
        K.dictationArchiveOutcome(
          for: .empty(hadSpeechEvidence: true), effectiveSpeechEvidence: false)
          == .noSpeech)
      #expect(
        K.dictationArchiveOutcome(for: .cancelled, effectiveSpeechEvidence: false) == .cancelled)
      #expect(
        K.dictationArchiveOutcome(for: .failed(.wedged), effectiveSpeechEvidence: false) == .wedged)
      #expect(
        K.dictationArchiveOutcome(for: .failed(.decodeFailed), effectiveSpeechEvidence: false)
          == .failed)
    }

    @Test("fed.wav uses the conditioned batch buffer only for a true batch decode")
    func fedUsesBatchBuffer() {
      typealias K = RecordingSessionKernel
      // Parakeet (decodes conditioned batch): batch session OR batch rescue → yes.
      #expect(
        K.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: true, isStreaming: false, cameFromBatchRescue: false))
      #expect(
        K.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: true, isStreaming: true, cameFromBatchRescue: true))
      // Parakeet streaming WIN (no rescue) → no: engine decoded the raw live feed.
      #expect(
        !K.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: true, isStreaming: true, cameFromBatchRescue: false))
      // WhisperKit never uses the conditioned batch buffer.
      #expect(
        !K.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: false, isStreaming: false, cameFromBatchRescue: false))
      #expect(
        !K.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: false, isStreaming: true, cameFromBatchRescue: false))
    }

    @Test("the archive outcome label set is frozen")
    func labelSetFrozen() {
      #expect(
        Set(DictationAudioArchive.Outcome.allCases.map(\.rawValue))
          == [
            "completed", "finalizationFailed", "asrEmpty", "noSpeech", "cancelled",
            "wedged", "failed",
          ])
    }
  }
#endif
