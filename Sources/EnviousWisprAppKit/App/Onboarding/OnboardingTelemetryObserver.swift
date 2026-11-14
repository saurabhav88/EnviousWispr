import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// The new Setup's telemetry (#4528 chunks F2a and F2b, plan §3.8, M67, M68). Observation only:
/// it never changes the flow, a download, readiness or a setting, and it owns no task or timer.
///
/// Screens (F2a): a step change is not a screen being shown (hidden steps, DEBUG positioning,
/// restore and readiness moves all change the step), so the only producer of
/// `onboarding.screen_viewed` is `screenPresented(_:resumed:)`, which Setup's screens call when a
/// screen is actually on screen (chunk D). Rows: one for the FIRST presentation of each step in a
/// visit, so there are at most `maxScreenRowsPerVisit`; revisits still move the position.
///
/// Choices, downloads, blockers and completion (F2b) come from the coordinator's observation
/// hook (`attach`) and the runtime's existing tick:
/// - Choices: the FINAL committed pick per kind in the visit, with the recommendation and rules
///   version as they were when it was picked, sent once at the visit's end (completion or
///   abandon). Restored picks are not this visit's evidence; unknown agreement is omitted.
/// - Downloads: one row per accepted attempt (an owner answered `requested`) whose end is
///   known. Parakeet's owner answers with the attempt's own end (`DeliveryOutcome`), which is
///   sent as is. Whisper and local polish answer acceptance only, so their end is read from the
///   owner's phase (installed `ok`, failed or unavailable `failed`, stopped after an explicit
///   Cancel `cancelled`); limit: an end that returns to the start's own phase before acceptance
///   can be missed. Refusals, superseded starts and installed models send none; a retry is a new
///   attempt. An attempt still running when the visit ends is not observed and sends none.
/// - Blockers: one `onboarding.step_blocked` per episode (a reason's continuous presence): the
///   coordinator's typed block (disk short, refused start) or a failed download on Downloads;
///   on Getting ready, a measured failed load of the picked local polish model (`polish_failed`).
/// - Completion: after the durable write, the final choices then `onboarding.completed`; an
///   interrupted completion sends only `onboarding.completed` (no visit was shown).
/// Nothing is sent unless the visit in flight belongs to the new Setup (completion excepted:
/// only the new Setup's coordinator completes it).
@MainActor
final class OnboardingTelemetryObserver {
  struct Inputs {
    /// The in-flight visit's start (`OnboardingProgress.sessionStart`), nil when none.
    var visitStart: () -> Date?
    /// Whether the in-flight visit is the new Setup's (never the old onboarding's).
    var visitOwned: () -> Bool
    /// Keeps the shared visit box's position current for an abandon row.
    var updatePosition: (OnboardingStep) -> Void
    var emitStarted: () -> Void = {}
    var emitPractice: (SetupPracticeResult, TimeInterval) -> Void = { _, _ in }
    var emitScreenViewed: (String, OnboardingTelemetry.Entry, Double) -> Void
    var now: () -> Date
    /// `onboarding.choice_made`: choice, recommended, followed (nil = unknown), rules version.
    var emitChoice: (OnboardingTelemetry.Choice, OnboardingTelemetry.Choice?, Bool?, String) -> Void
    /// `onboarding.download_finished`: model, result, seconds, bytes.
    var emitDownload:
      (OnboardingTelemetry.DownloadModel, OnboardingTelemetry.DownloadResult, Double, Int64?) ->
        Void
    /// `onboarding.step_blocked`: step, reason.
    var emitBlocked: (String, OnboardingTelemetry.BlockedReason) -> Void
    /// `onboarding.completed` (the legacy properties are read by the live closure).
    var emitCompleted: (OnboardingTelemetry.CompletionSummary?) -> Void
    /// The owner's phase for a Setup download.
    var downloadPhase: (OnboardingTelemetry.DownloadModel) -> OnboardingDownloadPhase?
    /// The settings-telemetry model projection (`SettingsProjection.model`) with the existing
    /// model list; the only way a cloud model value is built.
    var projectModel: (LLMProvider, String) -> OnboardingTelemetry.ProjectedModel
    /// `onboarding.film_finished`: result, last scene.
    var emitFilm: (OnboardingTelemetry.FilmResult, String) -> Void = { _, _ in }
  }

  /// Plan §3.8: the accepted ceiling, one per Setup screen (`done` is never presented).
  static let maxScreenRowsPerVisit = 14

