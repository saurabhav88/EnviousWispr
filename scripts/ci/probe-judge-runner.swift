// Probe: can a hosted GitHub macOS runner run the delivered correction judge
// (#996)? Loads the fp16 package the way `CoreMLCorrectionJudge` does
// (`.cpuAndNeuralEngine`), plus `.cpuOnly` and `.all` for comparison, runs one
// fixed prediction per unit, and prints which compute devices the VM exposes
// and where Core ML placed the model's operations. Output is one JSON object
// per line so the workflow log is greppable. Not part of the app.
//
// Usage: probe-judge-runner <path/to/xenc-mmbert-small-fp16.mlpackage>
import CoreML
import Foundation

struct ProbeError: Error, CustomStringConvertible {
  let description: String
}

func emit(_ object: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  fflush(stdout)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(
    "usage: probe-judge-runner <package.mlpackage>\n".data(using: .utf8)!)
  exit(2)
}
let packageURL = URL(fileURLWithPath: arguments[1])
let osVersion = ProcessInfo.processInfo.operatingSystemVersion

// Which devices does this machine (or VM) expose to Core ML at all?
var devices: [String] = []
if #available(macOS 14.0, *) {
  devices = MLComputeDevice.allComputeDevices.map { device in
    switch device {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "neuralEngine"
    @unknown default: return "unknown"
    }
  }
}
emit([
  "probe": "devices",
  "os": "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
  "computeDevices": devices,
])

let compileStart = Date()
let compiledURL: URL
do {
  compiledURL = try MLModel.compileModel(at: packageURL)
} catch {
  emit(["probe": "compile", "ok": false, "error": "\(error)"])
  exit(1)
}
emit(["probe": "compile", "ok": true, "seconds": Date().timeIntervalSince(compileStart)])

// The export is fixed-shape [1, 128] int32 for both features
// (`convert_edit_judge.py`). A short synthetic edit, then padding with an
// attention mask of zero, is enough to prove load, placement and a finite
// result; the decision itself is not under test here.
let maxLength = 128
func multiArray(_ values: [Int32]) throws -> MLMultiArray {
  let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
  for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
  return array
}
var inputIDs = [Int32](repeating: 0, count: maxLength)
var attentionMask = [Int32](repeating: 0, count: maxLength)
let tokens: [Int32] = [1, 20851, 2385, 4711, 302, 9985, 2]
for (index, token) in tokens.enumerated() {
  inputIDs[index] = token
  attentionMask[index] = 1
}
let features = try MLDictionaryFeatureProvider(dictionary: [
  "input_ids": MLFeatureValue(multiArray: try multiArray(inputIDs)),
  "attention_mask": MLFeatureValue(multiArray: try multiArray(attentionMask)),
])

let units: [(String, MLComputeUnits)] = [
  ("cpuOnly", .cpuOnly),
  ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
  ("all", .all),
]

@available(macOS 14.4, *)
func placement(compiledURL: URL, configuration: MLModelConfiguration) async -> [String: Int] {
  var counts: [String: Int] = [:]
  do {
    let plan = try await MLComputePlan.load(contentsOf: compiledURL, configuration: configuration)
    guard case .program(let program) = plan.modelStructure,
      let main = program.functions["main"]
    else { return ["notAProgram": 1] }
    func walk(_ block: MLModelStructure.Program.Block) {
      for operation in block.operations {
        if let usage = plan.deviceUsage(for: operation) {
          let label: String
          switch usage.preferred {
          case .cpu: label = "cpu"
          case .gpu: label = "gpu"
          case .neuralEngine: label = "neuralEngine"
          @unknown default: label = "unknown"
          }
          counts[label, default: 0] += 1
        } else {
          counts["unplaced", default: 0] += 1
        }
        for inner in operation.blocks { walk(inner) }
      }
    }
    walk(main.block)
  } catch {
    counts["planError"] = 1
    emit(["probe": "placementError", "error": "\(error)"])
  }
  return counts
}

var logitsByUnit: [String: [Double]] = [:]
let group = DispatchGroup()
group.enter()
Task {
  for (label, unit) in units {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = unit
    let loadStart = Date()
    let model: MLModel
    do {
      model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    } catch {
      emit(["probe": "load", "unit": label, "ok": false, "error": "\(error)"])
      continue
    }
    let loadSeconds = Date().timeIntervalSince(loadStart)
    var placed: [String: Int] = [:]
    if #available(macOS 14.4, *) {
      placed = await placement(compiledURL: compiledURL, configuration: configuration)
    }
    do {
      _ = try await model.prediction(from: features)  // warm
      var latencies: [Double] = []
      var logits: [Double] = []
      for _ in 0..<10 {
        let start = Date()
        let output = try await model.prediction(from: features)
        latencies.append(Date().timeIntervalSince(start) * 1000)
        guard let name = output.featureNames.first,
          let array = output.featureValue(for: name)?.multiArrayValue
        else { throw ProbeError(description: "no multiarray output") }
        logits = (0..<array.count).map { array[$0].doubleValue }
      }
      logitsByUnit[label] = logits
      emit([
        "probe": "predict", "unit": label, "ok": true,
        "loadSeconds": loadSeconds,
        "latencyMsP50": latencies.sorted()[latencies.count / 2],
        "logits": logits,
        "finite": logits.allSatisfy { $0.isFinite },
        "placement": placed,
      ])
    } catch {
      emit([
        "probe": "predict", "unit": label, "ok": false, "error": "\(error)", "placement": placed,
      ])
    }
  }
  if let reference = logitsByUnit["cpuOnly"] {
    for (label, logits) in logitsByUnit where label != "cpuOnly" {
      let drift = zip(reference, logits).map { abs($0 - $1) }.max() ?? .nan
      let argmaxReference = reference.indices.max { reference[$0] < reference[$1] }
      let argmaxThis = logits.indices.max { logits[$0] < logits[$1] }
      emit([
        "probe": "parity", "unit": label, "versus": "cpuOnly",
        "maxAbsDrift": drift, "argmaxFlip": argmaxReference != argmaxThis,
      ])
    }
  }
  group.leave()
}
group.wait()
