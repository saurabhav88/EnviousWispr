import CoreML
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

/// Fixed, independently loaded probes for the finished-call policy (#4424).
package enum MeetingNeuralSpeakerPreset: Sendable {
  case offline
  case low

  var config: Nemotron3Config {
    switch self {
    case .offline: .offline
    case .low: .low
    }
  }

  var computeUnits: MLComputeUnits {
    switch self {
    case .offline: .cpuAndGPU
    case .low: .all
    }
  }
}

/// Numerical work only. The caller supplies admitted bytes, scheduling permission and a
/// worker lifetime; Pipeline's SpeakerLabeler remains the deadline/cancellation/join owner.
package enum MeetingNeuralSpeakerAnalyzer {
  package typealias Admission = @Sendable () async -> Bool

  enum Failure: Error {
    case admissionClosed
    case invalidAudio
    case invalidOutput
  }

  /// Closure adapter, confined to one worker. It deliberately is not Sendable: the loader's
  /// `sending` result transfers sole ownership of the native diarizer to that worker.
  struct Runtime {
    let stepSamples: Int
    let slots: Int
    let appendAndProcess: ([Float]) throws -> [LiveSpeakerFrames]
    let finish: () throws -> [LiveSpeakerFrames]
  }

  typealias Load = @Sendable (URL, MeetingNeuralSpeakerPreset) async throws -> sending Runtime
  typealias Read = @Sendable (_ start: Int, _ count: Int) throws -> [Float]

  @concurrent package static func analyze(
    _ audio: MeetingTrackAudio, directory: URL, preset: MeetingNeuralSpeakerPreset,
    canContinue: @escaping Admission
  ) async throws -> [SpeakerSegment] {
    try await run(
      sampleCount: audio.endSample, directory: directory, preset: preset,
      read: { try audio.read(from: $0, count: $1) }, canContinue: canContinue, load: load)
  }

  /// Load-only readiness check. Its runtime is scoped here, never retained for a Ready badge.
  @concurrent package static func checkLoad(
    directory: URL, preset: MeetingNeuralSpeakerPreset
  ) async throws {
    try await checkLoad(directory: directory, preset: preset, load: load)
  }

  @concurrent static func checkLoad(
    directory: URL, preset: MeetingNeuralSpeakerPreset, load: Load
  ) async throws {
    try Task.checkCancellation()
    let runtime = try await load(directory, preset)
    try Task.checkCancellation()
    withExtendedLifetime(runtime) {}
  }

  private static let load: Load = { directory, preset in
    let config = preset.config
    let models = try await Nemotron3Models.load(
      config: config, directory: directory, computeUnits: preset.computeUnits)
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    return Runtime(
      stepSamples: Int((config.chunkSeconds * Double(config.sampleRate)).rounded()),
      slots: config.numSpeakers,
      appendAndProcess: { samples in
        diarizer.appendAudio(samples)
        return try diarizer.processBufferedAudio().map {
          LiveSpeakerFrames(probabilities: $0.probabilities, frameCount: $0.frameCount)
        }
      },
      finish: {
        try diarizer.finishStream().map {
          LiveSpeakerFrames(probabilities: $0.probabilities, frameCount: $0.frameCount)
        }
      })
  }

  /// Same driver for real segment-file reads and deterministic bounded-read fixtures.
  @concurrent static func run(
    sampleCount: Int, directory: URL, preset: MeetingNeuralSpeakerPreset,
    read: Read, canContinue: Admission, load: Load
  ) async throws -> [SpeakerSegment] {
    try Task.checkCancellation()
    guard sampleCount > 0 else { return [] }
    try await checkAdmission(canContinue)
    let runtime = try await load(directory, preset)
    // Core ML loading can finish after cancellation or a change in dictation/pressure.
    try await checkAdmission(canContinue)
    guard runtime.stepSamples > 0, runtime.slots > 0 else { throw Failure.invalidOutput }
    var activity = Activity(slots: runtime.slots)
    var cursor = 0
    while cursor < sampleCount {
      try await checkAdmission(canContinue)
      let count = min(runtime.stepSamples, sampleCount - cursor)
      let samples = try read(cursor, count)
      guard samples.count == count, samples.allSatisfy(\.isFinite) else {
        throw Failure.invalidAudio
      }
      try Task.checkCancellation()
      for frames in try runtime.appendAndProcess(samples) { try activity.append(frames) }
      cursor += count
    }
    try await checkAdmission(canContinue)
    for frames in try runtime.finish() { try activity.append(frames) }
    try Task.checkCancellation()
    guard activity.coveredSamples >= sampleCount else { throw Failure.invalidOutput }
    return activity.finish()
  }

  private static func checkAdmission(_ canContinue: Admission) async throws {
    try Task.checkCancellation()
    guard await canContinue() else { throw Failure.admissionClosed }
    // The admission hop must not let a cancelled worker start another native step.
    try Task.checkCancellation()
  }

  /// Only open runs and final spans survive a chunk; probability arrays do not accumulate.
  struct Activity {
    private struct Run {
      let firstFrame: Int
      var probabilitySum: Double
      var frames: Int
    }

    private let slots: Int
    private var open: [Run?]
    private var cursor = 0
    private var segments: [SpeakerSegment] = []

    var coveredSamples: Int { cursor * 160 }

    init(slots: Int) {
      self.slots = slots
      open = .init(repeating: nil, count: slots)
    }

    mutating func append(_ frames: LiveSpeakerFrames) throws {
      guard frames.frameCount >= 0,
        frames.probabilities.count == frames.frameCount * slots,
        frames.probabilities.allSatisfy(\.isFinite)
      else { throw Failure.invalidOutput }
      for frame in 0..<frames.frameCount {
        for slot in 0..<slots {
          let probability = frames.probabilities[frame * slots + slot]
          if probability > 0.5 {
            if open[slot] == nil {
              open[slot] = Run(firstFrame: cursor + frame, probabilitySum: 0, frames: 0)
            }
            open[slot]!.probabilitySum += Double(probability)
            open[slot]!.frames += 1
          } else {
            close(slot, at: cursor + frame)
          }
        }
      }
      cursor += frames.frameCount
    }

    mutating func finish() -> [SpeakerSegment] {
      for slot in 0..<slots { close(slot, at: cursor) }
      // Keep the vendor's complete 10 ms frame grid, including its centered tail frame.
      // Trimming to PCM duration here could erase a tail-only slot and change the frozen
      // count-agreement policy. Composition already bounds words to their actual timings.
      return segments.sorted {
        ($0.startMs, $0.speakerId, $0.endMs) < ($1.startMs, $1.speakerId, $1.endMs)
      }
    }

    private mutating func close(_ slot: Int, at frame: Int) {
      guard let run = open[slot] else { return }
      open[slot] = nil
      segments.append(
        SpeakerSegment(
          speakerId: "N\(slot)", startMs: run.firstFrame * 10, endMs: frame * 10,
          quality: Float(min(1, run.probabilitySum / Double(run.frames)))))
    }
  }
}
