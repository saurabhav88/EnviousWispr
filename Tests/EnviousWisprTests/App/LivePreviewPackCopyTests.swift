import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2080 — does the missing-pack sentence actually FIT the pill, in every language.
///
/// The plan required this as a MEASUREMENT rather than an estimate. A review round proposed
/// simply widening the pill's unavailable state from two lines to three; that would have changed
/// founder-tuned geometry on a guess. Measuring instead means the cap changes only if something
/// truly does not fit — and it means checking all 54 languages rather than "the longest name",
/// because character count is the wrong unit when scripts render at different widths.
@MainActor
struct LivePreviewPackCopyTests {

  /// The pill's real numbers, read from `RecordingOverlayPanel`: 400 pt wide with 14 pt of
  /// horizontal padding each side, text at system 12.
  private static let availableWidth: CGFloat = 400 - (14 * 2)
  private static let font = NSFont.systemFont(ofSize: 12)

  /// Lines the message wraps to at the pill's width, by real text layout rather than arithmetic
  /// on character counts.
  private static func renderedLines(_ message: String) -> Int {
    let attributed = NSAttributedString(string: message, attributes: [.font: font])
    let bounding = attributed.boundingRect(
      with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    return Int(ceil(bounding.height / lineHeight))
  }

  /// Every language Apple can transcribe, by its localized name — the exact strings the pill will
  /// interpolate. Taken from the measured 54-locale set rather than invented.
  private static let allLanguageNames: [String] = {
    let tags = [
      "ar-SA", "ca-ES", "cs-CZ", "da-DK", "de-AT", "de-CH", "de-DE", "el-GR", "en-AU", "en-CA",
      "en-GB", "en-IE", "en-IN", "en-NZ", "en-SG", "en-US", "en-ZA", "es-CL", "es-ES", "es-MX",
      "es-US", "fi-FI", "fr-BE", "fr-CA", "fr-CH", "fr-FR", "he-IL", "hi-IN", "hr-HR", "hu-HU",
      "id-ID", "it-CH", "it-IT", "ja-JP", "ko-KR", "ms-MY", "nb-NO", "nl-BE", "nl-NL", "pl-PL",
      "pt-BR", "pt-PT", "ro-RO", "ru-RU", "sk-SK", "sv-SE", "th-TH", "tr-TR", "uk-UA", "vi-VN",
      "yue-CN", "zh-CN", "zh-HK", "zh-TW",
    ]
    return tags.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
  }()

  @Test("The missing-pack sentence fits the pill's two-line cap in all 54 languages")
  func missingPackSentenceFitsEveryLanguage() {
    #expect(Self.allLanguageNames.count == 54, "control: the measured locale set is 54")

    var overflowing: [(String, Int)] = []
    for name in Self.allLanguageNames {
      let message = LivePreviewSettingsCopy.previewNeedsLanguagePack(name)
      let lines = Self.renderedLines(message)
      if lines > 2 { overflowing.append((name, lines)) }
    }

    #expect(
      overflowing.isEmpty,
      """
      These languages overflow the pill's 2-line cap for the unavailable state. \
      Either shorten the copy or raise the cap in RecordingOverlayPanel deliberately: \
      \(overflowing.map { "\($0.0)=\($0.1) lines" }.joined(separator: ", "))
      """)
  }

