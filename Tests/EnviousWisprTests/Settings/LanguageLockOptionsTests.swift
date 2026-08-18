import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2154 — the one owner of "which languages may this backend be locked to".
///
/// **Product Outcome.** When this fails the user picks a language, the picker
/// accepts it, and dictation quietly ignores it: an unclaimed code maps to no
/// vendor language, the decoder falls back to auto-detect, and nothing on
/// screen says so (#1678). They see a lock they set and are not getting.
///
/// **Asserts the RULE, not the new call site.** The rule was lifted out of a
/// private property on the Transcription page so Live Preview's Change button
/// could use it. A test that only exercised the new caller would pass just as
/// happily against a reproduced-and-drifted copy, which is the exact failure
/// the lift exists to prevent — this feature has already paid for one partial
/// port (`ApplePackCatalog` carried a second copy of the locale claim logic
/// without its evict-at-cap step, and the sixth Download silently refused).
@MainActor
struct LanguageLockOptionsTests {

  /// `nil` means "no restriction", NOT "no languages". `LanguageLockSheet` reads
  /// it as the multilingual engine's full catalogue, so a well-meaning cleanup
  /// to a non-optional empty set would render an empty picker.
  @Test("The multilingual engine is unrestricted, and unrestricted is nil not empty")
  func whisperKitIsUnrestricted() {
    #expect(LanguageLockOptions.lockableCodes(for: .whisperKit) == nil)
  }

  /// Delegated to the backend, which derives it from the vendor enum minus the
  /// cases its model card does not claim. A hand-copied list here would silently
  /// drift the moment the vendor adds a language.
  @Test("The fast engine offers exactly what the backend claims")
  func parakeetMatchesTheBackend() {
    let codes = LanguageLockOptions.lockableCodes(for: .parakeet)
    #expect(codes == ParakeetBackend.lockableLanguageCodes)
    // Not vacuous: a bug returning nil or an empty set would satisfy an
    // equality test written against a broken source, so pin the shape too.
    #expect(codes?.isEmpty == false)
  }

  /// The two backends must not answer alike. If a refactor collapsed the switch,
  /// the fast engine would start offering all 99 and every lock outside its 25
  /// would become the silent failure above.
  @Test("The two backends give genuinely different answers")
  func theBackendsDiffer() {
    let whisper = LanguageLockOptions.lockableCodes(for: .whisperKit)
    let parakeet = LanguageLockOptions.lockableCodes(for: .parakeet)
    #expect(whisper != parakeet)
    #expect(whisper == nil)
    #expect(parakeet != nil)
  }

  /// The rule has exactly one implementation. Two copies is the defect this
  /// owner was created to prevent, and the second copy is always added by
  /// somebody who did not know the first existed.
  @Test("No page reproduces the backend switch")
  func theRuleIsNotReproduced() throws {
    let settingsDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Settings
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/EnviousWisprAppKit/Views/Settings")

    let files = try FileManager.default.contentsOfDirectory(atPath: settingsDir.path)
      .filter { $0.hasSuffix(".swift") && $0 != "LanguageLockOptions.swift" }

    var offenders: [String] = []
    for file in files {
      let source = try String(contentsOf: settingsDir.appendingPathComponent(file), encoding: .utf8)
      // Strip comments first: a matcher that cannot tell an ACTION from PROSE
      // about one is the precision failure this repo keeps hitting, and the
      // doc comment on the shared owner describes exactly this call.
      let code =
        source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
      if code.contains("ParakeetBackend.lockableLanguageCodes") {
        offenders.append(file)
      }
    }
    #expect(
      offenders.isEmpty,
      "the backend rule is reproduced outside LanguageLockOptions in: \(offenders)")

    // Two-way control: the check can actually find the string, so an empty
    // result means "looked correctly and found nothing" rather than "the sweep
    // is broken". Without this, a wrong path reads as a clean pass.
    let owner = try String(
      contentsOf: settingsDir.appendingPathComponent("LanguageLockOptions.swift"), encoding: .utf8)
    #expect(
      owner.contains("ParakeetBackend.lockableLanguageCodes"),
      "positive control failed: the sweep cannot see the owner's own call, so its silence proves nothing"
    )
  }
}
