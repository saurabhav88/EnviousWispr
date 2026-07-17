import AppKit
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #923 — canonical defaults, store routing, exclusions, and the one-time
/// effective-state migration. Every test uses an ephemeral suite so nothing
/// touches the host process or the real `com.enviouswispr.app` store.
@MainActor
@Suite("SettingsDefaults (#923)")
struct SettingsDefaultsRoutingTests {
  init() { _ = NSApplication.shared }  // @MainActor AppKit-touching SUT (swift-patterns)

  private static func freshSuite() -> UserDefaults {
    let name = "ew.settingsDefaultsTest." + UUID().uuidString
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  // MARK: - Canonical defaults (piece 0)

  @Test("fresh install yields the founder-ratified canonical defaults")
  func canonicalDefaults() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    // The two #923 corrections:
    #expect(settings.emojiFormatterEnabled == true)
    #expect(settings.llmProvider == .appleIntelligence)
    // Unchanged canonical values (lock them so an accidental flip fails here):
    #expect(settings.recordingMode == .pushToTalk)
    #expect(settings.toggleKeyCode == ModifierKeyCodes.rightOption)
    #expect(settings.cancelKeyCode == 53)
    #expect(settings.selectedBackend == .parakeet)
    #expect(settings.wordCorrectionEnabled == true)
    #expect(settings.fillerRemovalEnabled == true)
    #expect(settings.autoCopyToClipboard == true)
    #expect(settings.restoreClipboardAfterPaste == true)
    #expect(settings.vadAutoStop == false)
    #expect(settings.vadSilenceTimeout == 1.5)
    #expect(settings.languageMode == .auto)
    #expect(settings.warmEnginePolicy == .seconds30)
    #expect(settings.useStreamingASR == false)
  }

  // MARK: - Routing

