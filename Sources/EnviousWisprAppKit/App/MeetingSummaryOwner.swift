import CryptoKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprStorage
import Foundation
import Observation

/// Writes each meeting's summary after its transcript is ready (#3972 R39, R44, R46, R50, R54),
/// with the user's own AI Polish provider and key, held by `MeetingCoordinator`.
///
/// - **When.** `plan(for:)` decides in the same main-actor turn the meeting becomes ready, so
///   `meeting.ended` carries the decision, and starts the attempt in the background. The
///   meeting's `documents.json` marks the summary as owed until the attempt ends, so a relaunch
///   finishes one a quit interrupted (`resumeOwed`).
/// - **Dictation and meeting work first.** A local model (Ollama on this Mac, Apple
///   Intelligence) is called one call at a time, each admitted only when dictation is idle, no
///   meeting engine unit runs and no final pass is due (`MeetingLocalModelLane`); local
///   summaries run one after another. A hosted model is called at once.
/// - **Never stale, never over the user.** The inputs are read from what History shows (echo
///   hidden), the saved notes and the speaker names. An answer is saved only if they still
///   match when it arrives, and the store refuses to replace the user's own summary unless
///   "Write again" was confirmed (`replacingUserEdit`).
/// - **One telemetry row per attempt** (`meeting.summary_finished`), except an attempt a quit
///   interrupted: it stays owed and its row is sent when the relaunch finishes it.
@MainActor
@Observable
final class MeetingSummaryOwner {
  struct Dependencies {
    /// "Write a summary when a meeting ends".
    var isEnabled: @MainActor () -> Bool
    /// The AI Polish provider and the model it uses now.
    var selection: @MainActor () -> (provider: LLMProvider, model: String)
    /// The call for a provider and model, or why there is none (`MeetingSummaryProviders`).
    var prepare:
      @MainActor (LLMProvider, String) async -> Result<
        MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable
      >
    /// What History shows for a ready meeting, echo hidden, and its speaker names. Nil when
    /// the meeting is not ready, gone, or has nothing visible.
    var visibleTranscript: @MainActor (UUID) -> VisibleTranscript?
    /// True when a local model call may start: dictation idle, no meeting engine unit running,
    /// no final pass due.
    var isLocalTurn: @MainActor () -> Bool
    /// Pokes for inputs of `isLocalTurn` that Observation cannot see.
    var wakes: MeetingWakeSignal?
    var emitFinished: @MainActor (MeetingSummaryFinishedTelemetry) -> Void
    var log: @MainActor (String) -> Void
    /// The summary writer; the real one in the app, a fake in tests.
    var write:
      @MainActor (
        _ transcript: String, _ notes: String, _ window: MeetingSummary.Window,
        _ timeoutSeconds: Double, _ admit: @escaping MeetingSummary.Admit,
        _ complete: @escaping MeetingSummary.Complete
      ) async throws -> String = { transcript, notes, window, timeout, admit, complete in
        try await MeetingSummary.write(
          transcript: transcript, notes: notes, window: window, callTimeoutSeconds: timeout,
          admit: admit, complete: complete)
      }
    /// Time limits for one model call. Policies until R51's measurements: a local model writes
    /// 1,500 tokens in about a minute on an M-series Mac, a hosted reasoning model in under two.
    var localCallTimeoutSeconds: Double = 300
    var hostedCallTimeoutSeconds: Double = 180
  }

  struct VisibleTranscript: Equatable {
    let text: String
    let speakerNames: [String: String]
  }

  /// What the Summary tab shows about a summary being written or that could not be.
  enum Activity: Equatable {
    /// A local model waits for dictation or for meeting work to finish.
    case waiting
    case writing
    case failed(Problem)
  }

  enum Problem: Equatable {
    case noProvider
    /// EG-1 or S1-mini, or a model whose window is too small.
    case notForSummaries
    /// Ollama is not running or lacks the model, or Apple Intelligence is not available.
    case notReady
    case ollamaTooOld
    /// The meeting is too long for this model.
    case tooLong
    /// The provider failed, timed out, cut its answer or answered with nothing.
    case providerFailed
    /// The notes could not be read, so the summary would leave them out.
    case notesUnreadable
  }

  private(set) var activity: [UUID: Activity] = [:]

