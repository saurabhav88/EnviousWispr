import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// `polish_setup.prompt` carries closed values, never content (#3438 M2).
///
/// When this fails, the "Polish setup prompts" funnel reads a field that is not there, two
/// problems share one tag, or a key, a model name or other text reaches the vendor.
#if DEBUG

  @MainActor
  @Suite("AI polish setup prompt telemetry contract (#3438)", .tags(.observabilityContract))
  struct PolishSetupPromptTelemetryTests {

    private final class EventBox: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("four closed string fields, plus take_id only on a card row, and nothing else")
    func payloadShape() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { box.events.append($0) }
      defer { TelemetryService.shared.testEventHook = nil }

      PolishSetupPromptEvent(
        surface: .leaveDialog, action: .shown,
        subject: .init(problem: .cloudKeyMissing(.openAI), provider: .openAI), takeID: nil
      ).send()
      let take = UUID()
      PolishSetupPromptEvent(
        surface: .card, action: .notNow,
        subject: .init(problem: .localEngineNotDownloaded(.egOne), provider: .egOne),
        takeID: take
      ).send()

      #expect(box.events.count == 2)
      let leave = try #require(box.events.first)
      #expect(leave.name == "polish_setup.prompt")
      #expect(
        leave.stringProps == [
          "surface": "leave_dialog", "action": "shown", "problem": "cloud_key_missing",
          "provider": "openAI",
        ])
      #expect(leave.intProps.isEmpty && leave.doubleProps.isEmpty && leave.boolProps.isEmpty)
      let card = try #require(box.events.last)
      #expect(
        card.stringProps == [
          "surface": "card", "action": "not_now", "problem": "local_not_downloaded",
          "provider": "egOne", "take_id": take.uuidString,
        ])
    }

    @Test("the vocabularies are the approved ones")
    func vocabularies() {
      #expect(
        Set(PolishSetupPromptEvent.Surface.allCases.map(\.rawValue)) == [
          "leave_dialog", "card", "banner", "menu",
        ])
      #expect(
        Set(PolishSetupPromptEvent.Action.allCases.map(\.rawValue)) == [
          "shown", "finish_setup", "go_back", "leave_anyway", "not_now", "closed",
          "open_system_settings", "ok",
        ])
      #expect(PolishSetupLeaveAction.finishSetup.promptAction == .finishSetup)
      #expect(PolishSetupLeaveAction.goBack(.gemini).promptAction == .goBack)
      #expect(PolishSetupLeaveAction.leaveAnyway.promptAction == .leaveAnyway)
      #expect(PolishSetupLeaveAction.ok.promptAction == .ok)
      #expect(PolishSetupLeaveAction.openSystemSettings.promptAction == .openSystemSettings)
    }

    @Test("Escape on the leave question reports closed; a click or Return reports the button")
    func escapeIsAClose() throws {
      func key(_ code: UInt16) throws -> NSEvent {
        try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: code))
      }
      let click = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
      let finish = PolishSetupLeaveAction.finishSetup
      #expect(finish.promptAction(isCancelRole: true, event: try key(53)) == .closed)
      #expect(PolishSetupLeaveAction.ok.promptAction(isCancelRole: true, event: try key(53)) == .closed)
      #expect(finish.promptAction(isCancelRole: true, event: click) == .finishSetup)
      #expect(finish.promptAction(isCancelRole: true, event: try key(36)) == .finishSetup)
      #expect(finish.promptAction(isCancelRole: true, event: nil) == .finishSetup)
      // Only the cancel-role button answers Escape; another button never reports closed.
      #expect(
        PolishSetupLeaveAction.leaveAnyway.promptAction(isCancelRole: false, event: try key(53))
          == .leaveAnyway)
    }

    @Test("every problem has its own tag, and no tag names a provider")
    func problemTags() {
      let problems: [PolishSetupProblem] = [
        .cloudKeyMissing(.openAI), .cloudKeyRejected(.claude), .ollamaNotInstalled,
        .ollamaNotRunning, .ollamaNoModel, .ollamaModelNotInstalled,
        .localEngineNotDownloaded(.egOne), .localEngineDownloadPaused(.egOne),
        .localEngineUpdatePaused(.egOne), .localEngineFailed(.egOne),
        .localEngineDownloading(.egOne), .localEngineVerifying(.egOne),
        .appleUnavailable(.unsupportedOS), .appleUnavailable(.appleIntelligenceDisabled),
        .appleModelNotReady,
      ]
      let tags = problems.map(\.telemetryTag)
      #expect(Set(tags).count == problems.count, "two problems share a tag: \(tags)")
      for tag in tags {
        #expect(tag.allSatisfy { $0.isLowercase || $0 == "_" }, "\(tag) is not snake_case")
      }
      // The provider is its own field; the tag stays the same for every provider.
      #expect(
        PolishSetupProblem.cloudKeyMissing(.openAI).telemetryTag
          == PolishSetupProblem.cloudKeyMissing(.gemini).telemetryTag)
      #expect(
        PolishSetupProblem.localEngineFailed(.egOne).telemetryTag
          == PolishSetupProblem.localEngineFailed(.s1Mini).telemetryTag)
    }

    // MARK: - A row is about what the surface showed

    @MainActor @Observable
    final class World {
      var provider: LLMProvider = .openAI { didSet { onTransition?() } }
      var openAIKeySaved: Bool? = false
      @ObservationIgnored var onTransition: (() -> Void)?

      var inputs: PolishSetupInputs {
        PolishSetupInputs(
          onboardingComplete: true,
          configuration: PolishSetupConfiguration(
            provider: provider, model: "model",
            credentialRevision: provider == .openAI ? 1 : nil),
          facts: PolishSetupFacts(
            egOneInstall: .installed(version: "1.2"), egOneHealth: .green,
            s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
            appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
            validationProvider: nil, cloudValidation: .idle,
            credentialRevisions: [.openAI: 1], cloudVerdicts: [:],
            openAIKeySaved: openAIKeySaved, geminiKeySaved: true, claudeKeySaved: true,
            ollamaSetup: .ready, ollamaModel: .installed),
          ollamaLastCommitAt: nil)
      }
    }

    private final class Reported {
      var rows: [PolishSetupPromptEvent] = []
    }

    private static func monitor(_ world: World, into reported: Reported) -> PolishSetupMonitor {
      let monitor = PolishSetupMonitor(
        readInputs: { world.inputs }, reportPrompt: { reported.rows.append($0) })
      world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
      monitor.start()
      return monitor
    }

    private static let openAIKeyMissing = PolishSetupPromptSubject(
      problem: .cloudKeyMissing(.openAI), provider: .openAI)

    @Test("the subject is the shown problem with the provider of the episode that has it")
    func subjectPairsProblemAndProvider() {
      let world = World()
      let reported = Reported()
      let monitor = Self.monitor(world, into: reported)
      defer { monitor.stop() }
      #expect(monitor.promptSubject == Self.openAIKeyMissing)
      // Gemini has a saved key: nothing to show, so no subject.
      world.provider = .gemini
      #expect(monitor.promptSubject == nil)
    }

    @Test("a leave question answered after a model change still reports what it asked about")
    func staleLeaveQuestion() throws {
      let world = World()
      let reported = Reported()
      let monitor = Self.monitor(world, into: reported)
      defer { monitor.stop() }
      let request = try #require(
        PolishSetupLeaveGuard.request(
          for: .sidebar(.history), from: .aiPolish, monitor: monitor, previousProvider: nil,
          currentProvider: world.provider, keyNotSaved: false))
      #expect(request.promptSubject == Self.openAIKeyMissing)
      // The model changes before the answer (here: to one that is set up).
      world.provider = .gemini
      monitor.recordPrompt(.leaveDialog, .leaveAnyway, subject: request.promptSubject)
      #expect(
        reported.rows == [
          PolishSetupPromptEvent(
            surface: .leaveDialog, action: .leaveAnyway, subject: Self.openAIKeyMissing,
            takeID: nil)
        ])
    }

    @Test("a banner closed after the setup was finished still reports what it showed")
    func staleBannerClose() throws {
      let world = World()
      let reported = Reported()
      let monitor = Self.monitor(world, into: reported)
      defer { monitor.stop() }
      // What the banner takes when it draws.
      let drawn = try #require(monitor.promptSubject)
      world.openAIKeySaved = true
      _ = monitor.currentContext()
      #expect(monitor.promptSubject == nil)
      monitor.recordPrompt(.banner, .closed, subject: drawn)
      #expect(reported.rows.map(\.subject) == [Self.openAIKeyMissing])
      #expect(reported.rows.map(\.surface) == [.banner])
    }
  }

#endif
