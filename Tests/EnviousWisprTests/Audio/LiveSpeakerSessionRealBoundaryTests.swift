import CryptoKit
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprModelDelivery

/// #4355 PR C on the real pinned Nemotron3 `low` model: when this fails, the shipped speaker
/// model does not load from an admitted folder through the production loader, or it streams no
/// usable speaker output for a real two-voice recording, or the session never releases it.
/// A mechanical boundary check: speaker accuracy was scored in Phase 0, not here.
///
/// The bytes are the delivery manifest's own files, checked by SHA-256 before use and laid out
/// flat in a temporary folder exactly as admission installs them. Source folder: the
/// `EW_SPEAKER_LIVE_SOURCE` variable (forwarded as `TEST_RUNNER_EW_SPEAKER_LIVE_SOURCE`), else
/// FluidAudio's Hugging Face cache folder, which holds the same revision's bytes. Nothing is
/// downloaded; absent bytes skip the suite (NOT VERIFIED, not a pass).
@Suite(
  "Live speaker session on the real model", .serialized, .tags(.productOutcome, .realBoundary),
  .realBoundaryRun,
  .enabled(if: SpeakerLiveModelBytes.available, "admitted speaker-live model bytes missing"))
struct LiveSpeakerSessionRealBoundaryTests {
  @Test("streams finite speaker activity for a real two-voice call and releases the model")
  func streamsAndReleases() async throws {
    let directory = try SpeakerLiveModelBytes.admittedFolder()
    let samples = try VADInputConditioningFixtureTests.loadPCM16(
      at: RepoRoot.sourceURL("Tests/Fixtures/speaker-diarization/two-voice-30s.wav"))
    try #require(samples.count > 16_000 * 20)

    let recorder = LiveSpeakerSessionTests.Recorder()
    let released = BoundedWait.Signal()
    let session = LiveSpeakerSession(
      directory: directory, admit: { true }, backlogLimitSamples: samples.count,
      publish: { recorder.record($0) }, onReleased: { released.fire() })
    session.start()
    try await BoundedWait.until(
      recorder.when { $0.contains { if case .ready = $0 { true } else { false } } },
      deadline: .seconds(120))

    let recording = UUID()
    let bank = 1600
    var offset = 0
    while offset < samples.count {
      let count = min(bank, samples.count - offset)
      let span = try #require(
        MeetingAudioSpan(
          recording: recording, track: .callSound, run: 0, startSample: offset, sampleCount: count))
      session.submit(
        MeetingLiveAudioChunk(
          samples: Array(samples[offset..<offset + count]),
          slices: [MeetingLiveAudioSlice(offset: 0, span: span)]))
      offset += count
    }
    // The model emits a frame once 1.04 s past its start is fed, so all but the last second
    // comes out; wait for 25 s of reported audio.
    let target = 25 * 100
    try await BoundedWait.until(
      recorder.when { _ in recorder.activityFrames + recorder.unpositioned >= target },
      deadline: .seconds(120))

    #expect(!recorder.updates.contains { if case .unavailable = $0 { true } else { false } })
    #expect(recorder.unpositioned == 0)
    let activities = recorder.activities
    var next = 0
    for activity in activities {
      #expect(activity.span.recording == recording)
      #expect(activity.span.startSample == next, "frames must tile the fed audio in order")
      #expect(activity.activeSlots.allSatisfy { (0..<8).contains($0) })
      next = activity.span.endSample
    }
    let talkingSlots = Set(activities.flatMap(\.activeSlots))
    #expect(!talkingSlots.isEmpty, "a two-voice recording produced no speaker activity")
    #expect(activities.contains { !$0.activeSlots.isEmpty })

    session.close()
    try await BoundedWait.until(released, deadline: .seconds(30))
  }
}

/// The manifest's files, verified, for the real-boundary suite.
enum SpeakerLiveModelBytes {
  static var manifestURL: URL {
    RepoRoot.sourceURL("Sources/EnviousWispr/Resources/speaker-live-delivery-manifest.json")
  }

  static var sourceRoot: URL {
    let env = ProcessInfo.processInfo.environment["EW_SPEAKER_LIVE_SOURCE"]
    if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FluidAudio/Models/nemotron-3-diarization")
  }

  /// Every manifest file is present at its fetch path under the source root (sizes only;
  /// hashes are checked before use).
  static var available: Bool {
    guard let manifest = try? DeliveryManifest.load(from: Data(contentsOf: manifestURL)) else {
      return false
    }
    return manifest.files.allSatisfy { file in
      let url = sourceRoot.appendingPathComponent(file.path)
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
      return size.map(Int64.init) == file.sizeBytes
    }
  }

  /// A temporary folder laid out at the manifest's install paths, holding hash-verified links.
  static func admittedFolder() throws -> URL {
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: manifestURL))
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("LiveSpeakerSessionRealBoundary-\(UUID().uuidString)")
    for file in manifest.files {
      let source = sourceRoot.appendingPathComponent(file.path)
      let digest = SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined()
      try #require(digest == file.sha256, "\(file.path) is not the manifest's byte")
      let target = root.appendingPathComponent(file.resolvedInstallPath)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
    }
    return root
  }
}
