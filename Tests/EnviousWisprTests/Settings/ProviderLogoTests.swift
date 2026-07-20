import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// Issue #1286 Phase 2 — logo smoke test. Guards two contracts:
///   1. Each inline brand SVG rasterizes to a valid, template-tinted image.
///   2. A garbage SVG fails to build → nil, so the tile falls back to a
///      lettered monogram (the "Apple tile was empty" class, plan §7/§9).
/// The real render-at-tile-size fidelity check is Live UAT; this locks the
/// build/fallback boundary in CI.
@Suite("ProviderLogoSVG — inline marks rasterize, garbage falls back")
struct ProviderLogoTests {

  @Test("Each brand SVG builds a valid template image")
  func brandMarksBuild() {
    for svg in [ProviderLogoSVG.openAI, ProviderLogoSVG.gemini, ProviderLogoSVG.ollama] {
      let image = ProviderLogoSVG.templateImage(svg)
      #expect(image != nil, "brand SVG should rasterize to a valid image")
      #expect(image?.isTemplate == true, "monochrome marks must be template-tinted")
      #expect((image?.size.width ?? 0) > 0)
    }
  }

  @Test("Garbage SVG → nil, so the tile can fall back to a monogram")
  func garbageFallsBack() {
    #expect(ProviderLogoSVG.templateImage("not an svg at all") == nil)
    #expect(ProviderLogoSVG.templateImage("") == nil)
  }

  @Test("Monograms identify the correct provider (#1597)")
  func monogramsMatchProviders() {
    // #1597: the prior version only checked `.isEmpty`, so swapping two
    // providers' monograms (or returning the same letter for every provider)
    // would still pass. Assert the exact contract instead.
    #expect(ProviderLogoSVG.monogram(for: .openAI) == "OA")
    #expect(ProviderLogoSVG.monogram(for: .gemini) == "G")
    // Claude ships with no hand-drawn brand SVG (plan §2.2 non-goal), so its
    // monogram is a first-class fallback, not a degraded state (#158).
    #expect(ProviderLogoSVG.monogram(for: .claude) == "CL")
    #expect(ProviderLogoSVG.monogram(for: .ollama) == "OL")
    #expect(ProviderLogoSVG.monogram(for: .egOne) == "EG")
    // Codex review flagged this as codifying a broken empty Apple fallback --
    // verified that's a DIFFERENT bug (#1613): `appleMark`'s SF-Symbol-unavailable
    // branch hardcodes `monogram("")` directly and never calls this static
    // function for `.appleIntelligence` at all, so this case is unreached by
    // production today. Asserting its actual current value here doesn't lock in
    // #1613's fix; that fix doesn't touch this function.
    #expect(ProviderLogoSVG.monogram(for: .appleIntelligence) == "")
    #expect(ProviderLogoSVG.monogram(for: .none) == "--")
  }
}
