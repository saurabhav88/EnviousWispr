import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: the EnviousDecode engine drafts several tokens, lets the model check them in one
/// pass and keeps only the tokens the model agrees with. The model's linear-attention layers
/// carry a memory that the check pass moves past every drafted token, so after a partial
/// agreement that memory must go back to exactly "after the last agreed token". The tape kernels
/// and `RecurrentRollbackCache` do that.
///
/// When this fails, the user sees wrong words in polished text and no error: the memory is a
/// little off after a rejected draft, every later token is computed from it, and the text still
/// reads well. Nothing crashes and nothing is logged. So these checks compare the restored
/// memory with the library's ordinary step-by-step computation, which uses no tape and no
/// kernel of ours.
@Suite(
  "DFlash tape and rollback restore the model's memory after a rejected draft (#4473)",
  .serialized, .tags(.productOutcome))
struct DFlashTapeRollbackTests {
  struct Layout: Sendable {
    let name: String
    let steps: Int
    let keyHeads: Int
    let valueHeads: Int
    let keyDim: Int
    let valueDim: Int
    /// The width of the layer's conv input: the q, k and v projections side by side.
    var rawDim: Int { 2 * keyHeads * keyDim + valueHeads * valueDim }
  }

  /// `research`: the layout of the research check this suite adapts (`checkTapeState`).
  /// `grouped`: two value heads share each key head, and a key spans two values per GPU lane.
  /// `mini`: the shipped EG-1 Mini layer (its config.json: 16 key heads, 16 value heads, 128 by
  /// 128, conv kernel 4).
  static let layouts = [
    Layout(name: "research", steps: 16, keyHeads: 1, valueHeads: 1, keyDim: 128, valueDim: 4),
    Layout(name: "grouped", steps: 16, keyHeads: 2, valueHeads: 4, keyDim: 64, valueDim: 8),
    Layout(name: "mini", steps: 16, keyHeads: 16, valueHeads: 16, keyDim: 128, valueDim: 128),
  ]
  /// Drafted tokens the model agreed with, from the research check: none, some, all of a pass.
  static let acceptedCounts = [0, 6, 15]
  /// Steps a mask switches off. Step 3 lies inside the 7-step replay, so that replay skips one.
  static let maskedSteps: Set<Int> = [3, 9, 10]
  /// The research check's bound for the float32 memory. Kept; the measured errors are printed.
  static let stateTolerance: Float = 1e-5

  /// One check pass's inputs, in float32. Built from index arithmetic, so every run and both
  /// devices get the same numbers and no random generator is involved.
  struct Inputs {
    var q: MLXArray
    var k: MLXArray
    var v: MLXArray
    let a: MLXArray
    let b: MLXArray
    let aLog: MLXArray
    let dtBias: MLXArray
    let initial: MLXArray
    var conv: MLXArray
    var raw: MLXArray

    /// The same inputs holding only values the activation format can carry. The kernel gets
    /// them in that format; the reference gets these float32 copies, which are equal in value.
    func rounded(to activation: DType) -> Inputs {
      var copy = self
      copy.q = q.asType(activation).asType(.float32)
      copy.k = k.asType(activation).asType(.float32)
      copy.v = v.asType(activation).asType(.float32)
      copy.conv = conv.asType(activation).asType(.float32)
      copy.raw = raw.asType(activation).asType(.float32)
      eval(copy.q, copy.k, copy.v, copy.conv, copy.raw)
      return copy
    }
  }

  static func wave(_ shape: [Int], scale: Float, step: Float, phase: Float) -> MLXArray {
    let count = shape.reduce(1, *)
    let index = MLXArray(Array(0..<count)).asType(.float32)
    return (sin(index * step + phase) * scale).reshaped(shape)
  }

