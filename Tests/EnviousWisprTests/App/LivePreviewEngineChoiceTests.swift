import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #2123 chunk A — the persisted engine choice, before anything reads it.
///
/// The whole chunk is one value and its fallbacks, so the tests are about the
/// fallbacks. The one that matters most is the CONTROL: a known `universal` raw
/// value must load as universal. Without it, every other assertion here passes
/// against a parser hardcoded to return Apple, which is exactly the shape a
/// default-to-Apple requirement invites.
@MainActor
@Suite struct LivePreviewEngineChoiceTests {

  private func store(_ name: String) throws -> UserDefaults {
    let suite = "com.enviouswispr.tests.2123.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return defaults
  }

  @Test("ships as Apple: the download is opt-in, never a default toll")
  func defaultIsApple() {
    #expect(SettingsDefaultValues.livePreviewEngine == .apple)
  }

  @Test("an absent key loads Apple, so an existing user is untouched by upgrade")
  func absentKeyLoadsApple() throws {
    let defaults = try store("absent")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.livePreviewEngine == .apple)
  }

  @Test("a value written by a newer build falls back to Apple instead of disabling the preview")
  func unknownRawValueFallsBackToApple() throws {
    let defaults = try store("unknown")
    defaults.set("some-engine-we-have-not-shipped", forKey: "livePreviewEngine")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.livePreviewEngine == .apple)
  }

  /// THE CONTROL for both fallback tests above.
  @Test("a known universal value loads as universal, not as Apple")
  func knownUniversalValueLoads() throws {
    let defaults = try store("known")
    defaults.set("universal", forKey: "livePreviewEngine")
    let settings = SettingsManager(defaults: defaults)
    #expect(
      settings.livePreviewEngine == .universal,
      "the reader returns Apple for everything — the fallback tests above are vacuous")
  }

  @Test("both choices round-trip through a relaunch")
  func bothChoicesPersist() throws {
    for choice in LivePreviewEngineChoice.allCases {
      let defaults = try store("roundtrip-\(choice.rawValue)")
      let writer = SettingsManager(defaults: defaults)
      writer.livePreviewEngine = choice
      // A second manager over the same store is what a relaunch looks like.
      let reader = SettingsManager(defaults: defaults)
      #expect(reader.livePreviewEngine == choice, "\(choice.rawValue) did not survive a reload")
    }
  }

  @Test("changing the engine notifies exactly once, under its own key")
  func changeNotifiesOnce() throws {
    let defaults = try store("notify")
    let settings = SettingsManager(defaults: defaults)
    final class Seen: @unchecked Sendable {
      var keys: [SettingsManager.SettingKey] = []
    }
    let seen = Seen()
    settings.onChange = { key in seen.keys.append(key) }

    settings.livePreviewEngine = .universal

    #expect(
      seen.keys.filter { $0 == .livePreviewEngine }.count == 1,
      "expected exactly one livePreviewEngine notification, got \(seen.keys)")
    #expect(
      !seen.keys.contains(.livePreviewEnabled),
      "changing the ENGINE must not report the on/off setting as changed")
  }

  /// Re-picking the engine you are already on must be inert (#2123 whole-diff
  /// review).
  ///
  /// The picker's card is a Button, so tapping the SELECTED one still assigns,
  /// and Swift runs `didSet` on a same-value assignment. The notification is not
  /// harmless here: it reaches `releaseForEngineChange()`, which tears the
  /// preview down unconditionally, so a re-tap during a recording killed the
  /// preview for the rest of that recording.
  ///
  /// Asserted two-way in ONE test on purpose. A test that only proved silence
  /// would also pass against a `didSet` that never fires at all, which is the
  /// same feature broken the other way.
  @Test("re-picking the current engine is silent; picking a different one is not")
  func noOpSelectionDoesNotNotify() throws {
    let defaults = try store("noop-select")
    let settings = SettingsManager(defaults: defaults)
    final class Seen: @unchecked Sendable {
      var keys: [SettingsManager.SettingKey] = []
    }
    let seen = Seen()
    settings.livePreviewEngine = .universal
    settings.onChange = { key in seen.keys.append(key) }

    settings.livePreviewEngine = .universal
    #expect(
      seen.keys.isEmpty,
      "re-picking the engine already selected must not notify, got \(seen.keys)")

    settings.livePreviewEngine = .apple
    #expect(
      seen.keys.filter { $0 == .livePreviewEngine }.count == 1,
      "a REAL change must still notify exactly once, got \(seen.keys)")
    #expect(settings.livePreviewEngine == .apple)
  }

  /// Registered ONCE, and registration is what carries it into the dev/release
  /// defaults migration too — `SettingsDefaultsMigration.unifiedKeys` reads this
  /// same list rather than keeping its own, so there is no second place to add it.
  ///
  /// The dispatch side needs no test: `handleSettingChanged` switches
  /// exhaustively over `SettingKey`, so the compiler is the enforcer and it
  /// already refused this chunk once for a missing case.
  @Test("the engine key is registered for unification exactly once")
  func keyIsRegisteredExactlyOnce() {
    #expect(
      SettingsManager.unifiedDefaultsKeys.filter { $0 == "livePreviewEngine" }.count == 1)
  }

  @Test("the engine value reaches telemetry as a closed enum, never as content")
  func telemetryProjectsTheEngine() throws {
    let defaults = try store("telemetry")
    let settings = SettingsManager(defaults: defaults)

    #expect(
      SettingsProjection.value(for: .livePreviewEngine, settings: settings) == "apple")
    settings.livePreviewEngine = .universal
    #expect(
      SettingsProjection.value(for: .livePreviewEngine, settings: settings) == "universal")

    // The change must map to the engine logical, and ONLY that one.
    #expect(SettingsProjection.logicals(for: .livePreviewEngine) == [.livePreviewEngine])
  }
}
