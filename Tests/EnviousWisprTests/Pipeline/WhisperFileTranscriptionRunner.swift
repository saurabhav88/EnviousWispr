import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3735: the Whisper arm of `scripts/eval/language_gate_corpus.py --transcribe`. Not a product
/// test: it transcribes a manifest of audio files and runs only when one is named
/// (`TEST_RUNNER_EW_WHISPER_FILE_MANIFEST`), so the ordinary lane reports it skipped.
///
/// Each file is decoded by the app's own `AudioFileDecoder` (16 kHz mono Float32) and
/// transcribed once by `TranscribeCppWhisperBackend` over `LiveWhisperExecutorDriver` and the
/// GGUF the caller names, fingerprinted before any file, with no language hint: the native
/// detection the backend reports is the row's language, the role the retired WhisperKit
/// autodetect arm filled. A decode that throws is an error row, never a text row.
@MainActor
@Suite(
  "Whisper file transcription runner (#3735, language-gate corpus arm)", .serialized,
  .tags(.harnessContract))
struct WhisperFileTranscriptionRunner {

  nonisolated private static var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
  nonisolated static var manifestIsNamed: Bool { environment["EW_WHISPER_FILE_MANIFEST"] != nil }

  @Test("transcribes every file the manifest names", .enabled(if: manifestIsNamed))
  func runManifest() async throws {
    let env = Self.environment
    let manifest = try #require(env["EW_WHISPER_FILE_MANIFEST"])
    let outPath = try #require(env["EW_WHISPER_FILE_OUT"])
    try #require(
      !FileManager.default.fileExists(atPath: outPath), "refusing to overwrite \(outPath)")
    let gguf = try #require(env["EW_WHISPER_FILE_GGUF"])
    let fingerprint = try WhisperQualificationFixtures.modelFingerprint(atPath: gguf)
    let expected = try #require(env["EW_WHISPER_FILE_EXPECTED_MODEL_SHA256"])
    try #require(fingerprint == expected, "model fingerprint \(fingerprint) != \(expected)")

    let backend = TranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(), modelVariant: "q8_0", admittedModelPath: { gguf })
    try await backend.prepare()

    var out = Data()
    func emit(_ object: [String: Any]) throws {
      out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      out.append(0x0A)
    }
    var rowCount = 0
    let lines = try String(contentsOfFile: manifest, encoding: .utf8).split(separator: "\n")
    for line in lines where !line.isEmpty {
      let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let id = try #require(row["id"] as? String)
      let wav = try #require(row["wav"] as? String)
      do {
        let decoded = try await AudioFileDecoder.decode(url: URL(filePath: wav))
        let result = try await backend.transcribe(
          audioSamples: decoded.samples, options: TranscriptionOptions(language: nil))
        try emit([
          "id": id, "model_sha256": fingerprint, "text": result.text,
          "detected_lang": result.language ?? NSNull(),
        ])
      } catch {
        try emit(["id": id, "error": String(describing: error)])
      }
      rowCount += 1
    }
    await backend.unload()
    #expect(rowCount > 0, "the manifest named no files")
    try out.write(to: URL(filePath: outPath), options: .withoutOverwriting)
  }
}
