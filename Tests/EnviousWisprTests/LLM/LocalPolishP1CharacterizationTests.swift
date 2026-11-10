import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprLLM

/// #4473 phase P1: the contracts the engine-boundary extraction must not change, pinned against
/// today's code BEFORE anything moves. When one of these fails after a move, the extraction
/// changed behavior for EG-1 or S1-mini: a wrong launch flag, a model health-checked as the other
/// one, a paused download that forgets it was paused, or a provider with no local model getting
/// an engine.
@Suite("Local polish contracts frozen before the engine split (#4473 P1)", .tags(.driftGuard))
struct LocalPolishP1CharacterizationTests {
  /// Every provider that has no bundled local model. Written out, not derived, so a new case
  /// has to be classified here by hand.
  static let providersWithoutABundledModel: [LLMProvider] = [
    .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none,
  ]

  // MARK: - Probe identity

  @Test("each bundled model is health-checked as itself, with its own connector")
  func probeSpecsNameTheirOwnModel() {
    let endpoint = EGOneEndpoint(port: 1, authToken: "t", contextTokens: 1)

    let egOne = LlamaServerHealthProbe.ProbeSpec.egOne
    #expect(egOne.provider == .egOne)
    #expect(egOne.modelID == "eg-1")
    #expect(egOne.makeConnector(endpoint) is EGOneConnector)

    let s1Mini = LlamaServerHealthProbe.ProbeSpec.s1Mini
    #expect(s1Mini.provider == .s1Mini)
    #expect(s1Mini.modelID == "s1-mini")
    #expect(s1Mini.makeConnector(endpoint) is S1MiniConnector)
  }

  // MARK: - Launch arguments

