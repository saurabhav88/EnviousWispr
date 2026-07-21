// AliasRunner — drives the shipped WordSuggestionService over a JSONL corpus
// and emits one JSONL record per case with raw aliases, filtered aliases,
// timing, and error metadata. Invoked by scripts/eval/alias_suggestion_gate.py.
// See issue #637.

import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

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
