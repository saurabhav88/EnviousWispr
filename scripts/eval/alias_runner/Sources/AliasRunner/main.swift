// AliasRunner — drives the shipped WordSuggestionService over a JSONL corpus
// and emits one JSONL record per case with raw aliases, filtered aliases,
// timing, and error metadata. Invoked by scripts/eval/alias_suggestion_gate.py.
// See issue #637.

import AliasRunnerKit
import CoreML
import CryptoKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Tokenizers

// MARK: - IO shapes

struct CorpusCase: Decodable {
  let id: String
  let canonical: String
}

struct OutRecord: Encodable {
  let id: String
  let canonical: String
  var predictedCategory: String?
  var rawAliases: [String]
  var filteredAliases: [String]
  var latencyMs: Int
  var coldStart: Bool
  var timedOut: Bool
  var error: String?

  enum CodingKeys: String, CodingKey {
    case id
    case canonical
    case predictedCategory = "predicted_category"
    case rawAliases = "raw_aliases"
    case filteredAliases = "filtered_aliases"
    case latencyMs = "latency_ms"
    case coldStart = "cold_start"
    case timedOut = "timed_out"
    case error
  }
}

// MARK: - Arg parsing

struct Args {
  var corpusPath: String
  var outPath: String?
  var sleepSeconds: Double = 0
  var disableTimeout: Bool = false
  var coldStartSubsetSize: Int = 0
  var coldIdleSeconds: Double = 180
  var concurrency: Int = 1
}

func parseArgs() -> Args {
  var corpusPath: String?
  var outPath: String?
  var sleepSeconds: Double = 0
  var disableTimeout = false
  var coldStartSubsetSize = 0
  var coldIdleSeconds: Double = 180
  var concurrency = 1
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
    case "--disable-timeout":
      disableTimeout = true
    case "--cold-start-subset":
      if let raw = argv.next(), let parsed = Int(raw) {
        coldStartSubsetSize = parsed
      } else {
        fail("--cold-start-subset requires an integer value")
      }
    case "--cold-idle-seconds":
      if let raw = argv.next(), let parsed = Double(raw) {
        coldIdleSeconds = parsed
      } else {
        fail("--cold-idle-seconds requires a numeric value")
      }
    case "--concurrency":
      if let raw = argv.next(), let parsed = Int(raw), parsed >= 1 {
        concurrency = parsed
      } else {
        fail("--concurrency requires a positive integer value")
      }
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
  if concurrency > 1 && coldStartSubsetSize > 0 {
    fail(
      "--concurrency and --cold-start-subset are mutually exclusive: cold-start idle gaps assume sequential execution"
    )
  }
  if concurrency > 1 && sleepSeconds > 0 {
    fail(
      "--concurrency and --sleep-seconds are mutually exclusive: the concurrent path does not pace requests, so combining them would silently drop the requested pacing"
    )
  }
  return Args(
    corpusPath: corpus,
    outPath: outPath,
    sleepSeconds: sleepSeconds,
    disableTimeout: disableTimeout,
    coldStartSubsetSize: coldStartSubsetSize,
    coldIdleSeconds: coldIdleSeconds,
    concurrency: concurrency
  )
}

func printUsage() {
  let msg = """
    AliasRunner — drive WordSuggestionService over a JSONL corpus.

    USAGE:
      AliasRunner --corpus <path> [--out <path>] [--sleep-seconds N]
                  [--disable-timeout] [--cold-start-subset K]
                  [--cold-idle-seconds S] [--concurrency N]

    INPUT:
      Each line of --corpus must be a JSON object with at least
      {"id": String, "canonical": String}. Extra fields are ignored.

    OUTPUT:
      One JSON object per line to stdout (or --out if provided), in
      corpus order regardless of --concurrency. Keys:
        id, canonical, predicted_category, raw_aliases, filtered_aliases,
        latency_ms, cold_start, timed_out, error

    --concurrency N (default 1) runs up to N cases in flight at once via a
    TaskGroup instead of strictly sequentially. Mutually exclusive with
    --cold-start-subset (idle-gap timing assumes sequential execution) and
    --sleep-seconds (the concurrent path does not pace requests).

    EXIT CODES:
      0  every case attempted (per-case errors recorded in `error` field)
      2  startup failure: Apple Intelligence unavailable on first case,
         corpus missing/malformed, or framework not present.
    """
  FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data(("AliasRunner: " + msg + "\n").utf8))
  exit(2)
}

// MARK: - Main

