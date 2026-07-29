// Verifies the output-safety classifier against the artifact a USER actually
// runs, on all four Core ML compute units (#1226).
//
// Why this exists. Every other check reads the source `.mlpackage` through
// coremltools or the Swift test suite. What ships is `OutputClassifier.mlmodelc`,
// produced by Xcode's Core ML build rule from that package — a different
// artifact, produced by a different tool. And the app loads it with the DEFAULT
// `MLModelConfiguration`, which lets Core ML place the model wherever it likes.
// Those two facts are why the FLOAT16 model shipped broken: it scored correctly
// on the Neural Engine and returned all-NaN on CPU-only / one constant value on
// CPU+GPU, so the classifier silently disabled itself on hardware that placed it
// elsewhere. Nothing caught it, because nothing ran anywhere but the default.
//
// The app now requests `.cpuAndNeuralEngine` explicitly, excluding the GPU on
// memory grounds (#1226). This probe still exercises all FOUR policies anyway,
// so a future conversion has to stay placement-independent rather than merely
// working on the one path we happen to ship.
//
// It asserts CORRECTNESS, not just liveness. Checking only for NaN and collapse
// would pass an artifact whose scores are finite but shifted or inverted, and
// this is the only check the shipped artifact gets — so it compares every row
// against the committed golden scores, on every compute unit.
//
// Run after any model change, against the built app:
//   swift scripts/uat/probe-classifier-compute-units.swift \
//     "build/EnviousWispr Local.app/Contents/Resources/OutputClassifier.mlmodelc" \
//     /path/to/repo
//
// Exits nonzero if any compute unit disagrees with the golden fixture.

import CoreML
import Foundation

// Matches `OutputClassifierGoldenScoreTests.probabilityTolerance`: ~38x the
// worst measured cross-compute spread (2.65e-06), and tight enough to catch the
// 1.6e-04 shift a precision change produces.
let probabilityTolerance = 1e-4

/// The committed parity/golden fixtures are both 50 rows, and so is the Swift
/// suite's own assertion. Pinned here so a shrunken fixture fails loudly instead
/// of quietly reducing what this probe covers.
let expectedRowCount = 50

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  FileHandle.standardError.write(
    Data("usage: probe-classifier-compute-units.swift <model.mlmodelc> <repo-root>\n".utf8))
  exit(2)
}
let modelURL = URL(fileURLWithPath: arguments[1])
let repoRoot = URL(fileURLWithPath: arguments[2])

let fixtures = repoRoot.appending(path: "Tests/EnviousWisprTests/Resources/OutputClassifier")
let pretokenizedURL = fixtures.appending(path: "MiniLM-L6.parity50.pretokenized.jsonl")
let goldenURL = fixtures.appending(path: "MiniLM-L6.golden-scores.jsonl")
let manifestURL = repoRoot.appending(path: "Sources/EnviousWisprLLM/OutputClassifierManifest.swift")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(2)
}

struct PretokenizedRow: Decodable {
  let id: String
  let input_ids: [Int32]
  let attention_mask: [Int32]
  let token_type_ids: [Int32]?
}
struct GoldenRow: Decodable {
  let id: String
  let prob: Double
  let decision: String
}

/// Decodes strictly and FAILS CLOSED. An earlier version used `try?` and dropped
/// undecodable lines silently, so a truncated or malformed fixture could leave a
/// handful of rows and still report a confident pass — on the only correctness
/// check the shipped `.mlmodelc` gets. A verifier that quietly tests less than it
/// claims is worse than no verifier.
func loadJSONL<T: Decodable>(_ url: URL, as: T.Type) -> [T] {
  guard let text = try? String(contentsOf: url, encoding: .utf8) else {
    fail("cannot read \(url.path)")
  }
  var decoded: [T] = []
  for (index, line) in text.split(separator: "\n").enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8) else {
      fail("\(url.lastPathComponent) line \(index + 1): not valid UTF-8")
    }
    do {
      decoded.append(try JSONDecoder().decode(T.self, from: data))
    } catch {
      fail("\(url.lastPathComponent) line \(index + 1): \(error)")
    }
  }
  return decoded
}

// Read the threshold from the Swift manifest rather than copying it — a stale
// copy here would quietly compare decisions against the wrong boundary and still
// report a confident pass.
guard let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8),
  let declaration = manifestText.split(separator: "\n").first(where: {
    $0.contains("static let discardThreshold")
  }),
  let rawValue = declaration.split(separator: "=").last,
  let discardThreshold = Double(rawValue.trimmingCharacters(in: .whitespaces))
