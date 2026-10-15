import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3765 PR-C: the Audio screen's input-socket row, which the dev control door now uses too.
///
/// When this fails, the user sees the socket row on a mono microphone, a saved input the
/// device no longer has shown as if it existed, or a pick that changes another device's
/// saved input.
@MainActor
@Suite(.tags(.productOutcome))
struct InputSocketRowTests {
  @Test("the row is offered only for a device with a readable UID and more than one input")
  func eligibility() {
    #expect(InputChannelSettings.offersChoice(uid: "mic-a", inputChannelCount: 2))
    #expect(InputChannelSettings.offersChoice(uid: "mic-a", inputChannelCount: 8))
    #expect(InputChannelSettings.offersChoice(uid: "mic-a", inputChannelCount: 1) == false)
    #expect(InputChannelSettings.offersChoice(uid: "", inputChannelCount: 4) == false)
  }

  @Test("the row shows the saved input, or Input 1 when the saved one is gone or invalid")
  func selection() {
    let saved = ["mic-a": 1, "mic-b": 5, "mic-c": -2]
    #expect(InputChannelSettings.selection(for: "mic-a", inputChannelCount: 2, in: saved) == 1)
    #expect(InputChannelSettings.selection(for: "mic-b", inputChannelCount: 2, in: saved) == 0)
    #expect(InputChannelSettings.selection(for: "mic-c", inputChannelCount: 2, in: saved) == 0)
    #expect(InputChannelSettings.selection(for: "mic-d", inputChannelCount: 4, in: saved) == 0)
    #expect(InputChannelSettings.selection(for: "", inputChannelCount: 4, in: ["": 2]) == 0)
  }

  @Test("a pick writes that device's input only, zero-based")
  func choose() {
    let settings = SettingsManager(
      defaults: TestDefaults.suite("ew.tests.3765.channel.\(UUID().uuidString)")!)
    settings.inputChannelByDeviceUID = ["mic-b": 3]
    InputChannelSettings.choose(1, for: "mic-a", in: settings)
    #expect(settings.inputChannelByDeviceUID == ["mic-a": 1, "mic-b": 3])
    InputChannelSettings.choose(0, for: "mic-a", in: settings)
    #expect(settings.inputChannelByDeviceUID == ["mic-a": 0, "mic-b": 3])
  }
}
