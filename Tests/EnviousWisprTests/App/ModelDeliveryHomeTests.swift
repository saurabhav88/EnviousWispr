import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit

/// #1741 Chunk 6 — pins the gate-refusal contract for `ModelDeliveryHome`'s
/// two Settings-row mutation sites (Parakeet Cancel/Resume).
@MainActor
@Suite("ModelDeliveryHome — engine mutation gate refusal")
struct ModelDeliveryHomeTests {

  /// Production's trust root is the signed app's own `Bundle.main` (contract
  /// §4a), which a unit-test process cannot see — these resources ride the
  /// `EnviousWispr` app target, not any framework or test bundle. Rather than
  /// author a divergent fixture, point at a `Bundle` over the SAME committed
  /// manifest files `ModelDeliveryHome` loads in production. Same repo-root
  /// discovery as `ParakeetShippedManifestTests.repoRoot`
  /// (`Tests/EnviousWisprTests/ModelDelivery/DeliveryManifestTests.swift`).
  private static func manifestBundle() throws -> Bundle {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
    let resourcesDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    return try #require(Bundle(url: resourcesDir))
  }

  @Test("a gate-refused cancel reports the site and never releases or wakes")
  func aGateRefusedCancelReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle())

    home.cancelParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetCancelDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  @Test("a gate-refused resume reports the site and never releases or wakes")
  func aGateRefusedResumeReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle())

    home.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetResumeDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  // MARK: - #2108: the Live Preview universal model registration

  /// The whole point of chunk 4a, and the one thing in it that can destroy data.
  ///
  /// `CacheAdmission` treats an install directory as exhaustive truth and deletes
  /// every top-level entry the active manifest does not list. If both WhisperKit
  /// registrations pointed at one directory, admitting either model would delete
  /// the other's files — the 1.6 GB transcription model, a heart-path artifact,
  /// wiped by a display-only limb.
  ///
  /// Asserted against the REAL `installDirectory` URLs rather than the manifests'
  /// `installLocation` tokens, because those tokens are documentary:
  /// `DeliveryManifest` decodes `installLocation` as a free `String` and never
  /// resolves it to a path. The directory is the authority, so the directory is
  /// what this test reads.
  @Test("the preview model installs to its own directory, never the transcription model's")
  func previewModelInstallsToItsOwnDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle())

    let transcription = try #require(home.whisperKitRegistration)
    let preview = try #require(home.whisperPreviewRegistration)

    #expect(
      preview.installDirectory != transcription.installDirectory,
      "two registrations sharing an install directory delete each other's files")
    #expect(preview.installDirectory.lastPathComponent == "whisper-preview")
    #expect(transcription.installDirectory.lastPathComponent == "whisper")

    // Neither may be an ANCESTOR of the other either: the exhaustive sweep runs
    // over a directory's top-level entries, so a nested install would put one
    // model's folder inside the other's swept space. Equality alone would not
    // catch that.
    let previewPath = preview.installDirectory.standardizedFileURL.path
    let transcriptionPath = transcription.installDirectory.standardizedFileURL.path
    #expect(!previewPath.hasPrefix(transcriptionPath + "/"))
    #expect(!transcriptionPath.hasPrefix(previewPath + "/"))
  }

  /// Everything that makes a collision plausible is genuinely true — same family,
  /// same source repo, same pinned revision — so the separation above is carrying
  /// real weight rather than restating an accident.
  @Test("the two WhisperKit registrations differ only by variant and install directory")
  func previewAndTranscriptionShareFamilyAndRevision() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle())

    let transcription = try #require(home.whisperKitRegistration).manifest.identity
    let preview = try #require(home.whisperPreviewRegistration).manifest.identity

    #expect(preview.family == transcription.family)
    #expect(preview.revision == transcription.revision)
    #expect(preview.variant != transcription.variant)
    #expect(preview.variant == "openai_whisper-small_216MB")
  }

  /// The shared metadata directory is deliberate and safe. Staging paths and
  /// admission markers key on the full `ModelIdentity.cacheKey`, which includes
  /// the variant, so two artifacts cannot collide there. Only the INSTALL
  /// directory is exhaustive — pinning that distinction stops a future reader
  /// "fixing" the shared metadata dir and losing the marker separation.
  @Test("the two registrations deliberately share one metadata directory")
  func previewAndTranscriptionShareMetadataDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle())

    let transcription = try #require(home.whisperKitRegistration)
    let preview = try #require(home.whisperPreviewRegistration)
    #expect(preview.metadataDirectory == transcription.metadataDirectory)
    #expect(
      preview.manifest.identity.cacheKey != transcription.manifest.identity.cacheKey,
      "the cache key is what keeps markers and staging apart in that shared directory")
  }

  /// A handle exists, so the artifact is reachable for download once chunk 4b
  /// asks. Nil would mean the bundled manifest failed to load, which is the
  /// can't-happen-in-release condition the sibling registrations also guard.
  @Test("the preview registration produces a usable delivery handle")
  func previewRegistrationProducesAHandle() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle())
    #expect(home.whisperPreviewHandle != nil)
  }

  // MARK: - #2123: the preview model's download state is observable

  /// The state starts where a not-yet-downloaded model should start.
  ///
  /// Deliberately a separate mirror from Parakeet's rather than a shared one:
  /// they are different models with different lifecycles, and a settings page
  /// rendering one from the other's state would show a download that is not
  /// happening.
  @Test("the preview model has its own delivery state, separate from Parakeet's")
  func previewStateIsItsOwnMirror() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle())

    #expect(home.whisperPreviewState == .notReady)
    #expect(home.parakeetState == .notReady)

    // The mirrors track DIFFERENT artifacts, which is what makes separate apply
    // guards necessary rather than tidy.
    let preview = try #require(home.whisperPreviewRegistration)
    let transcription = try #require(home.whisperKitRegistration).manifest.identity
    #expect(
      preview.manifest.identity.cacheKey != transcription.cacheKey,
      "two mirrors over one identity would make each model report the other's progress")

    // **The observer must actually OBSERVE.** Checking the initial value cannot
    // tell a wired mirror from a deleted one — both read `.notReady`. So publish
    // a real state for the preview identity and watch which mirror moves.
    //
    // `admitIfComplete` with no fetch is the safe trigger: it validates what is
    // already on disk and never downloads, and never deletes. `remove` would
    // have published a state too, and would have deleted a real model from the
    // machine running the tests.
    _ = await home.controller.admitIfComplete(preview)

    for _ in 0..<2000 where home.previewStateUpdatesForTests == 0 { await Task.yield() }
    #expect(
      home.previewStateUpdatesForTests > 0,
      "the preview mirror never applied an update — observer missing or filtered wrongly")
    #expect(
      home.parakeetStateUpdatesForTests == 0,
      "a preview state reached Parakeet's mirror, so the identity filter is wrong")
  }
}
