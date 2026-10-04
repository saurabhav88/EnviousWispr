import AppKit
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

  /// The pill's Paste action, bound to the coordinator that owns the row.
  ///
  /// Here rather than inline for the same reason `writer` is: the composition
  /// root is where dependencies MEET, not where features are implemented. This
  /// feature has drifted toward that root twice, which is the argument for
  /// keeping its wiring named and in one place.
  @MainActor
  static func pasteAction(
    coordinator: TranscriptCoordinator,
    overlay: (any RetainedPasteNoticeHosting)?,
    settingsAtPress: @escaping @MainActor () -> HeldDeliverySettings,
    report: @escaping (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void
  ) -> (CancelUndoPayload) -> Void {
    { [weak coordinator, weak overlay] payload in
      guard let coordinator else { return }
      // #3437: snapshotted HERE, synchronously at the press and before any await, so the
      // delivery uses the settings as they stood when the user asked.
      let settings = settingsAtPress()
      Task { @MainActor in
        await EscapeRecoveryPasteAction.paste(
          payload: payload,
          restorable: { coordinator.restorableHeldRow(id: $0) },
          deliver: { text, payload, takeID in
            await HeldTextDelivery.deliver(
              text: text, targetApp: payload.targetApp, targetElement: payload.targetElement,
              targetWindow: payload.targetWindow, takeID: takeID, facts: payload.takeFacts,
              settings: settings,
              onRetained: { takeID, changeCount, reportShown in
                EscapeRecoveryNotice.show(
                  identity: takeID, receipt: changeCount, reason: nil, host: overlay,
                  reportShown: reportShown)
              })
          },
          presentNotice: { result, takeID, transcriptID in
            EscapeRecoveryNotice.show(
              identity: takeID ?? transcriptID.uuidString,
              receipt: result.fallbackClipboardChangeCount,
              reason: result.outcome == .accessibilityDenied ? "ax_denied" : nil, host: overlay,
              reportShown: { _ in })
          },
          report: report)
      }
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
  /// lifetime field to bind: the handler travels with the presentation, on the
  /// `.escapeRecovery` request the one presenting site builds. The name used to
  /// say the side effect out loud; now there is nothing to say.
  ///
  /// Kept as a named call rather than inlining `writer()` for the reason it was
  /// extracted: this is where the feature's wiring lives, and the composition
  /// root is not.
  @MainActor
  static func wire(_ history: TranscriptCoordinator) -> PrepareEscapeRecovery {
    writer()
  }
}

/// The Copied notice after an Escape Recovery Undo that ended on the clipboard (#3437).
///
/// The SAME guarded request the late dictation notice uses (`retainedClipboardFallback`): the
/// reducer admits it only while no recording or processing pill is up and the slot is empty, so a
/// restore finishing late can never replace a newer dictation's pill or publish a recording-ended
/// effect. Mirrors `RetainedPasteNotice.retained` without its latest-take test: Undo is not a newly
/// accepted take.
@MainActor
enum EscapeRecoveryNotice {

  /// Shows the notice only while the board still holds THIS delivery's write (its `receipt`),
  /// checked before admission and again at a deferred first render. `reportShown` is completed
  /// exactly once, on every path, with the director's actual verdict.
  static func show(
    identity: String, receipt: Int?, reason: String?, host: (any RetainedPasteNoticeHosting)?,
    reportShown: @escaping @MainActor (Bool) -> Void,
    boardChangeCount: @escaping @MainActor () -> Int = { NSPasteboard.general.changeCount }
  ) {
    guard let receipt, boardChangeCount() == receipt, let host else {
      Self.log(shown: false, why: "stale", reason: reason)
      reportShown(false)
      return
    }
    let request = PillRequest.retainedClipboardFallback(
      takeID: identity, isStillWanted: { boardChangeCount() == receipt })
    host.present(request) { result in
      switch result {
      case .presented:
        Self.log(shown: true, why: "presented", reason: reason)
        reportShown(true)
      case .notPresented:
        Self.log(shown: false, why: "refused", reason: reason)
        reportShown(false)
      }
    }
  }

  /// One app.log line per notice decision, for Live UAT: the verdict and why, never text.
  private static func log(shown: Bool, why: String, reason: String?) {
    let suffix = reason.map { " reason=\($0)" } ?? ""
    Task {
      await AppLogger.shared.log(
        "ESCAPE_RECOVERY_NOTICE shown=\(shown) why=\(why)\(suffix)", level: .info,
        category: "EscapeRecovery")
    }
  }
}
