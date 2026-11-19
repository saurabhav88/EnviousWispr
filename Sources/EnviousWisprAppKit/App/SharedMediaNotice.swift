import AppKit

/// The receiver owns failures after macOS has delivered the share.
package enum SharedMediaNotice {
  case unavailable
  case finishSetup
  case moveToApplications
  case importInUse

  @MainActor package func present() {
    let message: String
    switch self {
    case .unavailable:
      message = String(localized: "EnviousWispr couldn’t open this recording. Try sharing it again.")
    case .finishSetup:
      message = String(localized: "Finish setting up EnviousWispr, then share the file again.")
    case .moveToApplications:
      message = String(localized: "Open EnviousWispr from Applications, then share the file again.")
    case .importInUse:
      message = String(localized: "Finish or clear the current import, then share the file again.")
    }
    let alert = NSAlert()
    alert.messageText = String(localized: "Transcribe a File")
    alert.informativeText = message
    if case .moveToApplications = self {
      // A sheet could be queued behind the Move question and disappear with this
      // process. Show the Share refusal in this turn of the preflight flow.
      alert.runModal()
    } else if let window = NSApp.keyWindow {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}
