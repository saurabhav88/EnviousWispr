import Foundation
import Testing

@testable import EnviousWisprPipeline

#if DEBUG
  /// #979 — the DEBUG-only diagnostic dumper for empty-ASR-despite-evidence
  /// terminals. Pure file IO + WAV encoding; tests run against a temp dir.
  @Suite("ASREmptyCaptureDump")
  struct ASREmptyCaptureDumpTests {

    private func tempDir() throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("asr-empty-dump-tests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    @Test("WAV container: header fields and payload size are correct for 16kHz mono 16-bit")
    func wavHeader() {
      let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0]  // incl. out-of-range
      let data = ASREmptyCaptureDump.wavData(samples: samples)

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

    @Test("dump writes a raw+fed pair and returns the shared prefix")
    func dumpWritesPair() throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      let prefix = ASREmptyCaptureDump.dump(
        raw: [0.1, 0.2, 0.3], fed: [0.1], sessionID: "ABCD-1234-EF",
        now: Date(timeIntervalSince1970: 1_750_000_000), directory: dir)

      let written = try #require(prefix)
      #expect(FileManager.default.fileExists(atPath: written + "-raw.wav"))
      #expect(FileManager.default.fileExists(atPath: written + "-fed.wav"))
      // sid embeds dash-stripped 8-char prefix.
      #expect(written.contains("ABCD1234"))
    }

    @Test("real-path writes are gated off under the test harness")
    func realPathGatedUnderTests() {
      // This suite runs under xctest, so the no-explicit-directory call must
      // refuse — otherwise kernel tests exercising .failed(.asrEmpty) would
      // write synthetic buffers into the dogfood evidence directory.
      let result = ASREmptyCaptureDump.dump(
        raw: [0.1], fed: [0.1], sessionID: "GATE-TEST")
      #expect(result == nil)
    }

    @Test("prune keeps only the newest maxRetainedFiles WAVs by name order")
    func pruneRetention() throws {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let fm = FileManager.default
      let total = ASREmptyCaptureDump.maxRetainedFiles + 6
      for i in 0..<total {
        let name = String(format: "20260601T%06d-aaaa-raw.wav", i)
        fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([1]))
      }

      ASREmptyCaptureDump.prune(directory: dir)

      let remaining = try fm.contentsOfDirectory(atPath: dir.path).sorted()
      #expect(remaining.count == ASREmptyCaptureDump.maxRetainedFiles)
      // The oldest 6 (lowest-sorting names) are the ones deleted.
      #expect(remaining.first == String(format: "20260601T%06d-aaaa-raw.wav", 6))
    }
  }
#endif