  private struct ChoiceRecord {
    var choice: OnboardingTelemetry.Choice
    var recommended: OnboardingTelemetry.Choice?
    var followed: Bool?
    var rulesVersion: String
  }

  /// One download start, from the moment it is sent to its owner (one lifecycle for answered
  /// and unanswered starts). A row is sent only once the owner answered `requested` AND an end
  /// was observed; whichever comes second sends it.
  private struct Request {
    let id: Int
    let model: OnboardingTelemetry.DownloadModel
    let startedAt: Date
    let bytes: Int64?
    /// The visit it began in; an answer is never adopted by another visit.
    let visit: Date
    /// The owner's phase when the start was sent. Before acceptance, an end counts only once the
    /// phase has moved from it, so an earlier failure or an installed model is not this start's.
    let initialPhase: OnboardingDownloadPhase?
    /// The owner answers with the attempt's end (Parakeet): no phase is read for this start.
    var ownerReportsEnd: Bool
    /// Started while an earlier owner-reporting start of the model was running: the same
    /// transfer, already counted by that start.
    var joined = false
    var accepted = false
    var cancelRequested = false
    /// The end observed (result, seconds), kept until acceptance confirms it.
    var ended: (OnboardingTelemetry.DownloadResult, Double)?
  }

  private let inputs: Inputs
  private var startedReported = false
  private var didReportPractice = false
  private var visit: Date?
  private var lastPresented: OnboardingStep?
  private var seenThisVisit: Set<OnboardingStep> = []
  private var choices: [OnboardingTelemetry.ChoiceKind: ChoiceRecord] = [:]
  private var requests: [Request] = []
  private var blocker: OnboardingTelemetry.BlockedReason?
  /// The polish pick whose failed load already sent its row this episode.
  private var polishFailure: String?
  /// Rejected cloud key revisions that already sent `key_check_failed` this visit.
  private var rejectedKeys: Set<String> = []
  /// How this visit's film ended, for the completion summary.
  private var filmResult: OnboardingTelemetry.FilmResult?

  init(inputs: Inputs) {
    self.inputs = inputs
  }

  /// Connects the coordinator's observation hook; returns the closure the runtime's existing
  /// tick calls (download ends and blockers are read there, no new timer).
  func attach(to coordinator: OnboardingCoordinator) -> () -> Void {
    coordinator.onObservation = { [weak self] in self?.observe($0) }
    return { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      self.tick(
        step: coordinator.state.step, block: coordinator.block, choices: coordinator.state.choices,
        readiness: coordinator.state.readiness)
    }
  }

  // MARK: Cloud key (D3b, M82 r1)

  /// A typed key outcome from See all's cloud panel (its check's current answer, or Add my key
  /// later; never view rendering, never the key). The last outcome is the visit's key choice
  /// row; a rejection also sends one `step_blocked key_check_failed` per provider and stored
  /// revision, so a revisit or a repeated read adds no row.
  func keyReported(_ event: SetupKeyEvent, rulesVersion: String) {
    guard ownedVisit() else { return }
    let outcome: OnboardingTelemetry.KeyOutcome
    switch event {
    case .saved: outcome = .saved
    case .passed: outcome = .checkPassed
    case .skipped: outcome = .skipped
    case .rejected(let provider, let revision):
      outcome = .checkFailed
      if rejectedKeys.insert("\(provider.rawValue)#\(revision)").inserted {
        inputs.emitBlocked(OnboardingStep.polishSeeAll.rawValue, .keyCheckFailed)
      }
    }
    choices[.key] = ChoiceRecord(
      choice: .key(outcome), recommended: nil, followed: nil, rulesVersion: rulesVersion)
  }

  // MARK: Film (E integration)

  /// The film ended (Start using EnviousWispr): one `film_finished` row per visit, and the result the
  /// completion summary carries. Sent from the button action, never from rendering.
  func filmEnded(_ result: OnboardingTelemetry.FilmResult, lastScene: FilmScene) {
    guard ownedVisit(), filmResult == nil else { return }
    filmResult = result
    inputs.emitFilm(result, lastScene.rawValue)
  }

  func setupStarted() {
    guard ownedVisit(), !startedReported else { return }
    startedReported = true
    inputs.emitStarted()
  }

  func practiceReported(_ result: SetupPracticeResult, duration: TimeInterval) {
    guard ownedVisit(), !didReportPractice else { return }
    didReportPractice = true
    inputs.emitPractice(result, duration)
  }

