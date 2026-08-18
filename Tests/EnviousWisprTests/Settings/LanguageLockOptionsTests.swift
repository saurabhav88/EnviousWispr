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
/// Class: **Product Outcome.** "When this fails, the user sees ___" completes as
/// "a language lock they set and are not getting" — the picker accepts a code the
/// engine cannot honour, the decoder silently falls back to auto-detect, and
/// nothing on screen says so (#1678).
@Suite(.tags(.productOutcome))
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

  /// #2154, cloud review r3. **Every consumer of the resolved language must read
  /// the staleness owner, not `packs.active` directly.**
  ///
  /// An earlier fix guarded only the status card, so the language panel and the
  /// "In use" badge kept deriving from a value known to describe the PREVIOUS
  /// language. Three consumers with one guard between them is not a fix, it is
  /// the first of three review rounds. This fails if a future consumer
  /// reintroduces a direct read.
  ///
  /// Guards over source TEXT are weak by construction (an alias walks past
  /// this), which is why it is paired with behavioural tests on the mapping
  /// rather than standing alone. It catches the mistake actually made — copying
  /// the obvious accessor — not every conceivable one.
  @Test("Only the staleness owner reads the resolved language directly")
  func everyConsumerGoesThroughTheStalenessOwner() throws {
    let view = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(
        "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift")
    let source = try String(contentsOf: view, encoding: .utf8)

    // Strip comments: the owner's own doc comment names the accessor it
    // replaces, and a matcher that cannot tell an ACTION from PROSE about one is
    // the precision failure this repo keeps hitting.
    let code = source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix("//") && !t.hasPrefix("///")
      }
      .joined(separator: "\n")

    let reads = code.components(separatedBy: "packs.active").count - 1
    #expect(
      reads == 1,
      "expected exactly one direct read of the resolved language, inside the staleness owner; found \(reads)")

    // Two-way control: the sweep can see the string at all, so a wrong path
    // cannot pass as a clean result.
    #expect(code.contains("currentActive"), "positive control: the owner is not in the file the sweep read")
  }

  /// **The sheet can now CLEAR a lock, and this is the whole of that behaviour
  /// that is testable without a running app.**
  ///
  /// Cloud review r11: #2154 put a Change button on the Live Preview page which
  /// opens `LanguageLockSheet`, and every row in it assigned `.locked(code)`. A
  /// user who locked a language from that page had no way to undo it there — the
  /// only Auto control was a separate toggle on a different page. An affordance
  /// that sets a state and cannot clear it strands the people who trusted it.
  ///
  /// The rows are SwiftUI and out of reach, so what is asserted is the decision
  /// both rows share: the transition a tap reports. All four directions, because
  /// the reason classification is the part that can silently go wrong and the
  /// return-to-Auto direction is the one that did not exist before.
  @Test("Every language-mode transition reports the right telemetry")
  func lockTelemetryCoversBothDirections() {
    let firstLock = LanguageLockOptions.lockTelemetry(from: .auto, to: .locked("de"))
    #expect(firstLock.fromLang == "auto")
    #expect(firstLock.toLang == "de")
    #expect(
      firstLock.reason == "first_time",
      "leaving Auto for the first lock is a first_time, not a preference change")

    let changedMind = LanguageLockOptions.lockTelemetry(from: .locked("de"), to: .locked("fr"))
    #expect(changedMind.fromLang == "de")
    #expect(changedMind.toLang == "fr")
    #expect(changedMind.reason == "preference", "swapping one lock for another is a preference")

    let backToAuto = LanguageLockOptions.lockTelemetry(from: .locked("de"), to: .auto)
    #expect(backToAuto.fromLang == "de")
    #expect(
      backToAuto.toLang == "auto",
      "a return to Auto must use the same vocabulary fromLang already used for it")
    #expect(
      backToAuto.reason == "preference",
      "returning to Auto is a change of mind and must never be reported as a first lock")

    // Degenerate but reachable: the Auto row is tappable while already on Auto.
    let noChange = LanguageLockOptions.lockTelemetry(from: .auto, to: .auto)
    #expect(noChange.fromLang == "auto")
    #expect(noChange.toLang == "auto")
    #expect(
      noChange.reason == "preference",
      "re-confirming Auto is not a first lock; nothing was locked")
  }

  /// The reserved value must stay reserved. `after_bad_detect` belongs to the
  /// passive chip CTA, and a Settings-driven change borrowing it would make the
  /// two indistinguishable in the data.
  @Test("The sheet never emits the reason reserved for the passive chip")
  func neverEmitsReservedReason() {
    let transitions: [(LanguageMode, LanguageMode)] = [
      (.auto, .locked("de")), (.locked("de"), .locked("fr")),
      (.locked("de"), .auto), (.auto, .auto),
    ]
    for (from, to) in transitions {
      #expect(
        LanguageLockOptions.lockTelemetry(from: from, to: to).reason != "after_bad_detect",
        "the sheet must not emit the chip CTA's reason for \(from) -> \(to)")
    }
  }

  // MARK: - Preview picker scope (founder 2026-08-18)

  /// **The picker offers what you can switch to NOW; the table below is the
  /// catalogue.** Founder: "we already have the download selector at the bottom,
  /// which is an endless scroll. It'd be silly for us to offer another option to
  /// download."
  @Test("On Apple the picker offers only languages whose pack is installed")
  func applyPickerIsInstalledOnly() {
    let codes = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple,
      installedPackTags: ["en-US", "de-DE"])
    #expect(codes == ["en", "de"], "only installed packs, as ISO language codes")
    #expect(
      codes?.contains("fr") != true,
      "a language with no installed pack must not be offered")
  }

  /// **The reactivity IS the requirement, not an implementation detail.** Founder:
  /// "if they download it from the bottom selection table, it should then pop up
  /// into the selector." Same call, one more installed tag, one more offered code.
  @Test("Downloading a pack makes that language available to the picker")
  func downloadedPackAppearsInPicker() {
    let before = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple, installedPackTags: ["en-US"])
    #expect(before?.contains("de") != true, "German is absent before its pack exists")

    let after = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple, installedPackTags: ["en-US", "de-DE"])
    #expect(
      after?.contains("de") == true,
      "after the table installs German it must appear in the picker")
  }

  /// Universal has no per-language installs — one model covers everything it
  /// claims — so the install set is irrelevant there and must not narrow it.
  @Test("On Universal the picker ignores installed packs entirely")
  func universalPickerIgnoresInstalls() {
    let none = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .universal, installedPackTags: [])
    #expect(
      none == LanguageLockOptions.lockableCodes(for: .whisperKit),
      "Universal must offer the backend's whole set even with no packs installed")

    let some = LanguageLockOptions.previewLockableCodes(
      backend: .parakeet, previewEngine: .universal, installedPackTags: ["en-US"])
    #expect(
      some == LanguageLockOptions.lockableCodes(for: .parakeet),
      "an installed Apple pack must not change what Universal offers")
  }

  /// **INTERSECTION, never replacement — this is the #1678 silent failure.** The
  /// picker sets the DICTATION language, so a code outside the ASR backend's
  /// lockable set produces a lock that looks set while the decoder auto-detects.
  /// Narrowing to installed packs happens INSIDE that set.
  @Test("The picker never offers a code the dictation engine cannot honour")
  func neverEscapesTheBackendSet() {
    guard let parakeet = LanguageLockOptions.lockableCodes(for: .parakeet) else {
      Issue.record("expected Parakeet to restrict its lockable codes")
      return
    }
    // Claim an installed pack for a language the fast engine does NOT claim.
    let unclaimed = LanguageCatalog.sortedByEnglishName
      .map(\.code).first { !parakeet.contains($0) }
    guard let unclaimed else {
      Issue.record("expected at least one catalogue code outside Parakeet's set")
      return
    }
    let codes = LanguageLockOptions.previewLockableCodes(
      backend: .parakeet, previewEngine: .apple,
      installedPackTags: ["en-US", "\(unclaimed)-XX"])
    #expect(
      codes?.contains(unclaimed) != true,
      "an installed pack for \(unclaimed) must not escape Parakeet's lockable set")
    #expect(codes?.isSubset(of: parakeet) == true, "always a subset of the backend's set")
  }

  /// Nothing installed is a real state on a fresh Mac, and it must not crash or
  /// silently fall back to "everything" — the picker simply offers Auto.
  @Test("No installed packs offers nothing to lock, not everything")
  func noInstalledPacksOffersNothing() {
    let codes = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple, installedPackTags: [])
    #expect(codes == [], "empty, never nil — nil would mean unrestricted")
  }
}
