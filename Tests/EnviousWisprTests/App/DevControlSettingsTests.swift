#if DEBUG
  import AppKit
  import EnviousWisprCore
  import EnviousWisprLLM
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
      let tree = CachedSwiftParser.parse(source: source)
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

    @Test("the table lists exactly the 84 declared keys, once each, in four kinds")
    func catalogMatchesDeclaration() throws {
      let declared = try Self.declaredKeyNames()
      #expect(declared.count == 84)
      #expect(Set(declared).count == declared.count)
      let listed = DevControlSettings.allKeys.map(DevControlSettings.name)
      #expect(listed == declared)
      for name in declared {
        #expect(DevControlSettings.key(named: name).map(DevControlSettings.name) == name)
      }
      #expect(DevControlSettings.key(named: "notASetting") == nil)

      let (_, _, settings) = Self.fixture()
      let rows = DevControlSettings.catalog(settings)
      #expect(rows.count == 84)
      #expect(rows.compactMap { $0["key"] as? String } == declared)
      for row in rows {
        #expect(row["value"] != nil)
        #expect(JSONSerialization.isValidJSONObject([row]))
      }

      var kinds: [String: [String]] = [:]
      for row in rows {
        kinds[row["kind"] as? String ?? "?", default: []].append(row["key"] as? String ?? "?")
      }
      #expect(kinds["direct"]?.count == 52)
      #expect(kinds["viaOwner"]?.count == 8)
      #expect(kinds["extractedCheck"]?.count == 16)
      #expect(kinds["staging"]?.count == 8)
      #expect(kinds.keys.sorted() == ["direct", "extractedCheck", "staging", "viaOwner"])
    }

    @Test("checked kinds and legacy fields are named as the plan places them")
    func kindAndLegacyPlacement() {
      func entry(_ key: SettingsManager.SettingKey) -> DevControlSettings.Entry {
        DevControlSettings.entry(key)
      }
      #expect(entry(.toggleKeyCode).kind == .extractedCheck)
      #expect(entry(.copyLastModifiers).kind == .extractedCheck)
      #expect(entry(.inputChannelByDeviceUID).kind == .extractedCheck)
      #expect(entry(.vadSilenceTimeout).kind == .extractedCheck)
      #expect(
        entry(.selectedInputDeviceUID)
          == DevControlSettings.Entry(
            key: .selectedInputDeviceUID, name: "selectedInputDeviceUID", kind: .viaOwner,
            legacy: false))
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
      // #3972: EnviousMeet's call-sound choice and its explainer acknowledgement.
      bool("meetingCaptureCallSound", \.meetingCaptureCallSound, fires: .meetingCaptureCallSound),
      bool(
        "meetingCallSoundExplained", \.meetingCallSoundExplained,
        fires: .meetingCallSoundExplained),
      bool("meetingWriteSummary", \.meetingWriteSummary, fires: .meetingWriteSummary),
      // #4069: "Turn off dictation during meetings".
      bool(
        "meetingTurnsOffDictation", \.meetingTurnsOffDictation,
        fires: .meetingTurnsOffDictation),
      // #4017: EnviousMeet's setup lock and calendar names.
      bool(
        "meetingOnboardingComplete", \.meetingOnboardingComplete,
        fires: .meetingOnboardingComplete),
      bool(
        "meetingUseCalendarForNames", \.meetingUseCalendarForNames,
        fires: .meetingUseCalendarForNames),
      text("meetingCallDetection", \.meetingCallDetection, fires: .meetingCallDetection),
      text("meetingCallAppsOff", \.meetingCallAppsOff, fires: .meetingCallAppsOff),
      text("meetingCallNoCounts", \.meetingCallNoCounts, fires: .meetingCallNoCounts),
      bool(
        "meetingCallFirstTipShown", \.meetingCallFirstTipShown, fires: .meetingCallFirstTipShown),
      // #3973: EnviousMeet's own language (decision 16); dictation's stays as it was.
      Row(
        name: "meetingLanguageMode", wire: { _ in #"{"mode":"locked","code":"de"}"# },
        holds: { $0.meetingLanguageMode == .locked("de") && $0.languageMode == .auto },
        fires: .meetingLanguageMode),
      Row(
        name: "meetingTranscriptEngine", wire: { _ in "\"whisper\"" },
        holds: { $0.meetingTranscriptEngine == .whisper }, fires: .meetingTranscriptEngine),
      // #4105: meeting live words engine and language; null clears either.
      Row(
        name: "meetingLiveWordsEngine", wire: { _ in "\"universal\"" },
        holds: { $0.meetingLiveWordsEngine == .universal }, fires: .meetingLiveWordsEngine),
      Row(
        name: "meetingLiveWordsLanguage", wire: { _ in "\"fr-CA\"" },
        holds: { $0.meetingLiveWordsLanguage == "fr-CA" }, fires: .meetingLiveWordsLanguage),
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
          return #"{"enabled":\#(enabled),"startWordOverrides":{"en":"zebra"},"englishPeriodWord":true}"#
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

    @Test("a forced write lands on the right property for every one of the 84 keys and persists")
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
      #expect(exercised == 84)
      #expect(readChecks == 84)
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
      // #4216: the old two-key shape is refused, never read as "period switch ON".
      (.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{}}"#),
      (.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{},"englishPeriodWord":"no"}"#),
      (.spokenPunctuation, #"{"enabled":1,"startWordOverrides":{},"englishPeriodWord":true}"#),
      (.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{"en":4},"englishPeriodWord":true}"#),
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
      connected: [String] = [], pill: PillWordsCapability = .available,
      channels: [String: Int] = [:]
    ) -> DevControlSettings.WriteContext {
      DevControlSettings.WriteContext(
        modelCatalog: { catalog }, loadCachedModelCatalog: { _, _ in },
        connectedInputUIDs: { connected },
        inputChannelCounts: { channels },
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

    // MARK: - Silence timeout (PR-C)

    @Test("an ordinary silence-timeout write takes only the slider's quarter-second values")
    func silenceTimeoutTakesSliderValues() throws {
      let offered = ["0.5", "0.75", "1.0", "1.25", "1.5", "1.75", "2.0", "2.25", "2.5", "2.75", "3.0"]
      for text in offered {
        let (_, _, settings) = Self.fixture()
        settings.vadSilenceTimeout = text == "0.5" ? 3.0 : 0.5
        var fired: [(SettingsManager.SettingKey, Bool)] = []
        settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
        let outcome = DevControlSettings.write(
          .vadSilenceTimeout, value: try Self.wire(text), force: false, context: Self.context(),
          to: settings)
        #expect(outcome == .written(forced: false), "\(text)")
        #expect(settings.vadSilenceTimeout == Double(text), "\(text)")
        #expect(fired.map(\.0) == [.vadSilenceTimeout] && fired.allSatisfy { $0.1 }, "\(text)")
        #expect(settings.isDevControlWrite == false)
      }
    }

    @Test("off-step or out-of-range values are checkFailed, wrong types badValue, nothing written")
    func silenceTimeoutRefusals() throws {
      for (text, code) in [
        ("0.25", "checkFailed"), ("3.25", "checkFailed"), ("1.1", "checkFailed"),
        ("0.6", "checkFailed"), ("120", "checkFailed"), ("1e30", "badValue"), ("true", "badValue"),
        ("\"2\"", "badValue"), ("null", "badValue"),
      ] {
        let (suite, defaults, settings) = Self.fixture()
        let before = settings.vadSilenceTimeout
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        var fired: [SettingsManager.SettingKey] = []
        settings.onChange = { fired.append($0) }
        let outcome = DevControlSettings.write(
          .vadSilenceTimeout, value: try Self.wire(text), force: false, context: Self.context(),
          to: settings)
        #expect(outcome.code == code, "\(text)")
        #expect(settings.vadSilenceTimeout == before, "\(text)")
        #expect(fired.isEmpty, "\(text)")
        #expect(stored == defaults.persistentDomain(forName: suite) as NSDictionary?, "\(text)")
      }
    }

    /// Written here by hand from plan §3.4, not derived from the table.
    private static let shortcutNames: Set<String> = [
      "cancelKeyCode", "cancelModifiers", "quickAddKeyCode", "quickAddModifiers",
      "pasteLastKeyCode", "pasteLastModifiers", "copyLastKeyCode", "copyLastModifiers",
      "toggleKeyCode", "toggleModifiers",
    ]

    @Test("every key has exactly one ordinary route; the 10 shortcut fields are checked whole")
    func routeCounts() {
      var counts: [DevControlSettings.Route: Int] = [:]
      var shortcutFields: Set<String> = []
      for key in DevControlSettings.allKeys {
        let route = DevControlSettings.route(key)
        counts[route, default: 0] += 1
        if route == .shortcutField { shortcutFields.insert(DevControlSettings.name(key)) }
      }
      #expect(shortcutFields == Self.shortcutNames)
      #expect(counts[.typed] == 60)
      #expect(counts[.modelCatalog] == 1)
      #expect(counts[.inputDevice] == 2)
      #expect(counts[.spokenPunctuation] == 1)
      #expect(counts[.pillDesign] == 2)
      #expect(counts[.languageCommand] == 2)
      #expect(counts[.silenceTimeout] == 1)
      #expect(counts[.importProvider] == 1)
      #expect(counts[.importModel] == 1)
      #expect(counts[.ollamaModel] == 2)
      #expect(counts[.channelCommand] == 1)
      #expect(counts[.shortcutField] == 10)
      #expect(counts.values.reduce(0, +) == 84)
      #expect(DevControlSettings.route(.llmModel) == .modelCatalog)
      #expect(DevControlSettings.route(.hasCompletedOnboarding) == .typed)
    }

    @Test("a typed route is exactly a direct or staging row, or the onboarding alias")
    func typedRouteMatchesKind() {
      for key in DevControlSettings.allKeys where key != .llmModel {
        let kind = DevControlSettings.entry(key).kind
        let expected = kind == .direct || kind == .staging || key == .hasCompletedOnboarding
        #expect(
          (DevControlSettings.route(key) == .typed) == expected, "\(DevControlSettings.name(key))")
      }
    }

    @Test("each shortcut field names its own row and half, matching the screen's fields")
    func shortcutFieldsMatchTheScreen() throws {
      let (_, _, settings) = Self.fixture()
      var seen = 0
      for key in DevControlSettings.allKeys {
        guard let field = DevControlSettings.shortcutField(key) else {
          #expect(!Self.shortcutNames.contains(DevControlSettings.name(key)))
          continue
        }
        seen += 1
        // Written through the screen's field path, read back through the door's table.
        if field.isKeyCode {
          settings[keyPath: ShortcutSettings.keyCodeField(for: field.role)] = 4000 + UInt16(seen)
          #expect(DevControlSettings.read(key, from: settings) as? Int == 4000 + seen)
        } else {
          let flags = NSEvent.ModifierFlags(rawValue: UInt(1 << (16 + seen)))
          settings[keyPath: ShortcutSettings.modifiersField(for: field.role)] = flags
          #expect(DevControlSettings.read(key, from: settings) as? UInt == flags.rawValue)
        }
      }
      #expect(seen == 10)
    }

    @Test("all five shortcuts go through the screen's check and save, with each role's own pair")
    func setShortcutForEveryRole() {
      let (_, _, settings) = Self.fixture()
      let codes: [ShortcutRole: UInt16] = [
        .record: 122, .cancel: 120, .quickAdd: 99, .pasteLast: 118, .copyLast: 96,
      ]
      for role in ShortcutRole.allCases {
        var fired: [(SettingsManager.SettingKey, Bool)] = []
        settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
        let outcome = DevControlSettings.setShortcut(
          role, keyCode: codes[role]!, modifiers: [.control, .option], to: settings)
        #expect(outcome == .written(forced: false), "\(role)")
        #expect(fired.count == 2 && fired.allSatisfy(\.1), "\(role): \(fired)")
        #expect(settings.isDevControlWrite == false)
      }
      #expect(settings.toggleKeyCode == 122 && settings.toggleModifiers == [.control, .option])
      #expect(settings.cancelKeyCode == 120)
      #expect(settings.quickAddKeyCode == 99)
      #expect(settings.pasteLastKeyCode == 118)
      #expect(settings.copyLastKeyCode == 96 && settings.copyLastModifiers == [.control, .option])
    }

    @Test("a refused shortcut changes nothing and fires nothing")
    func refusedShortcutsChangeNothing() {
      for (role, keyCode, modifiers): (ShortcutRole, UInt16, NSEvent.ModifierFlags) in [
        (.quickAdd, 8, [.command]),  // Command-C
        (.quickAdd, 9, [.control, .command]),  // Paste Last's default
        (.quickAdd, 40, [.option]),  // needs Option, which recording uses alone
        (.record, 53, []),  // Cancel's Escape
      ] {
        let (suite, defaults, settings) = Self.fixture()
        let before = settings.shortcutBindings
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        var fired = 0
        settings.onChange = { _ in fired += 1 }
        let outcome = DevControlSettings.setShortcut(
          role, keyCode: keyCode, modifiers: modifiers, to: settings)
        #expect(outcome.code == "checkFailed", "\(role) \(keyCode)")
        #expect(settings.shortcutBindings == before)
        #expect(fired == 0)
        #expect(stored == defaults.persistentDomain(forName: suite) as NSDictionary?)
      }
    }

    @Test("checked shortcuts refuse out-of-range codes without saving or notifying",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/3807"))
    func checkedShortcutKeyRange() {
      let cases: [(ShortcutRole, UInt16)] = ShortcutRole.allCases.map { ($0, 128) }
        + [(.record, UInt16.max)]
      for (role, keyCode) in cases {
        let (suite, defaults, settings) = Self.fixture()
        let before = settings.shortcutBindings
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        var fired = 0
        settings.onChange = { _ in fired += 1 }
        let result = DevControlSettings.setShortcut(
          role, keyCode: keyCode, modifiers: [.control, .shift], to: settings)
        #expect(result.code == "badValue", "\(role) key \(keyCode) must be refused")
        #expect(settings.shortcutBindings == before)
        #expect(defaults.persistentDomain(forName: suite) as NSDictionary? == stored)
        #expect(fired == 0)
        #expect(settings.isDevControlWrite == false)
      }
      // Admission boundaries, not a claim that every number corresponds to a physical key.
      for code: UInt16 in [0, 127] {
        let (_, _, settings) = Self.fixture()
        #expect(DevControlSettings.setShortcut(
          .record, keyCode: code, modifiers: [.control, .shift], to: settings)
          == .written(forced: false))
        #expect(settings.toggleKeyCode == code)
      }
    }

    @Test("individual shortcut fields validate the saved companion and restore attribution",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/3807"))
    func checkedShortcutFieldsPreserveState() throws {
      for priorAttribution in [false, true] {
        let (suite, defaults, settings) = Self.fixture()
        for (key, value): (SettingsManager.SettingKey, String) in [
          (.toggleKeyCode, "128"), (.toggleModifiers, "262144"),
        ] {
          // The modifiers-only route must validate this saved key as part of its candidate.
          if key == .toggleModifiers { settings.toggleKeyCode = UInt16.max }
          settings.isDevControlWrite = priorAttribution
          let before = settings.shortcutBindings
          let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
          var fired = 0
          settings.onChange = { _ in fired += 1 }
          let result = DevControlSettings.write(
            key, value: try Self.wire(value), force: false, context: Self.context(), to: settings)
          #expect(result.code == "badValue", "\(key) must reject the complete candidate")
          #expect(settings.shortcutBindings == before)
          #expect(defaults.persistentDomain(forName: suite) as NSDictionary? == stored)
          #expect(fired == 0)
          #expect(settings.isDevControlWrite == priorAttribution)
        }
      }
    }

    @Test("force can stage a high key and a checked compound write can repair it",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/3807"))
    func forcedShortcutCanBeRepaired() throws {
      let (_, defaults, settings) = Self.fixture()
      #expect(DevControlSettings.write(
        .toggleKeyCode, value: try Self.wire("65535"), force: true,
        context: Self.context(), to: settings) == .written(forced: true))
      #expect(settings.toggleKeyCode == UInt16.max)
      #expect(SettingsManager(defaults: defaults).toggleKeyCode == UInt16.max)
      #expect(DevControlSettings.setShortcut(
        .record, keyCode: 0, modifiers: [.control, .shift], to: settings)
        == .written(forced: false))
      #expect(settings.toggleKeyCode == 0 && settings.toggleModifiers == [.control, .shift])
    }

    @Test("numbers are stored the way the screen stores the key")
    func setShortcutNormalizes() {
      let (_, _, settings) = Self.fixture()
      // A lone Right Command with its own flag set stores no modifiers.
      #expect(
        DevControlSettings.setShortcut(
          .record, keyCode: ModifierKeyCodes.rightCommand, modifiers: [.command], to: settings)
          == .written(forced: false))
      #expect(settings.toggleKeyCode == ModifierKeyCodes.rightCommand && settings.toggleModifiers == [])
      // A chord keeps only Command, Option, Control and Shift.
      #expect(
        DevControlSettings.setShortcut(
          .quickAdd, keyCode: 40, modifiers: [.control, .shift, .capsLock, .function],
          to: settings) == .written(forced: false))
      #expect(settings.quickAddKeyCode == 40 && settings.quickAddModifiers == [.control, .shift])
    }

    @Test("Globe saved from the door leaves the one-time Globe explanation for the screen")
    func doorGlobeLeavesTheClaim() {
      let (_, _, settings) = Self.fixture()
      #expect(
        DevControlSettings.setShortcut(
          .record, keyCode: ModifierKeyCodes.globe, modifiers: [], to: settings)
          == .written(forced: false))
      #expect(settings.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe))
    }

    @Test("one field on its own is checked whole with the other half as saved")
    func singleFieldIsCheckedWhole() throws {
      let (_, _, settings) = Self.fixture()
      func write(_ key: SettingsManager.SettingKey, _ json: String) throws
        -> DevControlSettings.SetOutcome
      {
        DevControlSettings.write(
          key, value: try Self.wire(json), force: false, context: Self.context(), to: settings)
      }
      // Copy Last is Control-Command-C. Its key code alone to V makes Paste Last's shortcut.
      #expect(try write(.copyLastKeyCode, "9").code == "checkFailed")
      #expect(settings.copyLastKeyCode == 8)
      // Its modifiers alone to Control-Shift make Control-Shift-C, which is free.
      let controlShift = NSEvent.ModifierFlags([.control, .shift]).rawValue
      #expect(try write(.copyLastModifiers, "\(controlShift)") == .written(forced: false))
      #expect(settings.copyLastKeyCode == 8 && settings.copyLastModifiers == [.control, .shift])
      // Then the key code to V is Control-Shift-V, also free.
      #expect(try write(.copyLastKeyCode, "9") == .written(forced: false))
      #expect(settings.copyLastKeyCode == 9)
      #expect(try write(.toggleKeyCode, "1.5").code == "badValue")
      #expect(try write(.toggleModifiers, "true").code == "badValue")
    }

    @Test("the whole shortcut can change where its first half alone would clash")
    func compoundChangeSucceedsWhereAHalfWouldNot() throws {
      let (_, _, settings) = Self.fixture()
      // Control-Shift-V for Copy Last: the key code first would make Paste Last's shortcut.
      #expect(
        DevControlSettings.write(
          .copyLastKeyCode, value: try Self.wire("9"), force: false, context: Self.context(),
          to: settings).code == "checkFailed")
      #expect(
        DevControlSettings.setShortcut(
          .copyLast, keyCode: 9, modifiers: [.control, .shift], to: settings)
          == .written(forced: false))
      #expect(settings.copyLastKeyCode == 9 && settings.copyLastModifiers == [.control, .shift])
      #expect(settings.pasteLastKeyCode == 9 && settings.pasteLastModifiers == [.control, .command])
    }

    @Test("force still stages a clashing or unusual shortcut field as given")
    func forceStagesShortcutFields() throws {
      let (_, _, settings) = Self.fixture()
      #expect(
        DevControlSettings.write(
          .toggleKeyCode, value: try Self.wire("53"), force: true, context: Self.context(),
          to: settings) == .written(forced: true))
      #expect(settings.toggleKeyCode == 53, "Cancel's key, staged")
      #expect(
        DevControlSettings.write(
          .toggleModifiers, value: try Self.wire("\(NSEvent.ModifierFlags.capsLock.rawValue)"),
          force: true, context: Self.context(), to: settings) == .written(forced: true))
      #expect(settings.toggleModifiers == .capsLock, "not narrowed")
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
      #expect(written == 60)
    }

    private static func model(_ id: String, _ provider: LLMProvider, available: Bool = true, remote: Bool = false)
      -> LLMModelInfo
    {
      LLMModelInfo(id: id, displayName: id, provider: provider, isAvailable: available, isRemote: remote)
    }

    @Test("the import provider: a pick seeds then overrides, null follows dictation, none is its own choice")
    func importProviderRoute() throws {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      settings.llmModel = "gpt-dictation"
      settings.ollamaModel = "llama-dictation"
      var fired: [(SettingsManager.SettingKey, Bool)] = []
      settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
      func write(_ text: String) throws -> DevControlSettings.SetOutcome {
        DevControlSettings.write(
          .fileImportLLMProvider, value: try Self.wire(text), force: false,
          context: Self.context(), to: settings)
      }
      #expect(try write(#""gemini""#) == .written(forced: false))
      #expect(settings.fileImportLLMProvider == .gemini)
      #expect(settings.fileImportOllamaModel == "llama-dictation", "seeded before the override")
      #expect(fired.allSatisfy { $0.1 } && settings.isDevControlWrite == false)
      #expect(try write(#""none""#) == .written(forced: false))
      #expect(settings.fileImportLLMProvider == LLMProvider.none)
      #expect(try write("null") == .written(forced: false))
      #expect(settings.fileImportLLMProvider == nil, "back to following dictation")
      fired.removeAll()
      for bad in [#""bogus""#, "3", "true"] {
        #expect(try write(bad).code == "badValue", "\(bad)")
      }
      #expect(fired.isEmpty && settings.fileImportLLMProvider == nil)
      #expect(settings.llmProvider == .openAI && settings.llmModel == "gpt-dictation")
    }

    @Test("the import model goes through the import provider's catalog and creates the override")
    func importModelRoute() throws {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      settings.llmModel = "gpt-dictation"
      let catalog = DevControlSettings.ModelCatalog(
        provider: .openAI, models: [Self.model("gpt-import", .openAI)])
      func write(_ id: Any, _ catalog: DevControlSettings.ModelCatalog) -> DevControlSettings.SetOutcome {
        DevControlSettings.write(
          .fileImportLLMModel, value: id, force: false, context: Self.context(catalog: catalog),
          to: settings)
      }
      #expect(write("gpt-missing", catalog).code == "badValue")
      #expect(write("gpt-import", .init(provider: .gemini, models: catalog.models)).code == "catalogUnavailable")
      #expect(write(5, catalog).code == "badValue")
      #expect(settings.fileImportLLMProvider == nil, "a refusal never creates the override")
      #expect(write("gpt-import", catalog) == .written(forced: false))
      #expect(settings.fileImportLLMProvider == .openAI)
      #expect(settings.fileImportLLMModel == "gpt-import")
      #expect(settings.llmModel == "gpt-dictation")
    }

    @Test("an Ollama model write needs that surface's provider to be Ollama, then takes the menu's path")
    func ollamaModelRoutes() throws {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      let ollama = DevControlSettings.ModelCatalog(
        provider: .ollama, models: [Self.model("local-dev:1b", .ollama)])
      func write(_ key: SettingsManager.SettingKey, _ id: String) -> DevControlSettings.SetOutcome {
        DevControlSettings.write(
          key, value: id, force: false, context: Self.context(catalog: ollama), to: settings)
      }
      let before = (settings.ollamaModel, settings.llmModel, settings.fileImportOllamaModel)
      #expect(write(.ollamaModel, "local-dev:1b").code == "checkFailed")
      #expect(write(.fileImportOllamaModel, "local-dev:1b").code == "checkFailed")
      #expect((settings.ollamaModel, settings.llmModel, settings.fileImportOllamaModel) == before)
      #expect(settings.fileImportLLMProvider == nil)

      settings.llmProvider = .ollama
      #expect(write(.ollamaModel, "local-dev:1b") == .written(forced: false))
      #expect(settings.llmModel == "local-dev:1b", "the menu's own write; sync mirrors it live")
      #expect(write(.ollamaModel, "missing:1b").code == "badValue")

      settings.llmProvider = .openAI
      settings.fileImportLLMProvider = .ollama
      #expect(write(.fileImportOllamaModel, "local-dev:1b") == .written(forced: false))
      #expect(settings.fileImportLLMModel == "local-dev:1b")
      #expect(settings.llmProvider == .openAI)
    }

    @Test("channel.set takes an input a connected multi-input device has, and only that device's")
    func channelSet() {
      let (_, _, settings) = Self.fixture()
      settings.inputChannelByDeviceUID = ["mic-b": 2]
      let context = Self.context(channels: ["mic-a": 4, "mic-b": 4, "mono": 1])
      var fired: [(SettingsManager.SettingKey, Bool)] = []
      settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
      #expect(DevControlSettings.setChannel(3, for: "mic-a", context: context, to: settings)
        == .written(forced: false))
      #expect(DevControlSettings.setChannel(0, for: "mic-a", context: context, to: settings)
        == .written(forced: false))
      #expect(settings.inputChannelByDeviceUID == ["mic-a": 0, "mic-b": 2])
      #expect(fired.map(\.0) == [.inputChannelByDeviceUID, .inputChannelByDeviceUID])
      #expect(fired.allSatisfy { $0.1 } && settings.isDevControlWrite == false)
      fired.removeAll()
      for (channel, uid) in [(4, "mic-a"), (-1, "mic-a"), (0, "mono"), (1, "gone"), (0, "")] {
        #expect(
          DevControlSettings.setChannel(channel, for: uid, context: context, to: settings).code
            == "checkFailed", "\(uid) \(channel)")
      }
      #expect(settings.inputChannelByDeviceUID == ["mic-a": 0, "mic-b": 2])
      #expect(fired.isEmpty)
    }

    @Test("a whole-map channel write is refused toward channel.set; force stages an invalid index")
    func channelMapWrites() throws {
      let (_, _, settings) = Self.fixture()
      let map = #"{"mic-a": 9}"#
      let refused = DevControlSettings.write(
        .inputChannelByDeviceUID, value: try Self.wire(map), force: false,
        context: Self.context(channels: ["mic-a": 2]), to: settings)
      #expect(refused.code == "checkFailed" && refused.message.contains("channel.set"))
      #expect(settings.inputChannelByDeviceUID.isEmpty)
      let forced = DevControlSettings.write(
        .inputChannelByDeviceUID, value: try Self.wire(map), force: true,
        context: Self.context(channels: ["mic-a": 2]), to: settings)
      #expect(forced == .written(forced: true))
      #expect(settings.inputChannelByDeviceUID == ["mic-a": 9])
      #expect(
        InputChannelSettings.selection(
          for: "mic-a", inputChannelCount: 2, in: settings.inputChannelByDeviceUID) == 0,
        "a saved input the device does not have shows as Input 1")
    }

    @Test("all four model keys load the saved catalog without mounting a screen")
    func modelRoutesLoadCachedCatalogs() throws {
      let routes: [(SettingsManager.SettingKey, LLMProvider, ProviderSetupSurface)] = [
        (.llmModel, .openAI, .dictation),
        (.fileImportLLMModel, .gemini, .fileImport),
        (.ollamaModel, .ollama, .dictation),
        (.fileImportOllamaModel, .ollama, .fileImport),
      ]
      for (key, provider, surface) in routes {
        let (_, cache, settings) = Self.fixture()
        let discovery = LLMModelDiscoveryCoordinator(
          keychainManager: KeychainManager(), cacheDefaults: cache)
        discovery.loadCachedModels(for: .claude, settings: settings, surface: .dictation)

        let providerKey: SettingsManager.SettingKey =
          surface == .dictation ? .llmProvider : .fileImportLLMProvider
        #expect(
          DevControlSettings.write(
            providerKey, value: provider.rawValue, force: false, context: Self.context(),
            to: settings) == .written(forced: false))
        let dictationBefore = settings.llmModel
        let id = provider == .ollama ? "local-dev:1b" : "cached-dev-model"
        cache.set(
          try JSONEncoder().encode([Self.model(id, provider)]),
          forKey: "cachedModels_\(provider.rawValue)")

        var loads = 0
        var context = Self.context()
        context.modelCatalog = {
          .init(provider: discovery.stateProvider, models: discovery.discoveredModels)
        }
        context.loadCachedModelCatalog = { requestedProvider, requestedSurface in
          loads += 1
          #expect(requestedProvider == provider)
          #expect(requestedSurface == surface)
          #expect(settings.isDevControlWrite)
          discovery.loadCachedModels(
            for: requestedProvider, settings: settings, surface: requestedSurface)
        }

        #expect(
          DevControlSettings.write(key, value: id, force: false, context: context, to: settings)
            == .written(forced: false), "\(DevControlSettings.name(key))")
        #expect(loads == 1)
        #expect(discovery.stateProvider == provider)
        // The menu's write is the cloud-model field; the running app mirrors it into the Ollama
        // field (`PipelineSettingsSync`), which these tests do not run.
        #expect(
          PolishSettings.cloudModel(on: surface, in: settings) == id, "\(DevControlSettings.name(key))")
        #expect(settings.isDevControlWrite == false)
        if surface == .fileImport {
          #expect(settings.llmModel == dictationBefore)
        }

        // A usable published list is not replaced by another cache load.
        #expect(
          DevControlSettings.write(key, value: id, force: false, context: context, to: settings)
            == .written(forced: false))
        #expect(loads == 1)
      }
    }

    @Test("unusable catalogs get one load attempt; decoding, fixed providers and force skip it")
    func modelCacheLoadBoundaries() {
      let (_, _, settings) = Self.fixture()
      settings.llmProvider = .openAI
      let initial = settings.llmModel
      let unusable: [DevControlSettings.ModelCatalog] = [
        .init(provider: nil, models: []),
        .init(provider: .gemini, models: [Self.model("gemini-dev", .gemini)]),
        .init(provider: .openAI, models: []),
      ]
      for catalog in unusable {
        var loads = 0
        var context = Self.context(catalog: catalog)
        context.loadCachedModelCatalog = { _, _ in loads += 1 }
        let result = DevControlSettings.write(
          .llmModel, value: "missing", force: false, context: context, to: settings)
        #expect(result.code == "catalogUnavailable")
        #expect(result.message.contains("cached model catalog"))
        #expect(loads == 1)
        #expect(settings.llmModel == initial)
      }

      var loads = 0
      var context = Self.context()
      context.loadCachedModelCatalog = { _, _ in loads += 1 }
      #expect(
        DevControlSettings.write(
          .llmModel, value: 7, force: false, context: context, to: settings
        ).code == "badValue")
      for provider in [LLMProvider.appleIntelligence, .egOne, .s1Mini, .none] {
        settings.llmProvider = provider
        #expect(
          DevControlSettings.write(
            .llmModel, value: "arbitrary", force: false, context: context, to: settings
          ).code == "badValue")
      }
      #expect(
        DevControlSettings.write(
          .llmModel, value: "staged", force: true, context: context, to: settings)
          == .written(forced: true))
      #expect(loads == 0)
    }

    @Test("cache repair stays on the requested surface and is attributed even on refusal")
    func modelCacheRepairBeforeRefusal() throws {
      for surface in [ProviderSetupSurface.dictation, .fileImport] {
        let (_, cache, settings) = Self.fixture()
        settings.llmProvider = .gemini
        settings.llmModel = "gemini-3.5-transcribe"
        settings.fileImportLLMProvider = .gemini
        settings.fileImportLLMModel = "gemini-3.5-transcribe"
        cache.set(
          try JSONEncoder().encode([
            Self.model("gemini-3.5-transcribe", .gemini),
            Self.model("gemini-3.7-flash", .gemini),
          ]),
          forKey: "cachedModels_gemini")
        let discovery = LLMModelDiscoveryCoordinator(
          keychainManager: KeychainManager(), cacheDefaults: cache)
        var context = Self.context()
        context.modelCatalog = {
          .init(provider: discovery.stateProvider, models: discovery.discoveredModels)
        }
        context.loadCachedModelCatalog = {
          discovery.loadCachedModels(for: $0, settings: settings, surface: $1)
        }
        var fired: [(SettingsManager.SettingKey, Bool)] = []
        settings.onChange = { fired.append(($0, settings.isDevControlWrite)) }
        let key: SettingsManager.SettingKey =
          surface == .dictation ? .llmModel : .fileImportLLMModel

        #expect(
          DevControlSettings.write(
            key, value: "not-in-catalog", force: false, context: context, to: settings
          ).code == "badValue")
        #expect(PolishSettings.cloudModel(on: surface, in: settings) == "gemini-3.7-flash")
        let other: ProviderSetupSurface = surface == .dictation ? .fileImport : .dictation
        #expect(PolishSettings.cloudModel(on: other, in: settings) == "gemini-3.5-transcribe")
        #expect(fired.isEmpty == false)
        #expect(fired.allSatisfy { $0.1 })
        #expect(settings.isDevControlWrite == false)
        #expect(discovery.discoveredModels.map(\.id) == ["gemini-3.7-flash"])
      }
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
      settings.spokenPunctuation = SpokenPunctuationSettings(enabled: false, startWordOverrides: [:], englishPeriodWord: true)
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
      let bad = try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin","de":"two words"},"englishPeriodWord":true}"#)
      #expect(bad.code == "checkFailed")
      #expect(settings.spokenPunctuation == SpokenPunctuationSettings(enabled: false, startWordOverrides: ["de": "zebra"], englishPeriodWord: true))
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"en-US":"zebra"},"englishPeriodWord":true}"#).code == "checkFailed")
      #expect(try write(#"{"enabled":true}"#).code == "badValue")
      let twoKeys = try write(#"{"enabled":true,"startWordOverrides":{}}"#)
      #expect(twoKeys.code == "badValue")
      #expect(twoKeys.message.contains("englishPeriodWord"))

      // A good request: enable, a new French word, German absent (reset to its default).
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin"},"englishPeriodWord":true}"#) == .written(forced: false))
      #expect(settings.spokenPunctuation.enabled == true)
      #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "lapin"])

      // The owner's normalization still applies: German's own default stores no override.
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin","de":"\#(german)"},"englishPeriodWord":true}"#) == .written(forced: false))
      #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "lapin"])

      // #4216: the period switch is written through the same checked route, and only it changes.
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"fr":"lapin"},"englishPeriodWord":false}"#) == .written(forced: false))
      #expect(settings.spokenPunctuation == SpokenPunctuationSettings(enabled: true, startWordOverrides: ["fr": "lapin"], englishPeriodWord: false))
      // A refused request leaves the period switch untouched too.
      #expect(try write(#"{"enabled":true,"startWordOverrides":{"de":"two words"},"englishPeriodWord":true}"#).code == "checkFailed")
      #expect(settings.spokenPunctuation.englishPeriodWord == false)
      #expect(DevControlSettings.Codec.encode(settings.spokenPunctuation)["englishPeriodWord"] as? Bool == false)
    }

    @Test("an ordinary spoken-punctuation write refuses a stored map holding a key only force could stage")
    func spokenPunctuationRefusesStagedRegionalKey() throws {
      let (suite, defaults, settings) = Self.fixture()
      #expect(
        DevControlSettings.forceWrite(
          .spokenPunctuation,
          value: try Self.wire(#"{"enabled":false,"startWordOverrides":{"de-DE":"zebra"},"englishPeriodWord":true}"#),
          to: settings) == .written(forced: true))
      let before = settings.spokenPunctuation
      let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
      var fired: [SettingsManager.SettingKey] = []
      settings.onChange = { fired.append($0) }

      let outcome = DevControlSettings.write(
        .spokenPunctuation, value: try Self.wire(#"{"enabled":true,"startWordOverrides":{},"englishPeriodWord":true}"#),
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
      try write(.spokenPunctuation, #"{"enabled":true,"startWordOverrides":{"fr":"lapin"},"englishPeriodWord":true}"#)
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
