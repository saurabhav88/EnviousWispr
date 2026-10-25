#if DEBUG
  import AppKit
  import EnviousWisprASR
  import EnviousWisprCore
  import EnviousWisprModelDelivery
  import EnviousWisprPipeline
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprLLM
  @testable import EnviousWisprPostProcessing
  @testable import EnviousWisprStorage
  import EnviousWisprAppKitTestSupport

  /// #3765: the dev control door's command dispatcher (settings commands).
  ///
  /// Harness Contract: the dispatcher is the instrument agents set app state through. When
  /// this fails, a UAT script reads the wrong setting, writes one it asked not to force,
  /// or gets a refusal it cannot tell apart. No customer sees it.
  @Suite(.tags(.harnessContract))
  @MainActor
  struct DevControlDispatcherTests {
    private static func make() -> (SettingsManager, DevControlDispatcher) {
      let defaults = TestDefaults.suite("ew.tests.3765.dispatch.\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: defaults)
      let dispatcher = DevControlDispatcher(
        settings: settings,
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          loadCachedModelCatalog: { _, _ in },
          connectedInputUIDs: { ["mic-a"] }, inputChannelCounts: { [:] }, pillWordsCapability: { .available }),
        status: DevControlFixtures.StatusFake().sources,
        history: DevControlFixtures.history([]),
        models: DevControlFixtures.ModelFake().actions,
        dictation: DevControlFixtures.inertDictation(),
        credentials: DevControlFixtures.isolatedCredentials(),
        words: DevControlFixtures.unwrittenWords(), meetings: .unwired())
      return (settings, dispatcher)
    }

    private func payload(_ result: DevControlDispatcher.Result) -> [String: Any]? {
      if case .ok(let payload, _) = result { return payload }
      return nil
    }

    private func code(_ result: DevControlDispatcher.Result) -> String? {
      if case .error(let code, _) = result { return code }
      return nil
    }

    private func forcedFlag(_ result: DevControlDispatcher.Result) -> Bool? {
      if case .ok(_, let forced) = result { return forced }
      return nil
    }

    @Test("settings.list returns all 80 rows; settings.get returns one, and refuses bad keys")
    func listAndGet() async throws {
      let (settings, dispatcher) = Self.make()
      let listed = try #require(payload(await dispatcher.handle(.settingsList, args: [:])))
      let rows = try #require(listed["settings"] as? [[String: Any]])
      #expect(rows.count == 80)

      settings.fillerRemovalEnabled = false
      let got = try #require(
        payload(await dispatcher.handle(.settingsGet, args: ["key": "fillerRemovalEnabled"])))
      #expect(got["key"] as? String == "fillerRemovalEnabled")
      #expect(got["value"] as? Bool == false)
      #expect(got["kind"] as? String == "direct")

      // A list row and a get reply describe one setting with the same field names, so a
      // script can feed either one's `key` back into `settings get`.
      for row in rows {
        let name = try #require(row["key"] as? String, "list row without key: \(row)")
        let single = try #require(
          payload(await dispatcher.handle(.settingsGet, args: ["key": name])))
        #expect(Set(row.keys) == Set(single.keys), "\(name)")
        #expect(single["key"] as? String == name)
      }

      #expect(code(await dispatcher.handle(.settingsGet, args: ["key": "nope"])) == "unknownKey")
      #expect(code(await dispatcher.handle(.settingsGet, args: ["key": 5])) == "badArgs")
      #expect(code(await dispatcher.handle(.settingsGet, args: [:])) == "badArgs")
    }

    @Test("settings.set validates its arguments before touching anything")
    func setArgumentChecks() async throws {
      let (settings, dispatcher) = Self.make()
      let before = settings.fillerRemovalEnabled
      #expect(
        code(await dispatcher.handle(.settingsSet, args: ["key": "fillerRemovalEnabled"]))
          == "badArgs")
      #expect(
        code(
          await dispatcher.handle(
            .settingsSet, args: ["key": "fillerRemovalEnabled", "value": !before, "force": "yes"]))
          == "badArgs")
      #expect(
        code(
          await dispatcher.handle(
            .settingsSet,
            args: ["key": "fillerRemovalEnabled", "value": !before, "force": NSNumber(value: 1)]))
          == "badArgs")
      #expect(
        code(await dispatcher.handle(.settingsSet, args: ["key": "nope", "value": true]))
          == "unknownKey")
      #expect(settings.fillerRemovalEnabled == before)
    }

    @Test("an ordinary write reports forced false; a forced write reports forced true")
    func forcedFlagIsReported() async throws {
      let (settings, dispatcher) = Self.make()
      let target = !settings.fillerRemovalEnabled
      let plain = await dispatcher.handle(
        .settingsSet, args: ["key": "fillerRemovalEnabled", "value": target])
      #expect(forcedFlag(plain) == false)
      #expect(payload(plain)?["forced"] as? Bool == false)
      #expect(payload(plain)?["value"] as? Bool == target)
      #expect(settings.fillerRemovalEnabled == target)

      let forced = await dispatcher.handle(
        .settingsSet, args: ["key": "fillerRemovalEnabled", "value": !target, "force": true])
      #expect(forcedFlag(forced) == true)
      #expect(payload(forced)?["forced"] as? Bool == true)
      #expect(settings.fillerRemovalEnabled == !target)
    }

    @Test("channel.set validates its arguments, then reads back the input the row shows")
    func channelSetThroughDispatch() async throws {
      let defaults = TestDefaults.suite("ew.tests.3765.dispatch.\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: defaults)
      let dispatcher = DevControlDispatcher(
        settings: settings,
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          loadCachedModelCatalog: { _, _ in },
          connectedInputUIDs: { [] }, inputChannelCounts: { ["mic-a": 4] },
          pillWordsCapability: { .available }),
        status: DevControlFixtures.StatusFake().sources,
        history: DevControlFixtures.history([]),
        models: DevControlFixtures.ModelFake().actions,
        dictation: DevControlFixtures.inertDictation(),
        credentials: DevControlFixtures.isolatedCredentials(),
        words: DevControlFixtures.unwrittenWords(), meetings: .unwired())
      let reply = try #require(payload(await dispatcher.handle(
        .channelSet, args: ["deviceUID": "mic-a", "channel": NSNumber(value: 2)])))
      #expect(reply["deviceUID"] as? String == "mic-a")
      #expect(reply["channel"] as? Int == 2)
      for args: [String: Any] in [
        ["deviceUID": "mic-a"], ["channel": 1], ["deviceUID": "", "channel": 1],
        ["deviceUID": "mic-a", "channel": true], ["deviceUID": "mic-a", "channel": 1.5],
        ["deviceUID": "mic-a", "channel": "1"], ["deviceUID": "mic-a", "channel": 1, "x": 1],
      ] {
        #expect(code(await dispatcher.handle(.channelSet, args: args)) == "badArgs", "\(args)")
      }
      #expect(code(await dispatcher.handle(
        .channelSet, args: ["deviceUID": "mic-a", "channel": 9])) == "checkFailed")
      #expect(settings.inputChannelByDeviceUID == ["mic-a": 2])
    }

    @Test("shortcut.set saves a whole shortcut and reads both halves back")
    func shortcutSetThroughDispatch() async throws {
      let (settings, dispatcher) = Self.make()
      let reply = await dispatcher.handle(
        .shortcutSet,
        args: [
          "role": "record", "keyCode": NSNumber(value: ModifierKeyCodes.rightCommand),
          "modifiers": NSNumber(value: NSEvent.ModifierFlags.command.rawValue),
        ])
      guard case .ok(let payload, let forced) = reply else {
        Issue.record("not ok: \(reply)")
        return
      }
      #expect(forced == false)
      #expect(payload["role"] as? String == "record")
      #expect(payload["keyCode"] as? Int == Int(ModifierKeyCodes.rightCommand))
      #expect(payload["modifiers"] as? UInt == 0, "a lone modifier stores no modifiers")
      #expect(settings.toggleKeyCode == ModifierKeyCodes.rightCommand)

      // F2, F8, F9 and F5 with Control-Shift: no default and no Mac shortcut uses them.
      for (role, keyCode) in [("cancel", 120), ("quickAdd", 100), ("pasteLast", 101), ("copyLast", 96)] {
        let saved = await dispatcher.handle(
          .shortcutSet,
          args: [
            "role": role, "keyCode": keyCode,
            "modifiers": NSNumber(value: NSEvent.ModifierFlags([.control, .shift]).rawValue),
          ])
        #expect(code(saved) == nil, "\(role)")
      }
      #expect(settings.cancelKeyCode == 120 && settings.copyLastKeyCode == 96)
      #expect(settings.copyLastModifiers == [.control, .shift])
    }

    @Test("shortcut.set refuses malformed arguments and clashes without changing anything")
    func shortcutSetRefusals() async throws {
      let (settings, dispatcher) = Self.make()
      let before = settings.shortcutBindings
      let control = NSEvent.ModifierFlags.control.rawValue
      for args: [String: Any] in [
        [:],
        ["role": "toggle", "keyCode": 1, "modifiers": control],
        ["role": "record", "keyCode": 1],
        ["role": "record", "keyCode": 1, "modifiers": control, "force": true],
        ["role": 1, "keyCode": 1, "modifiers": control],
        ["role": "record", "keyCode": true, "modifiers": control],
        ["role": "record", "keyCode": 1.5, "modifiers": control],
        ["role": "record", "keyCode": 65536, "modifiers": control],
        ["role": "record", "keyCode": -1, "modifiers": control],
        ["role": "record", "keyCode": "1", "modifiers": control],
        ["role": "record", "keyCode": 1, "modifiers": -1],
        ["role": "record", "keyCode": 1, "modifiers": false],
      ] {
        #expect(code(await dispatcher.handle(.shortcutSet, args: args)) == "badArgs", "\(args)")
      }
      #expect(
        code(await dispatcher.handle(
          .shortcutSet,
          args: ["role": "quickAdd", "keyCode": 8,
                 "modifiers": NSNumber(value: NSEvent.ModifierFlags.command.rawValue)]))
          == "checkFailed")
      #expect(
        code(await dispatcher.handle(
          .shortcutSet, args: ["role": "record", "keyCode": 53, "modifiers": 0]))
          == "checkFailed")
      #expect(settings.shortcutBindings == before)
    }

    @Test("a single shortcut field is checked whole; force stages it")
    func shortcutFieldThroughDispatch() async throws {
      let (settings, dispatcher) = Self.make()
      #expect(
        code(await dispatcher.handle(
          .settingsSet, args: ["key": "toggleKeyCode", "value": 53])) == "checkFailed")
      #expect(settings.toggleKeyCode == ShortcutRole.record.defaultKeyCode)
      let forced = await dispatcher.handle(
        .settingsSet, args: ["key": "toggleKeyCode", "value": 53, "force": true])
      #expect(forcedFlag(forced) == true)
      #expect(settings.toggleKeyCode == 53)
    }

    @Test("every refusal code the dispatcher returns is in the closed vocabulary")
    func refusalCodesAreClosed() async throws {
      let (_, dispatcher) = Self.make()
      let vocabulary = Set(DevControlDispatcher.ErrorCode.allCases.map(\.rawValue))
      let results: [DevControlDispatcher.Result] = [
        await dispatcher.handle(nil, args: [:]),
        await dispatcher.handle(.settingsGet, args: [:]),
        await dispatcher.handle(.settingsGet, args: ["key": "nope"]),
        await dispatcher.handle(.settingsSet, args: ["key": "llmModel", "value": 3]),
        await dispatcher.handle(.settingsSet, args: ["key": "llmModel", "value": "gpt-x"]),
        await dispatcher.handle(.settingsSet, args: ["key": "toggleKeyCode", "value": 53]),
        await dispatcher.handle(.shortcutSet, args: ["role": "nope"]),
        await dispatcher.handle(
          .settingsSet, args: ["key": "selectedInputDeviceUID", "value": "mic-z"]),
      ]
      for result in results {
        let found = try #require(code(result))
        #expect(vocabulary.contains(found), "\(found)")
      }
    }

    // MARK: - Models

    @Test(
      "each model command presses exactly its own button once, then reads that engine's state",
      arguments: [
        (DevControlDispatcher.Command.modelsParakeetDownload, "parakeetDownload", "parakeet", "download"),
        (.modelsParakeetCancel, "parakeetCancel", "parakeet", "cancel"),
        (.modelsWhisperDownload, "whisperDownload", "whisper", "download"),
        (.modelsWhisperCancel, "whisperCancel", "whisper", "cancel"),
      ])
    func modelCommandPressesOneButton(
      command: DevControlDispatcher.Command, action: String, backend: String, verb: String
    ) async throws {
      let status = DevControlFixtures.StatusFake()
      status.parakeet = .notReady
      status.whisper = .notDownloaded
      let models = DevControlFixtures.ModelFake()
      // The owner moves its state when pressed; the reply must show the state AFTER.
      models.onPress = { _ in
        status.parakeet = .verifying
        status.whisper = .paused
      }
      let (_, dispatcher) = Self.make(status: status, models: models)
      let reply = try #require(payload(await dispatcher.handle(command, args: [:])))
      #expect(models.pressed == [action])
      #expect(reply["backend"] as? String == backend)
      #expect(reply["action"] as? String == verb)
      let state = try #require(reply["state"] as? [String: Any])
      #expect(state["state"] as? String == (backend == "parakeet" ? "verifying" : "paused"))
      #expect(JSONSerialization.isValidJSONObject(reply))
    }

    @Test("a model command whose owner does nothing reports the unchanged state")
    func modelCommandWithIdleOwnerReportsUnchangedState() async throws {
      let status = DevControlFixtures.StatusFake()
      status.parakeet = .cancelled(resumable: true)
      status.whisper = .ready
      let models = DevControlFixtures.ModelFake()
      let (_, dispatcher) = Self.make(status: status, models: models)
      let parakeet = try #require(payload(await dispatcher.handle(.modelsParakeetCancel, args: [:])))
      #expect(parakeet["state"] as? [String: AnyHashable] == ["state": "cancelled", "resumable": true])
      let whisper = try #require(payload(await dispatcher.handle(.modelsWhisperDownload, args: [:])))
      #expect(whisper["state"] as? [String: AnyHashable] == ["state": "ready"])
      #expect(models.pressed == ["parakeetCancel", "whisperDownload"])
    }

    @Test("a model command with any argument is refused before any button is pressed")
    func modelCommandRefusesArguments() async throws {
      let models = DevControlFixtures.ModelFake()
      let (_, dispatcher) = Self.make(status: DevControlFixtures.StatusFake(), models: models)
      for command in [
        DevControlDispatcher.Command.modelsParakeetDownload, .modelsParakeetCancel,
        .modelsWhisperDownload, .modelsWhisperCancel,
      ] {
        #expect(code(await dispatcher.handle(command, args: ["backend": "parakeet"])) == "badArgs")
      }
      #expect(models.pressed.isEmpty)
    }

    // MARK: - Status

    private static func make(
      status: DevControlFixtures.StatusFake, rows: @escaping @MainActor () -> [Transcript] = { [] },
      models: DevControlFixtures.ModelFake = DevControlFixtures.ModelFake()
    ) -> (SettingsManager, DevControlDispatcher) {
      let defaults = TestDefaults.suite("ew.tests.3765.dispatch.\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: defaults)
      let dispatcher = DevControlDispatcher(
        settings: settings,
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          loadCachedModelCatalog: { _, _ in },
          connectedInputUIDs: { [] }, inputChannelCounts: { [:] }, pillWordsCapability: { .available }),
        status: status.sources,
        history: DevControlDispatcher.HistorySource(visibleTranscripts: rows),
        models: models.actions,
        dictation: DevControlFixtures.inertDictation(),
        credentials: DevControlFixtures.isolatedCredentials(),
        words: DevControlFixtures.unwrittenWords(), meetings: .unwired())
      return (settings, dispatcher)
    }

    private func object(_ value: Any?) throws -> [String: Any] {
      try #require(value as? [String: Any])
    }

    @Test("status reports each owner's fact, and the driver state is the ACTIVE engine's")
    func statusReadsEachOwner() async throws {
      let fake = DevControlFixtures.StatusFake()
      fake.engine = DevControlFixtures.engine(
        selected: .whisper, active: .parakeet, selectedReadiness: .notReady,
        activeReadiness: .ready, selectedInstalled: false, blockedReason: .notInstalled)
      fake.driverStates = [.parakeet: .recording, .whisper: .polishing]
      fake.parakeet = .downloading(fractionCompleted: 0.25, bytesWritten: 100, totalBytes: 400)
      fake.whisper = .downloading(progress: 0.5, status: "Downloading screen copy")
      fake.fileImportRunning = true
      fake.keys = [.openAI: .present, .gemini: .absent, .claude: .unknown]
      let (settings, dispatcher) = Self.make(status: fake)
      settings.selectedBackend = .parakeet

      let reply = try #require(payload(await dispatcher.handle(.status, args: [:])))
      // The live setting and the coordinator's snapshot are separate facts.
      #expect(reply["selectedBackend"] as? String == "parakeet")
      let engine = try object(reply["engine"])
      #expect(engine["selected"] as? String == "whisper")
      #expect(engine["active"] as? String == "parakeet")
      #expect(engine["diverged"] as? Bool == true)
      #expect(engine["selectedReadiness"] as? String == "notReady")
      #expect(engine["activeReadiness"] as? String == "ready")
      #expect(engine["selectedInstalled"] as? Bool == false)
      #expect(engine["switchPhase"] as? String == "idle")
      #expect(engine["switchFailure"] is NSNull)
      #expect(engine["blockedReason"] as? String == "not_installed")
      #expect(engine["warmInFlight"] is NSNull)
      #expect(engine["isSwitching"] as? Bool == false)

      let driver = try object(reply["activeDriver"])
      #expect(driver["backend"] as? String == "parakeet")
      #expect(driver["state"] as? String == "recording")
      #expect(driver["reason"] is NSNull)
      #expect(fake.driverStateAsked == [.parakeet])

      let parakeet = try object(reply["parakeetDelivery"])
      #expect(parakeet["state"] as? String == "downloading")
      #expect(parakeet["fractionCompleted"] as? Double == 0.25)
      #expect(parakeet["bytesWritten"] as? Int64 == 100)
      #expect(parakeet["totalBytes"] as? Int64 == 400)
      let whisper = try object(reply["whisperSetup"])
      #expect(whisper["state"] as? String == "downloading")
      #expect(whisper["progress"] as? Double == 0.5)
      #expect(reply["fileImportRunning"] as? Bool == true)
      let keys = try #require(reply["savedKeys"] as? [String: String])
      #expect(keys == ["openAI": "present", "gemini": "absent", "claude": "unknown"])

      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
      #expect(encoded.contains("screen copy") == false)
    }

    @Test("status sources built from a temporary fake stay alive after construction")
    func defaultStatusSourcesRemainAlive() async throws {
      let (_, dispatcher) = Self.make()
      let reply = try #require(payload(await dispatcher.handle(.status, args: [:])))
      let engine = try object(reply["engine"])
      #expect(engine["active"] as? String == "parakeet")
    }

    @Test("status follows the owners from one request to the next, keeping each state apart")
    func statusFollowsChangingSnapshots() async throws {
      let fake = DevControlFixtures.StatusFake()
      fake.engine = DevControlFixtures.engine(
        selected: .whisper, active: .whisper, selectedReadiness: .warming,
        activeReadiness: .warming, switchPhase: .switching, warmInFlight: .whisper)
      fake.isSwitching = true
      fake.driverStates = [.parakeet: .idle, .whisper: .advisory(.vadGateNoSpeech)]
      fake.parakeet = .failed(
        DeliveryFailure(reason: .insufficientDisk, detail: "detail-text", failingSourceID: "src-x"))
      fake.whisper = .error("owner error words")
      let (_, dispatcher) = Self.make(status: fake)

      let first = try #require(payload(await dispatcher.handle(.status, args: [:])))
      let engine = try object(first["engine"])
      #expect(engine["active"] as? String == "whisper")
      #expect(engine["diverged"] as? Bool == false)
      #expect(engine["activeReadiness"] as? String == "warming")
      #expect(engine["switchPhase"] as? String == "switching")
      #expect(engine["warmInFlight"] as? String == "whisper")
      #expect(engine["isSwitching"] as? Bool == true)
      let driver = try object(first["activeDriver"])
      #expect(driver["backend"] as? String == "whisper")
      #expect(driver["state"] as? String == "advisory")
      #expect(driver["reason"] as? String == "vadGateNoSpeech")
      #expect(fake.driverStateAsked == [.whisper])
      #expect(try object(first["parakeetDelivery"]) as NSDictionary == ["state": "failed", "reason": "insufficient_disk"])
      #expect(try object(first["whisperSetup"]) as NSDictionary == ["state": "error"])
      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
      for owned in ["detail-text", "src-x", "owner error words"] {
        #expect(encoded.contains(owned) == false, "\(owned)")
      }

      fake.engine = DevControlFixtures.engine(
        selected: .parakeet, active: .parakeet, selectedReadiness: .ready,
        activeReadiness: .ready, switchPhase: .failed(reason: "load_failed"))
      fake.isSwitching = false
      fake.driverStates = [.parakeet: .error(.asrFailed), .whisper: .idle]
      fake.parakeet = .cancelled(resumable: true)
      fake.whisper = .paused
      let second = try #require(payload(await dispatcher.handle(.status, args: [:])))
      let engineAfter = try object(second["engine"])
      #expect(engineAfter["active"] as? String == "parakeet")
      #expect(engineAfter["switchPhase"] as? String == "failed")
      #expect(engineAfter["switchFailure"] as? String == "load_failed")
      #expect(engineAfter["isSwitching"] as? Bool == false)
      let driverAfter = try object(second["activeDriver"])
      #expect(driverAfter["state"] as? String == "error")
      #expect(driverAfter["reason"] as? String == "asr_failed")
      #expect(fake.driverStateAsked == [.whisper, .parakeet])
      #expect(
        try object(second["parakeetDelivery"]) as NSDictionary
          == ["state": "cancelled", "resumable": true])
      #expect(try object(second["whisperSetup"]) as NSDictionary == ["state": "paused"])

      fake.parakeet = .preparing(validatingExistingCache: true)
      fake.whisper = .notDownloaded
      let third = try #require(payload(await dispatcher.handle(.status, args: [:])))
      #expect(
        try object(third["parakeetDelivery"]) as NSDictionary
          == ["state": "preparing", "validatingExistingCache": true])
      #expect(try object(third["whisperSetup"]) as NSDictionary == ["state": "notDownloaded"])
      fake.parakeet = .admitted
      fake.whisper = .ready
      let fourth = try #require(payload(await dispatcher.handle(.status, args: [:])))
      #expect(try object(fourth["parakeetDelivery"]) as NSDictionary == ["state": "admitted"])
      #expect(try object(fourth["whisperSetup"]) as NSDictionary == ["state": "ready"])
    }

    @Test("saved keys come from SavedKeyPresence alone; a provider no path has read is unknown")
    func savedKeysComeFromPresenceOnly() async throws {
      let presence = SavedKeyPresence()
      let fake = DevControlFixtures.StatusFake()
      fake.keyState = { presence.state(for: $0) }
      let (_, dispatcher) = Self.make(status: fake)

      let fresh = try #require(payload(await dispatcher.handle(.status, args: [:])))
      #expect(
        fresh["savedKeys"] as? [String: String]
          == ["openAI": "unknown", "gemini": "unknown", "claude": "unknown"])

      presence.recordSaved(.openAI)
      presence.recordCleared(.gemini)
      let after = try #require(payload(await dispatcher.handle(.status, args: [:])))
      #expect(
        after["savedKeys"] as? [String: String]
          == ["openAI": "present", "gemini": "absent", "claude": "unknown"])
    }

    // MARK: - History

    private static func rows(_ count: Int, base: Date = Date()) -> [Transcript] {
      (0..<count).map {
        Transcript(text: "row \($0)", createdAt: base.addingTimeInterval(-Double($0)))
      }
    }

    @Test("history.list keeps owner order, defaults to 20, allows 200 and refuses other limits")
    func historyListLimits() async throws {
      let rows = DevControlFixtures.Box<[Transcript]>([])
      let (_, dispatcher) = Self.make(status: DevControlFixtures.StatusFake(), rows: { rows.value })

      let empty = try #require(payload(await dispatcher.handle(.historyList, args: [:])))
      #expect((empty["rows"] as? [Any])?.isEmpty == true)
      #expect(empty["total"] as? Int == 0)
      #expect(empty["limit"] as? Int == 20)

      rows.value = Self.rows(250)
      let byDefault = try #require(payload(await dispatcher.handle(.historyList, args: [:])))
      let defaultRows = try #require(byDefault["rows"] as? [[String: Any]])
      #expect(defaultRows.map { $0["id"] as? String } == rows.value.prefix(20).map(\.id.uuidString))
      #expect(byDefault["total"] as? Int == 250)

      let most = try #require(
        payload(await dispatcher.handle(.historyList, args: ["limit": NSNumber(value: 200)])))
      #expect((most["rows"] as? [Any])?.count == 200)
      let one = try #require(
        payload(await dispatcher.handle(.historyList, args: ["limit": NSNumber(value: 1)])))
      #expect((one["rows"] as? [[String: Any]])?.first?["id"] as? String == rows.value[0].id.uuidString)

      let refused: [Any] = [
        NSNumber(value: 201), NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: 1.5),
        true, "5", NSNull(),
      ]
      for limit in refused {
        #expect(
          code(await dispatcher.handle(.historyList, args: ["limit": limit])) == "badArgs",
          "\(limit)")
      }
    }

    @Test("a list summary carries no text or file name, and its size does not grow with the text")
    func historySummariesAreBounded() async throws {
      let long = String(repeating: "é\u{301}", count: 50_000)
      let rows = [
        Transcript(text: long, polishedText: long, importedFileName: long, processedText: long)
      ]
      let (_, dispatcher) = Self.make(status: DevControlFixtures.StatusFake(), rows: { rows })
      let listed = try #require(payload(await dispatcher.handle(.historyList, args: [:])))
      let summary = try #require((listed["rows"] as? [[String: Any]])?.first)
      #expect(summary["kind"] as? String == "import")
      #expect(summary["textBytes"] as? Int == long.utf8.count)
      #expect(summary["hasPolishedText"] as? Bool == true)
      #expect(summary["hasProcessedText"] as? Bool == true)
      let encoded = try JSONSerialization.data(withJSONObject: listed)
      #expect(encoded.count < 1_024, "\(encoded.count) bytes")
    }

    @Test("history.get returns exactly the asked row with its three texts apart")
    func historyGetExactRow() async throws {
      let target = Transcript(
        text: "raw words", polishedText: "Polished words.", language: "en",
        llmProvider: "openAI", llmModel: "gpt-x", processedText: "Processed words")
      let rows = Self.rows(3) + [target]
      let (_, dispatcher) = Self.make(status: DevControlFixtures.StatusFake(), rows: { rows })

      let got = try #require(
        payload(
          await dispatcher.handle(
            .historyGet, args: ["id": target.id.uuidString.lowercased()])))
      let row = try object(got["row"])
      #expect(row["id"] as? String == target.id.uuidString)
      #expect(row["text"] as? String == "raw words")
      #expect(row["polishedText"] as? String == "Polished words.")
      #expect(row["processedText"] as? String == "Processed words")
      #expect(row["language"] as? String == "en")
      #expect(row["llmModel"] as? String == "gpt-x")
      #expect(row["pending"] as? Bool == false)

      let plain = try #require(
        payload(await dispatcher.handle(.historyGet, args: ["id": rows[0].id.uuidString])))
      let plainRow = try object(plain["row"])
      #expect(plainRow["text"] as? String == "row 0")
      #expect(plainRow["polishedText"] is NSNull)
      #expect(plainRow["processedText"] is NSNull)
      #expect(plainRow["importedFileName"] is NSNull)
      #expect(plainRow["escapeRecoveredAt"] is NSNull)

      #expect(
        code(await dispatcher.handle(.historyGet, args: ["id": UUID().uuidString])) == "notFound")
      for bad in ["not-a-uuid", 5, NSNull()] as [Any] {
        #expect(code(await dispatcher.handle(.historyGet, args: ["id": bad])) == "badArgs")
      }
      #expect(code(await dispatcher.handle(.historyGet, args: [:])) == "badArgs")
    }

    @Test("History reads go through the real coordinator: expired rows and deleted rows are gone")
    func historyThroughTheRealCoordinator() async throws {
      let directory = TestTemporaryDirectory.url
        .appendingPathComponent("ew-3765-history-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = TranscriptStore(directory: directory)
      let coordinator = TranscriptCoordinator(store: store)
      defer { coordinator.cancelPulseForTesting() }

      let window = AppConstants.pendingTranscriptRetention
      let permanent = Transcript(text: "kept row")
      let held = Transcript(
        text: "held row", escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-held")
      let expired = Transcript(
        text: "expired row", escapeRecoveredAt: Date().addingTimeInterval(-window - 60),
        escapeRecoveryTakeID: "take-expired")
      try store.save(permanent)
      coordinator.setTranscriptsForTesting([permanent, held, expired])

      let (_, dispatcher) = Self.make(
        status: DevControlFixtures.StatusFake(), rows: { coordinator.visibleTranscripts })
      let listed = try #require(payload(await dispatcher.handle(.historyList, args: [:])))
      let ids = (listed["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
      #expect(ids == [permanent.id.uuidString, held.id.uuidString])
      #expect(
        (listed["rows"] as? [[String: Any]])?.map { $0["pending"] as? Bool } == [false, true])
      #expect(
        code(await dispatcher.handle(.historyGet, args: ["id": expired.id.uuidString]))
          == "notFound")

      #expect(
        payload(await dispatcher.handle(.historyGet, args: ["id": permanent.id.uuidString]))
          != nil)
      await coordinator.delete(permanent)
      try #require(coordinator.rawTranscriptsForTesting.contains { $0.id == permanent.id } == false)
      #expect(
        code(await dispatcher.handle(.historyGet, args: ["id": permanent.id.uuidString]))
          == "notFound")
    }

    @Test("status and History reads change no setting and never enter a dev-control write")
    func readsHaveNoSideEffects() async throws {
      let fake = DevControlFixtures.StatusFake()
      let rows = Self.rows(3)
      let writeFlags = DevControlFixtures.Box<[Bool]>([])
      let settingsRef = DevControlFixtures.Box<SettingsManager?>(nil)
      fake.onRead = {
        if let settings = settingsRef.value { writeFlags.value.append(settings.isDevControlWrite) }
      }
      let (settings, dispatcher) = Self.make(
        status: fake,
        rows: {
          if let settings = settingsRef.value { writeFlags.value.append(settings.isDevControlWrite) }
          return rows
        })
      settingsRef.value = settings
      let before = try JSONSerialization.data(
        withJSONObject: DevControlSettings.catalog(settings), options: .sortedKeys)

      _ = await dispatcher.handle(.status, args: [:])
      _ = await dispatcher.handle(.historyList, args: ["limit": NSNumber(value: 2)])
      _ = await dispatcher.handle(.historyGet, args: ["id": rows[1].id.uuidString])

      let after = try JSONSerialization.data(
        withJSONObject: DevControlSettings.catalog(settings), options: .sortedKeys)
      #expect(before == after)
      #expect(writeFlags.value.count == 3)
      #expect(writeFlags.value.allSatisfy { $0 == false })
    }
