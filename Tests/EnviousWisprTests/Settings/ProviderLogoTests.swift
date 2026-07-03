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

  @Test("Monograms are non-empty for the SVG-backed providers")
  func monogramsPresent() {
    #expect(!ProviderLogoSVG.monogram(for: .openAI).isEmpty)
    #expect(!ProviderLogoSVG.monogram(for: .gemini).isEmpty)
    #expect(!ProviderLogoSVG.monogram(for: .ollama).isEmpty)
    #expect(!ProviderLogoSVG.monogram(for: .egOne).isEmpty)
  }
}
