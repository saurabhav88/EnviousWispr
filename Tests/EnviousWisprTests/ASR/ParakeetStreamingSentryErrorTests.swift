import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprFluidAudioBridge
@testable import EnviousWisprServices

/// #1654 — `ParakeetStreamingSentryError`'s Sentry identity is PINNED, mirroring the
/// batch conformer's contract.
///
/// **Measured before pinning, per the epic protocol (`BIBLE.md` §5), 2026-08-12.** A
/// 90-day Sentry search returns ZERO issues for "SlidingWindow" or "streaming", against
/// a working positive control ("Parakeet" returns ENVIOUSWISPR-16). The mechanism agrees:
/// the only streaming failure PostHog has ever recorded (one event, one person,
/// 2026-07-30, v2.4.1) was `result: rescued`, and a rescued failure produces no terminal
/// and therefore no Sentry event. So no shipped grouping exists to preserve, and these
/// descriptors are app-owned strings rather than defensive vendor-ordinal pins.
@Suite("ParakeetStreamingSentryError Sentry stable identity (#1654)")
struct ParakeetStreamingSentryErrorTests {

  private static let env = "production"
  private static let base = "EnviousWisprASR.ParakeetStreamingSentryError"

  /// Every declared identity, including one `allWindowsFailed` / `startFailed` row per
  /// inner cause. Enumerated rather than generated: a generated table would reproduce
  /// whatever the implementation does, which proves only that the code equals itself.
  private static let pins: [(ParakeetStreamingSentryError, String, String)] = [
    (.modelsNotLoaded, "\(base).modelsNotLoaded", "parakeet_streaming.models_not_loaded"),
    (
      .streamAlreadyExists, "\(base).streamAlreadyExists",
      "parakeet_streaming.stream_already_exists"
    ),
    (
      .audioBufferProcessingFailed, "\(base).audioBufferProcessingFailed",
      "parakeet_streaming.audio_buffer_processing_failed"
    ),
    (
      .audioConversionFailed, "\(base).audioConversionFailed",
      "parakeet_streaming.audio_conversion_failed"
    ),
    (.bufferOverflow, "\(base).bufferOverflow", "parakeet_streaming.buffer_overflow"),
    (
      .invalidConfiguration, "\(base).invalidConfiguration",
      "parakeet_streaming.invalid_configuration"
    ),
    (
      .unknownStreamingFailure, "\(base).unknownStreamingFailure",
      "parakeet_streaming.unknown_streaming_failure"
    ),
    (
      .allWindowsFailed(inner: nil), "\(base).allWindowsFailed.unrecognised",
      "parakeet_streaming.all_windows_failed.unrecognised"
    ),
    (
      .allWindowsFailed(inner: .notInitialized), "\(base).allWindowsFailed.notInitialized",
      "parakeet_streaming.all_windows_failed.not_initialized"
    ),
    (
      .allWindowsFailed(inner: .invalidAudioData), "\(base).allWindowsFailed.invalidAudioData",
      "parakeet_streaming.all_windows_failed.invalid_audio_data"
    ),
    (
      .allWindowsFailed(inner: .modelLoadFailed), "\(base).allWindowsFailed.modelLoadFailed",
      "parakeet_streaming.all_windows_failed.model_load_failed"
    ),
    (
      .allWindowsFailed(inner: .processingFailed), "\(base).allWindowsFailed.processingFailed",
      "parakeet_streaming.all_windows_failed.processing_failed"
    ),
    (
      .allWindowsFailed(inner: .modelCompilationFailed),
      "\(base).allWindowsFailed.modelCompilationFailed",
      "parakeet_streaming.all_windows_failed.model_compilation_failed"
    ),
    (
      .allWindowsFailed(inner: .unsupportedPlatform),
      "\(base).allWindowsFailed.unsupportedPlatform",
      "parakeet_streaming.all_windows_failed.unsupported_platform"
    ),
    (
      .allWindowsFailed(inner: .streamingConversionFailed),
      "\(base).allWindowsFailed.streamingConversionFailed",
      "parakeet_streaming.all_windows_failed.streaming_conversion_failed"
    ),
    (
      .allWindowsFailed(inner: .fileAccessFailed), "\(base).allWindowsFailed.fileAccessFailed",
      "parakeet_streaming.all_windows_failed.file_access_failed"
    ),
    (
      .allWindowsFailed(inner: .encoderInstantiationFailed),
      "\(base).allWindowsFailed.encoderInstantiationFailed",
      "parakeet_streaming.all_windows_failed.encoder_instantiation_failed"
    ),
    (
      .allWindowsFailed(inner: .unknownFutureCase), "\(base).allWindowsFailed.unknownFutureCase",
      "parakeet_streaming.all_windows_failed.unknown_future_case"
    ),
    (
      .startFailed(inner: nil), "\(base).startFailed.unrecognised",
      "parakeet_streaming.start_failed.unrecognised"
    ),
    (
      .startFailed(inner: .notInitialized), "\(base).startFailed.notInitialized",
      "parakeet_streaming.start_failed.not_initialized"
    ),
    (
      .startFailed(inner: .invalidAudioData), "\(base).startFailed.invalidAudioData",
      "parakeet_streaming.start_failed.invalid_audio_data"
    ),
    (
      .startFailed(inner: .modelLoadFailed), "\(base).startFailed.modelLoadFailed",
      "parakeet_streaming.start_failed.model_load_failed"
    ),
    (
      .startFailed(inner: .processingFailed), "\(base).startFailed.processingFailed",
      "parakeet_streaming.start_failed.processing_failed"
    ),
    (
      .startFailed(inner: .modelCompilationFailed), "\(base).startFailed.modelCompilationFailed",
      "parakeet_streaming.start_failed.model_compilation_failed"
    ),
    (
      .startFailed(inner: .unsupportedPlatform), "\(base).startFailed.unsupportedPlatform",
      "parakeet_streaming.start_failed.unsupported_platform"
    ),
    (
      .startFailed(inner: .streamingConversionFailed),
      "\(base).startFailed.streamingConversionFailed",
      "parakeet_streaming.start_failed.streaming_conversion_failed"
    ),
    (
      .startFailed(inner: .fileAccessFailed), "\(base).startFailed.fileAccessFailed",
      "parakeet_streaming.start_failed.file_access_failed"
    ),
    (
      .startFailed(inner: .encoderInstantiationFailed),
      "\(base).startFailed.encoderInstantiationFailed",
      "parakeet_streaming.start_failed.encoder_instantiation_failed"
    ),
    (
      .startFailed(inner: .unknownFutureCase), "\(base).startFailed.unknownFutureCase",
      "parakeet_streaming.start_failed.unknown_future_case"
    ),
  ]

