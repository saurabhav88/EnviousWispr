import AppKit
import Foundation
import SwiftParser
import SwiftSyntax
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Keeps `DESIGN.md` (the one hand-edited token source, #4506) and the generated Swift token
/// file in agreement.
///
/// Two independent readings, neither of which runs or shares logic with
/// `scripts/design/generate-tokens.py`:
/// 1. Source declarations. Foundation reads the expected values from DESIGN.md's
///    ` ```json design-tokens` block; SwiftParser reads every declaration in
///    `DesignTokens.generated.swift` and checks identity, access, type, initializer, argument
///    labels, component order and literal values. Duplicate, missing, extra and unsupported
///    declarations fail.
/// 2. Compiled values. Every compiled color is resolved under the light and the dark
///    appearance, every compiled font is compared with the font DESIGN.md describes, and every
///    layout constant is read.
///
/// This is not pixel proof; the render harness owns that.
@Suite(.tags(.driftGuard))
struct DesignTokensSyncTests {

  // MARK: - Expected values (Foundation, from DESIGN.md)

  struct Book {
    var colors: [String: (light: [Double], dark: [Double])] = [:]
    var fonts: [String: (size: Double, weight: String?, design: String?)] = [:]
    var layout: [String: Double] = [:]
    var motion: [String: (curve: String, points: [Double]?, duration: Double)] = [:]
  }

  static let bookURL = RepoRoot.url.appending(path: "DESIGN.md")
  static let generatedURL = RepoRoot.url.appending(
    path: "Sources/EnviousWisprAppKit/Views/Design/DesignTokens.generated.swift")

  static func readBook() throws -> Book {
    let text = try String(contentsOf: bookURL, encoding: .utf8)
    let opener = "```json design-tokens\n"
    let pieces = text.components(separatedBy: opener)
    try #require(pieces.count == 2, "DESIGN.md must hold exactly one ```json design-tokens block")
    let body = try #require(
      pieces[1].components(separatedBy: "\n```").first, "the values block is not closed")
    let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
    let root = try #require(object as? [String: Any], "the values block is not a JSON object")
    #expect(
      Set(root.keys) == ["reasons", "colors", "fonts", "layout", "motion"],
      "unexpected token families")

    var book = Book()
    let colors = try #require(root["colors"] as? [String: [String: Any]])
    for (key, entry) in colors {
      let light = try #require(entry["light"] as? [NSNumber], "\(key) has no light value")
      let dark = try #require(entry["dark"] as? [NSNumber], "\(key) has no dark value")
      #expect(
        light.count == 4 && dark.count == 4, "\(key) must be [r, g, b, a] in both appearances")
      book.colors[key] = (light.map(\.doubleValue), dark.map(\.doubleValue))
    }
    let fonts = try #require(root["fonts"] as? [String: [String: Any]])
    for (key, entry) in fonts {
      let size = try #require(entry["size"] as? NSNumber, "\(key) has no size")
      book.fonts[key] = (size.doubleValue, entry["weight"] as? String, entry["design"] as? String)
    }
    let layout = try #require(root["layout"] as? [String: [String: Any]])
    for (key, entry) in layout {
      let value = try #require(entry["value"] as? NSNumber, "\(key) has no value")
      book.layout[key] = value.doubleValue
    }
    let motion = try #require(root["motion"] as? [String: [String: Any]])
    for (key, entry) in motion {
      let curve = try #require(entry["curve"] as? String, "\(key) has no curve")
      let duration = try #require(entry["duration"] as? NSNumber, "\(key) has no duration")
      let points = (entry["points"] as? [NSNumber])?.map(\.doubleValue)
      book.motion[key] = (curve, points, duration.doubleValue)
    }
    #expect(
      !book.colors.isEmpty && !book.fonts.isEmpty && !book.layout.isEmpty && !book.motion.isEmpty)
    return book
  }

  // MARK: - Actual declarations (SwiftParser, from the generated file)

  enum Declared: Equatable {
    case color(light: [Double], dark: [Double])
    case font(size: Double, weight: String?, design: String?)
    case layout(Double)
    case motion(curve: String, points: [Double]?, duration: Double)
  }

  static func literal(_ expression: ExprSyntax) -> Double? {
    if let float = expression.as(FloatLiteralExprSyntax.self) {
      return Double(float.literal.text)
    }
    if let integer = expression.as(IntegerLiteralExprSyntax.self) {
      return Double(integer.literal.text)
    }
    return nil
  }

  static func tuple(_ expression: ExprSyntax, _ where_: String) throws -> [Double] {
    let tuple = try #require(expression.as(TupleExprSyntax.self), "\(where_) is not a tuple")
    #expect(tuple.elements.allSatisfy { $0.label == nil }, "\(where_) has labelled components")
    return try tuple.elements.map {
      try #require(literal($0.expression), "\(where_) has a non-literal component")
    }
  }

  static func memberName(_ expression: ExprSyntax, _ where_: String) throws -> String {
    let member = try #require(
      expression.as(MemberAccessExprSyntax.self), "\(where_) is not a .member value")
    #expect(member.base == nil, "\(where_) must be an implicit member")
    return member.declName.baseName.text
  }

  /// Every declaration in the generated file, keyed `Namespace.member`. Throws on anything the
  /// generator never writes.
  static func readGenerated() throws -> [String: Declared] {
    let source = try String(contentsOf: generatedURL, encoding: .utf8)
    #expect(
      source.hasPrefix(
        "// GENERATED from DESIGN.md by scripts/design/generate-tokens.py. Do not edit."),
      "the generated file lost its header")
    let tree = Parser.parse(source: source)
    var declared: [String: Declared] = [:]

    for item in tree.statements {
      if item.item.is(ImportDeclSyntax.self) { continue }
      let namespace: String
      let members: MemberBlockItemListSyntax
      let isExtension: Bool
      if let ext = item.item.as(ExtensionDeclSyntax.self) {
        namespace = ext.extendedType.trimmedDescription
        members = ext.memberBlock.members
        isExtension = true
        #expect(ext.modifiers.isEmpty, "extension \(namespace) must keep internal access")
      } else if let enumDecl = item.item.as(EnumDeclSyntax.self) {
        namespace = enumDecl.name.text
        members = enumDecl.memberBlock.members
        isExtension = false
        #expect(enumDecl.modifiers.isEmpty, "\(namespace) must keep internal access")
      } else {
        Issue.record(
          "unsupported top-level declaration: \(item.item.trimmedDescription.prefix(60))")
        continue
      }

      for member in members {
        let variable = try #require(
          member.decl.as(VariableDeclSyntax.self),
          "\(namespace) holds a non-constant member: \(member.decl.trimmedDescription.prefix(60))")
        #expect(
          variable.modifiers.map(\.name.text) == ["static"],
          "\(namespace) members must be internal static")
        #expect(variable.bindingSpecifier.text == "let")
        let binding = try #require(variable.bindings.first)
        #expect(variable.bindings.count == 1)
        let name = try #require(binding.pattern.as(IdentifierPatternSyntax.self)).identifier.text
        let key = "\(namespace).\(name)"
        #expect(declared[key] == nil, "\(key) is declared twice")
        let value = try #require(binding.initializer?.value, "\(key) has no value")

        switch (namespace, isExtension) {
        case ("Color", true):
          #expect(binding.typeAnnotation == nil)
          let call = try #require(value.as(FunctionCallExprSyntax.self), "\(key) is not a call")
          #expect(
            call.calledExpression.trimmedDescription == "stDynamic", "\(key) must use stDynamic")
          #expect(
            call.arguments.map { $0.label?.text } == ["lightRGB", "darkRGB"], "\(key) labels")
          let arguments = Array(call.arguments)
          try #require(arguments.count == 2)
          declared[key] = .color(
            light: try tuple(arguments[0].expression, "\(key).light"),
            dark: try tuple(arguments[1].expression, "\(key).dark"))
        case ("Font", true):
          let call = try #require(value.as(FunctionCallExprSyntax.self), "\(key) is not a call")
          #expect(
            call.calledExpression.trimmedDescription == "Font.system", "\(key) must use Font.system"
          )
          var size: Double?
          var weight: String?
          var design: String?
          let labels = call.arguments.map { $0.label?.text ?? "" }
          #expect(
            ["size", "weight", "design"].starts(with: labels), "\(key) argument order \(labels)")
          for argument in call.arguments {
            switch argument.label?.text {
            case "size": size = literal(argument.expression)
            case "weight": weight = try memberName(argument.expression, "\(key).weight")
            case "design": design = try memberName(argument.expression, "\(key).design")
            default: Issue.record("\(key) has an unsupported argument")
            }
          }
          declared[key] = .font(
            size: try #require(size, "\(key) size is not a literal"), weight: weight, design: design
          )
        case ("DesignMotion", false):
          #expect(binding.typeAnnotation == nil)
          let call = try #require(value.as(FunctionCallExprSyntax.self), "\(key) is not a call")
          let callee = try #require(
            call.calledExpression.as(MemberAccessExprSyntax.self), "\(key) must be Animation.curve")
          #expect(callee.base?.trimmedDescription == "Animation", "\(key) must use Animation")
          let curve = callee.declName.baseName.text
          let labels = call.arguments.map { $0.label?.text }
          let points: [Double]?
          if curve == "timingCurve" {
            #expect(labels == [nil, nil, nil, nil, "duration"], "\(key) labels")
            points = try call.arguments.dropLast().map {
              try #require(literal($0.expression), "\(key) has a non-literal point")
            }
          } else {
            #expect(labels == ["duration"], "\(key) labels")
            points = nil
          }
          let duration = try #require(
            call.arguments.last.flatMap { literal($0.expression) }, "\(key) duration")
          declared[key] = .motion(curve: curve, points: points, duration: duration)
        case (_, false):
          #expect(
            binding.typeAnnotation?.type.trimmedDescription == "CGFloat", "\(key) must be CGFloat")
          declared[key] = .layout(try #require(literal(value), "\(key) is not a literal"))
        default:
          Issue.record("unsupported extension namespace \(namespace)")
        }
      }
    }
    return declared
  }

  @Test("every DESIGN.md token is declared once in the generated file, with the same values")
  func declarationsMatchTheBook() throws {
    let book = try Self.readBook()
    let declared = try Self.readGenerated()

    var expected: [String: Declared] = [:]
    for (key, value) in book.colors { expected[key] = .color(light: value.light, dark: value.dark) }
    for (key, value) in book.fonts {
      expected[key] = .font(size: value.size, weight: value.weight, design: value.design)
    }
    for (key, value) in book.layout { expected[key] = .layout(value) }
    for (key, value) in book.motion {
      expected[key] = .motion(curve: value.curve, points: value.points, duration: value.duration)
    }

    #expect(
      Set(declared.keys).subtracting(expected.keys).isEmpty,
      "declared but not in DESIGN.md: \(Set(declared.keys).subtracting(expected.keys).sorted())")
    #expect(
      Set(expected.keys).subtracting(declared.keys).isEmpty,
      "in DESIGN.md but not declared: \(Set(expected.keys).subtracting(declared.keys).sorted())")
    for (key, value) in expected where declared[key] != nil {
      #expect(
        declared[key] == value,
        "\(key): generated \(String(describing: declared[key])) vs book \(value)")
    }
    #expect(declared.count >= 50, "suspiciously few tokens: \(declared.count)")
  }

  // MARK: - Compiled values

  /// The compiled tokens, listed by hand so the compiler, not a name string, binds each one.
  /// `compiledTablesCoverTheBook` fails when this list and DESIGN.md disagree.
  static let compiledColors: [String: Color] = [
    "Color.stPageBg": .stPageBg, "Color.stSectionBg": .stSectionBg,
    "Color.stSidebarBg": .stSidebarBg, "Color.stWindowBg": .stWindowBg,
    "Color.stTextPrimary": .stTextPrimary, "Color.stTextSecondary": .stTextSecondary,
    "Color.stTextTertiary": .stTextTertiary, "Color.stTextBody": .stTextBody,
    "Color.stAccent": .stAccent, "Color.stAccentLight": .stAccentLight,
    "Color.stAccentSolid": .stAccentSolid, "Color.stToggleOn": .stToggleOn,
    "Color.stToggleOff": .stToggleOff, "Color.stSuccess": .stSuccess,
    "Color.stWarning": .stWarning, "Color.stWarningSoft": .stWarningSoft,
    "Color.stError": .stError, "Color.stInputBg": .stInputBg,
    "Color.stInputBorder": .stInputBorder, "Color.stDivider": .stDivider,
    "Color.obSurface": .obSurface, "Color.obCardBg": .obCardBg,
    "Color.obTextPrimary": .obTextPrimary, "Color.obTextSecondary": .obTextSecondary,
    "Color.obTextTertiary": .obTextTertiary, "Color.obButtonFill": .obButtonFill,
    "Color.obKeycapTop": .obKeycapTop, "Color.obAccent": .obAccent,
    "Color.obAccentSoft": .obAccentSoft, "Color.obSuccess": .obSuccess,
    "Color.obSuccessSoft": .obSuccessSoft, "Color.obSuccessText": .obSuccessText,
    "Color.obWarning": .obWarning, "Color.obError": .obError,
    "Color.obErrorSoft": .obErrorSoft, "Color.obBorder": .obBorder,
    "Color.firstRunTextTertiary": .firstRunTextTertiary, "Color.firstRunSuccessText": .firstRunSuccessText,
    "Color.firstRunErrorText": .firstRunErrorText, "Color.firstRunButtonHover": .firstRunButtonHover,
    "Color.firstRunButtonDisabled": .firstRunButtonDisabled,
    "Color.firstRunButtonDisabledText": .firstRunButtonDisabledText,
    "Color.firstRunOnAccent": .firstRunOnAccent, "Color.firstRunAccentSoft": .firstRunAccentSoft, "Color.firstRunRule": .firstRunRule,
    "Color.firstRunFilmWallTop": .firstRunFilmWallTop,
    "Color.firstRunFilmWallMid": .firstRunFilmWallMid,
    "Color.firstRunFilmWallBottom": .firstRunFilmWallBottom,
    "Color.firstRunFilmMenuBar": .firstRunFilmMenuBar,
    "Color.firstRunFilmMenuInk": .firstRunFilmMenuInk,
    "Color.firstRunFilmDock": .firstRunFilmDock,
    "Color.firstRunFilmLightRed": .firstRunFilmLightRed,
    "Color.firstRunFilmLightYellow": .firstRunFilmLightYellow,
    "Color.firstRunFilmLightGreen": .firstRunFilmLightGreen,
    "Color.firstRunFilmSlack": .firstRunFilmSlack,
    "Color.firstRunFilmMistakeWash": .firstRunFilmMistakeWash,
    "Color.firstRunFilmMistakeText": .firstRunFilmMistakeText,
    "Color.firstRunFilmMistakeStrike": .firstRunFilmMistakeStrike,
  ]

  static let compiledFonts: [String: Font] = [
    "Font.stSectionHeader": .stSectionHeader, "Font.stRowTitle": .stRowTitle,
    "Font.stRowLabel": .stRowLabel, "Font.stBody": .stBody, "Font.stHelper": .stHelper,
    "Font.stRowHelper": .stRowHelper, "Font.obDisplay": .obDisplay,
    "Font.obSubheading": .obSubheading, "Font.obBody": .obBody, "Font.obCaption": .obCaption,
    "Font.obCaptionSmall": .obCaptionSmall, "Font.obLabel": .obLabel,
    "Font.firstRunHero": .firstRunHero, "Font.firstRunDisplay": .firstRunDisplay,
    "Font.firstRunTitle": .firstRunTitle, "Font.firstRunSay": .firstRunSay, "Font.firstRunBody": .firstRunBody,
    "Font.firstRunLabel": .firstRunLabel, "Font.firstRunCaption": .firstRunCaption,
    "Font.firstRunEyebrow": .firstRunEyebrow,
  ]

  static let compiledLayout: [String: CGFloat] = [
    "SettingsLayout.sectionRadius": SettingsLayout.sectionRadius,
    "SettingsLayout.rowPaddingH": SettingsLayout.rowPaddingH,
    "SettingsLayout.rowPaddingV": SettingsLayout.rowPaddingV,
    "SettingsLayout.sectionSpacing": SettingsLayout.sectionSpacing,
    "SettingsLayout.contentTop": SettingsLayout.contentTop,
    "SettingsLayout.contentH": SettingsLayout.contentH,
    "SettingsLayout.contentBottom": SettingsLayout.contentBottom,
    "SettingsLayout.windowCardRadius": SettingsLayout.windowCardRadius,
    "SettingsLayout.windowFrameInset": SettingsLayout.windowFrameInset,
    "SettingsPR1Layout.rowPaddingV": SettingsPR1Layout.rowPaddingV,
    "SettingsPR1Layout.headingGap": SettingsPR1Layout.headingGap,
    "DesignRadius.xs": DesignRadius.xs, "DesignRadius.sm": DesignRadius.sm,
    "DesignRadius.md": DesignRadius.md, "DesignRadius.lg": DesignRadius.lg,
    "DesignRadius.xl": DesignRadius.xl, "DesignRadius.xxl": DesignRadius.xxl,
    "DesignSpacing.xxs": DesignSpacing.xxs, "DesignSpacing.xs": DesignSpacing.xs,
    "DesignSpacing.sm": DesignSpacing.sm, "DesignSpacing.md": DesignSpacing.md,
    "DesignSpacing.lg": DesignSpacing.lg, "DesignSpacing.xl": DesignSpacing.xl,
    "DesignSpacing.xxl": DesignSpacing.xxl, "DesignSpacing.xxxl": DesignSpacing.xxxl,
  ]

  static let compiledMotion: [String: Animation] = [
    "DesignMotion.quick": DesignMotion.quick, "DesignMotion.brisk": DesignMotion.brisk,
    "DesignMotion.standard": DesignMotion.standard, "DesignMotion.gentle": DesignMotion.gentle,
    "DesignMotion.firstRunScreenIn": DesignMotion.firstRunScreenIn,
    "DesignMotion.firstRunRise": DesignMotion.firstRunRise,
  ]

  @Test("the compiled-token tables name exactly the DESIGN.md tokens")
  func compiledTablesCoverTheBook() throws {
    let book = try Self.readBook()
    #expect(Set(Self.compiledColors.keys) == Set(book.colors.keys))
    #expect(Set(Self.compiledFonts.keys) == Set(book.fonts.keys))
    #expect(Set(Self.compiledLayout.keys) == Set(book.layout.keys))
    #expect(Set(Self.compiledMotion.keys) == Set(book.motion.keys))
  }

  static func resolved(_ color: Color, dark: Bool) throws -> [Double] {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let platform = NSColor(color)
    var components: [Double] = []
    appearance.performAsCurrentDrawingAppearance {
      if let srgb = platform.usingColorSpace(.sRGB) {
        components = [
          srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent,
        ]
        .map(Double.init)
      }
    }
    try #require(components.count == 4, "the color did not resolve to sRGB")
    return components
  }

  @Test("every compiled color resolves to the DESIGN.md value in light and in dark")
  func compiledColorsMatchTheBook() throws {
    let book = try Self.readBook()
    var checked = 0
    for (key, expected) in book.colors {
      let color = try #require(
        Self.compiledColors[key], "\(key) is missing from the compiled table")
      for (dark, values) in [(false, expected.light), (true, expected.dark)] {
        let actual = try Self.resolved(color, dark: dark)
        for (a, e) in zip(actual, values) {
          #expect(abs(a - e) < 1e-6, "\(key) \(dark ? "dark" : "light"): \(actual) vs \(values)")
        }
        checked += 1
      }
    }
    #expect(checked == book.colors.count * 2 && checked > 0)
  }

  static func weight(_ name: String?) throws -> Font.Weight? {
    switch name {
    case nil: return nil
    case "ultraLight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: throw DesignBookError.unknown("weight \(name ?? "")")
    }
  }

  static func design(_ name: String?) throws -> Font.Design? {
    switch name {
    case nil: return nil
    case "default": return .default
    case "rounded": return .rounded
    case "serif": return .serif
    case "monospaced": return .monospaced
    default: throw DesignBookError.unknown("design \(name ?? "")")
    }
  }

  enum DesignBookError: Error { case unknown(String) }

  @Test("every compiled font equals the font DESIGN.md describes")
  func compiledFontsMatchTheBook() throws {
    let book = try Self.readBook()
    for (key, expected) in book.fonts {
      let compiled = try #require(
        Self.compiledFonts[key], "\(key) is missing from the compiled table")
      let size = CGFloat(expected.size)
      let described: Font =
        switch (try Self.weight(expected.weight), try Self.design(expected.design)) {
        case (nil, nil): .system(size: size)
        case (let weight?, nil): .system(size: size, weight: weight)
        case (let weight?, let design?): .system(size: size, weight: weight, design: design)
        case (nil, .some): throw DesignBookError.unknown("\(key): a design needs a weight")
        }
      #expect(compiled == described, "\(key) differs from DESIGN.md")
    }
  }

  @Test("every compiled layout constant equals DESIGN.md")
  func compiledLayoutMatchesTheBook() throws {
    let book = try Self.readBook()
    for (key, expected) in book.layout {
      let compiled = try #require(
        Self.compiledLayout[key], "\(key) is missing from the compiled table")
      #expect(Double(compiled) == expected, "\(key): \(compiled) vs \(expected)")
    }
  }

  @Test("every compiled motion token equals the curve and duration in DESIGN.md")
  func compiledMotionMatchesTheBook() throws {
    let book = try Self.readBook()
    for (key, expected) in book.motion {
      let compiled = try #require(
        Self.compiledMotion[key], "\(key) is missing from the compiled table")
      let described: Animation =
        switch expected.curve {
        case "easeIn": .easeIn(duration: expected.duration)
        case "easeOut": .easeOut(duration: expected.duration)
        case "easeInOut": .easeInOut(duration: expected.duration)
        case "linear": .linear(duration: expected.duration)
        case "timingCurve":
          try {
            let p = try #require(expected.points, "\(key) has no points")
            try #require(p.count == 4, "\(key) needs four points")
            return .timingCurve(p[0], p[1], p[2], p[3], duration: expected.duration)
          }()
        default: throw DesignBookError.unknown("\(key): curve \(expected.curve)")
        }
      #expect(compiled == described, "\(key) differs from DESIGN.md")
    }
  }
}