  /// Two-way control. Without it the test above would pass just as happily against a broken
  /// measurement that returns 1 for everything.
  @Test("The line measurement can detect an overflowing string")
  func measurementDetectsOverflow() {
    let long = String(repeating: "Portuguese (Brazil) ", count: 12)
    #expect(
      Self.renderedLines(long) > 2,
      "the measurement must be able to report overflow, or the check above is vacuous")
    #expect(Self.renderedLines("Short.") == 1)
  }

  @Test("Pack copy carries no dashes, per the brand rule")
  func packCopyHasNoDashes() {
    let strings = [
      LivePreviewSettingsCopy.packsHeader,
      LivePreviewSettingsCopy.packsDescription,
      LivePreviewSettingsCopy.packInstalled,
      LivePreviewSettingsCopy.packInstall,
      LivePreviewSettingsCopy.packInstalling,
      LivePreviewSettingsCopy.packRetry,
      LivePreviewSettingsCopy.packsUnavailable,
      LivePreviewSettingsCopy.packInstallFailed,
      LivePreviewSettingsCopy.packsLoading,
      LivePreviewSettingsCopy.previewNeedsLanguagePack("French"),
    ]
    for s in strings {
      #expect(!s.contains("—"), "em-dash in user-facing copy: \(s)")
      #expect(!s.contains("–"), "en-dash in user-facing copy: \(s)")
    }
  }

  /// Review round 2: the page rendered "Downloading" while merely READING the language list, so
  /// every supported Mac opened it announcing a transfer that was not happening, contradicting the
  /// promise in its own description three lines above. The states are different facts and must not
  /// share a string.
  @Test("The list-loading state does not claim a download is happening")
  func loadingCopyDoesNotClaimADownload() {
    let loading = LivePreviewSettingsCopy.packsLoading
    #expect(loading != LivePreviewSettingsCopy.packInstalling)
    #expect(
      !loading.localizedCaseInsensitiveContains("download"),
      "reading the local language list is not a download: \(loading)")
    // Control: the string that DOES mean a transfer still says so, or the check above would pass
    // just as happily against copy that never mentions downloading anywhere.
    #expect(LivePreviewSettingsCopy.packInstalling.localizedCaseInsensitiveContains("download"))
  }

  /// Is `name` referenced as a WHOLE identifier, rather than merely as the opening characters
  /// of a longer sibling's name?
  ///
  /// **A substring test passes a declaration vacuously whenever a longer sibling is on screen.**
  /// Measured on PR #2169 head `7cc70be1`: a refactor left four strings referenced only from
  /// inside the copy file, and this guard reported exactly two of them —
  /// `universalLockedPaused` and `universalAutoPaused`, the two with no prefix sibling.
  /// `universalLocked` and `universalAuto` were in the identical situation and passed, because
  /// `universalLockedHelp` and `universalAutoHelp` were rendered. The guard caught the strings
  /// that had no sibling and missed the ones that did, which is the defect demonstrating itself
  /// on a live run.
  ///
  /// The trailing `(?![A-Za-z0-9_])` is what makes the match a whole identifier. Underscore is in
  /// that set even though no declaration uses one today: a Swift identifier may continue with it,
  /// so excluding it would reintroduce this bug the first time someone writes `packInstalling_v2`.
  /// The name is regex-escaped rather than interpolated raw, so a future declaration containing a
  /// metacharacter cannot silently turn this into a different pattern.
  nonisolated static func isReferenced(_ name: String, in corpus: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = "LivePreviewSettingsCopy\\.\(escaped)(?![A-Za-z0-9_])"
    return corpus.range(of: pattern, options: .regularExpression) != nil
  }

  /// Every string this page declares must actually reach a screen.
  ///
  /// **Written because one did not.** `packInstallFailed` was declared, referenced by the dash
  /// test above, and rendered nowhere — so a failed download relabelled its button to "Try again"
  /// and never explained what happened or what to do. The copy test referencing it is precisely
  /// what made it LOOK wired: existence is not function, and a test that touches a string proves
  /// only that it compiles.
  ///
  /// So this checks the whole surface rather than that one string, by reading the declarations
  /// out of the copy file and requiring each to be used from some OTHER source file.
  @Test("Every declared piece of page copy is rendered somewhere in the app")
  func everyStringIsActuallyUsed() throws {
    let settings = RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit/Views/Settings")
    let copyFile = settings.appending(path: "LivePreviewSettingsCopy.swift")
    let declarations = try String(contentsOf: copyFile, encoding: .utf8)
      .split(separator: "\n")
      .compactMap { line -> String? in
        guard let range = line.range(of: #"static (let|func) "#, options: .regularExpression)
        else { return nil }
        return String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
      }
    #expect(declarations.count > 10, "control: the copy surface was found and parsed")

    // Every source file that could render it — the page itself plus the coordinator that puts
    // the missing-pack sentence in the pill.
    let roots = ["Sources/EnviousWisprAppKit/Views/Settings", "Sources/EnviousWisprAppKit/App"]
    var corpus = ""
    for root in roots {
      let dir = RepoRoot.url.appending(path: root)
      let files =
        FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter {
          $0.pathExtension == "swift" && $0.lastPathComponent != "LivePreviewSettingsCopy.swift"
        }
        ?? []
      for file in files { corpus += (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
    #expect(
      corpus.contains("LivePreviewSettingsCopy."), "control: the corpus reached real call sites")

    let unused = declarations.filter { Self.isReferenced($0, in: corpus) == false }
    #expect(
      unused.isEmpty,
      """
      Declared but never rendered, so the user never sees it: \(unused.joined(separator: ", ")). \
      Either wire it into the page or delete it — a string that exists and is never shown reads \
      as done in review and is missing in the product.
      """)
  }

  /// Two-way control for the matcher above.
  ///
  /// **Written because a guard that stops firing is indistinguishable from one that was deleted.**
  /// The suite's existing `declarations.count > 10` control covers a parse failure and says
  /// nothing about MATCHING, so without these the tightening could be reverted — or broken by a
  /// future edit — with every test still green.
  ///
  /// Not parameterized on purpose. A named parameterized test prints
  /// `Test "..." with N test cases passed`, a shape `mutation-battery.py` cannot match, so it can
  /// never be named as a recipe's `expect_fail` and the overnight battery cannot reach it.
  @Test("A declaration referenced only as a longer sibling's prefix is not counted as used")
  func aPrefixSiblingDoesNotSatisfyADeclaration() {
    let corpus = "Text(LivePreviewSettingsCopy.universalLockedHelp)"

    #expect(
      Self.isReferenced("universalLockedHelp", in: corpus),
      "the declaration actually on screen must count as used")
    #expect(
      Self.isReferenced("universalLocked", in: corpus) == false,
      """
      `universalLocked` is referenced nowhere; only its longer sibling `universalLockedHelp` is. \
      A substring match reports it used, which is the #2172 defect.
      """)
  }

  /// The exact-reference side, in the shapes a call site really takes.
  ///
  /// A word-boundary rule that was too strict would be just as wrong as the substring rule, and
  /// would fail LOUDLY on every real declaration, so each of these is a shape the guard must keep
  /// accepting.
  @Test("An exact reference counts as used in every shape a call site takes")
  func anExactReferenceCountsAsUsed() {
    #expect(Self.isReferenced("packInstalling", in: "LivePreviewSettingsCopy.packInstalling"))
    #expect(Self.isReferenced("packInstalling", in: "Text(LivePreviewSettingsCopy.packInstalling)"))
    #expect(
      Self.isReferenced(
        "previewNeedsLanguagePack",
        in: "LivePreviewSettingsCopy.previewNeedsLanguagePack(\"French\")"),
      "a func declaration is referenced with an open paren straight after the name")
    #expect(
      Self.isReferenced("packInstalling", in: "let s = LivePreviewSettingsCopy.packInstalling\n"),
      "a reference at end of line still counts")
    #expect(
      Self.isReferenced("packInstalling", in: "LivePreviewSettingsCopy.packInstalling.count"),
      "a property accessed off the string still counts")
  }

  /// The underscore case, which the issue's proposed pattern would have missed.
  ///
  /// `(?![A-Za-z0-9])` alone treats `_` as a boundary, so `packInstalling` would be reported used
  /// by a reference to `packInstalling_v2`. No declaration uses an underscore today; this pins the
  /// wider character class so that stays safe when one does.
  @Test("An underscore continues an identifier, so a longer sibling does not satisfy the shorter")
  func underscoreDoesNotEndAnIdentifier() {
    let corpus = "Text(LivePreviewSettingsCopy.packInstalling_v2)"
    #expect(Self.isReferenced("packInstalling_v2", in: corpus))
    #expect(
      Self.isReferenced("packInstalling", in: corpus) == false,
      "`_` continues a Swift identifier, so this is a different declaration entirely")
  }

  /// The pill sentence must keep matching the phrasing the app already uses for a missing model,
  /// so the same situation is not described two different ways in two places.
  @Test("The missing-pack sentence follows the existing missing-model phrasing")
  func matchesExistingPrecedent() {
    let message = LivePreviewSettingsCopy.previewNeedsLanguagePack("French")
    #expect(message.hasPrefix("French"), "must name the language, not say 'a language'")
    #expect(message.contains("isn't downloaded yet"))
    #expect(message.contains("Open Settings"))
  }
}
