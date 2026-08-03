import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// Batch Parakeet transcription for eval corpora.
///
/// Mirrors `ParakeetBackend.swift` EXACTLY so the text this emits is the text
/// the shipped app would produce for the same audio:
///   - `AsrModels.loadFromCache(version: .v3)` (falls back to downloadAndLoad)
///   - `AsrManager(config: .default)` + `loadModels(_:)`
///   - a FRESH `TdtDecoderState` per file, sized by `manager.decoderLayerCount`
///     (the app makes one per one-shot batch decode; reusing state across files
///     would leak decoder context between unrelated utterances)
///   - `manager.transcribe(samples, decoderState: &state)`
///   - no language hint (parity with the shipped d5fcca4 behaviour)
///
/// Input:  a JSONL manifest, one {"id": "...", "wav": "/abs/path.wav"} per line.
/// Output: JSONL, one {"id","text","ms"} or {"id","error"} per line.

struct ManifestRow: Decodable {
  let id: String
  let wav: String
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
  fail("usage: ParakeetRunner <manifest.jsonl> <out.jsonl>")
}
let manifestURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let manifestData = try? Data(contentsOf: manifestURL) else {
  fail("cannot read manifest at \(manifestURL.path)")
}
let decoder = JSONDecoder()
var rows: [ManifestRow] = []
for line in String(decoding: manifestData, as: UTF8.self).split(separator: "\n") {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  if trimmed.isEmpty { continue }
  guard let row = try? decoder.decode(ManifestRow.self, from: Data(trimmed.utf8)) else {
    fail("bad manifest line: \(trimmed.prefix(120))")
  }
  rows.append(row)
}
guard !rows.isEmpty else { fail("manifest is empty") }

/// Read a WAV and return mono Float samples at the rate FluidAudio expects.
/// `AudioConverter().resampleAudioFile` is the same helper the CLI's transcribe
/// path uses, so resampling behaviour matches rather than being reimplemented.
func samples(at path: String) throws -> [Float] {
  try AudioConverter().resampleAudioFile(path: path)
}

let start = Date()
FileHandle.standardError.write(Data("loading Parakeet v3...\n".utf8))

let models: AsrModels
do {
  models = try await AsrModels.loadFromCache(version: .v3)
} catch {
  FileHandle.standardError.write(Data("cache miss (\(error)); downloading...\n".utf8))
  models = try await AsrModels.downloadAndLoad(version: .v3)
}
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
let layers = await manager.decoderLayerCount
FileHandle.standardError.write(
  Data("loaded in \(Int(Date().timeIntervalSince(start)))s, decoderLayers=\(layers)\n".utf8))

FileManager.default.createFile(atPath: outURL.path, contents: nil)
guard let out = FileHandle(forWritingAtPath: outURL.path) else {
  fail("cannot open \(outURL.path) for writing")
}
defer { try? out.close() }

var done = 0
var errors = 0
let runStart = Date()

for row in rows {
  var payload: [String: Any]
  let caseStart = Date()
  do {
    let audio = try samples(at: row.wav)
    // Fresh per file, exactly as the app does per batch decode.
    var state = TdtDecoderState.make(decoderLayers: layers)
    let result = try await manager.transcribe(audio, decoderState: &state)
    payload = [
      "id": row.id,
      "text": result.text,
      "ms": Int(Date().timeIntervalSince(caseStart) * 1000),
    ]
  } catch {
    errors += 1
    payload = ["id": row.id, "error": "\(error)"]
    FileHandle.standardError.write(Data("ERROR \(row.id): \(error)\n".utf8))
  }
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  out.write(data)
  out.write(Data("\n".utf8))
  done += 1
  if done % 100 == 0 {
    let elapsed = Int(Date().timeIntervalSince(runStart))
    FileHandle.standardError.write(
      Data("  \(done)/\(rows.count) (\(errors) errors, \(elapsed)s)\n".utf8))
  }
}

await manager.cleanup()
let elapsedTotal = Int(Date().timeIntervalSince(runStart))
// Build the summary as one String first: splitting a concatenation across the
// `.utf8` call makes `+` apply to a String and a UTF8View, which does not compile.
let summary =
  "DONE \(done - errors)/\(rows.count) in \(elapsedTotal)s | errors=\(errors) -> \(outURL.path)\n"
FileHandle.standardError.write(Data(summary.utf8))
exit(errors == 0 ? 0 : 1)