// MARK: - Words

private static func make(words: CustomWordsCoordinator) -> (SettingsManager, DevControlDispatcher) {
  let defaults = TestDefaults.suite("ew.tests.3765.dispatch.\(UUID().uuidString)")!
  let settings = SettingsManager(defaults: defaults)
  let dispatcher = DevControlDispatcher(
    settings: settings,
    writeContext: DevControlSettings.WriteContext(
      modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
      loadCachedModelCatalog: { _, _ in },
      connectedInputUIDs: { [] }, inputChannelCounts: { [:] }, pillWordsCapability: { .available }),
    status: DevControlFixtures.StatusFake().sources,
    history: DevControlFixtures.history([]),
    models: DevControlFixtures.ModelFake().actions,
    dictation: DevControlFixtures.inertDictation(),
    credentials: DevControlFixtures.isolatedCredentials(),
    words: words, meetings: .unwired())
  return (settings, dispatcher)
}

private func listed(_ dispatcher: DevControlDispatcher) async throws -> [[String: Any]] {
  let reply = try #require(payload(await dispatcher.handle(.wordsList, args: [:])))
  return try #require(reply["words"] as? [[String: Any]])
}

private func word(_ result: DevControlDispatcher.Result) throws -> [String: Any] {
  try object(try #require(payload(result))["word"])
}

private func outcome(_ result: DevControlDispatcher.Result) -> String? {
  payload(result)?["outcome"] as? String
}

@Test("add, list, update and remove go through the coordinator and persist to its file")
func wordsRoundTrip() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)

  let added = await dispatcher.handle(
    .wordsAdd, args: ["word": "  Zorblax ", "aliases": ["zor blacks"]])
  #expect(outcome(added) == "created")
  let row = try word(added)
  let id = try #require(row["id"] as? String)
  #expect(row["word"] as? String == "Zorblax")
  #expect(row["aliases"] as? [String] == ["zor blacks"])
  #expect(row["source"] as? String == "user")
  let listedRow = try #require(try await listed(dispatcher).first { $0["id"] as? String == id })
  #expect(listedRow["word"] as? String == "Zorblax")
  #expect(
    try await listed(dispatcher).map { $0["id"] as? String }
      == temp.coordinator.customWords.map(\.id.uuidString))

  let aliasOnly = await dispatcher.handle(
    .wordsUpdate, args: ["id": id.lowercased(), "aliases": ["zorb lax"]])
  #expect(outcome(aliasOnly) == "updated")
  #expect(try word(aliasOnly)["word"] as? String == "Zorblax")
  #expect(try word(aliasOnly)["aliases"] as? [String] == ["zorb lax"])
  #expect(try word(aliasOnly)["id"] as? String == id)

  let wordOnly = await dispatcher.handle(.wordsUpdate, args: ["id": id, "word": "Zorblaxx"])
  #expect(try word(wordOnly)["word"] as? String == "Zorblaxx")
  #expect(try word(wordOnly)["aliases"] as? [String] == ["zorb lax"])

  let cleared = await dispatcher.handle(.wordsUpdate, args: ["id": id, "aliases": [String]()])
  #expect(try word(cleared)["aliases"] as? [String] == [])

  let reread = try #require(CustomWordsManager(fileURL: temp.url).load())
  let saved = try #require(reread.first { $0.id.uuidString == id })
  #expect(saved.canonical == "Zorblaxx")
  #expect(saved.aliases.isEmpty)

  let removed = await dispatcher.handle(.wordsRemove, args: ["id": id])
  #expect(outcome(removed) == "removed")
  #expect(try await listed(dispatcher).contains { $0["id"] as? String == id } == false)
  let afterRemove = try #require(CustomWordsManager(fileURL: temp.url).load())
  #expect(afterRemove.contains { $0.id.uuidString == id } == false)
}

