import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Observation

/// History's Paste, shared by the dictation and meeting details (#3875, #3972 R36): the same
/// clipboard transaction as Paste Last Dictation, so "Restore clipboard after paste" and "Keep
/// dictations out of clipboard history" hold here too.
///
/// #4101: it pastes only into the app the user came from (`PreviousApplicationTracker`, read at
/// the press), and only once that app is OBSERVED in front: it hides this app, brings that app
/// forward if needed and checks again right before the write. When the app cannot be confirmed,
/// nothing touches the clipboard and History says so. This confirms an application, never a
/// window or a field, and a posted Command-V is not proof the text arrived.
///
/// One instance, built by `WisprBootstrapper` and shared by both details and the main window,
/// owns the one paste that may be waiting at a time. Why a paste did not happen goes to the
/// caller's `showNotice`, which History's page owns (`HistoryPasteNotice`).
@MainActor
@Observable
final class HistoryPaste {
  struct Effects {
    var hide: @MainActor () -> Void
    /// The live read: the cached permission flag stops updating once both permissions are granted.
    var accessibilityGrantedLive: @MainActor () -> Bool
    var confirmation: FrontApplicationConfirmation.Effects
    var restoreClipboard: @MainActor () -> Bool
    var markTransient: @MainActor () -> Bool
    /// `ClipboardCleanup.manualPaste` on the general board with the real Command-V, in production.
    var manualPaste:
      @MainActor (_ text: String, _ restore: Bool, _ markTransient: Bool) ->
        ClipboardCleanup.ManualClipboardResult
  }

  /// The refusal for a destination that is missing or could not be confirmed, and for a clipboard
  /// that could not be used: in every case nothing was pasted and the text is still in History.
  static var couldNotPaste: String {
    String(
      localized: "Couldn't paste. Your text is still in History.",
      comment: "History: Paste could not use the clipboard, so nothing was pasted.")
  }

  private let effects: Effects
  @ObservationIgnored private var pending: (id: UInt64, task: Task<Void, Never>)?
  @ObservationIgnored private var nextID: UInt64 = 0

  init(effects: Effects) {
    self.effects = effects
  }

  /// Whether a paste is waiting for its destination.
  var isPending: Bool { pending != nil }

  /// Pastes the row's text into `destination`, the app the user came from. `allowed` and `text`
  /// are read again after the wait: a dictation can start, a held row can lapse, a meeting can be
  /// deleted and Accessibility can be turned off while History is hidden. A press while another
  /// paste waits is ignored. The returned task lets a caller (a test) wait for this one paste.
  @discardableResult
  func paste(
    destination: NSRunningApplication?,
    allowed: @escaping @MainActor () -> Bool,
    text: @escaping @MainActor () -> String?,
    showHistory: @escaping @MainActor () -> Void,
    showNotice: @escaping @MainActor (String) -> Void,
    dispatched: @escaping @MainActor () -> Void = {}
  ) -> Task<Void, Never>? {
    guard allowed() else { return nil }
    guard pending == nil else { return nil }
    // Refused before anything is hidden: with no app to return to, the text stays in History.
    guard let destination, !effects.confirmation.isTerminated(destination) else {
      showNotice(Self.couldNotPaste)
      return nil
    }
    nextID &+= 1
    let id = nextID
    let task = Task { [self] in
      await run(
        id: id, destination: destination, allowed: allowed, text: text, showHistory: showHistory,
        showNotice: showNotice, dispatched: dispatched)
      if pending?.id == id { pending = nil }
    }
    pending = (id, task)
    return task
  }

  /// The main window closed: a waiting paste ends.
  func windowClosed() { cancelPending() }

  /// A committed navigation in the main window: leaving History ends a waiting paste; staying on
  /// it (another History selection, a filter) does not. Hiding the app for the paste is not a
  /// navigation and never reaches here.
  func navigated(from previous: SettingsPage, to current: SettingsPage) {
    if previous == .history, current != .history { cancelPending() }
  }

