import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - Shared Lock State

/// Observable state holder for hands-free lock mode.
/// Shared between RecordingOverlayPanel and RecordingOverlayView so that
/// locking mid-recording triggers a reactive SwiftUI update (with animation)
/// without tearing down and recreating the panel.
@MainActor
@Observable
final class OverlayLockState {
  var isLocked: Bool = false
}

/// Observable holder for the transient in-panel notice banner (#1060).
/// Shared between RecordingOverlayPanel and RecordingOverlayView so a notice can
/// morph the live recording pill (a banner inside the same capsule) WITHOUT
/// tearing the panel down — the existing `.warning`/`presentTransientNotice`
/// paths all rebuild the single panel and would lose the `.recording` state.
@MainActor
@Observable
final class OverlayNoticeState {
  var message: String? = nil
}

// MARK: - RecordingOverlayPanel

/// Floating overlay panel that shows recording and polishing status.
/// Uses NSPanel with .nonactivatingPanel behavior so it floats above all apps
/// without stealing focus.
@MainActor
final class RecordingOverlayPanel {
  private var panel: NSPanel?

  /// Reactive lock state shared with RecordingOverlayView.
  private let lockState = OverlayLockState()

  /// Reactive transient-notice state shared with RecordingOverlayView (#1060).
  private let noticeState = OverlayNoticeState()

  /// Pending auto-clear for the transient notice banner.
  private var noticeDismissWork: DispatchWorkItem?

  /// Monotonically-increasing generation token. Incremented on every show/hide
  /// call. The DispatchQueue.main.async closures capture their token at dispatch
  /// time and bail out silently if a newer operation has superseded them before
  /// they run. This eliminates all "async outlives state" races (H8, H9).
  private var generation: UInt64 = 0

  /// Pending deferred panel-creation work item. Stored so hide() can cancel
  /// it before it fires — this is stronger than the generation check alone,
  /// because it prevents the closure from running at all even when ESC is
  /// pressed within a single run-loop cycle of show().
  private var pendingCreateWork: DispatchWorkItem?

  /// Last intent shown — guards against redundant show calls that would
  /// close and recreate the panel for the same visual state (flicker).
  /// `private(set)`: the former root state reads this for the F14 chip-priority guard (chip
  /// shows only when `currentIntent == .hidden`).
  private(set) var currentIntent: OverlayIntent = .hidden

  /// Local, generation-stamped ownership record for the bulk-import-status
  /// pill (#1701 Phase 3 review finding B). Deliberately NOT an `OverlayIntent`
  /// case — that enum is the dictation/processing pipeline's own intent set;
  /// import-status UI ownership is local to this panel. The generation match
  /// is the ownership proof: a stale import record can never authorize
  /// closing a panel a newer recording or processing transition created.
  private struct ImportStatusPresentation {
    let generation: UInt64
    let message: String
  }
  private var importStatusPresentation: ImportStatusPresentation?
  private var importStatusOwnsCurrentSlot: Bool {
    currentIntent == .hidden && importStatusPresentation?.generation == generation
  }

  /// Tracks lock state for flicker guard comparison.
  private var isRecordingLocked: Bool = false

  private var accessibilityToastShownThisSession: Bool = false
  private var grantHandler: (() -> Void)?
  private var accessibilityWarningDismissedProvider: () -> Bool = { false }
  /// #1988: live preview. Defaults keep every existing caller (and every test that
  /// constructs a panel directly) on today's behavior and today's pill size.
  private var livePreviewEnabledProvider: () -> Bool = { false }
  private var livePreviewDisplayProvider: () -> LivePreviewDisplay = { .off }
  private var recordingIntentObserver: (Bool) -> Void = { _ in }
  /// #1063 PR2 — invoked when the user taps Discard on the "recovering" pill.
  /// Wired by the composition root to `RecoveryCoordinator.discardActiveRecovery`.
  private var discardRecoveryHandler: (() -> Void)?

  // Passive chip handlers — installed by the former root state once at init, invoked by the
  // chip view when the user taps Lock / Dismiss or when the auto-dismiss timer
  // fires. The closures are MainActor-bound; the panel itself is @MainActor.
  private var passiveChipLockHandler: (() -> Void)?
  private var passiveChipDismissHandler: (() -> Void)?

  /// #2087 — invoked when the user presses Paste on the Escape Recovery pill.
  ///
  /// Carries the WHOLE payload, not just the row id. An earlier draft passed the
  /// id alone, which quietly made the feature's own promise unreachable: the
  /// payload exists to hold the paste TARGET — the app and field the dictation
  /// was aimed at, captured before the terminal cleanup nils them — and the
  /// promise is to put the text back where it was going, not merely somewhere.
  ///
  /// It carries no TEXT, and that part was right. The pill may sit for its full
  /// dwell while the row is deleted or expires underneath it, so whoever handles
  /// this re-reads by id and no-ops if there is nothing there.
  ///
  /// Unbound today; binding it to the paste cascade is chunk 8b's, and needs the
  /// pending-row read that chunk 9 owns.
  var onEscapeRecoveryPaste: ((CancelUndoPayload) -> Void)?

  /// The payload for the pill currently showing, held because
  /// `OverlayIntent` is `Sendable` and cannot carry main-actor AX handles.
  ///
  /// Cleared whenever the offer ends: consumed by press or expiry, replaced by
  /// another intent, or hidden directly. Replacement is the one with no teardown
  /// of its own, and the one whose failure is worst: a payload outliving its
  /// pill could paste a later recovery into the app this one was aimed at.
  private var escapeRecoveryPayload: CancelUndoPayload?

  /// Take the payload ONLY if it is still the one the caller was showing (#2087).
  ///
  /// Panel replacement can be DEFERRED while the user is dragging the overlay,
  /// so an outgoing pill's SwiftUI callbacks can still fire after a newer pill
  /// has stored its own payload. Without the id match, the old view's expiry
  /// would clear the new offer, or its Paste would restore the new row from the
  /// old pill's press — a click the user aimed at different text.
  ///
  /// Consuming and matching in one step, for the same reason
  /// `EscapeRecoveryCompletionSlot.take()` is: a check followed by a separate
  /// clear is two chances to get the ordering wrong.
  private func takeEscapeRecoveryPayload(matching id: UUID) -> CancelUndoPayload? {
    guard let payload = escapeRecoveryPayload, payload.transcriptID == id else { return nil }
    escapeRecoveryPayload = nil
    return payload
  }

  /// The pair of callbacks a pill hands its view, built together so both guards
  /// sit in one screenful and a change to one is read beside the other. That is
  /// a legibility property, not an enforced one — what actually fails if either
  /// guard goes missing is `EscapeRecoveryPillTests`, which drives both closures
  /// through the DEBUG wrapper below.
  ///
  /// This exists because testing the guard helper alone proves nothing about the
  /// callbacks: an unguarded payload read inside either closure passes a test
  /// that only calls `takeEscapeRecoveryPayload` directly. `show(intent:)` posts
  /// to `NSApp.mainWindow` and traps in a unit host, so the closures cannot be
  /// reached through the panel's public surface — the DEBUG wrapper below hands
  /// tests THESE closures rather than a reconstruction of them.
  private func escapeRecoveryCallbacks(
    shownID: UUID, paste: ((CancelUndoPayload) -> Void)?
  ) -> (onPaste: () -> Void, onExpire: () -> Void) {
    let onPaste = { [weak self] in
      // One-shot at BOTH ends: the view refuses a second press, and taking the
      // payload here means even a press that slipped through reaches nothing.
      guard let self, let held = self.takeEscapeRecoveryPayload(matching: shownID) else { return }
      // Finish tearing down OUR offer before handing control outside. `hide()`
      // clears `escapeRecoveryPayload` synchronously, so a handler that presents
      // its own overlay during the paste would have that brand-new payload wiped
      // by this teardown — the offer the user is looking at revoked by the one
      // they just accepted. Unreachable while `onEscapeRecoveryPaste` is unbound;
      // fixed here so chunk 8b inherits the safe order rather than this trap.
      self.hide()
      paste?(held)
    }
    let onExpire = { [weak self] in
      // The offer is gone, so the target goes with it — but only if this pill
      // still owns it. A superseded pill expiring must not silently revoke the
      // offer the user can currently see.
      guard let self, self.takeEscapeRecoveryPayload(matching: shownID) != nil else { return }
      self.hide()
    }
    return (onPaste, onExpire)
  }

  #if DEBUG
    /// Test-only writer. The production writer is `presentEscapeRecoveryPill`,
    /// which shows the panel and therefore traps outside a real app.
    // periphery:ignore - test seam
    func setEscapeRecoveryPayloadForTesting(_ payload: CancelUndoPayload?) {
      escapeRecoveryPayload = payload
    }

    // periphery:ignore - test seam
    var escapeRecoveryPayloadForTesting: CancelUndoPayload? { escapeRecoveryPayload }

    /// Hands back the PRODUCTION closures, not a copy of their logic.
    // periphery:ignore - test seam
    func escapeRecoveryCallbacksForTesting(
      shownID: UUID, paste: ((CancelUndoPayload) -> Void)?
    ) -> (onPaste: () -> Void, onExpire: () -> Void) {
      escapeRecoveryCallbacks(shownID: shownID, paste: paste)
    }
  #endif

  /// Whether an intent keeps the pill's paste target alive (#2087).
  ///
  /// Extracted because `show(intent:)` cannot be driven in a unit context — every
  /// arm posts to `NSApp.mainWindow`, which is nil off a real app — so a rule
  /// left inline there would ship untested. Here it is a total function over the
  /// intent set, enumerated rather than defaulted so a future case has to decide
  /// rather than silently inheriting "drop it".
  ///
  /// Only the pill itself retains. Everything else REPLACES the pill, and
  /// replacement is the exit with no teardown of its own: a payload surviving it
  /// could paste a later recovery into the app this one was aimed at.
  static func retainsEscapeRecoveryPayload(_ intent: OverlayIntent) -> Bool {
    switch intent {
    case .escapeRecovery:
      return true
    case .hidden, .recording, .processing, .clipboardFallback, .accessibilityToast,
      .warning, .error, .advisory, .interruption, .passiveChip, .cachingModel,
      .engineReady, .recoveringLastRecording, .recoverySucceeded, .bluetoothAwareness:
      return false
    }
  }
  private var passiveChipAutoDismissHandler: ((UInt64) -> Void)?

  // #1480 Bluetooth awareness card handlers — installed once by the composition
  // root, invoked by the card view's three buttons. The presenter owns all
  // state/teardown/telemetry; these just forward the user's tap.
  private var bluetoothAwarenessGotItHandler: (() -> Void)?
  private var bluetoothAwarenessCloseHandler: (() -> Void)?
  private var bluetoothAwarenessAdjustSettingsHandler: (() -> Void)?

  /// #1341: where a FRESH panel opens (Top or Bottom of the active screen).
  /// The Top/Bottom SETTING itself is read once per fresh appearance inside
  /// `showPanel` — flipping the setting mid-recording does not retroactively
  /// move an already-showing panel between Top and Bottom. Injected via the
  /// initializer rather than a mutable setter so the composition root cannot
  /// forget to wire it.
  private let positionProvider: () -> OverlayPillPosition

  /// The Top/Bottom edge actually chosen for the CURRENT panel, captured once
  /// at fresh-appearance time. `repositionForActiveSpaceChange()` reuses this
  /// — never re-reads `positionProvider()` — so that changing the setting
  /// while a panel is visible can't retroactively snap it to the other edge
  /// mid-Space-swipe (Codex grounded review, 2026-07-17); the SwiftUI content
  /// alignment baked in at creation time (`createPanel`'s `.frame(alignment:)`)
  /// would otherwise mismatch the edge the panel got repositioned to,
  /// reintroducing the recording/polishing misalignment bug this same PR
  /// fixed. `nil` when nothing is showing.
  private var activePanelPosition: OverlayPillPosition?

  /// Whether the showing panel's frame hugs its content exactly (`fitToContent`)
  /// rather than sitting inside a taller fixed frame. Maintained by `showPanel`,
  /// read by the inherited-`y` Top transition, which has to preserve a DIFFERENT
  /// edge for the two geometries — see the branch there for why.
  private var activePanelIsContentSized = false

  /// The origin WE last set programmatically. Used only to DETECT a manual
  /// drag (`isMovableByWindowBackground = true`, an existing feature) by
  /// comparing against the panel's live origin — `wasManuallyDragged` below
  /// is the authoritative, sticky record of that fact once detected. `nil`
  /// when nothing is showing.
  ///
  /// **WRITING THIS ERASES THE ONLY EVIDENCE A DRAG HAPPENED, SO EVERY WRITE
  /// MUST FIRST ASK WHETHER THE LIVE ORIGIN STILL MATCHES.** The drag signal is
  /// a comparison, not an event: nothing observes the user dragging, so a write
  /// that re-baselines to wherever the panel now sits makes the drag
  /// undetectable forever after. This exact bug has been found three times, each
  /// time at a NEW write site rather than a regression of an old one (Codex
  /// grounded review r4 and r5, 2026-07-17; cloud review on #1988), which is why
  /// it is written here as a property of the field instead of a comment at any
  /// one of them. The three live write sites and how each discharges the
  /// obligation:
  /// - `repositionForActiveSpaceChange()` — compares, then returns early on a
  ///   mismatch, so it only writes when no drag happened.
  /// - `showPanel`'s inherited-`y` capture — latches `wasManuallyDragged` first.
  /// - `resizeRecordingPanel(toContentHeight:)` — latches first, using the
  ///   PRE-resize origin (the resize itself moves the origin in Top position).
  private var lastProgrammaticOrigin: NSPoint?