@main
struct RunnerMain {
  static func main() async {
    // #996: `judge` is a separate subcommand with its own parser so the alias
    // CLI (flags, ordering, exit meanings) stays byte-for-byte as it was.
    if CommandLine.arguments.dropFirst().first == "judge" {
      await runJudge(Array(CommandLine.arguments.dropFirst(2)))
    }
    if CommandLine.arguments.dropFirst().first == "tokenize" {
      await runTokenize(Array(CommandLine.arguments.dropFirst(2)))
    }
    if CommandLine.arguments.dropFirst().first == "shape" {
      runShape(Array(CommandLine.arguments.dropFirst(2)))
    }
    let args = parseArgs()
    let cases = loadCorpus(path: args.corpusPath)

    let sink: FileHandle
    if let outPath = args.outPath {
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

    let service = WordSuggestionService()
    guard service.isAvailable else {
      fail("Apple Intelligence is not available on this host")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let progressEvery = max(1, cases.count / 10)
    let startedAt = Date()
    var errorCount = 0

    let coldIdxSet: Set<Int> = {
      guard args.coldStartSubsetSize > 0 else { return [] }
      let stride = max(1, cases.count / args.coldStartSubsetSize)
      var picks: Set<Int> = []
      var idx = 0
      while picks.count < args.coldStartSubsetSize && idx < cases.count {
        picks.insert(idx)
        idx += stride
      }
      return picks
    }()

    if args.concurrency > 1 {
      await runConcurrent(
        args: args, cases: cases, service: service, sink: sink, encoder: encoder,
        startedAt: startedAt, progressEvery: progressEvery)
    } else {
      for (index, caseItem) in cases.enumerated() {
        let isCold = coldIdxSet.contains(index)
        if isCold && index > 0 {
          FileHandle.standardError.write(
            Data(
              "[alias_runner] cold-start idle \(Int(args.coldIdleSeconds))s before case \(caseItem.id)\n"
                .utf8))
          try? await Task.sleep(for: .seconds(args.coldIdleSeconds))
        }

        let out = await runOne(
          caseItem: caseItem, service: service, disableTimeout: args.disableTimeout,
          isCold: isCold)

        if out.error == "framework_unavailable" && index == 0 {
          fail("first case reported framework_unavailable; Apple Intelligence not usable")
        }
        if out.error != nil { errorCount += 1 }

        write(record: out, to: sink, encoder: encoder)

        if (index + 1) % progressEvery == 0 {
          let elapsed = Date().timeIntervalSince(startedAt)
          FileHandle.standardError.write(
            Data(
              "[alias_runner] \(index + 1)/\(cases.count)  elapsed \(Int(elapsed))s  errors \(errorCount)\n"
                .utf8
            ))
        }

        if args.sleepSeconds > 0 && index < cases.count - 1 && !isCold {
          try? await Task.sleep(for: .seconds(args.sleepSeconds))
        }
      }

      let elapsed = Date().timeIntervalSince(startedAt)
      FileHandle.standardError.write(
        Data(
          "[alias_runner] done  cases \(cases.count)  errors \(errorCount)  elapsed \(Int(elapsed))s\n"
            .utf8
        ))
    }
  }
}

/// Runs one case and builds its output record. Shared by the sequential and
/// concurrent paths so error/category classification cannot drift between them.
func runOne(
  caseItem: CorpusCase, service: WordSuggestionService, disableTimeout: Bool, isCold: Bool
) async -> OutRecord {
  let record = await service.benchmarkSuggest(
    for: caseItem.canonical, disableTimeout: disableTimeout)
  // Gate on BOTH errorDescription nil AND timedOut false so timeouts don't
  // fabricate a synthetic category that inflates category accuracy for cases
  // where `general` happens to be in acceptable_categories. Codex review #674
  // (2026-05-05).
  let categoryStr: String? =
    (record.errorDescription == nil && !record.timedOut) ? record.category.rawValue : nil
  return OutRecord(
    id: caseItem.id,
    canonical: caseItem.canonical,
    predictedCategory: categoryStr,
    rawAliases: record.rawAliases,
    filteredAliases: record.filteredAliases,
    latencyMs: record.latencyMs,
    coldStart: isCold,
    timedOut: record.timedOut,
    error: record.errorDescription
  )
}

/// Runs up to `args.concurrency` cases in flight at once via a bounded
/// TaskGroup (seed N, then replace each as it completes). Writes each
/// contiguous completed prefix out as soon as it becomes available, so an
/// interrupted long run only loses the cases still in flight, not everything
/// completed so far — verified by killing a live run mid-batch (Codex diff
/// review r3, #1702). Known residual gap (r4): output is still index-ordered,
/// not arrival-ordered, so a genuinely stuck early case under
/// `--disable-timeout` withholds any later cases that already finished
/// behind it. Accepted for this research tool rather than adding
/// out-of-order durable persistence — `--disable-timeout` is an opt-in,
/// rarely-used flag, and a true indefinite hang is not a failure mode this
/// benchmark has hit in practice.
/// This measures whether N-at-a-time beats sequential throughput for #1702;
/// cold-start idle gaps are not supported here (mutually exclusive at
/// arg-parse time).
func runConcurrent(
  args: Args, cases: [CorpusCase], service: WordSuggestionService, sink: FileHandle,
  encoder: JSONEncoder, startedAt: Date, progressEvery: Int
) async {
  var results = [OutRecord?](repeating: nil, count: cases.count)
  var errorCount = 0
  var completed = 0
  var nextToWrite = 0

  await withTaskGroup(of: (Int, OutRecord).self) { group in
    var nextIndex = 0
    func addNext() {
      guard nextIndex < cases.count else { return }
      let index = nextIndex
      let caseItem = cases[index]
      nextIndex += 1
      group.addTask {
        let out = await runOne(
          caseItem: caseItem, service: service, disableTimeout: args.disableTimeout, isCold: false)
        return (index, out)
      }
    }

    for _ in 0..<min(args.concurrency, cases.count) {
      addNext()
    }

    let seedSize = min(args.concurrency, cases.count)
    while let (index, out) = await group.next() {
      results[index] = out
      if out.error != nil { errorCount += 1 }
      completed += 1
      // Fail fast on the same signal the sequential path checks at index 0:
      // if AFM reports unavailable, don't burn the rest of the benchmark's
      // wall-clock discovering that at the end. Order isn't guaranteed under
      // concurrency, so check membership in the initial seeded batch by the
      // case's own corpus index, not by completion count — a later-index
      // replacement task can finish before an earlier-index seeded one, so
      // `completed <= seedSize` does not reliably identify the seeded batch
      // (Codex diff review r2, #1702).
      if out.error == "framework_unavailable" && index < seedSize {
        fail(
          "case \(out.id) reported framework_unavailable in the initial batch; Apple Intelligence not usable"
        )
      }
      while nextToWrite < results.count, let ready = results[nextToWrite] {
        write(record: ready, to: sink, encoder: encoder)
        nextToWrite += 1
      }
      if completed % progressEvery == 0 {
        let elapsed = Date().timeIntervalSince(startedAt)
        FileHandle.standardError.write(
          Data(
            "[alias_runner] \(completed)/\(cases.count)  elapsed \(Int(elapsed))s  errors \(errorCount)  concurrency \(args.concurrency)\n"
              .utf8
          ))
      }
      addNext()
    }
  }

  let elapsed = Date().timeIntervalSince(startedAt)
  FileHandle.standardError.write(
    Data(
      "[alias_runner] done  cases \(cases.count)  errors \(errorCount)  elapsed \(Int(elapsed))s  concurrency \(args.concurrency)\n"
        .utf8
    ))
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
  payload.append(0x0A)
  sink.write(payload)
}

// MARK: - judge subcommand (#996)

/// Never returns. Exit codes are `JudgeCLI.execute`'s: 0 ok, 2 usage/infra,
/// 3 named judge unimplemented (records still written).
func runJudge(_ argv: [String]) async -> Never {
  let judgeArgs: JudgeArgs
  do {
    judgeArgs = try JudgeCLI.parse(argv)
  } catch {
    FileHandle.standardError.write(Data(("AliasRunner judge: \(error)\n" + JudgeCLI.usage + "\n").utf8))
    exit(2)
  }
  var arms = DoorJudgeArm.arms()
  if let manifestPath = judgeArgs.modelManifestPath {
    do {
      arms[judgeArgs.judge] = try await ClassifierJudgeArm.load(candidate: judgeArgs.judge, manifestPath: manifestPath)
    } catch {
      FileHandle.standardError.write(Data("AliasRunner judge: classifier arm refused to load: \(error)\n".utf8))
      exit(2)
    }
  }
  // `--path shape+judge` measures the PLANNED proposal path: alignment drops
  // casing-only and punctuation-only runs before any judge is asked (plan
  // §3.1 step 5). The bound manifest must declare the same path; the gate
  // passes it through. `judge` measures the judge alone.
  if judgeArgs.path == .shapeAndJudge {
    for (candidate, arm) in arms {
      arms[candidate] = StageOneShapeArm(inner: arm, candidate: candidate)
    }
  }
  let (records, code) = await JudgeCLI.execute(args: judgeArgs, arms: arms)
  if code == 2 {
    FileHandle.standardError.write(
      Data("AliasRunner judge: could not load the corpus or the fixture (see usage)\n".utf8))
    exit(2)
  }
  let text: String
  do {
    text = try JudgeCLI.encode(records)
  } catch {
    FileHandle.standardError.write(Data("AliasRunner judge: encode failed: \(error)\n".utf8))
    exit(2)
  }
  if let outPath = judgeArgs.outPath {
    do {
      try text.write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
      FileHandle.standardError.write(Data("AliasRunner judge: could not write \(outPath)\n".utf8))
      exit(2)
    }
  } else {
    FileHandle.standardOutput.write(Data(text.utf8))
  }
  if code == 3 {
    FileHandle.standardError.write(
      Data("AliasRunner judge: \(judgeArgs.judge.rawValue) is unimplemented in this build; every row written as unimplemented\n".utf8))
  }
  exit(code)
}

// MARK: - AFM judge arms (#996 chunk 2b)

/// The judge arms that answer through the shipped JSON benchmark door: the
/// two Apple FoundationModels comparison arms, one per OS the plan names,
/// and the production rules judge (#996 chunk 4a). An OS-bound arm only
/// EXECUTES on the OS it is named for: asking for `afm-macos26` on a macOS 27
/// Mac writes `unavailable` rows that say so, never a result relabelled as
/// the other arm. Each executed row calls the door on the shipped
/// `WordSuggestionService` (one instance, one permit queue), with the row's
/// single candidate and the pasted sentence as context, and carries the
/// answering judge's execution identity.
struct DoorJudgeArm: JudgeArm {
  let candidate: JudgeCandidate
  /// The macOS major this arm may execute on; `nil` for an arm that runs on
  /// every supported macOS (rules).
  let requiredMajor: Int?
  let service: WordSuggestionService
  /// The door's `arm` selector: absent for the shipped AFM default, `rules`
  /// for the production rules judge (#996 chunk 4a). The door refuses any
  /// other value, so a typo here surfaces as `malformed` rows, never as the
  /// wrong judge's answers under this arm's name.
  let doorArm: String?

  static func arms() -> [JudgeCandidate: any JudgeArm] {
    let service = WordSuggestionService()
    return [
      .afmMacOS26: DoorJudgeArm(
        candidate: .afmMacOS26, requiredMajor: 26, service: service, doorArm: nil),
      .afmMacOS27: DoorJudgeArm(
        candidate: .afmMacOS27, requiredMajor: 27, service: service, doorArm: nil),
      .rules: DoorJudgeArm(candidate: .rules, requiredMajor: nil, service: service, doorArm: "rules"),
    ]
  }

  private struct DoorDecision: Decodable {
    let id: Int
    let vocabulary_correction: Bool
    let safe_alias: Bool
  }
  private struct DoorResponse: Decodable {
    let outcome: String
    let decisions: [DoorDecision]?
    let latency_ms: Double
    let execution_identity: [String: String]
    let note: String?
  }

  /// Identity without inference: the door answers an empty candidate list
  /// with the arm's identity and no model call (outcome `identity`).
  func loadedIdentity() async -> [String: String]? {
    let actual = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    if let requiredMajor, actual != requiredMajor { return nil }
    var request: [String: Any] = ["candidates": [], "context": "", "language": "en", "identity_only": true]
    if let doorArm { request["arm"] = doorArm }
    guard let requestJSON = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    let responseData = await service.benchmarkJudgeCorrections(requestJSON: requestJSON)
    guard let response = try? JSONDecoder().decode(DoorResponse.self, from: responseData), response.outcome == "identity" else { return nil }
    return response.execution_identity
  }

  func judge(row: EditCorpusRow) async -> JudgeRecord {
    let actual = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    if let requiredMajor, actual != requiredMajor {
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .unavailable, decision: nil, latencyMs: 0,
        note: "this Mac runs macOS \(actual); \(candidate.rawValue) requires macOS \(requiredMajor) and was not executed",
        executionIdentity: nil)
    }
    var request: [String: Any] = [
      "candidates": [["id": 1, "original": row.original, "replacement": row.replacement]],
      "context": row.pasted,
      "language": row.language,
    ]
    if let doorArm { request["arm"] = doorArm }
    guard let requestJSON = try? JSONSerialization.data(withJSONObject: request) else {
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: 0,
        note: "could not encode the request", executionIdentity: nil)
    }
    let responseData = await service.benchmarkJudgeCorrections(requestJSON: requestJSON)
    guard let response = try? JSONDecoder().decode(DoorResponse.self, from: responseData) else {
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: 0,
        note: "benchmark door returned an undecodable response", executionIdentity: nil)
    }
    if response.outcome == "verdict" {
      guard let decisions = response.decisions, decisions.count == 1, decisions[0].id == 1 else {
        return JudgeRecord(
          id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil,
          latencyMs: response.latency_ms, note: "verdict without exactly one decision for id 1",
          executionIdentity: response.execution_identity)
      }
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .verdict,
        decision: JudgeDecision(
          vocabularyCorrection: decisions[0].vocabulary_correction, safeAlias: decisions[0].safe_alias),
        latencyMs: response.latency_ms, note: nil, executionIdentity: response.execution_identity)
    }
    // Bypass names are the Core `CorrectionJudgeBypass` raw values, which are
    // the kit's `JudgeOutcome` names in camel case (`notGranted`).
    let outcome: JudgeOutcome
    switch response.outcome {
    case "unavailable": outcome = .unavailable
    case "notGranted": outcome = .notGranted
    case "deadline": outcome = .deadline
    case "cancelled": outcome = .cancelled
    default: outcome = .malformed
    }
    return JudgeRecord(
      id: row.id, judge: candidate.rawValue, outcome: outcome, decision: nil,
      latencyMs: response.latency_ms, note: response.note ?? "\(candidate.rawValue) arm bypass \(response.outcome)",
      executionIdentity: response.execution_identity)
  }
}

