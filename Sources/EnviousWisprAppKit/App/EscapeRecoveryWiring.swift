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

  /// Bind the pill's Paste button to the coordinator that owns the row.
  ///
  /// Takes the panel rather than returning a closure, so the composition root
  /// spends ONE line on it. That is not cosmetic: the bootstrapper's ceiling
  /// has now caught this feature twice, and it exists to keep the root a place
  /// where dependencies meet rather than where features are implemented.
  @MainActor
  static func bindPill(overlay: RecordingOverlayPanel, coordinator: TranscriptCoordinator) {
    overlay.onEscapeRecoveryPaste = pasteAction(
      coordinator: coordinator, report: restoreReporter(source: .pill))
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
  /// Binds the pill's Paste button as a side effect, which the name says out
  /// loud. Idempotent: called once per engine, assigning the same closure to
  /// the same panel, so the second call is a no-op in effect.
  ///
  /// Unlabelled arguments and this shape exist for one measured reason: the
  /// composition root was ALREADY at its line ceiling before this feature
  /// (1339 by `wc`, which the gate counts as 1340 of 1340), so the wiring had
  /// to cost it exactly zero net lines. Extract rather than raise — the
  /// precedent #1988 set when live-preview wiring hit the same cap.
  @MainActor
  static func wire(
    _ overlay: RecordingOverlayPanel, _ history: TranscriptCoordinator
  ) -> PrepareEscapeRecovery {
    bindPill(overlay: overlay, coordinator: history)
    return writer()
  }
}
