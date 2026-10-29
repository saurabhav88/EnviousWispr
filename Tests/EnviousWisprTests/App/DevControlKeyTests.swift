#if DEBUG
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprLLM

  /// #3765: the dev control door's keys.set and keys.clear, through the screen's own
  /// credential writer over a temporary key folder.
  ///
  /// Harness Contract: a UAT script stages a provider's key through this. When it fails, a
  /// script believes a key is saved that is not, or the key shows up in a reply. No customer
  /// sees it.
  @Suite(.tags(.harnessContract))
  @MainActor
  struct DevControlKeyTests {
    @MainActor
    final class Events {
      var seen: [[String]] = []
    }

    private struct FailingStorage: LegacyKeyFileStorage {
      func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-25308) }
      func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-25300) }
      func delete(key: String) throws { throw KeyStoreError.deleteFailed(-25308) }
    }

    private struct Fixture {
      let dispatcher: DevControlDispatcher
      let presence: SavedKeyPresence
      let events: Events
      let settings: SettingsManager
    }

    private static func make(
      failing: Bool = false, storage: (any LegacyKeyFileStorage)? = nil
    ) -> Fixture {
      let presence = SavedKeyPresence()
      let events = Events()
      let status = DevControlFixtures.StatusFake()
      status.keyState = { presence.state(for: $0) }
      let settings = SettingsManager(
        defaults: TestDefaults.suite("ew.tests.3765.keys.\(UUID().uuidString)")!)
      let dispatcher = DevControlDispatcher(
        settings: settings,
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          loadCachedModelCatalog: { _, _ in },
          connectedInputUIDs: { [] }, inputChannelCounts: { [:] }, pillWordsCapability: { .available }),
        status: status.sources,
        history: DevControlFixtures.history([]),
        models: DevControlFixtures.ModelFake().actions,
        dictation: DevControlFixtures.inertDictation(),
        credentials: DevControlFixtures.isolatedCredentials(
          presence: presence, storage: storage ?? (failing ? FailingStorage() : nil),
          emit: { events.seen.append([$0, $1, $2]) }),
        words: DevControlFixtures.unwrittenWords(), meetings: .unwired())
      return Fixture(dispatcher: dispatcher, presence: presence, events: events, settings: settings)
    }

    private func payload(_ result: DevControlDispatcher.Result) -> [String: Any]? {
      if case .ok(let payload, _) = result { return payload }
      return nil
    }

    private func code(_ result: DevControlDispatcher.Result) -> String? {
      if case .error(let code, _) = result { return code }
      return nil
    }

    private func message(_ result: DevControlDispatcher.Result) -> String {
      if case .error(_, let message) = result { return message }
      return ""
    }

    private static let providers: [LLMProvider] = [.openAI, .gemini, .claude]

    @Test("a cancelled key command reconciles storage without holding dev-write attribution")
    func cancellationReconcilesWithoutLeakingAttribution() async throws {
      let storage = ThreadRecordingCredentialStore(pausing: .store)
      let fx = Self.make(storage: storage)
      defer { storage.release() }
      var accepted = false
      let request = Task {
        let result = await fx.dispatcher.handle(.keysSet,
          args: ["provider": "openAI", "value": "synthetic"])
        accepted = payload(result)?["stored"] as? Bool == true
      }
      try #require(await storage.entered.wait())
      #expect(fx.settings.isDevControlWrite == false)
      #expect(fx.events.seen.isEmpty)
      #expect(fx.presence.state(for: .openAI) == .unknown)
      #expect(fx.presence.hasPendingMutation(for: .openAI) == true)
      request.cancel()
      storage.release()
      await request.value
      #expect(accepted == true)
      #expect(fx.presence.hasPendingMutation(for: .openAI) == false)
      #expect(fx.settings.isDevControlWrite == false)
      #expect(fx.presence.state(for: .openAI) == .present)
      #expect(fx.events.seen == [["openAI", "save", "success"]])
    }

    @Test("keys.set stores, reports presence and a started check, and never echoes the key")
    func setStoresWithoutEcho() async throws {
      for provider in Self.providers {
        let fx = Self.make()
        let before = try #require(fx.presence.revision(for: provider))
        let secret = "sk-synthetic-\(UUID().uuidString)"
        let result = await fx.dispatcher.handle(
          .keysSet, args: ["provider": provider.rawValue, "value": secret])
        let reply = try #require(payload(result), "\(provider): \(message(result))")
        #expect(reply["provider"] as? String == provider.rawValue)
        #expect(reply["stored"] as? Bool == true)
        #expect(reply["presence"] as? String == "present")
        #expect(reply["validation"] as? String == "started")
        #expect(fx.presence.revision(for: provider) == before + 1)
        let encoded = String(
          decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        #expect(encoded.contains(secret) == false)
        #expect(fx.events.seen == [[provider.rawValue, "save", "success"]])
      }
    }

    @Test("keys.clear clears and reports absent, with one remove event")
    func clearReportsAbsent() async throws {
      for provider in Self.providers {
        let fx = Self.make()
        _ = await fx.dispatcher.handle(.keysSet, args: ["provider": provider.rawValue, "value": "x"])
        let reply = try #require(
          payload(
            await fx.dispatcher.handle(
              .keysClear, args: ["provider": provider.rawValue])))
        #expect(reply["cleared"] as? Bool == true)
        #expect(reply["presence"] as? String == "absent")
        #expect(fx.events.seen.last == [provider.rawValue, "remove", "success"])
        #expect(fx.events.seen.count == 2)
      }
    }

    @Test("a refused store or clear is storeFailed, the key unknown, and no owner text leaks")
    func refusedStoreIsUncertain() async throws {
      for provider in Self.providers {
        let fx = Self.make(failing: true)
        let saved = await fx.dispatcher.handle(
          .keysSet, args: ["provider": provider.rawValue, "value": "sk-synthetic"])
        #expect(code(saved) == "storeFailed")
        #expect(message(saved).contains("25308") == false)
        #expect(message(saved).contains("sk-synthetic") == false)
        #expect(fx.presence.state(for: provider) == .unknown)
        let cleared = await fx.dispatcher.handle(.keysClear, args: ["provider": provider.rawValue])
        #expect(code(cleared) == "storeFailed")
        #expect(fx.presence.state(for: provider) == .unknown)
        #expect(
          fx.events.seen == [
            [provider.rawValue, "save", "failure"], [provider.rawValue, "remove", "failure"],
          ])
      }
    }

    @Test("malformed requests are refused before the writer is reached")
    func malformedRequests() async {
      let fx = Self.make()
      let cases: [([String: Any], DevControlDispatcher.Command, String)] = [
        ([:], .keysSet, "badArgs"),
        (["provider": "openAI"], .keysSet, "badArgs"),
        (["provider": "openAI", "value": ""], .keysSet, "badArgs"),
        (["provider": "openAI", "value": 3], .keysSet, "badArgs"),
        (["provider": "openAI", "value": "x", "keyID": "other"], .keysSet, "badArgs"),
        (["provider": "ollama", "value": "x"], .keysSet, "badValue"),
        (["provider": "openai", "value": "x"], .keysSet, "badValue"),
        (["provider": "openAI", "value": "x"], .keysClear, "badArgs"),
        (["provider": "appleIntelligence"], .keysClear, "badValue"),
      ]
      for (args, command, expected) in cases {
        #expect(code(await fx.dispatcher.handle(command, args: args)) == expected, "\(args)")
      }
      #expect(fx.events.seen.isEmpty)
      for provider in Self.providers {
        #expect(fx.presence.state(for: provider) == .unknown)
      }
    }
  }
#endif
