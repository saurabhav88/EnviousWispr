import CryptoKit
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprModelDelivery
@testable import EnviousWisprTranscribeCpp

/// #3735 real-byte receipt for the two transcribe.cpp Whisper manifests: the production
/// controller downloads each from the real sources (turbo as three parts from our copy),
/// assembles and admits it, and the admitted file then transcribes committed speech.
///
/// **What the user sees when this fails:** a Whisper user's new model never finishes
/// downloading, admits wrong bytes, or cannot transcribe.
///
/// It downloads about 1.16 GB into a private temporary directory, never the app's own
/// data, so it runs only when `EW_REAL_WHISPER_DELIVERY=1` (shell: prefix
/// `TEST_RUNNER_`) and reports skipped otherwise. A skipped receipt is not a passed one:
/// the evidence for these rows is the developer-machine run named in the chunk receipt.
/// Run it alone with `--filter`: a delivery suite elsewhere in the process stubs URLs.
@Suite("transcribe.cpp Whisper delivery on real bytes (#3735)", .serialized, .tags(.productOutcome))
struct WhisperGGUFRealDeliveryTests {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["EW_REAL_WHISPER_DELIVERY"] == "1"
  }

  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // ModelDelivery
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let expectedTranscript =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func normalizedWords(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }

  /// Downloads, assembles and admits one bundled manifest in a private root, then
  /// transcribes committed speech from the admitted file.
  static func deliverAndTranscribe(
    manifestName: String, expectedParts: Int?, installFolder: String
  ) async throws -> String {
    try #require(
      ChunkAppendDelegate.protocolClassesForTesting == nil,
      "run this row alone (--filter): the delivery URL stub is installed in this process")
    let manifest = try DeliveryManifest.load(
      from: try Data(
        contentsOf: repoRoot.appendingPathComponent(
          "Sources/EnviousWispr/Resources/\(manifestName).json")))
    let file = try #require(manifest.files.first)
    #expect(manifest.files.count == 1)
    #expect(file.parts?.count == expectedParts)

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3735-whisper-real-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    let registration = DeliveryRegistration(
      manifest: manifest,
      installDirectory: data.appendingPathComponent("Models/\(installFolder)", isDirectory: true),
      metadataDirectory: data.appendingPathComponent("ModelDelivery", isDirectory: true))
    let controller = ModelDeliveryController(
      defaults: try #require(TestDefaults.suite("test.whisper-real.\(UUID().uuidString)")))

    final class Events: @unchecked Sendable {
      let lock = NSLock()
      var all: [DeliveryEvent] = []
    }
    let events = Events()
    let identity = manifest.identity
    await controller.addEventObserver { observed, event in
      guard observed == identity else { return }
      events.lock.withLock { events.all.append(event) }
    }
    let outcome = await controller.ensureModelAvailable(registration)
    #expect(outcome == .admitted, "delivery outcome: \(outcome)")
    let seen = events.lock.withLock { events.all }
    #expect(
      seen.contains { if case .attemptCompleted(_, _, 1, "our_copy", _) = $0 { true } else { false } },
      "events: \(seen)")
    #expect(seen.contains { if case .sourceFailover = $0 { true } else { false } } == false)
    #expect(await controller.isAdmitted(registration))

    let installed = registration.installDirectory.appendingPathComponent(file.path)
    #expect(try sha256(of: installed) == file.sha256)
    let residue = try FileManager.default.subpathsOfDirectory(
      atPath: registration.installDirectory.path
    ).filter { $0.contains(".part") || $0.hasSuffix(".resume.json") || $0.contains("assembl") }
    #expect(residue.isEmpty, "transport residue in the install: \(residue)")

    let samples = try AudioConverter().resampleAudioFile(
      path: repoRoot.appendingPathComponent("scripts/freeze-suite/clips/normal-speech.wav").path)
    let session = try TranscribeCppSession(modelPath: installed.path)
    defer { session.close() }
    return try session.run(samples: samples, language: "en").text
  }

  @Test(
    "the turbo manifest downloads three parts from our copy, assembles, admits and transcribes",
    .enabled(if: WhisperGGUFRealDeliveryTests.enabled),
    .tags(.realBoundary),
    .timeLimit(.minutes(30)))
  func turboDeliversAndTranscribes() async throws {
    let text = try await Self.deliverAndTranscribe(
      manifestName: "whisper-delivery-manifest", expectedParts: 3, installFolder: "whisper-gguf")
    #expect(Self.normalizedWords(text) == Self.expectedTranscript, "turbo returned: \(text)")
  }

  @Test(
    "the preview manifest downloads one object from our copy, admits and transcribes",
    .enabled(if: WhisperGGUFRealDeliveryTests.enabled),
    .tags(.realBoundary),
    .timeLimit(.minutes(30)))
  func previewDeliversAndTranscribes() async throws {
    let text = try await Self.deliverAndTranscribe(
      manifestName: "whisper-preview-delivery-manifest", expectedParts: nil,
      installFolder: "whisper-preview-gguf")
    // The small model is the display engine; require the sentence's content words, not
    // an exact match.
    let words = Self.normalizedWords(text)
    for word in ["quick", "brown", "fox", "lazy", "dog", "morning"] {
      #expect(words.contains(word), "small model returned: \(text)")
    }
  }
}
