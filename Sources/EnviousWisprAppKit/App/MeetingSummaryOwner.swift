import CryptoKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprStorage
import Foundation
import os
import Observation

/// Writes each meeting's summary after its transcript is ready (#3972 R39, R44, R46, R50, R54),
/// with the user's own AI Polish provider and key, held by `MeetingCoordinator`.
///
/// - **When.** The coordinator asks `decide()` before the ready barrier, writes the owed mark
///   (`documents.json` `summaryPending`) before the meeting is ready, sends `meeting.ended` with
///   the decision, then calls `startOwed`. The mark stays until the attempt is settled, so a quit
///   at any point leaves the summary owed and a relaunch finishes it (`resumeOwed`).
/// - **Dictation and meeting work first.** A local model (Ollama on this Mac, Apple
///   Intelligence) is called one call at a time, each admitted only when dictation is idle, no
///   meeting engine unit runs and no final pass is due (`MeetingLocalModelLane`); local attempts
///   run one after another. A hosted model is called at once.
/// - **Never stale, never over the user.** The inputs are read from what History shows (echo
///   hidden), the saved notes and the speaker names, and checked again before and after the
///   save; the store refuses to replace the user's own summary unless the user confirmed
///   replacing exactly that text ("Write again").
/// - **One telemetry row per settled attempt** (`meeting.summary_finished`). An attempt a quit
///   stopped, or whose owed mark could not be cleared, is not settled: it stays owed and its one
///   row is sent when a later run settles it.
/// - **Drains.** A deletion waits until its attempt has physically ended; an attempt calling a
///   model or saving holds a relaunch (`hasWorkInFlight`); one only waiting for its turn does not.
@MainActor
@Observable
final class MeetingSummaryOwner {
  struct Dependencies {
    /// "Write a summary when a meeting ends".
    var isEnabled: @MainActor () -> Bool
    /// The AI Polish provider and the model it uses now.
    var selection: @MainActor () -> (provider: LLMProvider, model: String)
    /// #4353 D6: the cloud model list in use now. Read once per attempt, beside `selection`,
    /// and never part of the selection-change checks: a background refresh does not cancel
    /// an attempt already underway.
    var cloudModelList: @MainActor () -> CloudModelList?
    /// The call for a provider and model under the attempt's captured cloud model list, or why
    /// there is none (`MeetingSummaryProviders`).
    var prepare:
      @MainActor (LLMProvider, String, CloudModelList?) async -> Result<
        MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable
      >
    /// What History shows for a ready meeting, echo hidden, and its speaker names. Nil when
    /// the meeting is not ready, gone, or has nothing visible.
    var visibleTranscript: @MainActor (UUID) -> VisibleTranscript?
    /// #4148: true only for known, ready inputs with no visible transcript text. False when
    /// the meeting is not ready, gone, or its facts cannot be read.
    var hasNoWords: @MainActor (UUID) -> Bool
    /// #4286: what the summary is told about the meeting (its record's start, recorded length
    /// and call app, and its saved calendar facts). Nil when the meeting is not known.
    var promptFacts: @MainActor (UUID) -> MeetingPromptFacts? = { _ in nil }
    /// True when a local model call may start: dictation idle, no meeting engine unit running,
    /// no final pass due.
    /// #4319: per provider, because an EG-1 summary also waits while a file import holds a
    /// bundled server (it would otherwise borrow the server the import is using).
    var isLocalTurn: @MainActor (LLMProvider) -> Bool
    /// Pokes for inputs of `isLocalTurn` that Observation cannot see.
    var wakes: MeetingWakeSignal?
    var emitFinished: @MainActor (MeetingSummaryFinishedTelemetry) -> Void
    var log: @MainActor (String) -> Void
    /// #4012 D8, R6: names a meeting that has no name yet with the summary's AI title
    /// (`MeetingCoordinator.assignAITitle`).
    var assignTitle: @MainActor (UUID, String) async -> Void = { _, _ in }
    /// #3147 PR4A (D5): the meeting's visible turns (the same projection `visibleTranscript`
    /// reads, echo hidden) and its note blocks, for a summary with references. Nil when they
    /// are not known; read only on a qualified route.
    var referenceSources: @MainActor (UUID) -> MeetingSummaryReferenceSources? = { _ in nil }
    /// #3147 PR4A (D5): whether a provider and model write summaries with references. The app
    /// keeps the qualification table's answer; tests name a route.
    var writesReferences: @MainActor (LLMProvider, String) -> Bool = {
      MeetingSummaryReferences.isQualified(provider: $0, model: $1)
    }
    /// #3147 PR4A (D5): saves the reference document beside the summary just saved (nil
    /// removes an older one), through the meeting's writer. False when it could not be saved:
    /// the summary stays readable and simply has no links.
    var saveReferences: @MainActor (UUID, MeetingSummaryDocument?) async -> Bool = { _, _ in
      true
    }
    /// The summary writer; the real one in the app, a fake in tests.
    var write:
      @MainActor (
        _ transcript: String, _ notes: String, _ facts: String,
        _ window: MeetingSummary.Window, _ timeoutSeconds: Double,
        _ references: MeetingSummary.ReferenceRequest?,
        _ admit: @escaping MeetingSummary.Admit, _ complete: @escaping MeetingSummary.Complete
      ) async throws -> MeetingSummary.Written = {
        transcript, notes, facts, window, timeout, references, admit, complete in
        try await MeetingSummary.write(
          transcript: transcript, notes: notes, facts: facts, window: window,
          callTimeoutSeconds: timeout, references: references, admit: admit, complete: complete)
      }
    /// Time limits for one model call. Policies until R51's measurements: a local model writes
    /// 1,500 tokens in about a minute on an M-series Mac, a hosted reasoning model in under two.
    var localCallTimeoutSeconds: Double = Self.defaultLocalCallTimeoutSeconds
    var hostedCallTimeoutSeconds: Double = 180
    /// #4319: the one local call limit, read by these dependencies and by EG-1's preparation
    /// (its request waits this plus ten seconds, so this limit fires first).
    static let defaultLocalCallTimeoutSeconds: Double = 300
    /// #4319: the weights' revision for a provider whose model name is fixed while its weights
    /// change (EG-1), so a new release makes an older summary out of date; nil for the rest.
    var artifactRevision: @MainActor (LLMProvider) -> String? = { _ in nil }
    var prepareEGOneOverride:
      (@MainActor (EGOneSize) -> Result<MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable>)? = nil
    var overrideArtifactRevision: @MainActor (EGOneSize) -> String? = { _ in nil }
    /// #4319: the app is quitting; an engine lent to a summary must not be loaded or restored.
    var beginTermination: @MainActor () -> Void = {}
  }