  private let deps: Dependencies
  private let documents: MeetingDocumentsOwner
  private let lane: MeetingLocalModelLane
  /// The attempt running for each meeting.
  private struct Running {
    let attempt: UUID
    let task: Task<Void, Never>
  }
  private var tasks: [UUID: Running] = [:]
  /// Local attempts run one after another: each waits for the one before it.
  private var localChain: Task<Void, Never>?
  private var terminating = false

  init(dependencies: Dependencies, documents: MeetingDocumentsOwner, lane: MeetingLocalModelLane) {
    self.deps = dependencies
    self.documents = documents
    self.lane = lane
  }

  /// A summary is being written for the meeting (waiting or calling).
  func isWriting(_ meetingID: UUID) -> Bool { tasks[meetingID] != nil }

  // MARK: - Starting attempts

  /// The decision when a meeting becomes ready, taken now from the setting and the selected
  /// provider and model; a scheduled attempt starts in the background.
  func plan(for meetingID: UUID) -> MeetingEndedTelemetry.SummaryPlan {
    guard deps.isEnabled() else { return .off }
    let selection = deps.selection()
    switch MeetingSummary.capability(
      selection.provider, model: selection.model, ollamaModelIsRemote: nil)
    {
    case .noProvider: return .noProvider
    case .notForSummaries: return .unsupported
    case .supported:
      start(meetingID, replacingUserEdit: false, owedAlready: false)
      return .scheduled
    }
  }

  /// "Write again": a new attempt, replacing the user's own summary only when confirmed.
  func writeAgain(_ meetingID: UUID, replacingUserEdit: Bool) {
    start(meetingID, replacingUserEdit: replacingUserEdit, owedAlready: false)
  }

  /// At launch: finishes the summaries a quit interrupted, for these ready meetings.
  func resumeOwed(readyMeetingIDs: [UUID]) async {
    for meetingID in readyMeetingIDs {
      guard await documents.load(meetingID),
        documents.manifest(meetingID)?.summaryPending == true, tasks[meetingID] == nil
      else { continue }
      start(meetingID, replacingUserEdit: false, owedAlready: true)
    }
  }

  /// The meeting was deleted: its attempt ends, and nothing it does later writes.
  func cancel(_ meetingID: UUID) {
    tasks.removeValue(forKey: meetingID)?.task.cancel()
    activity[meetingID] = nil
  }

  /// The app quits: every attempt stops and stays owed, so the relaunch finishes it and sends
  /// its one row.
  func prepareForTermination() {
    terminating = true
    for entry in tasks.values { entry.task.cancel() }
  }

  private func start(_ meetingID: UUID, replacingUserEdit: Bool, owedAlready: Bool) {
    guard !terminating else { return }
    // A newer attempt replaces one still running (a Retry made a new transcript, or Write
    // again); the old one ends as cancelled.
    tasks.removeValue(forKey: meetingID)?.task.cancel()
    let attempt = UUID()
    activity[meetingID] = .waiting
    let task = Task { [weak self] () -> Void in
      guard let self else { return }
      await self.run(
        meetingID, attempt: attempt, replacingUserEdit: replacingUserEdit,
        owedAlready: owedAlready)
    }
    tasks[meetingID] = Running(attempt: attempt, task: task)
  }

  // MARK: - One attempt

  private struct Inputs: Equatable {
    let transcript: VisibleTranscript
    let notes: String
    let summaryInputs: SummaryInputs
  }

  private enum End: Equatable {
    case written
    case stale
    case cancelled
    case problem(Problem)
  }

  /// How an attempt ended, and whether its save already cleared the owed mark.
  private struct Ending {
    let end: End
    var savedMark = false
  }

  private func run(
    _ meetingID: UUID, attempt: UUID, replacingUserEdit: Bool, owedAlready: Bool
  ) async {
    var kind: MeetingSummaryFinishedTelemetry.ProviderKind = .none
    let ending = await attemptOnce(
      meetingID, replacingUserEdit: replacingUserEdit, owedAlready: owedAlready, kind: &kind)
    // The attempt is over: the mark goes, unless a quit stopped it (the relaunch finishes it),
    // the save already cleared it, or a newer attempt owns it now.
    let quit = terminating && ending.end == .cancelled
    if !quit, !ending.savedMark, tasks[meetingID]?.attempt == attempt {
      await documents.setSummaryPending(meetingID, false)
    }
    finish(meetingID, attempt: attempt, end: ending.end, kind: kind, quit: quit)
  }

