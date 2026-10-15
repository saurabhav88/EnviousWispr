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
      #expect(rows.compactMap { $0["name"] as? String } == declared)
      for row in rows {
        #expect(row["value"] != nil)
        #expect(JSONSerialization.isValidJSONObject([row]))
      }

      var kinds: [String: [String]] = [:]
      for row in rows {
        kinds[row["kind"] as? String ?? "?", default: []].append(row["name"] as? String ?? "?")
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
      #expect(entry(.languageMode).deferredTo == "PR-B")
      #expect(entry(.englishSpelling).deferredTo == "PR-B")
      #expect(entry(.recordingPillDesignWithWords).deferredTo == "PR-B")
      #expect(entry(.recordingPillDesignWithoutWords).deferredTo == "PR-B")
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
        "selectedBackend", \.selectedBackend, [.parakeet, .whisperKit], fires: .selectedBackend),
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
  }
#endif