// MARK: - tokenize subcommand (#996 chunk 2b)

/// `AliasRunner tokenize --request <json> --out <json> [--stack vendored|upstream]`:
/// `vendored` (default) hands the request to the LLM module's benchmark door
/// (`CorrectionJudgeBenchmark.tokenizerParity`, the shipped Argmax stack);
/// `upstream` encodes the texts with the pinned Hugging Face
/// `swift-transformers` tokenizer that ONLY this runner links (#996
/// chunk 2b-ii experiment), texts only, no pair assembly. Never returns.
func runTokenize(_ argv: [String]) async -> Never {
  var request: String?
  var out: String?
  var stack = "vendored"
  var it = argv.makeIterator()
  while let arg = it.next() {
    switch arg {
    case "--request": request = it.next()
    case "--out": out = it.next()
    case "--stack": stack = it.next() ?? ""
    default:
      FileHandle.standardError.write(Data("AliasRunner tokenize: unknown argument \(arg)\n".utf8))
      exit(2)
    }
  }
  guard let request, let out, let data = FileManager.default.contents(atPath: request),
    ["vendored", "upstream"].contains(stack)
  else {
    FileHandle.standardError.write(
      Data("usage: AliasRunner tokenize --request <json> --out <json> [--stack vendored|upstream]\n".utf8))
    exit(2)
  }
  let response: Data
  if stack == "upstream" {
    response = await UpstreamTokenizerProbe.encode(requestJSON: data)
  } else {
    response = await CorrectionJudgeBenchmark.tokenizerParity(requestJSON: data)
  }
  do {
    try response.write(to: URL(fileURLWithPath: out))
  } catch {
    FileHandle.standardError.write(Data("AliasRunner tokenize: could not write \(out)\n".utf8))
    exit(2)
  }
  exit(0)
}