  /// True once the user has manually dragged the panel during the CURRENT
  /// presentation. Sticky and carried across inherited-`y` transitions (e.g.
  /// recording -> polishing) on purpose: those transitions tear down and
  /// recreate the `NSPanel` object, but from the user's perspective it's the
  /// same pill continuing, so "I dragged this" must not be forgotten just
  /// because a new window object got created underneath it. Checked BEFORE
  /// `lastProgrammaticOrigin` comparison in both `repositionForActiveSpaceChange()`
  /// and the inherited-`y` capture — a continuous origin-comparison alone was
  /// tried first and broke twice (Codex grounded review r4 found the Space-
  /// change path re-anchoring over a drag; r5 found the SAME root cause one
  /// level up, an inherited-`y` transition silently re-baselining
  /// `lastProgrammaticOrigin` to the dragged spot and erasing the signal).
  /// Reset to `false` only on a genuine fresh appearance (`y == nil`).
  private var wasManuallyDragged = false

  /// #1341 follow-up: fullscreen state is a per-Space property, and macOS
  /// treats going fullscreen as switching to a NEW Space/"desktop" rather than
  /// changing the current one. A panel that started in windowed mode and then
  /// follows the user (`.canJoinAllSpaces`) into a fullscreen Space — or back
  /// out — keeps its ORIGINAL Y forever unless something re-runs the position
  /// math. Observing Space changes and repositioning the live panel (same
  /// Top/Bottom setting, freshly evaluated fullscreen state) is what makes the
  /// pill track the user across a trackpad swipe between Spaces mid-recording
  /// instead of freezing at whatever was correct for the Space it started in.
  /// Written once in `init` before any other access is possible, read once in
  /// `deinit` after which nothing else can touch it — a single-touch lifecycle
  /// handoff, not a shared-mutation risk. `deinit` is nonisolated even on a
  /// `@MainActor` class, so the property needs this to be readable there.
  private nonisolated(unsafe) var spaceChangeObserver: NSObjectProtocol?