@Test("malformed word requests and missing targets change nothing and fire no callback")
func wordRefusalsChangeNothing() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)
  let existing = try #require(
    payload(await dispatcher.handle(.wordsAdd, args: ["word": "Kestrel"])))
  let id = try #require((existing["word"] as? [String: Any])?["id"] as? String)
  var callbacks = 0
  temp.coordinator.onWordsChanged = { _ in callbacks += 1 }
  let before = temp.coordinator.customWords
  let fileBefore = try Data(contentsOf: temp.url)

  let refusals: [(DevControlDispatcher.Command, [String: Any], String)] = [
    (.wordsList, ["limit": 5], "badArgs"),
    (.wordsAdd, [:], "badArgs"),
    (.wordsAdd, ["word": 5], "badArgs"),
    (.wordsAdd, ["word": "Osprey", "aliases": "osprey"], "badArgs"),
    (.wordsAdd, ["word": "Osprey", "aliases": ["ok", 2]], "badArgs"),
    (.wordsAdd, ["word": "Osprey", "aliases": [NSNull()]], "badArgs"),
    (.wordsAdd, ["word": "Osprey", "id": UUID().uuidString], "badArgs"),
    (.wordsAdd, ["word": "Osprey", "source": "builtin"], "badArgs"),
    (.wordsUpdate, ["word": "Osprey"], "badArgs"),
    (.wordsUpdate, ["id": "not-a-uuid", "word": "Osprey"], "badArgs"),
    (.wordsUpdate, ["id": 7, "word": "Osprey"], "badArgs"),
    (.wordsUpdate, ["id": id], "badArgs"),
    (.wordsUpdate, ["id": id, "word": 5], "badArgs"),
    (.wordsUpdate, ["id": id, "aliases": ["a", 1]], "badArgs"),
    (.wordsUpdate, ["id": id, "frequencyUsed": 9], "badArgs"),
    (.wordsUpdate, ["id": UUID().uuidString, "word": "Osprey"], "notFound"),
    (.wordsRemove, [:], "badArgs"),
    (.wordsRemove, ["id": "nope"], "badArgs"),
    (.wordsRemove, ["id": id, "force": true], "badArgs"),
    (.wordsRemove, ["id": UUID().uuidString], "notFound"),
  ]
  for (command, args, expected) in refusals {
    #expect(code(await dispatcher.handle(command, args: args)) == expected, "\(command) \(args)")
  }
  #expect(callbacks == 0)
  #expect(temp.coordinator.customWords == before)
  #expect(try Data(contentsOf: temp.url) == fileBefore)
}