  // MARK: - A. Pinned identities

  @Test("every case keeps its exact pinned fingerprint and semantic ID")
  func pinnedIdentities() {
    for (error, descriptor, semanticID) in Self.pins {
      #expect(error.sentryFingerprintDescriptor == descriptor)
      #expect(error.sentrySemanticID == semanticID)
    }
  }

  @Test("all declared identities are unique")
  func identitiesAreUnique() {
    let descriptors = Self.pins.map(\.1)
    let semanticIDs = Self.pins.map(\.2)
    #expect(Set(descriptors).count == descriptors.count)
    #expect(Set(semanticIDs).count == semanticIDs.count)
    // The pin table must cover the whole space, or "unique" is a claim about a subset.
    // 7 flat cases + 2 blocks x (10 inner causes + 1 unrecognised) = 29.
    #expect(Self.pins.count == 29)
  }

  // MARK: - B. Code allocation

  /// The inner cause has to ride the `errorCode`, because `XPCErrorSanitizer` rebuilds
  /// every error crossing the boundary with `userInfo` reduced to exactly one key. So the
  /// code allocation IS the wire format, and a collision would silently merge two causes.
  @Test("every declared case has a distinct errorCode")
  func errorCodesAreUnique() {
    let codes = Self.pins.map { ($0.0 as NSError).code }
    #expect(Set(codes).count == codes.count)
  }

  @Test("the two inner-cause blocks do not overlap")
  func blocksDoNotOverlap() {
    let allWindows = Self.pins.filter {
      if case .allWindowsFailed = $0.0 { return true } else { return false }
    }.map { ($0.0 as NSError).code }
    let starts = Self.pins.filter {
      if case .startFailed = $0.0 { return true } else { return false }
    }.map { ($0.0 as NSError).code }
    #expect(Set(allWindows).isDisjoint(with: Set(starts)))
    #expect(allWindows.allSatisfy { (100...199).contains($0) })
    #expect(starts.allSatisfy { (200...299).contains($0) })
  }

