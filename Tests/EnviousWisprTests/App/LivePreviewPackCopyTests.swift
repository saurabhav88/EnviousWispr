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
      LivePreviewSettingsCopy.previewNeedsLanguagePack("French"),
    ]
    for s in strings {
      #expect(!s.contains("—"), "em-dash in user-facing copy: \(s)")
      #expect(!s.contains("–"), "en-dash in user-facing copy: \(s)")
    }
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