  /// `variant` shifts every phase, so two variants are two unrelated passes.
  static func inputs(_ layout: Layout, variant: Float = 0) -> Inputs {
    Device.withDefaultDevice(.cpu) {
      let (t, hk, hv, dk, dv) = (
        layout.steps, layout.keyHeads, layout.valueHeads, layout.keyDim, layout.valueDim
      )
      // Keys near unit length, as the layer's normalised keys are, so the memory stays bounded.
      let keyScale = Float(1.2 / Double(dk).squareRoot())
      let inputs = Inputs(
        q: wave([1, t, hk, dk], scale: keyScale, step: 0.37, phase: 0.1 + variant),
        k: wave([1, t, hk, dk], scale: keyScale, step: 0.53, phase: 0.7 + variant),
        v: wave([1, t, hv, dv], scale: 0.3, step: 0.71, phase: 1.3 + variant),
        a: wave([1, t, hv], scale: 1.0, step: 0.91, phase: 0.2 + variant),
        b: wave([1, t, hv], scale: 1.0, step: 1.13, phase: 0.5 + variant),
        aLog: wave([hv], scale: 0.2, step: 1.7, phase: 0.3),
        dtBias: wave([hv], scale: 0.2, step: 2.3, phase: 0.9),
        initial: wave([1, hv, dv, dk], scale: 0.1, step: 0.19, phase: 0.4),
        conv: wave([1, 3, layout.rawDim], scale: 1.0, step: 0.29, phase: 2.1),
        raw: wave([1, t, layout.rawDim], scale: 1.0, step: 0.43, phase: 1.9 + variant))
      eval(
        inputs.q, inputs.k, inputs.v, inputs.a, inputs.b, inputs.aLog, inputs.dtBias,
        inputs.initial, inputs.conv, inputs.raw)
      return inputs
    }
  }

  static func mask(steps: Int) -> MLXArray {
    MLXArray((0..<steps).map { !maskedSteps.contains($0) }).reshaped([1, steps])
  }

  /// Receives the gate and beta the library derives from `a` and `b`. The kernels take those
  /// two directly, and this hands them the library's own values, so the test re-implements no
  /// formula of the layer.
  final class GateCapture: GatedDeltaTapeCache {
    private(set) var gate: MLXArray?
    private(set) var beta: MLXArray?
    var isArmed: Bool { true }

    func gatedDeltaWithTape(
      q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray,
      mask: MLXArray?
    ) -> (MLXArray, MLXArray, MLXArray) {
      gate = g
      self.beta = beta
      return (MLXArray.zeros(v.shape, dtype: q.dtype), state, MLXArray.zeros(v.shape))
    }

    func recordTape(tape: MLXArray, k: MLXArray, g: MLXArray, qkv: MLXArray) {}
  }

  static func libraryGateAndBeta(_ inputs: Inputs) throws -> (gate: MLXArray, beta: MLXArray) {
    let capture = GateCapture()
    _ = Device.withDefaultDevice(.cpu) {
      gatedDeltaUpdate(
        q: inputs.q, k: inputs.k, v: inputs.v, a: inputs.a, b: inputs.b, aLog: inputs.aLog,
        dtBias: inputs.dtBias, state: inputs.initial, recordingCache: capture,
        projectedQKV: inputs.raw)
    }
    let gate = try #require(capture.gate)
    let beta = try #require(capture.beta)
    eval(gate, beta)
    return (gate, beta)
  }

  /// The reference: the library's ordinary gated-delta steps over the first `steps` tokens, on
  /// the CPU, with no tape and no custom kernel (`useKernel: false`).
  static func reference(
    _ inputs: Inputs, steps: Int, from state: MLXArray, mask: MLXArray?
  ) -> (y: MLXArray, state: MLXArray) {
    Device.withDefaultDevice(.cpu) {
      let (y, next) = gatedDeltaUpdate(
        q: inputs.q[0..., ..<steps, 0..., 0...], k: inputs.k[0..., ..<steps, 0..., 0...],
        v: inputs.v[0..., ..<steps, 0..., 0...], a: inputs.a[0..., ..<steps, 0...],
        b: inputs.b[0..., ..<steps, 0...], aLog: inputs.aLog, dtBias: inputs.dtBias,
        state: state, mask: mask.map { $0[0..., ..<steps] }, useKernel: false)
      eval(y, next)
      return (y, next)
    }
  }

  /// A different shape is a difference. MLX stops the whole test process on two shapes it
  /// cannot broadcast, so the shapes are compared first and a mismatch is reported as infinite.
  static func maxAbsDifference(_ a: MLXArray, _ b: MLXArray) -> Float {
    guard a.shape == b.shape else { return .infinity }
    return abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
  }

