// AppleIntelligenceRunner — drives the shipped AppleIntelligenceConnector over
// a JSONL corpus and emits one JSONL record per case to stdout (or --out).
// Invoked by scripts/eval/acceptance_gate.py --mode bench. See issue #372.

import EnviousWisprCore
import EnviousWisprLLM
import Foundation

// MARK: - IO shapes

struct CorpusCase: Decodable {
  let id: String
  let asr_input: String
}

struct OutRecord: Encodable {
  let id: String
  var candidate: String?
  var error: String?
  var latencyMs: Int?
}

// MARK: - Arg parsing (hand-rolled; keeping the tool dependency-free)

struct Args {
  var corpusPath: String
  var outPath: String?
  var sleepSeconds: Double = 0
  var systemPrompt: String?
  var systemPromptPath: String?
  var detectedLanguage: String = "en"
}

func parseArgs() -> Args {
  var corpusPath: String?
  var outPath: String?
  var sleepSeconds: Double = 0
  var systemPrompt: String?
  var systemPromptPath: String?
  var detectedLanguage: String = "en"
  var argv = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = argv.next() {
    switch arg {
    case "--corpus":
      corpusPath = argv.next()
    case "--out":
      outPath = argv.next()
    case "--sleep-seconds":
      if let raw = argv.next(), let parsed = Double(raw) {
        sleepSeconds = parsed
      } else {
        fail("--sleep-seconds requires a numeric value")
      }
    case "--system-prompt":
      systemPrompt = argv.next()
    case "--system-prompt-file":
      systemPromptPath = argv.next()
    case "--detected-language":
      if let code = argv.next() { detectedLanguage = code }
    case "-h", "--help":
      printUsage()
      exit(0)
    default:
      fail("Unknown argument: \(arg)")
    }
  }
  guard let corpus = corpusPath else {
    fail("--corpus <path> is required")
  }
  return Args(
    corpusPath: corpus,
    outPath: outPath,
    sleepSeconds: sleepSeconds,
    systemPrompt: systemPrompt,
    systemPromptPath: systemPromptPath,
    detectedLanguage: detectedLanguage
  )
}

func printUsage() {
  let msg = """
    AppleIntelligenceRunner — drive Apple Intelligence polish over a JSONL corpus.

    USAGE:
      AppleIntelligenceRunner --corpus <path> [--out <path>] [--sleep-seconds N]

    INPUT:
      Each line of --corpus must be a JSON object with fields {"id": String, "asr_input": String}.
      Extra fields are ignored.

    OUTPUT:
      One JSON object per line to stdout (or --out if provided).
      Success: {"id": "...", "candidate": "..."}
      Failure: {"id": "...", "error": "<reason>"}

    EXIT CODES:
      0  every case attempted (some may have errored — Python reads those lines)
      2  startup failure: Apple Intelligence unavailable, corpus missing/malformed,
         or the FIRST case reported Apple Intelligence unavailable
         (frameworkUnavailable / modelNotReady)
    """
  FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data(("AppleIntelligenceRunner: " + msg + "\n").utf8))
  exit(2)
}

// MARK: - Main