  /// A code from a block this build does not know must NOT be read as a known case with
  /// an unknown inner cause. Without the block bound, an unbounded `> base` test would
  /// absorb every code allocated above it — including the `startFailed` block.
  @Test("a code outside every allocated block reconstructs to nil, not to a neighbour")
  func unallocatedCodeReconstructsToNil() {
    for code in [50, 99, 300, 1000] {
      let ns = NSError(domain: ParakeetStreamingSentryError.errorDomain, code: code)
      #expect(
        ParakeetStreamingSentryError(reconstructingFrom: ns) == nil,
        "code \(code) must not reconstruct")
    }
  }

  /// The reverse direction of the same guard: an offset INSIDE a known block but not yet
  /// allocated must degrade to "cause unrecognised", never to a wrong cause.
  @Test("an unallocated offset inside a block degrades to an unrecognised cause")
  func unallocatedOffsetDegradesToUnrecognised() {
    let ns = NSError(domain: ParakeetStreamingSentryError.errorDomain, code: 150)
    #expect(ParakeetStreamingSentryError(reconstructingFrom: ns) == .allWindowsFailed(inner: nil))
  }

  // MARK: - C. NSError round-trip (survives the XPC boundary)

  @Test("every case round-trips through its NSError bridge")
  func nsErrorRoundTrip() {
    for (error, _, _) in Self.pins {
      let bridged = error as NSError
      #expect(bridged.domain == ParakeetStreamingSentryError.errorDomain)
      guard let reconstructed = ParakeetStreamingSentryError(reconstructingFrom: bridged) else {
        Issue.record("reconstruction failed for \(error)")
        continue
      }
      #expect(reconstructed == error)
    }
  }

  /// Same reason as the batch conformer: a plain `as NSError` cast survives in-process
  /// but an actual archive round-trip drops the description unless `errorUserInfo`
  /// carries it. This exercises the real archive, not the cast.
  @Test("the description survives an actual NSSecureCoding archive round-trip")
  func descriptionSurvivesArchiveRoundTrip() throws {
    let error = ParakeetStreamingSentryError.allWindowsFailed(inner: .processingFailed)
    let bridged = error as NSError
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: bridged, requiringSecureCoding: true)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
    #expect(decoded.localizedDescription == error.errorDescription)
    // And the identity itself survives, which is the part the diagnostics depend on.
    #expect(ParakeetStreamingSentryError(reconstructingFrom: decoded) == error)
  }

  @Test("reconstructingFrom returns nil for an unrelated NSError domain")
  func reconstructionRejectsForeignDomain() {
    let foreign = NSError(domain: "SomeOtherDomain", code: 100)
    #expect(ParakeetStreamingSentryError(reconstructingFrom: foreign) == nil)
  }

  // MARK: - D. Descriptions are app-authored

  /// Ship criterion 2b at the IDENTITY layer, as far as this target can reach it.
  ///
  /// The end-to-end leak test — a REAL vendor error carrying a marker, driven through the
  /// classifier and out to the wire — lives in `FluidAudioBridgeClassificationTests`,
  /// because this target cannot import FluidAudio: `ASRError` here resolves to OUR type,
  /// not the vendor's. That collision is the entire reason the bridge target exists, so
  /// splitting the test follows the same boundary rather than fighting it.
  ///
  /// What is provable here is the other half: every description is one of ours.
  @Test("every case's description is app-authored and non-empty")
  func descriptionsAreAppAuthored() {
    for (error, _, _) in Self.pins {
      let description = try? #require(error.errorDescription)
      #expect(description?.isEmpty == false)
      // Every app-authored string starts this way. A vendor description would not, and
      // an interpolated one would carry the vendor's own phrasing instead.
      #expect(description?.hasPrefix("Live transcription") == true)
      #expect((error as NSError).localizedDescription == description)
    }
  }

  // MARK: - E. Mapping from the bridge kind

  @Test("init(mapping:) covers every streaming kind")
  func mappingCoversEveryKind() {
    let kinds: [(FluidAudioStreamingErrorKind, ParakeetStreamingSentryError)] = [
      (.modelsNotLoaded, .modelsNotLoaded),
      (.streamAlreadyExists, .streamAlreadyExists),
      (.audioBufferProcessingFailed, .audioBufferProcessingFailed),
      (.audioConversionFailed, .audioConversionFailed),
      (.bufferOverflow, .bufferOverflow),
      (.invalidConfiguration, .invalidConfiguration),
      (.unknownFutureCase, .unknownStreamingFailure),
      (.allWindowsFailed(inner: nil), .allWindowsFailed(inner: nil)),
      (
        .allWindowsFailed(inner: .processingFailed),
        .allWindowsFailed(inner: .processingFailed)
      ),
    ]
    for (kind, expected) in kinds {
      #expect(ParakeetStreamingSentryError(mapping: kind) == expected)
    }
  }

  /// The positive half — a real vendor `ASRError` producing `.startFailed` — is in
  /// `FluidAudioBridgeClassificationTests` for the import reason above. The refusals are
  /// testable here and are the half that matters most: an error we cannot name must not
  /// acquire a streaming identity, and a cancellation must never look like a failure.
  @Test("init(mappingStartFailure:) refuses a foreign error and a cancellation")
  func startFailureMappingRefusals() {
    struct ForeignError: Error {}
    #expect(ParakeetStreamingSentryError(mappingStartFailure: ForeignError()) == nil)
    #expect(ParakeetStreamingSentryError(mappingStartFailure: CancellationError()) == nil)
  }

  // MARK: - F. Event-construction contract

  @MainActor
  @Test("a streaming-failure event carries the pinned fingerprint and identity tag")
  func streamingFailureEventShape() {
    let error = ParakeetStreamingSentryError.allWindowsFailed(inner: .processingFailed)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .asrFailed, stage: "transcription", environment: Self.env)

    #expect(
      event.fingerprint == [
        "handled_error", "asr_failed",
        "\(Self.base).allWindowsFailed.processingFailed", Self.env,
      ])
    #expect(
      event.tags?["error.identity"]
        == "parakeet_streaming.all_windows_failed.processing_failed")
  }
}
