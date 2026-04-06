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

        // Tier 1: AX direct insertion
        if let element = request.targetElement {
            if PasteService.insertViaAccessibility(request.text, element: element) {
                tier = .axDirect
            }
        }

        // Tier 2: Activate target app + CGEvent Cmd+V
        // Uses AX force-activate (kAXFrontmostAttribute) to bypass macOS 14+
        // restrictions on background processes stealing focus.
        if tier == .clipboardOnly, let app = request.targetApp, !app.isTerminated {
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

        // Tier 3: Clipboard fallback
        if tier == .clipboardOnly {
            PasteService.copyToClipboard(request.text)
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - pasteStart) * 1000)
        Task { await AppLogger.shared.log(
            "Paste cascade: tier=\(tier.rawValue), app=\(bundleId), duration=\(durationMs)ms",
            level: .info, category: "PipelineTiming"
        ) }
        return PasteDeliveryResult(tier: tier, durationMs: durationMs)
    }
}
