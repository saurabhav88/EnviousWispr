import Foundation
import Testing

/// Keeps the screen atlas (`design/atlas/`, #4506) true to the design book and complete.
///
/// - The generated block of `atlas.css` carries every DESIGN.md token with the same values: both
///   color appearances, font size, weight and family, layout points and motion curve and
///   duration. Expected values come from `DesignTokensSyncTests.readBook()` (Foundation over
///   DESIGN.md), never from the generator, so a generator defect cannot hide itself.
/// - The hand-written part classes use only the atlas variables: no raw color.
/// - Every picture `atlas.json` lists exists in both appearances and has an inventory section;
///   every harness picture names captures the render manifest declares.
/// - `index.html` is what `scripts/design/build-atlas-index.py` builds from the current files.
///
/// Stale pictures are allowed (founder 2026-11-12): nothing here compares a picture with the app.
@MainActor
@Suite(.tags(.driftGuard))
struct DesignAtlasSyncTests {

  static let atlasURL = RepoRoot.url.appending(path: "design/atlas")
  static let beginMarker = "/* GENERATED from DESIGN.md"
  static let endMarker = "/* END GENERATED."
  static let partClassesMarker = "/* PART CLASSES."

  /// `--ew-x: value;` pairs of one CSS block body.
  static func declarations(_ block: Substring) -> [String: String] {
    var found: [String: String] = [:]
    for line in block.split(separator: "\n") {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("--ew-"), let colon = text.firstIndex(of: ":"), text.hasSuffix(";")
      else { continue }
      let name = String(text[..<colon])
      let value = text[text.index(after: colon)...].dropLast().trimmingCharacters(in: .whitespaces)
      #expect(found[name] == nil, "\(name) is declared twice in one block")
      found[name] = value
    }
    return found
  }