@Test("an owner refusal comes back as rejected with the owner's message, and nothing changes")
func ownerRefusalIsRejected() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)
  let id = try #require(
    try word(await dispatcher.handle(.wordsAdd, args: ["word": "Heron"]))["id"] as? String)
  var callbacks = 0
  temp.coordinator.onWordsChanged = { _ in callbacks += 1 }
  let before = temp.coordinator.customWords
  let tooLong = String(repeating: "a", count: CustomWordsImportLimits.maximumStoredValueScalars + 1)

  for (command, args) in [
    (DevControlDispatcher.Command.wordsAdd, ["word": tooLong] as [String: Any]),
    (.wordsAdd, ["word": "Egret", "aliases": [tooLong]]),
    (.wordsUpdate, ["id": id, "aliases": [tooLong]]),
    (.wordsUpdate, ["id": id, "word": tooLong]),
  ] {
    let result = await dispatcher.handle(command, args: args)
    guard case .error(let code, let message) = result else {
      Issue.record("expected a refusal for \(command)")
      continue
    }
    #expect(code == "rejected")
    #expect(message == CustomWordsPersistenceError.unusableValue.localizedDescription)
  }
  #expect(callbacks == 0)
  #expect(temp.coordinator.customWords == before)
}

@Test("a duplicate or blank add makes nothing new and names what the list holds")
func duplicateAndBlankAdds() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)
  var published: [[CustomWord]] = []
  temp.coordinator.onWordsChanged = { published.append($0) }

  let first = await dispatcher.handle(.wordsAdd, args: ["word": "Kestrel"])
  let id = try #require(try word(first)["id"] as? String)
  let count = temp.coordinator.customWords.count

  let duplicate = await dispatcher.handle(.wordsAdd, args: ["word": " kestrel"])
  #expect(outcome(duplicate) == "existing")
  #expect(try word(duplicate)["id"] as? String == id)
  #expect(try word(duplicate)["word"] as? String == "Kestrel")

  let blank = await dispatcher.handle(.wordsAdd, args: ["word": "   "])
  #expect(outcome(blank) == "unchanged")
  #expect(payload(blank)?["word"] is NSNull)
  #expect(temp.coordinator.customWords.count == count)
  // The coordinator publishes after every accepted add, its no-op ones included.
  #expect(published.count == 3)
  #expect(published.last == temp.coordinator.customWords)
}