  struct VisibleTranscript: Equatable {
    let text: String
    let speakerNames: [String: String]
    /// #3973 C2: the History row's transcript attempt; nil for a row written before attempts.
    var transcriptAttemptID: UUID? = nil
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
    /// S1-mini, EG-1 through Ollama, or a model whose window is too small.
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
    /// The meeting's files could not be written; the summary stays owed.
    case storageFailed
    /// #4353 D9: OpenAI, Gemini or Claude with no model chosen. Nothing was sent.
    case cloudNoModel(LLMProvider)
    /// #4353 D9: the provider answered that this model does not exist. The provider and model
    /// are the attempt's own frozen selection, never the setting read afterwards.
    case cloudModelUnavailable(LLMProvider, String)
  }

  private(set) var activity: [UUID: Activity] = [:]
  private(set) var previews: [UUID: Preview] = [:]

  private let deps: Dependencies
  private let documents: MeetingDocumentsOwner
  private let lane: MeetingLocalModelLane
  /// Every attempt still physically running, by attempt id, until it has ended: a replaced
  /// attempt still draining stays here, so a deletion waits for it too.
  private struct Running {
    let meetingID: UUID
    let task: Task<Void, Never>
    var provider: LLMProvider?
  }
  private var attempts: [UUID: Running] = [:]
  /// The meeting's current attempt; a replaced one is no longer current.
  private var currentAttempt: [UUID: UUID] = [:]
  /// Attempts (by attempt id) calling a model or saving right now: a relaunch waits for them.
  /// Not set while an attempt waits for its turn between calls (it is owed on disk).
  private var busy: Set<UUID> = []
  /// Local attempts run one after another: each waits for the one before it.
  private var localChain: Task<Void, Never>?
  /// #4287: the local call the lane admitted, with the provider and model its attempt
  /// captured. The lane admits one local call at a time, so one value suffices. `started`
  /// marks that the physical call began: from then only `callEnded` (the call's own end)
  /// clears it, so a write that gave up early cannot release protection while the call
  /// still runs; before then the write's own exit clears it.
  private struct RunningLocalCall {
    let attempt: UUID
    let provider: LLMProvider
    let model: String
    var started = false
  }
  private var runningLocalCall: RunningLocalCall?
  /// #4287: told when a running local Ollama call releases its model, so an Ollama eviction
  /// deferred for that pin is retried (`PipelineSettingsSync.retryDeferredOllamaEviction`).
  /// Set by the composition root; nil in tests that do not care.
  var onOllamaModelReleased: (@MainActor () -> Void)?
  private var terminating = false

  init(dependencies: Dependencies, documents: MeetingDocumentsOwner, lane: MeetingLocalModelLane) {
    self.deps = dependencies
    self.documents = documents
    self.lane = lane
  }

  /// A summary is being written for the meeting (waiting, calling or saving).
  func isWriting(_ meetingID: UUID) -> Bool { currentAttempt[meetingID] != nil }

  func writingProvider(for meetingID: UUID) -> LLMProvider? {
    guard activity[meetingID] == .writing, let attempt = currentAttempt[meetingID] else {
      return nil
    }
    return attempts[attempt]?.provider
  }

  /// A local summary waits for its turn or calls (previews give way to it).
  var localSummaryActive: Bool { lane.summaryActive }
  /// A local summary call runs (a final pass unit waits for it).
  var localSummaryCallRunning: Bool { lane.summaryCallRunning }
  /// #4287: the Ollama model a running local summary call is using, from the attempt's own
  /// captured selection (never the live setting), for `PipelineSettingsSync`'s eviction check.
  var summaryPinnedOllamaModel: String? {
    guard let call = runningLocalCall, call.provider == .ollama else { return nil }
    return call.model
  }
  /// #4287 PR 3: the provider of the summary call the lane admitted on a local engine, from the
  /// attempt's own captured selection (never the live setting), from admission until the call
  /// physically ends. A dictation polishing with the same local engine skips polish meanwhile
  /// (`SummaryEngineClash`). Hosted calls are never recorded here.
  var runningLocalSummaryProvider: LLMProvider? { runningLocalCall?.provider }

  /// Test seam (#4319): the wired local-turn predicate for `provider`.
  func isLocalTurnForTesting(_ provider: LLMProvider) -> Bool { deps.isLocalTurn(provider) }

  /// An attempt is calling a model or saving: a relaunch must wait. One waiting for its turn
  /// does not hold it (it is owed on disk and resumes).
  var hasWorkInFlight: Bool { !busy.isEmpty }

  // MARK: - Starting attempts

