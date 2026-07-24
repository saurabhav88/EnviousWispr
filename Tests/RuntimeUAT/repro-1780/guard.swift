import CoreML
import Foundation

// Hypothesis: Apple's compute kernels over-read past the end of an exactly-sized
// input buffer. Normally harmless (the next bytes are mapped heap). It only
// faults when the allocation ends exactly at a page boundary and the next page
// is unmapped — which is what a page-aligned KERN_INVALID_ADDRESS looks like.
//
// Test: place each input so its LAST byte is the last byte of a mapped page,
// with an unmapped guard page immediately after. Any over-read faults here.

let pageSize = Int(getpagesize())
print("page size: \(pageSize)")

func guardedBuffer(byteCount: Int) -> UnsafeMutableRawPointer {
  let dataPages = (byteCount + pageSize - 1) / pageSize
  let total = (dataPages + 1) * pageSize
  let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)!
  precondition(base != MAP_FAILED)
  // Unmap the trailing guard page.
  precondition(mprotect(base.advanced(by: dataPages * pageSize), pageSize, PROT_NONE) == 0)
  // Right-align the data so its final byte is the last mapped byte.
  return base.advanced(by: dataPages * pageSize - byteCount)
}

func makeArray(shape: [NSNumber], fill: Float) throws -> MLMultiArray {
  let count = shape.reduce(1) { $0 * $1.intValue }
  let bytes = count * MemoryLayout<Float>.size
  let ptr = guardedBuffer(byteCount: bytes)
  ptr.assumingMemoryBound(to: Float.self).update(repeating: fill, count: count)
  var strides: [NSNumber] = []
  var acc = 1
  for d in shape.reversed() { strides.insert(NSNumber(value: acc), at: 0); acc *= d.intValue }
  return try MLMultiArray(dataPointer: ptr, shape: shape, dataType: .float32,
                          strides: strides, deallocator: nil)
}

let modelPath = ProcessInfo.processInfo.environment["VAD_MODEL"] ?? "Sources/EnviousWispr/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc"
let unitsName = ProcessInfo.processInfo.environment["UNITS"] ?? "cpuOnly"
let cfg = MLModelConfiguration()
cfg.computeUnits = unitsName == "cpuOnly" ? .cpuOnly
  : unitsName == "cpuAndGPU" ? .cpuAndGPU
  : unitsName == "cpuAndNeuralEngine" ? .cpuAndNeuralEngine : .all

let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: cfg)

let audio = try makeArray(shape: [1, 4160], fill: 0.05)
let hidden = try makeArray(shape: [1, 128], fill: 0.0)
let cell = try makeArray(shape: [1, 128], fill: 0.0)

print("UNITS=\(unitsName): buffers guard-page-aligned; running predictions…")
fflush(stdout)

let input = try MLDictionaryFeatureProvider(dictionary: [
  "audio_input": audio, "hidden_state": hidden, "cell_state": cell,
])
for i in 0..<50 {
  _ = try model.prediction(from: input)
  if i == 0 { print("  first prediction ok"); fflush(stdout) }
}
print("UNITS=\(unitsName) SURVIVED guard-page test")
