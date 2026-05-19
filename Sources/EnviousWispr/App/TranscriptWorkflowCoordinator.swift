import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Observation

/// PR6 of epic #763. Owns transcript re-polish workflow: the user-triggered
/// Enhance action on a history transcript, and the workflow state that
/// `TranscriptDetailView` surfaces (error banner, in-flight transcript ID).
///
/// Shape 4 cascade decision (2026-05-18): TWC ships in its final post-PR11
/// shape — `@State` on `EnviousWisprApp`, holds references to
/// `TranscriptCoordinator` + `TranscriptPolishService` injected by
/// `EnviousWisprApp.init()`. The references' storage stays on `AppState`
/// through PR6 (TC cascades out in PR9, TPS in PR11) because pipelines,
/// `PipelineSettingsSync`, and the custom-words propagator still call them
/// at construction time — moving storage in PR6 would require forwarding
/// shims that violate the no-half-done-handoffs rule.
///
/// **Anti-service-locator guardrail.** TWC exposes `transcriptCoordinator`
/// solely so the four transcript-history view consumers
/// (`TranscriptDetailView`, `HistoryContentView`, `TranscriptHistoryView`,
/// `SidebarStatsHeader`) can resolve list/count/delete/load/filter through
/// a single environment surface during the AppState deletion cascade. No new
/// domain APIs, no unrelated transcript surfaces, no non-transcript
/// consumers. `TranscriptWorkflowCoordinatorCeilingsTests` enforces ≤2
/// stored properties and ≤1 non-private method as the structural backstop.
///
/// **Scene injection.** Any SwiftUI scene that renders any of the four
/// transcript-history views MUST also `.environment(transcriptWorkflowCoordinator)`
/// on its hierarchy or the view body will crash on
/// `@Environment(TranscriptWorkflowCoordinator.self)` lookup. Today only the
/// main `Window` scene renders these views; onboarding does not.
@Observable @MainActor
final class TranscriptWorkflowCoordinator {
  let transcriptCoordinator: TranscriptCoordinator
  let polishService: TranscriptPolishService

  init(transcriptCoordinator: TranscriptCoordinator, polishService: TranscriptPolishService) {
    self.transcriptCoordinator = transcriptCoordinator
    self.polishService = polishService
  }

  /// Re-polish an existing transcript via the standalone polish service.
  /// Decoupled from pipeline state: does not touch pipeline.state, currentTranscript, or lastPolishError.
  ///
  /// Idempotency: no internal guard. UI gate is the Enhance button disabling
  /// on `polishingTranscriptID != nil`. Direct-call guard is
  /// `TranscriptPolishService.polish` itself, which sets/checks its own
  /// `polishingTranscriptID`. PR6 preserves this two-layer guard exactly as
  /// pre-PR6 AppState had it.
  func polishTranscript(_ transcript: Transcript) async {
    do {
      let updated = try await polishService.polish(transcript)
      if let idx = transcriptCoordinator.transcripts.firstIndex(where: { $0.id == updated.id }) {
        transcriptCoordinator.transcripts[idx] = updated
      }
      // Ensure detail view refreshes even when activeTranscript falls back to pipeline.currentTranscript
      transcriptCoordinator.selectedTranscriptID = updated.id
    } catch {
      // Error already captured in polishService.lastEnhancementError
      Task {
        await AppLogger.shared.log(
          "Transcript enhancement failed: \(error.localizedDescription)",
          level: .info, category: "Enhancement"
        )
      }
    }
  }

  /// Enhancement error from the re-polish service, surfaced to TranscriptDetailView.
  var lastEnhancementError: EnhancementError? {
    polishService.lastEnhancementError
  }

  /// ID of the transcript currently being re-polished. TranscriptDetailView
  /// reads this to disable the Enhance button while polish is in flight.
  /// Computed pass-through; do NOT expose `polishService` directly to views.
  var polishingTranscriptID: UUID? {
    polishService.polishingTranscriptID
  }
}
