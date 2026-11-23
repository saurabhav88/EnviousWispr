import Foundation

/// #3853: the words of the "Unload polish model after" row on the AI Polish page. One owner, so
/// the row, its Settings Map entry and Settings search read the same.
enum LocalPolishUnloadCopy {
  static let title = LocalizedStringResource(
    "Unload polish model after",
    comment:
      "AI Polish settings, EG-1 and S1-mini: title of the choice that frees the on-Mac polish model's memory after a time without dictation.")
  static let short = LocalizedStringResource(
    "Frees the polish model's memory when you are not dictating.",
    comment: "AI Polish settings: short line under the unload polish model row.")
  static let help = LocalizedStringResource(
    "Frees the on-Mac polish model's memory after the time you choose. Your next dictation wakes it; the first one may take a moment longer.",
    comment: "AI Polish settings: help behind the question mark on the unload polish model row.")
  static let immediatelyWarning = LocalizedStringResource(
    "The polish model is freed after about 10 seconds without a request. Expect a short wait on the next dictation.",
    comment:
      "AI Polish settings: warning under the unload polish model row when Immediately is chosen.")
}