  fileprivate static func emitPracticeResult(_ result: SetupPracticeResult, _ duration: TimeInterval) {
    let telemetry = TelemetryService.shared
    let step = "practice_dictation"
    switch result {
    case .completed(let polished):
      telemetry.onboardingStepCompleted(
        step: step, result: "completed", durationSeconds: duration, polishRan: polished)
    case .missedBox:
      telemetry.onboardingStepCompleted(step: step, result: "missed_box", durationSeconds: duration)
    case .noSpeech:
      telemetry.onboardingStepCompleted(step: step, result: "no_speech", durationSeconds: duration)
    case .skipped:
      telemetry.onboardingStepCompleted(step: step, result: "skipped", durationSeconds: duration)
    case .pipelineFailed:
      telemetry.onboardingStepBlocked(step: step, reason: "pipeline_failed", durationSeconds: duration)
    case .microphoneDenied:
      telemetry.onboardingStepBlocked(
        step: step, reason: "mic_denied", permission: "microphone", durationSeconds: duration)
    case .accessibilityDenied:
      telemetry.onboardingStepBlocked(
        step: step, reason: "accessibility_denied", permission: "accessibility",
        durationSeconds: duration)
    }
  }

  // MARK: Screens (F2a)

  /// A Setup screen is now on screen. `resumed` is the coordinator's `resumedFromCheckpoint`.
  func screenPresented(_ step: OnboardingStep, resumed: Bool) {
    guard ownedVisit() else { return }
    guard step != lastPresented else { return }
    inputs.updatePosition(step)
    let entry = Self.entry(to: step, from: lastPresented, resumed: resumed)
    lastPresented = step
    // First view of this screen in this visit only (the set is bounded by the 14 screens).
    guard seenThisVisit.insert(step).inserted, seenThisVisit.count <= Self.maxScreenRowsPerVisit,
      let start = visit
    else { return }
    inputs.emitScreenViewed(step.rawValue, entry, max(0, inputs.now().timeIntervalSince(start)))
  }

  /// `resume` for the first screen of a restored visit; `back` for an earlier screen in Setup's
  /// order; otherwise `forward`.
  static func entry(
    to step: OnboardingStep, from previous: OnboardingStep?, resumed: Bool
  ) -> OnboardingTelemetry.Entry {
    guard let previous else { return resumed ? .resume : .forward }
    let order = OnboardingStep.allCases
    guard let to = order.firstIndex(of: step), let from = order.firstIndex(of: previous) else {
      return .forward
    }
    return to < from ? .back : .forward
  }

  // MARK: Coordinator observations (F2b)

  func observe(_ observation: OnboardingObservation) {
    switch observation {
    case .choicesCommitted(let before, let after, let recommended):
      guard ownedVisit() else { return }
      record(before: before, after: after, recommended: recommended)
    case .downloadStarting(let model, let request, let at, let bytes, let ownerReportsEnd):
      guard ownedVisit(), let visit else { return }
      // Before the owner sees the start (a Retry clears the old failure): every earlier
      // phase-observed start of this model records the end it shows now, with its own timing.
      observeEnds(of: model)
      let phase = inputs.downloadPhase(model)
      var start = Request(
        id: request, model: model, startedAt: at, bytes: bytes, visit: visit,
        initialPhase: phase, ownerReportsEnd: ownerReportsEnd)
      if ownerReportsEnd, Self.isRunning(phase),
        requests.contains(where: { $0.model == model && $0.ownerReportsEnd && !$0.joined })
      {
        start.joined = true  // single-flight: the running transfer answers both starts
      }
      requests.append(start)
    case .downloadAnswered(let request, let answer, let ended):
      // The visit check first: a new visit drops every earlier start before the lookup.
      let owned = ownedVisit()
      guard let index = requests.firstIndex(where: { $0.id == request }) else { return }
      // Not accepted, or from an earlier visit: no attempt.
      guard owned, visit == requests[index].visit, answer == .requested else {
        requests.remove(at: index)
        return
      }
      if requests[index].ownerReportsEnd {
        let r = requests.remove(at: index)
        if let ended {
          // The owner's own end for this attempt, with its own timing; no phase read.
          if !r.joined {
            inputs.emitDownload(
              r.model, ended, max(0, inputs.now().timeIntervalSince(r.startedAt)), r.bytes)
          }
        } else {
          // Accepted without an end: observe it like any other start.
          var accepted = r
          accepted.ownerReportsEnd = false
          accepted.accepted = true
          requests.append(accepted)
        }
        return
      }
      if requests[index].ended == nil,
        requests.contains(where: {
          $0.id != request && $0.model == requests[index].model && $0.accepted && $0.ended == nil
        })
      {
        // The same transfer already counted under an accepted start: one transfer, one row.
        requests.remove(at: index)
        return
      }
      requests[index].accepted = true
      sendEnded()
    case .downloadsCancelled:
      // Explicit Cancel evidence, for starts not yet answered too.
      for index in requests.indices { requests[index].cancelRequested = true }
    case .blockChanged(let block, let step, let choices):
      guard ownedVisit() else { return }
      updateBlocker(step: step, block: block, choices: choices)
    case .warmFailed(let step):
      // One row per failure: each failure waits for an explicit Retry, so it is its own episode.
      guard ownedVisit() else { return }
      inputs.emitBlocked(step.rawValue, .warmupFailed)
    case .reset:
      choices = [:]
      blocker = nil
      polishFailure = nil
      rejectedKeys = []
    case .completed(let final, let interrupted, let rulesVersion):
      let owned = !interrupted && ownedVisit()
      // Agreement is read from this visit's picks before they are sent and cleared.
      let summary = completionSummary(final, interrupted: !owned, rulesVersion: rulesVersion)
      if owned {
        observeAllEnds()
        emitChoices()
      }
      inputs.emitCompleted(summary)
      clearVisit()
    }
  }

