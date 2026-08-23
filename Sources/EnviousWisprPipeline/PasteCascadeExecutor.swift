import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Input for a paste delivery operation. Captures session-scoped target info.
@MainActor
internal struct PasteDeliveryRequest {
  /// Today's payload, including its trailing space. ALWAYS present, and until
  /// Chunk 7 the only payload any route submits.
  let legacyText: String
  /// The contextual candidate, or nil when no safe one exists — unreadable caret
  /// context, the setting off, or a deliberate mid-word refusal. Transported
  /// only; plan §6 owns which route may commit it.
  let repairedText: String?
  /// The exact caret context the candidate was computed from, so a later route
  /// can revalidate against the same evidence rather than re-reading.
  let caretContext: PasteService.CaretContext?
  /// Whether the candidate REMOVES words the user dictated.
  ///
  /// This is the only difference from the legacy payload that a stale caret can
  /// turn into a real loss. Every other repair rule changes a letter's case or a
  /// space, and if the caret moved, committing such a candidate costs exactly
  /// what refusing it costs — one wrong capital. Paying for a second caret read
  /// to choose between those two buys nothing, and measured on the founder's
  /// machine on 2026-08-04 it discarded CORRECT fixes on most terminal
  /// dictations, because the re-read fails far more often than the caret
  /// actually moves.
  ///
  /// The duplicate-seam rule is the exception: it drops a word from what the
  /// user said, so committing it against a stale caret loses dictated content.
  /// That case, and only that case, still earns the re-read.
  let candidateDeletesDictatedText: Bool
  let targetApp: NSRunningApplication?
  let targetElement: AXUIElement?
  /// True when the delivery-time retry was attempted. If it recovered
  /// `targetElement`, that element proves same-APP only, never same-window/tab,
  /// so every commit boundary must re-verify the field before submitting a
  /// repaired candidate.
  let targetElementIsRetried: Bool
  let restoreClipboardAfterPaste: Bool
  /// The SAME cumulative terminal-resolution budget the caret read used.
  ///
  /// One per delivery, shared by the initial resolution and every commit
  /// revalidation. A fresh budget per route would let the total wait grow with
  /// the number of routes tried, which is the bound this exists to keep.
  let terminalBudget: TerminalResolutionBudget?
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
  /// A Tier 1 Accessibility write reported success but could not be verified,
  /// so the cascade stopped rather than risk pasting twice. Distinct from
  /// `clipboardOnly` because the destination state is genuinely UNKNOWN: the
  /// text may already be in the document. The user-facing presentation is the
  /// same clipboard notice; only the typed result differs.
  case axWriteUnverifiable(
    targetBundleID: String?,
    targetDiagnostics: PasteElementDiagnostics
  )
}

/// Result of a paste delivery operation.
internal struct PasteDeliveryResult {
  let tier: PasteTier
  let durationMs: Int
  let outcome: PasteDeliveryOutcome
  /// Which payload the route that last attempted a write submitted, or nil when
  /// no route reached its write (#1785). Records what was SUBMITTED, never
  /// proof of what landed — Tier 2 only proves Cmd+V was posted.
  var submittedPayload: PasteService.PastePayloadKind?
  /// #1332. Why the Tier 1 fast route did not deliver, and both settability
  /// answers as one token. Nil when Tier 1 delivered.
  var axDeclineReason: String?
  var axSettability: String?

  var pasteTierLabel: String {
    if case .clipboardOnlyAccessibilityDenied = outcome {
      return "clipboard_only_ax_denied"
    }
    return tier.rawValue
  }
}

/// Whether the clipboard is still holding a contextual payload that must be
/// replaced with today's payload before the cascade returns.
///
/// Plan §6: no route may carry a contextual payload into a MANUAL paste. The
/// repaired text is only correct at the exact caret it was computed for, and a
/// later Cmd+V happens somewhere we have no claim about — possibly another app,
/// possibly an hour later. Three of the four conditions are what make this rule
/// narrow rather than a blanket rewrite:
///
/// - `submitted == .repaired`: nothing to undo when today's payload was used.
/// - `routeWroteClipboard`: the Tier 1 accessibility write never touches the
///   clipboard, so "restoring" after it would CLOBBER whatever the user had
///   copied with text they never asked for.
/// - `!willRestoreUserClipboard`: when the restore-clipboard setting is on, the
///   user's own snapshot goes back and takes our text with it.
/// - `!fellBackToClipboardOnly`: a failed cascade ends at Tier 3, which already
///   puts today's payload on the clipboard. A second write here would be a
///   second authority for the same rule.
internal func mustRewriteClipboardToLegacy(
  submitted: PasteService.PastePayloadKind?,
  routeWroteClipboard: Bool,
  willRestoreUserClipboard: Bool,
  fellBackToClipboardOnly: Bool
) -> Bool {
  submitted == .repaired && routeWroteClipboard && !willRestoreUserClipboard
    && !fellBackToClipboardOnly
}

