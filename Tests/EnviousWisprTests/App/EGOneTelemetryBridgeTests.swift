import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The runtime-event bridge for both bundled engines (#2649, cloud review).
/// The S1-mini runtime had no handler at all, so every S1-mini health and
/// paused-install signal was dropped and the rollout dashboards read as if the
/// engine never changed state. When this fails, a dashboard lies by omission.
@MainActor
@Suite("EG-1 telemetry bridge carries the engine (#2649)", .tags(.observabilityContract))
struct EGOneTelemetryBridgeTests {

  // testEventHook is DEBUG-only (CI also compiles tests in release).
  #if DEBUG
    @Test("a health change from either engine lands on eg1.health_changed with its engine")
    func healthChangeCarriesEngine() async throws {
      for engine in [LLMProvider.egOne, .s1Mini] {
        let waiter = TelemetryEventWaiter()
        TelemetryService.shared.testEventHook = { @Sendable event in
          MainActor.assumeIsolated { waiter.record(event) }
        }
        defer { TelemetryService.shared.testEventHook = nil }

        EGOneTelemetryBridge.handler(engine: engine)(
          .healthChanged(from: "yellow", to: "green", reason: nil))

        let event = try await waiter.waitForEvent(named: "eg1.health_changed")
        #expect(event.stringProps["engine"] == engine.rawValue, Comment(rawValue: engine.rawValue))
        #expect(event.stringProps["from"] == "yellow")
        #expect(event.stringProps["to"] == "green")
        #expect(event.stringProps["reason"] == "none")
      }
    }

    @Test("a paused-install change carries the engine too")
    func pausedInstallCarriesEngine() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      EGOneTelemetryBridge.handler(engine: .s1Mini)(.pausedInstallStateChanged(nil))

      let event = try await waiter.waitForEvent(named: "eg1.paused_install_state_changed")
      #expect(event.stringProps["engine"] == LLMProvider.s1Mini.rawValue)
      #expect(event.stringProps["state"] == "none")
    }
  #endif

  /// The composition root must wire BOTH runtimes. A source scan, because the
  /// bootstrapper needs the whole app to construct; the twin-assignment shape is
  /// what the cloud review found missing.
  @Test("the bootstrapper wires an event handler for each bundled engine")
  func bootstrapperWiresBothRuntimes() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"),
      encoding: .utf8)
    #expect(source.contains("egOneRuntime.onEvent = EGOneTelemetryBridge.handler(engine: .egOne)"))
    #expect(
      source.contains("s1MiniRuntime.onEvent = EGOneTelemetryBridge.handler(engine: .s1Mini)"))
  }
}
