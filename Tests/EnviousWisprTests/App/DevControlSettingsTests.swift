#if DEBUG
  import AppKit
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation
  import SwiftParser
  import SwiftSyntax
  import Testing

  @testable import EnviousWisprAppKit

  /// #3765: the dev control door's settings table.
  ///
  /// Drift Guard: when this fails, a new or renamed setting is missing from the door, sits
  /// in the wrong write kind, or a forced write lands on the wrong property; an agent's UAT
  /// would set up the wrong state. No customer sees it.
  ///
  /// Expectations come from the source declaration and from key paths written here by
  /// hand, never from the table under test.
  @Suite(.tags(.driftGuard))
  @MainActor
  struct DevControlSettingsTests {
    private static var repoRoot: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // App
        .deletingLastPathComponent()  // EnviousWisprTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    }

    /// The `case` names inside `public enum SettingKey { ... }`, read from source.
    private static func declaredKeyNames() throws -> [String] {
      let source = try String(
        contentsOf: repoRoot.appendingPathComponent(
          "Sources/EnviousWisprServices/SettingsManager.swift"),
        encoding: .utf8)
      let tree = Parser.parse(source: source)
      try #require(tree.hasError == false)
      let owner = try #require(
        tree.statements.compactMap { $0.item.as(ClassDeclSyntax.self) }
          .first { $0.name.text == "SettingsManager" })
      let declaration = try #require(
        owner.memberBlock.members.compactMap { $0.decl.as(EnumDeclSyntax.self) }
          .first { $0.name.text == "SettingKey" })
      let visitor = CaseNames(viewMode: .sourceAccurate)
      visitor.walk(declaration.memberBlock)
      return visitor.names
    }

    /// Every case element in an enum body, including several cases on one line, skipping
    /// nested enums.
    private final class CaseNames: SyntaxVisitor {
      var names: [String] = []

      override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        names.append(contentsOf: node.elements.map { $0.name.identifier?.name ?? $0.name.text })
        return .skipChildren
      }

      override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
      }
    }

    private static func fixture() -> (String, UserDefaults, SettingsManager) {
      let name = "ew.tests.3765.settings.\(UUID().uuidString)"
      let defaults = TestDefaults.suite(name)!
      return (name, defaults, SettingsManager(defaults: defaults))
    }

    /// A JSON value exactly as the door receives it off the wire.
    private static func wire(_ text: String) throws -> Any {
      try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    // MARK: - Catalog

    @Test("the table lists exactly the 70 declared keys, once each, in four kinds")
    func catalogMatchesDeclaration() throws {
      let declared = try Self.declaredKeyNames()
      #expect(declared.count == 70)
      #expect(Set(declared).count == declared.count)
      let listed = DevControlSettings.allKeys.map(DevControlSettings.name)
      #expect(listed == declared)
      for name in declared {
        #expect(DevControlSettings.key(named: name).map(DevControlSettings.name) == name)
      }
      #expect(DevControlSettings.key(named: "notASetting") == nil)

      let (_, _, settings) = Self.fixture()
      let rows = DevControlSettings.catalog(settings)
      #expect(rows.count == 70)
      #expect(rows.compactMap { $0["key"] as? String } == declared)
      for row in rows {
        #expect(row["value"] != nil)
        #expect(JSONSerialization.isValidJSONObject([row]))
      }

      var kinds: [String: [String]] = [:]
      for row in rows {
        kinds[row["kind"] as? String ?? "?", default: []].append(row["key"] as? String ?? "?")
      }
      #expect(kinds["direct"]?.count == 38)
      #expect(kinds["viaOwner"]?.count == 8)
      #expect(kinds["extractedCheck"]?.count == 16)
      #expect(kinds["staging"]?.count == 8)
      #expect(kinds.keys.sorted() == ["direct", "extractedCheck", "staging", "viaOwner"])
    }

    @Test("deferred routes and legacy fields are named as the plan places them")
    func deferredAndLegacyPlacement() {
      func entry(_ key: SettingsManager.SettingKey) -> DevControlSettings.Entry {
        DevControlSettings.entry(key)
      }
      #expect(entry(.languageMode).deferredTo == nil)
      #expect(entry(.englishSpelling).deferredTo == nil)
      #expect(entry(.recordingPillDesignWithWords).deferredTo == nil)
      #expect(entry(.recordingPillDesignWithoutWords).deferredTo == nil)
      #expect(entry(.toggleKeyCode).deferredTo == "PR-C")
      #expect(entry(.inputChannelByDeviceUID).deferredTo == "PR-C")
      #expect(entry(.vadSilenceTimeout).kind == .extractedCheck)
      #expect(
        entry(.selectedInputDeviceUID)
          == DevControlSettings.Entry(
            key: .selectedInputDeviceUID, name: "selectedInputDeviceUID", kind: .viaOwner,
            deferredTo: nil, legacy: false))
      #expect(entry(.whisperKitLanguage).legacy == true)
      #expect(entry(.pushToTalkKeyCode).legacy == true)
      #expect(entry(.pushToTalkModifiers).legacy == true)
      #expect(entry(.pushToTalkKeyCode).kind == .staging)
      #expect(entry(.onboardingState).legacy == false)
      #expect(entry(.appearance).name == "appearance")
    }

    // MARK: - Forced writes, every key

    /// One row per key: a changed wire value chosen from the CURRENT property value, the
    /// check that the property now holds it, and the key the setter notifies.
    private struct Row {
      let name: String
      let wire: (SettingsManager) -> String
      let holds: (SettingsManager) -> Bool
      let fires: SettingsManager.SettingKey
    }

    private static func bool(
      _ name: String, _ path: ReferenceWritableKeyPath<SettingsManager, Bool>,
      fires: SettingsManager.SettingKey
    ) -> Row {
      var chosen = false
      return Row(
        name: name,
        wire: { settings in
          chosen = !settings[keyPath: path]
          return chosen ? "true" : "false"
        },
        holds: { $0[keyPath: path] == chosen }, fires: fires)
    }

    private static func choice<E: RawRepresentable & Equatable>(
      _ name: String, _ path: ReferenceWritableKeyPath<SettingsManager, E>, _ cases: [E],
      fires: SettingsManager.SettingKey
    ) -> Row where E.RawValue == String {
      var chosen = cases[0]
      return Row(
        name: name,
        wire: { settings in
          chosen = cases.first { $0 != settings[keyPath: path] } ?? cases[0]
          return "\"\(chosen.rawValue)\""
        },
        holds: { $0[keyPath: path] == chosen }, fires: fires)
    }

    private static func text(
      _ name: String, _ path: ReferenceWritableKeyPath<SettingsManager, String>,
      fires: SettingsManager.SettingKey
    ) -> Row {
      let chosen = "dev-control-\(name)"
      return Row(
        name: name, wire: { _ in "\"\(chosen)\"" }, holds: { $0[keyPath: path] == chosen },
        fires: fires)
    }

    private static func keyCode(
      _ name: String, _ path: ReferenceWritableKeyPath<SettingsManager, UInt16>,
      fires: SettingsManager.SettingKey
    ) -> Row {
      var chosen: UInt16 = 49
      return Row(
        name: name,
        wire: { settings in
          chosen = settings[keyPath: path] == 49 ? 50 : 49
          return "\(chosen)"
        },
        holds: { $0[keyPath: path] == chosen }, fires: fires)
    }

    private static func modifiers(
      _ name: String, _ path: ReferenceWritableKeyPath<SettingsManager, NSEvent.ModifierFlags>,
      fires: SettingsManager.SettingKey
    ) -> Row {
      let a: NSEvent.ModifierFlags = [.command, .option]
      let b: NSEvent.ModifierFlags = [.control, .shift]
      var chosen = a
      return Row(
        name: name,
        wire: { settings in
          chosen = settings[keyPath: path] == a ? b : a
          return "\(chosen.rawValue)"
        },
        holds: { $0[keyPath: path] == chosen }, fires: fires)
    }

    private static let rows: [Row] = [
      choice(
        "selectedBackend", \.selectedBackend, [.parakeet, .whisper], fires: .selectedBackend),
      choice("recordingMode", \.recordingMode, [.pushToTalk, .toggle], fires: .recordingMode),
      choice("llmProvider", \.llmProvider, [.ollama, .openAI], fires: .llmProvider),
      text("llmModel", \.llmModel, fires: .llmModel),
      text("ollamaModel", \.ollamaModel, fires: .ollamaModel),
      Row(
        name: "fileImportLLMProvider", wire: { _ in "\"gemini\"" },
        holds: { $0.fileImportLLMProvider == .gemini }, fires: .fileImportLLMProvider),
      text("fileImportLLMModel", \.fileImportLLMModel, fires: .fileImportLLMModel),
      text("fileImportOllamaModel", \.fileImportOllamaModel, fires: .fileImportOllamaModel),
      choice("s1MiniStyling", \.s1MiniStyling, [.formal, .casual], fires: .s1MiniStyling),
      choice("s1MiniStructure", \.s1MiniStructure, [.lists, .prose], fires: .s1MiniStructure),
      choice("s1MiniContext", \.s1MiniContext, [.email, .general], fires: .s1MiniContext),
      bool("autoCopyToClipboard", \.autoCopyToClipboard, fires: .autoCopyToClipboard),
      bool("hotkeyEnabled", \.hotkeyEnabled, fires: .hotkeyEnabled),
      bool("vadAutoStop", \.vadAutoStop, fires: .vadAutoStop),
      Row(
        name: "vadSilenceTimeout", wire: { _ in "7.25" },
        holds: { $0.vadSilenceTimeout == 7.25 }, fires: .vadSilenceTimeout),
      Row(
        name: "vadSensitivity", wire: { _ in "0.375" },
        holds: { $0.vadSensitivity == Float(0.375) }, fires: .vadSensitivity),
      bool("vadEnergyGate", \.vadEnergyGate, fires: .vadEnergyGate),
      choice(
        "onboardingState", \.onboardingState, [.needsPermissions, .settingUp],
        fires: .onboardingState),
      bool("hasCompletedOnboarding", \.hasCompletedOnboarding, fires: .onboardingState),
      keyCode("cancelKeyCode", \.cancelKeyCode, fires: .cancelKeyCode),
      modifiers("cancelModifiers", \.cancelModifiers, fires: .cancelModifiers),
      keyCode("quickAddKeyCode", \.quickAddKeyCode, fires: .quickAddKeyCode),
      modifiers("quickAddModifiers", \.quickAddModifiers, fires: .quickAddModifiers),
      keyCode("pasteLastKeyCode", \.pasteLastKeyCode, fires: .pasteLastKeyCode),
      modifiers("pasteLastModifiers", \.pasteLastModifiers, fires: .pasteLastModifiers),
      keyCode("copyLastKeyCode", \.copyLastKeyCode, fires: .copyLastKeyCode),
      modifiers("copyLastModifiers", \.copyLastModifiers, fires: .copyLastModifiers),
      keyCode("toggleKeyCode", \.toggleKeyCode, fires: .toggleKeyCode),
      modifiers("toggleModifiers", \.toggleModifiers, fires: .toggleModifiers),
      keyCode("pushToTalkKeyCode", \.pushToTalkKeyCode, fires: .pushToTalkKeyCode),
      modifiers("pushToTalkModifiers", \.pushToTalkModifiers, fires: .pushToTalkModifiers),
      choice(
        "modelUnloadPolicy", \.modelUnloadPolicy, [.tenMinutes, .never], fires: .modelUnloadPolicy),
      bool(
        "restoreClipboardAfterPaste", \.restoreClipboardAfterPaste,
        fires: .restoreClipboardAfterPaste),
      bool(
        "keepDictationsOutOfClipboardHistory", \.keepDictationsOutOfClipboardHistory,
        fires: .keepDictationsOutOfClipboardHistory),
      bool(
        "quickAddClipboardFallback", \.quickAddClipboardFallback, fires: .quickAddClipboardFallback),
      bool("smartInsertion", \.smartInsertion, fires: .smartInsertion),
      bool("escapeRecoveryEnabled", \.escapeRecoveryEnabled, fires: .escapeRecoveryEnabled),
      bool("wordCorrectionEnabled", \.wordCorrectionEnabled, fires: .wordCorrectionEnabled),
      bool("fillerRemovalEnabled", \.fillerRemovalEnabled, fires: .fillerRemovalEnabled),
      bool("emojiFormatterEnabled", \.emojiFormatterEnabled, fires: .emojiFormatterEnabled),
      Row(
        name: "spokenPunctuation",
        wire: { settings in
          let enabled = settings.spokenPunctuation.enabled ? "false" : "true"
          return #"{"enabled":\#(enabled),"startWordOverrides":{"en":"zebra"}}"#
        },
        holds: { $0.spokenPunctuation.startWordOverrides == ["en": "zebra"] },
        fires: .spokenPunctuation),
      bool("casualModeEnabled", \.casualModeEnabled, fires: .casualModeEnabled),
      bool("crashRecoveryEnabled", \.crashRecoveryEnabled, fires: .crashRecoveryEnabled),
      bool("shareUsageMetrics", \.shareUsageMetrics, fires: .shareUsageMetrics),
      bool("sendCrashReports", \.sendCrashReports, fires: .sendCrashReports),
      bool(
        "contactsSyncOnLaunchEnabled", \.contactsSyncOnLaunchEnabled,
        fires: .contactsSyncOnLaunchEnabled),
      bool("isDebugModeEnabled", \.isDebugModeEnabled, fires: .isDebugModeEnabled),
      bool(
        "isDictationAudioArchiveEnabled", \.isDictationAudioArchiveEnabled,
        fires: .isDictationAudioArchiveEnabled),
      choice("debugLogLevel", \.debugLogLevel, [.verbose, .info], fires: .debugLogLevel),
      text("whisperKitLanguage", \.whisperKitLanguage, fires: .whisperKitLanguage),
      Row(
        name: "languageMode", wire: { _ in #"{"mode":"locked","code":"de"}"# },
        holds: { $0.languageMode == .locked("de") }, fires: .languageMode),
      choice("englishSpelling", \.englishSpelling, [.british, .american], fires: .englishSpelling),
      text("selectedInputDeviceUID", \.selectedInputDeviceUID, fires: .selectedInputDeviceUID),
      text(
        "preferredInputDeviceIDOverride", \.preferredInputDeviceIDOverride,
        fires: .preferredInputDeviceIDOverride),
      Row(
        name: "inputChannelByDeviceUID", wire: { _ in #"{"dev-uid":3}"# },
        holds: { $0.inputChannelByDeviceUID == ["dev-uid": 3] }, fires: .inputChannelByDeviceUID),
      bool("useStreamingASR", \.useStreamingASR, fires: .useStreamingASR),
      bool("livePreviewEnabled", \.livePreviewEnabled, fires: .livePreviewEnabled),
      choice(
        "livePreviewEngine", \.livePreviewEngine, [.universal, .apple], fires: .livePreviewEngine),
      choice(
        "warmEnginePolicy", \.warmEnginePolicy, [.seconds30, .off], fires: .warmEnginePolicy),
      choice("appearance", \.appearancePreference, [.dark, .light], fires: .appearance),
      choice(
        "overlayPillPosition", \.overlayPillPosition, [.top, .bottom], fires: .overlayPillPosition),
      choice(
        "recordingPillDesignWithoutWords", \.recordingPillDesignWithoutWords,
        [.levelRail, .classic], fires: .recordingPillDesignWithoutWords),
      choice(
        "recordingPillDesignWithWords", \.recordingPillDesignWithWords, [.readingWell, .classic],
        fires: .recordingPillDesignWithWords),
      bool("showBluetoothTips", \.showBluetoothTips, fires: .showBluetoothTips),
      bool("showInDock", \.showInDock, fires: .showInDock),
      bool("showMenuBarUpdateAlert", \.showMenuBarUpdateAlert, fires: .showMenuBarUpdateAlert),
      bool("playRecordingSounds", \.playRecordingSounds, fires: .playRecordingSounds),
      choice(
        "recordingSoundPairing", \.recordingSoundPairing, [.paperTap, .dustMote],
        fires: .recordingSoundPairing),
      choice(
        "otherAudioWhileDictating", \.otherAudioWhileDictating, [.mute, .nothing],
        fires: .otherAudioWhileDictating),
      bool("learnFromEdits", \.learnFromEdits, fires: .learnFromEdits),
    ]

    /// Keys whose value `SettingsManager.init` replaces on load, mapped to their stored key:
    /// `hotkeyEnabled` is always reset to its default (the toggle was removed), and
    /// `llmModel` is re-canonicalized for the loaded provider. Their persistence is checked
    /// on the stored value instead of through a reload.
    private static let normalizedAtLoad: [String: String] = [
      "hotkeyEnabled": "hotkeyEnabled",
      "llmModel": "llmModel",
    ]

    @Test("a forced write lands on the right property for every one of the 70 keys and persists")
    func forcedWriteEveryKey() throws {
      let declared = try Self.declaredKeyNames()
      #expect(Self.rows.map(\.name) == declared)
      var exercised = 0
      var readChecks = 0
      for row in Self.rows {
        let (_, defaults, settings) = Self.fixture()
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let key = try #require(DevControlSettings.key(named: row.name), "\(row.name)")
        let text = row.wire(settings)
        let outcome = DevControlSettings.forceWrite(key, value: try Self.wire(text), to: settings)
        #expect(outcome == .written(forced: true), "\(row.name) <- \(text)")
        #expect(row.holds(settings), "\(row.name) does not hold \(text)")
        #expect(fired.contains(row.fires), "\(row.name) fired \(fired)")
        let expected = try Self.wire(text)
        let actual = DevControlSettings.read(key, from: settings)
        let actualJSON = try JSONSerialization.data(
          withJSONObject: actual, options: [.fragmentsAllowed, .sortedKeys])
        let expectedJSON = try JSONSerialization.data(
          withJSONObject: expected, options: [.fragmentsAllowed, .sortedKeys])
        #expect(actualJSON == expectedJSON, "\(row.name) read the wrong value")
        readChecks += 1
        if let storedKey = Self.normalizedAtLoad[row.name] {
          // The load path replaces this value on purpose, so read what was stored.
          let stored = defaults.object(forKey: storedKey) as AnyObject?
          #expect(stored?.isEqual(try Self.wire(text)) == true, "\(row.name) did not persist")
        } else {
          let reloaded = SettingsManager(defaults: defaults)
          #expect(row.holds(reloaded), "\(row.name) did not persist")
        }
        exercised += 1
      }
      #expect(exercised == 70)
      #expect(readChecks == 70)
    }

    @Test("hasCompletedOnboarding is the onboarding alias; forcing it moves onboardingState")
    func onboardingAlias() throws {
      let (_, _, settings) = Self.fixture()
      settings.onboardingState = .notStarted
      #expect(
        DevControlSettings.forceWrite(.hasCompletedOnboarding, value: true, to: settings)
          == .written(forced: true))
      #expect(settings.onboardingState == .completed)
      #expect(settings.hasCompletedOnboarding == true)
    }

    @Test("forcing the dictation provider keeps the setter's model canonicalization")
    func providerCanonicalizationSurvivesForce() throws {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      settings.llmModel = "dev-control-stale-model"
      #expect(
        DevControlSettings.forceWrite(.llmProvider, value: "none", to: settings)
          == .written(forced: true))
      #expect(settings.llmProvider == LLMProvider.none)
      #expect(settings.lastLLMProvider == .openAI)

      // Off keeps any model id; a fixed-model provider pins its literal, so the setter's
      // sweep is visible exactly there.
      #expect(
        DevControlSettings.forceWrite(.llmProvider, value: "appleIntelligence", to: settings)
          == .written(forced: true))
      #expect(settings.llmModel == "apple-intelligence")
    }

    // MARK: - Refusals

    /// (key, wire JSON) pairs that must be refused, one per decoder branch.
    private static let refusals: [(SettingsManager.SettingKey, String)] = [
      (.autoCopyToClipboard, "1"),
      (.autoCopyToClipboard, "\"true\""),
      (.llmModel, "5"),
      (.llmModel, "null"),
      (.vadSilenceTimeout, "true"),
      (.vadSilenceTimeout, "\"2\""),
      (.vadSilenceTimeout, "1e30"),
      (.vadSensitivity, "1e300"),
      (.cancelKeyCode, "70000"),
      (.cancelKeyCode, "-1"),
      (.cancelKeyCode, "1.5"),
      (.cancelKeyCode, "true"),
      (.cancelModifiers, "-1"),
      (.cancelModifiers, "false"),
      (.cancelModifiers, "1.5"),
      (.cancelModifiers, "18446744073709551616"),
      (.cancelKeyCode, "65536"),
      (.inputChannelByDeviceUID, #"{"dev":18446744073709551615}"#),
      (.selectedBackend, "\"nope\""),
      (.selectedBackend, "3"),
      (.fileImportLLMProvider, "\"nope\""),
      (.fileImportLLMProvider, "7"),
      (.languageMode, #"{"mode":"locked"}"#),
      (.languageMode, #"{"mode":"auto","code":"de"}"#),
      (.languageMode, #""auto""#),
      (.spokenPunctuation, #"{"enabled":true}"#),
      (.spokenPunctuation, #"{"enabled":1,"startWordOverrides":{}}"#),
      (.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{"en":4}}"#),
      (.inputChannelByDeviceUID, #"{"dev":1.5}"#),
      (.inputChannelByDeviceUID, #"{"dev":"1"}"#),
      (.inputChannelByDeviceUID, #"[1]"#),
    ]

    @Test("a refused value changes neither the property, its stored value, nor fires a change")
    func refusalsChangeNothing() throws {
      var refused = 0
      for (key, text) in Self.refusals {
        let (suite, defaults, settings) = Self.fixture()
        settings.onChange = nil
        let before = DevControlSettings.read(key, from: settings)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let outcome = DevControlSettings.forceWrite(key, value: try Self.wire(text), to: settings)
        guard case .badValue = outcome else {
          Issue.record("\(DevControlSettings.name(key)) accepted \(text): \(outcome)")
          continue
        }
        refused += 1
        let after = DevControlSettings.read(key, from: settings)
        #expect(
          (before as AnyObject).isEqual(after), "\(DevControlSettings.name(key)) moved on \(text)")
        #expect(fired.isEmpty, "\(DevControlSettings.name(key)) fired \(fired) on \(text)")
        let storedAfter = defaults.persistentDomain(forName: suite) as NSDictionary?
        #expect(stored == storedAfter, "\(DevControlSettings.name(key)) persisted on \(text)")
      }
      #expect(refused == Self.refusals.count)
    }

    @Test("integers convert exactly: unsigned modifiers round-trip, signed and 16-bit bounds hold")
    func integerBoundaries() throws {
      let (_, defaults, settings) = Self.fixture()
      #expect(
        DevControlSettings.forceWrite(
          .cancelModifiers, value: try Self.wire("18446744073709551615"), to: settings)
          == .written(forced: true))
      #expect(settings.cancelModifiers.rawValue == UInt.max)
      let read = DevControlSettings.read(.cancelModifiers, from: settings)
      let encoded = try JSONSerialization.data(withJSONObject: read, options: .fragmentsAllowed)
      #expect(String(decoding: encoded, as: UTF8.self) == "18446744073709551615")
      #expect(SettingsManager(defaults: defaults).cancelModifiers.rawValue == UInt.max)

      #expect(
        DevControlSettings.forceWrite(.cancelKeyCode, value: try Self.wire("65535"), to: settings)
          == .written(forced: true))
      #expect(settings.cancelKeyCode == UInt16.max)
      #expect(
        DevControlSettings.forceWrite(
          .inputChannelByDeviceUID, value: try Self.wire(#"{"dev":-9223372036854775808}"#),
          to: settings) == .written(forced: true))
      #expect(settings.inputChannelByDeviceUID == ["dev": Int.min])
    }

    @Test("force assigns a locked language with an empty code; the screen's catalog check is not force's")
    func forcedEmptyLanguageCode() throws {
      let (_, defaults, settings) = Self.fixture()
      #expect(
        DevControlSettings.forceWrite(
          .languageMode, value: try Self.wire(#"{"mode":"locked","code":""}"#), to: settings)
          == .written(forced: true))
      #expect(settings.languageMode == .locked(""))
      let stored = try #require(defaults.data(forKey: "languageMode"))
      #expect(try JSONDecoder().decode(LanguageMode.self, from: stored) == .locked(""))
    }

    @Test("null clears the import provider back to following dictation")
    func nullClearsImportProvider() throws {
      let (_, _, settings) = Self.fixture()
      settings.fileImportLLMProvider = .gemini
      #expect(
        DevControlSettings.forceWrite(
          .fileImportLLMProvider, value: try Self.wire("null"), to: settings)
          == .written(forced: true))
      #expect(settings.fileImportLLMProvider == nil)
    }

    // MARK: - Numeric safety

    @Test(
      "the silence timeout admits representable values outside the screen's range and refuses unsafe ones"
    )
    func silenceTimeoutSafety() throws {
      // Independent of the door: the detector's chunk duration, from its own constants.
      let chunkDuration = 4096.0 / 16_000.0
      #expect(DevControlSettings.silenceTimeoutIsConvertible(0.01))
      #expect(DevControlSettings.silenceTimeoutIsConvertible(120))
      #expect(DevControlSettings.silenceTimeoutIsConvertible(-5))
      #expect(
        DevControlSettings.silenceTimeoutIsConvertible(Double(Int.max / 2) * chunkDuration / 2))
      #expect(DevControlSettings.silenceTimeoutIsConvertible(1e30) == false)
      #expect(DevControlSettings.silenceTimeoutIsConvertible(.infinity) == false)
      #expect(DevControlSettings.silenceTimeoutIsConvertible(.nan) == false)

      let (_, _, settings) = Self.fixture()
      #expect(
        DevControlSettings.forceWrite(.vadSilenceTimeout, value: try Self.wire("0.1"), to: settings)
          == .written(forced: true))
      #expect(settings.vadSilenceTimeout == 0.1)
      #expect(
        DevControlSettings.forceWrite(.vadSilenceTimeout, value: try Self.wire("120"), to: settings)
          == .written(forced: true))
      #expect(settings.vadSilenceTimeout == 120)
    }

    // MARK: - Ordinary writes (chunk 4)

    private static func context(
      catalog: DevControlSettings.ModelCatalog = .init(provider: nil, models: []),
      connected: [String] = [], pill: PillWordsCapability = .available
    ) -> DevControlSettings.WriteContext {
      DevControlSettings.WriteContext(
        modelCatalog: { catalog }, connectedInputUIDs: { connected },
        pillWordsCapability: { pill })
    }

    // MARK: - Pill design (PR-B)

    /// One ordinary pill write against a fresh isolated store, with what it changed.
    private struct PillWrite {
      let outcome: DevControlSettings.SetOutcome
      let withoutWords: RecordingPillDesign
      let withWords: RecordingPillDesign
      let livePreview: Bool
      let fired: [(SettingsManager.SettingKey, Bool)]
      let flagAfter: Bool
    }

    private static func pillWrite(
      _ name: String, _ value: String, capability: PillWordsCapability, force: Bool = false,
      start: (withoutWords: RecordingPillDesign, withWords: RecordingPillDesign, preview: Bool)
        = (.levelRail, .readingWell, false)
    ) throws -> PillWrite {
      let (_, _, settings) = Self.fixture()
      settings.recordingPillDesignWithoutWords = start.withoutWords
      settings.recordingPillDesignWithWords = start.withWords
      settings.livePreviewEnabled = start.preview
      var fired: [(SettingsManager.SettingKey, Bool)] = []
      settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
      let key = try #require(DevControlSettings.key(named: name))
      let outcome = DevControlSettings.write(
        key, value: try Self.wire(value), force: force,
        context: Self.context(pill: capability), to: settings)
      return PillWrite(
        outcome: outcome, withoutWords: settings.recordingPillDesignWithoutWords,
        withWords: settings.recordingPillDesignWithWords,
        livePreview: settings.livePreviewEnabled, fired: fired,
        flagAfter: settings.isDevControlWrite)
    }

    @Test(
      "a words design is offered when words are possible; the coupled pick turns Live Preview on",
      arguments: [PillWordsCapability.available, .previewOff])
    func wordsDesignOfferedWhenPossible(capability: PillWordsCapability) throws {
      let write = try Self.pillWrite(
        "recordingPillDesignWithWords", #""readingWell""#, capability: capability,
        start: (.levelRail, .classic, false))
      #expect(write.outcome == .written(forced: false))
      #expect(write.withWords == .readingWell)
      #expect(write.withoutWords == .levelRail, "the other slot keeps its memory")
      #expect(write.livePreview == true)
      #expect(write.fired.map(\.0).contains(.recordingPillDesignWithWords))
      #expect(write.fired.map(\.0).contains(.livePreviewEnabled))
      #expect(write.fired.allSatisfy { $0.1 }, "every notification is attributed to the door")
      #expect(write.flagAfter == false)
    }

    @Test(
      "a words design is refused where no tap can produce words, and nothing changes",
      arguments: [PillWordsCapability.engineUnsupported, .modelBeingRemoved])
    func wordsDesignRefusedWhenImpossible(capability: PillWordsCapability) throws {
      let write = try Self.pillWrite(
        "recordingPillDesignWithWords", #""readingWell""#, capability: capability,
        start: (.levelRail, .classic, false))
      #expect(write.outcome.code == "checkFailed")
      #expect(write.withWords == .classic && write.withoutWords == .levelRail)
      #expect(write.livePreview == false)
      #expect(write.fired.isEmpty)
      #expect(write.flagAfter == false)
    }

    @Test("a wordless design is offered even without an engine, and turns Live Preview off")
    func wordlessDesignTurnsPreviewOff() throws {
      let write = try Self.pillWrite(
        "recordingPillDesignWithoutWords", #""classic""#, capability: .engineUnsupported,
        start: (.levelRail, .readingWell, true))
      #expect(write.outcome == .written(forced: false))
      #expect(write.withoutWords == .classic)
      #expect(write.withWords == .readingWell, "the other slot keeps its memory")
      #expect(write.livePreview == false)
      #expect(write.fired.allSatisfy { $0.1 })
    }

    @Test("a design from the other picker group is refused before any write; force stages it")
    func otherGroupDesignIsRefusedButForceable() throws {
      for (name, value) in [
        ("recordingPillDesignWithWords", #""classic""#),
        ("recordingPillDesignWithoutWords", #""readingWell""#),
      ] {
        let refused = try Self.pillWrite(name, value, capability: .available)
        #expect(refused.outcome.code == "checkFailed", "\(name)")
        #expect(refused.withoutWords == .levelRail && refused.withWords == .readingWell)
        #expect(refused.fired.isEmpty, "\(name)")
        let forced = try Self.pillWrite(name, value, capability: .engineUnsupported, force: true)
        #expect(forced.outcome == .written(forced: true), "\(name)")
        #expect(forced.livePreview == false, "force assigns only the addressed slot")
        #expect(forced.fired.map(\.0) == [try #require(DevControlSettings.key(named: name))])
      }
    }

    @Test("pill writes refuse a non-design value before any change")
    func pillWriteDecodesFirst() throws {
      for value in [#""nope""#, "3", "null"] {
        let write = try Self.pillWrite("recordingPillDesignWithWords", value, capability: .available)
        #expect(write.outcome.code == "badValue", "\(value)")
        #expect(write.fired.isEmpty)
      }
    }

    // MARK: - Language (PR-B)

    private struct LanguageWrite {
      let outcome: DevControlSettings.SetOutcome
      let mode: LanguageMode
      let spelling: EnglishSpelling
      let fired: [(SettingsManager.SettingKey, Bool)]
      let flagAfter: Bool
    }

    private static func language(
      _ code: String, backend: ASRBackendType = .parakeet,
      start: (LanguageMode, EnglishSpelling) = (.auto, .american)
    ) -> LanguageWrite {
      let (_, _, settings) = Self.fixture()
      settings.selectedBackend = backend
      settings.englishSpelling = start.1
      settings.languageMode = start.0
      var fired: [(SettingsManager.SettingKey, Bool)] = []
      settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
      let outcome = DevControlSettings.setLanguage(code, to: settings)
      return LanguageWrite(
        outcome: outcome, mode: settings.languageMode, spelling: settings.englishSpelling,
        fired: fired, flagAfter: settings.isDevControlWrite)
    }

    @Test("English and English (UK) share the en lock and set their own spelling, spelling first")
    func englishRowsSetLockAndSpelling() {
      let british = Self.language("en-gb", start: (.locked("de"), .american))
      #expect(british.outcome == .written(forced: false))
      #expect(british.mode == .locked("en") && british.spelling == .british)
      #expect(british.fired.map(\.0) == [.englishSpelling, .languageMode])
      #expect(british.fired.allSatisfy { $0.1 } && british.flagAfter == false)

      let american = Self.language("en", start: (.auto, .british))
      #expect(american.mode == .locked("en") && american.spelling == .american)
      #expect(american.fired.allSatisfy { $0.1 })
    }

    @Test("another language and Auto keep the stored spelling")
    func otherRowsKeepSpelling() {
      let german = Self.language("de", backend: .whisper, start: (.auto, .british))
      #expect(german.outcome == .written(forced: false))
      #expect(german.mode == .locked("de") && german.spelling == .british)
      #expect(german.fired.map(\.0) == [.languageMode])
      let auto = Self.language("auto", start: (.locked("en"), .british))
      #expect(auto.mode == .auto && auto.spelling == .british)
      #expect(auto.fired.allSatisfy { $0.1 })
    }

    @Test("the SELECTED engine's picker decides: a code Parakeet does not offer is refused there only")
    func selectedBackendRestriction() throws {
      let offered = try #require(LanguageLockOptions.lockableCodes(for: .parakeet))
      let outside = try #require(
        LanguageCatalog.pickerEntries.first { !offered.contains($0.lockCode) },
        "every picker row is offered on Parakeet; no restriction to test")
      let refused = Self.language(outside.code, backend: .parakeet)
      #expect(refused.outcome.code == "checkFailed", "\(outside.code)")
      #expect(refused.mode == .auto && refused.fired.isEmpty)
      let accepted = Self.language(outside.code, backend: .whisper)
      #expect(accepted.outcome == .written(forced: false))
      #expect(accepted.mode == .locked(outside.lockCode))
    }

    @Test("an unknown or differently spelled code is refused before any write")
    func unknownLanguageCodes() {
      for code in ["xx-yy", "EN", "", "Auto", "english"] {
        let write = Self.language(code)
        #expect(write.outcome.code == "badValue", "\(code)")
        #expect(write.fired.isEmpty, "\(code)")
      }
    }

    @Test("a single-field language write is refused toward language.set; force stages it alone")
    func singleFieldLanguageWrites() throws {
      for (name, value) in [("languageMode", #"{"mode": "locked", "code": "de"}"#),
                            ("englishSpelling", #""british""#)] {
        let (_, _, settings) = Self.fixture()
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let key = try #require(DevControlSettings.key(named: name))
        let refused = DevControlSettings.write(
          key, value: try Self.wire(value), force: false, context: Self.context(), to: settings)
        #expect(refused.code == "checkFailed", "\(name)")
        #expect(refused.message.contains("language.set"), "\(name)")
        #expect(fired.isEmpty, "\(name)")
        let forced = DevControlSettings.write(
          key, value: try Self.wire(value), force: true, context: Self.context(), to: settings)
        #expect(forced == .written(forced: true), "\(name)")
        #expect(fired == [key], "\(name): force writes only that field")
      }
    }

    /// Written here by hand from plan §3.4, not derived from the table.
    private static let deferredNames: Set<String> = [
      "cancelKeyCode", "cancelModifiers", "quickAddKeyCode",
      "quickAddModifiers", "pasteLastKeyCode", "pasteLastModifiers", "copyLastKeyCode",
      "copyLastModifiers", "toggleKeyCode", "toggleModifiers", "fileImportLLMProvider",
      "fileImportLLMModel", "fileImportOllamaModel", "ollamaModel", "vadSilenceTimeout",
      "inputChannelByDeviceUID",
    ]

    @Test("every key has exactly one ordinary route; 16 are not shared yet")
    func routeCounts() {
      var counts: [DevControlSettings.Route: Int] = [:]
      var notYetShared: Set<String> = []
      for key in DevControlSettings.allKeys {
        let route = DevControlSettings.route(key)
        counts[route, default: 0] += 1
        if route == .notYetShared { notYetShared.insert(DevControlSettings.name(key)) }
      }
      #expect(notYetShared == Self.deferredNames)
      #expect(counts[.typed] == 46)
      #expect(counts[.modelCatalog] == 1)
      #expect(counts[.inputDevice] == 2)
      #expect(counts[.spokenPunctuation] == 1)
      #expect(counts[.pillDesign] == 2)
      #expect(counts[.languageCommand] == 2)
      #expect(counts[.notYetShared] == 16)
      #expect(DevControlSettings.route(.llmModel) == .modelCatalog)
      #expect(DevControlSettings.route(.hasCompletedOnboarding) == .typed)
    }

    @Test("the 16 deferred keys refuse an ordinary write without any change, and force still writes them")
    func deferredKeysRefuseOrdinaryWrites() throws {
      var refused = 0
      for row in Self.rows where Self.deferredNames.contains(row.name) {
        let (suite, defaults, settings) = Self.fixture()
        let key = try #require(DevControlSettings.key(named: row.name))
        let text = row.wire(settings)
        let before = DevControlSettings.read(key, from: settings)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let outcome = DevControlSettings.write(
          key, value: try Self.wire(text), force: false, context: Self.context(), to: settings)
        #expect(outcome == .refused(code: "checkNotYetShared", message: outcome.message), "\(row.name)")
        #expect((before as AnyObject).isEqual(DevControlSettings.read(key, from: settings)), "\(row.name)")
        #expect(fired.isEmpty, "\(row.name) fired \(fired)")
        #expect(stored == defaults.persistentDomain(forName: suite) as NSDictionary?, "\(row.name)")
        refused += 1

        let forced = DevControlSettings.write(
          key, value: try Self.wire(text), force: true, context: Self.context(), to: settings)
        #expect(forced == .written(forced: true), "\(row.name)")
        #expect(row.holds(settings), "\(row.name)")
      }
      #expect(refused == 16)
    }

    @Test("every typed-route key takes an ordinary write, reported not forced")
    func typedRouteOrdinaryWrites() throws {
      var written = 0
      for row in Self.rows {
        let key = try #require(DevControlSettings.key(named: row.name))
        guard DevControlSettings.route(key) == .typed else { continue }
        let (_, _, settings) = Self.fixture()
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let text = row.wire(settings)
        let outcome = DevControlSettings.write(
          key, value: try Self.wire(text), force: false, context: Self.context(), to: settings)
        #expect(outcome == .written(forced: false), "\(row.name) <- \(text)")
        #expect(row.holds(settings), "\(row.name)")
        #expect(fired.contains(row.fires), "\(row.name) fired \(fired)")
        written += 1
      }
      #expect(written == 46)
    }

    private static func model(_ id: String, _ provider: LLMProvider, available: Bool = true, remote: Bool = false)
      -> LLMModelInfo
    {
      LLMModelInfo(id: id, displayName: id, provider: provider, isAvailable: available, isRemote: remote)
    }

    @Test("an ordinary llmModel write admits only an offered model from the current provider's catalog")
    func modelAdmission() throws {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      let start = settings.llmModel
      let catalog = DevControlSettings.ModelCatalog(
        provider: .openAI,
        models: [Self.model("gpt-dev-a", .openAI), Self.model("gpt-dev-locked", .openAI, available: false)])
      func write(_ id: Any, _ catalog: DevControlSettings.ModelCatalog) -> DevControlSettings.SetOutcome {
        DevControlSettings.write(
          .llmModel, value: id, force: false, context: Self.context(catalog: catalog), to: settings)
      }

      #expect(write("gpt-dev-locked", catalog).code == "badValue")
      #expect(write("gpt-dev-missing", catalog).code == "badValue")
      #expect(write(7, catalog).code == "badValue")
      #expect(write("gpt-dev-a", .init(provider: .gemini, models: catalog.models)).code == "catalogUnavailable")
      #expect(write("gpt-dev-a", .init(provider: nil, models: [])).code == "catalogUnavailable")
      #expect(write("gpt-dev-a", .init(provider: .openAI, models: [])).code == "catalogUnavailable")
      #expect(settings.llmModel == start)

      #expect(write("gpt-dev-a", catalog) == .written(forced: false))
      #expect(settings.llmModel == "gpt-dev-a")

      settings.llmProvider = .ollama
      let ollama = DevControlSettings.ModelCatalog(
        provider: .ollama,
        models: [Self.model("local-dev:1b", .ollama), Self.model("hosted-dev:cloud", .ollama, remote: true)])
      #expect(write("hosted-dev:cloud", ollama) == .written(forced: false))
      #expect(settings.llmModel == "hosted-dev:cloud")
      #expect(write("local-dev:1b", ollama) == .written(forced: false))

      for fixed in [LLMProvider.appleIntelligence, .egOne, .s1Mini, .none] {
        settings.llmProvider = fixed
        let pinned = settings.llmModel
        #expect(write("anything", .init(provider: fixed, models: [Self.model("anything", fixed)])).code == "badValue")
        #expect(settings.llmModel == pinned)
      }
      // Force still stages any id, catalog or not.
      #expect(
        DevControlSettings.write(
          .llmModel, value: "staged-id", force: true, context: Self.context(), to: settings)
          == .written(forced: true))
    }

    @Test("an ordinary microphone write checks the device is connected, then writes override then selection")
    func inputDeviceRoute() throws {
      for key in [SettingsManager.SettingKey.selectedInputDeviceUID, .preferredInputDeviceIDOverride] {
        let (_, defaults, settings) = Self.fixture()
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let connected = Self.context(connected: ["mic-a"])

        #expect(DevControlSettings.write(key, value: "mic-b", force: false, context: connected, to: settings).code == "checkFailed")
        #expect(fired.isEmpty)
        #expect(DevControlSettings.write(key, value: 4, force: false, context: connected, to: settings).code == "badValue")

        #expect(DevControlSettings.write(key, value: "mic-a", force: false, context: connected, to: settings) == .written(forced: false))
        #expect(fired == [.preferredInputDeviceIDOverride, .selectedInputDeviceUID])
        #expect(settings.preferredInputDeviceIDOverride == "mic-a")
        #expect(settings.selectedInputDeviceUID == "mic-a")
        #expect(defaults.string(forKey: "selectedInputDeviceUID") == "mic-a")

        fired.removeAll()
        #expect(DevControlSettings.write(key, value: "", force: false, context: connected, to: settings) == .written(forced: false))
        #expect(fired == [.preferredInputDeviceIDOverride, .selectedInputDeviceUID])
        #expect(settings.preferredInputDeviceIDOverride == "")
        #expect(settings.selectedInputDeviceUID == "")

        // Force stages a disconnected device on the addressed field only.
        #expect(DevControlSettings.write(key, value: "mic-z", force: true, context: connected, to: settings) == .written(forced: true))
      }
    }

    @Test("an ordinary spoken-punctuation write validates every start word first, then commits and resets through the owners")
    func spokenPunctuationRoute() throws {
      let (_, _, settings) = Self.fixture()
      settings.spokenPunctuation = SpokenPunctuationSettings(enabled: false, startWordOverrides: [:])
      let german = try #require(SpokenPunctuationRules.startWordDefault(for: "de"))
      try #require(german.isEmpty == false, "German has a default start word")
      // A non-default German override, set through the owner (not through the door).
      #expect(settings.commitSpokenPunctuationStartWord("zebra", language: "de") == .accepted("zebra"))
      try #require(settings.spokenPunctuation.startWordOverrides == ["de": "zebra"])

      func write(_ json: String) throws -> DevControlSettings.SetOutcome {
        DevControlSettings.write(
          .spokenPunctuation, value: try Self.wire(json), force: false, context: Self.context(),
          to: settings)
      }
      // One bad entry refuses the whole request: nothing changes, not even `enabled`.
      let bad = try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin","de":"two words"}}"#)
      #expect(bad.code == "checkFailed")
      #expect(settings.spokenPunctuation == SpokenPunctuationSettings(enabled: false, startWordOverrides: ["de": "zebra"]))
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"en-US":"zebra"}}"#).code == "checkFailed")
      #expect(try write(#"{"enabled":true}"#).code == "badValue")

      // A good request: enable, a new French word, German absent (reset to its default).
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin"}}"#) == .written(forced: false))
      #expect(settings.spokenPunctuation.enabled == true)
      #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "lapin"])

      // The owner's normalization still applies: German's own default stores no override.
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin","de":"\#(german)"}}"#) == .written(forced: false))
      #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "lapin"])
    }

    @Test("an ordinary spoken-punctuation write refuses a stored map holding a key only force could stage")
    func spokenPunctuationRefusesStagedRegionalKey() throws {
      let (suite, defaults, settings) = Self.fixture()
      #expect(
        DevControlSettings.forceWrite(
          .spokenPunctuation,
          value: try Self.wire(#"{"enabled":false,"startWordOverrides":{"de-DE":"zebra"}}"#),
          to: settings) == .written(forced: true))
      let before = settings.spokenPunctuation
      let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
      var fired: [SettingsManager.SettingKey] = []
      settings.onChange = { fired.append($0) }

      let outcome = DevControlSettings.write(
        .spokenPunctuation, value: try Self.wire(#"{"enabled":true,"startWordOverrides":{}}"#),
        force: false, context: Self.context(), to: settings)
      #expect(outcome.code == "checkFailed")
      #expect(settings.spokenPunctuation == before)
      #expect(fired.isEmpty)
      #expect(stored == defaults.persistentDomain(forName: suite) as NSDictionary?)
    }

    @Test("every mutation route runs with the door's attribution flag set, then restores it")
    func everyRouteIsAttributed() throws {
      let (_, _, settings) = Self.fixture()
      settings.onboardingState = .completed
      settings.llmProvider = .openAI
      var seen: [(SettingsManager.SettingKey, Bool)] = []
      settings.onChange = { seen.append(($0, settings.isDevControlWrite)) }
      let catalog = DevControlSettings.ModelCatalog(
        provider: .openAI, models: [Self.model("gpt-dev-a", .openAI)])
      let context = Self.context(catalog: catalog, connected: ["mic-a"])
      func write(_ key: SettingsManager.SettingKey, _ json: String, force: Bool = false) throws {
        let outcome = DevControlSettings.write(
          key, value: try Self.wire(json), force: force, context: context, to: settings)
        #expect(outcome == .written(forced: force), "\(DevControlSettings.name(key))")
      }
      try write(.fillerRemovalEnabled, settings.fillerRemovalEnabled ? "false" : "true")
      try write(.llmModel, #""gpt-dev-a""#)
      try write(.selectedInputDeviceUID, #""mic-a""#)
      try write(.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{"fr":"lapin"}}"#)
      try write(.hasCompletedOnboarding, "false")
      try write(.toggleKeyCode, "33", force: true)
      try write(.llmProvider, #""none""#, force: true)

      let keys = Set(seen.map(\.0))
      for key in [SettingsManager.SettingKey.fillerRemovalEnabled, .llmModel,
        .preferredInputDeviceIDOverride, .selectedInputDeviceUID, .spokenPunctuation,
        .onboardingState, .toggleKeyCode, .llmProvider]
      {
        #expect(keys.contains(key), "\(DevControlSettings.name(key)) never notified")
      }
      #expect(seen.allSatisfy { $0.1 }, "unattributed: \(seen.filter { !$0.1 }.map(\.0))")
      #expect(settings.isDevControlWrite == false)
    }

    @Test("an ordinary hasCompletedOnboarding write goes through the alias setter")
    func onboardingAliasOrdinaryWrite() throws {
      let (_, _, settings) = Self.fixture()
      settings.onboardingState = .notStarted
      #expect(
        DevControlSettings.write(
          .hasCompletedOnboarding, value: true, force: false, context: Self.context(), to: settings)
          == .written(forced: false))
      #expect(settings.onboardingState == .completed)
    }
  }
#endif
