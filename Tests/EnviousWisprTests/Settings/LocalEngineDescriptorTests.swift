import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// #2649. The two bundled engines render through ONE status card, so what makes
/// them different is a value, and these rows are about that value being right.
///
/// The download size is the row that matters. It is a promise about the user's
/// disk and their patience, and it is the kind of number that goes stale in
/// silence: a model revision ships as a manifest edit with no Swift change, so
/// a hand-written size keeps describing the previous file forever. Every size
/// here is checked against the manifest that actually ships.
@Suite("Bundled local engine descriptors (#2649)", .tags(.driftGuard))
struct LocalEngineDescriptorTests {

  private static func manifest(_ leaf: String) throws -> DeliveryManifest {
    let url = ParakeetShippedManifestTests.repoRoot
      .appendingPathComponent("Sources/EnviousWispr/Resources/\(leaf)")
    return try DeliveryManifest.load(from: Data(contentsOf: url))
  }

  /// Decimal, not binary. EG-1's shipped string is "2.9 GB" for 2,889,512,608
  /// bytes, which is decimal, and decimal is also what Finder shows the user
  /// when they go looking for the space. S1-mini's publisher states "462 MiB"
  /// for the same file; quoting that would have the app disagree with the
  /// user's own disk by 22 MB.
  private static func decimalMB(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000 }

  @Test("S1-mini's stated download size is the size of the file we actually serve")
  func s1MiniSizeMatchesItsManifest() throws {
    let manifest = try Self.manifest("s1-delivery-manifest.json")
    let stated = LocalEngineDescriptor.s1Mini.downloadSize
    #expect(stated == "484 MB")

    let actual = Self.decimalMB(manifest.totalBytes)
    let claimed = try #require(Double(stated.replacingOccurrences(of: " MB", with: "")))
    #expect(
      abs(actual - claimed) < 1.0,
      "the card promises \(stated) but the manifest ships \(actual) MB")
    // Two-way control on the unit: if this were read as MiB the answer would be
    // 462, so a suite that passed under either reading would prove nothing.
    #expect(
      abs(Double(manifest.totalBytes) / 1_048_576 - claimed) > 20,
      "484 and 462 must not both satisfy this row, or the unit is untested")
  }

  @Test("EG-1's stated download size is the size of the file we actually serve")
  func egOneSizeMatchesItsManifest() throws {
    let manifest = try Self.manifest("eg1-delivery-manifest.json")
    #expect(LocalEngineDescriptor.egOne.downloadSize == "2.9 GB")
    let actualGB = Double(manifest.totalBytes) / 1_000_000_000
    #expect(
      abs(actualGB - 2.9) < 0.1,
      "the card promises 2.9 GB but the manifest ships \(actualGB) GB")
  }

  /// The licence's ADDITIONAL TERM binds this name, so the descriptor must READ
  /// the one owner rather than restate the string. A restated copy is what lets
  /// a rename land in one place and not the other.
  @Test("S1-mini's descriptor reads the licensed name rather than restating it")
  func s1MiniNameIsTheLicensedOne() {
    #expect(LocalEngineDescriptor.s1Mini.name == LLMProvider.s1Mini.displayName)
    #expect(LocalEngineDescriptor.s1Mini.name == "S1-mini")
    #expect(!LocalEngineDescriptor.s1Mini.name.contains("SuperWhisper"))
  }

  /// The card asks the engine for its name, so a mismatched pairing shows the
  /// other model's identity on this model's row. This is the row that would
  /// have caught "Download EG-1" appearing on the S1-mini pane.
  @Test("the download button names the engine it belongs to")
  func downloadButtonNamesItsOwnEngine() {
    let s1 = EGOneRowPresentation.forState(
      .notInstalled, engine: LocalEngineDescriptor.s1Mini.name)
    let eg1 = EGOneRowPresentation.forState(
      .notInstalled, engine: LocalEngineDescriptor.egOne.name)
    #expect(s1.primaryAction == "Download S1-mini")
    #expect(eg1.primaryAction == "Download EG-1")
    #expect(s1.primaryAction != eg1.primaryAction, "one engine's row is naming the other")
  }

  /// The 8 GB warning is EG-1's, and giving it to S1-mini would be noise that
  /// teaches users to ignore the real one. The headroom differs for the same
  /// reason: EG-1's 6 GB demand would refuse a 484 MB install that fits fine.
  @Test("what differs between the engines actually differs")
  func descriptorsDoNotShareIdentity() {
    #expect(LocalEngineDescriptor.egOne.showsLowMemoryNote)
    #expect(!LocalEngineDescriptor.s1Mini.showsLowMemoryNote)
    #expect(
      LocalEngineDescriptor.egOne.installHeadroom != LocalEngineDescriptor.s1Mini.installHeadroom)
    #expect(LocalEngineDescriptor.egOne != LocalEngineDescriptor.s1Mini)
  }

  /// The rail falls back to an "S1" monogram when a mark will not render, and
  /// that fallback is SILENT — a broken asset looks like a design choice. So
  /// the mark is asserted to actually produce an image.
  ///
  /// Founder 2026-09-04 asked for their logo specifically: *"It's an open
  /// source model that they're providing. Not showing their logo would be doing
  /// them a disservice."* A silent fallback would quietly undo that.
  @Test("Superwhisper's mark renders, rather than silently falling back")
  func superwhisperMarkRenders() throws {
    let image = try #require(
      ProviderLogoSVG.templateImage(ProviderLogoSVG.superwhisper),
      "their logo did not parse; the rail would show an S1 monogram instead")
    #expect(image.isValid)
    #expect(image.size.width > 0 && image.size.height > 0)
    // Their published artwork is 828x755, so a square result means something
    // re-authored it. Two-way: a control that cannot fail proves nothing.
    #expect(image.size.width != image.size.height, "the mark is not their artwork")
  }

  /// The even-odd fill is what makes the centre hollow. Losing it renders a
  /// solid triangle, which is a different logo and still parses fine — so it
  /// cannot be caught by "does it render".
  @Test("their mark is carried verbatim, not re-drawn")
  func superwhisperMarkIsVerbatim() {
    let svg = ProviderLogoSVG.superwhisper
    #expect(svg.contains("fill-rule=\"evenodd\""), "the hollow centre comes from the fill rule")
    #expect(svg.contains("viewBox=\"0 0 828 755\""), "their own artboard, not ours")
    #expect(!svg.contains("viewBox=\"0 0 24 24\""), "this must not go through our wrap helper")
  }
}