// MARK: - Upstream tokenizer experiment (#996 chunk 2b-ii)

/// The same request/response shape as the vendored door, answered by the
/// pinned upstream `swift-transformers` tokenizer (strict load from the local
/// folder). Pairs (#996 chunk 4a-ii) go through the SHIPPED
/// `PairEncodingAdapter` with the upstream tokenizer as its encode function,
/// so the parity check covers what the classifier arm will actually assemble:
/// specials, truncation and padding, not the bare token ids alone.
enum UpstreamTokenizerProbe {
  struct PairInput: Decodable {
    let input: String
    let output: String
  }
  struct Request: Decodable {
    let tokenizer_folder: String
    let texts: [String]
    let contract: String?
    let pairs: [PairInput]?
  }
  struct EncodedText: Encodable {
    let text: String
    let ids: [Int]
  }
  struct EncodedPair: Encodable {
    let input_ids: [Int32]
    let attention_mask: [Int32]
    let token_type_ids: [Int32]
  }
  struct Response: Encodable {
    let loaded: Bool
    let stack: String
    let error: String?
    let texts: [EncodedText]?
    let pairs: [EncodedPair]?
    let contract_error: String?
    let special_tokens: [String: Int]?
  }

  static func encode(requestJSON: Data) async -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func emit(_ r: Response) -> Data { (try? encoder.encode(r)) ?? Data() }
    let request: Request
    do {
      request = try JSONDecoder().decode(Request.self, from: requestJSON)
    } catch {
      return emit(Response(loaded: false, stack: "upstream-1.3.4", error: "request rejected: \(error)", texts: nil, pairs: nil, contract_error: nil, special_tokens: nil))
    }
    let folder = URL(fileURLWithPath: request.tokenizer_folder, isDirectory: true)
    let tokenizer: any Tokenizer
    do {
      tokenizer = try await AutoTokenizer.from(modelFolder: folder, strict: true)
    } catch {
      return emit(Response(loaded: false, stack: "upstream-1.3.4", error: "tokenizer load failed (strict): \(error)", texts: nil, pairs: nil, contract_error: nil, special_tokens: nil))
    }
    let texts = request.texts.map { EncodedText(text: $0, ids: tokenizer.encode(text: $0, addSpecialTokens: false)) }
    var specials: [String: Int] = [:]
    for name in ["<s>", "</s>", "<pad>", "[CLS]", "[SEP]", "[PAD]", "<bos>", "<eos>", "<unk>", "[UNK]"] {
      if let id = tokenizer.convertTokenToId(name) { specials[name] = id }
    }
    var pairs: [EncodedPair]? = nil
    var contractError: String? = nil
    if let contractPath = request.contract, let pairInputs = request.pairs {
      do {
        let encoded = try CorrectionJudgeBenchmark.encodePairs(
          contractJSON: try Data(contentsOf: URL(fileURLWithPath: contractPath)), pairs: pairInputs.map { ($0.input, $0.output) }
        ) { text in tokenizer.encode(text: text, addSpecialTokens: false) }
        pairs = encoded.map { EncodedPair(input_ids: $0.inputIDs, attention_mask: $0.attentionMask, token_type_ids: $0.tokenTypeIDs) }
      } catch {
        contractError = "contract rejected: \(error)"
      }
    }
    return emit(Response(loaded: true, stack: "upstream-1.3.4", error: nil, texts: texts, pairs: pairs, contract_error: contractError, special_tokens: specials))
  }
}

