import Testing

@testable import EnviousWisprAppKit

/// #3479, #3486: a microphone unplugged while a picker was open must not be saved. Driven with an
/// injected list of what the system lists "right now"; the production default asks CoreAudio.
@Suite("Microphone choice validation (#3479, #3486)", .tags(.productOutcome))
@MainActor
struct MicrophoneChoiceValidationTests {
  @Test("Auto is always selectable, even with no input connected")
  func autoIsAlwaysSelectable() {
    #expect(MicrophoneChoiceValidation.isSelectable(uid: "", connectedUIDs: { [] }))
    #expect(MicrophoneChoiceValidation.isSelectable(uid: "", connectedUIDs: { ["usb-uid"] }))
  }

  @Test("a connected input is selectable")
  func connectedInputIsSelectable() {
    #expect(
      MicrophoneChoiceValidation.isSelectable(
        uid: "usb-uid", connectedUIDs: { ["builtin-uid", "usb-uid"] }))
  }

  @Test("an input that is no longer connected is refused, including with nothing connected")
  func unpluggedInputIsRefused() {
    #expect(
      !MicrophoneChoiceValidation.isSelectable(
        uid: "usb-uid", connectedUIDs: { ["builtin-uid"] }))
    #expect(!MicrophoneChoiceValidation.isSelectable(uid: "usb-uid", connectedUIDs: { [] }))
  }
}
