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

/// Typed outcome of a paste delivery operation. Authoritative input for both
/// UI overlay decisions and Sentry telemetry — decouples the two from the
/// stringly-typed `pasteTier` metric (issue #285).
internal enum PasteDeliveryOutcome: Equatable, Sendable {
  case delivered(tier: PasteTier, durationMs: Int)
  case clipboardOnly(
    tiersAttempted: [PasteTier],
    focus: PasteFocusClassification,
    targetBundleID: String?,
    accessibilityTrusted: Bool,
    targetDiagnostics: PasteElementDiagnostics
  )
  case clipboardOnlyAccessibilityDenied(targetBundleID: String?)
  case cgEventCreationFailed(accessibilityTrusted: Bool)
}

/// Result of a paste delivery operation.
internal struct PasteDeliveryResult {
  let tier: PasteTier
  let durationMs: Int
  let outcome: PasteDeliveryOutcome

  var pasteTierLabel: String {
    if case .clipboardOnlyAccessibilityDenied = outcome {
      return "clipboard_only_ax_denied"
    }
    return tier.rawValue
  }
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
/// provides the inputs from `request.targetElement` and `isTextFieldRole`.
///
/// #729: when the focused element is non-text AND the target app is a known
/// web-wrapper packager (Pake / Tauri), classify as `.missing` instead of
/// `.nonText` so Tier 2 Cmd+V is still attempted. The wrapper's outer AX
/// tree exposes an `AXGroup` container, but the inner web view's
/// contenteditable accepts CGEvent paste — same shape as the Chromium /
/// Electron lazy-AX case. Native Mac apps with a focused non-text element
/// (button, image, page body) continue to fall through to clipboard-only.
internal func classifyPasteFocus(
  elementPresent: Bool,
  roleIsTextField: Bool,
  targetBundleID: String? = nil
) -> PasteFocusClassification {
  guard elementPresent else { return .missing }
  if roleIsTextField { return .textField }
  if isKnownWebWrapperBundle(targetBundleID) { return .missing }  // #729
  return .nonText
}

/// #729 — bundle-id prefixes for known web-wrapper packagers. Conservative
/// list: only prefixes that no native macOS app uses in practice. Each
/// addition needs a real signal (Sentry event or user report) — not
/// speculative widening, because a false positive fires Cmd+V into a void.
///
/// - `com.pake.*` — Pake (github.com/tw93/Pake). Production format is
///   `com.pake.<hash>` (e.g. `com.pake.c6796d` from #729's Sentry event).
/// - `com.tauri.*` — Tauri (tauri.app) default/dev builds. Production Tauri
///   apps usually rebrand to a custom bundle id, so this only catches the
///   un-rebranded subset.
internal func isKnownWebWrapperBundle(_ bundleID: String?) -> Bool {
  guard let bundleID else { return false }
  if bundleID.hasPrefix("com.pake.") { return true }
  if bundleID.hasPrefix("com.tauri.") { return true }
  return false
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
    // Tracked for `.clipboardOnly` outcome construction.
    var tiersAttempted: [PasteTier] = []
    var cgEventFailureAccessibilityTrusted: Bool? = nil
    // Per-tier failure reasons (issue #313). Keyed by a short stage label
    // (`ax_direct`, `cgevent`, `applescript`, `activation`) rather than by
    // PasteTier so activation timeout, which happens before any tier is
    // attempted, can also be recorded. Populated only on failure paths;
    // attached to the `.clipboardOnly` Sentry payload as `paste.tier_failures`.
    var tierFailures: [String: String] = [:]
    // #729 Tier 2c menu-paste probe outcome, used to compute `paste.focus_class`.
    // nil = the menu probe never ran (not a `.nonText` path, or activation
    // timed out before probing) → no `focus_class` value is emitted.
    var menuProbe: MenuPasteProbe? = nil

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
    let targetDiagnostics: PasteElementDiagnostics
    // #729: thread the target app's bundle id through the classifier so known
    // web-wrapper packagers (Pake, Tauri) don't fall to clipboard-only on
    // their outer AXGroup container. ONLY applied when AX is trusted —
    // promoting to `.missing` in the AX-denied branch would attempt Cmd+V
    // anyway (it can't paste without AX) and would bypass the educational
    // accessibility-denied toast that the former root state surfaces via the existing
    // `.clipboardOnlyAccessibilityDenied` outcome.
    let targetBundleID = request.targetApp?.bundleIdentifier
    if !axTrusted {
      classification = classifyPasteFocus(
        elementPresent: true, roleIsTextField: false, targetBundleID: nil)
      targetDiagnostics = .unavailable
    } else if let element = request.targetElement {
      classification = classifyPasteFocus(
        elementPresent: true,
        roleIsTextField: PasteService.isTextFieldRole(element),
        targetBundleID: targetBundleID
      )
      // Role/subrole are read at paste time from the captured AXUIElement handle.
      targetDiagnostics = PasteService.capturedElementDiagnostics(element)
    } else {
      classification = classifyPasteFocus(
        elementPresent: false, roleIsTextField: false, targetBundleID: targetBundleID)
      targetDiagnostics = .missing
    }
    let canAttemptKeyPaste = classification.canAttemptKeyPaste

    // Tier 1: AX direct insertion (only with a confirmed text field element).
    if classification == .textField, let element = request.targetElement {
      tiersAttempted.append(.axDirect)
      if PasteService.insertViaAccessibility(request.text, element: element) {
        tier = .axDirect
      } else {
        tierFailures["ax_direct"] = "refused"
        emitTierFailureBreadcrumb(stage: "ax_direct", reason: "refused", bundleId: bundleId)
      }
    }

    // Tier 2: Activate target app + CGEvent Cmd+V. Attempted when a text field
    // was focused OR when no element was reported at all (Chromium/Electron
    // lazy-AX fallback). Skipped when a non-text element was focused so Cmd+V
    // doesn't fire into a void.
    if tier == .clipboardOnly, canAttemptKeyPaste,
      let app = request.targetApp, !app.isTerminated
    {
      let activation = await activate(app)
      let activated = activation.activated
      let elapsed = activation.elapsed

      if activated {
        tiersAttempted.append(.cgEvent)
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste
          ? PasteService.saveClipboard()
          : nil
        let dispatchResult = PasteService.pasteToActiveApp(request.text)
        switch dispatchResult {
        case .dispatched:
          tier = .cgEvent
        case .cgEventCreationFailed(let accessibilityTrusted, _):
          cgEventFailureAccessibilityTrusted = accessibilityTrusted
          tierFailures["cgevent"] = "creation_failed (ax_trusted=\(accessibilityTrusted))"
          emitTierFailureBreadcrumb(
            stage: "cgevent",
            reason: "creation_failed (ax_trusted=\(accessibilityTrusted))",
            bundleId: bundleId
          )
        }
        if let snapshot {
          try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
          PasteService.restoreClipboard(
            snapshot, changeCountAfterPaste: dispatchResult.changeCount)
        }
      } else {
        // Activation timed out. Record it as a distinct failure stage so
        // Sentry can separate "target app never came frontmost" from
        // "cgevent failed on the frontmost app".
        tierFailures["activation"] = "timeout_ms=\(elapsed)"
        emitTierFailureBreadcrumb(
          stage: "activation", reason: "timeout_ms=\(elapsed)", bundleId: bundleId
        )
        // Tier 2b: AppleScript Edit > Paste
        tiersAttempted.append(.appleScript)
        _ = PasteService.forceActivateApp(pid: app.processIdentifier)
        app.activate()
        try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste
          ? PasteService.saveClipboard()
          : nil
        let changeCount = PasteService.copyToClipboardReturningChangeCount(request.text)
        if PasteService.pasteViaAppleScript(pid: app.processIdentifier) {
          tier = .appleScript
        } else {
          tierFailures["applescript"] = "refused"
          emitTierFailureBreadcrumb(stage: "applescript", reason: "refused", bundleId: bundleId)
        }
        if let snapshot {
          try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
          PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCount)
        }
      }
    }

