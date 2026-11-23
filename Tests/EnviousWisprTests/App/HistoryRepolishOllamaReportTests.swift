import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3853 (#4851). Class: `.productOutcome`: when these fail, an Ollama model a Polish again with
/// run used is never reported to the unload owner (it stays in memory about an hour), or is
/// reported before the run's pin clears (an unpinned model can be unloaded in the middle of the
/// polish).
@MainActor
@Suite("History repolish reports its Ollama model (#4851)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct HistoryRepolishOllamaReportTests {
  @MainActor
  final class Log { var events: [String] = [] }

  private func makeRunner(
    rig: ImportedTranscriberRig, choice: HistoryPolishChoice, log: Log,
    prepared: Bool = true, polish: @escaping @MainActor (String, String?) async throws -> String?
  ) -> HistoryRepolishRunner {
    HistoryRepolishRunner(
      choices: { _ in [choice] }, admission: .live(lease: rig.lease, as: .fileImport),
      freeze: { backend, _, _ in
        .init(
          settings: rig.snapshot(backend),
          configuration: .init(
            polishIsCloud: false, localPolishModel: nil, polishProvider: rig.polishProvider,
            ollamaModel: nil, polishModel: rig.polishModelName, backendType: backend))
      },
      cleanup: .init(
        freeze: { rig.snapshot($0).asFrozenRun(rig) },
        prepareLocalPolish: { _ in prepared },
        processParts: { _, _, _ in },
        release: { log.events.append("release") }),
      polishDictation: { text, language in
        log.events.append("polish")
        return try await polish(text, language)
      },
      meetingInfo: { _ in nil },
      ollamaModelUsed: { log.events.append("used:\($0)") })
  }

  private func ollamaRig() -> ImportedTranscriberRig {
    let rig = ImportedTranscriberRig()
    rig.polishProvider = .ollama
    rig.polishModelName = "qwen3:8b"
    return rig
  }

  private let choice = HistoryPolishChoice(provider: .ollama, model: "qwen3:8b")
  private let row = Transcript(text: "please remind the team about friday")

  @Test("an Ollama run reports its model after polish and before the release retry")
  func reportsAtTeardown() async throws {
    let rig = ollamaRig()
    let log = Log()
    let runner = makeRunner(rig: rig, choice: choice, log: log) { text, _ in text }
    _ = try await runner.candidate(for: row, choice: choice)
    #expect(log.events == ["polish", "used:qwen3:8b", "release"])
  }

  @Test("a cancelled polish still reports the model it may have loaded")
  func reportsAfterCancellation() async {
    let rig = ollamaRig()
    let log = Log()
    let runner = makeRunner(rig: rig, choice: choice, log: log) { _, _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
      _ = try await runner.candidate(for: row, choice: choice)
    }
    #expect(log.events == ["polish", "used:qwen3:8b", "release"])
  }

  @Test("a run that leaves before polish reports nothing")
  func exitBeforePolishReportsNothing() async {
    let rig = ollamaRig()
    let log = Log()
    let runner = makeRunner(rig: rig, choice: choice, log: log, prepared: false) { text, _ in text }
    await #expect(throws: HistoryRepolishRunner.Failure.self) {
      _ = try await runner.candidate(for: row, choice: choice)
    }
    #expect(log.events == ["release"])
  }

  @Test("a non-Ollama run reports nothing")
  func nonOllamaReportsNothing() async throws {
    let rig = ImportedTranscriberRig()
    let log = Log()
    let egOne = HistoryPolishChoice(provider: .egOne, model: "eg-1")
    let runner = makeRunner(rig: rig, choice: egOne, log: log) { text, _ in text }
    _ = try await runner.candidate(for: row, choice: egOne)
    #expect(log.events == ["polish", "release"])
  }
}

extension RecordingSettingsSnapshot {
  @MainActor
  fileprivate func asFrozenRun(_ rig: ImportedTranscriberRig) -> ImportedFileTranscriber.FrozenRun {
    .init(
      settings: self,
      configuration: .init(
        polishIsCloud: false, localPolishModel: nil, polishProvider: rig.polishProvider,
        ollamaModel: nil, polishModel: rig.polishModelName, backendType: backendType))
  }
}