  /// The decision when a meeting becomes ready, from the setting and the selected provider and
  /// model. No side effects: the coordinator makes it durable, then calls `startOwed`.
  func decide() -> MeetingEndedTelemetry.SummaryPlan {
    guard deps.isEnabled() else { return .off }
    let selection = deps.selection()
    // #4353 D9: no cloud model chosen schedules nothing; the Summary tab explains it from the
    // setting (`configurationProblem`), and Write summary works once a model is chosen.
    if MeetingSummaryProviders.isCloudWithNoModel(selection.provider, model: selection.model) {
      return .unsupported
    }
    switch MeetingSummary.capability(
      selection.provider, model: selection.model, ollamaModelIsRemote: nil)
    {
    case .noProvider: return .noProvider
    case .notForSummaries: return .unsupported
    case .supported: return .scheduled
    }
  }

  /// Starts the attempt for a meeting whose owed mark is written.
  func startOwed(_ meetingID: UUID) {
    previews[meetingID] = nil
    start(meetingID, approvedUserEdit: nil, owedAlready: true)
  }

  /// The owed mark of a scheduled summary could not be written at ready: no attempt starts
  /// (a quit could lose it), and the failure is settled now with its one row; the Summary tab
  /// offers Write again.
  func settleUnwritableMark(_ meetingID: UUID) {
    let kind = Self.providerKind(deps.selection().provider)
    deps.emitFinished(
      MeetingSummaryFinishedTelemetry(
        outcome: kind == .none ? .noProvider : .failed, providerKind: kind))
    deps.log("meeting summary not started; owed mark unwritable")
    activity[meetingID] = .failed(.storageFailed)
  }

  /// "Write again": a new attempt. `replacing` is the SHA-256 of the user's own summary the
  /// user confirmed replacing; nil keeps any user-edited summary.
  func writeAgain(_ meetingID: UUID, replacing approvedUserEdit: String?) {
    start(meetingID, approvedUserEdit: approvedUserEdit, owedAlready: false)
  }

  /// At launch: finishes the summaries still owed, for these ready meetings.
  func resumeOwed(readyMeetingIDs: [UUID]) async {
    for meetingID in readyMeetingIDs {
      guard await documents.load(meetingID),
        documents.manifest(meetingID)?.summaryPending == true, currentAttempt[meetingID] == nil
      else { continue }
      startOwed(meetingID)
    }
  }

  /// The meeting is being deleted: its attempt ends, and this returns once it has physically
  /// ended, so nothing it does later touches the meeting's files.
  func cancelAndWait(_ meetingID: UUID) async {
    previews[meetingID] = nil
    activity[meetingID] = nil
    let mine = attempts.values.filter { $0.meetingID == meetingID }
    for running in mine { running.task.cancel() }
    for running in mine { await running.task.value }
    // After the drain, so a finishing attempt cannot keep this meeting's hashes (#4001).
    fingerprints[meetingID] = nil
  }

  /// A newer transcript of the meeting is ready: every attempt over the old one is cancelled
  /// and this returns once each has physically ended and settled (mark cleared, one row sent),
  /// so the new transcript's owed mark is written after them and none of them can clear it.
  func settleBeforeNewTranscript(_ meetingID: UUID) async {
    previews[meetingID] = nil
    let mine = attempts.values.filter { $0.meetingID == meetingID }
    for running in mine { running.task.cancel() }
    for running in mine { await running.task.value }
  }

  /// The app quits: every attempt stops and stays owed, so a relaunch finishes it and sends
  /// its one row.
  func prepareForTermination() {
    terminating = true
    previews.removeAll()
    deps.beginTermination()
    for running in attempts.values { running.task.cancel() }
  }

  enum Preview {
    case generating(UUID)
    case comparing(Candidate)
    case failed
  }

  struct Candidate {
    let id: UUID
    let current: String?
    let text: String
    let choice: HistoryPolishChoice
    fileprivate let base: MeetingDocumentsManifest.Summary?
    fileprivate let inputs: Inputs
    fileprivate let answer: MeetingSummary.Written
  }

  func startPreview(_ meetingID: UUID, with choice: HistoryPolishChoice) {
    guard currentAttempt[meetingID] == nil, !requesting.contains(meetingID), !terminating,
      choice.provider != .none, choice.provider != .s1Mini
    else { return }
    start(meetingID, approvedUserEdit: nil, owedAlready: false, preview: choice)
  }

  func defaultPreviewChoice(in choices: [HistoryPolishChoice]) -> HistoryPolishChoice? {
    let current = deps.selection()
    return choices.first { $0.provider == current.provider && $0.model == current.model }
  }

  func discardPreview(_ meetingID: UUID) {
    if case .generating(let id) = previews[meetingID] { attempts[id]?.task.cancel() }
    previews[meetingID] = nil
  }

  func keepPreview(_ meetingID: UUID, candidateID: UUID) async -> Bool {
    guard !terminating, currentAttempt[meetingID] == nil, !requesting.contains(meetingID),
      case .comparing(let candidate) = previews[meetingID], candidate.id == candidateID
    else { return false }
    requesting.insert(meetingID)
    defer { requesting.remove(meetingID) }
    let selection = (provider: candidate.choice.provider, model: candidate.choice.model)
    guard !documents.hasUnsavedNotes(meetingID), !documents.hasUnsavedSummary(meetingID),
      currentInputs(meetingID, selection: selection, override: candidate.choice, withSources: true)
        == candidate.inputs
    else {
      previews[meetingID] = nil
      return false
    }
    let saved = await documents.publishGeneratedSummary(
      meetingID, text: candidate.text, inputs: candidate.inputs.summaryInputs,
      writtenInParts: candidate.answer.inParts, approvedUserEdit: candidate.base?.sha256,
      publication: .replacing(candidate.base))
    if case .comparing(let current) = previews[meetingID], current.id == candidateID {
      previews[meetingID] = nil
    }
    guard case .saved = saved else { return false }
    await publishReferences(meetingID, answer: candidate.answer, text: candidate.text)
    return true
  }

