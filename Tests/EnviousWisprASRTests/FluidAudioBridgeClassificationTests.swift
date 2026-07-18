import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprFluidAudioBridge

/// #1525 PR I-B — classification-completeness tests for the bridge that isolates
/// FluidAudio's raw error taxonomies (`ASRError`, `AsrModelsError`,
/// `DownloadUtils.OfflineError`, `DownloadUtils.HuggingFaceDownloadError`) behind
/// name-collision-free values. Lives in this CONSUMING test target, not inside the
/// bridge target itself (Codex r9). Both types' `@unknown default`/catch-all
/// branches are code-inspection-only guarantees — no real FluidAudio SDK value
/// can exercise them with the currently pinned fork version.
@Suite("FluidAudio error classification (#1525 PR I-B)")
struct FluidAudioBridgeClassificationTests {

  // MARK: - FluidAudioASRErrorKind (transcription path, 8 real cases)

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

  // MARK: - FluidAudioModelLoadErrorKind (model-load path, 11 real cases across 3 enums)

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

  @Test("classifyFluidAudioModelLoadError maps every real DownloadUtils.OfflineError case")
  func classifiesAllOfflineErrorCases() {
    let cases: [(DownloadUtils.OfflineError, FluidAudioModelLoadErrorKind)] = [
      (
        .networkDisabled(operation: "downloadRepo(x)"),
        .offlineNetworkDisabled(
          DownloadUtils.OfflineError.networkDisabled(operation: "downloadRepo(x)")
            .localizedDescription)
      ),
      (
        .modelMissing(repo: "r", missing: ["a.mlmodel"]),
        .offlineModelMissing(
          DownloadUtils.OfflineError.modelMissing(repo: "r", missing: ["a.mlmodel"])
            .localizedDescription)
      ),
    ]
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioModelLoadError(vendorError) == expected)
    }
  }

  @Test(
    "classifyFluidAudioModelLoadError maps every real DownloadUtils.HuggingFaceDownloadError case"
  )
  func classifiesAllHuggingFaceDownloadErrorCases() {
    let cases: [(DownloadUtils.HuggingFaceDownloadError, FluidAudioModelLoadErrorKind)] = [
      (
        .invalidResponse,
        .hfInvalidResponse(
          DownloadUtils.HuggingFaceDownloadError.invalidResponse.localizedDescription)
      ),
      (
        .rateLimited(statusCode: 429, message: "slow down"),
        .hfRateLimited(
          DownloadUtils.HuggingFaceDownloadError.rateLimited(
            statusCode: 429, message: "slow down"
          ).localizedDescription)
      ),
      (
        .downloadFailed(path: "p", underlying: NSError(domain: "fixture", code: 3)),
        .hfDownloadFailed(
          DownloadUtils.HuggingFaceDownloadError.downloadFailed(
            path: "p", underlying: NSError(domain: "fixture", code: 3)
          ).localizedDescription)
      ),
      (
        .modelNotFound(path: "p"),
        .hfModelNotFound(
          DownloadUtils.HuggingFaceDownloadError.modelNotFound(path: "p").localizedDescription)
      ),
      (
        .htmlErrorResponse(path: "p", snippet: "<html>"),
        .hfHtmlErrorResponse(
          DownloadUtils.HuggingFaceDownloadError.htmlErrorResponse(path: "p", snippet: "<html>")
            .localizedDescription)
      ),
    ]
    for (vendorError, expected) in cases {
      #expect(classifyFluidAudioModelLoadError(vendorError) == expected)
    }
  }

  @Test("classifyFluidAudioModelLoadError returns nil for none of the 3 named vendor types")
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
}
