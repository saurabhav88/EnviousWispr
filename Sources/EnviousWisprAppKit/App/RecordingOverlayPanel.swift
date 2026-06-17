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

  /// Tracks lock state for flicker guard comparison.
  private var isRecordingLocked: Bool = false

  private var accessibilityToastShownThisSession: Bool = false
  private var grantHandler: (() -> Void)?
  private var accessibilityWarningDismissedProvider: () -> Bool = { false }

  // Passive chip handlers — installed by the former root state once at init, invoked by the
  // chip view when the user taps Lock / Dismiss or when the auto-dismiss timer
  // fires. The closures are MainActor-bound; the panel itself is @MainActor.
  private var passiveChipLockHandler: (() -> Void)?
  private var passiveChipDismissHandler: (() -> Void)?
  private var passiveChipAutoDismissHandler: ((UInt64) -> Void)?

  // MARK: - Intent-driven API

  func setGrantHandler(_ handler: @escaping () -> Void) {
    grantHandler = handler
  }

  func setAccessibilityWarningDismissedProvider(_ provider: @escaping () -> Bool) {
    accessibilityWarningDismissedProvider = provider
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

  /// Unified entry point: render the overlay for the given intent.
  /// Guards against identical intents to prevent flicker.
  func show(
    intent: OverlayIntent, audioLevelProvider: @escaping () -> Float = { 0 },
    isRecordingLocked: Bool = false
  ) {
    let isRecordingIntent: Bool = if case .recording = intent { true } else { false }
    guard
      intent != currentIntent || (isRecordingIntent && self.isRecordingLocked != isRecordingLocked)
    else { return }
    self.isRecordingLocked = isRecordingLocked
    currentIntent = intent
    switch intent {
    case .hidden:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Recording complete",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      hide()
    case .recording:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Recording started",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      show(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
    case .processing(let label):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Processing transcription",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showPolishing(label: label)
    case .clipboardFallback:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Text copied to clipboard",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showClipboardFallback()
    case .accessibilityToast:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Accessibility permission needed for auto-paste",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      if accessibilityToastShownThisSession || accessibilityWarningDismissedProvider() {
        showClipboardFallback()
      } else {
        accessibilityToastShownThisSession = true
        showAccessibilityToast()
      }
    case .warning(let message):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Warning: \(message)",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showWarning(message: message)
    case .error(let message):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Error: \(message)",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showError(message: message)
    case .interruption(let message):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Interruption: \(message)",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      showNotification(message: message, style: .interruption)
    case .passiveChip(let payload):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Detected \(payload.displayName)",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      showPassiveChip(payload: payload)
    case .cachingModel(let engineLabel):
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Getting dictation ready, one moment",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: ColdStartNoticeView(
          title: "Getting dictation ready…",
          subtitle: "\(engineLabel) is warming up after a restart",
          icon: .spinner
        ).frame(width: 300, height: 56),
        width: 300, height: 56, dismissAfter: 2.0)
    case .engineReady:
      NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Dictation ready. Press to start.",
          .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
      presentTransientNotice(
        content: ColdStartNoticeView(
          title: "Ready — press to dictate",
          subtitle: nil,
          icon: .ready
        ).frame(width: 240, height: 44),
        width: 240, height: 44, dismissAfter: 1.5)
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
    let existingPanel = panel
    let y = existingPanel?.frame.origin.y
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
      self.showPanel(content: content, width: width, height: height, y: y)
      self.scheduleAutoDismiss(seconds: dismissAfter)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  // MARK: - Legacy API (internal)

  func show(audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false) {
    if panel != nil {
      // A panel already exists (e.g., "Starting..." polishing panel).
      // Transition to recording — mirrors transitionToPolishing() in reverse.
      transitionToRecording(
        audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
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
      self.createPanel(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Show a processing overlay with a custom label during model loading, transcription, or LLM polishing.
  func showPolishing(label: String = "Polishing...") {
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
    audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false, y: CGFloat? = nil
  ) {
    guard panel == nil else { return }

    lockState.isLocked = isRecordingLocked
    let overlayView = RecordingOverlayView(
      audioLevelProvider: audioLevelProvider,
      lockState: lockState,
      noticeState: noticeState
    )
    // Fixed frame accommodating normal (185x44), locked (120x64), and the #1060
    // notice-banner expansion (a 2-line banner under the pill). Content is
    // centered and the capsule self-sizes; showPanel clamps the origin so the
    // taller frame never clips under the menu bar (Codex P2).
    .frame(width: 185, height: 92)
    showPanel(content: overlayView, width: 185, height: 92, y: y)
  }

  /// #1060: flash a transient banner over the LIVE recording pill (a second line
  /// inside the same capsule), then auto-clear. No-op unless a recording panel is
  /// live — leaves `panel`, `currentIntent`, and `generation` untouched (no
  /// teardown → no #930 flicker). The App layer owns the copy string.
  func flashRecordingNotice(_ message: String, dismissAfter: Double? = nil) {
    guard panel != nil, case .recording = currentIntent else { return }
    noticeDismissWork?.cancel()
    noticeDismissWork = nil
    noticeState.message = message
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
      // Transition from existing panel (recording/polishing) to clipboard notice
      transitionToPolishing(label: "Copied. Press \u{2318}V to paste")
      scheduleAutoDismiss()
      return
    }
    pendingCreateWork?.cancel()
    pendingCreateWork = nil
    generation &+= 1
    let token = generation

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.pendingCreateWork = nil
      self.createPolishingPanel(label: "Copied. Press \u{2318}V to paste")
      self.scheduleAutoDismiss()
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Show a transient Accessibility permission notice that auto-dismisses after 6s.
  func showAccessibilityToast() {
    guard panel == nil else {
      transitionToAccessibilityToast()
      scheduleAutoDismiss(seconds: 6.0)
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

  /// Show a transient warning notice that auto-dismisses after 2.5s.
  func showWarning(message: String) {
    showNotification(message: message, style: .warning)
  }

  /// Show a transient error notice that auto-dismisses after 3s.
  func showError(message: String) {
    showNotification(message: message, style: .error)
  }

  /// Unified handler for transient notification overlays (errors and warnings).
  private func showNotification(message: String, style: NotificationStyle) {
    guard panel == nil else {
      transitionToNotification(message: message, style: style)
      scheduleAutoDismiss(seconds: style.autoDismissSeconds)
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
        content: NotificationOverlayView(message: message, style: style).frame(
          width: 280, height: 44),
        width: 280
      )
      self.scheduleAutoDismiss(seconds: style.autoDismissSeconds)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Transition an existing panel to a notification display.
  private func transitionToNotification(message: String, style: NotificationStyle) {
    guard let existingPanel = panel else { return }
    let y = existingPanel.frame.origin.y

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
        content: NotificationOverlayView(message: message, style: style).frame(
          width: 280, height: 44),
        width: 280,
        y: y
      )
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  private func createPolishingPanel(label: String = "Polishing...") {
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
    guard let existingPanel = panel else { return }
    let y = existingPanel.frame.origin.y

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
        y: y
      )
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Transition an existing panel from recording to polishing mode.
  private func transitionToPolishing(label: String = "Polishing...") {
    guard let existingPanel = panel else { return }
    clearRecordingNotice()  // #1060 (Codex P3): don't leak a cap notice into the next session.
    let y = existingPanel.frame.origin.y

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
        content: PolishingOverlayView(label: label), width: 230, y: y, fitToContent: true)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  /// Transition an existing panel from polishing/processing to recording mode.
  /// Mirrors transitionToPolishing() — tears down the current panel and creates
  /// a recording panel at the same position on the next run loop cycle.
  private func transitionToRecording(
    audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false
  ) {
    guard let existingPanel = panel else { return }
    clearRecordingNotice()  // #1060 (Codex P3): fresh session starts with no stale notice.
    let y = existingPanel.frame.origin.y

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
        audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked, y: y)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
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
    content: V, width: CGFloat, height: CGFloat = 44, y: CGFloat? = nil,
    fitToContent: Bool = false
  ) {
    // Guard against the edge case where no screen is available (C3).
    guard
      let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    else { return }

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
    let requestedY = y ?? (targetScreen.visibleFrame.maxY - 60)
    // #1060 (Codex P2): keep the whole panel within the visible frame. The
    // recording pill's frame is tall enough to host the cap-warning banner, and
    // positioning by the bottom origin would push the top above the visible
    // frame (clipping under the menu bar) on a normal recording start. Clamp the
    // origin so the top never exceeds the frame. Small panels (≤ the default
    // 60 pt offset) are unaffected.
    let maxOriginY = targetScreen.visibleFrame.maxY - resolvedHeight - 8
    let panelY = min(requestedY, maxOriginY)
    p.setFrameOrigin(NSPoint(x: x, y: panelY))

    p.orderFrontRegardless()
    self.panel = p
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

  private func createPassiveChipPanel(payload: LanguageChipPayload, y: CGFloat? = nil) {
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
    showPanel(content: view, width: 340, height: 56, y: y)
  }

  private func transitionToPassiveChip(payload: LanguageChipPayload) {
    guard let existingPanel = panel else { return }
    let y = existingPanel.frame.origin.y

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
      self.createPassiveChipPanel(payload: payload, y: y)
    }
    pendingCreateWork = work
    DispatchQueue.main.async(execute: work)
  }

  func hide() {
    currentIntent = .hidden
    isRecordingLocked = false
    lockState.isLocked = false
    clearRecordingNotice()
    autoDismissTask?.cancel()
    autoDismissTask = nil
    generation &+= 1
    // Cancel any pending deferred panel creation so it never fires.
    // This handles the rapid-ESC race: if hide() is called before the
    // DispatchQueue.main.async closure from show() has had a chance to run,
    // cancelling the work item prevents the panel from being created at all.
    // The generation counter check inside the closure is a secondary guard.
    pendingCreateWork?.cancel()
    pendingCreateWork = nil

    guard let panelToClose = panel else { return }
    panel = nil

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
        .opacity(glowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
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
  var lockState: OverlayLockState
  /// #1060: transient notice banner shown inside the recording capsule.
  var noticeState: OverlayNoticeState
  @State private var audioLevel: Float = 0
  @State private var elapsed: TimeInterval = 0

  private let startTime = Date()

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
    .animation(.easeOut(duration: 0.08), value: audioLevel)
    .animation(.easeInOut(duration: 0.25), value: noticeState.message)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
    .task {
      while !Task.isCancelled {
        audioLevel = audioLevelProvider()
        elapsed = Date().timeIntervalSince(startTime)
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
  var label: String = "Polishing..."

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

  var iconName: String {
    switch self {
    case .error: "xmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .interruption: ""  // uses distress lips, not SF Symbol
    }
  }

  var iconColor: Color {
    switch self {
    case .error: .red
    case .warning: .orange
    case .interruption: .red
    }
  }

  var autoDismissSeconds: Double {
    switch self {
    case .error: 3.0
    case .warning: 2.5
    case .interruption: 2.0
    }
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
        .lineLimit(1)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      style.usesDistressLips
        ? AnyView(DistressCapsuleBackground()) : AnyView(OverlayCapsuleBackground()))
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
      Text("Auto-paste needs Accessibility")
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
