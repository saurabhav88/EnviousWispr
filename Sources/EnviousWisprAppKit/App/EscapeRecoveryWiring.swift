import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Composition wiring for Escape Recovery's crash-provenance connector (#2087).
///
/// Extracted rather than inlined in `WisprBootstrapper`, because the composition
/// root holds dependencies TOGETHER and does not implement features. #1988 set
/// the precedent when live-preview wiring moved to `LivePreviewInstaller` for
/// the same reason.
///
/// A line ceiling on the bootstrapper is what originally flagged both, and that
/// ceiling is gone (#2292 C6, founder decision: size caps get raised rather than
/// respected, so they measure nothing). The SPLIT is unaffected — it was always
/// justified by what belongs where, and the cap merely noticed. Recorded as the
/// design rule it is, so nobody re-inlines this on the reasoning that the thing
/// which objected no longer exists.
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
  ///
  /// `paste` is a parameter with a production default for the same reason
  /// `writer`'s `makeStore` is: without it this composition is untestable by
  /// construction. The production closure reaches `TelemetryService.shared` and
  /// the real paste cascade, so the only way to exercise the WRAPPER's own
  /// contract — dismiss first, forward once — would be to fire real telemetry
  /// and drive AX against whatever app happened to be frontmost. The seam is one
  /// argument; a test copy of this closure would be a second definition that
  /// passes while the real one is broken, which is the shape that let the
  /// missing dismissal through in the first place.
  @MainActor
  static func pillActions(
    director: OverlayDirector,
    coordinator: TranscriptCoordinator,
    paste: ((CancelUndoPayload) -> Void)? = nil
  ) -> (OverlayAction) -> Void {
    let paste =
      paste ?? pasteAction(coordinator: coordinator, report: restoreReporter(source: .pill))
    return { [weak director] action in
      guard case .pasteEscapeRecovery(let transcriptID) = action,
        let payload = director?.takeEscapeRecoveryPayload(matching: transcriptID)
      else { return }
      // **Finish tearing down OUR offer before handing control outside**, which
      // is the shipped order and is load-bearing in two directions.
      //
      // Forwards: an accepted pill that stays on screen is an offer the user has
      // already taken. It sits there until its dwell expires, and a second press
      // does nothing at all, because the one-shot take above has already spent
      // the payload — a button that looks live and is not.
      //
      // Backwards, and this is the half the shipped comment exists to record:
      // the paste handler may PRESENT ITS OWN OVERLAY. Dismissing after the call
      // would tear down the pill that handler just put up, so the offer the user
      // is now looking at would be revoked by the one they just accepted.
      //
      // SILENT, matching shipped `hide()` rather than `show(intent: .hidden)`:
      // the user pressed a button and their text is being restored, so a spoken
      // "overlay hidden" is noise on top of the outcome they asked for.
      director?.dismissSilently()
      paste(payload)
    }
  }

  /// The pill's Paste action, bound to the coordinator that owns the row.
  ///
  /// Here rather than inline for the same reason `writer` is: the composition
  /// root is where dependencies MEET, not where features are implemented. This
  /// feature has drifted toward that root twice, which is the argument for
  /// keeping its wiring named and in one place.
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
        copyToClipboard: { PasteService.copyToClipboard($0) },
        dispatchPaste: { PasteService.simulatePaste() },
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
  /// Kept as a named call rather than inlining `writer()` for the reason it was
  /// extracted: this is where the feature's wiring lives, and the composition
  /// root is not.
  @MainActor
  static func wire(_ history: TranscriptCoordinator) -> PrepareEscapeRecovery {
    writer()
  }
}
