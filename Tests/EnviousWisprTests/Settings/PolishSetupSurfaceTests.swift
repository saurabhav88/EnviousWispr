import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
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

  @MainActor
  final class PromptLog {
    var events: [PolishSetupPromptEvent] = []
  }

  private static func monitor(_ world: World, log: PromptLog) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs }, reportPrompt: { log.events.append($0) })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    monitor.start()
    return monitor
  }

  /// A new episode for the same configuration: repaired, then broken again.
  private static func newEpisode(_ world: World, _ monitor: PolishSetupMonitor) {
    world.openAIKeySaved = true
    _ = monitor.currentContext()
    world.openAIKeySaved = false
    _ = monitor.currentContext()
  }

  @Test("#4721: Close answers only the episodes the banner showed, each on its own monitor")
  func closeAnswersCapturedEpisodes() throws {
    let log = PromptLog()
    let dictationWorld = World()
    let summaryWorld = World()
    let dictation = Self.monitor(dictationWorld, log: log)
    let summary = Self.monitor(summaryWorld, log: log)
    defer { dictation.stop(); summary.stop() }
    // Distinct tokens across the two monitors, so a crossed acknowledgement cannot pass.
    Self.newEpisode(summaryWorld, summary)
    let shownDictation = try #require(PolishSetupBanner.shown(dictation))
    let shownSummary = try #require(PolishSetupBanner.shown(summary))
    try #require(shownDictation.episode != shownSummary.episode)

    // Dictation's problem is repaired and returns before the click: a newer episode.
    Self.newEpisode(dictationWorld, dictation)
    try #require(dictation.currentEpisode != shownDictation.episode)

    PolishSetupBanner.close(
      dictation: shownDictation, summary: shownSummary, dictationMonitor: dictation,
      summaryMonitor: summary)

    #expect(summary.shows(.banner) == false, "the summary banner the person closed is still up")
    #expect(dictation.shows(.banner), "an old close answered dictation's newer problem")
    #expect(log.events.map(\.surface) == [.banner, .summaryBanner])
    #expect(log.events.map(\.action) == [.closed, .closed])
  }

  @Test("#4721: Finish setup reports each named engine and goes where the warning says")
  func finishSetupRoutesAndReports() throws {
    let log = PromptLog()
    let dictation = Self.monitor(World(), log: log)
    let summary = Self.monitor(World(), log: log)
    defer { dictation.stop(); summary.stop() }
    let openAI = PolishSetupPromptSubject(problem: .cloudKeyMissing(.openAI), provider: .openAI)
    let claude = PolishSetupPromptSubject(problem: .cloudKeyRejected(.claude), provider: .claude)
    var requested: [SettingsDestination] = []
    var windowOpened = 0

    // Summary only, from the History banner: Summaries, no window request.
    let summaryOnly = try #require(PolishSetupWarningSubjects(dictation: nil, summary: claude))
    summaryOnly.finishSetup(
      dictationMonitor: dictation, summaryMonitor: summary, on: .banner,
      request: { requested.append($0) })
    #expect(requested == [.meetings(.summaries)])
    #expect(log.events.map(\.surface) == [.summaryBanner])

    // Summary only, from the menu: Summaries, and the window opens.
    log.events = []
    summaryOnly.finishSetup(
      dictationMonitor: dictation, summaryMonitor: summary, on: .menu,
      request: { requested.append($0) }, showWindow: { windowOpened += 1 })
    #expect(requested.last == .meetings(.summaries))
    #expect(windowOpened == 1)
    #expect(log.events.map(\.surface) == [.summaryMenu])

    // Both, from the menu: AI Polish first, one row per engine.
    log.events = []
    let both = try #require(PolishSetupWarningSubjects(dictation: openAI, summary: claude))
    both.finishSetup(
      dictationMonitor: dictation, summaryMonitor: summary, on: .menu,
      request: { requested.append($0) }, showWindow: { windowOpened += 1 })
    #expect(requested.last == .aiPolish)
    #expect(windowOpened == 2)
    #expect(log.events.map(\.surface) == [.menu, .summaryMenu])
    #expect(log.events.map(\.action) == [.finishSetup, .finishSetup])
    #expect(log.events.map(\.subject) == [openAI, claude])
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

/// Copy protection; reminder visibility is exercised separately above.
@MainActor
@Suite("AI polish setup reminder copy (#4016)", .tags(.driftGuard))
struct PolishSetupSurfaceCopyTests {
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
      (.appleUnavailable(.appleIntelligenceDisabled),
       ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
         ? "Apple Intelligence wasn't enabled" : "Apple Intelligence is turned off"),
    ]
    for (problem, reason) in reasons {
      let text = PolishSetupSurfaceCopy.shortReason(problem)
      #expect(text == reason, "\(problem)")
      #expect(text.hasSuffix(".") == false, "a short reason carries its own full stop")
    }
  }

  @Test("#4721: the banner and menu line name meeting summaries, or both engines")
  func summaryAndBothWords() throws {
    let openAI = PolishSetupPromptSubject(problem: .cloudKeyMissing(.openAI), provider: .openAI)
    let claude = PolishSetupPromptSubject(problem: .cloudKeyRejected(.claude), provider: .claude)
    let dictationOnly = try #require(PolishSetupWarningSubjects(dictation: openAI, summary: nil))
    let summaryOnly = try #require(PolishSetupWarningSubjects(dictation: nil, summary: claude))
    let both = try #require(PolishSetupWarningSubjects(dictation: openAI, summary: claude))

    #expect(PolishSetupSurfaceCopy.banner(dictationOnly) == "AI polish isn't set up: OpenAI needs an API key.")
    #expect(
      PolishSetupSurfaceCopy.banner(summaryOnly)
        == "Meeting summaries aren't set up: Claude did not accept your API key.")
    #expect(PolishSetupSurfaceCopy.banner(both) == "AI polish and meeting summaries both need attention.")

    #expect(PolishSetupSurfaceCopy.menuLine(dictationOnly) == "Finish setting up AI polish")
    #expect(PolishSetupSurfaceCopy.menuLine(summaryOnly) == "Finish setting up meeting summaries")
    #expect(PolishSetupSurfaceCopy.menuLine(both) == "Finish setting up AI polish and meeting summaries")

    #expect(PolishSetupBanner.closeLabel(dictationOnly) == "Close the AI polish setup notice")
    #expect(PolishSetupBanner.closeLabel(summaryOnly) == "Close")
    #expect(PolishSetupBanner.closeLabel(both) == "Close")
  }

  // #4473: setup messages name the EG-1 size.
  @Test("engineName names an EG-1 size, and nothing else changes")
  func engineNameTable() {
    let rows: [(LLMProvider, EGOneSize?, String)] = [
      (.egOne, .full, "EG-1"),
      (.egOne, .mini, "EG-1 Mini"),
      (.egOne, .micro, "EG-1 Micro"),
      (.egOne, nil, "EG-1"),
      (.s1Mini, nil, LLMProvider.s1Mini.displayName),
      (.s1Mini, .micro, LLMProvider.s1Mini.displayName),
      (.openAI, .micro, LLMProvider.openAI.displayName),
    ]
    for (provider, size, expected) in rows {
      #expect(
        PolishSetupSurfaceCopy.engineName(provider, egOneSize: size) == expected,
        "\(provider) \(String(describing: size))")
    }
  }

  @Test("the six local-engine reasons name the EG-1 size; nil keeps plain EG-1")
  func shortReasonNamesTheSize() {
    let problems: [PolishSetupProblem] = [
      .localEngineNotDownloaded(.egOne), .localEngineDownloadPaused(.egOne),
      .localEngineUpdatePaused(.egOne), .localEngineFailed(.egOne),
      .localEngineDownloading(.egOne), .localEngineVerifying(.egOne),
    ]
    for problem in problems {
      #expect(
        PolishSetupSurfaceCopy.shortReason(problem, egOneSize: .micro).contains("EG-1 Micro"),
        "\(problem)")
      #expect(
        PolishSetupSurfaceCopy.shortReason(problem, egOneSize: .mini).contains("EG-1 Mini"),
        "\(problem)")
      let plain = PolishSetupSurfaceCopy.shortReason(problem, egOneSize: nil)
      #expect(plain.contains("EG-1"), "\(problem)")
      #expect(plain.contains("Micro") == false, "\(problem)")
    }
  }

  @Test("a size changes nothing for S1-mini or for a non-local problem")
  func sizeIgnoredElsewhere() {
    let s1: [PolishSetupProblem] = [
      .localEngineNotDownloaded(.s1Mini), .localEngineDownloadPaused(.s1Mini),
      .localEngineUpdatePaused(.s1Mini), .localEngineFailed(.s1Mini),
      .localEngineDownloading(.s1Mini), .localEngineVerifying(.s1Mini),
      .cloudKeyMissing(.openAI),
    ]
    for problem in s1 {
      #expect(
        PolishSetupSurfaceCopy.shortReason(problem, egOneSize: .micro)
          == PolishSetupSurfaceCopy.shortReason(problem, egOneSize: nil),
        "\(problem)")
    }
    #expect(
      PolishSetupSurfaceCopy.shortReason(.localEngineNotDownloaded(.s1Mini), egOneSize: .micro)
        .contains("EG-1") == false)
  }
}
