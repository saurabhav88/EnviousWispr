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
}
