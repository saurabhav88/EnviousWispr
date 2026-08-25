import AppKit
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// Two persisted selections, one per capability group (#2376 Phase 4, C6).
///
/// **The criterion is a RENDERED WIDTH, not a value read back out of the store.**
/// Reading a key back proves the store works; what has to be true is that a
/// choice reaches the pill, and that the OTHER group's choice is still there when
/// the capability flips back. So every row here drives
/// `PillDesignSelections.resolve` — the same function the director calls — from
/// values loaded by a real `SettingsManager` over an ephemeral store, and asserts
/// on the design that comes out.
///
/// **Product Outcome.** When these fail a user's chosen pill silently reverts, or
/// choosing one pill forgets the other.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingPillSelectionTests {

  init() { _ = NSApplication.shared }

  private static func freshSuite() -> UserDefaults {
    let name = "ew.pillDesignTest." + UUID().uuidString
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  /// The selections a settings-backed director would build, which is the exact
  /// expression the bootstrapper's seam evaluates.
  private static func selections(_ s: SettingsManager) -> PillDesignSelections {
    PillDesignSelections(
      withoutWords: s.recordingPillDesignWithoutWords,
      withWords: s.recordingPillDesignWithWords)
  }

  private static func width(_ s: SettingsManager, hasWords: Bool) -> CGFloat {
    selections(s).resolve(capabilityHasWords: hasWords).design.width
  }

  // MARK: - The criterion nothing else produces

  /// **FOUR WIDTHS FROM ONE RUN, and the fourth is the whole point.** A key read
  /// back would fake the first three: the memory claim is that flipping the
  /// capability away and back returns the design last chosen on THAT side, and
  /// only a second reading of the without-words group after a round trip can say
  /// so.
  @Test("each group remembers its own choice across a capability flip")
  func perGroupMemorySurvivesACapabilityFlip() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)

    // 1. Fresh install, no words: the shipped capsule.
    #expect(Self.width(settings, hasWords: false) == 185)

    // 2. Choose the level rail for the wordless side.
    settings.recordingPillDesignWithoutWords = .levelRail
    #expect(
      Self.width(settings, hasWords: false) == 260,
      "the chosen design did not reach the pill")

    // 3. Words become available: the OTHER group's choice decides, untouched.
    #expect(
      Self.width(settings, hasWords: true) == 400,
      "choosing a wordless design changed what the with-words group renders")

    // 4. Words go away again. THIS is the memory claim: 260, not the 185 a
    //    single shared key or a reset would give back.
    #expect(
      Self.width(settings, hasWords: false) == 260,
      """
      the wordless group came back at a different width after a capability flip, \
      so the user's choice on that side was lost or overwritten by the other \
      group's.
      """)
  }

  /// The mirror: choosing on the with-words side leaves the wordless side alone.
  /// Without this the row above passes on an implementation that simply never
  /// writes the with-words key.
  @Test("choosing a with-words design leaves the wordless choice alone")
  func theTwoGroupsAreIndependent() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.recordingPillDesignWithoutWords = .levelRail
    settings.recordingPillDesignWithWords = .readingWell

    #expect(Self.width(settings, hasWords: true) == 400)
    #expect(Self.width(settings, hasWords: false) == 260)
    #expect(
      suite.string(forKey: "recordingPillDesignWithoutWords") == "levelRail",
      "the with-words write reached the wordless key")
  }

  // MARK: - Fail-closed, observed through the first path that can reach it

  /// **C4's guard, seen through persistence.** A cross-group value is only
  /// reachable from a hand-edited plist or a downgrade, and this is the first
  /// path in the product that can carry one. It must render the wordless design,
  /// not a 400-point panel with nothing to put in it.
  @Test("a with-words design stored in the wordless key renders the wordless pill")
  func aCrossGroupValueFailsClosed() {
    let suite = Self.freshSuite()
    suite.set("readingWell", forKey: "recordingPillDesignWithoutWords")
    let settings = SettingsManager(defaults: suite)

    #expect(
      settings.recordingPillDesignWithoutWords == .readingWell,
      "control: the store really does hold the crossed value")
    let resolution = Self.selections(settings).resolve(capabilityHasWords: false)
    #expect(resolution.substituted, "the crossed value was accepted")
    #expect(
      resolution.design.width == 185,
      "a wordless pill rendered at \(resolution.design.width)pt — the empty wide panel")
  }

  // MARK: - The defaults are the frozen pair, and stay so

  /// **The binding the canonical-defaults doc requires.** `PillDesignSelections.
  /// shipped` is what every overlay test measures against; these two constants
  /// are what production loads. Asserting they agree is what makes the frozen
  /// reference a reference rather than a second opinion.
  @Test("the shipped defaults are the frozen pair")
  func defaultsEqualTheFrozenPair() {
    #expect(
      SettingsDefaultValues.recordingPillDesignWithoutWords
        == PillDesignSelections.shipped.withoutWords)
    #expect(
      SettingsDefaultValues.recordingPillDesignWithWords
        == PillDesignSelections.shipped.withWords)
  }

  @Test("a fresh install renders exactly what it rendered before this phase")
  func freshInstallIsUnchanged() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(Self.selections(settings) == PillDesignSelections.shipped)
    #expect(Self.width(settings, hasWords: false) == 185)
    #expect(Self.width(settings, hasWords: true) == 400)
  }

  // MARK: - The three-test pattern, per key

  @Test(
    "each key persists to the injected store and is in the unified key set",
    arguments: [
      ("recordingPillDesignWithoutWords", RecordingPillDesign.levelRail),
      ("recordingPillDesignWithWords", RecordingPillDesign.readingWell),
    ])
  func keysPersistAndAreUnified(row: (String, RecordingPillDesign)) {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    if row.0.hasSuffix("WithoutWords") {
      settings.recordingPillDesignWithoutWords = row.1
    } else {
      settings.recordingPillDesignWithWords = row.1
    }
    #expect(suite.string(forKey: row.0) == row.1.rawValue)
    #expect(
      SettingsManager.unifiedDefaultsKeys.contains(row.0),
      """
      \(row.0) is missing from unifiedDefaultsKeys, so the build-unification
      migration will not carry it and a user's choice is lost between builds. That
      array is hand-written with no derivation, so nothing but this catches it.
      """)
  }

  @Test(
    "an unparseable stored design falls back to its shipped default",
    arguments: ["recordingPillDesignWithoutWords", "recordingPillDesignWithWords"])
  func unparseableFallsBack(key: String) {
    let suite = Self.freshSuite()
    suite.set("sideways", forKey: key)
    let settings = SettingsManager(defaults: suite)
    #expect(Self.selections(settings) == PillDesignSelections.shipped)
  }

  /// **Raw values derive from case NAMES, so a rename orphans every saved
  /// selection to the fallback — silently, on every machine.** Pinned explicitly
  /// rather than trusted, because nothing else in the build would notice.
  @Test("the persisted spellings are stable")
  func rawValuesAreStable() {
    #expect(RecordingPillDesign.classic.rawValue == "classic")
    #expect(RecordingPillDesign.readingWell.rawValue == "readingWell")
    #expect(RecordingPillDesign.levelRail.rawValue == "levelRail")
    #expect(
      Set(RecordingPillDesign.allCases.map(\.rawValue)).count
        == RecordingPillDesign.allCases.count,
      "two designs share a persisted spelling, so one silently loads as the other")
  }
}
