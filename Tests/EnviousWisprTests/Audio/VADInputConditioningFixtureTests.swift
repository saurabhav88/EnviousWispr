import CoreML
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2184 — the real Silero model, the real `SilenceDetector`, and committed
/// audio that reproduces the production failure.
///
/// **What the user sees when this fails:** a dictation recorded near a running
/// engine, extractor fan or HVAC unit comes back missing its opening words.
///
/// Tagged `.realBoundary` because it decodes committed audio through the shipped
/// CoreML model rather than a fake. It is deliberately **not** gated with
/// `.enabled(if:)`: both the model and the fixtures are committed repository
/// files, so there is no hardware to be absent, and a missing file must fail
/// loudly rather than skip silently. The fixtures are synthetic — no founder
/// audio, no dictated content — and their generator is committed beside them at
/// `Tests/Fixtures/vad-conditioning/generate-fixtures.py`, so the bytes are
/// reproducible rather than mysterious.
@Suite("VAD input conditioning fixtures", .tags(.productOutcome, .realBoundary))
struct VADInputConditioningFixtureTests {

  // MARK: - Cases

  /// The regression. Speech runs from 0.00 s, and on the unconditioned detector
  /// the VAD finds none of it until 3.58 s of a 6.26 s clip — the same shape as
  /// the founder's aeroplane takes that lost 42%, 87% and 55% of their audio.
  ///
  /// Proven red against the branch parent (`e616c989`) by restoring
  /// `SilenceDetector.swift` to its parent version and rerunning this suite:
  /// **8.3% voiced, first speech 3.584 s**, both assertions failing. With the
  /// conditioning in place it is **100% voiced, first speech 0.00 s**.
  ///
  /// The frozen replay receipt reports the same clip as 8.2% / 3.58 s. Same
  /// segments, different denominator — this suite feeds whole 4096-sample chunks
  /// and divides by 24 x 4096, the replay harness divides by the file's full
  /// 100,224 samples. Do not read the two as disagreeing.
  @Test("the cabin fixture keeps its speech once the VAD's input is conditioned")
  func cabinFixtureRecoversItsSpeech() async throws {
    let outcome = try await runDetector(over: "fixture-noisy-cabin.wav")

    // Pinned to the production topology (two sections, parameter 250, Double
    // state). A floor rather than an equality: CoreML may differ in the last
    // digit across OS revisions, and the claim under test is "the speech is
    // retained", not "this exact ratio". The measured pair is 8.3% and 100%, so
    // no floating-point drift bridges the gap in either direction.
    #expect(
      outcome.voicedFraction >= 0.60,
      "cabin retained \(pct(outcome.voicedFraction)) of its audio — the parent commit retains 8.2%, so anything near that means the conditioning is not reaching the VAD"
    )
    #expect(
      outcome.firstSpeechSeconds ?? .infinity <= 0.30,
      "cabin found its first speech at \(String(describing: outcome.firstSpeechSeconds))s; it is speech from 0.00s and the parent finds it at 3.58s"
    )
  }

  /// The over-fitting guard. `mild` carries ordinary room noise at RMS 0.096 and
  /// is fully retained with or without the change. A fix that only rescues the
  /// loud case is over-fitted to it; a fix that alters this one has changed
  /// ordinary dictation.
  @Test("the mild fixture is unchanged by conditioning")
  func mildFixtureIsUnchanged() async throws {
    let outcome = try await runDetector(over: "fixture-noisy-mild.wav")

    #expect(
      outcome.voicedFraction >= 0.99,
      "mild retained \(pct(outcome.voicedFraction)); it retains 100% on the parent commit and must stay there"
    )
    #expect(outcome.firstSpeechSeconds == 0.0)
  }

  /// The specificity guard. Conditioning removes energy the VAD was reading as
  /// speech, so the direction of risk here is *fewer* false alarms, not more —
  /// measured across 32 labelled non-speech recordings, 28% → 19%. This pins
  /// the one committed non-speech clip at zero.
  @Test("real background noise still produces no speech")
  func backgroundNoiseStaysSilent() async throws {
    let outcome = try await runDetector(
      at: RepoRoot.sourceURL("scripts/freeze-suite/clips/background-noise.wav"))

    #expect(
      outcome.segmentCount == 0,
      "background noise produced \(outcome.segmentCount) speech segment(s) — conditioning must not invent speech"
    )
  }

  // MARK: - Harness

  private struct Outcome {
    var voicedFraction: Double
    var firstSpeechSeconds: Double?
    var segmentCount: Int
  }

  private func pct(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }

  private func runDetector(over fixtureName: String) async throws -> Outcome {
    try await runDetector(
      at: RepoRoot.sourceURL("Tests/Fixtures/vad-conditioning/\(fixtureName)"))
  }

  private func runDetector(at url: URL) async throws -> Outcome {
    // Assert the resource resolves BEFORE running the VAD. A fixture that
    // silently fails to load turns this into a test of an empty array, which
    // passes the specificity case and says nothing about the other two.
    try #require(
      FileManager.default.fileExists(atPath: url.path),
      "fixture missing at \(url.path) — this suite reads committed repository files, so a miss is a real failure, never a skip"
    )
    let samples = try Self.loadPCM16(at: url)
    try #require(!samples.isEmpty, "fixture at \(url.lastPathComponent) decoded to zero samples")

    let detector = SilenceDetector(
      silenceTimeout: 1.5,
      // Production's own defaults. `energyGateThreshold` stays at 0 (the
      // detector's default) so this measures segmentation alone.
      vadConfig: SmoothedVADConfig(),
      makeStreamingVad: { try Self.makeRealVadManager() }
    )
    try await detector.prepare()
    await detector.reset()

    let chunkSize = SilenceDetector.chunkSize
    let fullChunks = samples.count / chunkSize
    try #require(fullChunks > 0, "fixture is shorter than one 4096-sample chunk")

    for index in 0..<fullChunks {
      let start = index * chunkSize
      _ = await detector.processChunk(Array(samples[start..<(start + chunkSize)]))
    }
    let totalSamples = fullChunks * chunkSize
    await detector.finalizeSegments(totalSampleCount: totalSamples)

    let segments = await detector.speechSegments
    let voiced = segments.reduce(0) { $0 + max(0, $1.endSample - $1.startSample) }
    return Outcome(
      voicedFraction: Double(voiced) / Double(totalSamples),
      firstSpeechSeconds: segments.first.map {
        Double($0.startSample) / AudioConstants.sampleRate
      },
      segmentCount: segments.count
    )
  }

  /// Builds the real FluidAudio manager over the model this app ships, read from
  /// the repository rather than an app bundle — the test bundle has no copy of
  /// `Contents/Resources`. The configuration mirrors `BundledVADModelLoader` and
  /// `SilenceDetector.prepare`; if either changes, this must change with it or
  /// the suite stops measuring what production does.
  private static func makeRealVadManager() throws -> any StreamingVad {
    // Read the name from the loader rather than repeating it, so this suite can
    // never end up measuring a different model from the one production loads.
    let modelURL = RepoRoot.sourceURL(
      "Sources/EnviousWispr/Resources/VAD/\(BundledVADModelLoader.pinnedModelName).mlmodelc")
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw FixtureError.modelMissing(modelURL.path)
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    configuration.allowLowPrecisionAccumulationOnGPU = true
    let model = try MLModel(contentsOf: modelURL, configuration: configuration)
    return VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
  }

  private enum FixtureError: Error {
    case modelMissing(String)
    case notPCM16Mono16k(String)
  }

  /// Minimal 16 kHz mono int16 WAV reader. Deliberately strict: a fixture in any
  /// other format is a broken fixture, not something to resample quietly.
  private static func loadPCM16(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count > 12,
      data[0..<4].elementsEqual("RIFF".utf8),
      data[8..<12].elementsEqual("WAVE".utf8)
    else { throw FixtureError.notPCM16Mono16k(url.lastPathComponent) }

    var cursor = 12
    var sawFormat = false
    while cursor + 8 <= data.count {
      let identifier = data[cursor..<(cursor + 4)]
      let size = Int(
        data[(cursor + 4)..<(cursor + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      let body = cursor + 8

      if identifier.elementsEqual("fmt ".utf8), body + 16 <= data.count {
        let channels = data[(body + 2)..<(body + 4)].withUnsafeBytes {
          $0.loadUnaligned(as: UInt16.self)
        }
        let rate = data[(body + 4)..<(body + 8)].withUnsafeBytes {
          $0.loadUnaligned(as: UInt32.self)
        }
        let bits = data[(body + 14)..<(body + 16)].withUnsafeBytes {
          $0.loadUnaligned(as: UInt16.self)
        }
        guard channels == 1, rate == 16_000, bits == 16 else {
          throw FixtureError.notPCM16Mono16k(
            "\(url.lastPathComponent): \(rate) Hz \(channels)ch \(bits)-bit")
        }
        sawFormat = true
      }

      if identifier.elementsEqual("data".utf8) {
        guard sawFormat else { throw FixtureError.notPCM16Mono16k(url.lastPathComponent) }
        let end = min(data.count, body + size)
        var out = [Float]()
        out.reserveCapacity((end - body) / 2)
        var index = body
        while index + 1 < end {
          let sample = data[index..<(index + 2)].withUnsafeBytes {
            $0.loadUnaligned(as: Int16.self)
          }
          out.append(Float(sample) / 32768.0)
          index += 2
        }
        return out
      }
      cursor = body + size + (size % 2)
    }
    throw FixtureError.notPCM16Mono16k("\(url.lastPathComponent): no data chunk")
  }
}
