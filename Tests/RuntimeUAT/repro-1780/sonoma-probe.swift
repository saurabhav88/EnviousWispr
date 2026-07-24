import Accelerate
import CoreML
import Darwin
import Foundation

// Sonoma probe for #1780.
//
// The macOS 14 runner ships Swift 5.10 and FluidAudio requires swift-tools 6.0,
// so the library cannot be built there. This file therefore PORTS the exact
// input-preparation FluidAudio performs — that is the part inside the fault
// path; the crash itself is in Apple's Espresso/BNNS code reached from
// MLModel.prediction, not in FluidAudio's Swift.
//
// Ported verbatim in behaviour from
// FluidAudio/Sources/FluidAudio/Shared/ANEMemoryUtils.swift (createAlignedArray,
// calculateOptimalStrides) and VAD/VadManager.swift (processUnifiedModel):
//   * posix_memalign, 64-byte alignment, size rounded up to 64
//   * tile-padded strides (aneTileSize = 16)
//   * buffers POOLED and reused across predictions
//   * recurrent state fed back each step
//
// This is a faithful port, not the library binary. Stated plainly so no result
// from it is read as more than it is.

let aneAlignment = 64
let aneTileSize = 16

func elementSize(_ t: MLMultiArrayDataType) -> Int { t == .float32 ? 4 : 8 }

func optimalStrides(for shape: [NSNumber]) -> [NSNumber] {
  var strides: [Int] = []
  var currentStride = 1
  for i in (0..<shape.count).reversed() {
    strides.insert(currentStride, at: 0)
    let dimSize = shape[i].intValue
    if i == shape.count - 1 && dimSize % aneTileSize != 0 {
      currentStride *= ((dimSize + aneTileSize - 1) / aneTileSize) * aneTileSize
    } else {
      currentStride *= dimSize
    }
  }
  return strides.map { NSNumber(value: $0) }
}

func createAlignedArray(shape: [NSNumber], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
  let esize = elementSize(dataType)
  let strides = optimalStrides(for: shape)
  let totalElements = shape.isEmpty ? 0 : strides[0].intValue * shape[0].intValue
  let bytesNeeded = totalElements * esize
  let alignedBytes = max(
    aneAlignment, ((bytesNeeded + aneAlignment - 1) / aneAlignment) * aneAlignment)
  var p: UnsafeMutableRawPointer?
  guard posix_memalign(&p, aneAlignment, alignedBytes) == 0, let ptr = p else {
    fatalError("posix_memalign failed")
  }
  memset(ptr, 0, alignedBytes)
  return try MLMultiArray(
    dataPointer: ptr, shape: shape, dataType: dataType, strides: strides,
    deallocator: { Darwin.free($0) })
}

let modelPath =
  ProcessInfo.processInfo.environment["VAD_MODEL"]
  ?? "Sources/EnviousWispr/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc"
let unitsName = ProcessInfo.processInfo.environment["UNITS"] ?? "all"
let iterations = Int(ProcessInfo.processInfo.environment["ITERS"] ?? "800") ?? 800
let workers = Int(ProcessInfo.processInfo.environment["PARALLEL"] ?? "4") ?? 4
let churnEvery = Int(ProcessInfo.processInfo.environment["CHURN_EVERY"] ?? "0") ?? 0

func units(_ n: String) -> MLComputeUnits {
  switch n {
  case "cpuOnly": return .cpuOnly
  case "cpuAndGPU": return .cpuAndGPU
  case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
  default: return .all
  }
}

// modelInputSize 4160 = contextSize 64 + chunkSize 4096, per VadManager.
let inputSize = 4160
let stateSize = 128

func worker(_ w: Int) {
  do {
    func loadModel() throws -> MLModel {
      let c = MLModelConfiguration()
      c.computeUnits = units(unitsName)
      return try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: c)
    }
    var model = try loadModel()
    var audio = try createAlignedArray(shape: [1, NSNumber(value: inputSize)], dataType: .float32)
    var hidden = try createAlignedArray(shape: [1, NSNumber(value: stateSize)], dataType: .float32)
    var cell = try createAlignedArray(shape: [1, NSNumber(value: stateSize)], dataType: .float32)

    for i in 0..<iterations {
      if churnEvery > 0 && i > 0 && i % churnEvery == 0 {
        model = try loadModel()
        audio = try createAlignedArray(shape: [1, NSNumber(value: inputSize)], dataType: .float32)
        hidden = try createAlignedArray(shape: [1, NSNumber(value: stateSize)], dataType: .float32)
        cell = try createAlignedArray(shape: [1, NSNumber(value: stateSize)], dataType: .float32)
      }

      // Same write pattern as processUnifiedModel: clear, then fill.
      let ap = audio.dataPointer.assumingMemoryBound(to: Float.self)
      vDSP_vclr(ap, 1, vDSP_Length(inputSize))
      let speaking = ((i + w) / 8) % 2 == 0
      for n in 0..<inputSize {
        let t = Float(i &* inputSize &+ n) / 16000.0
        var v = Float.random(in: -0.002...0.002)
        if speaking {
          v += 0.28 * sin(2 * .pi * 150 * t) + 0.12 * sin(2 * .pi * 900 * t)
        }
        ap[n] = v
      }

      let input = try MLDictionaryFeatureProvider(dictionary: [
        "audio_input": audio, "hidden_state": hidden, "cell_state": cell,
      ])
      let out = try model.prediction(from: input)

      // Feed recurrent state back, as the streaming path does.
      if let nh = out.featureValue(for: "new_hidden_state")?.multiArrayValue,
        let nc = out.featureValue(for: "new_cell_state")?.multiArrayValue
      {
        let hp = hidden.dataPointer.assumingMemoryBound(to: Float.self)
        let cp = cell.dataPointer.assumingMemoryBound(to: Float.self)
        let nhp = nh.dataPointer.assumingMemoryBound(to: Float.self)
        let ncp = nc.dataPointer.assumingMemoryBound(to: Float.self)
        for k in 0..<stateSize {
          hp[k] = nhp[k]
          cp[k] = ncp[k]
        }
      }

      if w == 0 && i % 200 == 0 {
        print("  iter \(i) ok")
        fflush(stdout)
      }
    }
  } catch {
    print("worker \(w) threw: \(error)")
    exit(2)
  }
}

print(
  "UNITS=\(unitsName) iters=\(iterations) workers=\(workers) churnEvery=\(churnEvery) — starting")
fflush(stdout)
if workers <= 1 {
  worker(0)
} else {
  DispatchQueue.concurrentPerform(iterations: workers) { worker($0) }
}
print("UNITS=\(unitsName) SURVIVED \(iterations) iters x\(workers) workers")
