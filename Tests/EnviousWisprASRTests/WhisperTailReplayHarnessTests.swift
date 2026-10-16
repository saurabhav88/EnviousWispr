import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3801 measurement harness: replays archived dictations through the real transcribe.cpp
/// session and model, once per input-shaping arm, and writes one JSON line per decode.
/// Runs only when `TEST_RUNNER_EW_TAIL_MANIFEST` names a manifest; otherwise it is disabled.
///
/// Manifest: JSON array of `{"id", "path", "language"}`; `path` is 16 kHz mono 16-bit PCM WAV.
/// Optional: `TEST_RUNNER_EW_TAIL_ARMS` (comma list), `TEST_RUNNER_EW_TAIL_REPS` (default 3),
/// `TEST_RUNNER_EW_TAIL_MODEL` (default: the app's installed turbo Q8_0 GGUF),
/// `TEST_RUNNER_EW_TAIL_OUT` (default: beside the manifest).
private enum TailReplayConfig {
  static let env = ProcessInfo.processInfo.environment
  static var manifestPath: String? { env["EW_TAIL_MANIFEST"] }
  static var isConfigured: Bool {
    manifestPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
  }
  static var arms: [String] {
    (env["EW_TAIL_ARMS"] ?? "zeros500,nopad,noise500").split(separator: ",").map(String.init)
  }
  static var reps: Int { Int(env["EW_TAIL_REPS"] ?? "") ?? 3 }
  static var modelPath: String {
    env["EW_TAIL_MODEL"]
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(
        path:
          "Library/Application Support/EnviousWispr/Models/whisper-gguf/whisper-large-v3-turbo-Q8_0.gguf"
      )
      .path
  }
  /// #3801 C3: a saved `filtered`-arm JSONL whose native results are re-filtered without decoding.
  static var refilterPath: String? { env["EW_TAIL_REFILTER"] }
  static var isRefilterConfigured: Bool {
    isConfigured && (refilterPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
  }
  static var outPath: String { env["EW_TAIL_OUT"] ?? (manifestPath ?? "/tmp/x") + ".results.jsonl" }
}

private struct TailReplayItem: Decodable {
  let id: String
  let path: String
  let language: String?
}

/// Reads a canonical 44-byte-header PCM16 mono WAV (the archive's `fed.wav` format) to floats.
private func readPCM16Mono(_ path: String) throws -> [Float] {
  let data = try Data(contentsOf: URL(filePath: path))
  // The #3705/#3546 evaluation corpus stores raw little-endian Float32 at 16 kHz.
  if path.hasSuffix(".f32") {
    return data.withUnsafeBytes { raw in
      (0..<(raw.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
  }
  // Walk chunks to find "data"; the archive writes a plain RIFF header.
  var offset = 12
  while offset + 8 <= data.count {
    let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
    let size = Int(
      data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    if id == "data" {
      let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
      return body.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
      }
    }
    offset += 8 + size + (size & 1)
  }
  throw CocoaError(.fileReadCorruptFile)
}

/// Deterministic low-level white noise (fixed seed, fixed RMS) for the noise-pad arm.
private func fixedNoise(count: Int, rms: Float) -> [Float] {
  var state: UInt64 = 0x3801
  let amplitude = rms * Float(3).squareRoot()  // uniform [-a, a] has RMS a/sqrt(3)
  return (0..<count).map { _ in
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let unit = Float(state >> 40) / Float(1 << 24)
    return (unit * 2 - 1) * amplitude
  }
}

private func shape(_ samples: [Float], arm: String) -> [Float] {
  let pad = 8_000  // production `silencePaddingSamples` (500 ms at 16 kHz)
  switch arm {
  case "zeros500": return samples + [Float](repeating: 0, count: pad)
  case "nopad": return samples
  case "noise500": return samples + fixedNoise(count: pad, rms: 0.0015)
  // Production batch input for a file-like clip: the whole clip plus the unchanged padding.
  case "filtered": return samples + [Float](repeating: 0, count: pad)
  default: preconditionFailure("unknown harness arm \(arm)")
  }
}

@Suite(
  "Whisper trailing-hallucination replay harness (#3801)", .serialized, .tags(.harnessContract))
struct WhisperTailReplayHarnessTests {
  @Test(
    "replays the manifest through every arm and records raw text",
    .enabled(if: TailReplayConfig.isConfigured && TailReplayConfig.refilterPath == nil),
    .tags(.realBoundary)
  )
  func replay() throws {
    let manifest = try JSONDecoder().decode(
      [TailReplayItem].self, from: Data(contentsOf: URL(filePath: TailReplayConfig.manifestPath!)))
    let session = try TranscribeCppSession(modelPath: TailReplayConfig.modelPath)
    defer { session.close() }
    FileManager.default.createFile(atPath: TailReplayConfig.outPath, contents: nil)
    let out = try FileHandle(forWritingTo: URL(filePath: TailReplayConfig.outPath))
    defer { try? out.close() }

    let arms = TailReplayConfig.arms
    var rows = 0
    for rep in 0..<TailReplayConfig.reps {
      for item in manifest {
        let samples = try readPCM16Mono(item.path)
        // Interleave arm order by repetition so no arm always runs first.
        let ordered = rep % 2 == 0 ? arms : arms.reversed()
        for arm in ordered {
          let input = shape(samples, arm: arm)
          let start = ContinuousClock.now
          let result = try session.run(samples: input, language: item.language)
          let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
          var row: [String: Any] = [
            "id": item.id, "arm": arm, "rep": rep, "ms": ms,
            "inputSamples": input.count, "text": result.text,
            "segments": result.segments.map {
              ["t0": $0.startMs, "t1": $0.endMs, "text": $0.text]
            },
          ]
          if arm == "filtered" {
            // #3801 C3: the REAL filter on this same native result, in the production shape for
            // a file-like clip (no VAD ranges): unpadded clip statistics, offset 0, real end =
            // clip length. Only the filter call is timed.
            let filterStart = ContinuousClock.now
            let tail = WhisperSilentTailFilter.filter(
              result, statsSamples: samples, segmentOffsetSamples: 0, realEndSample: samples.count)
            let filterMs = Double((ContinuousClock.now - filterStart) / .nanoseconds(1)) / 1_000_000
            row["filterMs"] = filterMs
            row["dropped"] = tail.dropped
            row["offsetSamples"] = 0
            row["realEndSample"] = samples.count
            row["sampleCount"] = samples.count
            row["filteredText"] = tail.result.text
            row["filteredSegments"] = tail.result.segments.map {
              ["t0": $0.startMs, "t1": $0.endMs, "text": $0.text]
            }
          }
          out.write(try JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
          rows += 1
        }
      }
    }
    #expect(!manifest.isEmpty)
    // Fails loudly on any silently skipped decode.
    #expect(rows == manifest.count * arms.count * TailReplayConfig.reps)
  }

  @Test(
    "re-applies the filter to saved native results and records the filtered output",
    .enabled(if: TailReplayConfig.isRefilterConfigured)
  )
  func refilter() throws {
    let manifest = try JSONDecoder().decode(
      [TailReplayItem].self, from: Data(contentsOf: URL(filePath: TailReplayConfig.manifestPath!)))
    let paths = Dictionary(uniqueKeysWithValues: manifest.map { ($0.id, $0.path) })
    let saved = try String(contentsOfFile: TailReplayConfig.refilterPath!, encoding: .utf8)
      .split(separator: "\n").map { line in
        try #require(
          try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      }
    FileManager.default.createFile(atPath: TailReplayConfig.outPath, contents: nil)
    let out = try FileHandle(forWritingTo: URL(filePath: TailReplayConfig.outPath))
    defer { try? out.close() }
    var rows = 0
    for row in saved {
      let id = try #require(row["id"] as? String)
      let samples = try readPCM16Mono(try #require(paths[id]))
      let segments = try #require(row["segments"] as? [[String: Any]]).map { segment in
        let start = try #require(segment["t0"] as? NSNumber)
        let end = try #require(segment["t1"] as? NSNumber)
        let text = try #require(segment["text"] as? String)
        return TranscribeCppSegment(startMs: start.int64Value, endMs: end.int64Value, text: text)
      }
      let run = TranscribeCppRunResult(
        text: try #require(row["text"] as? String), detectedLanguage: nil, segments: segments)
      let filterStart = ContinuousClock.now
      let tail = WhisperSilentTailFilter.filter(
        run, statsSamples: samples, segmentOffsetSamples: 0, realEndSample: samples.count)
      let filterMs = Double((ContinuousClock.now - filterStart) / .nanoseconds(1)) / 1_000_000
      var result = row
      result["arm"] = "refiltered"
      result["filterMs"] = filterMs
      result["dropped"] = tail.dropped
      result["filteredText"] = tail.result.text
      result["filteredSegments"] = tail.result.segments.map {
        ["t0": $0.startMs, "t1": $0.endMs, "text": $0.text]
      }
      out.write(try JSONSerialization.data(withJSONObject: result) + Data("\n".utf8))
      rows += 1
    }
    #expect(rows == manifest.count)
    #expect(rows == saved.count)
  }
}
