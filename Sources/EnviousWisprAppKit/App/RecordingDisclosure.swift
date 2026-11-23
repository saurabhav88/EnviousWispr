import EnviousWisprCore
import Foundation

/// The recording disclosure's words (#3147 §16 C9), owned here for the History banner; What's
/// New carries the same facts as literal entry text. Setup shows no note since #4528 (founder
/// 2026-11-13: new users learn about recordings in the post-install tour, #4565). Each surface reads
/// the LIVE settings, so it never describes a default the user already changed: saving off says
/// so, and a chosen keep period is never called "until you delete them". Fresh installs read the
/// canonical defaults through the same live values (nothing is seeded).
///
/// Facts every version states: saved dictations keep a recording on this Mac; by default it
/// stays until the user deletes it; the keep period and storage behavior are settings; turning
/// off Save dictation recordings in Settings > App Settings > Recordings stops new ones and does
/// not delete existing audio; existing audio can be deleted in History or with Delete all
/// dictation recordings, and the text stays.
enum RecordingDisclosureCopy {
  static var bannerTitle: String {
    String(
      localized: "Your dictations now have recordings",
      comment: "History: title of the one-time notice that saved dictations now keep a recording.")
  }

  static func bannerBody(saving: Bool, retention: DictationRecordingRetention) -> String {
    guard saving else {
      return String(
        localized:
          "Saving dictation recordings is off, so new dictations are not recorded. You can turn it on in Settings > App Settings > Recordings. Recordings you already have can be deleted in History or with Delete all dictation recordings there. The text always stays.",
        comment: "History: the one-time recording notice when the user already turned saving off.")
    }
    if retention == .forever {
      return String(
        localized:
          "EnviousWispr keeps a recording of each saved dictation on this Mac, so you can play it back in History. Recordings stay until you delete them, or for a keep period you choose in Settings > App Settings > Recordings. Turning off Save dictation recordings there stops new ones without deleting the ones you have. Delete a recording in History, or all of them with Delete all dictation recordings. The text always stays.",
        comment: "History: the one-time recording notice with the default keep period.")
    }
    return String(
      localized:
        "EnviousWispr keeps a recording of each saved dictation on this Mac, so you can play it back in History. Recordings are kept for the period you chose in Settings > App Settings > Recordings. Turning off Save dictation recordings there stops new ones without deleting the ones you have. Delete a recording in History, or all of them with Delete all dictation recordings. The text always stays.",
      comment: "History: the one-time recording notice when the user chose a keep period.")
  }

  static var openSettings: String {
    String(
      localized: "Open Recordings settings",
      comment: "History: button on the storage warning that opens App Settings > Recordings.")
  }

  static var dismiss: String {
    String(
      localized: "Dismiss",
      comment: "History: closes the one-time recording notice for good.")
  }
}
