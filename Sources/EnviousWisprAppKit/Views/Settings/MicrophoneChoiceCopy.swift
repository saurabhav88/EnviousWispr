import Foundation

/// Additional explanation only; selectable menu titles keep their existing grammar.
enum MicrophoneChoiceCopy {
  static let autoExplanation = LocalizedStringResource(
    "Auto may skip inputs that are not microphones.",
    comment: "Microphone menu: Auto can divert from the macOS input when it is proven not to be a microphone. Never promise it always follows macOS.")
  static let inUse = LocalizedStringResource(
    "In use", comment: "Microphone settings: capture is active on the displayed microphone, not merely selected or kept warm.")
}
