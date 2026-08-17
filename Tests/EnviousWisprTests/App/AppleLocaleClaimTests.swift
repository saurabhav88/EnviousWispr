import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2145 — the three pure decisions behind a locale claim.
///
/// The release-target one is the whole bug: `AssetInventory.release(reservedLocale:)` matches on
/// `Locale.identifier`, the inventory stores `en_US`, and every call site handed it `en-US`, so no
/// release the app ever issued did anything.
struct AppleLocaleClaimTests {

  @Test("The release target uses the identifier spelling macOS matches on, not the tag")
  func releaseTargetUsesTheICUForm() {
    // Measured on the real SDK: Locale(identifier: "en-US") -> release false, claim still held;
    // Locale(identifier: "en_US") -> release true, claim gone.
    let target = AppleLocaleClaim.releaseTarget(tag: "en-US", reserved: [])
    #expect(target.identifier == "en_US")
    #expect(target.identifier != "en-US", "the hyphenated form is the shipped defect")
  }

  @Test("Every catalogue shape converts, not just the two-letter-region ones")
  func releaseTargetHandlesEveryTagShape() {
    let cases = [
      ("de-DE", "de_DE"), ("zh-CN", "zh_CN"), ("pt-BR", "pt_BR"),
      ("yue-CN", "yue_CN"), ("ca-ES", "ca_ES"), ("nb-NO", "nb_NO"),
    ]
    for (tag, expected) in cases {
      #expect(
        AppleLocaleClaim.releaseTarget(tag: tag, reserved: []).identifier == expected,
        "\(tag) must release as \(expected)")
    }
  }

  @Test("A visible claim is released as the object the inventory itself returned")
  func releaseTargetPrefersTheInventorysOwnObject() {
    // **The input is deliberately one the real inventory does not produce.** Measured across all 54
    // supported locales: the ICU form rebuilt from the tag equals the stored identifier every time,
    // 0 divergent. So on today's macOS the fallback alone would be correct, and an assertion using a
    // realistic object cannot tell the two paths apart — the first version of this test passed with
    // the preference deleted, which is a guard that looks binding and is not.
    //
    // It is kept, and tested with a synthetic divergent object, because the failure it prevents is
    // SILENT: if a future macOS ever hands back a spelling the ICU rebuild does not reproduce,
    // release goes back to returning false and doing nothing, which is #2145 exactly. That is the
    // one condition under which dont-test-what-cannot-happen admits a hypothetical.
    let divergent = Locale(identifier: "en-US")  // bcp47 "en-US", identifier "en-US", ICU "en_US"
    #expect(divergent.identifier != Locale(identifier: "en-US").identifier(.icu), "control")

    let target = AppleLocaleClaim.releaseTarget(
      tag: "en-US", reserved: [Locale(identifier: "de_DE"), divergent])

    #expect(
      target.identifier == divergent.identifier,
      "the inventory's own object wins over a rebuilt identifier, or the release silently no-ops")
  }

  @Test("Reserve outcomes: proceed, recover once, then refuse")
  func outcomeTable() {
    #expect(
      AppleLocaleClaim.outcome(
        reserveReturned: true, heldAfter: true, recoveryAlreadyTried: false) == .proceed)
    // False is not failure: it is what macOS returns for a claim somebody already holds.
    #expect(
      AppleLocaleClaim.outcome(
        reserveReturned: false, heldAfter: true, recoveryAlreadyTried: false) == .proceed)
    #expect(
      AppleLocaleClaim.outcome(
        reserveReturned: false, heldAfter: false, recoveryAlreadyTried: false) == .recover)
    #expect(
      AppleLocaleClaim.outcome(
        reserveReturned: false, heldAfter: false, recoveryAlreadyTried: true) == .refuse)
    // A second success after recovery still proceeds rather than refusing.
    #expect(
      AppleLocaleClaim.outcome(
        reserveReturned: true, heldAfter: true, recoveryAlreadyTried: true) == .proceed)
  }

  @Test("Only an owned, idle claim may be evicted")
  func evictionVictimRespectsOwnershipAndUse() {
    let reserved = ["a-AA", "b-BB", "c-CC"]

    #expect(
      AppleLocaleClaim.evictionVictim(
        reserved: reserved, owned: ["b-BB"], inUse: []) == "b-BB")
    #expect(
      AppleLocaleClaim.evictionVictim(
        reserved: reserved, owned: ["b-BB"], inUse: ["b-BB"]) == nil,
      "ours but still working")
    #expect(
      AppleLocaleClaim.evictionVictim(reserved: reserved, owned: [], inUse: []) == nil,
      "nothing of ours: another process's claim is not ours to take")
    #expect(
      AppleLocaleClaim.evictionVictim(
        reserved: reserved, owned: ["c-CC", "a-AA"], inUse: ["a-AA"]) == "c-CC",
      "skips the in-use one and keeps the inventory's order")
  }

  @Test("The victim choice is deterministic for one inventory reading")
  func evictionVictimIsStable() {
    // An unstable choice would make the eviction path irreproducible, and a failure that cannot be
    // replayed costs more than the one it catches.
    let reserved = ["a-AA", "b-BB", "c-CC"]
    let owned: Set<String> = ["c-CC", "b-BB"]
    let first = AppleLocaleClaim.evictionVictim(reserved: reserved, owned: owned, inUse: [])
    for _ in 0..<20 {
      #expect(
        AppleLocaleClaim.evictionVictim(reserved: reserved, owned: owned, inUse: []) == first)
    }
    #expect(first == "b-BB", "the inventory's own order decides, not the Set's")
  }
}
