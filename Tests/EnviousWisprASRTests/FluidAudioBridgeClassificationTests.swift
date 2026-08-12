import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprFluidAudioBridge

/// #1525 PR I-B (types updated #1981) — classification-completeness tests for the
/// bridge that isolates FluidAudio's raw error taxonomies (`ASRError`,
/// `AsrModelsError`, and the unified `DownloadError`) behind name-collision-free
/// values. Lives in this CONSUMING test target, not inside the bridge target itself
/// (Codex r9). The `DownloadError` switch is deliberately exhaustive with no
/// default branch, so vendor growth is a compile error, never a silent miss.
@Suite("FluidAudio error classification (#1525 PR I-B)")
struct FluidAudioBridgeClassificationTests {

  // MARK: - FluidAudioASRErrorKind (transcription path, 9 real cases)

  @Test("classifyFluidAudioASRError maps every real ASRError case")
  func classifiesAllASRErrorCases() {
    let cases: [(ASRError, FluidAudioASRErrorKind)] = [
      (.notInitialized, .notInitialized(ASRError.notInitialized.localizedDescription)),
      (.invalidAudioData, .invalidAudioData(ASRError.invalidAudioData.localizedDescription)),
      (.modelLoadFailed, .modelLoadFailed(ASRError.modelLoadFailed.localizedDescription)),
      (
        .processingFailed("x"),
        .processingFailed(ASRError.processingFailed("x").localizedDescription)
      ),
      (
        .modelCompilationFailed,
        .modelCompilationFailed(ASRError.modelCompilationFailed.localizedDescription)
      ),
      (
        .unsupportedPlatform("x"),
        .unsupportedPlatform(ASRError.unsupportedPlatform("x").localizedDescription)
      ),
      (
        .streamingConversionFailed(NSError(domain: "fixture", code: 1)),
        .streamingConversionFailed(
          ASRError.streamingConversionFailed(NSError(domain: "fixture", code: 1))
            .localizedDescription)
      ),
      (
        .fileAccessFailed(URL(fileURLWithPath: "/tmp/x"), NSError(domain: "fixture", code: 2)),
        .fileAccessFailed(
          ASRError.fileAccessFailed(
            URL(fileURLWithPath: "/tmp/x"), NSError(domain: "fixture", code: 2)
          ).localizedDescription)
      ),
      // #1654: the vendor added this in the 2026-08-08 pin bump (#1985). Until it was
      // enumerated it fell through `@unknown default` into `unknownFutureCase`, so a
      // real named cause was reaching Sentry as the junk bucket. This row is what
      // makes that drift a test failure instead of a silent collapse.
      (
        .encoderInstantiationFailed("x"),
        .encoderInstantiationFailed(ASRError.encoderInstantiationFailed("x").localizedDescription)
      ),
    ]
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioASRError(vendorError) == expected)
    }
  }

  @Test("classifyFluidAudioASRError returns nil for a non-ASRError")
  func returnsNilForNonASRError() {
    struct OtherError: Error {}
    #expect(classifyFluidAudioASRError(OtherError()) == nil)
  }

  // MARK: - FluidAudioModelLoadErrorKind (model-load path, 13 real cases across 2 enums)

  @Test("classifyFluidAudioModelLoadError maps every real AsrModelsError case")
  func classifiesAllAsrModelsErrorCases() {
    let cases: [(AsrModelsError, FluidAudioModelLoadErrorKind)] = [
      (
        .modelNotFound("m", URL(fileURLWithPath: "/tmp/m")),
        .modelsModelNotFound(
          AsrModelsError.modelNotFound("m", URL(fileURLWithPath: "/tmp/m")).localizedDescription)
      ),
      (
        .downloadFailed("d"),
        .modelsDownloadFailed(AsrModelsError.downloadFailed("d").localizedDescription)
      ),
      (
        .loadingFailed("l"),
        .modelsLoadingFailed(AsrModelsError.loadingFailed("l").localizedDescription)
      ),
      (
        .modelCompilationFailed("c"),
        .modelsCompilationFailed(AsrModelsError.modelCompilationFailed("c").localizedDescription)
      ),
    ]
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioModelLoadError(vendorError) == expected)
    }
  }

  @Test("classifyFluidAudioModelLoadError maps every real unified DownloadError case (all 9)")
  func classifiesAllDownloadErrorCases() {
    let cases: [(DownloadError, FluidAudioModelLoadErrorKind)] = [
      (
        .networkDisabled(operation: "loadModels(x)"),
        .offlineNetworkDisabled(
          DownloadError.networkDisabled(operation: "loadModels(x)").localizedDescription)
      ),
      (
        .modelMissing(repo: "r", missing: ["a.mlmodel"]),
        .offlineModelMissing(
          DownloadError.modelMissing(repo: "r", missing: ["a.mlmodel"]).localizedDescription)
      ),
      (
        .invalidResponse,
        .hfInvalidResponse(DownloadError.invalidResponse.localizedDescription)
      ),
      (
        .rateLimited(statusCode: 429, message: "slow down"),
        .hfRateLimited(
          DownloadError.rateLimited(statusCode: 429, message: "slow down").localizedDescription)
      ),
      (
        .downloadFailed(path: "p", underlying: NSError(domain: "fixture", code: 3)),
        .hfDownloadFailed(
          DownloadError.downloadFailed(path: "p", underlying: NSError(domain: "fixture", code: 3))
            .localizedDescription)
      ),
      (
        .modelNotFound(path: "p"),
        .hfModelNotFound(DownloadError.modelNotFound(path: "p").localizedDescription)
      ),
      (
        .htmlErrorResponse(path: "p", snippet: "<html>"),
        .hfHtmlErrorResponse(
          DownloadError.htmlErrorResponse(path: "p", snippet: "<html>").localizedDescription)
      ),
      (
        .invalidArtifact(path: "p", reason: "truncated"),
        .downloadInvalidArtifact(
          DownloadError.invalidArtifact(path: "p", reason: "truncated").localizedDescription)
      ),
      (
        .stalled(path: "p", window: 60),
        .downloadStalled(DownloadError.stalled(path: "p", window: 60).localizedDescription)
      ),
    ]
    #expect(cases.count == 9, "the unified DownloadError has exactly 9 cases")
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioModelLoadError(vendorError) == expected)
    }
  }

  @Test("classifyFluidAudioModelLoadError returns nil for neither named vendor type")
  func returnsNilForNonVendorModelLoadError() {
    struct OtherError: Error {}
    #expect(classifyFluidAudioModelLoadError(OtherError()) == nil)
  }

  /// #1525 PR I-B naming-trap regression: a future accidental reintroduction of
  /// `ASRError`/`FluidAudio.ASRError` inside `EnviousWisprASR` would be caught by
  /// THAT module failing to compile or silently never matching — this test proves
  /// the bridge itself (the durable fix) correctly resolves FluidAudio's real
  /// `ASRError`, not some shadowing type, by asserting a case that only exists on
  /// the real vendor enum.
  @Test("the bridge resolves FluidAudio's real ASRError, not a shadowing type")
  func resolvesRealFluidAudioType() {
    let kind = classifyFluidAudioASRError(ASRError.notInitialized)
    guard case .notInitialized = kind else {
      Issue.record("expected .notInitialized, got \(String(describing: kind))")
      return
    }
  }

  // MARK: - FluidAudioStreamingErrorKind (streaming path, 7 vendor cases) — #1654

  /// Ship criterion 1. Every case is driven from a REAL vendor error value, not a
  /// hand-built double, so the row fails if the vendor's enum moves under us — the
  /// #2041 drift is what happens when a classifier is only tested from its own output.
  @Test("classifyFluidAudioStreamingError maps every SlidingWindowAsrError case")
  func classifiesAllStreamingErrorCases() {
    let fixture = NSError(domain: "fixture", code: 1)
    let cases: [(SlidingWindowAsrError, FluidAudioStreamingErrorKind)] = [
      (.modelsNotLoaded, .modelsNotLoaded),
      (.streamAlreadyExists(.microphone), .streamAlreadyExists),
      (.audioBufferProcessingFailed(fixture), .audioBufferProcessingFailed),
      (.audioConversionFailed(fixture), .audioConversionFailed),
      (.bufferOverflow, .bufferOverflow),
      (.invalidConfiguration("x"), .invalidConfiguration),
    ]
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioStreamingError(vendorError) == expected)
    }
  }

  /// Ship criterion 2 — BOTH directions, because a one-sided test passes whether or not
  /// the unwrap actually runs.
  @Test("the allWindowsFailed unwrap recovers a recognised inner cause")
  func unwrapsRecognisedInnerCause() {
    let wrapped = SlidingWindowAsrError.modelProcessingFailed(ASRError.processingFailed("x"))
    #expect(
      classifyFluidAudioStreamingError(wrapped) == .allWindowsFailed(inner: .processingFailed))
  }

  @Test("the allWindowsFailed outer case survives an unrecognised inner error")
  func keepsOuterCaseForForeignInnerError() {
    struct ForeignError: Error {}
    let wrapped = SlidingWindowAsrError.modelProcessingFailed(ForeignError())
    // The outer identity must NOT collapse to nil: we still know every window failed
    // even when we cannot name why. That distinction is the whole point of the case.
    #expect(classifyFluidAudioStreamingError(wrapped) == .allWindowsFailed(inner: nil))
  }

  /// Ship criterion 3. A cancelled stream is not a failure and must never acquire a
  /// failure identity — neither through the streaming classifier nor the start-path one.
  @Test("cancellation acquires no streaming identity")
  func cancellationGetsNoIdentity() {
    #expect(classifyFluidAudioStreamingError(CancellationError()) == nil)
    #expect(fluidAudioStreamingInnerCause(CancellationError()) == nil)
  }

  @Test("classifyFluidAudioStreamingError returns nil for a foreign error type")
  func returnsNilForNonStreamingError() {
    struct OtherError: Error {}
    #expect(classifyFluidAudioStreamingError(OtherError()) == nil)
    // A BATCH vendor error is foreign to the streaming classifier too. Without this the
    // start-path mapping and the streaming mapping could quietly overlap.
    #expect(classifyFluidAudioStreamingError(ASRError.notInitialized) == nil)
  }

  /// The start leg: the vendor throws a bare `ASRError` there, and it must classify into
  /// the same text-free vocabulary rather than borrowing the batch path's identity.
  @Test("the start-path classifier maps a bare ASRError to a bare inner cause")
  func mapsStartPathASRError() {
    #expect(fluidAudioStreamingInnerCause(ASRError.notInitialized) == .notInitialized)
    #expect(fluidAudioStreamingInnerCause(ASRError.processingFailed("x")) == .processingFailed)
    #expect(
      fluidAudioStreamingInnerCause(ASRError.encoderInstantiationFailed("x"))
        == .encoderInstantiationFailed)
  }

  /// Ship criterion 2b. Asserting the inner case is right is not the same as asserting
  /// nothing else came with it. The vendor interpolates an inner error's own description
  /// into four of its seven `errorDescription` cases, so this is the guard that the
  /// streaming kind forwards none of it.
  @Test("no vendor text rides the streaming kind")
  func streamingKindCarriesNoVendorText() {
    let secret = "VENDOR-TEXT-THAT-MUST-NOT-TRAVEL"
    let inner = NSError(
      domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
    let wrapped = SlidingWindowAsrError.modelProcessingFailed(inner)

    // Control: prove the fixture actually reaches the vendor's own description, so a
    // clean result below is the kind's doing and not a fixture that never carried it.
    #expect(wrapped.localizedDescription.contains(secret))

    let kind = classifyFluidAudioStreamingError(wrapped)
    #expect(!String(describing: kind).contains(secret))

    // Same check on the case that interpolates a vendor-authored message rather than an
    // inner error's description.
    let configured = SlidingWindowAsrError.invalidConfiguration(secret)
    #expect(configured.localizedDescription.contains(secret))
    #expect(!String(describing: classifyFluidAudioStreamingError(configured)).contains(secret))
  }
}