  /// The runtime's existing tick: observed download ends and blockers.
  func tick(
    step: OnboardingStep, block: OnboardingDownloadBlock?, choices: OnboardingChoices,
    readiness: OnboardingReadiness
  ) {
    guard ownedVisit() else { return }
    observeAllEnds()
    updateBlocker(step: step, block: block, choices: choices)
    updatePolishFailure(step: step, choices: choices, readiness: readiness)
  }

  /// The visit ended without completion (window close, app quit): the final choices and any
  /// observed download ends are sent, before the caller's abandon row.
  func visitEnded() {
    guard ownedVisit() else { return }
    observeAllEnds()
    emitChoices()
    clearVisit()
  }

  // MARK: Private

  /// Whether a visit the new Setup owns is in flight; a new visit starts every count over (a
  /// reset of a live visit keeps its start, so it does not).
  private func ownedVisit() -> Bool {
    guard inputs.visitOwned(), let start = inputs.visitStart() else { return false }
    if start != visit {
      clearVisit()
      visit = start
    }
    return true
  }

  private func clearVisit() {
    startedReported = false
    didReportPractice = false
    visit = nil
    lastPresented = nil
    seenThisVisit = []
    choices = [:]
    requests = []
    blocker = nil
    polishFailure = nil
    rejectedKeys = []
    filmResult = nil
  }

  private func record(
    before: OnboardingChoices, after: OnboardingChoices, recommended: OnboardingRecommended
  ) {
    let version = recommended.rulesVersion
    func set(
      _ kind: OnboardingTelemetry.ChoiceKind, _ choice: OnboardingTelemetry.Choice?,
      recommended: OnboardingTelemetry.Choice? = nil
    ) {
      guard let choice else {
        choices[kind] = nil  // The pick was cleared: no final choice of this kind.
        return
      }
      choices[kind] = ChoiceRecord(
        choice: choice, recommended: recommended,
        followed: recommended.map { $0 == choice }, rulesVersion: version)
    }
    if before.languageMode != after.languageMode {
      // The Language screen offers Auto and the Mac's language side by side: no single
      // recommendation, so agreement is unknown and omitted.
      set(.language, after.languageMode.map { .language($0) })
    }
    if before.speech != after.speech {
      set(.speech, after.speech.map { .speech($0) }, recommended: .speech(recommended.speech))
    }
    if before.polish != after.polish {
      set(.polish, after.polish.map { .polish($0) }, recommended: .polish(recommended.polish))
    }
    if before.cloudProvider != after.cloudProvider {
      set(.cloudProvider, after.cloudProvider.map { .cloudProvider($0) })
    }
    if before.cloudModel != after.cloudModel || before.cloudProvider != after.cloudProvider {
      let model = after.cloudProvider.flatMap { provider in
        after.cloudModel.map {
          OnboardingTelemetry.Choice.cloudModel(inputs.projectModel(provider, $0))
        }
      }
      set(.cloudModel, model)
    }
  }

  private func emitChoices() {
    for kind in OnboardingTelemetry.ChoiceKind.allCases {
      guard let r = choices[kind] else { continue }
      inputs.emitChoice(r.choice, r.recommended, r.followed, r.rulesVersion)
    }
    choices = [:]
  }