  private func start(
    _ meetingID: UUID, approvedUserEdit: String?, owedAlready: Bool,
    preview: HistoryPolishChoice? = nil
  ) {
    guard !terminating else { return }
    // A newer attempt replaces one still running (a Retry made a new transcript, or Write
    // again); the old one ends as cancelled and stays tracked until it has ended.
    if let previous = currentAttempt[meetingID] { attempts[previous]?.task.cancel() }
    let attempt = UUID()
    activity[meetingID] = .waiting
    if preview != nil { previews[meetingID] = .generating(attempt) }
    let task = Task { [weak self] () -> Void in
      guard let self else { return }
      await self.run(
        meetingID, attempt: attempt, approvedUserEdit: approvedUserEdit,
        owedAlready: owedAlready, preview: preview)
    }
    attempts[attempt] = Running(meetingID: meetingID, task: task)
    currentAttempt[meetingID] = attempt
  }

  // MARK: - One attempt

  fileprivate struct Inputs: Equatable {
    let transcript: VisibleTranscript
    let notes: String
    /// #4286: the rendered facts block ("" when none), frozen for the attempt: the exact text
    /// the summary is told and `summaryInputs.contextSHA256` records.
    let factsBlock: String
    let summaryInputs: SummaryInputs
    /// #3147 PR4A (D5): the tagged sources on a qualified route whose sources match the
    /// transcript; nil writes the plain summary exactly as before.
    let sources: MeetingSummaryReferenceSources?
  }

  private enum End: Equatable {
    case written
    case preview
    case stale
    case cancelled
    /// #4148: known inputs had no visible transcript text; no model call was made.
    case nothingToSummarize
    case problem(Problem)
  }

  /// How an attempt ended, and whether no owed mark is left to clear (the save cleared it, or
  /// none was written).
  private struct Ending {
    let end: End
    var savedMark = false
  }

  private func run(
    _ meetingID: UUID, attempt: UUID, approvedUserEdit: String?, owedAlready: Bool,
    preview: HistoryPolishChoice?
  ) async {
    // Where the model runs is known from the selection before anything can fail, so every row
    // pairs `none` with `noProvider` only (R57). No provider ends the attempt at once.
    let selection = preview.map { (provider: $0.provider, model: $0.model) } ?? deps.selection()
    attempts[attempt]?.provider = selection.provider
    // #4353 D6: captured with the selection, before the first suspension, and carried to
    // `prepare`; planning and every request of this attempt use it.
    let cloudModelList = deps.cloudModelList()
    var kind = Self.providerKind(selection.provider)
    let ending: Ending
    if selection.provider == .none {
      ending = Ending(end: .problem(.noProvider))
    } else {
      ending = await attemptOnce(
        meetingID, attempt: attempt, selection: selection, cloudModelList: cloudModelList,
        approvedUserEdit: approvedUserEdit, owedAlready: owedAlready, preview: preview, kind: &kind)
    }
    defer {
      busy.remove(attempt)
      attempts[attempt] = nil
    }
    if preview != nil {
      guard currentAttempt[meetingID] == attempt else { return }
      currentAttempt[meetingID] = nil
      activity[meetingID] = nil
      if case .generating(let id) = previews[meetingID], id == attempt {
        previews[meetingID] = Task.isCancelled || terminating ? nil : .failed
      }
      return
    }
    // A quit leaves the attempt owed and unsettled: the relaunch finishes it.
    let quit = terminating && ending.end == .cancelled
    var settled = !quit
    // A replaced attempt leaves the mark to the attempt that replaced it.
    if settled, !ending.savedMark, currentAttempt[meetingID] == attempt,
      !documents.isForgotten(meetingID)
    {
      // The mark goes with the attempt; if it cannot, the attempt stays owed and unsettled, so
      // a later run settles it and sends its one row (never two).
      settled = await documents.setSummaryPending(meetingID, false)
      // Replaced during that wait: the newer attempt owns the mark now and settles it, so this
      // attempt is settled whatever its own clear did.
      if !settled, currentAttempt[meetingID] != attempt { settled = true }
    }
    // Read after that wait: a newer attempt may have replaced this one meanwhile.
    finish(
      meetingID, attempt: attempt, end: settled ? ending.end : .problem(.storageFailed),
      kind: kind, settled: settled, current: currentAttempt[meetingID] == attempt)
  }

