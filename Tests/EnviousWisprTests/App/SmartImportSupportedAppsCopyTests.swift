import EnviousWisprPostProcessing
import Testing

@testable import EnviousWisprAppKit

/// The picker's "EnviousWispr can read …" sentence (#1773).
///
/// It lives in AppKit and is tested here rather than being pushed down into
/// PostProcessing so a PostProcessing test could reach it — moving user-facing
/// English a layer down for test convenience is exactly what "convenience is
/// not justification" forbids, and this target already links AppKit.
@Suite("SmartImportSupportedAppsCopy")
struct SmartImportSupportedAppsCopyTests {

  @Test("the picker sentence names every adapter the registry ships")
  func namesEveryRegisteredAdapter() {
    // A page that wrongly LEAVES AN APP OUT contains no mention of it to find,
    // so a sweep for the new name can never catch the omission (#1944). This
    // is the freeze test that makes the copy follow the registry instead of
    // being remembered.
    let sentence = SmartImportSupportedAppsCopy.sentence(for: .v1)
    for name in SmartImportRegistry.v1.displayNames {
      #expect(sentence.contains(name), "picker copy omits \(name)")
    }
  }

  @Test("the picker sentence reads naturally at one, two and many apps")
  func grammarAcrossCounts() {
    func sentence(_ adapters: [any SmartImportAdapter]) -> String {
      SmartImportSupportedAppsCopy.sentence(for: SmartImportRegistry(adapters: adapters))
    }
    #expect(sentence([VoxAdapter()]) == "Vox")
    #expect(sentence([VoxAdapter(), JunoAdapter()]) == "Vox and Juno")
    #expect(
      sentence([VoxAdapter(), JunoAdapter(), SpokenlyAdapter()]) == "Vox, Juno, and Spokenly")
  }

  @Test("an empty registry still produces a readable sentence")
  func emptyRegistry() {
    // Unreachable in production — `v1` is never empty — but the formatter must
    // not produce "EnviousWispr can read ." if a future refactor empties it.
    #expect(
      SmartImportSupportedAppsCopy.sentence(for: SmartImportRegistry(adapters: []))
        == "no apps yet")
  }
}
