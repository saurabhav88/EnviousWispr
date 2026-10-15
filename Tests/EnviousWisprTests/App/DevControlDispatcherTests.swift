#if DEBUG
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

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
          connectedInputUIDs: { ["mic-a"] }))
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

    @Test("settings.list returns all 70 rows; settings.get returns one, and refuses bad keys")
    func listAndGet() async throws {
      let (settings, dispatcher) = Self.make()
      let listed = try #require(payload(await dispatcher.handle(.settingsList, args: [:])))
      let rows = try #require(listed["settings"] as? [[String: Any]])
      #expect(rows.count == 70)

      settings.fillerRemovalEnabled = false
      let got = try #require(
        payload(await dispatcher.handle(.settingsGet, args: ["key": "fillerRemovalEnabled"])))
      #expect(got["key"] as? String == "fillerRemovalEnabled")
      #expect(got["value"] as? Bool == false)
      #expect(got["kind"] as? String == "direct")

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

    @Test("a deferred key refuses an ordinary write and accepts a forced one")
    func deferredKeyThroughDispatch() async throws {
      let (settings, dispatcher) = Self.make()
      let before = settings.toggleKeyCode
      let target: UInt16 = before == 12 ? 13 : 12
      #expect(
        code(
          await dispatcher.handle(
            .settingsSet, args: ["key": "toggleKeyCode", "value": NSNumber(value: target)]))
          == "checkNotYetShared")
      #expect(settings.toggleKeyCode == before)
      let forced = await dispatcher.handle(
        .settingsSet,
        args: ["key": "toggleKeyCode", "value": NSNumber(value: target), "force": true])
      #expect(forcedFlag(forced) == true)
      #expect(settings.toggleKeyCode == target)
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
        await dispatcher.handle(.settingsSet, args: ["key": "toggleKeyCode", "value": 1]),
        await dispatcher.handle(
          .settingsSet, args: ["key": "selectedInputDeviceUID", "value": "mic-z"]),
      ]
      for result in results {
        let found = try #require(code(result))
        #expect(vocabulary.contains(found), "\(found)")
      }
    }
  }
#endif
