import Testing

@testable import EnviousWisprAppKit

// #2664: the "Microphone socket" row's copy, frozen. Drift guard: changing a
// string here is a deliberate product decision, not a side effect.
@Suite("InputSocketCopy is frozen — #2664", .tags(.driftGuard))
struct InputSocketCopyTests {

  @Test("the row label, option labels and helper are byte-exact")
  func copyIsFrozen() {
    #expect(String(localized: InputSocketCopy.labelResource) == "Mic is on")
    #expect(InputSocketCopy.optionLabel(index: 0) == "Input 1")
    #expect(InputSocketCopy.optionLabel(index: 1) == "Input 2")
    #expect(InputSocketCopy.optionLabel(index: 5) == "Input 6")
    #expect(
      InputSocketCopy.helper(deviceName: "Scarlett 2i2 USB") == "Remembered for Scarlett 2i2 USB.")
  }

}