  private func attemptOnce(
    _ meetingID: UUID, replacingUserEdit: Bool, owedAlready: Bool,
    kind: inout MeetingSummaryFinishedTelemetry.ProviderKind
  ) async -> Ending {
    if !owedAlready {
      guard await documents.setSummaryPending(meetingID, true) else {
        return Ending(end: .cancelled)
      }
    }
    let selection = deps.selection()
    // Known before the provider answers, so every row says where the model runs (R57: `none`
    // only with `noProvider`); Ollama counts as local until the daemon says otherwise.
    kind = Self.providerKind(selection.provider)
    let prepared: MeetingSummaryProviders.Prepared
    switch await deps.prepare(selection.provider, selection.model) {
    case .failure(.noProvider): return Ending(end: .problem(.noProvider))
    case .failure(.notForSummaries): return Ending(end: .problem(.notForSummaries))
    case .failure(.notReady): return Ending(end: .problem(.notReady))
    case .failure(.ollamaTooOld): return Ending(end: .problem(.ollamaTooOld))
    case .success(let ready): prepared = ready
    }
    kind = prepared.execution == .local ? .local : .hosted
    if Task.isCancelled { return Ending(end: .cancelled) }

    if prepared.execution == .local {
      lane.summaryQueued()
      defer { lane.summaryFinished() }
      // This attempt's whole write runs after the previous local attempt's whole write.
      let previous = localChain
      let body = Task { @MainActor [weak self] () -> Ending in
        await previous?.value
        guard let self else { return Ending(end: .cancelled) }
        return await self.write(
          meetingID, selection: selection, prepared: prepared,
          replacingUserEdit: replacingUserEdit)
      }
      localChain = Task { _ = await body.value }
      return await withTaskCancellationHandler {
        await body.value
      } onCancel: {
        body.cancel()
      }
    }
    return await write(
      meetingID, selection: selection, prepared: prepared, replacingUserEdit: replacingUserEdit)
  }

  private func write(
    _ meetingID: UUID, selection: (provider: LLMProvider, model: String),
    prepared: MeetingSummaryProviders.Prepared, replacingUserEdit: Bool
  ) async -> Ending {
    if Task.isCancelled { return Ending(end: .cancelled) }
    // Notes are saved first, so the summary names the revision it read.
    let notes = await documents.ensureNotesDurable(meetingID)
    // A deletion meanwhile makes the notes unknown; that is a cancel, not a failure.
    if Task.isCancelled { return Ending(end: .cancelled) }
    switch notes {
    case .failed, .unknown: return Ending(end: .problem(.notesUnreadable))
    case .none, .saved: break
    }
    guard let inputs = currentInputs(meetingID, selection: selection) else {
      return Ending(end: .cancelled)
    }

    let local = prepared.execution == .local
    let admit: MeetingSummary.Admit
    let complete: MeetingSummary.Complete
    if local {
      admit = { @MainActor [weak self] in try await self?.admitLocalCall(meetingID) }
      let lane = self.lane
      let call = prepared.complete
      complete = { instructions, prompt in
        // The call holds the lane until it has physically ended, however it ends.
        do {
          let answer = try await call(instructions, prompt)
          await lane.endSummaryCall()
          return answer
        } catch {
          await lane.endSummaryCall()
          throw error
        }
      }
    } else {
      admit = { @MainActor [weak self] in
        try Task.checkCancellation()
        self?.activity[meetingID] = .writing
      }
      complete = prepared.complete
    }

    let text: String
    do {
      text = try await deps.write(
        inputs.transcript.text, inputs.notes, prepared.window,
        local ? deps.localCallTimeoutSeconds : deps.hostedCallTimeoutSeconds, admit, complete)
    } catch let failure as MeetingSummary.Failure {
      if local { lane.endSummaryCall() }
      switch failure {
      case .cancelled: return Ending(end: .cancelled)
      case .tooLong: return Ending(end: .problem(.tooLong))
      case .windowTooSmall: return Ending(end: .problem(.notForSummaries))
      case .providerFailed, .empty, .truncated, .timedOut:
        return Ending(end: .problem(.providerFailed))
      }
    } catch {
      if local { lane.endSummaryCall() }
      return Ending(end: Task.isCancelled ? .cancelled : .problem(.providerFailed))
    }
    if local { lane.endSummaryCall() }
    if Task.isCancelled { return Ending(end: .cancelled) }

    // The meeting changed while the summary was written (a rename, new notes, a Retry, a model
    // change): the answer describes something else and is not saved.
    guard currentInputs(meetingID, selection: deps.selection()) == inputs else {
      return Ending(end: .stale)
    }
    // Every answer of the checked save also ends the owed mark.
    switch await documents.publishGeneratedSummary(
      meetingID, text: text, inputs: inputs.summaryInputs, replacingUserEdit: replacingUserEdit)
    {
    case .saved: return Ending(end: .written, savedMark: true)
    case .userEditKept, .notesChanged: return Ending(end: .stale, savedMark: true)
    case nil: return Ending(end: .cancelled)
    }
  }