else {
  fail("could not read discardThreshold from \(manifestURL.path)")
}

let rows = loadJSONL(pretokenizedURL, as: PretokenizedRow.self)
let golden = loadJSONL(goldenURL, as: GoldenRow.self)
// Assert the EXPECTED count, not merely "some rows". "At least one row" would let
// a shrunken fixture pass while testing almost nothing.
guard rows.count == expectedRowCount else {
  fail("expected \(expectedRowCount) pretokenized rows, decoded \(rows.count)")
}
// A count alone is satisfied by a DUPLICATE that replaced another row: the total
// still reads 50, every id still resolves in the golden map, and the probe
// silently scores one case twice while omitting another. Identity, not just count.
guard Set(rows.map(\.id)).count == expectedRowCount else {
  fail(
    "pretokenized fixture has duplicate ids: \(rows.count) rows, "
      + "\(Set(rows.map(\.id)).count) unique")
}
guard golden.count == expectedRowCount else {
  fail("expected \(expectedRowCount) golden rows, decoded \(golden.count)")
}
// Check uniqueness BEFORE building the dictionary: `uniqueKeysWithValues` traps
// on a duplicate key, which would crash with a runtime fault instead of saying
// what is wrong with the fixture.
guard Set(golden.map(\.id)).count == expectedRowCount else {
  fail(
    "golden fixture has duplicate ids: \(golden.count) rows, \(Set(golden.map(\.id)).count) unique")
}
let goldenByID = Dictionary(uniqueKeysWithValues: golden.map { ($0.id, $0) })
for row in rows where goldenByID[row.id] == nil {
  fail(
    "no golden score for row \(row.id) — regenerate with scripts/emit-output-classifier-golden.py")
}

func multiArray(_ values: [Int32]) throws -> MLMultiArray {
  let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
  for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
  return array
}

print("artifact:  \(modelURL.path)")
print("rows:      \(rows.count)   threshold: \(discardThreshold)\n")
print("compute unit          nan  worst drift  decision mismatches  verdict")
print(String(repeating: "-", count: 78))

var broken = false
for (name, unit): (String, MLComputeUnits) in [
  ("ALL", .all), ("CPU_ONLY", .cpuOnly),
  ("CPU_AND_GPU", .cpuAndGPU), ("CPU_AND_NE (app)", .cpuAndNeuralEngine),
] {
  let configuration = MLModelConfiguration()
  configuration.computeUnits = unit
  guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
    print("\(name): LOAD FAILED")
    broken = true
    continue
  }

  var nanCount = 0
  var worstDrift = 0.0
  var mismatches: [String] = []
  for row in rows {
    guard let expected = goldenByID[row.id] else { continue }
    var probability = Double.nan
    do {
      var features: [String: Any] = [
        "input_ids": try multiArray(row.input_ids),
        "attention_mask": try multiArray(row.attention_mask),
      ]
      if let tokenTypes = row.token_type_ids {
        features["token_type_ids"] = try multiArray(tokenTypes)
      }
      let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
      if let logit = output.featureValue(for: "logits")?.multiArrayValue?[0].doubleValue {
        probability = 1.0 / (1.0 + exp(-logit))
      }
    } catch {
      probability = .nan
    }
    guard probability.isFinite else {
      nanCount += 1
      continue
    }
    worstDrift = max(worstDrift, abs(probability - expected.prob))
    let decision = probability >= discardThreshold ? "DISCARD" : "KEEP"
    if decision != expected.decision { mismatches.append(row.id) }
  }

  let drifted = worstDrift > probabilityTolerance
  let verdict: String
  if nanCount == rows.count {
    verdict = "BROKEN - all NaN"
  } else if nanCount > 0 {
    verdict = "BROKEN - \(nanCount) NaN"
  } else if !mismatches.isEmpty {
    verdict = "BROKEN - decisions differ: \(mismatches.prefix(3).joined(separator: ", "))"
  } else if drifted {
    verdict = "BROKEN - drift exceeds \(probabilityTolerance)"
  } else {
    verdict = "ok - matches golden scores"
  }
  if verdict != "ok - matches golden scores" { broken = true }
  print(
    name.padding(toLength: 20, withPad: " ", startingAt: 0)
      + String(
        format: "%5d %12.3e %20d  %@", nanCount, worstDrift, mismatches.count,
        verdict as NSString))
}

if broken {
  print(
    "\nFAILED: the shipped artifact does not reproduce the golden scores on every compute unit.")
  exit(1)
}
print(
  "\nPASSED: all four compute units reproduce the golden scores within \(probabilityTolerance).")