/// Whether the pasteboard still holds exactly what this route put there.
///
/// The rewrite above waits for the target app to consume the posted Cmd+V, and
/// during that wait the user — or their clipboard manager — can copy something
/// else. Writing anyway would destroy it. This is the same change-count guard
/// `restoreClipboard` has always applied, asked separately here because the
/// POLICY question ("should this be rewritten at all") is answered before the
/// wait and the FRESHNESS question can only be answered after it.
///
/// Fails closed on an unknown count: if we cannot prove what is on the board is
/// ours, we do not touch it.
internal func clipboardUntouchedSinceSubmit(submitted: Int?, current: Int) -> Bool {
  guard let submitted else { return false }
  return submitted == current
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

/// What the cascade does after a Tier 1 Accessibility attempt.
///
/// Extracted as a pure mapping for the same reason `classifyPasteFocus` is: the
/// AX round-trips themselves are live-only and covered by Live UAT, while the
/// decision they feed is the part that can be wrong in a way tests can catch.
internal enum AXDirectDisposition: Equatable {
  /// Verified. Stop the cascade and report Tier 1 delivery.
  case delivered
  /// Provably nothing landed. Continue to Tier 2 exactly as before.
  case continueCascade
  /// The write may have landed but cannot be proven. Suppress every automatic
  /// retry and let the clipboard fallback carry the text, so the user is never
  /// given the same sentence twice.
  case stopUnverified

  /// The `tierFailures` reason this disposition records, or nil on success.
  var tierFailureReason: String? {
    switch self {
    case .delivered: return nil
    case .continueCascade: return "refused"
    case .stopUnverified: return "unverifiable"
    }
  }

  /// Whether any automatic paste attempt may follow. Only a provable
  /// no-mutation may retry.
  var allowsAutomaticRetry: Bool {
    switch self {
    case .delivered, .stopUnverified: return false
    case .continueCascade: return true
    }
  }
}

internal func dispositionForAXDirect(
  _ outcome: PasteService.AXInsertOutcome
) -> AXDirectDisposition {
  switch outcome {
  case .verified: return .delivered
  case .noMutation: return .continueCascade
  case .unverifiable: return .stopUnverified
  }
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
  /// The pasteboard every clipboard write in this cascade goes to.
  ///
  /// EVERY one, verified rather than asserted: an earlier version of this comment
  /// made that claim while `PasteService.pasteToActiveApp` still hard-coded
  /// `NSPasteboard.general` internally, so Tier 2 wrote the real board whatever
  /// this property held. Cloud review found it; `grep -n NSPasteboard.general` on
  /// `PasteService.swift` now returns one comment and no code.
  ///
  /// **WHAT INJECTING A NON-GENERAL BOARD MEANS, so it is not mistaken for a
  /// regression: every tier that triggers a SYSTEM paste goes inert.** Cmd+V, the
  /// AppleScript paste and the menu-item paste are all satisfied by the OS from
  /// `NSPasteboard.general`, so text written anywhere else is written correctly
  /// and pasted nowhere. That is enforced by `systemPasteCanReachOurText`, which
  /// SKIPS every system-paste tier rather than letting one run and paste the real
  /// board's contents. Only the clipboard-only fallback is meaningful with a
  /// board of your choosing, because there the user pastes by hand.
  /// That is the DESIRED behaviour rather than a limitation: a test should not be
  /// pasting into whatever app the developer has frontmost, and production passes
  /// `.general`, where every tier behaves exactly as it always has.
  ///
  /// REQUIRED, not defaulted, and that is the whole point (#2170). This type is
  /// reachable from tests through `@testable import`, and the tiers below write
  /// to it — so a defaulted `.general` would let any test that reaches the
  /// clipboard tier write the developer's real board by omission, which is the
  /// hazard this seam exists to remove.
  ///
  /// #2146 measured what a DEFAULTED capability costs on this exact surface: a
  /// name-based sweep for tests writing the real board found 7 sites, and
  /// flipping the seam's default to fail closed found 9. The two extras
  /// contained no clipboard token anywhere — they inherited the board by not
  /// passing one. A capability reached through a defaulted argument has no
  /// call-site token, so no sweep can enumerate it.
  ///
  /// There is exactly one production construction site, so requiring it is
  /// cheap. `PasteService`'s own writers keep their `.general` default: layer 1
  /// is that parameter, layer 2 is this being mandatory.
  private let pasteboard: NSPasteboard

  /// **Whether a SYSTEM PASTE can deliver what this cascade writes.**
  ///
  /// Every system-paste route — Cmd+V, AppleScript `keystroke "v"`, and an app's
  /// own Edit > Paste menu item — is satisfied by the system from
  /// `NSPasteboard.general`. None of them can be pointed anywhere else. So with
  /// any other board those routes do not merely fail to deliver our text: they
  /// deliver whatever the REAL board happens to hold, into the frontmost app.
  ///
  /// **This is one precondition rather than a guard per route, and that is the
  /// point.** Three consecutive review rounds each found a different route
  /// reaching the general board — the write, then the Cmd+V dispatch, then the
  /// AppleScript and menu paths with their clipboard snapshot/restore. Guarding
  /// them one at a time is answering "which routes touch the general board",
  /// which is a set with a next member. The closed question is this one.
  ///
  /// **ONE PREDICATE, TWO GUARD SITES.** Tiers 2 and 2b share a branch; Tier 2c
  /// (menu paste) is its SIBLING, not a child of it — an earlier version of this
  /// comment claimed all three were one branch and gated only the first, which
  /// left the menu route open under a comment saying it was covered. Tier 3 is
  /// deliberately ungated: it is the plain clipboard write, and the only route
  /// that delivers anything meaningful when the board is not the general one.
  ///
  /// Production passes `.general`, where this is always `true` and the cascade
  /// behaves exactly as it did before the board became injectable.
  private var systemPasteCanReachOurText: Bool {
    pasteboard === NSPasteboard.general
  }

  internal init(pasteboard: NSPasteboard) {
    self.pasteboard = pasteboard
  }


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
    // Why Tier 1 did not run, decided HERE rather than inside the write. These
    // are the majority of declines — a reason set covering only the write's own
    // exits would be nil for most of them (#1332).
    var axDeclineReason: PasteService.AXDeclineReason? = {
      if !axTrusted { return .accessibilityDenied }
      switch classification {
      case .textField: return nil  // Tier 1 runs; the write reports its own.
      case .missing: return .focusMissing
      case .nonText: return .focusNonText
      }
    }()
    var axSettability: PasteService.AXSettability?
    // Which payload was submitted by the route that last attempted a write.
    // Nil until one does. A later route may legitimately overwrite this: Tier 1
    // can attempt a write, PROVE nothing landed, and hand off to Tier 2, whose
    // choice is then the one the clipboard decision below has to reason about.
    var submittedKind: PasteService.PastePayloadKind?
    // The pasteboard's change count immediately after a clipboard route wrote
    // its payload. Any later write by the user or a clipboard manager advances
    // it, which is how the post-cascade rewrite below knows to keep its hands off.
    var submittedClipboardChangeCount: Int?

    // Tier 1: AX direct insertion (only with a confirmed text field element).
    //
    // `unverifiable` blocks every automatic retry below. The AX write reported
    // success and we could not prove the result, so the text may already be in
    // the user's document; a second paste would duplicate it. The user still
    // gets the text — Tier 3 puts it on the clipboard and shows the existing
    // "press Cmd+V" notice — but we never place it twice on their behalf.
    var axAllowsRetry = true
    if classification == .textField, let element = request.targetElement {
      tiersAttempted.append(.axDirect)
      // The payload choice happens INSIDE the write, against the range read in
      // the same breath as the write itself (plan §6). Nothing is chosen here.
      let insert = PasteService.insertViaAccessibility(
        legacy: request.legacyText,
        repaired: request.repairedText,
        context: request.caretContext,
        element: element,
        requireFocusedElementMatch: request.targetElementIsRetried)
      let disposition = dispositionForAXDirect(insert.outcome)
      submittedKind = insert.submitted
      axDeclineReason = insert.declineReason
      axSettability = insert.settability
      axAllowsRetry = disposition.allowsAutomaticRetry
      switch disposition {
      case .delivered:
        tier = .axDirect
      case .continueCascade, .stopUnverified:
        // `tierFailureReason` stays the single authority for these strings, so
        // the switch cannot drift from the enum.
        if let reason = disposition.tierFailureReason {
          tierFailures["ax_direct"] = reason
          emitTierFailureBreadcrumb(stage: "ax_direct", reason: reason, bundleId: bundleId)
        }
      }
    }

    // Tier 2: Activate target app + CGEvent Cmd+V. Attempted when a text field
    // was focused OR when no element was reported at all (Chromium/Electron
    // lazy-AX fallback). Skipped when a non-text element was focused so Cmd+V
    // doesn't fire into a void.
    // `axAllowsRetry` is false only after an unprovable Tier 1 write, and it
    // gates Tier 2b too because 2b lives inside this branch.
    if tier == .clipboardOnly, axAllowsRetry, canAttemptKeyPaste,
      systemPasteCanReachOurText,
      let app = request.targetApp, !app.isTerminated
    {
      let activation = await activate(app)
      let activated = activation.activated
      let elapsed = activation.elapsed

      if activated {
        tiersAttempted.append(.cgEvent)
        // Revalidated AFTER activation, because bringing the app frontmost is
        // itself capable of moving focus and selection.
        let payload = PasteService.payloadAtCommitBoundary(
          legacy: request.legacyText,
          repaired: request.repairedText,
          context: request.caretContext,
          element: request.targetElement,
          candidateDeletesDictatedText: request.candidateDeletesDictatedText,
          requireCaretUnchanged: request.targetElementIsRetried,
          terminalBudget: request.terminalBudget)
        // Snapshot AFTER that revalidation, immediately before the write. The
        // re-check makes accessibility calls, and anything copied while they run
        // would otherwise be captured as "the user's old clipboard" and then
        // restored over (Codex review r5). The window is a fraction of a
        // millisecond in practice, so this is narrowing rather than closing a
        // proven gap — taken because it costs one moved line.
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste
          ? ClipboardCleanup.snapshotForDelivery(from: pasteboard)
          : nil
        submittedKind = payload.kind
        let dispatchResult = PasteService.pasteToActiveApp(
          payload.text, to: pasteboard)
        submittedClipboardChangeCount = dispatchResult.changeCount
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
          // Scheduled, not awaited (#2197). The delay and the guard are
          // unchanged; the dictation just stops queueing behind them.
          ClipboardCleanup.scheduleRestore(
            snapshot, changeCountAfterPaste: dispatchResult.changeCount, tier: tier)
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
        // Not a clipboard delay — this waits for the activation to settle before
        // the payload is chosen. It shared `clipboardRestoreDelayMs` by accident
        // of history; #2197 gave it its own name so an edit to one cannot
        // silently retune the other.
        try? await Task.sleep(for: .milliseconds(TimingConstants.activationSettleBeforePasteMs))
        let payload = PasteService.payloadAtCommitBoundary(
          legacy: request.legacyText,
          repaired: request.repairedText,
          context: request.caretContext,
          element: request.targetElement,
          candidateDeletesDictatedText: request.candidateDeletesDictatedText,
          requireCaretUnchanged: request.targetElementIsRetried,
          terminalBudget: request.terminalBudget)
        // Same ordering as Tier 2: snapshot after the re-check, before the write.
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste
          ? ClipboardCleanup.snapshotForDelivery(from: pasteboard)
          : nil
        submittedKind = payload.kind
        let changeCount = PasteService.copyToClipboardReturningChangeCount(
          payload.text, to: pasteboard)
        submittedClipboardChangeCount = changeCount
        if PasteService.pasteViaAppleScript(pid: app.processIdentifier) {
          tier = .appleScript
        } else {
          tierFailures["applescript"] = "refused"
          emitTierFailureBreadcrumb(stage: "applescript", reason: "refused", bundleId: bundleId)
        }
        if let snapshot {
          ClipboardCleanup.scheduleRestore(
            snapshot, changeCountAfterPaste: changeCount, tier: tier)
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
    //
    // Deliberately NOT gated on `axAllowsRetry`: this branch requires
    // `.nonText` and Tier 1 only runs on `.textField`, so an unprovable Tier 1
    // write cannot reach here. Adding a guard would service an impossible state.
    if tier == .clipboardOnly, classification == .nonText, axTrusted,
      systemPasteCanReachOurText,
      let app = request.targetApp, !app.isTerminated
    {
      let activation = await activate(app)
      if activation.activated {
        // Put our text on the clipboard BEFORE probing enabled-state: apps grey
        // out Paste when the clipboard is empty/incompatible (#729 Codex r1).
        let snapshot: ClipboardSnapshot? =
          request.restoreClipboardAfterPaste
          ? ClipboardCleanup.snapshotForDelivery(from: pasteboard)
          : nil
        // Selected through the same owner as every other route. A container
        // target should never HAVE a candidate — the context reader refuses any
        // role that is not a text role — but this route asks the same question
        // rather than relying on that argument staying true.
        let payload = PasteService.payloadAtCommitBoundary(
          legacy: request.legacyText,
          repaired: request.repairedText,
          context: request.caretContext,
          element: request.targetElement,
          candidateDeletesDictatedText: request.candidateDeletesDictatedText,
          requireCaretUnchanged: request.targetElementIsRetried,
          terminalBudget: request.terminalBudget)
        submittedKind = payload.kind
        let changeCount = PasteService.copyToClipboardReturningChangeCount(
          payload.text, to: pasteboard)
        submittedClipboardChangeCount = changeCount
        switch PasteService.findPasteMenuItem(pid: app.processIdentifier) {
        case .found(let menuItem):
          switch PasteService.isMenuItemEnabled(menuItem) {
          case .enabled:
            // Scenario B: a real paste target. Enabled item found.
            menuProbe = .targetEnabled
            tiersAttempted.append(.menuPaste)
            if PasteService.pressMenuItem(menuItem) {
              tier = .menuPaste
              // Restore the user's prior clipboard after the paste lands.
              if let snapshot {
                ClipboardCleanup.scheduleRestore(
                  snapshot, changeCountAfterPaste: changeCount, tier: tier)
              }
            } else {
              // Enabled but AXPress failed. Leave the payload on the clipboard
              // (do NOT restore) so the user's manual Cmd+V still works.
              tierFailures["menu_paste"] = "press_failed"
              emitTierFailureBreadcrumb(
                stage: "menu_paste", reason: "press_failed", bundleId: bundleId)
            }
          case .disabled:
            // Scenario A: item found but disabled. Leave the payload on the
            // clipboard; Tier 3 overlay follows.
            menuProbe = .noTarget
          case .unreadable:
            // Enabled-state AX read failed — unknown, not a confirmed refusal.
            menuProbe = .unreadable
          }
        case .confirmedAbsent:
          // Scenario A: no paste target. Leave the payload on the clipboard;
          // Tier 3 overlay follows.
          menuProbe = .noTarget
        case .depthLimited:
          // We stopped looking before the tree ran out. Not a confirmed
          // refusal, and delivery is unaffected — this behaves exactly as
          // `.unreadable` does here (#1332).
          menuProbe = .depthLimited
        case .unreadable:
          // Menu bar (or traversal) AX read failed — unknown, not a confirmed
          // refusal (#1435). Since #1332 this ALSO includes the one-second AX
          // messaging timeout, which was never in force before. A slow or
          // unknown probe deliberately keeps full alerting rather than becoming
          // `no_paste_target`, so this branch can raise the alert count on a
          // slow app even though the change as a whole reduces it.
          menuProbe = .unreadable
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
      PasteService.copyToClipboard(request.legacyText, to: pasteboard)
      // An earlier route may have SUBMITTED the contextual payload and failed.
      // What the user can now paste by hand is this legacy text, so that is what
      // the record has to say (Codex review r4) — otherwise the field reports a
      // contextual paste for a dictation the user pasted manually from today's
      // payload.
      submittedKind = .legacy
      if !canAttemptKeyPaste {
        Task {
          await AppLogger.shared.log(
            "Paste cascade: non-text element focused, falling back to clipboard-only",
            level: .info, category: "PipelineTiming"
          )
        }
      }
    } else if mustRewriteClipboardToLegacy(
      submitted: submittedKind,
      routeWroteClipboard: tier != .axDirect,
      willRestoreUserClipboard: request.restoreClipboardAfterPaste,
      fellBackToClipboardOnly: false)
    {
      // A clipboard route delivered contextual text and nothing else is going to
      // clear it. The wait exists for the same reason the restore path waits: the
      // Cmd+V we posted is read by the target app asynchronously, and replacing
      // the clipboard underneath it would deliver today's payload instead of the
      // one we just chose — silently undoing the feature at the last step.
      //
      // Scheduled rather than awaited (#2197). The freshness guard still runs
      // AFTER the wait, inside the scheduled body, because the POLICY question
      // was answered here and the FRESHNESS question can only be answered later.
      if let submitted = submittedClipboardChangeCount {
        ClipboardCleanup.scheduleLegacyRewrite(
          legacyText: request.legacyText, submittedChangeCount: submitted, tier: tier)
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
    } else if !axAllowsRetry {
      // Only an unprovable Tier 1 write clears this flag, and Tier 1 runs only
      // on a trusted, text-field-classified element — so no other fallback
      // diagnosis can apply here.
      outcome = .axWriteUnverifiable(
        targetBundleID: request.targetApp?.bundleIdentifier,
        targetDiagnostics: targetDiagnostics
      )
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
      outcome: outcome, tierFailures: tierFailures, focusClass: menuProbe?.focusClassLabel,
      axDeclineReason: axDeclineReason?.rawValue,
      axSettability: axSettability?.telemetryValue)

    return PasteDeliveryResult(
      tier: tier, durationMs: durationMs, outcome: outcome, submittedPayload: submittedKind,
      axDeclineReason: axDeclineReason?.rawValue, axSettability: axSettability?.telemetryValue)
  }

  /// #729 Tier 2c menu-paste probe outcome. Drives `paste.focus_class`.
  enum MenuPasteProbe {
    /// An enabled Edit > Paste item was found (Scenario B — real paste target).
    case targetEnabled
    /// The item was confirmed absent or confirmed disabled (Scenario A — no
    /// paste target).
    case noTarget
    /// An AX read failed somewhere in the probe (menu bar, traversal, or
    /// enabled-state) — unknown, NOT a confirmed refusal (#1435).
    case unreadable
    /// The traversal hit its own depth bound with menus it never opened —
    /// unknown, and unknown for a DIFFERENT reason than `.unreadable`: nothing
    /// failed, we stopped. Kept separate so #1332's suppression projection can
    /// be measured rather than assumed.
    case depthLimited

    var focusClassLabel: String {
      switch self {
      case .targetEnabled: return "non_text_with_paste_target"
      case .noTarget: return "no_paste_target"
      case .unreadable: return "non_text_menu_unreadable"
      case .depthLimited: return "non_text_menu_depth_limit"
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
    outcome: PasteDeliveryOutcome, tierFailures: [String: String], focusClass: String?,
    axDeclineReason: String? = nil, axSettability: String? = nil
  ) {
    switch outcome {
    case .delivered:
      return
    case .clipboardOnly(let tiers, let focus, let bundle, let accessibilityTrusted, let diagnostics):
      let tierStrings = tiers.map(\.rawValue)
      let extra = Self.clipboardOnlyTelemetryExtra(
        axDeclineReason: axDeclineReason,
        axSettability: axSettability,
        tiersAttempted: tierStrings,
        focus: focus,
        targetBundleID: bundle,
        accessibilityTrusted: accessibilityTrusted,
        targetDiagnostics: diagnostics,
        tierFailures: tierFailures,
        focusClass: focusClass
      )
      if Self.isExpectedNonTextRefusal(
        tiersAttempted: tierStrings,
        focus: focus,
        focusClass: focusClass,
        targetBundleID: bundle
      ) {
        SentryBreadcrumb.add(
          stage: "paste",
          message: "paste.outcome=clipboard_only_no_target",
          level: .info,
          data: extra
        )
      } else {
        let err = HeartPathError.pasteCascadeClipboardFallback(
          tiersAttempted: tierStrings,
          focusClassification: focus.telemetryLabel,
          targetBundleID: bundle
        )
        SentryBreadcrumb.captureError(err, category: .pasteFailed, stage: "paste", extra: extra)
      }
    case .axWriteUnverifiable(let bundle, let diagnostics):
      // Reuses the clipboard-fallback payload shape so there is one authority
      // for it. `focus` and `accessibilityTrusted` are invariants of this case,
      // not assumptions: Tier 1 runs only when the element classified as
      // `.textField` and Accessibility is trusted. The distinguishing signal is
      // `paste.tier_failures["ax_direct"] == "unverifiable"`.
      let tierStrings = [PasteTier.axDirect.rawValue]
      let extra = Self.clipboardOnlyTelemetryExtra(
        axDeclineReason: axDeclineReason,
        axSettability: axSettability,
        tiersAttempted: tierStrings,
        focus: .textField,
        targetBundleID: bundle,
        accessibilityTrusted: true,
        targetDiagnostics: diagnostics,
        tierFailures: tierFailures,
        focusClass: nil
      )
      let err = HeartPathError.pasteCascadeClipboardFallback(
        tiersAttempted: tierStrings,
        focusClassification: PasteFocusClassification.textField.telemetryLabel,
        targetBundleID: bundle
      )
      SentryBreadcrumb.captureError(err, category: .pasteFailed, stage: "paste", extra: extra)
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

  /// Whether a clipboard-only outcome is a CONFIRMED correct refusal, and so
  /// belongs on the counted breadcrumb channel rather than the alerting error
  /// channel (#1430, narrowed #1332). False in every other case, because
  /// anything short of full confirmation could be a real, scaling defect.
  ///
  /// Requires exact confirmation (`focusClass == "no_paste_target"`) rather than
  /// defaulting an absent probe result to "no target": `canAttemptKeyPaste` is
  /// always false for `.nonText`, so Tier 2c's menu probe is the ONLY paste
  /// attempt for a non-text target, and `focusClass` is nil whenever that probe
  /// never ran or never resolved — activation timeout, a terminated target app,
  /// or no target app captured at all — none of which is a confirmed refusal
  /// (Codex code-diff review r2, #1430). `"non_text_with_paste_target"` means
  /// the probe found a real, enabled paste target and pressing it failed, which
  /// is a real failure rather than a refusal (Codex code-diff review r1). Any
  /// other or future label fails closed the same way.
  ///
  /// `roleSource` was a parameter until #1332 and is deliberately gone rather
  /// than merely unread. It required the ELEMENT's role to have been captured
  /// before trusting the MENU probe's answer, which lets one instrument's
  /// failure suppress the other instrument's positive result. The menu probe is
  /// independent evidence: since #1435 `no_paste_target` means the app's own
  /// menu bar was read and its Paste command is confirmed absent or confirmed
  /// disabled, and since this issue's Chunk 1a a search that merely ran out of
  /// depth reports `non_text_menu_depth_limit` instead of masquerading as a
  /// confirmation. Removing the parameter rather than ignoring it turns the
  /// stale `unrecognizedRoleSourceFailsClosed` test into a compile error rather
  /// than a test that keeps passing under a comment describing a literal
  /// nothing reads.
  ///
  /// KNOWN RESIDUAL, stated so this is not read as claiming more than it
  /// proves: a real text target whose role read fails classifies as `.nonText`,
  /// and if that app ALSO reports its Paste command absent or disabled it is
  /// silenced here. A failed role read is NO answer rather than a wrong one, so
  /// the residual needs one independent role-read failure plus a misleading menu
  /// answer. Chunks 0 and 1a narrow it to that; they do not eliminate it.
  internal static func isExpectedNonTextRefusal(
    tiersAttempted: [String],
    focus: PasteFocusClassification,
    focusClass: String?,
    targetBundleID: String?
  ) -> Bool {
    // `paste_failed` should mean a paste we ATTEMPTED that failed. Every real
    // route appends its tier before trying (ax_direct, cgevent, applescript,
    // menu_paste), so a non-empty list is proof something was attempted and
    // this is not a refusal at all.
    guard tiersAttempted.isEmpty else { return false }
    // The Mac is locked. There is no session to paste into, and no reading of
    // the focused element can make one appear.
    if targetBundleID == "com.apple.loginwindow" { return true }
    return focus == .nonText && focusClass == "no_paste_target"
  }

  internal static func clipboardOnlyTelemetryExtra(
    axDeclineReason: String? = nil,
    axSettability: String? = nil,
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
    // #1332: WHY the fast route declined, and both settability answers as one
    // token. Genuinely OMITTED when nil rather than sent as a placeholder — a
    // sentinel string would be indistinguishable from a real value in every
    // query built on this, and older event shapes must stay unchanged.
    if let axDeclineReason { extra["paste.ax_decline_reason"] = axDeclineReason }
    if let axSettability { extra["paste.ax_settability"] = axSettability }
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
