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
    // #1794: the ONE Text-cleanup toggle that ships OFF.
    #expect(settings.spokenPunctuationEnabled == false)
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
    // Smart insertion ships ON: the repair only fires where it is positively
    // safe, and an unrecognised word keeps today's behaviour, so the default
    // costs nothing and the feature is invisible until it helps.
    #expect(settings.smartInsertion == true)
    #expect(settings.vadAutoStop == false)
    #expect(settings.vadSilenceTimeout == 1.5)
    #expect(settings.languageMode == .auto)
    #expect(settings.warmEnginePolicy == .seconds30)
    #expect(settings.useStreamingASR == false)
    // #1950: lock the exact shipped value here because a default change must update the settings
    // authority, Core fallback, canonical-defaults test, knowledge mirror, and What's New together.
    #expect(settings.ollamaModel == "qwen2.5:3b")
  }

  @Test("the Ollama default and the Core fallback cannot drift apart")
  func ollamaDefaultMatchesCoreFallback() {
    // Two sites hold this string: the settings authority, and `defaultModel`'s fallback parameter
    // for callers with no saved value. Changing one alone means the fallback path quietly serves a
    // different model than a fresh install does, which is invisible until someone hits that path.
    #expect(SettingsDefaultValues.ollamaModel == LLMProvider.defaultModel(for: .ollama))
  }

  @Test("a model the user already chose survives the default move")
  func storedOllamaModelSurvives() {
    // Deliberately neither the old nor the new default, so this cannot pass by coincidence if the
    // stored value were being ignored and a default substituted.
    let suite = Self.freshSuite()
    suite.set("someones-own-finetune:13b", forKey: "ollamaModel")

    let settings = SettingsManager(defaults: suite)

    #expect(settings.ollamaModel == "someones-own-finetune:13b")
  }

  // MARK: - Routing

  @Test("Smart insertion persists OFF and belongs to unified defaults")
  func smartInsertionPersistsOff() {
    // The default alone proves nothing about an explicit choice surviving.
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)

    settings.smartInsertion = false

    #expect(suite.object(forKey: "smartInsertion") as? Bool == false)
    #expect(SettingsManager(defaults: suite).smartInsertion == false)
    #expect(
      SettingsManager.unifiedDefaultsKeys.filter { $0 == "smartInsertion" }.count == 1)
  }

  /// #2087. Tested in the ON direction because OFF is the default: writing the
  /// default proves nothing about persistence, since a store that dropped the
  /// write entirely would still read back `false`.
  @Test("Escape Recovery persists ON and belongs to unified defaults")
  func escapeRecoveryPersistsOn() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)

    #expect(settings.escapeRecoveryEnabled == false, "ships OFF — the product decision")

    settings.escapeRecoveryEnabled = true

    #expect(suite.object(forKey: "escapeRecoveryEnabled") as? Bool == true)
    #expect(SettingsManager(defaults: suite).escapeRecoveryEnabled == true)
    #expect(
      SettingsManager.unifiedDefaultsKeys.filter { $0 == "escapeRecoveryEnabled" }.count == 1,
      "missing from unified keys means it never migrates to the shared suite (#923)")
  }

  @Test("Escape Recovery change emits its SettingKey exactly once")
  func escapeRecoveryNotifies() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    var matchingChanges = 0

    settings.onChange = { key in
      if case .escapeRecoveryEnabled = key { matchingChanges += 1 }
    }

    settings.escapeRecoveryEnabled = true
    #expect(matchingChanges == 1)
  }

  @Test("Smart insertion change emits its SettingKey exactly once")
  func smartInsertionNotifies() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    var matchingChanges = 0

    settings.onChange = { key in
      if case .smartInsertion = key { matchingChanges += 1 }
    }

    settings.smartInsertion = false
    #expect(matchingChanges == 1)
  }

  @Test("writes land in the injected store, not .standard")
  func writesRouteToInjectedStore() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.toggleKeyCode = 99
    settings.emojiFormatterEnabled = false
    settings.spokenPunctuationEnabled = true
    #expect(suite.object(forKey: "toggleKeyCode") as? Int == 99)
    #expect(suite.object(forKey: "emojiFormatterEnabled") as? Bool == false)
    #expect(suite.object(forKey: "spokenPunctuationEnabled") as? Bool == true)
    // Reconstructing from the same suite round-trips the explicit values.
    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.toggleKeyCode == 99)
    #expect(reloaded.emojiFormatterEnabled == false)
    #expect(reloaded.spokenPunctuationEnabled == true)
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

  // MARK: - Recording sound cues (#1342)

  @Test("recording sounds default to off, whisperTick pairing, on a fresh install")
  func recordingSoundsDefaults() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.playRecordingSounds == false)
    #expect(settings.recordingSoundPairing == .whisperTick)
  }

  @Test("recording sound settings persist to the injected store and are in the unified key set")
  func recordingSoundsPersist() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.playRecordingSounds = true
    settings.recordingSoundPairing = .cloudPop
    #expect(suite.object(forKey: "playRecordingSounds") as? Bool == true)
    #expect(suite.string(forKey: "recordingSoundPairing") == "cloudPop")
    // Reload from the same store → the choice survives.
    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.playRecordingSounds == true)
    #expect(reloaded.recordingSoundPairing == .cloudPop)
    #expect(SettingsManager.unifiedDefaultsKeys.contains("playRecordingSounds"))
    #expect(SettingsManager.unifiedDefaultsKeys.contains("recordingSoundPairing"))
  }

  @Test("an unparseable stored recording sound pairing falls back to .whisperTick")
  func recordingSoundPairingUnparseableFallsBack() {
    let suite = Self.freshSuite()
    suite.set("nonexistentPairing", forKey: "recordingSoundPairing")
    #expect(SettingsManager(defaults: suite).recordingSoundPairing == .whisperTick)
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

  // MARK: - #1987 Globe key guidance claim

  /// The claim is one shared owner, so a second caller gets `false` no matter who
  /// asked first. That single-owner design is what makes the surface ORDER
  /// irrelevant, which is why it is not simulated here.
  ///
  /// An earlier version of this test labelled two identical blocks "onboarding
  /// first" and "Settings first". They executed the same two calls against
  /// `SettingsManager`, so the labels described an ordering the code never varied
  /// and neither surface appeared at all. Removed rather than reworded: a name
  /// that claims more than the body does is worse than a narrower name, because
  /// it stops the next reader looking for the missing coverage.
  ///
  /// NOT COVERED HERE, deliberately, and on the founder's manual pass instead:
  /// that `KeybindsSettingsView` and `ReadyScreenV2` actually CALL this on an
  /// accepted bind. Both call sites live in SwiftUI view bodies that need a
  /// rendered hierarchy, so deleting either one leaves every test in this file
  /// green. A user who binds Globe and sees no explanation is the visible symptom.
  @Test("A second claim on the same store returns false")
  func guidanceClaimIsOncePerInstall() {
    let suite = UserDefaults(suiteName: "GlobeClaim-\(UUID().uuidString)")!
    let settings = SettingsManager(defaults: suite)
    #expect(settings.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe))
    #expect(!settings.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe))
  }

  /// A separate installation is unaffected by another store's claim. Without this,
  /// a claim keyed on something process-wide rather than on the defaults store
  /// would pass every other test in this file.
  @Test("A fresh store gets its own claim")
  func guidanceClaimIsPerStore() {
    let suiteA = UserDefaults(suiteName: "GlobeClaimA-\(UUID().uuidString)")!
    let suiteB = UserDefaults(suiteName: "GlobeClaimB-\(UUID().uuidString)")!
    #expect(
      SettingsManager(defaults: suiteA).claimGlobeKeyGuidancePresentation(
        for: ModifierKeyCodes.globe))
    #expect(
      SettingsManager(defaults: suiteB).claimGlobeKeyGuidancePresentation(
        for: ModifierKeyCodes.globe))
  }

  /// The claim must survive a relaunch, or the explanation reappears forever.
  @Test("The claim persists across a new SettingsManager on the same store")
  func guidanceClaimPersists() {
    let suite = UserDefaults(suiteName: "GlobeClaimPersist-\(UUID().uuidString)")!
    #expect(
      SettingsManager(defaults: suite).claimGlobeKeyGuidancePresentation(
        for: ModifierKeyCodes.globe))
    // A second manager over the same store is what a relaunch looks like.
    #expect(
      !SettingsManager(defaults: suite).claimGlobeKeyGuidancePresentation(
        for: ModifierKeyCodes.globe))
  }

  /// Binding a non-Globe key must NOT consume the claim, or a user who picks Right
  /// Option first would never see the explanation when they later choose Globe.
  @Test("A non-Globe bind does not consume the claim")
  func nonGlobeBindDoesNotConsumeTheClaim() {
    let suite = UserDefaults(suiteName: "GlobeClaimOther-\(UUID().uuidString)")!
    let settings = SettingsManager(defaults: suite)

    #expect(!settings.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.rightOption))
    #expect(!settings.claimGlobeKeyGuidancePresentation(for: 0))
    // The claim is still available.
    #expect(settings.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe))
  }

  /// Two separate claims, because asserting only the first leaves the gap that
  /// prompted this test: the list could name one key while the claim wrote another,
  /// and the claim would silently fall outside build unification. Reading the store
  /// after a real claim ties the registered name to the key actually persisted.
  ///
  /// The production constant is `private`, so this asserts the literal deliberately.
  /// That is the point: the string is what survives an app update, and changing it
  /// re-shows the explanation to every existing user.
  @Test("The key the claim actually writes is the one registered for unification")
  func claimKeyIsRegisteredAndIsTheKeyWritten() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("hasClaimedGlobeKeyGuidance"))

    let suite = UserDefaults(suiteName: "GlobeClaimKeyName-\(UUID().uuidString)")!
    #expect(suite.object(forKey: "hasClaimedGlobeKeyGuidance") == nil)
    #expect(
      SettingsManager(defaults: suite).claimGlobeKeyGuidancePresentation(
        for: ModifierKeyCodes.globe))
    #expect(suite.bool(forKey: "hasClaimedGlobeKeyGuidance"))
  }
}