  /// Waits until a local call may start, then takes the lane in the same main-actor step.
  private func admitLocalCall(_ meetingID: UUID) async throws {
    activity[meetingID] = .waiting
    while true {
      await MeetingWorkAdmission.waitUntil(deps.isLocalTurn, wakes: deps.wakes)
      try Task.checkCancellation()
      if deps.isLocalTurn(), !lane.summaryCallRunning {
        lane.beginSummaryCall()
        activity[meetingID] = .writing
        return
      }
    }
  }

  private func currentInputs(
    _ meetingID: UUID, selection: (provider: LLMProvider, model: String)
  ) -> Inputs? {
    guard let transcript = deps.visibleTranscript(meetingID) else { return nil }
    let notes = documents.notes(meetingID)
    return Inputs(
      transcript: transcript, notes: notes,
      summaryInputs: SummaryInputs(
        transcriptSHA256: MeetingDocumentHash.sha256(transcript.text),
        notesRevision: documents.manifest(meetingID)?.notes?.revision ?? 0,
        speakerNamesSHA256: Self.speakerNamesSHA256(transcript.speakerNames),
        promptVersion: MeetingSummary.promptVersion,
        providerID: selection.provider.rawValue,
        configurationSHA256: MeetingSummary.configurationFingerprint(
          provider: selection.provider, model: selection.model)))
  }

  static func providerKind(_ provider: LLMProvider) -> MeetingSummaryFinishedTelemetry.ProviderKind {
    switch provider {
    case .openAI, .gemini, .claude: return .hosted
    case .ollama, .appleIntelligence, .egOne, .s1Mini: return .local
    case .none: return .none
    }
  }

  /// SHA-256 of the speaker names in a fixed order, so a rename makes a summary out of date.
  static func speakerNamesSHA256(_ names: [String: String]) -> String {
    let canonical = names.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: "\n")
    return MeetingDocumentHash.sha256(canonical)
  }

  // MARK: - Ending

  private func finish(
    _ meetingID: UUID, attempt: UUID, end: End,
    kind: MeetingSummaryFinishedTelemetry.ProviderKind, quit: Bool
  ) {
    let current = tasks[meetingID]?.attempt == attempt
    if current { tasks[meetingID] = nil }
    // A quit leaves the summary owed and sends nothing: the relaunch finishes this attempt.
    if quit { return }
    let outcome: MeetingSummaryFinishedTelemetry.Outcome
    switch end {
    case .written: outcome = .written
    case .stale: outcome = .stale
    case .cancelled: outcome = .cancelled
    case .problem(.noProvider): outcome = .noProvider
    case .problem(.notForSummaries), .problem(.notReady), .problem(.ollamaTooOld),
      .problem(.tooLong):
      outcome = .unsupported
    case .problem(.providerFailed), .problem(.notesUnreadable): outcome = .failed
    }
    deps.emitFinished(
      MeetingSummaryFinishedTelemetry(
        outcome: outcome, providerKind: outcome == .noProvider ? .none : kind))
    deps.log("meeting summary finished outcome=\(outcome.rawValue) provider=\(kind.rawValue)")
    guard current else { return }
    switch end {
    case .problem(let problem): activity[meetingID] = .failed(problem)
    case .written, .stale, .cancelled: activity[meetingID] = nil
    }
  }
}
