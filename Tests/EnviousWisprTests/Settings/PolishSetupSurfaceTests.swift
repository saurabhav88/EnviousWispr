import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #3438. The quiet reminders: the menu bar line, the History banner and the sidebar tag. When
/// this is wrong, a person whose polish is off is never reminded, a closed banner comes back for
/// the same problem, or a reminder shows while polish is off.
@MainActor
@Suite("AI polish setup reminders: menu, banner, sidebar (#3438)", .tags(.productOutcome))
struct PolishSetupSurfaceTests {

  @MainActor @Observable
  final class World {
    var onboardingComplete = true { didSet { onTransition?() } }
    var provider: LLMProvider = .openAI { didSet { onTransition?() } }
    var openAIKeySaved: Bool? = false
    var egOneInstall: EGOneInstallState = .installed(version: "1.2")
    @ObservationIgnored var onTransition: (() -> Void)?

    var inputs: PolishSetupInputs {
      PolishSetupInputs(
        onboardingComplete: onboardingComplete,
        configuration: PolishSetupConfiguration(
          provider: provider, model: provider == .none ? "" : "model",
          credentialRevision: provider == .openAI ? 1 : nil),
        facts: PolishSetupFacts(
          egOneInstall: egOneInstall, egOneHealth: .green,
          s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
          appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
          validationProvider: nil, cloudValidation: .idle,
          credentialRevisions: [.openAI: 1], cloudVerdicts: [:],
          openAIKeySaved: openAIKeySaved, geminiKeySaved: true, claudeKeySaved: true,
          ollamaSetup: .ready, ollamaModel: .installed),
        ollamaLastCommitAt: nil)
    }
  }

  private static func monitor(_ world: World) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(readInputs: { world.inputs })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    monitor.start()
    return monitor
  }

  @Test("a confirmed problem shows all three; off, onboarding, unknown and ready show none")
  func whenTheyShow() {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    for surface in [PolishSetupSurface.menu, .banner, .sidebarTag] {
      #expect(monitor.shows(surface), "\(surface)")
    }
    world.onboardingComplete = false
    #expect(monitor.shows(.menu) == false)
    world.onboardingComplete = true
    world.provider = .none
    #expect(monitor.shows(.sidebarTag) == false)
    world.provider = .openAI
    world.openAIKeySaved = nil
    _ = monitor.currentContext()
    #expect(monitor.shows(.banner) == false, "an unreadable key was treated as missing")
    world.openAIKeySaved = true
    _ = monitor.currentContext()
    #expect(monitor.shows(.menu) == false)
    // Downloading is informational: a leave notice only, no reminders.
    world.provider = .egOne
    world.egOneInstall = .downloading(fractionCompleted: 0.2, upgrade: nil)
    _ = monitor.currentContext()
    for surface in [PolishSetupSurface.menu, .banner, .sidebarTag] {
      #expect(monitor.shows(surface) == false, "\(surface)")
    }
  }

  @Test("Leave anyway hides none of them; closing the banner hides only the banner")
  func answersAreSeparate() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let episode = try #require(monitor.currentEpisode)
    monitor.acknowledge(.leaveDialog, in: episode)
    #expect(monitor.shows(.banner) && monitor.shows(.menu) && monitor.shows(.sidebarTag))
    monitor.acknowledge(.banner, in: episode)
    #expect(monitor.shows(.banner) == false)
    #expect(monitor.shows(.menu) && monitor.shows(.sidebarTag))
  }

  @Test("an old banner close does not close the banner for a new problem")
  func staleBannerClose() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let old = try #require(monitor.currentEpisode)
    world.openAIKeySaved = true
    _ = monitor.currentContext()
    world.openAIKeySaved = false
    _ = monitor.currentContext()
    monitor.acknowledge(.banner, in: old)
    #expect(monitor.shows(.banner))
  }

  @Test("the banner, menu line and tag read the approved words")
  func words() {
    #expect(PolishSetupSurfaceCopy.menuLine == "Finish setting up AI polish")
    #expect(PolishSetupSurfaceCopy.sidebarTag == "Set up")
    #expect(
      PolishSetupSurfaceCopy.banner(
        reason: PolishSetupSurfaceCopy.shortReason(.cloudKeyMissing(.openAI)))
        == "AI polish isn't set up: OpenAI needs an API key.")
    let reasons: [(PolishSetupProblem, String)] = [
      (.cloudKeyRejected(.claude), "Claude did not accept your API key"),
      (.ollamaNotRunning, "Ollama is not running"),
      (.ollamaNotInstalled, "Ollama is not installed"),
      (.ollamaNoModel, "Ollama needs a model"),
      (.ollamaModelNotInstalled, "the chosen Ollama model is not downloaded"),
      (.localEngineNotDownloaded(.egOne), "EG-1 is not downloaded yet"),
      (.localEngineDownloadPaused(.s1Mini), "the S1-mini download is paused"),
      (.localEngineUpdatePaused(.egOne), "the EG-1 update is paused"),
      (.localEngineFailed(.egOne), "the EG-1 download did not finish"),
      (.appleUnavailable(.unsupportedOS), "Apple Intelligence isn't available on this Mac"),
      (.appleUnavailable(.appleIntelligenceDisabled), "Apple Intelligence is turned off"),
    ]
    for (problem, reason) in reasons {
      let text = PolishSetupSurfaceCopy.shortReason(problem)
      #expect(text == reason, "\(problem)")
      #expect(text.hasSuffix(".") == false, "a short reason carries its own full stop")
    }
  }

  @Test("the sidebar row says 'Needs setup', not 'in progress'")
  func sidebarSpokenValue() {
    #expect(
      SettingsShellCopy.sidebarValue(isSelected: false, activity: .polishNeedsSetup)
        == "Not selected. Needs setup")
    #expect(
      SettingsShellCopy.sidebarValue(isSelected: true, activity: .polishNeedsSetup)
        == "Selected. Needs setup")
    #expect(
      SettingsShellCopy.sidebarValue(isSelected: false, activity: .fileImport)
        == "Not selected. Importing in progress")
  }
}