    // Tier 2c: Language-agnostic Edit > Paste for non-text container roles (#729).
    // Word/Excel/Numbers/OneNote expose their editor as a container AX role, so
    // Tier 2's blind Cmd+V is skipped (canAttemptKeyPaste == false) to avoid
    // firing into a void. Instead we activate the app (snap-back), put our text
    // on the clipboard, then drive the app's OWN Edit > Paste command, found by
    // its ⌘V shortcut. The command's enabled-state separates a real editor
    // (Scenario B — paste it) from no-field-focused (Scenario A — overlay).
    if tier == .clipboardOnly, classification == .nonText, axTrusted,
      let app = request.targetApp, !app.isTerminated
    {
      let activation = await activate(app)
      if activation.activated {
        // Put our text on the clipboard BEFORE probing enabled-state: apps grey
        // out Paste when the clipboard is empty/incompatible (#729 Codex r1).
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste ? PasteService.saveClipboard() : nil
        let changeCount = PasteService.copyToClipboardReturningChangeCount(request.text)
        if let menuItem = PasteService.findPasteMenuItem(pid: app.processIdentifier),
          PasteService.isMenuItemEnabled(menuItem)
        {
          // Scenario B: a real paste target. Enabled item found.
          menuProbe = .targetEnabled
          tiersAttempted.append(.menuPaste)
          if PasteService.pressMenuItem(menuItem) {
            tier = .menuPaste
            // Restore the user's prior clipboard after the paste lands.
            if let snapshot {
              try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
              PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCount)
            }
          } else {
            // Enabled but AXPress failed. Leave request.text on the clipboard
            // (do NOT restore) so the user's manual Cmd+V still works.
            tierFailures["menu_paste"] = "press_failed"
            emitTierFailureBreadcrumb(
              stage: "menu_paste", reason: "press_failed", bundleId: bundleId)
          }
        } else {
          // Scenario A (or item disabled/absent): no paste target. Leave
          // request.text on the clipboard; Tier 3 overlay follows.
          menuProbe = .noTarget
        }
      } else {
        // Activation timed out for .nonText: do NOT route to the English-only
        // Tier 2b AppleScript path (that fallback is for the key-paste-eligible
        // branch). Fall to clipboard-only; the probe never ran, so no focus_class.
        tierFailures["activation"] = "timeout_ms=\(activation.elapsed)"
        emitTierFailureBreadcrumb(
          stage: "activation", reason: "timeout_ms=\(activation.elapsed)", bundleId: bundleId)
      }
    }

    // Tier 3: Clipboard fallback.
    // The "non-text element focused" log fires only when we deliberately skipped
    // Tier 2 because a non-text element was focused (PR #220's void-protection
    // path). Nil-element paths reach Tier 2 and log their own tier=cgevent.
    if tier == .clipboardOnly {
      PasteService.copyToClipboard(request.text)
      if !canAttemptKeyPaste {
        Task {
          await AppLogger.shared.log(
            "Paste cascade: non-text element focused, falling back to clipboard-only",
            level: .info, category: "PipelineTiming"
          )
        }
      }
    }

    let durationMs = Int((CFAbsoluteTimeGetCurrent() - pasteStart) * 1000)
    Task {
      await AppLogger.shared.log(
        "Paste cascade: tier=\(tier.rawValue), app=\(bundleId), duration=\(durationMs)ms",
        level: .info, category: "PipelineTiming"
      )
    }

    // Construct typed outcome. `cgEventCreationFailed` takes priority over
    // `clipboardOnly` when both would be true — CGEvent failure is a more
    // specific diagnosis than generic fallback.
    let outcome: PasteDeliveryOutcome
    if tier != .clipboardOnly {
      outcome = .delivered(tier: tier, durationMs: durationMs)
    } else if let accessibilityTrusted = cgEventFailureAccessibilityTrusted {
      outcome = .cgEventCreationFailed(accessibilityTrusted: accessibilityTrusted)
    } else if !axTrusted {
      outcome = .clipboardOnlyAccessibilityDenied(
        targetBundleID: request.targetApp?.bundleIdentifier)
    } else {
      outcome = .clipboardOnly(
        tiersAttempted: tiersAttempted,
        focus: classification,
        targetBundleID: request.targetApp?.bundleIdentifier,
        accessibilityTrusted: axTrusted,
        targetDiagnostics: targetDiagnostics
      )
    }

    emitPasteTelemetry(
      outcome: outcome, tierFailures: tierFailures, focusClass: menuProbe?.focusClassLabel)

    return PasteDeliveryResult(tier: tier, durationMs: durationMs, outcome: outcome)
  }

  /// #729 Tier 2c menu-paste probe outcome. Drives `paste.focus_class`.
  enum MenuPasteProbe {
    /// An enabled Edit > Paste item was found (Scenario B — real paste target).
    case targetEnabled
    /// The item was absent or disabled (Scenario A — no paste target).
    case noTarget

    var focusClassLabel: String {
      switch self {
      case .targetEnabled: return "non_text_with_paste_target"
      case .noTarget: return "no_paste_target"
      }
    }
  }

  /// Activate `app` and poll until it is frontmost or the activation timeout
  /// elapses. Re-issues activation every ~300ms. Returns whether the app became
  /// frontmost and how long we waited. Shared by Tier 2 (Cmd+V) and Tier 2c
  /// (menu paste).
  private func activate(_ app: NSRunningApplication) async -> (activated: Bool, elapsed: Int) {
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
    let activated =
      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    return (activated, elapsed)
  }

  /// Fires Sentry captureError for non-delivered outcomes. Owned by the cascade
  /// so overlay UI and telemetry both derive from the same typed outcome.
  private func emitPasteTelemetry(
    outcome: PasteDeliveryOutcome, tierFailures: [String: String], focusClass: String?
  ) {
    switch outcome {
    case .delivered:
      return
    case .clipboardOnly(let tiers, let focus, let bundle, let accessibilityTrusted, let diagnostics):
      let tierStrings = tiers.map(\.rawValue)
      let err = HeartPathError.pasteCascadeClipboardFallback(
        tiersAttempted: tierStrings,
        focusClassification: focus.telemetryLabel,
        targetBundleID: bundle
      )
      SentryBreadcrumb.captureError(
        err,
        category: .pasteFailed,
        stage: "paste",
        extra: Self.clipboardOnlyTelemetryExtra(
          tiersAttempted: tierStrings,
          focus: focus,
          targetBundleID: bundle,
          accessibilityTrusted: accessibilityTrusted,
          targetDiagnostics: diagnostics,
          tierFailures: tierFailures,
          focusClass: focusClass
        )
      )
    case .cgEventCreationFailed(let accessibilityTrusted):
      let err = HeartPathError.pasteCGEventCreationFailed(
        accessibilityTrusted: accessibilityTrusted)
      SentryBreadcrumb.captureError(
        err,
        category: .pasteFailed,
        stage: "paste",
        extra: [
          "paste.outcome": "cgevent_creation_failed",
          "paste.accessibility_trusted": accessibilityTrusted,
          "paste.cgevent_failed": true,
          "paste.tier_failures": tierFailures,
        ]
      )
    case .clipboardOnlyAccessibilityDenied(let targetBundleID):
      SentryBreadcrumb.add(
        stage: "paste",
        message: "paste.outcome=clipboard_only_ax_denied",
        level: .info,
        data: [
          "target_bundle_id": targetBundleID ?? "unknown",
          "paste.accessibility_trusted": false,
        ]
      )
    }
  }

  internal static func clipboardOnlyTelemetryExtra(
    tiersAttempted: [String],
    focus: PasteFocusClassification,
    targetBundleID: String?,
    accessibilityTrusted: Bool,
    targetDiagnostics: PasteElementDiagnostics,
    tierFailures: [String: String],
    focusClass: String? = nil
  ) -> [String: Any] {
    var extra: [String: Any] = [
      "paste.tiers_attempted": tiersAttempted,
      "paste.focus_classification": focus.telemetryLabel,
      "paste.target_bundle_id": targetBundleID ?? NSNull(),
      "paste.outcome": "clipboard_only",
      "paste.tier_failures": tierFailures,
      "paste.accessibility_trusted": accessibilityTrusted,
      "paste.target_element_role": targetDiagnostics.role ?? NSNull(),
      "paste.target_element_subrole": targetDiagnostics.subrole ?? NSNull(),
      "paste.target_element_role_source": targetDiagnostics.roleSource,
      "paste.target_element_subrole_status": targetDiagnostics.subroleStatus,
    ]
    // #729: present only when the Tier 2c menu probe actually ran (Scenario
    // A/B discriminator). Absent on .textField/.missing and on activation
    // timeout before probing.
    if let focusClass {
      extra["paste.focus_class"] = focusClass
    }
    return extra
  }

  /// Emit a non-blocking Sentry breadcrumb for a single tier failure. The
  /// clipboard-only handled-error event carries the full `tier_failures` map;
  /// these breadcrumbs preserve the trail when the session reaches Sentry via
  /// an unrelated later error or crash.
  private func emitTierFailureBreadcrumb(stage: String, reason: String, bundleId: String) {
    SentryBreadcrumb.add(
      stage: "paste",
      message: "paste.tier_failed: \(stage)",
      level: .info,
      data: [
        "tier": stage,
        "reason": reason,
        "target_bundle_id": bundleId,
      ]
    )
  }
}

extension PasteFocusClassification {
  /// Stable string label for Sentry tags.
  fileprivate var telemetryLabel: String {
    switch self {
    case .textField: return "text_field"
    case .missing: return "missing"
    case .nonText: return "non_text"
    }
  }
}
