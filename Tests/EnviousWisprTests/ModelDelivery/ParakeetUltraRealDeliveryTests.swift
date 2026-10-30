import CryptoKit
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprModelDelivery
import EnviousWisprAppKitTestSupport

/// #3546 real-byte receipt for the shipped Parakeet Ultra manifest: the production
/// controller downloads it from the real sources (the encoder as two parts from
/// our copy), assembles and admits it, and the real Ultra model then transcribes
/// committed speech from the admitted directory.
///
/// **What the user sees when this fails:** a new or upgrading user's Parakeet
/// download never finishes, admits wrong bytes, or produces a model that cannot
/// transcribe.
///
/// It downloads about 632 MB into a private temporary directory, never the
/// app's own data, so it runs only when `EW_REAL_ULTRA_DELIVERY=1` and reports
/// skipped otherwise. A skipped receipt is not a passed one: the evidence for
/// this row is the developer-machine run named in the chunk receipt.
@Suite("Shipped Parakeet Ultra delivery on real bytes", .serialized, .tags(.productOutcome))
struct ParakeetUltraRealDeliveryTests {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["EW_REAL_ULTRA_DELIVERY"] == "1"
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

  @Test(
    "the shipped Ultra manifest downloads, assembles, admits and transcribes",
    .enabled(if: ParakeetUltraRealDeliveryTests.enabled),
    .tags(.realBoundary),
    .timeLimit(.minutes(30)), .realBoundaryRun)
  func shippedUltraDeliversAndTranscribes() async throws {
    // Real network only: a delivery suite in this process installs its URL
    // stub for the whole process, so this row must run on its own.
    try #require(
      ChunkAppendDelegate.protocolClassesForTesting == nil,
      "run this row alone (--filter): the delivery URL stub is installed in this process")
    let manifest = try DeliveryManifest.load(
      from: try Data(
        contentsOf: Self.repoRoot.appendingPathComponent(
          "Sources/EnviousWispr/Resources/parakeet-delivery-manifest.json")))
    #expect(manifest.identity.name == "parakeet-ultra-coreml")
    let encoder = try #require(
      manifest.files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" })
    #expect(encoder.parts?.count == 2, "our copy serves the encoder as two parts")

    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3546-ultra-real-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    let registration = DeliveryRegistration(
      manifest: manifest,
      installDirectory: ParakeetInstallLocation.directory(for: .ultra, dataDirectory: data),
      metadataDirectory: data.appendingPathComponent("ModelDelivery", isDirectory: true))
    let suite = "test.ultra-real.\(UUID().uuidString)"
    let controller = ModelDeliveryController(
      defaults: try #require(TestDefaults.suite(suite)))

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
    // Every byte came from our copy (the encoder as its two parts), with no
    // failover to the whole-file backup.
    let seen = events.lock.withLock { events.all }
    #expect(
      seen.contains { if case .attemptCompleted(_, _, 1, "our_copy", _) = $0 { true } else { false } },
      "events: \(seen)")
    #expect(
      seen.contains {
        if case .sourceFailover = $0 { return true }
        return false
      } == false)
    #expect(await controller.isAdmitted(registration))

    // The installed encoder is the publisher's whole file, and no transport
    // residue (parts, sidecars, assembly output) is left in the install.
    let installed = registration.installDirectory.appendingPathComponent(encoder.path)
    #expect(try Self.sha256(of: installed) == encoder.sha256)
    let residue = try FileManager.default.subpathsOfDirectory(
      atPath: registration.installDirectory.path
    ).filter { $0.contains(".part") || $0.hasSuffix(".resume.json") || $0.contains("assembl") }
    #expect(residue.isEmpty, "transport residue in the install: \(residue)")

    // The real Ultra model loads cache-only from the admitted directory and
    // transcribes committed speech.
    let samples = try AudioConverter().resampleAudioFile(
      path: Self.repoRoot.appendingPathComponent("scripts/freeze-suite/clips/normal-speech.wav")
        .path)
    let backend = ParakeetBackend()
    let text: String
    do {
      try await backend.prepare(
        selection: ParakeetModelSelection(
          model: .ultra, revision: manifest.identity.revision,
          directory: registration.installDirectory, cacheOnly: true,
          displayBytes: manifest.totalBytes, repairable: false, generation: 1),
        progressCallback: nil)
      text = try await backend.transcribe(audioSamples: samples, options: .default).text
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }
    #expect(Self.normalizedWords(text) == Self.expectedTranscript, "Ultra returned: \(text)")
  }
}
