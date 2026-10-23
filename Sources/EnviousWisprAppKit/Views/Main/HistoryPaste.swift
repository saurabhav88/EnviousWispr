import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices

/// History's Paste, shared by the dictation and meeting details (#3875, #3972 R36): the same
/// clipboard transaction as Paste Last Dictation, so "Restore clipboard after paste" and "Keep
/// dictations out of clipboard history" hold here too.
@MainActor
enum HistoryPaste {
  /// Hides the app, waits for the previous app to take the front, then reads the text once and
  /// pastes it. `allowed` and `text` are read AFTER the wait: a dictation can start, a held row
  /// can lapse, a meeting can be deleted and Accessibility can be turned off while History is
  /// hidden. Nothing pasted brings History back; a failure says why.
  static func paste(
    allowed: @escaping @MainActor () -> Bool,
    text: @escaping @MainActor () -> String?,
    settings: SettingsManager,
    permissions: PermissionsService,
    showHistory: @escaping @MainActor () -> Void,
    showNotice: @escaping @MainActor (String) -> Void,
    dispatched: @escaping @MainActor () -> Void = {}
  ) {
    guard allowed() else { return }
    NSApp.hide(nil)
    Task {
      try? await Task.sleep(for: .milliseconds(TimingConstants.appHideBeforePasteDelayMs))
      // The live read: the cached flag stops updating once both permissions are granted.
      guard allowed(), permissions.accessibilityGrantedLive, let text = text() else {
        // Nothing was written or pasted; bring History back rather than leave the app hidden
        // (cloud review of PR #3945). The row's own state now explains why Paste stood down.
        showHistory()
        return
      }
      let result = ClipboardCleanup.manualPaste(
        text: text, restore: settings.restoreClipboardAfterPaste,
        markTransient: settings.keepDictationsOutOfClipboardHistory, on: .general,
        dispatch: { PasteService.postPasteKeystroke() })
      switch result {
      case .dispatched:
        dispatched()
      case .dispatchFailed:
        // The text is on the clipboard and no restore is scheduled.
        showNotice(
          String(
            localized: "Copied. Paste it yourself.",
            comment: "History: Paste could not press Command-V; the text is on the clipboard."))
      case .clipboardBusy, .writeFailed:
        showNotice(
          String(
            localized: "Couldn't paste. Your text is still in History.",
            comment: "History: Paste could not use the clipboard, so nothing was pasted."))
      case .copied:
        // `manualPaste` never answers `.copied`; that is `manualCopy`'s result.
        break
      }
    }
  }
}