  /// The three generated blocks: light (`:root`), system dark (inside the media query) and the
  /// explicit dark choice.
  static func generatedBlocks() throws -> (
    light: [String: String], systemDark: [String: String], dark: [String: String], css: String
  ) {
    let css = try String(contentsOf: atlasURL.appending(path: "atlas.css"), encoding: .utf8)
    let begin = try #require(css.range(of: beginMarker), "atlas.css has no generated block")
    let end = try #require(css.range(of: endMarker), "atlas.css generated block is not closed")
    let generated = css[begin.lowerBound..<end.lowerBound]
    func block(after opener: String) throws -> Substring {
      let start = try #require(generated.range(of: opener), "atlas.css has no \(opener) block")
      let rest = generated[start.upperBound...]
      let close = try #require(rest.range(of: "\n}"), "\(opener) block is not closed")
      return rest[..<close.lowerBound]
    }
    // The system-dark values must sit inside the dark media query, guarded by "no light
    // choice"; the declarations alone cannot show which condition encloses them.
    try #require(
      generated.contains(
        "@media (prefers-color-scheme: dark) {\n  :root:not([data-theme=\"light\"]) {"),
      "atlas.css: the system-dark block is not inside @media (prefers-color-scheme: dark)")
    return (
      declarations(try block(after: ":root, :root[data-theme=\"light\"] {")),
      declarations(try block(after: ":root:not([data-theme=\"light\"]) {")),
      declarations(try block(after: "\n:root[data-theme=\"dark\"] {")),
      css
    )
  }

  /// `Namespace.member` -> the CSS name: kebab-case, Color and Font namespaces dropped.
  static func cssName(_ key: String) -> String {
    let parts = key.split(separator: ".").map(String.init)
    func kebab(_ name: String) -> String {
      var out = ""
      let chars = Array(name)
      for (index, char) in chars.enumerated() {
        if char.isUppercase, index > 0 {
          let previous = chars[index - 1]
          let next = index + 1 < chars.count ? chars[index + 1] : nil
          if previous.isLowercase || previous.isNumber
            || (previous.isUppercase && next.map { $0.isLowercase } == true)
          {
            out.append("-")
          }
        }
        out.append(contentsOf: char.lowercased())
      }
      return out
    }
    if ["Color", "Font"].contains(parts[0]) { return kebab(parts[1]) }
    return kebab(parts[0]) + "-" + kebab(parts[1])
  }

  /// `rgb(97.3% 96.1% 100% / 100%)` -> [0.973, 0.961, 1, 1].
  static func components(_ value: String) -> [Double]? {
    guard value.hasPrefix("rgb("), value.hasSuffix(")") else { return nil }
    let inner = value.dropFirst(4).dropLast().replacingOccurrences(of: "/", with: " ")
    let numbers = inner.split(separator: " ").compactMap { piece -> Double? in
      guard piece.hasSuffix("%") else { return nil }
      return Double(piece.dropLast()).map { $0 / 100 }
    }
    return numbers.count == 4 ? numbers : nil
  }

  @Test("atlas.css carries every DESIGN.md token, with the same values, and nothing else")
  func generatedBlockMatchesTheBook() throws {
    let book = try DesignTokensSyncTests.readBook()
    let blocks = try Self.generatedBlocks()
    var expectedLight: Set<String> = []
    var expectedDark: Set<String> = []

    for (key, color) in book.colors {
      let name = "--ew-" + Self.cssName(key)
      expectedLight.insert(name)
      expectedDark.insert(name)
      for (label, values, wanted) in [
        ("light", blocks.light, color.light), ("system dark", blocks.systemDark, color.dark),
        ("explicit dark", blocks.dark, color.dark),
      ] {
        let got = try #require(
          values[name].flatMap(Self.components), "\(key): \(name) missing or unreadable in \(label)"
        )
        #expect(
          zip(got, wanted).allSatisfy { abs($0 - $1) < 1e-9 },
          "\(key) \(label): atlas.css has \(got), DESIGN.md has \(wanted)")
      }
    }

    let weights: [String: String] = [
      "ultraLight": "100", "thin": "200", "light": "300", "regular": "400", "medium": "500",
      "semibold": "600", "bold": "700", "heavy": "800", "black": "900",
    ]
    let familyLead: [String: String] = [
      "default": "-apple-system", "rounded": "ui-rounded", "serif": "ui-serif",
      "monospaced": "ui-monospace",
    ]
    for (key, font) in book.fonts {
      let name = "--ew-font-" + Self.cssName(key)
      expectedLight.formUnion([name + "-size", name + "-weight", name + "-family"])
      #expect(Self.number(blocks.light[name + "-size"], unit: "px") == font.size, "\(key): size")
      #expect(blocks.light[name + "-weight"] == weights[font.weight ?? "regular"], "\(key): weight")
      let lead = try #require(familyLead[font.design ?? "default"], "\(key): unknown design")
      #expect(
        blocks.light[name + "-family"]?.hasPrefix(lead) == true,
        "\(key): family should lead with \(lead)")
    }
    for (key, value) in book.layout {
      let name = "--ew-" + Self.cssName(key)
      expectedLight.insert(name)
      #expect(Self.number(blocks.light[name], unit: "px") == value, "\(key): \(name)")
    }
    let curves = [
      "easeIn": "ease-in", "easeOut": "ease-out", "easeInOut": "ease-in-out", "linear": "linear",
    ]
    for (key, motion) in book.motion {
      let member = String(key.split(separator: ".")[1])
      let name = "--ew-motion-" + Self.cssName("Color." + member)
      expectedLight.formUnion([name + "-duration", name + "-curve"])
      #expect(
        Self.number(blocks.light[name + "-duration"], unit: "s") == motion.duration, "\(key): duration")
      #expect(blocks.light[name + "-curve"] == curves[motion.curve], "\(key): curve")
    }

    #expect(Set(blocks.light.keys) == expectedLight, "light block names differ from DESIGN.md")
    #expect(Set(blocks.systemDark.keys) == expectedDark, "system-dark block names differ")
    #expect(Set(blocks.dark.keys) == expectedDark, "explicit-dark block names differ")
  }

  /// `14px` -> 14, `0.15s` -> 0.15; nil when the unit differs or the number does not parse, so
  /// `14` and `14.0` in DESIGN.md compare equal whatever spelling the generator writes.
  static func number(_ value: String?, unit: String) -> Double? {
    guard let value, value.hasSuffix(unit) else { return nil }
    return Double(value.dropLast(unit.count))
  }

  @Test("the hand-written part classes use only atlas variables, never a raw color")
  func partClassesHaveNoRawColor() throws {
    let css = try Self.generatedBlocks().css
    let start = try #require(css.range(of: Self.partClassesMarker), "atlas.css has no part classes")
    let classes = css[start.upperBound...]
    let raw = try Regex(#"#[0-9a-fA-F]{3,8}\b|\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(\s*[0-9.]"#)
      .ignoresCase()
    let hits = classes.matches(of: raw).map { String(classes[$0.range]) }
    #expect(hits.isEmpty, "raw colors in atlas.css part classes: \(hits)")
  }

  struct Atlas: Decodable {
    struct Picture: Decodable {
      let id: String
      let kind: String
      let source: Source?
      /// Hand photos only: the appearances that exist when not both (the menu bar menu follows
      /// the macOS appearance, which a session cannot change).
      let appearances: [String]?
    }
    struct Source: Decodable {
      let page: String?
      let manifest: String?
    }
    let pictures: [Picture]
  }

  @Test("every atlas picture exists in light and dark, has an inventory entry and a real source")
  func picturesAreComplete() throws {
    let atlas = try JSONDecoder().decode(
      Atlas.self, from: Data(contentsOf: Self.atlasURL.appending(path: "atlas.json")))
    #expect(!atlas.pictures.isEmpty, "atlas.json lists no pictures")
    #expect(Set(atlas.pictures.map(\.id)).count == atlas.pictures.count, "a picture id repeats")
    let inventory = try String(
      contentsOf: Self.atlasURL.appending(path: "inventory.md"), encoding: .utf8)
    let sections = Set(
      inventory.split(separator: "\n").filter { $0.hasPrefix("## ") }.map {
        String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      })
    let manifest = try JSONDecoder().decode(
      DesignRenderHarness.Manifest.self, from: Data(contentsOf: DesignRenderHarness.manifestURL))
    let names = Set(manifest.entries.map(\.name))
    let files = Set(
      try FileManager.default.contentsOfDirectory(
        atPath: Self.atlasURL.appending(path: "pictures").path))

    for picture in atlas.pictures {
      #expect(["harness", "hand"].contains(picture.kind), "\(picture.id): unknown kind")
      #expect(sections.contains(picture.id), "inventory.md has no '## \(picture.id)' section")
      let appearances = picture.appearances ?? ["light", "dark"]
      #expect(
        picture.kind == "hand" || picture.appearances == nil,
        "\(picture.id): only a hand photo may skip an appearance")
      #expect(!appearances.isEmpty, "\(picture.id): no appearances")
      for appearance in appearances {
        #expect(
          files.contains("\(picture.id)-\(appearance).png"),
          "pictures/ has no \(appearance) picture of \(picture.id)")
      }
      guard picture.kind == "harness" else { continue }
      let source = try #require(picture.source, "\(picture.id): a harness picture needs a source")
      if let manifestName = source.manifest {
        #expect(
          names.contains("\(manifestName)-light") && names.contains("\(manifestName)-dark"),
          "\(picture.id): the render manifest has no \(manifestName) captures")
      } else if let page = source.page {
        #expect(
          manifest.entries.contains {
            $0.fixture == "page:\(page)" && $0.window == DesignAtlasRender.window
          },
          "\(picture.id): the render manifest has no \(page) page at the atlas width")
      } else {
        Issue.record("\(picture.id): a harness source names neither a page nor a manifest capture")
      }
    }
  }

  @Test("index.html is what build-atlas-index.py builds from the current atlas files")
  func indexIsCurrent() {
    let result = DesignRenderHarness.run(
      "/usr/bin/python3",
      [RepoRoot.url.appending(path: "scripts/design/build-atlas-index.py").path, "--check"])
    #expect(result.status == 0, "\(result.output)")
  }
}