  /// On the current default device: records the tape over the whole pass, then replays each
  /// accepted prefix from the starting memory, and compares both with the reference.
  static func checkTapeAndReplay(
    _ layout: Layout, activation: DType, masked: Bool, device: String
  ) throws {
    let inputs = Self.inputs(layout).rounded(to: activation)
    let (gate, beta) = try libraryGateAndBeta(inputs)
    let mask = masked ? Self.mask(steps: layout.steps) : nil
    let k = inputs.k.asType(activation)
    let label = "\(device) \(layout.name) \(activation)\(masked ? " masked" : "")"

    let (y, final, tape) = DFlashKernels.gatedDeltaKernelWithTape(
      q: inputs.q.asType(activation), k: k, v: inputs.v.asType(activation), g: gate, beta: beta,
      state: inputs.initial, mask: mask)
    eval(y, final, tape)
    let whole = reference(inputs, steps: layout.steps, from: inputs.initial, mask: mask)

    #expect(
      final.dtype == .float32 && tape.dtype == .float32, "\(label): memory and tape stay float32")
    let finalError = maxAbsDifference(final, whole.state)
    #expect(
      finalError < stateTolerance, "\(label): memory after the whole pass is off by \(finalError)")

    // The layer output. A masked step is padding: the tape kernel writes zero there and the
    // ordinary path writes a value nobody reads, so only the kept steps are compared. The
    // float32 bound is the memory's; a 16-bit activation format adds its own rounding of the
    // written output (bfloat16 keeps 8 significant bits: half a unit is 2^-8 of the value).
    let keep =
      mask.map { expandedDimensions($0, axes: [2, 3]).asType(.float32) } ?? MLXArray(Float(1))
    let outputError = (abs(y.asType(.float32) - whole.y.asType(.float32)) * keep).max().item(
      Float.self)
    let outputScale = abs(whole.y).max().item(Float.self)
    let outputTolerance =
      activation == .float32 ? stateTolerance : outputScale / 256 + stateTolerance
    #expect(
      outputError < outputTolerance,
      "\(label): layer output is off by \(outputError), bound \(outputTolerance)")

    var replayError: Float = 0
    for accepted in acceptedCounts {
      let steps = accepted + 1
      let replayed = DFlashKernels.tapeReplayKernel(
        tape: tape[0..., ..<steps, 0..., 0...], k: k[0..., ..<steps, 0..., 0...],
        g: gate[0..., ..<steps, 0...], state: inputs.initial, mask: mask.map { $0[0..., ..<steps] })
      let expected = reference(inputs, steps: steps, from: inputs.initial, mask: mask).state
      let error = maxAbsDifference(replayed, expected)
      #expect(error < stateTolerance, "\(label): replay of \(steps) steps is off by \(error)")
      replayError = max(replayError, error)
    }
    print(
      "DFLASH_TAPE_CHECK \(label): final=\(finalError) replay=\(replayError) output=\(outputError) outputBound=\(outputTolerance) outputScale=\(outputScale)"
    )
  }

  @Test(
    "on the CPU, the recorded tape and its replay give the memory the ordinary computation gives")
  func cpuTapeAndReplayMatchTheOrdinaryComputation() throws {
    try Device.withDefaultDevice(.cpu) {
      for layout in Self.layouts {
        try Self.checkTapeAndReplay(layout, activation: .float32, masked: false, device: "cpu")
      }
    }
  }

  @Test(
    "on the GPU, the Metal tape kernels give that memory for the shipped number formats and with masked steps"
  )
  func metalTapeAndReplayMatchTheOrdinaryComputation() throws {
    // This variable sends both kernels to the ops path. Set, this test would prove nothing
    // about Metal, so it stops instead of passing.
    try #require(
      ProcessInfo.processInfo.environment["DFLASH_FORCE_OPS"] == nil,
      "DFLASH_FORCE_OPS is set: the Metal kernels would not run")

    try Device.withDefaultDevice(.gpu) {
      // The shipped models hold bfloat16 activations and keep the layer memory in float32.
      for layout in Self.layouts {
        try Self.checkTapeAndReplay(layout, activation: .float32, masked: false, device: "gpu")
        try Self.checkTapeAndReplay(layout, activation: .bfloat16, masked: false, device: "gpu")
        try Self.checkTapeAndReplay(layout, activation: .bfloat16, masked: true, device: "gpu")
      }
    }

    // Proof that Metal ran above and the ops path did not, seen in the results. The Metal
    // kernels write their output in the format of an input (the layer output as the
    // activations, the replayed memory as the memory); the ops path lets MLX widen both to
    // float32. So a bfloat16 result on the GPU, beside float32 from the same call on the CPU,
    // is the Metal kernel. One witness per kernel and per mask setting: the choice of kernel
    // depends on the device, the key width, the gate's rank and the mask, never on a format.
    let layout = Self.layouts[2]
    let inputs = Self.inputs(layout).rounded(to: .bfloat16)
    let (gate, beta) = try Self.libraryGateAndBeta(inputs)
    for mask in [nil, Self.mask(steps: layout.steps)] as [MLXArray?] {
      func formats() -> (output: DType, replayed: DType) {
        let k = inputs.k.asType(.bfloat16)
        let (y, _, tape) = DFlashKernels.gatedDeltaKernelWithTape(
          q: inputs.q.asType(.bfloat16), k: k, v: inputs.v.asType(.bfloat16), g: gate, beta: beta,
          state: inputs.initial, mask: mask)
        // A bfloat16 memory is not a shipped combination. It is here only to make the replay
        // kernel's route visible.
        let replayed = DFlashKernels.tapeReplayKernel(
          tape: tape, k: k, g: gate, state: inputs.initial.asType(.bfloat16), mask: mask)
        eval(y, replayed)
        return (y.dtype, replayed.dtype)
      }
      let onGPU = Device.withDefaultDevice(.gpu) { formats() }
      let onCPU = Device.withDefaultDevice(.cpu) { formats() }
      #expect(
        onGPU.output == .bfloat16 && onGPU.replayed == .bfloat16, "GPU ran the ops path: \(onGPU)")
      #expect(
        onCPU.output == .float32 && onCPU.replayed == .float32,
        "the control no longer tells the two routes apart: \(onCPU)")
    }
  }

  /// One check pass through the library's own hook, then what the layer does after it: keep the
  /// last three conv inputs and store the new memory.
  static func runCheckPass(
    on cache: RecurrentRollbackCache, _ inputs: Inputs, activation: DType, mask: MLXArray?
  ) throws {
    let memory = try #require(cache[1])
    let conv = try #require(cache[0])
    let raw = inputs.raw.asType(activation)
    let (_, next) = gatedDeltaUpdate(
      q: inputs.q.asType(activation), k: inputs.k.asType(activation),
      v: inputs.v.asType(activation), a: inputs.a, b: inputs.b, aLog: inputs.aLog,
      dtBias: inputs.dtBias, state: memory, mask: mask, recordingCache: cache, projectedQKV: raw)
    cache[0] = concatenated([conv, raw], axis: 1)[0..., (-3)..., 0...]
    cache[1] = next
    eval(cache[0]!, cache[1]!)
  }

  static func expectedConv(_ conv: MLXArray, _ raw: MLXArray, steps: Int) -> MLXArray {
    concatenated([conv, raw[0..., ..<steps, 0...]], axis: 1)[0..., (-3)..., 0...]
  }

  @Test(
    "a rollback puts the memory and the conv inputs back to the last accepted token, and a cleared or re-armed cache never replays an older tape"
  )
  func rollbackRestoresTheMemoryAndNeverReusesAnOlderTape() throws {
    let cases: [(device: Device, name: String, activation: DType, masked: Bool)] = [
      (.cpu, "cpu", .float32, false), (.gpu, "gpu", .bfloat16, false),
      (.gpu, "gpu", .bfloat16, true),
    ]
    for testCase in cases {
      try Device.withDefaultDevice(testCase.device) {
        let layout = Self.layouts[2]
        let activation = testCase.activation
        let label =
          "\(testCase.name) \(layout.name) \(activation)\(testCase.masked ? " masked" : "")"
        let mask = testCase.masked ? Self.mask(steps: layout.steps) : nil
        let first = Self.inputs(layout).rounded(to: activation)
        let second = Self.inputs(layout, variant: 1).rounded(to: activation)
        let conv = first.conv.asType(activation)

        // 1. Rejected suffixes: after the pass ran over all 16 tokens, keep 1, 7 or 16 of them.
        var worst: Float = 0
        for accepted in Self.acceptedCounts {
          let steps = accepted + 1
          let cache = RecurrentRollbackCache()
          cache[0] = conv
          cache[1] = first.initial
          cache.offset = 5
          cache.armRollback()
          #expect(cache.isArmed)
          try Self.runCheckPass(on: cache, first, activation: activation, mask: mask)
          #expect(cache.recordedVerifications == 1)

          cache.rollback(nAccepted: accepted)

          let expected = Self.reference(first, steps: steps, from: first.initial, mask: mask).state
          let memory = try #require(cache[1])
          let error = Self.maxAbsDifference(memory, expected)
          #expect(
            error < Self.stateTolerance,
            "\(label): memory after keeping \(steps) is off by \(error)")
          worst = max(worst, error)
          let restoredConv = try #require(cache[0])
          #expect(restoredConv.dtype == activation)
          #expect(
            Self.maxAbsDifference(
              restoredConv, Self.expectedConv(conv, first.raw.asType(activation), steps: steps))
              == 0,
            "\(label): conv inputs after keeping \(steps) are not the last three real inputs")
          #expect(!cache.isArmed && cache.performedRollbacks == 1)

          // Token positions are not this cache's to restore: the attention caches own them. A
          // rollback leaves `offset` alone, and `trim` moves `offset` only, by at most its value.
          #expect(cache.offset == 5)
          #expect(cache.trim(3) == 3 && cache.offset == 2)
          #expect(cache.trim(9) == 2 && cache.offset == 0)
          #expect(Self.maxAbsDifference(try #require(cache[1]), memory) == 0)
        }

        // 2. Cleared: a recorded tape is gone after `clearTransients`, so a rollback replays nothing.
        let cleared = RecurrentRollbackCache()
        cleared[0] = conv
        cleared[1] = first.initial
        cleared.armRollback()
        try Self.runCheckPass(on: cleared, first, activation: activation, mask: mask)
        cleared.clearTransients()
        #expect(!cleared.isArmed)
        let marker = MLXArray.ones(first.initial.shape) * Float(7)
        cleared[1] = marker
        cleared.rollback(nAccepted: 3)
        #expect(Self.maxAbsDifference(try #require(cleared[1]), marker) == 0)
        #expect(cleared.performedRollbacks == 0)

        // 3. Re-armed: a second pass from the first pass's end. Its rollback must replay the
        // second tape from the second snapshot. The last line is the control: the first pass's
        // answer for the same count is far from the right one, so reusing its tape would show.
        let rearmed = RecurrentRollbackCache()
        rearmed[0] = conv
        rearmed[1] = first.initial
        rearmed.armRollback()
        try Self.runCheckPass(on: rearmed, first, activation: activation, mask: mask)
        let memoryAfterFirst = try #require(rearmed[1])
        let convAfterFirst = try #require(rearmed[0])
        rearmed.armRollback()
        try Self.runCheckPass(on: rearmed, second, activation: activation, mask: mask)
        rearmed.rollback(nAccepted: 6)
        let expected = Self.reference(second, steps: 7, from: memoryAfterFirst, mask: mask).state
        let rearmedError = Self.maxAbsDifference(try #require(rearmed[1]), expected)
        #expect(
          rearmedError < Self.stateTolerance,
          "\(label): re-armed rollback is off by \(rearmedError)")
        #expect(
          Self.maxAbsDifference(
            try #require(rearmed[0]),
            Self.expectedConv(convAfterFirst, second.raw.asType(activation), steps: 7)) == 0)
        #expect(rearmed.recordedVerifications == 2 && rearmed.performedRollbacks == 1)
        let firstPassAnswer = Self.reference(first, steps: 7, from: first.initial, mask: mask).state
        #expect(Self.maxAbsDifference(expected, firstPassAnswer) > 1000 * Self.stateTolerance)

        print("DFLASH_ROLLBACK_CHECK \(label): rollback=\(worst) rearmed=\(rearmedError)")
      }
    }
  }
}
