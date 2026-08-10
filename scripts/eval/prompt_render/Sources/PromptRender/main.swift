// PromptRender — emits the REAL production polish prompt per case by driving
// the shipped DefaultPromptPlanner (same code path production uses for cloud +
// Ollama). One JSONL record per case: {id, system, user, mode}.
//
// Usage:
//   swift run -c release PromptRender --corpus <path> --provider openai --model gpt-4o [--out <path>]
//   swift run -c release PromptRender --corpus <path> --provider gemini --model gemini-2.5-flash
//   swift run -c release PromptRender --corpus <path> --provider ollama --model llama3.2 [--hosted]
//
// #1948: Ollama prompt selection reads the daemon's execution-location report, so a render
// that omits it silently produces the LOCAL prompt for every Ollama model. `--hosted`
// renders the arm a model served from Ollama's servers receives. Both the selected family
// and the flag are written into every record, so an arm file can never be mistaken for the
// other one after the fact.
//
// English corpus assumptions (match the naked bench): no appName, no language
// override, empty custom vocabulary, nil backend (safety-net passthrough).

import EnviousWisprCore
import EnviousWisprLLM
import Foundation

struct CorpusCase: Decodable {
  let id: String
  let asr_input: String
}

struct OutRecord: Encodable {
  let id: String
  let system: String
  let user: String
  let mode: String
  let family: String
  let ollamaIsRemote: Bool?
}

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data(("ERROR: " + msg + "\n").utf8))
  exit(1)
}

var corpusPath: String?
var provider: String?
var model: String?
var outPath: String?
var hosted = false
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argv.next() {
  switch arg {
  case "--corpus": corpusPath = argv.next()
  case "--provider": provider = argv.next()
  case "--model": model = argv.next()
  case "--out": outPath = argv.next()
  case "--hosted": hosted = true
  default: fail("unknown arg \(arg)")
  }
}

guard let corpusPath, let provider, let model else {
  fail("--corpus, --provider, --model are required")
}

// Fail closed rather than emit a misleadingly-labelled arm: `--hosted` means nothing off Ollama.
if hosted, provider.lowercased() != "ollama" {
  fail("--hosted applies only to --provider ollama")
}

let llmProvider: LLMProvider
switch provider.lowercased() {
case "openai": llmProvider = .openAI
case "gemini": llmProvider = .gemini
case "ollama": llmProvider = .ollama
default: fail("--provider must be openai|gemini|ollama")
}

let raw = try String(contentsOfFile: corpusPath, encoding: .utf8)
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

let planner = DefaultPromptPlanner()
var out: [String] = []
for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
  guard let data = line.data(using: .utf8),
    let c = try? decoder.decode(CorpusCase.self, from: data)
  else { continue }

  let input = PromptBuildInput(
    transcript: c.asr_input,
    provider: llmProvider,
    modelID: model,
    appName: nil,
    language: nil,
    polishVocabulary: PolishVocabulary(terms: [], generation: 0),
    // nil off Ollama: those providers route on provider identity alone.
    ollamaIsRemote: llmProvider == .ollama ? hosted : nil
  )
  let plan = planner.plan(input: input)
  let system = plan.envelope.messages.first { $0.role == .system }?.content ?? ""
  let user = plan.envelope.messages.first { $0.role == .user }?.content ?? ""
  let rec = OutRecord(
    id: c.id, system: system, user: user, mode: plan.mode.rawValue,
    family: plan.family.rawValue,
    ollamaIsRemote: llmProvider == .ollama ? hosted : nil)
  let enc = try encoder.encode(rec)
  out.append(String(data: enc, encoding: .utf8)!)
}

let joined = out.joined(separator: "\n") + "\n"
if let outPath {
  try joined.write(toFile: outPath, atomically: true, encoding: .utf8)
  FileHandle.standardError.write(Data("wrote \(out.count) records to \(outPath)\n".utf8))
} else {
  print(joined, terminator: "")
}