  /// Records the end every open start shows now, then sends the accepted ones.
  private func observeAllEnds() {
    var models: [OnboardingTelemetry.DownloadModel] = []
    for r in requests where !models.contains(r.model) { models.append(r.model) }
    for model in models { observeEnds(of: model) }
  }

  /// Every open start of `model` records the end its owner shows now (if any) and its timing.
  private func observeEnds(of model: OnboardingTelemetry.DownloadModel) {
    let phase = inputs.downloadPhase(model)
    for index in requests.indices
    where requests[index].model == model && requests[index].ended == nil
      && !requests[index].ownerReportsEnd
    {
      let r = requests[index]
      // Before acceptance the phase must have moved since the start was sent.
      guard r.accepted || phase != r.initialPhase,
        let result = Self.end(phase, cancelled: r.cancelRequested)
      else { continue }
      requests[index].ended = (result, max(0, inputs.now().timeIntervalSince(r.startedAt)))
    }
    sendEnded()
  }

  /// Sends every accepted start with an observed end, once.
  private func sendEnded() {
    requests.removeAll { r in
      guard r.accepted, let (result, seconds) = r.ended else { return false }
      inputs.emitDownload(r.model, result, seconds, r.bytes)
      return true
    }
  }

  private static func isRunning(_ phase: OnboardingDownloadPhase?) -> Bool {
    switch phase {
    case .downloading?, .verifying?: true
    default: false
    }
  }

  /// An owner phase that ends a transfer: installed `ok`, failed or unavailable `failed`, stopped
  /// after an explicit Cancel `cancelled`; nil while it runs (or stopped without a Cancel).
  private static func end(_ phase: OnboardingDownloadPhase?, cancelled: Bool)
    -> OnboardingTelemetry.DownloadResult?
  {
    switch phase {
    case .installed?: .ok
    case .failed?, .unavailable?: .failed
    case .notStarted?, .paused?, nil: cancelled ? .cancelled : nil
    case .downloading?, .verifying?, .unknown?: nil
    }
  }

  /// One row per blocking episode: the typed block, else a failed current download on the
  /// Downloads screen. Never a "not ready" read, never error text.
  private func updateBlocker(
    step: OnboardingStep, block: OnboardingDownloadBlock?, choices: OnboardingChoices
  ) {
    let reason: OnboardingTelemetry.BlockedReason?
    switch block {
    case .insufficientDisk?: reason = .diskShort
    case .speechRefused?, .polishRefused?: reason = .downloadFailed
    case nil:
      reason = step == .downloads && currentDownloadFailed(choices) ? .downloadFailed : nil
    }
    guard reason != blocker else { return }
    blocker = reason
    if let reason { inputs.emitBlocked(step.rawValue, reason) }
  }

  /// One `polish_failed` row per failure episode of the picked local polish model, sent from
  /// Getting ready (where the failure is shown). Only a readiness measured for the current pick
  /// counts: a cleared, pending re-measure (an unrelated fact change, a Retry) and a measured
  /// loading (the owner starting the model again) neither end nor start an episode, so a Retry
  /// that fails again stays one episode. Only the current pick measured ready, a different pick,
  /// reset or the visit's end ends it; a later failure is a new row.
  private func updatePolishFailure(
    step: OnboardingStep, choices: OnboardingChoices, readiness: OnboardingReadiness
  ) {
    if let episode = polishFailure, choices.polish != episode { polishFailure = nil }
    guard let polish = choices.polish, readiness.polish == polish else { return }
    guard readiness.polishFailed else {
      // Only a ready model is a recovery; a measured loading (a Retry starting it) is not.
      if readiness.polishReady { polishFailure = nil }
      return
    }
    guard step == .gettingReady, polishFailure != polish else { return }
    polishFailure = polish
    inputs.emitBlocked(step.rawValue, .polishFailed)
  }

  private func currentDownloadFailed(_ choices: OnboardingChoices) -> Bool {
    func failed(_ phase: OnboardingDownloadPhase?) -> Bool {
      switch phase {
      case .failed?, .unavailable?: true
      default: false
      }
    }
    if let speech = choices.speech, failed(inputs.downloadPhase(.speech(speech))) { return true }
    if let polish = choices.polish, OnboardingDownloads.localModel(forPolish: polish) != nil,
      failed(inputs.downloadPhase(.polish(polish)))
    {
      return true
    }
    return false
  }