// MARK: - Trained classifier arm (#996 chunk 4a-ii)

/// `MLModel` is not `Sendable`; rows are judged sequentially by the kit, so
/// a single model behind an unchecked box is sound here (eval runner only).
final class ModelBox: @unchecked Sendable {
  let model: MLModel
  init(_ model: MLModel) { self.model = model }
  /// Synchronous overload on purpose: Core ML is not an actor and the async
  /// overload is what the compiler otherwise picks inside an async context.
  func predict(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
    try model.prediction(from: provider)
  }
}

/// A trained cross-encoder (mmBERT-small, XLM-R) answering a corpus row from
/// its Core ML export. The arm derives its execution identity from what it
/// LOADS, never from an unchecked manifest claim:
/// - the `.mlpackage` tree digest must equal `package_sha256` inside the
///   canonical decision configuration the converter wrote;
/// - the tokenizer folder's tree digest must equal the manifest's
///   `tokenizer_sha256`;
/// - `config_sha256` is recomputed by hashing `decision_config_canonical`,
///   the exact bytes the converter digested, and must match the manifest.
/// The checkpoint digest (PyTorch weights) cannot be recomputed from the
/// package; it is carried from the manifest and bound through
/// `package_sha256`, which the converter derived from that checkpoint.
/// Pairs are assembled by the SHIPPED `PairEncodingAdapter` through
/// `CorrectionJudgeBenchmark.encodePairs` with this runner's pinned upstream
/// tokenizer, the same path the trainer's parity check exercised.
struct ClassifierJudgeArm: JudgeArm {
  struct LoadError: Error, CustomStringConvertible {
    let description: String
  }

