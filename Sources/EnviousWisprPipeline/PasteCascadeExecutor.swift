import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Input for a paste delivery operation. Captures session-scoped target info.
@MainActor
internal struct PasteDeliveryRequest {
    let text: String
    let targetApp: NSRunningApplication?
    let targetElement: AXUIElement?
    let restoreClipboardAfterPaste: Bool
}

/// Result of a paste delivery operation.
internal struct PasteDeliveryResult {
    let tier: PasteTier
    let durationMs: Int
}

/// Three-way classification of the focused AX element at paste time.
internal enum PasteFocusClassification: Equatable {
    /// Element present with a known text-input role. Full cascade applies.
    case textField
    /// No focused element reported (Chromium/Electron lazy-AX tree).
    /// Skip Tier 1 but still attempt Tier 2 Cmd+V.
    case missing
    /// Element present but role not in textRoles. Skip Tier 1 and Tier 2 —
    /// firing Cmd+V would go nowhere. Falls through to clipboard-only overlay.
    case nonText
}

/// Pure classification helper. Extracted for unit testing — the live cascade
/// provides the two inputs from `request.targetElement` and `isTextFieldRole`.
internal func classifyPasteFocus(elementPresent: Bool, roleIsTextField: Bool) -> PasteFocusClassification {
    guard elementPresent else { return .missing }
    return roleIsTextField ? .textField : .nonText
}

extension PasteFocusClassification {
    /// Whether a key-based paste (Tier 2 Cmd+V / Tier 2b AppleScript) should be
    /// attempted. True for `.textField` and `.missing`; false for `.nonText`.
    var canAttemptKeyPaste: Bool {
        switch self {
        case .textField, .missing: return true
        case .nonText: return false
        }
    }
}

/// Executes the tiered paste cascade: AX direct -> CGEvent Cmd+V -> AppleScript -> clipboard.
///
/// Thin orchestrator over PasteService static methods. Both pipelines call this
/// instead of owning their own paste logic. The cascade is OS-integration code
/// that must exist in exactly one place to prevent drift.
@MainActor
internal final class PasteCascadeExecutor {

    func deliver(_ request: PasteDeliveryRequest) async -> PasteDeliveryResult {
        let pasteStart = CFAbsoluteTimeGetCurrent()
        let bundleId = request.targetApp?.bundleIdentifier ?? "unknown"
        var tier: PasteTier = .clipboardOnly

        // Three-way classification of the focused element (PR #220 design intent,
        // restored for Chromium/Electron contenteditable inputs — see #277).
        //
        // - textField: element present with a known text input role. Run full cascade.
        // - missing:   captureFocusedElement returned nil. Common when Chromium /
        //              Electron apps lazy-init their AX tree (systemWide focus query
        //              returns kAXErrorNoValue even though a DOM contenteditable is
        //              focused). Skip Tier 1 (no element to write to), but STILL
        //              attempt Tier 2 Cmd+V — the target usually accepts it.
        // - nonText:   element present but role not in textRoles (button, page body).
        //              Cmd+V would fire into a void; fall straight to clipboard-only
        //              with the "Copied. Press Cmd+V" overlay (PR #220's protection).
        // If Accessibility is not trusted, CGEvent Cmd+V can't paste anyway
        // (see gotchas.md § CGEvent Paste Requires Accessibility). Fall back
        // to clipboard-only + overlay so the user can press Cmd+V themselves,
        // matching PR #220's behavior rather than silently synthesizing
        // keystrokes that go nowhere.
        let axTrusted = AXIsProcessTrusted()
        let classification: PasteFocusClassification
        if !axTrusted {
            classification = classifyPasteFocus(elementPresent: true, roleIsTextField: false)
        } else if let element = request.targetElement {
            classification = classifyPasteFocus(
                elementPresent: true,
                roleIsTextField: PasteService.isTextFieldRole(element)
            )
        } else {
            classification = classifyPasteFocus(elementPresent: false, roleIsTextField: false)
        }
        let canAttemptKeyPaste = classification.canAttemptKeyPaste

        // Tier 1: AX direct insertion (only with a confirmed text field element).
        if classification == .textField, let element = request.targetElement {
            if PasteService.insertViaAccessibility(request.text, element: element) {
                tier = .axDirect
            }
        }

        // Tier 2: Activate target app + CGEvent Cmd+V. Attempted when a text field
        // was focused OR when no element was reported at all (Chromium/Electron
        // lazy-AX fallback). Skipped when a non-text element was focused so Cmd+V
        // doesn't fire into a void.
        if tier == .clipboardOnly, canAttemptKeyPaste,
           let app = request.targetApp, !app.isTerminated {
            let pollInterval = TimingConstants.activationPollIntervalMs
            let timeout = TimingConstants.activationTimeoutMs

            _ = PasteService.forceActivateApp(pid: app.processIdentifier)
            app.activate()
            var elapsed = 0
            while elapsed < timeout {
                try? await Task.sleep(for: .milliseconds(pollInterval))
                elapsed += pollInterval
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    break
                }
                if elapsed % 300 < pollInterval {
                    _ = PasteService.forceActivateApp(pid: app.processIdentifier)
                    app.activate()
                }
            }

            let activated = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

            if activated {
                let snapshot: ClipboardSnapshot? = request.restoreClipboardAfterPaste
                    ? PasteService.saveClipboard()
                    : nil
                let changeCountAfterPaste = PasteService.pasteToActiveApp(request.text)
                tier = .cgEvent
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
                }
            } else {
                // Tier 2b: AppleScript Edit > Paste
                _ = PasteService.forceActivateApp(pid: app.processIdentifier)
                app.activate()
                try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                let snapshot: ClipboardSnapshot? = request.restoreClipboardAfterPaste
                    ? PasteService.saveClipboard()
                    : nil
                let changeCount = PasteService.copyToClipboardReturningChangeCount(request.text)
                if PasteService.pasteViaAppleScript(pid: app.processIdentifier) {
                    tier = .appleScript
                }
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCount)
                }
            }
        }

        // Tier 3: Clipboard fallback.
        // The "non-text element focused" log fires only when we deliberately skipped
        // Tier 2 because a non-text element was focused (PR #220's void-protection
        // path). Nil-element paths reach Tier 2 and log their own tier=cgevent.
        if tier == .clipboardOnly {
            PasteService.copyToClipboard(request.text)
            if !canAttemptKeyPaste {
                Task { await AppLogger.shared.log(
                    "Paste cascade: non-text element focused, falling back to clipboard-only",
                    level: .info, category: "PipelineTiming"
                ) }
            }
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - pasteStart) * 1000)
        Task { await AppLogger.shared.log(
            "Paste cascade: tier=\(tier.rawValue), app=\(bundleId), duration=\(durationMs)ms",
            level: .info, category: "PipelineTiming"
        ) }
        return PasteDeliveryResult(tier: tier, durationMs: durationMs)
    }
}
