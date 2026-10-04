import AppKit
import ApplicationServices
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// What a held-text delivery achieved, in the vocabulary the Escape Recovery Undo reports.
package enum HeldTextDeliveryOutcome: Equatable, Sendable {
  /// The cascade delivered: a verified direct insertion, or a gated key or menu paste dispatch.
  case pasted
  /// The text is on the clipboard and nowhere else.
  case clipboardOnly
  /// The text is on the clipboard because Accessibility is not granted.
  case accessibilityDenied
}

/// The outcome plus the change count of this delivery's own clipboard write, the receipt a later
/// notice compares against (nil when no clipboard write was made).
package struct HeldTextDeliveryResult: Equatable, Sendable {
  package let outcome: HeldTextDeliveryOutcome
  package let fallbackClipboardChangeCount: Int?

  package init(outcome: HeldTextDeliveryOutcome, fallbackClipboardChangeCount: Int?) {
    self.outcome = outcome
    self.fallbackClipboardChangeCount = fallbackClipboardChangeCount
  }
}

/// The settings a held delivery uses, snapshotted ONCE when the user presses Undo. Ordinary
/// dictation uses its recording-start configuration; Undo is a new delivery action and uses the
/// settings as they stand at the press.
package struct HeldDeliverySettings: Equatable, Sendable {
  package let smartInsertion: Bool
  package let autoPasteToActiveApp: Bool
  package let restoreClipboardAfterPaste: Bool

  package init(smartInsertion: Bool, autoPasteToActiveApp: Bool, restoreClipboardAfterPaste: Bool) {
    self.smartInsertion = smartInsertion
    self.autoPasteToActiveApp = autoPasteToActiveApp
    self.restoreClipboardAfterPaste = restoreClipboardAfterPaste
  }
}

/// Delivers text held from an earlier take (#3437): the Escape Recovery pill's Undo.
///
/// There is no Undo-only paste. This runs the dictation delivery's own Smart Insertion
/// (`KernelFinalizationWiring.computeInsertion`) with the take's frozen facts, builds the request
/// with the same `deliveryRequest`, and delivers through the same `PasteCascadeExecutor`, so the
/// text lands exactly where a dictation finishing at the moment of the press would land, and falls
/// back to the clipboard where that dictation would.
@MainActor
package enum HeldTextDelivery {

  /// The production delivery: live seams, the general board and the production cascade.
  package static func deliver(
    text: String, targetApp: NSRunningApplication?, targetElement: AXUIElement?,
    targetWindow: AXUIElement?, takeID: String?, facts: InsertionTakeFacts,
    settings: HeldDeliverySettings,
    onRetained: @escaping KernelDictationDriverFactory.RetainedCallback
  ) async -> HeldTextDeliveryResult {
    await deliver(
      text: text, targetApp: targetApp, targetElement: targetElement, targetWindow: targetWindow,
      takeID: takeID, facts: facts, settings: settings, seams: .live, pasteboard: .general,
      cascade: { request in
        await PasteCascadeExecutor(
          pasteboard: .general, policy: KernelDictationDriverFactory.pasteDeliveryPolicy,
          onRetained: onRetained
        ).deliver(request)
      },
      log: { line in
        await AppLogger.shared.log(line, level: .info, category: "EscapeRecovery")
      })
  }

  /// The delivery with every system boundary injected, so a test drives the real computation,
  /// request building and outcome mapping without a live field, board or cascade.
  static func deliver(
    text: String, targetApp: NSRunningApplication?, targetElement: AXUIElement?,
    targetWindow: AXUIElement?, takeID: String?, facts: InsertionTakeFacts,
    settings: HeldDeliverySettings, seams: KernelFinalizationWiring.InsertionSeams,
    pasteboard: NSPasteboard,
    cascade: @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult,
    log: @escaping @Sendable (String) async -> Void
  ) async -> HeldTextDeliveryResult {
    // Auto-paste off: a dictation would not paste at all, but Undo is an explicit request for the
    // text, so it is copied and the caller shows the Copied notice. No target is touched, so no
    // Accessibility work runs, and nothing schedules a restore over this explicit copy.
    guard settings.autoPasteToActiveApp else {
      ClipboardCleanup.deliveryClaimsBoard()
      let receipt = PasteService.copyToClipboardReturningChangeCount(text, to: pasteboard)
      return HeldTextDeliveryResult(outcome: .clipboardOnly, fallbackClipboardChangeCount: receipt)
    }

    let computation = await KernelFinalizationWiring.computeInsertion(
      text: text, smartInsertion: settings.smartInsertion, targetApp: targetApp,
      targetElement: targetElement, targetWindow: targetWindow, seams: seams,
      afterCaret: { _ in facts })
    let request = KernelFinalizationWiring.deliveryRequest(
      computation: computation, targetApp: targetApp, recordedWindow: targetWindow,
      takeID: takeID, restoreClipboardAfterPaste: settings.restoreClipboardAfterPaste,
      origin: .escapeRecoveryUndo)

    let caret = computation.caret
    let repair = computation.repair
    await log(
      KernelFinalizationWiring.cursorRepairLine(
        app: targetApp?.bundleIdentifier,
        caretOutcome: KernelFinalizationWiring.caretContextOutcome(
          smartInsertion: settings.smartInsertion, targetElement: caret.targetElement,
          terminalRefusal: caret.terminalRefusal, caretContext: caret.caretContext),
        rules: KernelFinalizationWiring.repairRulesLabel(repair.payloads),
        candidateOffered: repair.payloads.repairedText != nil,
        terminalTiming: caret.terminalBudget.timingDescription,
        casingTiming: KernelFinalizationWiring.casingTimingDescription(
          repair.casingSnapshot ?? repair.gate.frozenEvidence),
        retried: caret.retried, retryMs: caret.retryMs,
        origin: PasteDeliveryOrigin.escapeRecoveryUndo.reportedValue))

    let result = await cascade(request)
    // The committed arrival session runs after the outcome is fixed and holds its timers weakly,
    // so this task owns it until its one report, exactly as the dictation delivery does.
    if let arrivalCapture = result.arrivalCapture {
      Task { @MainActor in await arrivalCapture.terminated() }
    }
    return HeldTextDeliveryResult(
      outcome: Self.outcome(of: result.outcome),
      fallbackClipboardChangeCount: result.fallbackClipboardChangeCount)
  }

  /// The cascade's outcome in the Undo vocabulary: only `.delivered` pasted; Accessibility denial
  /// is named; every other outcome left the text on the clipboard. Exhaustive, so a new cascade
  /// outcome must decide here what Undo tells the user.
  static func outcome(of outcome: PasteDeliveryOutcome) -> HeldTextDeliveryOutcome {
    switch outcome {
    case .delivered: return .pasted
    case .clipboardOnlyAccessibilityDenied: return .accessibilityDenied
    case .clipboardOnly, .cgEventCreationFailed, .axWriteUnverifiable: return .clipboardOnly
    }
  }
}