  static let detectionRule = "vocabulary_correction := p[1] >= detection_threshold; safe_alias := false"
  let candidate: JudgeCandidate
  let model: ModelBox
  let tokenizer: any Tokenizer
  /// The contract bytes whose digest was verified at load; the pair adapter
  /// is built from these, never from the file again.
  let contractJSON: Data
  let maxLength: Int
  let needsSegmentIDs: Bool
  let threshold: Double
  let identity: [String: String]

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Mirror of the trainer's `tree_digest`: every regular file under the
  /// folder, sorted by its relative POSIX path, path bytes then contents.
  static func treeDigest(_ folder: URL) throws -> String {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw LoadError(description: "cannot enumerate \(folder.path)")
    }
    var files: [(String, URL)] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let relative = url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)
      files.append((String(relative), url))
    }
    files.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    var hasher = SHA256()
    for (relative, url) in files {
      hasher.update(data: Data(relative.utf8))
      hasher.update(data: try Data(contentsOf: url))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func load(candidate: JudgeCandidate, manifestPath: String) async throws -> ClassifierJudgeArm {
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
      throw LoadError(description: "manifest is not a JSON object")
    }
    guard let judge = manifest["judge"] as? String, judge == candidate.rawValue else {
      throw LoadError(description: "manifest judge \(manifest["judge"] ?? "nil") is not \(candidate.rawValue)")
    }
    guard let canonical = manifest["decision_config_canonical"] as? String,
      let claimed = manifest["execution_identity"] as? [String: String],
      let packagePath = manifest["package"] as? String,
      let tokenizerPath = manifest["tokenizer"] as? String,
      let contractPath = manifest["contract"] as? String
    else {
      throw LoadError(description: "manifest lacks decision_config_canonical, execution_identity, package, tokenizer or contract (export with convert_edit_judge.py after 2026-09-19)")
    }
    let configDigest = sha256Hex(Data(canonical.utf8))
    guard configDigest == claimed["config_sha256"] else {
      throw LoadError(description: "decision_config_canonical hashes to \(configDigest), manifest claims \(claimed["config_sha256"] ?? "nil")")
    }
    guard let cfg = try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any] else {
      throw LoadError(description: "decision_config_canonical is not a JSON object")
    }
    guard cfg["objective"] as? String == "detection",
      cfg["class_order"] as? [String] == ["notCorrection", "correction"],
      cfg["decision_rule"] as? String == Self.detectionRule,
      let threshold = cfg["detection_threshold"] as? Double, threshold.isFinite, (0.0...1.0).contains(threshold),
      let packageDigestClaim = cfg["package_sha256"] as? String,
      let contractDigestClaim = cfg["contract_sha256"] as? String
    else {
      throw LoadError(description: "decision configuration is not a locked detection configuration this arm executes (objective detection, class_order [notCorrection, correction], rule \(Self.detectionRule), finite threshold in [0,1], package_sha256, contract_sha256)")
    }
    // The converter's verification receipt beside the manifest must record a
    // PASSING conversion for this exact package and identity; the converter
    // writes manifests for failed variants too.
    let verificationURL = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().appendingPathComponent("verification.json")
    guard let verification = try JSONSerialization.jsonObject(with: Data(contentsOf: verificationURL)) as? [String: Any],
      verification["all_placements_ok"] as? Bool == true,
      verification["package_sha256"] as? String == packageDigestClaim,
      (verification["execution_identity"] as? [String: String])?["config_sha256"] == claimed["config_sha256"]
    else {
      throw LoadError(description: "verification.json beside the manifest does not record a passing conversion for package \(packageDigestClaim.prefix(12))")
    }
    let packageURL = URL(fileURLWithPath: packagePath, isDirectory: true)
    let packageDigest = try treeDigest(packageURL)
    guard packageDigest == packageDigestClaim else {
      throw LoadError(description: "package tree digest \(packageDigest) differs from the bound \(packageDigestClaim)")
    }
    let tokenizerURL = URL(fileURLWithPath: tokenizerPath, isDirectory: true)
    let tokenizerDigest = try treeDigest(tokenizerURL)
    guard tokenizerDigest == claimed["tokenizer_sha256"] else {
      throw LoadError(description: "tokenizer tree digest \(tokenizerDigest) differs from the manifest's")
    }
    let contractData = try Data(contentsOf: URL(fileURLWithPath: contractPath))
    guard sha256Hex(contractData) == contractDigestClaim else {
      throw LoadError(description: "tokenizer contract digest differs from the bound contract_sha256")
    }
    // Prove the verified bytes decode and validate ONCE, before any row.
    _ = try CorrectionJudgeBenchmark.encodePairs(contractJSON: contractData, pairs: []) { _ in [] }
    guard let contract = try JSONSerialization.jsonObject(with: contractData) as? [String: Any],
      let maxLength = contract["maxLength"] as? Int,
      let tokenPolicy = contract["tokenTypePolicy"] as? [String: Any],
      let needsSegments = tokenPolicy["needsSegmentIds"] as? Bool
    else {
      throw LoadError(description: "tokenizer contract lacks maxLength or tokenTypePolicy")
    }
    guard let checkpoint = claimed["checkpoint_sha256"] else {
      throw LoadError(description: "manifest identity lacks checkpoint_sha256")
    }
    let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerURL, strict: true)
    let compiled = try await MLModel.compileModel(at: packageURL)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = ModelBox(try MLModel(contentsOf: compiled, configuration: configuration))
    return ClassifierJudgeArm(
      candidate: candidate, model: model, tokenizer: tokenizer, contractJSON: contractData,
      maxLength: maxLength, needsSegmentIDs: needsSegments, threshold: threshold,
      identity: ["checkpoint_sha256": checkpoint, "tokenizer_sha256": tokenizerDigest, "config_sha256": configDigest])
  }

  func loadedIdentity() async -> [String: String]? { identity }

  private func array(_ values: [Int32]) throws -> MLMultiArray {
    let arr = try MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32)
    for (i, v) in values.enumerated() { arr[i] = NSNumber(value: v) }
    return arr
  }

  func judge(row: EditCorpusRow) async -> JudgeRecord {
    let started = Date()
    let tokenizer = self.tokenizer
    let encoded: EncodedClassifierInput
    do {
      let pairs = try CorrectionJudgeBenchmark.encodePairs(
        contractJSON: contractJSON, pairs: [("\(row.original) → \(row.replacement)", row.pasted)]
      ) { text in tokenizer.encode(text: text, addSpecialTokens: false) }
      guard pairs.count == 1 else {
        return JudgeRecord(id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: 0, note: "adapter returned \(pairs.count) pairs", executionIdentity: identity)
      }
      encoded = pairs[0]
    } catch {
      return JudgeRecord(id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: 0, note: "pair encoding failed: \(error)", executionIdentity: identity)
    }
    do {
      var features: [String: MLFeatureValue] = [
        "input_ids": MLFeatureValue(multiArray: try array(encoded.inputIDs)),
        "attention_mask": MLFeatureValue(multiArray: try array(encoded.attentionMask)),
      ]
      if needsSegmentIDs {
        features["token_type_ids"] = MLFeatureValue(multiArray: try array(encoded.tokenTypeIDs))
      }
      let provider = try MLDictionaryFeatureProvider(dictionary: features)
      let prediction = try model.predict(provider)
      guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue, logits.count == 2 else {
        return JudgeRecord(id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: Date().timeIntervalSince(started) * 1000, note: "model returned no two-class logits", executionIdentity: identity)
      }
      let l0 = logits[0].doubleValue
      let l1 = logits[1].doubleValue
      guard l0.isFinite, l1.isFinite else {
        return JudgeRecord(id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: Date().timeIntervalSince(started) * 1000, note: "non-finite logits", executionIdentity: identity)
      }
      // softmax over two logits, p(correction) = p[1]
      let m = max(l0, l1)
      let p1 = exp(l1 - m) / (exp(l0 - m) + exp(l1 - m))
      let latency = Date().timeIntervalSince(started) * 1000
      // Detection rule (trainer DETECTION_RULE): vocabulary_correction := p[1] >= detection_threshold; safe_alias := false.
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .verdict,
        decision: JudgeDecision(vocabularyCorrection: p1 >= threshold, safeAlias: false),
        latencyMs: latency, note: nil, executionIdentity: identity)
    } catch {
      return JudgeRecord(id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: Date().timeIntervalSince(started) * 1000, note: "prediction failed: \(error)", executionIdentity: identity)
    }
  }
}