@Test("a built-in can be edited, removed and brought back through the same owner")
func builtinEditRemoveRestore() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)
  let builtin = try #require(temp.coordinator.customWords.first { $0.source == .builtin })
  let id = builtin.id.uuidString

  let removed = await dispatcher.handle(.wordsRemove, args: ["id": id])
  #expect(outcome(removed) == "removed")
  #expect(temp.coordinator.customWords.contains { $0.id == builtin.id } == false)

  let restored = await dispatcher.handle(
    .wordsAdd, args: ["word": builtin.canonical.uppercased()])
  #expect(outcome(restored) == "restored")
  #expect(try word(restored)["id"] as? String == id)
  #expect(try word(restored)["source"] as? String == "builtin")

  let edited = await dispatcher.handle(
    .wordsUpdate, args: ["id": id, "aliases": builtin.aliases + ["extra sound alike"]])
  #expect(outcome(edited) == "updated")
  #expect(try word(edited)["id"] as? String == id)
  #expect(try word(edited)["source"] as? String == "user")
  #expect((try word(edited)["aliases"] as? [String])?.contains("extra sound alike") == true)
}

@Test("an edit to a word another window deleted is dropped, and the reply says the target is gone")
func staleUpdateReportsTargetGone() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (_, dispatcher) = Self.make(words: temp.coordinator)
  let id = try #require(
    try word(await dispatcher.handle(.wordsAdd, args: ["word": "Quokka"]))["id"] as? String)
  let uuid = try #require(UUID(uuidString: id))

  // A second app copy removes the word straight from the shared file.
  let other = CustomWordsManager(fileURL: temp.url)
  var otherWords = try #require(other.load())
  try other.remove(id: uuid, from: &otherWords)
  #expect(temp.coordinator.customWords.contains { $0.id == uuid })

  let stale = await dispatcher.handle(.wordsUpdate, args: ["id": id, "aliases": ["quoka"]])
  #expect(outcome(stale) == "targetGone")
  #expect(payload(stale)?["word"] is NSNull)
  #expect(temp.coordinator.customWords.contains { $0.id == uuid } == false)
  #expect(
    try #require(CustomWordsManager(fileURL: temp.url).load()).contains { $0.id == uuid } == false)
}

