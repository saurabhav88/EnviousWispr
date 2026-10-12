import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// Batch Parakeet transcription for eval corpora.
///
/// Matches the shipped one-shot decode mechanics after model setup, so the
/// text this emits is the text the app would produce for the same audio:
///   - a cache-only model load with FluidAudio's network switch armed off —
///     the app's ModelDelivery path OWNS model setup and admission; this
///     benchmark only consumes the cache it populated, and must never mutate
///     the model bytes it measures (#1981)
///   - `AsrManager(config: ASRConfig(melChunkContext: true))` (#2788, matches the app) + `loadModels(_:)`
///   - a FRESH `TdtDecoderState` per file, sized by `manager.decoderLayerCount`
///     (the app makes one per one-shot batch decode; reusing state across files
///     would leak decoder context between unrelated utterances)
///   - `manager.transcribe(samples, decoderState: &state)`
///   - no language hint (parity with the shipped behaviour)
///
/// #3546: the model is explicit. `--model ultra` is the shipping Parakeet;
/// `--model v3` replays the historical model. `--model-dir` is the repo-shaped
/// directory the app installed (for Ultra:
/// `~/Library/Application Support/EnviousWispr/Models/parakeet-ultra`). There is
/// no default and no fallback: a missing or unloadable directory fails the run
/// rather than measuring a different model.
///
/// Usage:  ParakeetRunner --model ultra|v3 --model-dir <dir> <manifest.jsonl> <out.jsonl>
/// Input:  a JSONL manifest, one {"id": "...", "wav": "/abs/path.wav"} per line.
/// Output: JSONL, one {"id","model","text","ms"} or {"id","model","error"} per line.

struct ManifestRow: Decodable {
  let id: String
  let wav: String
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let usage = "usage: ParakeetRunner --model ultra|v3 --model-dir <dir> <manifest.jsonl> <out.jsonl>"
var options: [String: String] = [:]
var positional: [String] = []
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
  if arg == "--model" || arg == "--model-dir" {
    guard let value = argIterator.next() else { fail(usage) }
    options[arg] = value
  } else if arg.hasPrefix("--") {
    fail("unknown option \(arg)\n\(usage)")
  } else {
    positional.append(arg)
  }
}
guard positional.count == 2, let modelName = options["--model"],
  let modelDirPath = options["--model-dir"]
else { fail(usage) }
let version: AsrModelVersion
let repo: Repo
switch modelName {
case "ultra": (version, repo) = (.ultra, .parakeetUltra)
case "v3": (version, repo) = (.v3, .parakeetV3)
default: fail("--model must be ultra or v3, got \(modelName)")
}
let modelDir = URL(fileURLWithPath: modelDirPath, isDirectory: true).standardizedFileURL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDirectory),
  isDirectory.boolValue
else { fail("model directory does not exist: \(modelDir.path)") }
// FluidAudio loads from the directory's PARENT plus the model's own folder name, so a
// differently named directory would load a sibling model silently.
guard modelDir.lastPathComponent == repo.folderName else {
  fail(
    "--model-dir must name \(repo.folderName), got \(modelDir.path); "
      + "FluidAudio resolves the model folder from its parent")
}
let manifestURL = URL(fileURLWithPath: positional[0])
let outURL = URL(fileURLWithPath: positional[1])

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
FileHandle.standardError.write(
  Data("loading Parakeet \(modelName) from \(modelDir.path)...\n".utf8))

// Cache-only: the app owns model setup; a benchmark must never mutate the
// model bytes it measures.
ModelHub.offlineMode = true
let models: AsrModels
do {
  models = try await AsrModels.load(from: modelDir, version: version)
} catch {
  fail("cannot load Parakeet \(modelName) from \(modelDir.path) offline: \(error)")
}
// #2788: same explicit long-form path as the app (ParakeetBackend), so this measures
// what ships rather than upstream's default.
let manager = AsrManager(config: ASRConfig(melChunkContext: true))
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
      "model": modelName,
      "text": result.text,
      "ms": Int(Date().timeIntervalSince(caseStart) * 1000),
    ]
  } catch {
    errors += 1
    payload = ["id": row.id, "model": modelName, "error": "\(error)"]
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
  "DONE model=\(modelName) \(done - errors)/\(rows.count) in \(elapsedTotal)s | errors=\(errors) -> \(outURL.path)\n"
FileHandle.standardError.write(Data(summary.utf8))
exit(errors == 0 ? 0 : 1)