// MARK: - Stage-1 shape rule in front of every arm (#996, plan §3.1 step 5)

/// Wraps an arm with the shape rule: a run the planned path would never send
/// to a judge is answered `notCorrection` here with ZERO calls to the inner
/// judge. The record carries the COMBINED-PATH identity: the inner arm's
/// identity plus `shape_policy` and `path`, so judge-only and shape+judge
/// records are distinct configurations, and a manifest for the combined path
/// must declare the same keys (`training-manifest-shaped.json` from the
/// converter; hand-written for the untrained arms). Latency covers the shape
/// check and, when taken, the judge, on one monotonic clock.
struct StageOneShapeArm: JudgeArm {
  static let shapePolicy = "EditRunShape-v1"
  let inner: any JudgeArm
  let candidate: JudgeCandidate

  static func combined(_ identity: [String: String]?) -> [String: String]? {
    guard var id = identity else { return nil }
    id["shape_policy"] = shapePolicy
    id["path"] = "shape+judge"
    return id
  }

  func loadedIdentity() async -> [String: String]? {
    Self.combined(await inner.loadedIdentity())
  }

  func judge(row: EditCorpusRow) async -> JudgeRecord {
    let clock = ContinuousClock()
    let start = clock.now
    func elapsedMs() -> Double {
      let d = start.duration(to: clock.now)
      return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    if WordSuggestionService.benchmarkStageOneShapeDrop(original: row.original, replacement: row.replacement) {
      guard let identity = await loadedIdentity() else {
        return JudgeRecord(
          id: row.id, judge: candidate.rawValue, outcome: .malformed, decision: nil, latencyMs: elapsedMs(),
          note: "stage-1 shape drop, but the arm could not state its identity without inference", executionIdentity: nil)
      }
      return JudgeRecord(
        id: row.id, judge: candidate.rawValue, outcome: .verdict,
        decision: JudgeDecision(vocabularyCorrection: false, safeAlias: false),
        latencyMs: elapsedMs(),
        note: "stage-1 shape drop: casing or punctuation-only run (plan step 5); judge not consulted",
        executionIdentity: identity)
    }
    let inner = await inner.judge(row: row)
    return JudgeRecord(
      id: inner.id, judge: inner.judge, outcome: inner.outcome, decision: inner.decision,
      latencyMs: elapsedMs(), note: inner.note, executionIdentity: Self.combined(inner.executionIdentity))
  }
}

// MARK: - shape subcommand (#996 chunk 4a-ii)

/// `AliasRunner shape --request <json> --out <json>`: the stage-1 shape rule
/// as the shipped code evaluates it, for every pair in the request, so the
/// Python trainer can prove its mirror agrees on the actual dataset before
/// training (Codex 4a-ii round 2: two copied fixture lists are not a
/// contract). Request `{"pairs":[{"original":"…","replacement":"…"}]}`;
/// response `{"policy":"EditRunShape-v1","drops":[true,false,…]}`.
func runShape(_ argv: [String]) -> Never {
  var request: String?
  var out: String?
  var it = argv.makeIterator()
  while let arg = it.next() {
    switch arg {
    case "--request": request = it.next()
    case "--out": out = it.next()
    default:
      FileHandle.standardError.write(Data("AliasRunner shape: unknown argument \(arg)\n".utf8))
      exit(2)
    }
  }
  guard let request, let out, let data = FileManager.default.contents(atPath: request),
    let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let pairs = doc["pairs"] as? [[String: Any]]
  else {
    FileHandle.standardError.write(Data("usage: AliasRunner shape --request <json> --out <json>\n".utf8))
    exit(2)
  }
  var drops: [Bool] = []
  for p in pairs {
    guard let o = p["original"] as? String, let r = p["replacement"] as? String else {
      FileHandle.standardError.write(Data("AliasRunner shape: a pair lacks original/replacement strings\n".utf8))
      exit(2)
    }
    drops.append(WordSuggestionService.benchmarkStageOneShapeDrop(original: o, replacement: r))
  }
  let response: [String: Any] = ["policy": StageOneShapeArm.shapePolicy, "drops": drops]
  guard let bytes = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { exit(2) }
  do {
    try bytes.write(to: URL(fileURLWithPath: out))
  } catch {
    FileHandle.standardError.write(Data("AliasRunner shape: could not write \(out)\n".utf8))
    exit(2)
  }
  exit(0)
}