  private func attemptOnce(
    _ meetingID: UUID, attempt: UUID, selection: (provider: LLMProvider, model: String),
    cloudModelList: CloudModelList?, approvedUserEdit: String?, owedAlready: Bool,
    preview: HistoryPolishChoice?,
    kind: inout MeetingSummaryFinishedTelemetry.ProviderKind
  ) async -> Ending {
    if !owedAlready, preview == nil {
      // No mark was written, so there is none to clear: the attempt settles at once.
      guard await documents.setSummaryPending(meetingID, true) else {
        return Ending(
          end: documents.isForgotten(meetingID) || Task.isCancelled
            ? .cancelled : .problem(.storageFailed),
          savedMark: true)
      }
    }
    let prepared: MeetingSummaryProviders.Prepared
    let preparation: Result<MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable>
    if let preview, preview.provider == .egOne {
      guard let size = preview.egOneSize, let prepare = deps.prepareEGOneOverride else {
        return Ending(end: .problem(.notReady))
      }
      preparation = prepare(size)
    } else {
      preparation = await deps.prepare(selection.provider, selection.model, cloudModelList)
    }
    // #4319: a successful preparation is unpacked before anything else, so its `finish` runs
    // exactly once on every path from here, a cancel included.
    switch preparation {
    case .success(let ready): prepared = ready
    case .failure(let unavailable):
      // A quit or deletion during preparation is a cancel, whatever the provider answered.
      if Task.isCancelled { return Ending(end: .cancelled) }
      switch unavailable {
      case .noProvider: return Ending(end: .problem(.noProvider))
      case .notForSummaries: return Ending(end: .problem(.notForSummaries))
      case .notReady: return Ending(end: .problem(.notReady))
      case .ollamaTooOld: return Ending(end: .problem(.ollamaTooOld))
      case .noModelChosen: return Ending(end: .problem(.cloudNoModel(selection.provider)))
      }
    }
    if Task.isCancelled {
      await prepared.finish()
      return Ending(end: .cancelled)
    }
    kind = prepared.execution == .local ? .local : .hosted

    guard prepared.execution == .local else {
      let ending = await write(
        meetingID, attempt: attempt, selection: selection, prepared: prepared,
        approvedUserEdit: approvedUserEdit, preview: preview)
      await prepared.finish()
      return ending
    }
    lane.summaryQueued()
    defer { lane.summaryFinished() }
    // This attempt's whole write runs after the previous local attempt's whole write. A
    // cancelled attempt stops waiting at once (a final pass may be waiting for it to settle,
    // whole-diff review r2 F1), but the chain link it leaves still waits for the previous
    // attempt too, so the next attempt is never ordered behind anything but the real owner.
    let previous = localChain
    // #4319: the attempt's cleanup (`prepared.finish`, which gives a borrowed engine back) runs
    // inside the body, so the chain link, and with it the next local attempt, waits for it.
    let body = Task { @MainActor [weak self] () -> Ending in
      if let previous, !(await Self.waitUnlessCancelled(previous)) {
        await prepared.finish()
        return Ending(end: .cancelled)
      }
      guard let self else {
        await prepared.finish()
        return Ending(end: .cancelled)
      }
      let ending = await self.write(
        meetingID, attempt: attempt, selection: selection, prepared: prepared,
        approvedUserEdit: approvedUserEdit, preview: preview)
      await prepared.finish()
      return ending
    }
    localChain = Task {
      await previous?.value
      _ = await body.value
    }
    return await withTaskCancellationHandler {
      await body.value
    } onCancel: {
      body.cancel()
    }
  }

  /// True once `task` has finished; false as soon as the waiting task is cancelled.
  static func waitUnlessCancelled(_ task: Task<Void, Never>) async -> Bool {
    let shot = OneShot()
    Task { await task.value; shot.resolve(true) }
    return await withTaskCancellationHandler {
      await shot.wait()
    } onCancel: {
      shot.resolve(false)
    }
  }

  /// One answer, from whichever side gives it first; safe from any thread.
  final class OneShot: Sendable {
    private let state = OSAllocatedUnfairLock<(waiter: CheckedContinuation<Bool, Never>?, value: Bool?)>(
      initialState: (nil, nil))

    func wait() async -> Bool {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { state -> Bool? in
          if let value = state.value { return value }
          state.waiter = continuation
          return nil
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }

    func resolve(_ value: Bool) {
      let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
        guard state.value == nil else { return nil }
        state.value = value
        defer { state.waiter = nil }
        return state.waiter
      }
      waiter?.resume(returning: value)
    }
  }

  private func write(
    _ meetingID: UUID, attempt: UUID, selection: (provider: LLMProvider, model: String),
    prepared: MeetingSummaryProviders.Prepared, approvedUserEdit: String?,
    preview: HistoryPolishChoice?
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
    if preview != nil {
      guard await documents.flushSummary(meetingID) else {
        return Ending(end: .problem(.storageFailed))
      }
      if Task.isCancelled { return Ending(end: .cancelled) }
    }
    let baseSummary = preview == nil ? nil : documents.manifest(meetingID)?.summary
    let currentSummary = preview == nil ? nil : documents.summary(meetingID)
    // Nil inputs are a cancel (gone, not ready) unless the meeting is known and wordless (#4148).
    guard
      let inputs = currentInputs(
        meetingID, selection: selection,
        // The attempt's own captured revision when its preparation carries one (EG-1); a
        // provider whose preparation carries none is read as before.
        attemptRevision: prepared.artifactRevision.map { Optional($0) },
        override: preview, withSources: true)
    else {
      return Ending(end: deps.hasNoWords(meetingID) ? .nothingToSummarize : .cancelled)
    }

    let local = prepared.execution == .local
    let admit: MeetingSummary.Admit
    let complete: MeetingSummary.Complete
    if local {
      admit = { @MainActor [weak self, borrow = prepared.borrow] in
        try await self?.admitLocalCall(
          meetingID, attempt: attempt, selection: selection, borrow: borrow)
      }
    } else {
      admit = { @MainActor [weak self] in
        try Task.checkCancellation()
        self?.busy.insert(attempt)
        self?.activity[meetingID] = .writing
      }
    }
    // Each call holds the lane (local) and the busy mark until it has physically ended, however
    // it ends; the waits between calls hold neither.
    let call = prepared.complete
    complete = { [weak self] instructions, prompt in
      if local { await self?.markLocalCallStarted(attempt) }
      do {
        let answer = try await call(instructions, prompt)
        await self?.callEnded(attempt, local: local)
        return answer
      } catch {
        await self?.callEnded(attempt, local: local)
        throw error
      }
    }

    // R11: an AI title only when "Write a summary when a meeting ends" is on, here and again
    // after the save; a Write again with it off writes the summary alone.
    let titleWanted = preview == nil && deps.isEnabled()
    // #3147 PR4A (D5): on a qualified route the model reads tagged turns and note blocks; the
    // notes are tagged only when their blocks are known, so no notes are lost.
    let references = inputs.sources.map {
      MeetingSummary.ReferenceRequest(sources: $0, inputs: inputs.summaryInputs)
    }
    let transcriptText = inputs.sources?.taggedTranscript ?? inputs.transcript.text
    let notesText =
      inputs.sources.flatMap { $0.notes.isEmpty ? nil : $0.taggedNotes } ?? inputs.notes
    let answer: MeetingSummary.Written
    do {
      answer = try await deps.write(
        transcriptText, notesText, inputs.factsBlock, prepared.window,
        local ? deps.localCallTimeoutSeconds : deps.hostedCallTimeoutSeconds, references, admit,
        complete)
    } catch let failure as MeetingSummary.Failure {
      if local {
        lane.endSummaryCall()
        releaseUnstartedLocalCall(attempt)
      }
      switch failure {
      case .cancelled: return Ending(end: .cancelled)
      case .tooLong: return Ending(end: .problem(.tooLong))
      case .windowTooSmall: return Ending(end: .problem(.notForSummaries))
      case .providerFailed, .empty, .truncated, .timedOut:
        return Ending(end: .problem(.providerFailed))
      case .rejected(let reason):
        // #4353 D9: a cloud model problem only when the shared reading says this attempt's
        // captured model cannot be used; anything else keeps its existing explanation.
        return Ending(end: .problem(Self.rejectedProblem(reason, selection)))
      }
    } catch {
      if local {
        lane.endSummaryCall()
        releaseUnstartedLocalCall(attempt)
      }
      return Ending(end: Task.isCancelled ? .cancelled : .problem(.providerFailed))
    }
    if local {
      lane.endSummaryCall()
      releaseUnstartedLocalCall(attempt)
    }
    if Task.isCancelled { return Ending(end: .cancelled) }
    // The title line is never part of the saved summary, usable or not (R6).
    let (title, text) = MeetingSummary.splitTitle(answer.text)
    // An answer that was only a title is no summary: the one saved before stays (review r4 F5).
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Ending(end: .problem(.providerFailed))
    }

