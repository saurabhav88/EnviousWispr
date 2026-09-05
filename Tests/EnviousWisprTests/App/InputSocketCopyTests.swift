import Testing

@testable import EnviousWisprAppKit

// #2664: the "Microphone socket" row's copy, frozen. Drift guard: changing a
// string here is a deliberate product decision, not a side effect.
@Suite("InputSocketCopy is frozen — #2664", .tags(.driftGuard))
struct InputSocketCopyTests {

  @Test("the row header, option labels and helper are byte-exact")
  func copyIsFrozen() {
    #expect(InputSocketCopy.header == "Microphone socket")
    #expect(InputSocketCopy.optionLabel(index: 0) == "Input 1")
    #expect(InputSocketCopy.optionLabel(index: 1) == "Input 2")
    #expect(InputSocketCopy.optionLabel(index: 5) == "Input 6")
    #expect(
      InputSocketCopy.helper(inputCount: 2, deviceName: "Scarlett 2i2 USB")
        == "This device has 2 inputs. Pick the one your microphone is plugged into. "
        + "EnviousWispr remembers this for Scarlett 2i2 USB.")
  }

  @Test("no dashes anywhere in the row's copy (content rule)")
  func noDashes() {
    let all = [
      InputSocketCopy.header, InputSocketCopy.optionLabel(index: 3),
      InputSocketCopy.helper(inputCount: 8, deviceName: "Any Box"),
    ]
    for s in all {
      #expect(s.contains("\u{2014}") == false, "em dash in: \(s)")
      #expect(s.contains("\u{2013}") == false, "en dash in: \(s)")
    }
  }
}