@Test("word commands never enter a settings attribution scope or change a setting")
func wordCommandsLeaveSettingsAlone() async throws {
  let temp = DevControlFixtures.TempWords()
  defer { temp.cleanUp() }
  let (settings, dispatcher) = Self.make(words: temp.coordinator)
  var flags: [Bool] = []
  temp.coordinator.onWordsChanged = { _ in flags.append(settings.isDevControlWrite) }
  let before = try JSONSerialization.data(
    withJSONObject: DevControlSettings.catalog(settings), options: .sortedKeys)

  let id = try #require(
    try word(await dispatcher.handle(.wordsAdd, args: ["word": "Puffin"]))["id"] as? String)
  _ = await dispatcher.handle(.wordsUpdate, args: ["id": id, "aliases": ["puff in"]])
  _ = await dispatcher.handle(.wordsRemove, args: ["id": id])

  #expect(flags == [false, false, false])
  let after = try JSONSerialization.data(
    withJSONObject: DevControlSettings.catalog(settings), options: .sortedKeys)
  #expect(before == after)
}
  }

  /// Plain-value owners for the dispatcher's `status`, History and word commands.
  @MainActor
  enum DevControlFixtures {
    static func engine(
      selected: ASRBackendType = .parakeet, active: ASRBackendType = .parakeet,
      selectedReadiness: ASREngineReadiness = .ready, activeReadiness: ASREngineReadiness = .ready,
      switchPhase: EngineStatus.SwitchPhase = .idle, selectedInstalled: Bool = true,
      blockedReason: EngineStatus.BlockedReason? = nil, warmInFlight: ASRBackendType? = nil
    ) -> EngineStatus {
      EngineStatus(
        selected: selected, active: active, selectedReadiness: selectedReadiness,
        activeReadiness: activeReadiness, switchPhase: switchPhase,
        selectedInstalled: selectedInstalled, blockedReason: blockedReason,
        warmInFlight: warmInFlight)
    }

    /// A reference a test and a source closure share.
    @MainActor
    final class Box<Value> {
      var value: Value
      init(_ value: Value) { self.value = value }
    }

    /// A coordinator for tests that never change a word. The manager makes its folder at
    /// init; the folder is removed again once the coordinator has loaded (the built-ins), so
    /// nothing is left behind.
    static func unwrittenWords() -> CustomWordsCoordinator {
      let words = TempWords()
      words.cleanUp()
      return words.coordinator
    }

    /// A temporary word library this test owns: the coordinator, its file, and `cleanUp` to
    /// remove the folder made for it.
    @MainActor
    struct TempWords {
      let coordinator: CustomWordsCoordinator
      let url: URL
      let folder: URL

      init() {
        folder = TestTemporaryDirectory.url
          .appendingPathComponent("ew-3765-words-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("custom-words.json")
        coordinator = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
      }

      func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    static func history(_ rows: [Transcript]) -> DevControlDispatcher.HistorySource {
      DevControlDispatcher.HistorySource(visibleTranscripts: { rows })
    }

    /// The screen's credential writer over a fresh temporary key folder, a fresh presence and
    /// a discovery that answers with no models: never the real key files or Keychain.
    static func isolatedCredentials(
      presence: SavedKeyPresence = SavedKeyPresence(),
      storage: (any LegacyKeyFileStorage)? = nil,
      emit: @escaping CredentialWriter.Emit = { _, _, _ in }
    ) -> CredentialWriter {
      let folder = TestTemporaryDirectory.url
        .appending(path: "ew-tests-3765-keys-\(UUID().uuidString)")
      let keychain = KeychainManager(
        backend: .legacyFiles, legacyStore: storage ?? FileLegacyKeyStore(storageDirectory: folder))
      let discovery = LLMModelDiscoveryCoordinator(
        keychainManager: keychain,
        cacheDefaults: TestDefaults.suite("ew.tests.3765.keys.cache.\(UUID().uuidString)")!,
        savedKeyPresence: presence, discoverModels: { _, _ in [] })
      var writer = CredentialWriter(keychainManager: keychain, presence: presence, discovery: discovery)
      writer.emit = emit
      return writer
    }

    /// A dictation owner whose runtime is at rest and never mints a take: for suites that
    /// do not exercise dictation commands.
    static func inertDictation() -> DevControlDictation {
      DevControlDictation(
        launchID: UUID(),
        control: DevControlDictation.Control(
          activeBackend: { .parakeet }, driverState: { _ in .idle }, readiness: { _ in .ready },
          continuingTakeID: { _ in nil }, lastTakeID: { _ in nil },
          terminalFacts: { _, _ in .init(savedRowID: nil, historySaved: true) },
          start: {}, stop: {}, cancel: {},
          frontApp: .init(
            processes: { _ in [] }, activate: { _ in }, frontmost: { nil },
            waitUntilFrontmost: { _ in false })))
    }

    /// Records which model button a command pressed, in order. `onPress` lets a test move
    /// the matching status fact as a real owner would when it schedules work.
    @MainActor
    final class ModelFake {
      private(set) var pressed: [String] = []
      var onPress: (@MainActor (String) -> Void)?

      var actions: DevControlDispatcher.ModelActions {
        DevControlDispatcher.ModelActions(
          parakeetDownload: { [self] in press("parakeetDownload") },
          parakeetCancel: { [self] in press("parakeetCancel") },
          whisperDownload: { [self] in press("whisperDownload") },
          whisperCancel: { [self] in press("whisperCancel") })
      }

      private func press(_ action: String) {
        pressed.append(action)
        onPress?(action)
      }
    }

    /// Mutable owner facts; `sources` reads them at call time, so a test can change one
    /// between two requests. The closures hold the fake strongly, so a dispatcher built from
    /// a temporary fake keeps it alive.
    @MainActor
    final class StatusFake {
      var engine = DevControlFixtures.engine()
      var isSwitching = false
      var driverStates: [ASRBackendType: PipelineState] = [.parakeet: .idle, .whisper: .idle]
      var parakeet: DeliveryState = .notReady
      var whisper: WhisperSetupState = .checking
      var fileImportRunning = false
      var keys: [LLMProvider: SavedKeyState] = [:]
      var keyState: (@MainActor (LLMProvider) -> SavedKeyState)?
      var onRead: (@MainActor () -> Void)?
      private(set) var driverStateAsked: [ASRBackendType] = []

      var sources: DevControlDispatcher.StatusSources {
        DevControlDispatcher.StatusSources(
          engineStatus: { [self] in onRead?(); return engine },
          isSwitching: { [self] in isSwitching },
          driverState: { [self] backend in
            driverStateAsked.append(backend)
            return driverStates[backend] ?? .idle
          },
          parakeetDelivery: { [self] in parakeet },
          whisperSetup: { [self] in whisper },
          isFileImportRunning: { [self] in fileImportRunning },
          savedKeyState: { [self] provider in
            keyState?(provider) ?? keys[provider] ?? .unknown
          })
      }
    }
  }
#endif