  @Test("the complete launch flags of both engines, with and without a word-check adapter")
  func completeLaunchArguments() {
    let footprint = ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    let egOne = footprint + ["--spec-type", "ngram-simple"]
    let s1Mini = footprint + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#]
    let adapter = URL(fileURLWithPath: "/tmp/ew-p1/checker.gguf")
    // Scale 0 at launch, nine slots (one polish slot plus eight checker slots), one shared cache.
    let adapterFlags = [
      "--lora-scaled", "/tmp/ew-p1/checker.gguf:0",
      "-np", "9", "--kv-unified", "--no-cache-idle-slots",
    ]

    #expect(LlamaServerLaunchBuilder.launchArguments(for: .egOne, learnedWordAdapterURL: nil) == egOne)
    #expect(LlamaServerLaunchBuilder.launchArguments(for: .s1Mini, learnedWordAdapterURL: nil) == s1Mini)
    #expect(
      LlamaServerLaunchBuilder.launchArguments(for: .egOne, learnedWordAdapterURL: adapter)
        == egOne + adapterFlags)
    #expect(
      LlamaServerLaunchBuilder.launchArguments(for: .s1Mini, learnedWordAdapterURL: adapter)
        == s1Mini + adapterFlags)
  }

  // MARK: - Runtime lookup

  @MainActor
  @Test("a bundled provider gets its own runtime and every other provider gets none")
  func runtimeLookup() throws {
    let suite = "ew-p1-lookup-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer { store.removePersistentDomain(forName: suite) }
    let coordinator = LocalPolishServerCoordinator()
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make, defaults: store,
      coordinator: coordinator, provider: .egOne)
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make, defaults: store,
      coordinator: coordinator, provider: .s1Mini)
    let set = LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1Mini)

    #expect(set.runtime(for: .singleModel(for: .egOne)) === egOne)
    #expect(set.runtime(for: .singleModel(for: .s1Mini)) === s1Mini)
    for provider in Self.providersWithoutABundledModel {
      #expect(
        set.runtime(for: .singleModel(for: provider)) == nil,
        "\(provider) must have no local runtime")
    }
  }

  // MARK: - Persisted keys

  /// Collects the runtime's events; the runtime calls back on the main actor, synchronously
  /// inside `applyInstallStateForTesting`, so no waiting is involved.
  private final class EventBox: Sendable {
    private let events = OSAllocatedUnfairLock<[EGOnePausedInstallState?]>(initialState: [])
    func record(_ event: EGOneRuntimeEvent) {
      if case .pausedInstallStateChanged(let state) = event {
        events.withLock { $0.append(state) }
      }
    }
    var paused: [EGOnePausedInstallState?] { events.withLock { $0 } }
  }

  @MainActor
  @Test("each model keeps its own paused-download key, and neither reads the other's")
  func pausedProjectionKeysArePerModel() throws {
    let suite = "ew-p1-paused-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer { store.removePersistentDomain(forName: suite) }
    let egKey = "eg1.pausedInstallProjection"
    let s1Key = "s1.pausedInstallProjection"

    // Update: a pause is written under the model's own key only.
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make, defaults: store, provider: .egOne)
    egOne.applyInstallStateForTesting(.paused)
    #expect(store.string(forKey: egKey) == "paused")
    #expect(store.string(forKey: s1Key) == nil)

    // Isolation: S1-mini starts with no pause of its own although EG-1's is stored, so its
    // first pause is reported as a new entry.
    let s1Events = EventBox()
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make, defaults: store, provider: .s1Mini)
    s1Mini.onEvent = { s1Events.record($0) }
    s1Mini.applyInstallStateForTesting(.paused)
    #expect(s1Events.paused == [.paused])
    #expect(store.string(forKey: s1Key) == "paused")
    #expect(store.string(forKey: egKey) == "paused")

    // Restoration: a new EG-1 runtime reads the stored pause, so the same state is not
    // reported a second time, and leaving the pause clears the key.
    let restoredEvents = EventBox()
    let restored = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make, defaults: store, provider: .egOne)
    restored.onEvent = { restoredEvents.record($0) }
    restored.applyInstallStateForTesting(.paused)
    #expect(restoredEvents.paused.isEmpty)
    restored.applyInstallStateForTesting(.installed(version: nil))
    #expect(restoredEvents.paused == [nil])
    #expect(store.string(forKey: egKey) == nil)
    #expect(store.string(forKey: s1Key) == "paused")

    // Nothing else is persisted by these runtimes: no size key exists in P1.
    #expect(Set(store.persistentDomain(forName: suite)?.keys.map { $0 } ?? []) == [s1Key])
  }

  // MARK: - Providers without a bundled model are refused

  @Test(
    "building a local runtime for a provider with no bundled model stops the process",
    arguments: providersWithoutABundledModel)
  func runtimeConstructionRefuses(provider: LLMProvider) async {
    await #expect(processExitsWith: .failure) { [raw = provider.rawValue as String] in
      await MainActor.run {
        _ = EGOneRuntime(
          manifest: nil, serverBinaryURL: nil, delivery: nil,
          makeHealthProbe: LlamaServerHealthProbe.make,
          provider: LLMProvider(rawValue: raw) ?? .none)
      }
    }
  }

  /// Control for the two refusal tests: the same child-process calls with a bundled provider
  /// exit cleanly, so a refusal above is the provider check and not a crash from the rig.
  @Test("the same calls with a bundled provider do not stop the process")
  func bundledProvidersAreAccepted() async {
    await #expect(processExitsWith: .success) {
      await MainActor.run {
        _ = EGOneRuntime(
          manifest: nil, serverBinaryURL: nil, delivery: nil,
          makeHealthProbe: LlamaServerHealthProbe.make, provider: .s1Mini)
      }
      _ = LlamaServerLaunchBuilder.launchArguments(for: .egOne, learnedWordAdapterURL: nil)
    }
  }

  @Test(
    "asking for engine launch flags for a provider with no bundled model stops the process",
    arguments: providersWithoutABundledModel)
  func launchRoutingRefuses(provider: LLMProvider) async {
    await #expect(processExitsWith: .failure) { [raw = provider.rawValue as String] in
      _ = LlamaServerLaunchBuilder.launchArguments(
        for: LLMProvider(rawValue: raw) ?? .none, learnedWordAdapterURL: nil)
    }
  }
}
