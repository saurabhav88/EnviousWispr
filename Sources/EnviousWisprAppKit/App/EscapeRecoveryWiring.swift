import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Composition wiring for Escape Recovery's crash-provenance connector (#2087).
///
/// Extracted rather than inlined in `WisprBootstrapper` because that file's
/// ceiling caught it, which is exactly what the ceiling is for — #1988 set the
/// precedent when live-preview wiring hit the same cap and moved to
/// `LivePreviewInstaller` instead of raising it. The composition root holds
/// dependencies together; it does not implement features.
///
/// Deliberately tiny and stateless. It owns no lifecycle, makes no decisions, and
/// exists so that "which store writes the marker" is answered in one place for
/// both the kernel connector and `RecoveryCoordinator`.
enum EscapeRecoveryWiring {
  /// The single spool-store factory. Shared so the kernel's marker writer and the
  /// recovery coordinator can never end up pointed at different directories — a
  /// divergence that would look like markers silently vanishing.
  static let makeSpoolStore: @Sendable () -> RecoverySpoolStore = { RecoverySpoolStore() }

  /// The kernel's `prepareEscapeRecovery` connector.
  ///
  /// Returns whether the marker is durably on disk. `false` means the caller
  /// performs today's ordinary destructive cancel — see
  /// `RecoverySpoolStore.prepareEscapeRecovery` for why failure destroys the
  /// spool rather than leaving one with no provenance.
  /// `makeStore` is a parameter with a production default so a test can point the
  /// writer at a temp directory. Without it this composition would be untestable
  /// by construction — the only way to exercise it would be to write into the
  /// real user's recovery directory, which no test may do.
  static func writer(
    makeStore: @escaping @Sendable () -> RecoverySpoolStore = makeSpoolStore
  ) -> PrepareEscapeRecovery {
    {
      makeStore().prepareEscapeRecovery(
        recoverySessionID: $0, triggeredAt: $1, takeID: $2)
    }
  }

  /// The pill's action handler, for the ONE call that presents it.
  ///
  /// **A binding that arrives WITH the presentation, not a lifetime field.** The
  /// panel kept onEscapeRecoveryPaste alive for the app's life whether or not
  /// a pill was showing; the director holds exactly one active binding, for the
  /// presentation it belongs to, and drops it when the occupant changes.
  ///
  /// The payload is TAKEN from the director's custody rather than captured here.
  /// The action carries the transcript id as a LOOKUP KEY only, and the take is
  /// one-shot — which is what makes a stale Undo press safe: the second press
  /// finds nothing rather than pasting twice.
  @MainActor
  static func pillActions(
    director: OverlayDirector, coordinator: TranscriptCoordinator
  ) -> (OverlayAction) -> Void {
    let paste = pasteAction(coordinator: coordinator, report: restoreReporter(source: .pill))
    return { [weak director] action in
      guard case .pasteEscapeRecovery(let transcriptID) = action,
        let payload = director?.takeEscapeRecoveryPayload(matching: transcriptID)
      else { return }
      paste(payload)
    }
  }

  /// The pill's Paste action, bound to the coordinator that owns the row.
  ///
  /// Here rather than inline for the same reason `writer` is: the bootstrapper's
  /// line ceiling caught it. The ceiling is the mechanism that keeps the
  /// composition root a place where dependencies MEET rather than a place where
  /// features are implemented, and it has now caught this feature twice.
  @MainActor
  static func pasteAction(
    coordinator: TranscriptCoordinator,
    report: @escaping (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void
  ) -> (CancelUndoPayload) -> Void {
    { [weak coordinator] payload in
      guard let coordinator else { return }
      EscapeRecoveryPasteAction.paste(
        payload: payload,
        restorable: { coordinator.restorableHeldRow(id: $0) },
        report: report)
    }
  }

  /// The production restore reporter. Separate from `pasteAction` so a test can
  /// drive the action without a telemetry client.
  @MainActor
  static func restoreReporter(
    source: EscapeRecoveryRestoreSource
  ) -> (Int, EscapeRecoveryPasteResult, String) -> Void {
    { ageMs, result, takeID in
      TelemetryService.shared.escapeRecoveryRestored(
        source: source, ageMs: ageMs, pasteResult: result, takeID: takeID)
    }
  }

  /// Wire the whole feature and hand back what the kernel needs.
  ///
  /// The Q4 notice is bound for BOTH engines from here, because a notice wired
  /// into one engine appears only for whichever the user happens to be running
  /// — the half-connection this feature has already produced twice.
  ///
  /// **It no longer binds the pill as a side effect**, because there is no
  /// lifetime field to bind: the handler now travels with the presentation, from
  /// `pillActions`, at the one site that presents it. The name used to say the
  /// side effect out loud; now there is nothing to say.
  ///
  /// Kept as a named call rather than inlining `writer()` for the measured
  /// reason it was extracted: the composition root is at its line ceiling, and
  /// this is where the feature's wiring lives.
  @MainActor
  static func wire(_ history: TranscriptCoordinator) -> PrepareEscapeRecovery {
    writer()
  }
}