  @Test("writes land in the injected store, not .standard")
  func writesRouteToInjectedStore() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.toggleKeyCode = 99
    settings.emojiFormatterEnabled = false
    #expect(suite.object(forKey: "toggleKeyCode") as? Int == 99)
    #expect(suite.object(forKey: "emojiFormatterEnabled") as? Bool == false)
    // Reconstructing from the same suite round-trips the explicit values.
    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.toggleKeyCode == 99)
    #expect(reloaded.emojiFormatterEnabled == false)
  }

  // MARK: - Exclusions (adversarial — these MUST stay per-build)

  @Test("unifiedDefaultsKeys excludes per-build knobs")
  func exclusionsHold() {
    let keys = Set(SettingsManager.unifiedDefaultsKeys)
    #expect(!keys.contains("useXPCASRService"))
    #expect(!keys.contains("accessibilityWarningDismissed"))
    // Removed setting (#734/#1533): the legacy `noiseSuppression` key is
    // migration-stripped on load, never part of the unified set.
    #expect(!keys.contains("noiseSuppression"))
    #expect(!keys.contains("sessionLanguagePriors"))
  }

  // MARK: - Appearance preference (#1047)

  @Test("appearance defaults to .system on a fresh install")
  func appearanceDefaultsToSystem() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.appearancePreference == .system)
  }

  @Test("appearance persists to the injected store and is in the unified key set")
  func appearancePersists() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.appearancePreference = .dark
    #expect(suite.string(forKey: "appearancePreference") == "dark")
    // Reload from the same store → the choice survives.
    #expect(SettingsManager(defaults: suite).appearancePreference == .dark)
    #expect(SettingsManager.unifiedDefaultsKeys.contains("appearancePreference"))
  }

  @Test("an unparseable stored appearance value falls back to .system")
  func appearanceUnparseableFallsBack() {
    let suite = Self.freshSuite()
    suite.set("solarized", forKey: "appearancePreference")
    #expect(SettingsManager(defaults: suite).appearancePreference == .system)
  }

  // MARK: - Overlay pill position (#1341)

  @Test("overlay pill position defaults to .top on a fresh install")
  func overlayPillPositionDefaultsToTop() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.overlayPillPosition == .top)
  }

  @Test("overlay pill position persists to the injected store and is in the unified key set")
  func overlayPillPositionPersists() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.overlayPillPosition = .bottom
    #expect(suite.string(forKey: "overlayPillPosition") == "bottom")
    // Reload from the same store → the choice survives.
    #expect(SettingsManager(defaults: suite).overlayPillPosition == .bottom)
    #expect(SettingsManager.unifiedDefaultsKeys.contains("overlayPillPosition"))
  }

  @Test("an unparseable stored overlay pill position falls back to .top")
  func overlayPillPositionUnparseableFallsBack() {
    let suite = Self.freshSuite()
    suite.set("sideways", forKey: "overlayPillPosition")
    #expect(SettingsManager(defaults: suite).overlayPillPosition == .top)
  }

  #if DEBUG
    // AFM adapter PoC dev knob — a per-build contract: writes to .standard (not
    // the injected store) and stays out of the unified key set. DEBUG-gated
    // because the property only exists in DEBUG builds.
    @Test("devAdapterPolishEnabled writes to .standard and stays out of unified defaults")
    func devAdapterStaysPerBuild() {
      let suite = Self.freshSuite()
      let settings = SettingsManager(defaults: suite)
      settings.devAdapterPolishEnabled = false
      // The per-build knob must NOT land in the injected (shared) suite.
      #expect(suite.object(forKey: "devAdapterPolishEnabled") == nil)
      #expect(UserDefaults.standard.object(forKey: "devAdapterPolishEnabled") as? Bool == false)
      // And it must never join the unified key set.
      #expect(Set(SettingsManager.unifiedDefaultsKeys).contains("devAdapterPolishEnabled") == false)
      UserDefaults.standard.removeObject(forKey: "devAdapterPolishEnabled")  // cleanup
    }
  #endif

  // MARK: - lastLLMProvider (#1285 AI Polish on/off toggle memory)

  @Test("lastLLMProvider persists to the injected store and is in the unified key set")
  func lastLLMProviderPersists() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.llmProvider = .openAI
    #expect(suite.string(forKey: "lastLLMProvider") == LLMProvider.openAI.rawValue)
    // Reload from the same store → the remembered engine survives.
    #expect(SettingsManager(defaults: suite).lastLLMProvider == .openAI)
    #expect(SettingsManager.unifiedDefaultsKeys.contains("lastLLMProvider"))
  }

  @Test("fresh install seeds lastLLMProvider to the default engine and writes it through")
  func lastLLMProviderFreshSeed() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    #expect(settings.lastLLMProvider == SettingsDefaultValues.lastLLMProvider)
    // Write-through: init must persist the seed even though didSet does not fire
    // on init assignment (the upgrade-toggle-off-then-quit data-loss guard).
    #expect(
      suite.string(forKey: "lastLLMProvider") == SettingsDefaultValues.lastLLMProvider.rawValue)
  }

  // MARK: - Migration (effective-state, dev-store sentinel)

  @Test("dev migration copies explicit values, clears stale shared, sets dev sentinel")
  func migrationEffectiveState() {
    let dev = Self.freshSuite()
    let shared = Self.freshSuite()
    // dev explicitly chose a record key; shared holds a STALE value dev never set.
    dev.set(99, forKey: "toggleKeyCode")
    shared.set(100, forKey: "emojiFormatterEnabled")  // stale-only-in-shared (the F8-class ghost)

    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app.dev", devStore: dev, shared: shared)

    // explicit dev value carried over:
    #expect(shared.object(forKey: "toggleKeyCode") as? Int == 99)
    // stale shared value (absent in dev) cleared so the canonical default re-applies:
    #expect(shared.object(forKey: "emojiFormatterEnabled") == nil)
    // sentinel lives in the DEV store, not shared:
    #expect(dev.bool(forKey: SettingsDefaultsMigration.devSentinelKey) == true)
    #expect(shared.object(forKey: SettingsDefaultsMigration.devSentinelKey) == nil)
  }

  @Test("release build is a no-op (no writes, no sentinel)")
  func migrationReleaseNoOp() {
    let dev = Self.freshSuite()
    let shared = Self.freshSuite()
    dev.set(99, forKey: "toggleKeyCode")

    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app", devStore: dev, shared: shared)

    #expect(shared.object(forKey: "toggleKeyCode") == nil)
    #expect(dev.bool(forKey: SettingsDefaultsMigration.devSentinelKey) == false)
  }

  @Test("idempotent: second run with sentinel set is a no-op")
  func migrationIdempotent() {
    let dev = Self.freshSuite()
    let shared = Self.freshSuite()
    dev.set(99, forKey: "toggleKeyCode")
    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app.dev", devStore: dev, shared: shared)
    // Change dev AFTER first migration; second run must not re-copy.
    dev.set(55, forKey: "toggleKeyCode")
    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app.dev", devStore: dev, shared: shared)
    #expect(shared.object(forKey: "toggleKeyCode") as? Int == 99)  // not 55
  }

  @Test("dev-store sentinel survives a shared-store wipe (no resurrection)")
  func sentinelSurvivesSharedWipe() {
    let dev = Self.freshSuite()
    let shared = Self.freshSuite()
    dev.set(99, forKey: "toggleKeyCode")
    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app.dev", devStore: dev, shared: shared)
    // Simulate `defaults delete com.enviouswispr.app` (wipe the shared store).
    shared.removeObject(forKey: "toggleKeyCode")
    // Next dev launch: sentinel is in the DEV store (untouched), so NO re-copy.
    SettingsDefaultsMigration.migrateIfNeeded(
      bundleID: "com.enviouswispr.app.dev", devStore: dev, shared: shared)
    #expect(shared.object(forKey: "toggleKeyCode") == nil)  // stale dev value NOT resurrected
  }
}