  /// Ends the waiting paste, if any. Idempotent. The request is forgotten before its task is
  /// cancelled, so a task that resumes later writes nothing, shows nothing and cannot clear a
  /// newer paste.
  func cancelPending() {
    guard let waiting = pending else { return }
    pending = nil
    waiting.task.cancel()
  }

  private func isCurrent(_ id: UInt64) -> Bool { pending?.id == id && !Task.isCancelled }


  private func run(
    id: UInt64, destination: NSRunningApplication, allowed: @MainActor () -> Bool,
    text: @MainActor () -> String?, showHistory: @MainActor () -> Void,
    showNotice: @MainActor (String) -> Void, dispatched: @MainActor () -> Void
  ) async {
    /// Brings History back and says why nothing was pasted.
    func refuse(_ notice: String) {
      showHistory()
      showNotice(notice)
    }
    guard isCurrent(id) else { return }
    effects.hide()
    let confirmation = FrontApplicationConfirmation(effects: effects.confirmation)
    let outcome = await confirmation.bringToFront(destination)
    // A cancelled paste ends silently: the user closed the window or left History.
    guard isCurrent(id) else { return }
    switch outcome {
    case .cancelled:
      return
    case .targetGone, .focusLost:
      refuse(Self.couldNotPaste)
      return
    case .confirmed:
      break
    }
    // No await from here to the write: these are the state the paste meets.
    guard allowed(), effects.accessibilityGrantedLive(), let text = text() else {
      // Nothing was written or pasted; bring History back rather than leave the app hidden
      // (cloud review of PR #3945). The row's own state now explains why Paste stood down.
      showHistory()
      return
    }
    guard !effects.confirmation.isTerminated(destination), confirmation.isFrontmost(destination)
    else {
      refuse(Self.couldNotPaste)
      return
    }
    let result = effects.manualPaste(text, effects.restoreClipboard(), effects.markTransient())
    switch result {
    case .dispatched:
      dispatched()
    case .dispatchFailed:
      // The text is on the clipboard and no restore is scheduled.
      refuse(
        String(
          localized: "Copied. Paste it yourself.",
          comment: "History: Paste could not press Command-V; the text is on the clipboard."))
    case .clipboardBusy, .writeFailed:
      refuse(Self.couldNotPaste)
    case .copied:
      // `manualPaste` never answers `.copied`; that is `manualCopy`'s result.
      break
    }
  }
}

extension HistoryPaste {
  /// The production effects: the real hide, permission read, activation and clipboard.
  static func live(
    settings: SettingsManager, permissions: PermissionsService,
    application: any ApplicationActivating
  ) -> HistoryPaste {
    HistoryPaste(
      effects: Effects(
        hide: { NSApp.hide(nil) },
        accessibilityGrantedLive: { permissions.accessibilityGrantedLive },
        confirmation: .init(
          frontmost: { NSWorkspace.shared.frontmostApplication },
          isTerminated: { $0.isTerminated },
          // The AX route first, as Paste Last does: macOS 14+ refuses a background process the
          // foreground through `activate()`.
          activate: { app in
            application.forceActivate(processIdentifier: app.processIdentifier)
              || application.activate(app)
          },
          sleep: { try? await Task.sleep(for: $0) },
          now: { ContinuousClock.now }),
        restoreClipboard: { [weak settings] in settings?.restoreClipboardAfterPaste ?? true },
        markTransient: { [weak settings] in settings?.keepDictationsOutOfClipboardHistory ?? false
        },
        manualPaste: { text, restore, markTransient in
          ClipboardCleanup.manualPaste(
            text: text, restore: restore, markTransient: markTransient, on: .general,
            dispatch: {
              PasteService.postPasteKeystroke(keyCode: SyntheticCopyChord.commandVKeyCode())
            })
        }))
  }
}
