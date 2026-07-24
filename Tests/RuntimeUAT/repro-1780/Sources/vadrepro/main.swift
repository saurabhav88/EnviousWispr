import CoreML
import FluidAudio
import Foundation

// Drives the REAL FluidAudio VadManager with the REAL bundled model, using the
// exact call shape SilenceDetector.processChunk makes. Varies computeUnits to
// test whether the CPU/BNNS path (the one in the crash stack) faults.

let modelPath =
  ProcessInfo.processInfo.environment["VAD_MODEL"]
  ?? "Sources/EnviousWispr/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc"

let chunkSize = 4096
let chunks = Int(ProcessInfo.processInfo.environment["CHUNKS"] ?? "400")!
let unitsName = ProcessInfo.processInfo.environment["UNITS"] ?? "all"

let units: MLComputeUnits = {
  switch unitsName {
  case "cpuOnly": return .cpuOnly
  case "cpuAndGPU": return .cpuAndGPU
  case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
  default: return .all
  }
}()

// Speech-like signal: sweeping tone + noise, so VAD actually transitions
// between speech and silence rather than sitting in one state.
func makeChunk(_ i: Int) -> [Float] {
  var out = [Float](repeating: 0, count: chunkSize)
  let speaking = (i / 8) % 2 == 0
  for n in 0..<chunkSize {
    let t = Float(i * chunkSize + n) / 16000.0
    var v = Float.random(in: -0.002...0.002)
    if speaking {
      v += 0.28 * sin(2 * .pi * (140 + 40 * sin(t * 2)) * t)
      v += 0.12 * sin(2 * .pi * 900 * t)
    }
    out[n] = v
  }
  return out
}

let cfg = MLModelConfiguration()
cfg.computeUnits = units
let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: cfg)

_ = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
let segConfig = VadSegmentationConfig(
  minSpeechDuration: 0.3, minSilenceDuration: 1.5, speechPadding: 0.0)

let parallel = Int(ProcessInfo.processInfo.environment["PARALLEL"] ?? "1")!
let churn = ProcessInfo.processInfo.environment["CHURN"] == "1"

print("UNITS=\(unitsName) chunks=\(chunks) parallel=\(parallel) churn=\(churn) — starting")
fflush(stdout)

// Each worker gets its own model + manager, mirroring how SilenceDetector builds
// one per detector instance. `churn` rebuilds the manager mid-run, mirroring the
// rebuild that happens when the silence timeout changes.
func runWorker(
  _ w: Int, units: MLComputeUnits, modelPath: String, segConfig: VadSegmentationConfig, chunks: Int,
  churn: Bool
) async throws -> Int {
  func freshConfig() -> MLModelConfiguration {
    let c = MLModelConfiguration()
    c.computeUnits = units
    return c
  }
  var localModel = try MLModel(
    contentsOf: URL(fileURLWithPath: modelPath), configuration: freshConfig())
  var vad = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: localModel)
  var state = VadStreamState.initial()
  var events = 0
  for i in 0..<chunks {
    if churn && i > 0 && i % 50 == 0 {
      localModel = try MLModel(
        contentsOf: URL(fileURLWithPath: modelPath), configuration: freshConfig())
      vad = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: localModel)
      state = VadStreamState.initial()
    }
    let result = try await vad.processStreamingChunk(
      makeChunk(i &+ w &* 7), state: state, config: segConfig,
      returnSeconds: false, timeResolution: 1)
    state = result.state
    if result.event != nil { events += 1 }
    if w == 0 && i % 100 == 0 {
      print("  chunk \(i) ok")
      fflush(stdout)
    }
  }
  return events
}

var totalEvents = 0
try await withThrowingTaskGroup(of: Int.self) { group in
  for w in 0..<parallel {
    group.addTask { [units, modelPath, segConfig, chunks, churn] in
      try await runWorker(
        w, units: units, modelPath: modelPath, segConfig: segConfig,
        chunks: chunks, churn: churn)
    }
  }
  for try await e in group { totalEvents += e }
}
print(
  "UNITS=\(unitsName) SURVIVED \(chunks) chunks x\(parallel) workers, \(totalEvents) boundary events"
)