  /// The summary from the actual picks; nil when a required pick is missing (the event then
  /// carries only its original properties). Agreement is known only from this visit's picks.
  private func completionSummary(_ c: OnboardingChoices, interrupted: Bool, rulesVersion: String)
    -> OnboardingTelemetry.CompletionSummary?
  {
    guard let speech = c.speech, let language = c.languageMode else { return nil }
    let polish = c.polish ?? OnboardingChoices.polishOff
    let provider: LLMProvider
    let model: OnboardingTelemetry.PolishModel
    if OnboardingDownloads.localModel(forPolish: polish) != nil,
      let registered = SetupRules.registeredPolish[polish]
    {
      provider = registered.provider
      model = .local(polish)
    } else if polish == OnboardingChoices.polishOff {
      provider = .none
      model = .projected(inputs.projectModel(.none, ""))
    } else if polish == OnboardingChoices.polishCloud {
      guard let cloud = c.cloudProvider else { return nil }
      provider = cloud
      model = .projected(inputs.projectModel(cloud, c.cloudModel ?? ""))
    } else if let registered = SetupRules.registeredPolish[polish] {
      provider = registered.provider  // Apple Intelligence
      model = .projected(inputs.projectModel(provider, ""))
    } else {
      return nil
    }
    return OnboardingTelemetry.CompletionSummary(
      polishProvider: provider, polishModel: model, speechModel: speech,
      followedAllRecommendations: interrupted ? nil : followedAll(), languageMode: language,
      rulesVersion: rulesVersion, filmResult: interrupted ? nil : filmResult)
  }

  /// False if any recommended pick this visit differed; true only when both recommended kinds
  /// were picked this visit and matched; otherwise unknown.
  private func followedAll() -> Bool? {
    let known = [OnboardingTelemetry.ChoiceKind.speech, .polish].compactMap {
      choices[$0]?.followed
    }
    if known.contains(false) { return false }
    return known.count == 2 ? true : nil
  }
}

extension OnboardingTelemetryObserver.Inputs {
  /// The shared visit box's reads and position write (the live inputs use these).
  @MainActor
  static func visitBox(_ progress: OnboardingProgress) -> (
    visitStart: () -> Date?, updatePosition: (OnboardingStep) -> Void
  ) {
    (
      { progress.isInFlight ? progress.sessionStart : nil },
      { progress.update(screen: "setup", step: $0.rawValue) }
    )
  }

  /// Production inputs over the shared visit box, the live owners and F1's capture path
  /// (consent unchanged).
  @MainActor
  static func live(
    progress: OnboardingProgress, owners: OnboardingLiveOwners, facts: OnboardingLiveFacts,
    visitOwned: @escaping () -> Bool
  ) -> Self {
    let settings = owners.settings
    let telemetry = TelemetryService.shared
    let box = visitBox(progress)
    return Self(
      visitStart: box.visitStart,
      visitOwned: visitOwned,
      updatePosition: box.updatePosition,
      emitStarted: { telemetry.onboardingStarted() },
      emitPractice: OnboardingTelemetryObserver.emitPracticeResult,
      emitScreenViewed: { step, entry, elapsed in
        telemetry.onboardingScreenViewed(step: step, entry: entry, elapsedSeconds: elapsed)
      },
      now: { Date() },
      emitChoice: { choice, recommended, followed, version in
        telemetry.onboardingChoiceMade(
          choice, recommended: recommended, followedRecommendation: followed,
          rulesVersion: version)
      },
      emitDownload: { model, result, seconds, bytes in
        telemetry.onboardingDownloadFinished(
          model: model, result: result, seconds: seconds, bytes: bytes)
      },
      emitBlocked: { step, reason in telemetry.onboardingStepBlocked(step: step, reason: reason) },
      emitCompleted: { summary in
        telemetry.onboardingCompleted(
          asrBackend: settings.selectedBackend.rawValue,
          recordingMode: settings.recordingMode.rawValue, summary: summary)
      },
      downloadPhase: { model in
        let downloads = OnboardingDownloads(
          owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts))
        switch model {
        case .speech(let engine): return downloads.speechPhase(engine)
        case .polish(let id): return downloads.polishPhase(id)
        }
      },
      projectModel: { provider, id in
        OnboardingTelemetry.ProjectedModel(
          projectedBySettingsTelemetry: SettingsProjection.model(
            provider: provider, id: id, list: owners.cloudModelList.snapshot?.list))
      },
      emitFilm: { result, scene in telemetry.onboardingFilmFinished(result: result, lastScene: scene) })
  }
}