    // The meeting changed while the summary was written (a rename, new notes, a Retry, a model
    // change): the answer describes something else and is not saved.
    let latestSelection = preview == nil ? deps.selection() : selection
    guard currentInputs(
      meetingID, selection: latestSelection, override: preview, withSources: true) == inputs
    else {
      return Ending(end: .stale)
    }
    if let preview {
      guard case .generating(let id) = previews[meetingID], id == attempt,
        documents.manifest(meetingID)?.summary == baseSummary, !documents.hasUnsavedSummary(meetingID)
      else { return Ending(end: .stale) }
      previews[meetingID] = .comparing(
        Candidate(
          id: attempt, current: currentSummary, text: text, choice: preview,
          base: baseSummary, inputs: inputs, answer: answer))
      return Ending(end: .preview)
    }
    // Every answer of the checked save also ends the owed mark. The save holds a relaunch.
    busy.insert(attempt)
    defer { busy.remove(attempt) }
    switch await documents.publishGeneratedSummary(
      meetingID, text: text, inputs: inputs.summaryInputs, writtenInParts: answer.inParts,
      approvedUserEdit: approvedUserEdit)
    {
    case .saved:
      await publishReferences(meetingID, answer: answer, text: text)
      // Checked once more after the save: a change during the write makes the saved summary
      // show as out of date (its recorded inputs differ), and the attempt counts as stale.
      let unchanged =
        currentInputs(meetingID, selection: deps.selection(), withSources: true) == inputs
      if unchanged, titleWanted, deps.isEnabled(), let title, !Task.isCancelled {
        await deps.assignTitle(meetingID, title)
      }
      return Ending(end: unchanged ? .written : .stale, savedMark: true)
    case .userEditKept, .notesChanged, .baseChanged:
      return Ending(end: .stale, savedMark: true)
    case nil:
      return Ending(
        end: documents.isForgotten(meetingID) || Task.isCancelled
          ? .cancelled : .problem(.storageFailed))
    }
  }

  /// Publish links only for the exact accepted text. A failed save costs only the links.
  private func publishReferences(_ meetingID: UUID, answer: MeetingSummary.Written, text: String) async {
    let document = answer.document.flatMap {
      MeetingDocumentHash.sameBytes($0.renderedMarkdownSHA256, MeetingDocumentHash.sha256(text))
        ? $0 : nil
    }
    if !(await deps.saveReferences(meetingID, document)) {
      deps.log("meeting summary references not saved")
    }
  }

  /// A call has physically ended.
  private func callEnded(_ attempt: UUID, local: Bool) {
    if local {
      lane.endSummaryCall()
      // The physical call ended: its protection ends with it, and only its own.
      if let call = runningLocalCall, call.attempt == attempt {
        runningLocalCall = nil
        if call.provider == .ollama { onOllamaModelReleased?() }
      }
    }
    busy.remove(attempt)
  }

  private func markLocalCallStarted(_ attempt: UUID) {
    if runningLocalCall?.attempt == attempt { runningLocalCall?.started = true }
  }

  /// A write that ends (or gives up) after admission but before its call began never reaches
  /// `callEnded`, so it releases the identity here. A started call keeps it until its own end.
  private func releaseUnstartedLocalCall(_ attempt: UUID) {
    if let call = runningLocalCall, call.attempt == attempt, !call.started {
      runningLocalCall = nil
    }
  }

  /// Waits until a local call may start, then takes the lane in the same main-actor step.
  private func admitLocalCall(
    _ meetingID: UUID, attempt: UUID, selection: (provider: LLMProvider, model: String),
    borrow: (@Sendable () async throws -> MeetingSummaryProviders.BorrowOutcome)? = nil
  ) async throws {
    activity[meetingID] = .waiting
    while true {
      let provider = selection.provider
      await MeetingWorkAdmission.waitUntil({ [deps] in deps.isLocalTurn(provider) }, wakes: deps.wakes)
      try Task.checkCancellation()
      if deps.isLocalTurn(provider), !lane.summaryCallRunning {
        lane.beginSummaryCall()
        // #4287: the attempt's own captured selection; only local calls are admitted here.
        runningLocalCall = RunningLocalCall(
          attempt: attempt, provider: selection.provider, model: selection.model)
        busy.insert(attempt)
        activity[meetingID] = .writing
        // #4319: EG-1 takes the shared server here. A file import holding it wins: the lane
        // and the busy mark go back and the attempt waits for its next turn (the import's pin
        // keeps the turn closed until the import lets go, so this does not spin).
        guard let borrow, try await borrow() == .retryLater else { return }
        lane.endSummaryCall()
        runningLocalCall = nil
        busy.remove(attempt)
        activity[meetingID] = .waiting
        continue
      }
    }
  }

  /// `attemptRevision`: given by a running attempt, the artifact revision it was PREPARED with
  /// (#4473), so what it saves names the model that wrote it even when Settings changed while
  /// it waited. Not given: the revision a new attempt would use now, for "is this out of date".
  /// `withSources` (#3147 PR4A): read the reference sources too (an attempt, and its checks
  /// before and after the save). Off for "is this out of date", which a view asks often and
  /// which the recorded summary inputs alone decide.
  private func currentInputs(
    _ meetingID: UUID, selection: (provider: LLMProvider, model: String),
    attemptRevision: String?? = nil, override: HistoryPolishChoice? = nil, withSources: Bool = false
  ) -> Inputs? {
    guard let transcript = deps.visibleTranscript(meetingID) else {
      fingerprints[meetingID] = nil
      return nil
    }
    let notes = documents.notes(meetingID)
    let hashes = fingerprint(meetingID, transcript)
    // #4286: the facts block exactly as the summary is told it, so a changed fact makes the
    // summary out of date.
    let factsBlock = deps.promptFacts(meetingID).map { MeetingSummary.factsBlock($0) } ?? ""
    let factsHash = factsBlock.isEmpty ? nil : MeetingDocumentHash.sha256(factsBlock)
    // #3147 PR4A (D5): the route alone decides the prompt version, so "out of date" never
    // depends on the sources. The sources are used only when they make exactly the transcript
    // this summary is hashed from; otherwise the plain prompt runs and no document is made.
    let referencing = deps.writesReferences(selection.provider, selection.model)
    let sources =
      referencing && withSources
      ? deps.referenceSources(meetingID).flatMap {
        MeetingDocumentHash.sameBytes($0.plainTranscript, transcript.text) ? $0 : nil
      } : nil
    let revision = if let size = override?.egOneSize {
      deps.overrideArtifactRevision(size)
    } else {
      deps.artifactRevision(selection.provider)
    }
    return Inputs(
      transcript: transcript, notes: notes, factsBlock: factsBlock,
      summaryInputs: SummaryInputs(
        transcriptSHA256: hashes.textSHA,
        notesRevision: documents.manifest(meetingID)?.notes?.revision ?? 0,
        speakerNamesSHA256: hashes.namesSHA,
        promptVersion: referencing
          ? MeetingSummaryReferences.promptVersion : MeetingSummary.promptVersion,
        providerID: selection.provider.rawValue,
        configurationSHA256: MeetingSummary.configurationFingerprint(
          provider: selection.provider, model: selection.model,
          artifactRevision: attemptRevision ?? revision),
        transcriptAttemptID: transcript.transcriptAttemptID, contextSHA256: factsHash,
        modelOverride: override.map { .init(model: $0.model, egOneSize: $0.egOneSize?.rawValue) }),
      sources: sources)
  }

  /// #4148: true when the meeting is ready and has no visible transcript text, so the Summary
  /// tab says there is nothing to summarize instead of offering Write summary.
  func hasNothingToSummarize(_ meetingID: UUID) -> Bool {
    deps.hasNoWords(meetingID)
  }

  /// The meeting's summary was written from inputs that differ from the meeting now (a rename,
  /// new notes, a Retry, another model or prompt): it is shown as out of date, never as current
  /// (R60). False when there is no summary or it records no inputs (the user wrote it).
  /// Typed notes not yet saved count as changed notes, and a meeting whose current facts cannot
  /// be read counts as changed, never as current.
  func isOutOfDate(_ meetingID: UUID) -> Bool {
    guard let recorded = documents.manifest(meetingID)?.summary?.inputs else { return false }
    var selection = deps.selection()
    var choice: HistoryPolishChoice?
    if let manual = recorded.modelOverride {
      guard let provider = LLMProvider(rawValue: recorded.providerID) else { return true }
      selection = (provider, manual.model)
      choice = HistoryPolishChoice(
        provider: provider, model: manual.model, egOneSize: manual.egOneSize.flatMap(EGOneSize.init))
    }
    guard let current = currentInputs(meetingID, selection: selection, override: choice) else {
      return true
    }
    return recorded != current.summaryInputs || documents.hasUnsavedNotes(meetingID)
  }

  /// Why no summary can be written with the current setting, whatever any attempt did: no
  /// provider, or a provider or model that cannot summarize. Nil when one can be tried.
  func configurationProblem() -> Problem? {
    let selection = deps.selection()
    // #4353 D9: an empty cloud choice is explained from the setting itself, before any request.
    if MeetingSummaryProviders.isCloudWithNoModel(selection.provider, model: selection.model) {
      return .cloudNoModel(selection.provider)
    }
    switch MeetingSummary.capability(
      selection.provider, model: selection.model, ollamaModelIsRemote: nil)
    {
    case .noProvider: return .noProvider
    case .notForSummaries: return .notForSummaries
    case .supported: return nil
    }
  }

  /// What a Write summary or Write again press found (`requestWrite`).
  enum WriteRequest: Equatable {
    case started
    /// The summary is the user's own text: confirm, then `writeAgain(replacing:)` with this
    /// SHA-256.
    case needsConfirmation(String)
    /// Nothing started: a press is already being handled, an attempt runs, or the documents
    /// could not be read or saved (shown as the meeting's activity).
    case refused
  }

  /// Meetings whose Write press is being handled: a second press does nothing.
  private(set) var requesting: Set<UUID> = []

  /// A Write summary or Write again press: the documents read, typing saved, then either an
  /// attempt or a confirmation. Reserved before any wait, so two presses start one attempt.
  func requestWrite(_ meetingID: UUID) async -> WriteRequest {
    guard !requesting.contains(meetingID), currentAttempt[meetingID] == nil else {
      return .refused
    }
    requesting.insert(meetingID)
    defer { requesting.remove(meetingID) }
    guard await documents.load(meetingID) else {
      activity[meetingID] = .failed(.notesUnreadable)
      return .refused
    }
    guard await documents.flushSummary(meetingID) else {
      activity[meetingID] = .failed(.storageFailed)
      return .refused
    }
    if let summary = documents.manifest(meetingID)?.summary, summary.origin == .userEdited {
      return .needsConfirmation(summary.sha256)
    }
    writeAgain(meetingID, replacing: nil)
    return .started
  }

  /// #4353 D9: what a refused request means for the attempt that got it, read with its own
  /// captured provider and model.
  static func rejectedProblem(
    _ reason: PolishFailureReason, _ selection: (provider: LLMProvider, model: String)
  ) -> Problem {
    reason.meansCloudModelUnavailable(provider: selection.provider, model: selection.model)
      ? .cloudModelUnavailable(selection.provider, selection.model) : .providerFailed
  }

  static func providerKind(_ provider: LLMProvider) -> MeetingSummaryFinishedTelemetry.ProviderKind
  {
    switch provider {
    case .openAI, .gemini, .claude: return .hosted
    case .ollama, .appleIntelligence, .egOne, .s1Mini: return .local
    case .none: return .none
    }
  }

  /// #4001 step 2b-C: the transcript and speaker-name hashes of the last transcript this
  /// meeting was judged against, reused while the words and names are byte-identical, so a
  /// summary keystroke does not hash the whole meeting again. Only these two hashes are kept;
  /// notes, provider, model and prompt are read fresh by `currentInputs` every time.
  private struct Fingerprint {
    let text: String
    let names: [String: String]
    let textSHA: String
    let namesSHA: String
  }

  @ObservationIgnored private var fingerprints: [UUID: Fingerprint] = [:]

  #if DEBUG
    /// How many times the two hashes were computed rather than reused.
    @ObservationIgnored var fingerprintBuildsForTesting = 0
  #endif

  private func fingerprint(_ meetingID: UUID, _ transcript: VisibleTranscript) -> Fingerprint {
    if let kept = fingerprints[meetingID],
      MeetingDocumentHash.sameBytes(kept.text, transcript.text),
      MeetingDocumentHash.sameBytes(kept.names, transcript.speakerNames)
    {
      return kept
    }
    #if DEBUG
      fingerprintBuildsForTesting += 1
    #endif
    let made = Fingerprint(
      text: transcript.text, names: transcript.speakerNames,
      textSHA: MeetingDocumentHash.sha256(transcript.text),
      namesSHA: Self.speakerNamesSHA256(transcript.speakerNames))
    fingerprints[meetingID] = made
    return made
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
    kind: MeetingSummaryFinishedTelemetry.ProviderKind, settled: Bool, current: Bool
  ) {
    if current { currentAttempt[meetingID] = nil }
    if settled {
      let outcome: MeetingSummaryFinishedTelemetry.Outcome
      switch end {
      case .written: outcome = .written
      case .preview: return
      case .stale: outcome = .stale
      case .cancelled: outcome = .cancelled
      case .nothingToSummarize: outcome = .nothingToSummarize
      case .problem(.noProvider): outcome = .noProvider
      // #4353 D9: no cloud model chosen is a setup state like an engine that cannot summarize;
      // nothing was attempted, so it never reads as a provider failure.
      case .problem(.notForSummaries), .problem(.notReady), .problem(.ollamaTooOld),
        .problem(.tooLong), .problem(.cloudNoModel):
        outcome = .unsupported
      case .problem(.providerFailed), .problem(.notesUnreadable), .problem(.storageFailed),
        .problem(.cloudModelUnavailable):
        outcome = .failed
      }
      // R57, enforced here for every path: `none` exactly with `noProvider`. A provider other
      // than none never yields `none` (`providerKind`), and none always ends as `noProvider`.
      deps.emitFinished(
        MeetingSummaryFinishedTelemetry(
          outcome: outcome, providerKind: outcome == .noProvider ? .none : kind))
      deps.log("meeting summary finished outcome=\(outcome.rawValue) provider=\(kind.rawValue)")
    } else {
      deps.log("meeting summary unsettled; stays owed")
    }
    guard current, !terminating else { return }
    switch end {
    case .problem(let problem): activity[meetingID] = .failed(problem)
    case .written, .preview, .stale, .cancelled, .nothingToSummarize: activity[meetingID] = nil
    }
  }
}