  init(positionProvider: @escaping () -> OverlayPillPosition = { .top }) {
    self.positionProvider = positionProvider
    // Same `queue: .main` + `MainActor.assumeIsolated` shape as
    // `UpdateTriggerCoordinator.start()`'s wake observer — the notification
    // center guarantees this callback runs on the main thread, so hopping
    // through a `Task` first only adds a scheduling round-trip and delays how
    // fast the pill can react to the Space switch.
    spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.repositionForActiveSpaceChange() }
    }
  }

  deinit {
    if let spaceChangeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
    }
  }

  /// Recompute and apply the current panel's frame using the same formula as
  /// a fresh appearance. No-op when nothing is showing. Only geometry moves —
  /// elapsed timer, audio level, and every other piece of live state are
  /// untouched. Animated (`animate: true`): repositioning a panel that is
  /// ALREADY visible and settled needs to read as an intentional glide, not a
  /// snap-to-new-spot jump — the panel is already on-screen at its old
  /// position by the time this notification fires, so an instant jump reads
  /// as a glitch (founder feedback, live-tested 2026-07-17). A fresh
  /// appearance in `showPanel` stays instant on purpose: there is no "old
  /// position" for a brand-new panel to visibly jump from.
  ///
  /// SCOPE: Bottom only (founder decision, 2026-07-17). Top's fresh-Y formula
  /// is a fixed offset from the menu bar, so it was never affected by the
  /// bug this feature exists to fix (the Dock-reservation gap only shows up
  /// at the BOTTOM of a fullscreen Space). Reacting for Top too surfaced a
  /// real but narrow bug: Top's origin gets height-clamped so a tall panel
  /// (the 92pt recording capsule) doesn't poke above the screen, and an
  /// inherited-y transition to a SHORTER panel (the ~44pt polishing pill)
  /// carries that taller clamp forward — a later Space change would then
  /// recompute the clamp for the shorter height and visibly jump the panel
  /// (Codex grounded review r6). Rather than chase that height/clamp
  /// interaction through more rounds for an edge that was never broken,
  /// Top is excluded from reactive repositioning entirely; the founder
  /// explicitly asked not to touch Top's existing behavior in the first
  /// place.
  private func repositionForActiveSpaceChange() {
    // Reuses whichever edge THIS panel was actually created with — never
    // `positionProvider()` live — so a settings change made while the panel
    // is already visible can't retroactively snap it to the other edge on
    // the next Space swipe (Codex grounded review, 2026-07-17). Doing so
    // would also desync the SwiftUI content's baked-in `.frame(alignment:)`
    // from wherever the window got repositioned to, reintroducing the
    // recording/polishing misalignment bug this same PR fixed.
    guard let panel, let position = activePanelPosition, position == .bottom else { return }
    if wasManuallyDragged { return }
    // The pill supports drag-to-relocate (`isMovableByWindowBackground`) —
    // if the panel's live origin no longer matches the spot WE last put it,
    // the user moved it since, and an automatic Space-change reposition must
    // not silently undo that (Codex grounded review r4, 2026-07-17). Stays
    // wherever the user left it for the rest of this presentation; the next
    // fresh appearance re-anchors normally.
    if let lastProgrammaticOrigin, !panel.frame.origin.isApproximately(lastProgrammaticOrigin) {
      wasManuallyDragged = true
      return
    }
    guard
      let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    else { return }
    let resolvedWidth = panel.frame.width
    let resolvedHeight = panel.frame.height
    let x = targetScreen.visibleFrame.midX - resolvedWidth / 2
    let panelY = clampedOriginY(
      requestedY: computeRequestedY(on: targetScreen, position: position),
      resolvedHeight: resolvedHeight, on: targetScreen)
    panel.setFrame(
      NSRect(x: x, y: panelY, width: resolvedWidth, height: resolvedHeight),
      display: true, animate: true
    )
    lastProgrammaticOrigin = NSPoint(x: x, y: panelY)
  }

  /// Shared Top/Bottom position formula — used both when a panel first
  /// appears and when `repositionForActiveSpaceChange()` re-anchors a panel
  /// that is already showing. Takes `position` explicitly (never reads
  /// `positionProvider()` itself) so callers control whether they want the
  /// live setting (fresh appearance) or the edge already committed to the
  /// current panel (Space-change reposition).
  private func computeRequestedY(on screen: NSScreen, position: OverlayPillPosition) -> CGFloat {
    switch position {
    case .top: return screen.visibleFrame.maxY - 60
    // #1341 follow-up: `visibleFrame` is Dock-reserved space as this
    // background app sees it — it does NOT shrink when a DIFFERENT app is in
    // native fullscreen and the Dock is actually hidden from view. Confirmed
    // empirically (2026-07-17): `visibleFrame` stayed identical between
    // windowed and fullscreen, leaving an ~85pt unused gap between the pill
    // and the true screen bottom during fullscreen. When the frontmost app is
    // genuinely fullscreen on this screen, drop all the way to the true
    // screen edge instead; otherwise keep the existing Dock-safe flush
    // position.
    case .bottom:
      return isFrontmostAppFullScreen(on: screen) ? screen.frame.minY : screen.visibleFrame.minY
    }
  }

  /// #1060 (Codex P2): keep the whole panel within the visible frame. The
  /// recording pill's frame is tall enough to host the cap-warning banner, and
  /// positioning by the bottom origin would push the top above the visible
  /// frame (clipping under the menu bar) on a normal recording start. Clamp so
  /// the top never exceeds the frame — small panels (≤ the default 60pt
  /// offset) are unaffected. Shared by fresh appearance and by
  /// `repositionForActiveSpaceChange()` so the guard can't drift between them.
  private func clampedOriginY(requestedY: CGFloat, resolvedHeight: CGFloat, on screen: NSScreen)
    -> CGFloat
  {
    let maxOriginY = screen.visibleFrame.maxY - resolvedHeight - 8
    return min(requestedY, maxOriginY)
  }

  // MARK: - Intent-driven API

  func setGrantHandler(_ handler: @escaping () -> Void) {
    grantHandler = handler
  }

  /// #1063 PR2 — wire the "recovering" pill's Discard action.
  func setDiscardRecoveryHandler(_ handler: @escaping () -> Void) {
    discardRecoveryHandler = handler
  }

  func setAccessibilityWarningDismissedProvider(_ provider: @escaping () -> Bool) {
    accessibilityWarningDismissedProvider = provider
  }

  /// #1988 — wire the live preview.
  ///
  /// Two closures rather than one, and the split is deliberate. `enabled` sizes
  /// the panel and `display` fills it, because size is fixed for the life of a
  /// panel: an `NSPanel` cannot grow mid-recording without a rebuild, and a
  /// rebuild is the #930 flicker. Reading the SETTING for geometry means the
  /// answer does not depend on whether the preview coordinator happened to be
  /// started before this push, which deriving size from `display` would.
  func setLivePreviewProviders(
    enabled: @escaping () -> Bool,
    display: @escaping () -> LivePreviewDisplay
  ) {
    livePreviewEnabledProvider = enabled
    livePreviewDisplayProvider = display
  }

  /// #1988: told whether the overlay is currently showing a live recording, so the
  /// preview can start and stop without the heart path knowing it exists.
  ///
  /// This seam rather than the kernel deliberately. `show(intent:)` is the single
  /// funnel both the first push (`RecordingStarter`) and every state-driven push
  /// (`DictationLifecycleCoordinator`) already pass through, so wiring here keeps
  /// the recording path completely unaware of the preview — which is the whole
  /// point of a limb. The receiver is idempotent because this fires on duplicate
  /// pushes too.
  func setRecordingIntentObserver(_ observer: @escaping (Bool) -> Void) {
    recordingIntentObserver = observer
  }

  /// Wire passive chip action handlers (Lock / Dismiss / auto-dismiss).
  /// Installed once by the former root state at construction time.
  func setPassiveChipHandlers(
    onLock: @escaping () -> Void,
    onDismiss: @escaping () -> Void,
    onAutoDismiss: @escaping (UInt64) -> Void
  ) {
    passiveChipLockHandler = onLock
    passiveChipDismissHandler = onDismiss
    passiveChipAutoDismissHandler = onAutoDismiss
  }

  /// #1480 — wire the Bluetooth awareness card's button actions. Installed once
  /// by the composition root; each closure routes to `BluetoothAwarenessPresenter`.
  func setBluetoothAwarenessHandlers(
    onGotIt: @escaping () -> Void,
    onClose: @escaping () -> Void,
    onAdjustSettings: @escaping () -> Void
  ) {
    bluetoothAwarenessGotItHandler = onGotIt
    bluetoothAwarenessCloseHandler = onClose
    bluetoothAwarenessAdjustSettingsHandler = onAdjustSettings
  }

  /// Unified entry point: render the overlay for the given intent.
  /// Guards against identical intents to prevent flicker.
  func show(
    intent: OverlayIntent, audioLevelProvider: @escaping () -> Float = { 0 },
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    isRecordingLocked: Bool = false
  ) {
    let isRecordingIntent: Bool = if case .recording = intent { true } else { false }
    // #1988: reported BEFORE the dedup guard, so the preview learns about a
    // recording even when this push is a duplicate the panel itself drops.
    recordingIntentObserver(isRecordingIntent)
    guard
      intent != currentIntent || (isRecordingIntent && self.isRecordingLocked != isRecordingLocked)
    else { return }
    self.isRecordingLocked = isRecordingLocked
    currentIntent = intent
    // #2087: any intent that is NOT the pill replaces it, and the paste target
    // must go with it. Otherwise the payload outlives its offer — a new
    // recording starts, and a later pill could paste into the app THIS one was
    // aimed at. Cleared here rather than in each teardown path because
    // replacement is the path with no teardown of its own.
    if !Self.retainsEscapeRecoveryPayload(intent) { escapeRecoveryPayload = nil }
    // #1569 (E4): the narrator is the sole author of the spoken announcement;
    // the panel keeps choosing the per-case AX priority + target element.
    let spokenAnnouncement = DictationNarrator.announcement(for: intent)
    switch intent {
    case .hidden:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      hide()
    case .recording:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      show(
        audioLevelProvider: audioLevelProvider, recordingElapsedProvider: recordingElapsedProvider,
        isRecordingLocked: isRecordingLocked)
    case .processing(let phase):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showPolishing(label: DictationNarrator.copy(for: phase))
    case .clipboardFallback:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showClipboardFallback()
    case .accessibilityToast:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      if accessibilityToastShownThisSession || accessibilityWarningDismissedProvider() {
        showClipboardFallback()
      } else {
        accessibilityToastShownThisSession = true
        showAccessibilityToast()
      }
    case .warning(let reason):
      // #1567: the narrator is the sole author of the sentence.
      let message = DictationNarrator.copy(for: reason)
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showWarning(message: message)
    case .error(let reason):
      // #1558: the narrator is the sole author of the sentence.
      let message = DictationNarrator.copy(for: reason)
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showError(message: message)
    // #1891: a user-setup advisory, announced WITHOUT an "Error: " prefix (the
    // narrator owns that) and rendered in the non-red multiline style.
    case .advisory(let reason):
      let message = DictationNarrator.copy(for: reason)
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showAdvisory(message: message)
    case .interruption(let reason):
      let message = DictationNarrator.copy(for: reason)
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showNotification(message: message, style: .interruption)
    case .passiveChip(let payload):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showPassiveChip(payload: payload)
    case .cachingModel(let engineLabel):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: ColdStartNoticeView(
          title: DictationNarrator.coldStartTitle,
          subtitle: DictationNarrator.coldStartSubtitle(engineLabel: engineLabel),
          icon: .spinner
        ).frame(width: 300, height: 56),
        width: 300, height: 56, dismissAfter: 2.0)
    case .engineReady:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: ColdStartNoticeView(
          title: DictationNarrator.readyTitle,
          subtitle: nil,
          icon: .ready
        ).frame(width: 240, height: 44),
        width: 240, height: 44, dismissAfter: 1.5)
    case .recoverySucceeded:
      // #1464: standalone green success notice after a leftover recording landed
      // in History. Mirrors `.engineReady` (launch-visible, green `.ready` icon),
      // with a subtitle for "where to find it" and a slightly longer dwell.
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: ColdStartNoticeView(
          title: DictationNarrator.recoverySucceededTitle,
          subtitle: DictationNarrator.recoverySucceededSubtitle,
          icon: .ready
        ).frame(width: 300, height: 56),
        width: 300, height: 56, dismissAfter: 3.0)
    case .recoveringLastRecording:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: RecoveryNoticeView(onDiscard: { [weak self] in
          self?.discardRecoveryHandler?()
          self?.hide()
        }).frame(width: 320, height: 56),
        width: 320, height: 56, dismissAfter: 6.0)
    case .bluetoothAwareness:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showBluetoothAwareness()
    // #2087. The announcement is posted here (the narrator authors the words)
    // beside the visible pill, following `.passiveChip`'s post-dictation shape.
    //
    // The spoken form names History as well as Paste. The row is saved before
    // any pill is offered (#1897), so a VoiceOver user who misses the dwell
    // still has a true and unhurried way back to the text.
    case .escapeRecovery:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: spokenAnnouncement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      // FAIL CLOSED. The pill needs a payload the intent cannot carry, so
      // `presentEscapeRecoveryPill(_:)` stores one first. A bare `show` with
      // this intent finds none and renders nothing — it still announces, which
      // is true (the row is saved), rather than offering a Paste pointing at no
      // target.
      guard escapeRecoveryPayload != nil else { return }
      showEscapeRecoveryPill()
    }
  }

  /// Present a transient cold-start notice (caching / ready pill, #879).
  /// Mirrors the create-or-transition + auto-dismiss shape of the other
  /// transient notices, generalized over the content view so the two
  /// cold-start pills share one path. Tears down any existing panel and
  /// recreates at the same position on the next run-loop cycle (the same
  /// `DispatchQueue.main.async` deferral the rest of this file uses to avoid
  /// re-entrant `NSHostingView` creation).
  private func presentTransientNotice<V: View>(
    content: V, width: CGFloat, height: CGFloat, dismissAfter: Double
  ) {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.presentTransientNoticeNow(
        content: content, width: width, height: height, dismissAfter: dismissAfter)
    }
  }

  private func presentTransientNoticeNow<V: View>(
    content: V, width: CGFloat, height: CGFloat, dismissAfter: Double
  ) {
    let existingPanel = panel
    let inheritedFrame = existingPanel?.frame
    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    if let existingPanel {
      CATransaction.flush()
      existingPanel.close()
    }
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.showPanel(content: content, width: width, height: height, inheritedFrame: inheritedFrame)
      self.scheduleAutoDismiss(seconds: dismissAfter)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  // MARK: - Legacy API (internal)

  func show(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    isRecordingLocked: Bool = false
  ) {
    if panel != nil {
      // A panel already exists (e.g., "Starting..." polishing panel).
      // Transition to recording — mirrors transitionToPolishing() in reverse.
      transitionToRecording(
        audioLevelProvider: audioLevelProvider, recordingElapsedProvider: recordingElapsedProvider,
        isRecordingLocked: isRecordingLocked)
      return
    }
    // Cancel any lingering deferred work from a prior session that wasn't
    // cleaned up (e.g., if a VAD self-cancel left pendingCreateWork set but
    // panel still nil). This is defensive — normally hide() clears it.
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    // Delay creation to the next run loop cycle.
    // When triggered from an NSStatusItem menu action, the menu dismiss
    // animation is still in progress. Creating an NSHostingView during
    // that animation causes a re-entrant NSWindow layout cycle (SIGABRT).
    // BRAIN: gotcha id=dispatch-queue-not-task
    // NOTE: Do NOT replace with Task { @MainActor } — DispatchQueue.main.async
    // guarantees next-run-loop-cycle deferral; Task may execute immediately
    // if already on the main actor.
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPanel(
        audioLevelProvider: audioLevelProvider, recordingElapsedProvider: recordingElapsedProvider,
        isRecordingLocked: isRecordingLocked)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Show a processing overlay with a custom label during model loading, transcription, or LLM polishing.
  func showPolishing(label: String) {
    guard panel == nil else {
      // If recording overlay is showing, transition to polishing
      transitionToPolishing(label: label)
      return
    }
    // Cancel any prior deferred work defensively before queuing new work.
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPolishingPanel(label: label)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createPanel(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    isRecordingLocked: Bool = false
  ) {
    guard panel == nil else { return }

    lockState.isLocked = isRecordingLocked
    // #1988: the preview needs room for a sentence, which the 185pt capsule cannot
    // give. Width is fixed; HEIGHT is not — the pill earns its size, growing a line
    // at a time as words wrap and settling once it reaches the cap. See
    // `resizeRecordingPanel(toContentHeight:)`.
    let showsPreview = livePreviewEnabledProvider()
    let width: CGFloat = showsPreview ? Self.previewPillWidth : 185
    let overlayView = RecordingOverlayView(
      audioLevelProvider: audioLevelProvider,
      recordingElapsedProvider: recordingElapsedProvider,
      livePreviewProvider: showsPreview ? livePreviewDisplayProvider : { .off },
      onContentHeightChange: showsPreview
        ? { [weak self] height in self?.resizeRecordingPanel(toContentHeight: height) }
        : { _ in },
      usesPreviewLayout: showsPreview,
      lockState: lockState,
      noticeState: noticeState
    )
    if showsPreview {
      // Content-sized from the start, so the first frame is already correct rather
      // than a guess that visibly snaps once the real height is measured.
      showPanel(
        content: overlayView.frame(width: width),
        width: width, fitToContent: true)
      return
    }
    // Fixed frame accommodating normal (185x44), locked (120x64), and the #1060
    // notice-banner expansion (a 2-line banner under the pill); showPanel clamps
    // the origin so the taller frame never clips under the menu bar (Codex P2).
    // #1341 follow-up: in Top position content stays centered (unchanged
    // behavior). In Bottom position content is bottom-aligned so the panel's Y
    // origin IS the pill's visible bottom edge — without this, the 92pt frame
    // centered a ~44pt capsule, leaving 24pt of invisible space below it, which
    // both muted the Bottom offset change and made the polishing pill (which has
    // no such gap) visibly misaligned with the recording pill it replaces. A
    // notice banner now grows upward from the stable bottom edge instead of
    // pushing the capsule down.
    let fixedFrameView = overlayView.frame(
      width: width, height: 92,
      alignment: positionProvider() == .bottom ? .bottom : .center
    )
    showPanel(content: fixedFrameView, width: width, height: 92)
  }

  /// #1988 preview width. Height is content-driven — see `previewMaxLines`.
  private static let previewPillWidth: CGFloat = 400

  /// Grow or shrink the live recording pill as preview text wraps to more lines.
  ///
  /// **The panel really resizes; it is not oversized and padded.** Reserving the
  /// five-line height up front would have been simpler, but the pill accepts mouse
  /// events across its whole frame (it is drag-to-relocate), so a permanently tall
  /// transparent panel would swallow clicks over a large invisible region of the
  /// user's screen.
  ///
  /// Resizing an existing panel is NOT the #930 flicker: that came from tearing the
  /// panel down and rebuilding it, which destroys the hosting view. `setFrame` keeps
  /// the same window and the same SwiftUI content.
  ///
  /// The anchored edge is the one the user's chosen position pins. Bottom keeps its
  /// bottom edge, so the pill grows UPWARD and its origin never moves — which also
  /// means the Space-change reposition's drag detection cannot mistake growth for a
  /// user drag. Top keeps its top edge and grows downward.
  private func resizeRecordingPanel(toContentHeight contentHeight: CGFloat) {
    guard let panel, case .recording = currentIntent else { return }
    let target = contentHeight.rounded()
    guard target > 0, abs(panel.frame.height - target) >= 1 else { return }

    // Latch a drag BEFORE the frame moves, or the re-baseline at the end of this
    // method silently erases it — see `lastProgrammaticOrigin`. The comparison
    // has to happen here rather than after `setFrame` because in Top position
    // the resize itself moves the origin, which would read as a drag.
    if !wasManuallyDragged, let lastProgrammaticOrigin,
      !panel.frame.origin.isApproximately(lastProgrammaticOrigin)
    {
      wasManuallyDragged = true
    }

    let previousHeight = panel.frame.height
    var frame = panel.frame
    if activePanelPosition == .bottom {
      frame.size.height = target
    } else {
      let topEdge = frame.maxY
      frame.size.height = target
      frame.origin.y = topEdge - target
    }
    panel.setFrame(frame, display: true)
    if !wasManuallyDragged { lastProgrammaticOrigin = frame.origin }

    // #2201: every ACCEPTED resize, so "the box holds still" has a receipt an
    // instrument can read. Until now this method logged nothing, which left the
    // only evidence for a pill that will not stop moving a human watching it —
    // and no way at all to tell one legitimate resize from forty.
    //
    // Deliberately AFTER `setFrame` and after the re-baseline, so it cannot
    // disturb the drag-latch ordering above: `lastProgrammaticOrigin` is the only
    // evidence a user drag happened, and the latch has to run before the frame
    // moves. Reading `previousHeight` from before the mutation costs nothing and
    // keeps every statement between the latch and `setFrame` untouched.
    //
    // No `#if DEBUG` at the call site: `AppLogger.log` is itself DEBUG-gated and
    // compiles to a no-op in release. Fire-and-forget through a `Task` because
    // this is a synchronous `@MainActor` method and the logger is an actor —
    // same shape as `RecoveryLog.swift:64`.
    Task {
      await AppLogger.shared.log(
        "OVERLAY_RESIZE preview height \(Int(previousHeight)) -> \(Int(target))",
        category: "Overlay")
    }
  }

  /// #1060: flash a transient banner over the LIVE recording pill (a second line
  /// inside the same capsule), then auto-clear. No-op unless a recording panel is
  /// live — leaves `panel`, `currentIntent`, and `generation` untouched (no
  /// teardown → no #930 flicker). #1567: carries a typed `RecordingNoticeReason`;
  /// `DictationNarrator` owns the copy.
  func flashRecordingNotice(reason: RecordingNoticeReason, dismissAfter: Double? = nil) {
    guard panel != nil, case .recording = currentIntent else { return }
    noticeDismissWork?.cancel()
    noticeDismissWork = nil
    noticeState.message = DictationNarrator.copy(for: reason)
    // #1060: nil dismissAfter = persist until the recording ends. The cap warning
    // stays the whole final minute and is cleared by the transition out of
    // recording (transitionToPolishing) or hide(). A non-nil value auto-dismisses.
    guard let dismissAfter else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.noticeState.message = nil
      self?.noticeDismissWork = nil
    }
    noticeDismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
  }

  /// Clear any live notice banner + its pending auto-clear. Called on hide and on
  /// transitions away from recording so a notice never bleeds into the next session.
  private func clearRecordingNotice() {
    noticeDismissWork?.cancel()
    noticeDismissWork = nil
    noticeState.message = nil
  }

  /// Show a transient "Copied to clipboard" notice that auto-dismisses after 2.5s.
  func showClipboardFallback() {
    guard panel == nil else {
      // Transition from existing panel (recording/polishing) to clipboard
      // notice. Both steps are inside ONE deferred block (rather than calling
      // the public `transitionToPolishing(label:)` wrapper and arming the
      // dismiss timer right after, synchronously) — otherwise, while a drag
      // defers the actual panel swap, this timer would still arm immediately
      // for content that has not been shown yet and could fire before the
      // deferred content ever appears (Codex grounded review, #2075).
      deferringIfPanelIsBeingDragged { [weak self] in
        guard let self else { return }
        self.transitionToPolishingNow(label: DictationNarrator.clipboardFallbackText)
        self.scheduleAutoDismiss()
      }
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPolishingPanel(label: DictationNarrator.clipboardFallbackText)
      self.scheduleAutoDismiss()
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Show a transient Accessibility permission notice that auto-dismisses after 6s.
  func showAccessibilityToast() {
    guard panel == nil else {
      // Both steps deferred together — see `showClipboardFallback()`'s
      // comment for why (Codex grounded review, #2075).
      deferringIfPanelIsBeingDragged { [weak self] in
        guard let self else { return }
        self.transitionToAccessibilityToastNow()
        self.scheduleAutoDismiss(seconds: 6.0)
      }
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.showPanel(
        content: AccessibilityToastView(onGrant: { [weak self] in
          self?.grantHandler?()
          self?.hide()
        }).frame(width: 300, height: 56),
        width: 300,
        height: 56
      )
      self.scheduleAutoDismiss(seconds: 6.0)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Auto-dismiss timer for transient notices (clipboard fallback, errors).
  private var autoDismissTask: Task<Void, Never>?

  private func scheduleAutoDismiss(seconds: Double = 2.5) {
    autoDismissTask?.cancel()
    autoDismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self, self.panel != nil else { return }
      self.hide()
    }
  }

  /// One narrow informational-status entry point for the bulk-import-
  /// enrichment start/finish pills (#1701 Chunk 2). Reuses this same
  /// non-activating, positioned, auto-dismissing panel shell
  /// `showWarning`/`showError`/`showNotification` already use, but is
  /// deliberately NOT routed through `NotificationStyle` — that enum is the
  /// recording domain's error/warning/interruption intent set, and this
  /// message is neither; adding a case there would widen an intent enum this
  /// feature has no business touching. `BulkImportEnrichmentCoordinator`
  /// receives only a closure into this method, never the concrete panel type.
  func showImportStatus(message: String) {
    // Heart & Limbs: bulk-import enrichment is a limb and must never
    // interrupt the live dictation overlay. Accepted only when idle, or when
    // replacing THIS feature's own prior import-status pill (#1701 Phase 3
    // review finding B) — never a genuine recording/processing panel. This
    // permission check stays synchronous/unconditional (unlike the teardown
    // below): it must reflect the state at CALL time, and every branch it
    // gates already re-validates itself via `generation`/`importStatusPresentation`
    // staleness checks inside the deferred work.
    let replacingOwnStatus = importStatusOwnsCurrentSlot
    guard
      replacingOwnStatus
        || (currentIntent == .hidden && panel == nil && pendingCreateWork == nil)
    else { return }

    // #2075: this pill shares the same close-and-recreate shape every other
    // transition in this file does, and is only ever dragged in the
    // `replacingOwnStatus` case (its own prior import-status pill — never a
    // recording/processing panel, per the comment above), so it needs the
    // same drag guard as the rest.
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.showImportStatusNow(message: message, replacingOwnStatus: replacingOwnStatus)
    }
  }

  private func showImportStatusNow(message: String, replacingOwnStatus: Bool) {
    let dismissSeconds = Self.importStatusAutoDismissSeconds
    let inheritedFrame = replacingOwnStatus ? tearDownOwnedImportStatus() : nil

    generation &+= 1
    let token = generation
    importStatusPresentation = ImportStatusPresentation(generation: token, message: message)

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token,
        self.importStatusPresentation?.generation == token
      else { return }
      self.pendingCreateWork = nil
      self.showPanel(
        content: ImportStatusOverlayView(message: message), width: 320,
        inheritedFrame: inheritedFrame, fitToContent: true)
      guard self.panel != nil else {
        // `showPanel` can no-op (no screen available) — never claim false
        // ownership of a slot with no actual panel.
        self.importStatusPresentation = nil
        return
      }
      self.scheduleAutoDismiss(seconds: dismissSeconds)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Tears down THIS feature's own currently-owned import-status
  /// pending/visible pill, returning its frame if one was visible so a
  /// replacement can appear in the same place. Never operates on an
  /// unowned panel (#1701 Phase 3 review finding B) — the previous,
  /// unrestricted `transitionToImportStatus` (deleted in the round-1 fix)
  /// is exactly what let this feature close a live recording panel.
  private func tearDownOwnedImportStatus() -> NSRect? {
    guard importStatusOwnsCurrentSlot else { return nil }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    guard let existingPanel = panel else { return nil }
    let frame = existingPanel.frame
    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    CATransaction.flush()
    existingPanel.close()
    return frame
  }

  // periphery:ignore - test seam
  /// Projects the currently-owned import-status message without exposing
  /// panel/NSPanel internals (#1701 Phase 3 review finding B) — lets a
  /// headless test assert the state-machine outcome without rendering.
  var importStatusMessageForTesting: String? {
    guard importStatusOwnsCurrentSlot else { return nil }
    return importStatusPresentation?.message
  }

  private static let importStatusAutoDismissSeconds = 3.0

  /// Show a transient warning notice that auto-dismisses after 2.5s.
  func showWarning(message: String) {
    showNotification(message: message, style: .warning)
  }

  /// Show a transient error notice that auto-dismisses after 3s.
  func showError(message: String) {
    showNotification(message: message, style: .error)
  }

  /// #1891: show a user-setup advisory. Wider and taller than the other
  /// notices because it carries a full sentence, and it dwells long enough to
  /// read that sentence.
  func showAdvisory(message: String) {
    showNotification(message: message, style: .advisory)
  }

  /// Unified handler for transient notification overlays (errors and warnings).
  private func showNotification(message: String, style: NotificationStyle) {
    guard panel == nil else {
      // Both steps deferred together — see `showClipboardFallback()`'s
      // comment for why (Codex grounded review, #2075).
      deferringIfPanelIsBeingDragged { [weak self] in
        guard let self else { return }
        self.transitionToNotificationNow(message: message, style: style)
        self.scheduleAutoDismiss(seconds: style.autoDismissSeconds)
      }
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      // #1891: the advisory sizes to its content; every other notice keeps the
      // fixed 280x44 box unchanged.
      let width: CGFloat = style.isMultiline ? Self.advisoryWidth : 280
      let content =
        style.isMultiline
        ? AnyView(
          NotificationOverlayView(message: message, style: style)
            .frame(width: width))
        : AnyView(
          NotificationOverlayView(message: message, style: style)
            .frame(width: 280, height: 44))
      self.showPanel(content: content, width: width, fitToContent: style.isMultiline)
      self.scheduleAutoDismiss(seconds: style.autoDismissSeconds)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// #1891: wider than the 280pt notice box so the advisory sentence wraps to a
  /// readable number of lines instead of a narrow column.
  static let advisoryWidth: CGFloat = 360

  /// Transition an existing panel to a notification display.
  private func transitionToNotification(message: String, style: NotificationStyle) {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToNotificationNow(message: message, style: style)
    }
  }

  private func transitionToNotificationNow(message: String, style: NotificationStyle) {
    guard let existingPanel = panel else { return }
    let inheritedFrame = existingPanel.frame

    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      // #1891: mirror the create path exactly. A notice inherited from a
      // recording panel must not be silently clipped back to 280x44 — the twin
      // site is where this class of defect hides
      // (workflow-process.md RULE: port-proven-patterns-wholesale).
      let width: CGFloat = style.isMultiline ? Self.advisoryWidth : 280
      let content =
        style.isMultiline
        ? AnyView(
          NotificationOverlayView(message: message, style: style).frame(width: width))
        : AnyView(
          NotificationOverlayView(message: message, style: style)
            .frame(width: 280, height: 44))
      self.showPanel(
        content: content, width: width, inheritedFrame: inheritedFrame,
        fitToContent: style.isMultiline)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createPolishingPanel(label: String) {
    guard panel == nil else { return }

    // #1064: size the pill to its content (one hugging line) so short labels
    // ("Polishing...", "Transcribing...") stay compact and the longer 60-minute
    // cap-end message gets exactly the width it needs. A fixed frame stranded
    // short labels in empty space (the #1060 regression). `width` is ignored
    // under fitToContent.
    showPanel(content: PolishingOverlayView(label: label), width: 230, fitToContent: true)
  }

  /// Transition an existing panel to the Accessibility permission notice.
  private func transitionToAccessibilityToast() {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToAccessibilityToastNow()
    }
  }

  private func transitionToAccessibilityToastNow() {
    guard let existingPanel = panel else { return }
    let inheritedFrame = existingPanel.frame

    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.showPanel(
        content: AccessibilityToastView(onGrant: { [weak self] in
          self?.grantHandler?()
          self?.hide()
        }).frame(width: 300, height: 56),
        width: 300,
        height: 56,
        inheritedFrame: inheritedFrame
      )
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Transition an existing panel from recording to polishing mode.
  private func transitionToPolishing(label: String) {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToPolishingNow(label: label)
    }
  }

  private func transitionToPolishingNow(label: String) {
    guard let existingPanel = panel else { return }
    clearRecordingNotice()  // #1060 (Codex P3): don't leak a cap notice into the next session.
    let inheritedFrame = existingPanel.frame

    panel = nil
    // Cancel any stale auto-dismiss timer from a transient notification
    // (error/warning/clipboard fallback) so it doesn't hide the new panel.
    autoDismissTask?.cancel()
    autoDismissTask = nil
    // Cancel any pre-existing deferred work before queuing new work. Without
    // this, a stale DispatchWorkItem could hold a reference that the new token
    // won't invalidate until it actually runs on the next drain cycle.
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    // Flush pending CA frames before closing — same use-after-free guard as hide().
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    // Defer to the next run loop cycle so the close animation completes
    // before the new panel appears, preventing a visual flash.
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.showPanel(
        content: PolishingOverlayView(label: label), width: 230, inheritedFrame: inheritedFrame,
        fitToContent: true)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Transition an existing panel from polishing/processing to recording mode.
  /// A fresh recording starts a new presentation and re-anchors to the user's
  /// configured Top or Bottom position on the next run-loop cycle.
  private func transitionToRecording(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    isRecordingLocked: Bool = false
  ) {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToRecordingNow(
        audioLevelProvider: audioLevelProvider, recordingElapsedProvider: recordingElapsedProvider,
        isRecordingLocked: isRecordingLocked)
    }
  }

  private func transitionToRecordingNow(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    isRecordingLocked: Bool = false
  ) {
    guard let existingPanel = panel else { return }
    clearRecordingNotice()  // #1060 (Codex P3): fresh session starts with no stale notice.
    // A fresh recording is a new lifecycle, so it does not inherit the outgoing
    // panel's frame. `createPanel()` (no inheritedFrame param) re-anchors it to
    // the user's configured Top or Bottom position. A taller panel (e.g. the
    // #1480 Bluetooth card) sits lower, so reusing its origin would drop the
    // pill to mid-screen (#1480 live UAT).
    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPanel(
        audioLevelProvider: audioLevelProvider, recordingElapsedProvider: recordingElapsedProvider,
        isRecordingLocked: isRecordingLocked)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Where a Top-positioned panel goes when it CONTINUES an existing
  /// presentation whose frame was a different height (recording -> polishing).
  ///
  /// Both branches preserve the same thing — where the VISIBLE pill sits — and
  /// differ only because the frame relates to that pill differently in the two
  /// geometries. They agree exactly whenever the heights match, so this can only
  /// diverge on a transition that actually changes height.
  ///
  /// - `outgoingWasContentSized`: the frame hugged its content (`fitToContent`),
  ///   so the frame IS the visible pill and its TOP edge is the anchor. The
  ///   #1988 preview grows downward from a fixed top edge
  ///   (`resizeRecordingPanel`) and can be far taller than what replaces it —
  ///   five lines of text against a one-line "Polishing..." pill. Preserving the
  ///   center here would drop that pill by half the height difference.
  /// - Otherwise: #1650. Content in a FIXED frame is `.center`-aligned inside it
  ///   (createPanel), so the visible pill's vertical CENTER equals the frame's
  ///   center regardless of the frame's own height. Preserving that center — not
  ///   the raw bottom origin — keeps the pill pixel-identical across the 92pt
  ///   recording frame -> ~44pt polishing pill change, closing the ~24pt drop.
  ///
  /// Extracted as a pure function because it is the arithmetic that was wrong,
  /// and the rest of `showPanel` needs a window server. Tests:
  /// `RecordingOverlayPanelInheritedGeometryTests`.
  /// `nonisolated` because it reads no panel state — the inputs are the whole
  /// story, which is what makes it testable without a window server.
  nonisolated static func inheritedTopOriginY(
    inheritedFrame: NSRect, resolvedHeight: CGFloat, outgoingWasContentSized: Bool
  ) -> CGFloat {
    outgoingWasContentSized
      ? inheritedFrame.maxY - resolvedHeight
      : inheritedFrame.midY - resolvedHeight / 2
  }

  /// Create and show a floating overlay panel with the given SwiftUI content.
  ///
  /// `fitToContent` (#1064): size the panel to the SwiftUI view's own
  /// `fittingSize` instead of the passed `width`/`height`, so a pill hugs its
  /// label — compact for short labels ("Polishing...", "Transcribing...") and
  /// only as wide as the content needs for a longer label (the 60-minute
  /// cap-end message). A fixed frame strands short labels in empty space (the
  /// #1060 regression). `width`/`height` are ignored when set.
  private func showPanel<V: View>(
    content: V, width: CGFloat, height: CGFloat = 44, inheritedFrame: NSRect? = nil,
    fitToContent: Bool = false
  ) {
    // Guard against the edge case where no screen is available (C3).
    guard
      let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    else { return }

    // Captured before anything below can overwrite it: this describes the panel
    // being REPLACED, which is what the inherited-`y` transition reasons about.
    let outgoingWasContentSized = activePanelIsContentSized

    let hostingView = NSHostingView(rootView: content)
    // Resolve the panel size: content-driven when `fitToContent`, else the
    // caller's fixed dims. `fittingSize` triggers a layout pass on the hosting
    // view and returns the SwiftUI content's ideal size.
    let resolvedWidth: CGFloat
    let resolvedHeight: CGFloat
    if fitToContent {
      let fitting = hostingView.fittingSize
      resolvedWidth = fitting.width
      resolvedHeight = fitting.height
    } else {
      resolvedWidth = width
      resolvedHeight = height
    }
    let size = NSRect(x: 0, y: 0, width: resolvedWidth, height: resolvedHeight)

    let p = NSPanel(
      contentRect: size,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    p.isReleasedWhenClosed = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isMovableByWindowBackground = true
    p.hasShadow = true

    hostingView.frame = size
    p.contentView = hostingView

    let x = targetScreen.visibleFrame.midX - resolvedWidth / 2
    let requestedY: CGFloat
    if let inheritedFrame {
      let inheritedY = inheritedFrame.origin.y
      // #1341 follow-up: inherited `inheritedFrame` means this panel is
      // CONTINUING the same on-screen presentation (e.g. recording ->
      // polishing), not starting a new one — `activePanelPosition` is
      // deliberately left untouched here. Re-reading `positionProvider()` on
      // this path was a real bug (Codex grounded review r3, 2026-07-17): a
      // setting change made while the panel was visible would get picked up
      // on the NEXT inherited transition, desyncing `activePanelPosition`
      // from the edge the panel's SwiftUI content is actually aligned for,
      // and the next Space swipe would then jump the panel to the wrong edge.
      if activePanelPosition == .top {
        // clampedOriginY below remains authoritative when the incoming panel is
        // too tall to fit below the menu bar at the preserved position. Bottom
        // is unaffected either way: its content is `.bottom`-aligned (#1341) and
        // the preview grows upward from a fixed bottom edge, so the outgoing
        // frame's bottom origin already IS the visible bottom in both
        // geometries, and preserving it unchanged (below) is already correct.
        requestedY = Self.inheritedTopOriginY(
          inheritedFrame: inheritedFrame, resolvedHeight: resolvedHeight,
          outgoingWasContentSized: outgoingWasContentSized)
      } else {
        requestedY = inheritedY
      }
      // Same reasoning applies to drag detection (Codex grounded review r5,
      // 2026-07-17): if the outgoing panel's Y no longer matches where WE
      // last put it, the user dragged it, and that fact must survive into
      // the new panel object this transition creates — check and latch
      // `wasManuallyDragged` HERE, before `lastProgrammaticOrigin` gets
      // rewritten below to the (possibly dragged) inherited position, or the
      // mismatch that proves the drag happened is gone for good. Unaffected
      // by the branch above: this always compares the raw bottom origin.
      if let lastProgrammaticOrigin, abs(inheritedY - lastProgrammaticOrigin.y) > 0.5 {
        wasManuallyDragged = true
      }
    } else {
      // #1341: fresh appearance only — captures the edge for THIS panel's
      // lifetime. `repositionForActiveSpaceChange()` reuses it; an inherited
      // transition above leaves it alone; only a fresh appearance is allowed
      // to change which edge `activePanelPosition` points at.
      let position = positionProvider()
      activePanelPosition = position
      requestedY = computeRequestedY(on: targetScreen, position: position)
      // A genuinely NEW presentation starts clean — any earlier drag doesn't
      // carry over, matching the existing "position resets on next
      // appearance" contract the settings copy already promises.
      wasManuallyDragged = false
    }
    let panelY = clampedOriginY(
      requestedY: requestedY, resolvedHeight: resolvedHeight, on: targetScreen)
    p.setFrameOrigin(NSPoint(x: x, y: panelY))
    lastProgrammaticOrigin = NSPoint(x: x, y: panelY)

    p.orderFrontRegardless()
    self.panel = p
    activePanelIsContentSized = fitToContent
  }

  /// #1341: is the CURRENT frontmost app genuinely in native macOS fullscreen
  /// on `screen`? `NSScreen.visibleFrame` does not answer this for a
  /// background/accessory app — it keeps reporting the regular-desktop
  /// Dock reservation regardless of another app's fullscreen state (confirmed
  /// empirically 2026-07-17; `NSApplication.currentSystemPresentationOptions`
  /// also does not update for `LSUIElement` apps — a known AppKit limitation).
  /// The Accessibility attribute on the frontmost app's own focused window is
  /// the one signal that actually flips correctly, and is available to us
  /// because EnviousWispr is non-sandboxed and already holds Accessibility
  /// trust for paste. Gated to `screen == .main` (the screen holding the
  /// keyboard-focused window) so a fullscreen Space on one display never
  /// pushes the pill into Dock territory on a different, non-fullscreen
  /// display.
  ///
  /// KNOWN SCOPE BOUNDARY (Codex grounded review, 2026-07-17): without
  /// Accessibility trust this always returns `false`, so Bottom keeps the
  /// pre-existing Dock-safe `visibleFrame.minY` position in fullscreen for
  /// those users — same as before this fix, not worse. EnviousWispr already
  /// treats an Accessibility-denied user as a first-class supported flow
  /// (`PasteCascadeExecutor`'s clipboard-only fallback), so this doesn't
  /// regress anyone; it just doesn't reach that subset yet. The other two
  /// permission-free signals investigated (`CGWindowListCopyWindowInfo`,
  /// `NSApplication.currentSystemPresentationOptions`) don't reliably work
  /// either (see the two paragraphs above and 2026-07-17 session notes) — a
  /// real permission-independent fix would mean requesting Screen Recording
  /// access, which is a product scope decision, not something to fold into
  /// a positioning bug fix.
  private func isFrontmostAppFullScreen(on screen: NSScreen) -> Bool {
    guard screen == NSScreen.main, AXIsProcessTrusted(),
      let frontApp = NSWorkspace.shared.frontmostApplication
    else { return false }
    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedWindow: AnyObject?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        == .success,
      let focusedWindow
    else { return false }
    // `AXUIElement` is a CFTypeRef-family type: neither `as!` nor `as?` performs
    // a real dynamic type check here (verified empirically — both silently
    // "succeed" on a wrong CF type instead of crashing or returning nil), so a
    // checked cast would only be misleading. `kAXFocusedWindowAttribute` is
    // documented to always yield an AXUIElement on `.success`; the subsequent
    // AX call is what actually fails gracefully if that contract is ever broken.
    let window = focusedWindow as! AXUIElement
    var fullScreenValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreenValue)
        == .success
    else { return false }
    return (fullScreenValue as? Bool) ?? false
  }

  /// Update the lock state reactively. Called by the former root state when
  /// hands-free mode is activated or deactivated mid-recording.
  /// The shared OverlayLockState triggers a SwiftUI animation
  /// on the existing RecordingOverlayView without panel recreation.
  func updateLockState(_ locked: Bool) {
    lockState.isLocked = locked
    isRecordingLocked = locked
  }

  /// Read-only mirror of the private lock flag, for tests that verify
  /// `markLocked()` / `updateLockState(_:)` actually toggled the overlay rather
  /// than only the shared lock setter. Mirrors the
  /// `ASRManagerProxy.isProgressPollingActiveForTesting` test-accessor pattern.
  // periphery:ignore - test seam
  internal var isRecordingLockedForTesting: Bool { isRecordingLocked }

  // MARK: - Escape Recovery pill (#2087)

  /// Raise the Escape Recovery pill for a durably saved row (#2087).
  ///
  /// The entry point, because the payload cannot travel on the intent:
  /// `OverlayIntent` is `Sendable` and `AXUIElement` / `NSRunningApplication`
  /// are main-actor handles. The payload is stored here and the intent then
  /// carries only the id, which is also what the announcement needs.
  func presentEscapeRecoveryPill(_ payload: CancelUndoPayload) {
    escapeRecoveryPayload = payload
    show(intent: .escapeRecovery(transcriptID: payload.transcriptID))
  }

  /// Mirrors `showPassiveChip` rather than `presentTransientNotice`, because the
  /// VIEW owns this dwell. A panel-level timer cannot be paused by a hover the
  /// view sees, so the two would race and the hover would appear to do nothing.
  private func showEscapeRecoveryPill() {
    guard panel == nil else {
      deferringIfPanelIsBeingDragged { [weak self] in
        self?.transitionToEscapeRecoveryPillNow()
      }
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createEscapeRecoveryPillPanel()
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func transitionToEscapeRecoveryPillNow() {
    guard let existingPanel = panel else { return }
    let inheritedFrame = existingPanel.frame
    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    CATransaction.flush()
    existingPanel.close()
    generation &+= 1
    let token = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createEscapeRecoveryPillPanel(inheritedFrame: inheritedFrame)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createEscapeRecoveryPillPanel(inheritedFrame: NSRect? = nil) {
    guard panel == nil, let payload = escapeRecoveryPayload else { return }
    // The id THIS pill is showing. Both callbacks match on it, so a pill that
    // has been superseded cannot act on its successor's payload.
    let callbacks = escapeRecoveryCallbacks(
      shownID: payload.transcriptID, paste: onEscapeRecoveryPaste)
    // Sized from `PillMetrics`, which measures the sentence, rather than from
    // literals here. Two places holding the same number is how a copy revision
    // clips the pill in one of them.
    let view = EscapeRecoveryPillView(
      onPaste: callbacks.onPaste, onExpire: callbacks.onExpire
    )
    .frame(width: PillMetrics.panelWidth, height: PillMetrics.panelHeight)
    showPanel(
      content: view, width: PillMetrics.panelWidth, height: PillMetrics.panelHeight,
      inheritedFrame: inheritedFrame)
  }

  /// Show the passive language-detection chip as a floating panel. Mirrors the
  /// `showAccessibilityToast` shape: defers creation to next run loop cycle,
  /// guards against rapid replace via the generation token. Auto-dismiss is 6s
  /// with hover-pause (handled inside `LanguageChipView`).
  func showPassiveChip(payload: LanguageChipPayload) {
    guard panel == nil else {
      transitionToPassiveChip(payload: payload)
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPassiveChipPanel(payload: payload)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createPassiveChipPanel(payload: LanguageChipPayload, inheritedFrame: NSRect? = nil) {
    guard panel == nil else { return }
    let onLock = passiveChipLockHandler
    let onDismiss = passiveChipDismissHandler
    let onAutoDismiss = passiveChipAutoDismissHandler
    let view = LanguageChipView(
      payload: payload,
      onLock: { onLock?() },
      onDismiss: { onDismiss?() },
      onAutoDismiss: { onAutoDismiss?(payload.generation) }
    )
    .frame(width: 340, height: 56)
    showPanel(content: view, width: 340, height: 56, inheritedFrame: inheritedFrame)
  }

  private func transitionToPassiveChip(payload: LanguageChipPayload) {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToPassiveChipNow(payload: payload)
    }
  }

  private func transitionToPassiveChipNow(payload: LanguageChipPayload) {
    guard let existingPanel = panel else { return }
    let inheritedFrame = existingPanel.frame

    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPassiveChipPanel(payload: payload, inheritedFrame: inheritedFrame)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// #1480 — show the Bluetooth cold-start education card. Mirrors
  /// `showPassiveChip`'s defer-to-next-run-loop + generation-guard shape, but has
  /// NO auto-dismiss (plan §3D): the card persists until the presenter tears it
  /// down (record-supersede, Got it / close / Adjust settings, route-off, or the
  /// tips setting turning off).
  func showBluetoothAwareness() {
    guard panel == nil else {
      transitionToBluetoothAwareness()
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createBluetoothAwarenessPanel()
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createBluetoothAwarenessPanel(inheritedFrame: NSRect? = nil) {
    guard panel == nil else { return }
    let onGotIt = bluetoothAwarenessGotItHandler
    let onClose = bluetoothAwarenessCloseHandler
    let onAdjust = bluetoothAwarenessAdjustSettingsHandler
    let view = BluetoothAwarenessCardView(
      onGotIt: { onGotIt?() },
      onClose: { onClose?() },
      onAdjustSettings: { onAdjust?() }
    )
    // Fixed width, content-driven height (`fitToContent`) so the multi-row card
    // is never clipped and adapts to copy length in either appearance.
    showPanel(
      content: view, width: 320, height: 0, inheritedFrame: inheritedFrame, fitToContent: true)
  }

  private func transitionToBluetoothAwareness() {
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.transitionToBluetoothAwarenessNow()
    }
  }

  private func transitionToBluetoothAwarenessNow() {
    guard let existingPanel = panel else { return }
    let inheritedFrame = existingPanel.frame

    panel = nil
    autoDismissTask?.cancel()
    autoDismissTask = nil
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    CATransaction.flush()
    existingPanel.close()

    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createBluetoothAwarenessPanel(inheritedFrame: inheritedFrame)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// True while the left mouse button is held down with the cursor inside the
  /// CURRENTLY VISIBLE panel's frame — the live signature of an active
  /// `isMovableByWindowBackground` drag of THAT panel (background-window
  /// dragging keeps the cursor at a fixed offset from where the drag started,
  /// so the cursor stays inside the frame for the drag's whole duration; this
  /// is the mechanism's own invariant, not a heuristic). Checking button
  /// state alone would also true-positive on a drag of some unrelated window
  /// elsewhere on screen — pairing it with frame containment scopes it to
  /// THIS panel only.
  private func isDraggingCurrentPanel() -> Bool {
    guard let panel, NSEvent.pressedMouseButtons & 0x1 != 0 else { return false }
    return panel.frame.contains(NSEvent.mouseLocation)
  }

  /// The most recently requested panel-changing operation still waiting for
  /// a native window drag to end, and the single retry poll driving it.
  /// LATEST-WINS: a newer call to `deferringIfPanelIsBeingDragged` while an
  /// older one is still waiting on the SAME drag simply overwrites this slot
  /// rather than starting a second, independent retry chain — see the
  /// `deferringIfPanelIsBeingDragged` doc comment for why two chains racing
  /// each other is itself a bug (Codex grounded review, #2075).
  private var deferredPanelTransition: (() -> Void)?
  private var deferredPanelTransitionWork: DispatchWorkItem?

  /// Runs `body` now, or — if `isDraggingCurrentPanel()` — retries shortly
  /// until the drag ends. #2075: every panel-replacing transition in this
  /// file closes the CURRENTLY VISIBLE `NSPanel` and asynchronously builds a
  /// replacement. `isMovableByWindowBackground` dragging is native AppKit
  /// machinery outside this file's control that keeps moving/repainting that
  /// exact panel object for as long as the mouse stays down; closing it
  /// mid-drag doesn't flush visually before the drag moves on, leaving the
  /// old bitmap stuck on screen at wherever the mouse was at that instant
  /// while the replacement opens fresh elsewhere — the reported "multiple
  /// copies" bug. Deferring the whole transition until the drag ends closes
  /// the race outright. Every one of these already-identical teardown call
  /// sites gets this same wrap (`workflow-process.md` RULE:
  /// close-the-window-never-handle-it) — fixing only the reported pill would
  /// leave the identical race live on every other one.
  ///
  /// LATEST-WINS, not one-retry-chain-per-caller (Codex grounded review,
  /// #2075): a naive version that spawns its own independent `asyncAfter`
  /// retry per call lets two transitions requested during the same drag
  /// race each other once it ends — whichever's retry callback happens to
  /// run first sees `panel` at its live value and can bail out having done
  /// nothing (every `XyzNow()` guards `panel != nil`/`existingPanel`), while
  /// `currentIntent` was already updated synchronously by the SECOND,
  /// "winning" call back in `show(intent:)` — so the visible panel can end
  /// up showing the FIRST (older, losing) transition's content while
  /// `currentIntent` records the second. Coalescing every waiting request
  /// into one `deferredPanelTransition` slot (only the most recent survives)
  /// and one shared `deferredPanelTransitionWork` retry closure removes that
  /// race by construction — there is only ever one thing left to apply once
  /// the drag ends, and it is always the newest.
  private func deferringIfPanelIsBeingDragged(_ body: @escaping () -> Void) {
    guard isDraggingCurrentPanel() else {
      deferredPanelTransition = nil
      deferredPanelTransitionWork?.cancel()
      deferredPanelTransitionWork = nil
      body()
      return
    }

    // A pending replacement supersedes the still-visible (being-dragged)
    // panel's own auto-dismiss timer — that timer was armed for the OLD
    // content and must not fire while a newer transition is queued behind
    // the drag; the newest transition (applied below, once the drag ends)
    // re-arms whatever dismiss timer it needs.
    autoDismissTask?.cancel()
    autoDismissTask = nil
    deferredPanelTransition = body

    guard deferredPanelTransitionWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deferredPanelTransitionWork = nil
      guard let latest = self.deferredPanelTransition else { return }
      self.deferringIfPanelIsBeingDragged(latest)
    }
    deferredPanelTransitionWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  func hide() {
    // Record the requested state immediately — mirroring `show(intent:)`'s
    // own synchronous `currentIntent = intent` (line ~331) — so a later
    // `show(intent:)` call arriving during the same drag is not incorrectly
    // deduplicated against a `currentIntent` this queued hide hasn't applied
    // yet (Codex grounded review round 2, #2075).
    currentIntent = .hidden
    // #2087: SYNCHRONOUSLY, for the same reason `currentIntent` is. The teardown
    // below can be deferred while the overlay is being dragged, and a paste
    // target that outlives its hidden pill is a target a later recovery could
    // reach.
    escapeRecoveryPayload = nil
    deferringIfPanelIsBeingDragged { [weak self] in
      self?.hideNow()
    }
  }

  private func hideNow() {
    currentIntent = .hidden
    // #1988: a direct `hide()` (not every caller routes through `show(intent:)`)
    // must still stop the preview. Idempotent, so the common path that already
    // reported `false` costs nothing.
    recordingIntentObserver(false)
    isRecordingLocked = false
    lockState.isLocked = false
    clearRecordingNotice()
    autoDismissTask?.cancel()
    autoDismissTask = nil
    generation &+= 1
    importStatusPresentation = nil
    // Cancel any pending deferred panel creation so it never fires.
    // This handles the rapid-ESC race: if hide() is called before the
    // DispatchQueue.main.async closure from show() has had a chance to run,
    // cancelling the work item prevents the panel from being created at all.
    // The generation counter check inside the closure is a secondary guard.
    pendingCreateWork?.cancel()
    pendingCreateWork = nil

    guard let panelToClose = panel else { return }
    panel = nil
    activePanelPosition = nil
    activePanelIsContentSized = false
    lastProgrammaticOrigin = nil
    wasManuallyDragged = false

    // Flush pending CA transactions before releasing the panel.
    // RecordingOverlayView has a running .task loop updating audioLevel every 50ms
    // and OverlayCapsuleBackground has a repeatForever animation. When close() fires,
    // CA may have a pending implicit transaction trying to render a final frame of
    // the now-deallocating NSHostingView backing layer. Flushing here ensures that
    // frame is committed while the view graph is still alive, preventing the
    // _DictionaryStorage use-after-free in CA::Transaction::commit.
    //
    // We must flush BEFORE close() (not after), because close() begins view teardown.
    // The local `panelToClose` retain keeps the panel alive through the flush.
    CATransaction.flush()
    panelToClose.close()
  }
}

extension NSPoint {
  /// #1341: origin comparison for drag detection — a strict `==` would false-
  /// positive on the sub-point floating-point noise `setFrame`/display-scale
  /// rounding can introduce between what we requested and what AppKit reports
  /// back, reading as "the user dragged it" when nothing moved.
  fileprivate func isApproximately(_ other: NSPoint, tolerance: CGFloat = 0.5) -> Bool {
    abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
  }
}

// MARK: - SpectrumWheelIcon

/// 12 rainbow-colored bars arranged radially, spinning slowly.
struct SpectrumWheelIcon: View {
  @State private var rotation: Double = 0
  let size: CGFloat

  private let bars: [(deg: Double, yOffset: CGFloat, height: CGFloat, color: Color)] = [
    (0, 4, 14, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (30, 7, 10, Color(red: 1.0, green: 0.624, blue: 0.039)),
    (60, 5, 12, Color(red: 1.0, green: 0.839, blue: 0.039)),
    (90, 8, 9, Color(red: 0.188, green: 0.82, blue: 0.345)),
    (120, 4, 14, Color(red: 0.204, green: 0.78, blue: 0.349)),
    (150, 6, 11, Color(red: 0.196, green: 0.847, blue: 0.745)),
    (180, 5, 13, Color(red: 0.392, green: 0.824, blue: 1.0)),
    (210, 8, 9, Color(red: 0.039, green: 0.518, blue: 1.0)),
    (240, 4, 14, Color(red: 0.369, green: 0.361, blue: 0.902)),
    (270, 6, 12, Color(red: 0.749, green: 0.353, blue: 0.949)),
    (300, 7, 10, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (330, 5, 13, Color(red: 1.0, green: 0.624, blue: 0.039)),
  ]

  var body: some View {
    // Scale factor: SVG viewBox is 64x64, we map to `size`
    let scale = size / 64.0
    Canvas { context, size in
      let cx = size.width / 2
      let cy = size.height / 2
      for bar in bars {
        let barW = 4.0 * scale
        let barH = bar.height * scale
        // Bar rect centered on the canvas, offset upward by yOffset so
        // its visual center sits at the correct radial distance.
        let distFromCenter = 32.0 * scale - bar.yOffset * scale - barH / 2
        let rect = CGRect(
          x: -barW / 2,
          y: -distFromCenter - barH / 2,
          width: barW,
          height: barH
        )
        let cornerRadius = 2.0 * scale
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        // Rotate around canvas center by bar's degree offset (converted to radians).
        let angle = bar.deg * .pi / 180.0
        let transform = CGAffineTransform(translationX: cx, y: cy)
          .rotated(by: angle)
        let rotatedPath = barPath.applying(transform)
        context.fill(rotatedPath, with: .color(bar.color))
      }
    }
    .frame(width: size, height: size)
    .rotationEffect(.degrees(rotation))
    .onAppear {
      withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
        rotation = 360
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - RainbowLipsIcon

/// Lip/spectrum bar brand icon driven by real-time audio level during recording.
/// Each of the 18 bars (9 upper + 9 lower) scales vertically in response to
/// `audioLevel` (0.0–1.0). Per-bar variation factors make the motion organic
/// rather than all bars moving in lockstep.
///
/// Scale formula (matches MenuBarIconAnimator.renderRecordingLips):
///   scaleY = silenceScale + (peakScale - silenceScale) * level * perBarFactor
///
/// At silence (level ≈ 0) bars sit at their minimum compressed state (lips closed).
/// At peak (level = 1.0) center bars reach maximum expansion (lips open/talking).
/// #2202: the live level meter in the preview pill's header.
///
/// **Replaces the lips mark in THIS box only.** The mark stays everywhere else —
/// the menu bar, the polishing pill, settings. Founder direction, 2026-08-19: it
/// is a logo doing a meter's job, a square block of nine bars that has to be read
/// as a picture before it reads as movement, and it occupies the left edge the
/// timer should own. Nine bars on a baseline say "I can hear you" in a shape
/// everyone knows from every recorder ever made.
///
/// Nine bars, nine brand spectrum colours in order, red through violet — the same
/// palette and the same order as `RainbowLipsIcon`, so the two read as one family
/// while the pill transitions between layouts.
///
/// **Symmetric about a centre line rather than growing off a floor.** That echoes
/// the mark it replaces, and it means the meter's visual weight does not shift
/// down the header as the level drops.
///
/// Fixed height in every state, which is load-bearing rather than cosmetic: today
/// hands-free scales the lips mark to 2x, and that is the single biggest height
/// jump anywhere in the pill. A meter that occupies one strip whatever the mode is
/// what lets the header stop changing size between hold-to-talk and hands-free.
struct RainbowLevelMeter: View {
  /// Normalised audio level 0.0-1.0, polled every ~50 ms by the parent view. The
  /// same value `RainbowLipsIcon` reads, so this adds no timer and no new source.
  let audioLevel: Float

  /// Height of the strip. Bars are drawn symmetrically about its middle.
  var height: CGFloat = 16
  var barWidth: CGFloat = 2.5
  var spacing: CGFloat = 3

  /// The brand spectrum, in order. Shared with `RainbowLipsIcon`'s bar table.
  static let spectrum: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
    Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
    Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 gold
    Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f lime
    Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a spring
    Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
    Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff blue
    Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal
    Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 violet
  ]

  /// Per-bar sensitivity. Centre bars react most, edges least — the same
  /// weighting `RainbowLipsIcon` uses, so both instruments agree about what the
  /// same audio looks like.
  static let sensitivity: [CGFloat] = [0.70, 0.80, 0.90, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70]

  /// Fraction of the strip a bar occupies at silence. Non-zero on purpose: a
  /// meter that collapses to nothing between words reads as "it stopped hearing
  /// me", which is the exact anxiety the preview exists to remove.
  static let silenceFraction: CGFloat = 0.18

  /// Additional fraction available at full level, for the most sensitive bar.
  static let peakFraction: CGFloat = 0.82

  /// Fraction of the strip bar `index` fills at `level`.
  ///
  /// `static` and `package`-visible so a test can assert the shape without
  /// rendering: the property that matters is monotonic in level and clamped at
  /// both ends, and a Canvas cannot be asked about that.
  static func fill(index: Int, level: CGFloat) -> CGFloat {
    let clamped = min(max(level, 0), 1)
    let weight = sensitivity[min(max(index, 0), sensitivity.count - 1)]
    return silenceFraction + peakFraction * clamped * weight
  }

  var body: some View {
    let level = CGFloat(min(max(audioLevel, 0), 1))
    Canvas { context, size in
      for i in 0..<Self.spectrum.count {
        let barHeight = size.height * Self.fill(index: i, level: level)
        let x = CGFloat(i) * (barWidth + spacing)
        let rect = CGRect(
          x: x,
          y: (size.height - barHeight) / 2,
          width: barWidth,
          height: barHeight
        )
        context.fill(
          Path(roundedRect: rect, cornerRadius: barWidth / 2),
          with: .color(Self.spectrum[i]))
      }
    }
    .frame(width: Self.width(barWidth: barWidth, spacing: spacing), height: height)
    .accessibilityHidden(true)
  }

  /// Total width for nine bars and eight gaps. Derived rather than a literal, so
  /// the frame cannot drift from what the Canvas draws.
  static func width(barWidth: CGFloat, spacing: CGFloat) -> CGFloat {
    CGFloat(spectrum.count) * barWidth + CGFloat(spectrum.count - 1) * spacing
  }
}

struct RainbowLipsIcon: View {
  let size: CGFloat
  /// Normalised audio level 0.0-1.0, updated every ~50 ms by the parent view.
  let audioLevel: Float
  /// When true, all bars turn red and pulse opacity (distress/interruption state).
  var isDistress: Bool = false

  private let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 22.25, 5, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (10, 17.6375, 8, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (16, 12.04, 12, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (22, 16.96, 9, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (28, 21.5575, 6, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (34, 16.96, 9, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (40, 12.04, 12, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (46, 17.6375, 8, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (52, 22.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  private let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 30.25, 5, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (10, 28.6375, 9, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (16, 27.04, 12, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (22, 28.96, 15, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (28, 30.5575, 17, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (34, 28.96, 15, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (40, 27.04, 12, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (46, 28.6375, 9, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (52, 30.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  // Per-bar sensitivity multipliers (index 0-8).
  // Center bars (index 4) react most; edge bars react least — mirrors the
  // centerDistance weighting used in MenuBarIconAnimator.renderRecordingLips.
  private let sensitivity: [CGFloat] = [0.70, 0.80, 0.90, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70]

  // Baseline scaleY when audio level is zero (lips lightly closed).
  private let silenceScale: CGFloat = 0.55

  // Maximum additional scaleY headroom above silence (reached at level = 1.0
  // for the most-sensitive bar). Chosen so peak scaleY ≈ 1.45 for center bars.
  private let peakRange: CGFloat = 0.90

  /// Compute the Y scale for a given bar index and the current audio level.
  /// Upper and lower bars share the same formula; the caller may pass a
  /// mirrored index to create counterpoint movement between the two lip halves.
  private func yScale(for barIndex: Int, level: CGFloat) -> CGFloat {
    silenceScale + peakRange * level * sensitivity[barIndex]
  }

  private static let distressRed = Color(red: 1.0, green: 0.165, blue: 0.251)

  var body: some View {
    if isDistress {
      // Distress mode: lips in normal shape, all bars red, pulsing opacity.
      // TimelineView drives continuous redraw; Canvas does not respond to @State animation.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let phase = timeline.date.timeIntervalSinceReferenceDate
        let pulseOpacity = 0.4 + 0.6 * (0.5 + 0.5 * sin(phase * .pi / 0.35))
        lipsCanvas(level: 0.3, barColorOverride: Self.distressRed)
          .opacity(pulseOpacity)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
    } else {
      lipsCanvas(level: CGFloat(min(max(audioLevel, 0), 1)), barColorOverride: nil)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }

  /// Shared Canvas renderer for both normal and distress modes.
  /// When `barColorOverride` is non-nil, all bars use that color instead of their rainbow colors.
  private func lipsCanvas(level: CGFloat, barColorOverride: Color?) -> some View {
    let scale = size / 64.0
    return Canvas { context, canvasSize in
      let maxSeparation = 3.5 * scale
      let barW = 4.5 * scale
      let cornerRadius = 1.5 * scale

      for i in 0..<upperBars.count {
        let bar = upperBars[i]
        let s = yScale(for: i, level: level)
        let scaledH = bar.h * scale * s
        let separation = -maxSeparation * level * sensitivity[i]
        let barBottom = (bar.y + bar.h) * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barBottom - scaledH,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }

      for i in 0..<lowerBars.count {
        let bar = lowerBars[i]
        let s = yScale(for: 8 - i, level: level)
        let scaledH = bar.h * scale * s
        let separation = maxSeparation * level * sensitivity[8 - i]
        let barTop = bar.y * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barTop,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }
    }
  }
}

// MARK: - OverlayCapsuleBackground

/// Shared capsule background with warmer dark fill, subtle border, and a
/// rainbow gradient line pulsing along the bottom edge.
private struct OverlayCapsuleBackground: View {
  /// #1988: the live-preview pill is tall and full of text, and a capsule's
  /// semicircular ends eat exactly the width the text needs while crowding the
  /// first and last characters of every line. A rounded rectangle reads as a panel
  /// rather than a lozenge at that size, which is what the shape should say.
  /// Everything else keeps the capsule.
  enum CornerStyle {
    case capsule
    case rounded
  }

  var cornerStyle: CornerStyle = .capsule
  @State private var glowOpacity: Double = 0.3

  /// #2201: the preview pill's rainbow hairline holds still instead of breathing
  /// on a permanent two-second loop.
  ///
  /// The loop is a nice touch on the small capsule, which shows for a moment and
  /// carries no text. On the preview pill it sits under a box that is already
  /// growing a line at a time while words arrive, and the two movements read as
  /// one restless object — the founder reported the pill "pulsing", and this is
  /// the part of that which is not the sizing defect.
  ///
  /// Mid-way between the loop's own 0.3 and 0.65 endpoints, so the line is no
  /// dimmer on average than the one it replaces.
  private static let steadyPreviewGlow: Double = 0.5

  private var shape: AnyShape {
    switch cornerStyle {
    case .capsule: return AnyShape(Capsule())
    case .rounded: return AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  var body: some View {
    shape
      .fill(Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82))
      // `strokeBorder` needs an insettable shape, which the type-erased `AnyShape`
      // is not, so the two concrete shapes are named here. Kept as `strokeBorder`
      // rather than switching both to `stroke`: the capsule is shipped UI and its
      // border should stay exactly where it already sits.
      .overlay(
        Group {
          switch cornerStyle {
          case .capsule:
            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
          case .rounded:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
          }
        }
      )
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [
            .clear,
            Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
            Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
            Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 yellow
            Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f yellow-green
            Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a mint
            Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
            Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff dodger blue
            Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal blue
            Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 purple
            .clear,
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
        .opacity(cornerStyle == .rounded ? Self.steadyPreviewGlow : glowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
        // #2201: only the capsule breathes. Arming a `repeatForever` for the
        // preview would keep it re-rendering whether or not anything read
        // `glowOpacity`, and the point of this chunk is that the preview pill
        // stops moving on its own.
        guard cornerStyle == .capsule else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
          glowOpacity = 0.65
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - DistressCapsuleBackground

/// Capsule background for interruption warnings: red glow instead of rainbow.
private struct DistressCapsuleBackground: View {
  @State private var glowOpacity: Double = 0.3

  var body: some View {
    Capsule()
      .fill(Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82))
      .overlay(
        Capsule()
          .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
      )
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [
            .clear,
            Color(red: 1.0, green: 0.165, blue: 0.251),
            Color(red: 1.0, green: 0.27, blue: 0.27),
            Color(red: 1.0, green: 0.165, blue: 0.251),
            .clear,
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
        .opacity(glowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
          glowOpacity = 0.6
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
  let audioLevelProvider: () -> Float
  /// #1393: monotonic elapsed recording time, read from the shared kernel
  /// source of truth instead of a per-view-instance stamp — a panel-recreate
  /// (e.g. `transitionToRecording`) must not reset the displayed timer.
  let recordingElapsedProvider: () -> TimeInterval?
  /// #1988: what the live preview should show. Polled on the same 50 ms loop as
  /// audio level and elapsed time rather than on a publisher, because that loop
  /// already exists and coalesces naturally: Apple emits updates every ~210-290 ms,
  /// so a push-based feed would redraw more often than the eye can read without
  /// showing anything more.
  let livePreviewProvider: () -> LivePreviewDisplay
  /// #1988: reports the capsule's measured height so the panel can follow it as the
  /// preview grows. No-op when the preview is off.
  var onContentHeightChange: (CGFloat) -> Void = { _ in }
  /// #1988: whether this pill is the tall preview layout. Passed in rather than
  /// derived from the display state, which remains `.off` until the polling task
  /// first runs and would flash the capsule shape before that first read.
  ///
  /// #2201: the previous wording said "for one 50 ms poll", which names a duration
  /// the code does not have — the task reads its providers BEFORE its first sleep,
  /// so the window is until it is first scheduled, not a fixed 50 ms.
  var usesPreviewLayout: Bool = false
  var lockState: OverlayLockState
  /// #1060: transient notice banner shown inside the recording capsule.
  var noticeState: OverlayNoticeState
  @State private var audioLevel: Float = 0
  @State private var elapsed: TimeInterval = 0
  @State private var preview: LivePreviewDisplay

  /// Seeds `preview` so a size test can measure a KNOWN display state on the
  /// first layout pass instead of waiting for the 50 ms poll to publish one.
  ///
  /// **The seam exists because the alternative is a timed wait, and this view's
  /// whole defect is about what its height does over time.** `preview` is
  /// `@State`, so nothing outside can set it; without this a test would have to
  /// pump a run loop until the polling task happened to run, which is the
  /// guess-when-the-subject-is-finished shape testing-philosophy.md forbids.
  ///
  /// Production never passes it. The poll is the only writer it needs, and it
  /// overwrites this on the first tick regardless — so a wrong value here cannot
  /// survive into a real recording, which is what makes the seam cheap.
  init(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    livePreviewProvider: @escaping () -> LivePreviewDisplay,
    onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
    usesPreviewLayout: Bool = false,
    lockState: OverlayLockState,
    noticeState: OverlayNoticeState,
    initialPreview: LivePreviewDisplay = .off
  ) {
    self.audioLevelProvider = audioLevelProvider
    self.recordingElapsedProvider = recordingElapsedProvider
    self.livePreviewProvider = livePreviewProvider
    self.onContentHeightChange = onContentHeightChange
    self.usesPreviewLayout = usesPreviewLayout
    self.lockState = lockState
    self.noticeState = noticeState
    _preview = State(initialValue: initialPreview)
  }

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 10) {
        // Rainbow lips icon — audio-reactive during recording.
        // Scales to 2x in hands-free (locked) mode.
        RainbowLipsIcon(size: 24, audioLevel: audioLevel)
          .scaleEffect(lockState.isLocked ? 2.0 : 1.0)

        if !lockState.isLocked {
          Text(FormattingConstants.formatDuration(elapsed))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .transition(.opacity)
        }
      }

      // #1988: the live preview. Display only — the pasted text comes from the
      // normal transcription path after the key is released.
      livePreviewBody

      // #1060: approaching-cap warning banner. Appears inside the same capsule
      // (no panel rebuild), wraps within the pill width, auto-clears.
      if let notice = noticeState.message {
        Text(notice)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.95))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 170)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: lockState.isLocked)
    // Single container animation prevents animation stacking: N per-element
    // modifiers × update rate creates exponential state transitions (gotchas.md).
    //
    // #2201: the PREVIEW layout selects no animation here. `audioLevel` is
    // repolled every 50 ms, so this fires ~20 times a second, and a container
    // animation animates whatever else changed in the same update — including the
    // preview text, and therefore the capsule's HEIGHT. That turned each genuine
    // resize into a smoothly animated one and drove `setFrame` once per frame.
    //
    // The trigger VALUE is kept rather than deleted, so the non-preview capsule's
    // animation is visibly untouched in the diff and the two branches sit side by
    // side. Audio-reactive PAINT is unaffected in both: `RainbowLipsIcon` reads
    // `audioLevel` directly and redraws without needing this.
    //
    // Not a violation of swift-patterns.md RULE: animate-the-container-not-children
    // — that forbids per-child `.animation(value:)`, and this adds none. The
    // container keeps its `lockState` and `noticeState` triggers in both layouts.
    .animation(
      usesPreviewLayout ? nil : .easeOut(duration: 0.08),
      value: audioLevel
    )
    .animation(.easeInOut(duration: 0.25), value: noticeState.message)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    // #2201: the preview pill's height must be a function of what it is SHOWING,
    // never of how tall it happens to be already.
    //
    // Without this the capsule is free to stretch into whatever room the panel
    // offers, because `previewText`'s `.frame(maxHeight:)` grows to its cap under
    // a large proposal. The panel is then sized FROM that measurement
    // (`onContentHeightChange` -> `resizeRecordingPanel`) while the measurement is
    // taken INSIDE the panel, so the pair has no single solution: measured on the
    // real view, one line of text reported 65pt in a 65pt panel and 125pt in a
    // 125pt one. Nothing in the loop pulls the height back down either, so a box
    // that grew for a long sentence stayed at the cap when the recognizer revised
    // the sentence shorter.
    //
    // `fixedSize` makes the stack report its IDEAL height whatever it is offered,
    // which is the same question `showPanel(fitToContent:)` asks at creation — so
    // the two sizing paths finally agree. Growth is unaffected: the ideal height
    // still tracks the text (65 -> 80 -> 125 across one, three and six-plus lines).
    //
    // **Gated, because every modifier on this root is rendered by BOTH layouts.**
    // The 185pt capsule sits inside a fixed 92pt frame and is out of scope for
    // #2198; `vertical: false` leaves it exactly as it was.
    //
    // **Order is load-bearing:** after both paddings, before both backgrounds. The
    // measurement is taken on the padded stack, so moving this either side of it
    // measures a different view than the one that was proven.
    .fixedSize(horizontal: false, vertical: usesPreviewLayout)
    .background(OverlayCapsuleBackground(cornerStyle: usesPreviewLayout ? .rounded : .capsule))
    // #1988: report the capsule's real height so the panel can follow it. Measured
    // on the capsule rather than computed from a line count, because only the text
    // engine knows how many lines a sentence wraps to at this width in this script.
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { onContentHeightChange(geo.size.height) }
          .onChange(of: geo.size.height) { _, height in onContentHeightChange(height) }
      }
    )
    .task {
      while !Task.isCancelled {
        audioLevel = audioLevelProvider()
        elapsed = recordingElapsedProvider() ?? 0
        preview = livePreviewProvider()
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// The preview area.
  ///
  /// **The tail is produced by `.truncationMode(.head)`, not by counting characters
  /// and not by clipping an oversized box.** A character budget is a guess about how
  /// many glyphs fit, and that guess is wrong by a factor of two for CJK and wrong
  /// again for any proportional font. Clipping was tried first and shipped two
  /// visible defects that a screenshot caught immediately: `fixedSize` makes a Text
  /// render at its ideal height regardless of the frame around it, so three lines of
  /// text spilled out of the capsule background entirely and the top line was sliced
  /// through the middle of its glyphs. Letting the text engine drop the head gives
  /// the same "newest words win" result, correct in every script, with a leading
  /// ellipsis that reads as continuation rather than as a rendering fault.
  @ViewBuilder
  private var livePreviewBody: some View {
    switch preview {
    case .off:
      EmptyView()
    case .waiting:
      // One line, so the pill starts compact and the growth the user sees is their
      // own words arriving rather than space that was always reserved.
      previewText(LivePreviewCopy.listening, dimmed: true, lines: 1)
    case .unavailable(let reason):
      // Say why rather than sitting blank. A blank preview reads as "it did not
      // hear me", which is the exact anxiety this feature exists to remove. Two
      // lines because some of these sentences wrap.
      previewText(reason, dimmed: true, lines: 2)
    case .text(let text):
      previewText(text, dimmed: false, lines: Self.previewMaxLines)
    }
  }

  /// One builder for all three states, so the pill cannot change alignment as it
  /// moves between "Listening...", real words, and a reason it cannot run.
  ///
  /// **No fixed height.** The text takes exactly the lines it needs, the capsule
  /// grows with it, and the panel follows via `onContentHeightChange`. At the cap
  /// the text keeps laying out in full but the box stops growing and pins the text
  /// to its BOTTOM, so the overflow leaves at the top and the newest words stay
  /// where the eye already is.
  ///
  /// **`.lineLimit(n)` + `.truncationMode(.head)` does NOT do this, despite
  /// reading as though it should.** Measured by rendering this exact modifier
  /// stack over 60 numbered words: it keeps the OLDEST four lines and truncates
  /// only the LAST one, so a long dictation showed `word1...word32`, then a jump
  /// to `...word53 word60` — the middle silently gone and four fifths of the pill
  /// frozen on the opening words. Review caught it; the screenshot that had
  /// "verified" the behaviour showed a transcript at exactly five lines, which
  /// never exercises overflow at all.
  ///
  /// Bottom-pinned clipping is the literal reading of "scrolls off the top", and
  /// needs no ScrollView (which brings scrollers, elasticity and its own
  /// scroll-to-bottom timing into a borderless overlay) and no manual text
  /// measurement.
  private func previewText(_ message: String, dimmed: Bool, lines: Int) -> some View {
    Text(message)
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(dimmed ? 0.5 : 0.92))
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      // `maxHeight` CAPS without fixing: below the cap the box is the text's own
      // height, which is what lets the pill still grow a line at a time.
      .frame(maxHeight: Self.previewHeight(lines: lines), alignment: .bottom)
      .clipped()
  }

  /// Height of `lines` lines of the preview font.
  ///
  /// Derived from the font's own metrics rather than a literal, so the cap tracks
  /// the type size instead of drifting silently if it changes. An exact multiple
  /// of the line height matters: the clip lands on a line boundary, so no row is
  /// ever cut through the middle of its glyphs. Verified against the render — five
  /// lines measured 75pt, matching 5 x 15.
  private static func previewHeight(lines: Int) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12)
    return ceil(font.ascender - font.descender + font.leading) * CGFloat(lines)
  }

  /// Five lines, matching the shape the founder tested against Spokenly: the pill
  /// grows a line at a time up to this, then holds its size and scrolls.
  private static let previewMaxLines = 5
}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
  var label: String

  var body: some View {
    HStack(spacing: 10) {
      // Spinning spectrum wheel icon — polishing/processing state
      SpectrumWheelIcon(size: 24)

      // #1064: single line that hugs its content. The panel is sized to this
      // view's fittingSize (showPanel `fitToContent`), so short labels
      // ("Polishing...", "Transcribing...") stay compact and the long 60-minute
      // cap-end message gets exactly the width it needs — never clipped, never
      // stranded in empty space (the #1060 fixed-frame regression).
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - ColdStartNoticeView

/// Cold-boot warm-up pill (#879). Two uses, driven by `icon`:
/// - `.spinner` — "getting ready" while the engine warms after a cold boot.
/// - `.ready` — the "ready, press to dictate" announcement.
///
/// Both convey state with a shape (spinning wheel / checkmark) plus text, never
/// color alone (accessibility-noncolor). An optional `subtitle` renders a
/// dimmer secondary line (e.g. which engine is warming).
struct ColdStartNoticeView: View {
  enum Icon {
    case spinner
    case ready
  }

  let title: String
  var subtitle: String?
  let icon: Icon

  var body: some View {
    HStack(spacing: 10) {
      switch icon {
      case .spinner:
        SpectrumWheelIcon(size: 24)
      case .ready:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color(red: 0.2, green: 0.82, blue: 0.45))
          .font(.system(size: 18))
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - NotificationStyle

/// Visual style for transient overlay notifications (errors and warnings).
enum NotificationStyle {
  case error
  case warning
  case interruption
  /// #1891: a user-setup advisory. Not a failure of ours, so it does not
  /// borrow the red failure treatment.
  case advisory

  var iconName: String {
    switch self {
    case .error: "xmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .interruption: ""  // uses distress lips, not SF Symbol
    case .advisory: "mic.slash.fill"
    }
  }

  var iconColor: Color {
    switch self {
    case .error: .red
    case .warning: .orange
    case .interruption: .red
    // #1891: deliberately not red. The glyph carries the meaning, so the state
    // is never signalled by colour alone (accessibility-macos.md
    // RULE: accessibility-macos-baseline, accessibility-noncolor-motion).
    case .advisory: .secondary
    }
  }

  var autoDismissSeconds: Double {
    switch self {
    case .error: 3.0
    case .warning: 2.5
    case .interruption: 2.0
    // #1891: the advisory sentence is ~23 words. At roughly 200 wpm that needs
    // about 7 seconds to read, so the 3.0s error dwell would show a message
    // the user physically cannot finish. 8s, confirmed by reading UAT.
    case .advisory: 8.0
    }
  }

  /// #1891: only the advisory wraps and sizes to its content. Every other
  /// notice is a short single line in a fixed 280x44 box and stays that way.
  var isMultiline: Bool {
    self == .advisory
  }

  var usesDistressLips: Bool {
    self == .interruption
  }
}

// MARK: - NotificationOverlayView

/// Compact notification overlay for errors (red), warnings (orange), and interruptions (distress lips).
struct NotificationOverlayView: View {
  let message: String
  let style: NotificationStyle

  var body: some View {
    HStack(spacing: 8) {
      if style.usesDistressLips {
        RainbowLipsIcon(size: 24, audioLevel: 0, isDistress: true)
      } else {
        Image(systemName: style.iconName)
          .foregroundStyle(style.iconColor)
          .font(.system(size: 16))
      }

      Text(message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(style.usesDistressLips ? Color.orange : .white)
        // #1891: `.lineLimit(1)` in a 280pt box truncates the advisory sentence
        // to a fragment. Only the advisory wraps; every other notice keeps its
        // single-line shape exactly as before.
        .lineLimit(style.isMultiline ? nil : 1)
        .fixedSize(horizontal: false, vertical: style.isMultiline)
        .multilineTextAlignment(.leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      style.usesDistressLips
        ? AnyView(DistressCapsuleBackground()) : AnyView(OverlayCapsuleBackground()))
  }
}

/// Bulk-import-enrichment start/finish pill (#1701 Chunk 2). Mirrors
/// `NotificationOverlayView`'s shell with a neutral status icon — this is
/// neither an error nor a warning, so it does not borrow `NotificationStyle`.
struct ImportStatusOverlayView: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.white)
        .font(.system(size: 16))
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - AccessibilityToastView

// MARK: - LanguageChipView

/// Passive language-detection chip surfaced post-dictation. Two visual states:
/// - `.askToLock`: "Detected <Lang>. Lock it?" with Lock + Dismiss buttons.
/// - `.educateAboutSettings`: "Detected <Lang>. This can be changed in Settings." with Dismiss only.
///
/// Auto-dismiss timer: 6 seconds. Paused while the cursor hovers over the chip.
/// Auto-dismiss callback is gated on a generation token (race protection).
struct LanguageChipView: View {
  let payload: LanguageChipPayload
  let onLock: () -> Void
  let onDismiss: () -> Void
  let onAutoDismiss: () -> Void

  @State private var hovering: Bool = false
  @State private var dismissTask: Task<Void, Never>?

  private static let autoDismissSeconds: Double = 6.0

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "globe")
        .foregroundStyle(.white.opacity(0.85))
        .font(.system(size: 16))

      Text(promptText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 6)

      if payload.state == .askToLock {
        Button(action: {
          dismissTask?.cancel()
          onLock()
        }) {
          Text("Lock")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(Capsule().fill(Color.blue.opacity(0.85)))
        }
        .buttonStyle(.plain)
      }

      Button(action: {
        dismissTask?.cancel()
        onDismiss()
      }) {
        Text("Dismiss")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .background(Capsule().fill(Color.white.opacity(0.15)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
    .onHover { isHovering in
      hovering = isHovering
      if isHovering {
        dismissTask?.cancel()
      } else {
        scheduleAutoDismiss()
      }
    }
    .onAppear {
      scheduleAutoDismiss()
    }
    .onDisappear {
      dismissTask?.cancel()
    }
  }

  private var promptText: String {
    switch payload.state {
    case .askToLock:
      return "Detected \(payload.displayName). Lock it?"
    case .educateAboutSettings:
      return "Detected \(payload.displayName). This can be changed in Settings."
    }
  }

  private func scheduleAutoDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
      guard !Task.isCancelled else { return }
      onAutoDismiss()
    }
  }
}

// MARK: - AccessibilityToastView

struct AccessibilityToastView: View {
  let onGrant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 16))
      Text(DictationNarrator.accessibilityToastText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
      Spacer(minLength: 8)
      Button(action: onGrant) {
        Text("Grant")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.orange.opacity(0.85)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - RecoveryNoticeView (#1063 PR2)

/// The "recovering your last recording" pill shown when a record-press lands
/// while the crash-recovery limb holds the shared engine. Mirrors the cold-start
/// notice shape (spinner + plain-English copy) and adds a Discard affordance for
/// "I don't want to wait." Icon + text (never color-only); the Discard button is
/// keyboard-activatable for VoiceOver.
struct RecoveryNoticeView: View {
  let onDiscard: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(DictationNarrator.recoveryTitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
        Text(DictationNarrator.recoverySubtitle)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.7))
      }
      Spacer(minLength: 8)
      Button(action: onDiscard) {
        Text("Discard")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .background(Capsule().fill(Color.white.opacity(0.18)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Discard recovering recording")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(DictationNarrator.recoveryAccessibilityLabel)
  }
}