@main
struct RunnerMain {
  static func main() async {
    let args = parseArgs()
    let cases = loadCorpus(path: args.corpusPath)

    // Enable file logging so [AIPolish] trace lines from AppleIntelligenceConnector
    // land in ~/Library/Logs/EnviousWispr/app.log. Required for bench-mode A/B
    // analysis of filter/polish behavior. AppLogger is file-gated on this flag.
    await AppLogger.shared.setDebugMode(true)

    let sink: FileHandle
    if let outPath = args.outPath {
      // Remove any existing file before recreating: createFile(atPath:contents:)
      // semantics around truncation are platform-fragile, and a partial prior
      // run left behind would produce duplicate/stale JSONL records.
      try? FileManager.default.removeItem(atPath: outPath)
      FileManager.default.createFile(atPath: outPath, contents: nil)
      guard let handle = FileHandle(forWritingAtPath: outPath) else {
        fail("could not open --out for writing: \(outPath)")
      }
      sink = handle
    } else {
      sink = FileHandle.standardOutput
    }
    defer {
      if args.outPath != nil { try? sink.close() }
    }

    let connector = AppleIntelligenceConnector()
    let config = LLMProviderConfig(
      model: "apple-intelligence",
      apiKeyKeychainId: nil,
      maxTokens: 2048,
      temperature: 0,
      thinkingBudget: nil,
      reasoningEffort: nil,
      // Empty string maps to nil so the bench can mirror the DEFAULT Parakeet
      // production path (no LID → language nil → LeadingMarkerRepair does NOT
      // fire). Passing "en" forces the repair on, which inflates onset numbers
      // vs what most users actually get. See #963 onset-masking finding.
      detectedLanguage: args.detectedLanguage.isEmpty ? nil : args.detectedLanguage
    )
    // System prompt resolution: explicit --system-prompt > --system-prompt-file
    // > built-in enrichment fallback. Python bench driver normally passes the
    // full enriched prompt (default + false-start) via --system-prompt-file so
    // the runner mirrors LLMPolishStep.appleIntelligenceInstructions exactly
    // (custom vocab dropped from the Apple path in #1084).
    let systemPrompt: String
    if let explicit = args.systemPrompt {
      systemPrompt = explicit
    } else if let path = args.systemPromptPath {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let text = String(data: data, encoding: .utf8)
      else {
        fail("could not read --system-prompt-file at \(path)")
      }
      systemPrompt = text
    } else {
      systemPrompt =
        PolishInstructions.default.systemPrompt
        + "\nThis is speech-to-text output. Remove false starts. "
        + "Preserve the speaker's tone and formality level. "
        + "If unsure about a correction, leave unchanged."
    }
    let instructions = PolishInstructions(systemPrompt: systemPrompt)

    let encoder = JSONEncoder()
    // Stable key order helps humans diffing the JSONL files. Does not affect parse.
    encoder.outputFormatting = [.sortedKeys]

    let progressEvery = max(1, cases.count / 10)
    let startedAt = Date()
    var errorCount = 0

    for (index, caseItem) in cases.enumerated() {
      let record: OutRecord
      let caseStart = Date()
      do {
        let result = try await connector.polish(
          text: caseItem.asr_input,
          instructions: instructions,
          config: config,
          onToken: nil
        )
        let ms = Int(Date().timeIntervalSince(caseStart) * 1000)
        record = OutRecord(
          id: caseItem.id, candidate: result.polishedText, error: nil, latencyMs: ms)
      } catch let err as LLMError {
        // frameworkUnavailable OR modelNotReady on the very first case means
        // Apple Intelligence is not usable on this machine right now (unsupported
        // OS, switched off, ineligible hardware, not compiled in, OR the on-device
        // model is still downloading / org-restricted) — no reason to keep trying.
        // Exit 2 so the Python driver treats it as an infra error, not per-case
        // noise. #1101: `modelNotReady` was split out of `frameworkUnavailable`
        // in #1080; before that it was the same case and already aborted here, so
        // this restores the pre-#1080 contract (an unavailable model must abort
        // setup, never corrupt `--mode bench` results as a per-case loss).
        if index == 0 {
          switch err {
          case .frameworkUnavailable, .modelNotReady:
            fail(
              "first case threw \(String(describing: err)): \(err.errorDescription ?? "Apple Intelligence unavailable on this machine")"
            )
          default:
            break
          }
        }
        errorCount += 1
        record = OutRecord(id: caseItem.id, candidate: nil, error: String(describing: err))
      } catch {
        errorCount += 1
        record = OutRecord(id: caseItem.id, candidate: nil, error: String(describing: error))
      }

      write(record: record, to: sink, encoder: encoder)

      if (index + 1) % progressEvery == 0 {
        let elapsed = Date().timeIntervalSince(startedAt)
        FileHandle.standardError.write(
          Data(
            "[apple_runner] \(index + 1)/\(cases.count)  elapsed \(Int(elapsed))s  errors \(errorCount)\n"
              .utf8
          ))
      }

      if args.sleepSeconds > 0 && index < cases.count - 1 {
        try? await Task.sleep(for: .seconds(args.sleepSeconds))
      }
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    FileHandle.standardError.write(
      Data(
        "[apple_runner] done  cases \(cases.count)  errors \(errorCount)  elapsed \(Int(elapsed))s\n"
          .utf8
      ))
  }
}

// MARK: - Helpers

func loadCorpus(path: String) -> [CorpusCase] {
  let url = URL(fileURLWithPath: path)
  guard let data = try? Data(contentsOf: url),
    let text = String(data: data, encoding: .utf8)
  else {
    fail("could not read corpus at \(path)")
  }
  let decoder = JSONDecoder()
  var cases: [CorpusCase] = []
  for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
    .enumerated()
  {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.isEmpty { continue }
    guard let lineData = line.data(using: .utf8),
      let decoded = try? decoder.decode(CorpusCase.self, from: lineData)
    else {
      fail("corpus line \(lineNumber + 1) is not a valid CorpusCase JSON object")
    }
    cases.append(decoded)
  }
  if cases.isEmpty { fail("corpus has zero cases") }
  return cases
}

func write(record: OutRecord, to sink: FileHandle, encoder: JSONEncoder) {
  guard let encoded = try? encoder.encode(record) else {
    fail("JSONEncoder failed on record id=\(record.id) — this should never happen")
  }
  var payload = encoded
  payload.append(0x0A)  // newline
  sink.write(payload)
}
