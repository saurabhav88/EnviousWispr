import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4528 B1: the Mac profile Setup recommends from.
///
/// **Product Outcome.** When this fails, a French or Hindi Mac is treated as English because the
/// app read its own interface language (plan M20), an 8 GB Mac is read as 16 GB, or Setup claims
/// Apple Intelligence can be turned on when Apple gave no such reason (plan M24, #1454).
@Suite(.tags(.productOutcome))
struct MacProfileReaderTests {
  private static func reader(memory: UInt64, languages: [String]) -> MacProfileReader {
    MacProfileReader(
      physicalMemoryBytes: { memory }, macOSMajor: { 26 }, chipName: { nil },
      freeDiskBytes: { 50_000_000_000 }, systemLanguages: { languages })
  }

  @Test("installed memory is read in whole binary gigabytes, never rounded up")
  func memoryInWholeGiB() {
    let gib: UInt64 = 1 << 30
    #expect(
      Self.reader(memory: 8 * gib, languages: []).read(appleIntelligence: .unavailable).memoryGiB
        == 8)
    #expect(
      Self.reader(memory: 16 * gib - 1, languages: []).read(appleIntelligence: .unavailable)
        .memoryGiB == 15)
    #expect(
      Self.reader(memory: 36 * gib, languages: []).read(appleIntelligence: .unavailable).memoryGiB
        == 36)
  }

  @Test("the Mac's own language list is used, first entry as the primary code")
  func systemLanguageList() {
    let french = Self.reader(memory: 1 << 34, languages: ["fr-CA", "en-US"]).read(
      appleIntelligence: .unavailable)
    #expect(french.macLanguages == ["fr-CA", "en-US"])
    #expect(french.primaryMacLanguageCode == "fr")
    let hindi = Self.reader(memory: 1 << 34, languages: ["hi-IN"]).read(
      appleIntelligence: .unavailable)
    #expect(hindi.primaryMacLanguageCode == "hi")
    let none = Self.reader(memory: 1 << 34, languages: []).read(appleIntelligence: .unavailable)
    #expect(none.primaryMacLanguageCode == nil)
  }

  @Test("language identifiers reduce to their base code")
  func baseCodes() {
    #expect(MacProfile.baseCode("zh-Hans-CN") == "zh")
    #expect(MacProfile.baseCode("EN_gb") == "en")
    #expect(MacProfile.baseCode("") == nil)
  }

  struct Mapping: Sendable, CustomTestStringConvertible {
    let notice: AppleIntelligenceAvailabilityReport.OnboardingPolishNotice?
    let live: AppleIntelligenceLiveAvailability
    let expected: AppleIntelligenceSetupState
    var testDescription: String { "\(String(describing: notice)) + \(live) -> \(expected)" }
  }

  /// Plan M24: the state comes only from the report's actionable notice and the live status.
  static let mappings: [Mapping] = [
    Mapping(notice: .enableInSettings, live: .disabled, expected: .turnedOff),
    Mapping(notice: .updateMacOS, live: .unsupported, expected: .needsNewerMacOS),
    Mapping(notice: nil, live: .available, expected: .available),
    Mapping(notice: nil, live: .modelNotReady, expected: .gettingReady),
    // No actionable reason: say nothing about why (deviceNotEligible must not become "turn it on").
    Mapping(notice: nil, live: .notEligible, expected: .unavailable),
    Mapping(notice: nil, live: .disabled, expected: .unavailable),
    Mapping(notice: nil, live: .unsupported, expected: .unavailable),
    Mapping(notice: nil, live: .unknown, expected: .unavailable),
  ]

  @Test("Apple Intelligence's Setup state follows the report's own notice", arguments: mappings)
  func appleIntelligenceMapping(_ m: Mapping) {
    #expect(AppleIntelligenceSetupState.from(notice: m.notice, live: m.live) == m.expected)
  }
}
