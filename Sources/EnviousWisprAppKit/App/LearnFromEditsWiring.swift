import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

// MARK: - Learn from edits: composition (#996 chunk 5h)
//
// Everything the feature needs at runtime, built once at the composition root
// and retained for the app's lifetime: the durable ledger, the vocabulary
// access over the real word list, the proposal coordinator, the overlay
// presenter (the coordinator holds it WEAKLY, so this holder is what keeps it
// alive), the paste observer and the watcher (the paste registry holds
// subscribers WEAKLY, likewise), the one arm-selection value the watcher and
// the Settings row both read, and the source-app name lookup the Pending tab
// uses. `WisprBootstrapper` constructs it and injects `coordinator`,
// `settingsPresentation` and `sourceAppName` into the Settings environment.
//
// Production selects NOTHING: `CorrectionJudgeArmSelection.qualified` is
// empty, so `select` answers `.unavailable(.noQualifiedArm)` everywhere, the
// watcher's `selectJudge` returns nil (`model_unavailable`) and the Settings
// row is disabled with its reason. The Debug UAT door below is the only way a
// judge serves before a candidate qualifies.

/// `TelemetryService` already carries the nine `learn*` emitters (5c); the
/// coordinator and watcher talk to the protocol so a spy can stand in.
extension TelemetryService: LearnFromEditsTelemetrySink {}

#if DEBUG
  /// Debug builds mirror every learn event into app.log as one
  /// `[LearnFromEdits]` line (shape only, the same fields the wire row
  /// carries), so a Live UAT reads its verdict from the log the way every
  /// other drill does (`code-tooling.md` RULE: uat-verdicts-from-app-log).
  /// Forwards everything to the real sink; Release has no such type.
  @MainActor
  final class LearnFromEditsLoggingSink: LearnFromEditsTelemetrySink {
    private let inner: any LearnFromEditsTelemetrySink
    init(_ inner: any LearnFromEditsTelemetrySink) { self.inner = inner }

    private func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }

    func learnSkipped(reason: T.SkipReason) {
      log("learn_skipped reason=\(reason.rawValue)")
      inner.learnSkipped(reason: reason)
    }
    func learnObservationEnded(
      reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int
    ) {
      log("learn_observation_ended reason=\(reason.rawValue) settled_bursts=\(settledBursts) app_class=\(appClass.rawValue) duration_ms=\(durationMs)")
      inner.learnObservationEnded(reason: reason, settledBursts: settledBursts, appClass: appClass, durationMs: durationMs)
    }
    func learnJudged(
      arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int, queueWaitMs: Int?
    ) {
      log("learn_judged arm=\(arm.rawValue) outcome=\(outcome.rawValue) candidates=\(candidates) accepted=\(accepted) latency_ms=\(latencyMs)")
      inner.learnJudged(arm: arm, outcome: outcome, candidates: candidates, accepted: accepted, latencyMs: latencyMs, queueWaitMs: queueWaitMs)
    }
    func learnProposed(state: T.TargetState) {
      log("learn_proposed state=\(state.rawValue)")
      inner.learnProposed(state: state)
    }
    func learnCardShown() {
      log("learn_card_shown")
      inner.learnCardShown()
    }
    func learnCardExpired() {
      log("learn_card_expired")
      inner.learnCardExpired()
    }
    func learnResolved(decision: T.Decision, surface: T.Surface, state: T.TargetState, outcome: T.ResolutionOutcome) {
      log("learn_resolved decision=\(decision.rawValue) surface=\(surface.rawValue) state=\(state.rawValue) outcome=\(outcome.rawValue)")
      inner.learnResolved(decision: decision, surface: surface, state: state, outcome: outcome)
    }
    func learnSaveFailed(reason: T.SaveFailure) {
      log("learn_save_failed reason=\(reason.rawValue)")
      inner.learnSaveFailed(reason: reason)
    }
    func learnLedgerUntrusted(kind: T.LedgerUntrustedKind, disposition: T.LedgerDisposition) {
      log("learn_ledger_untrusted kind=\(kind.rawValue) disposition=\(disposition.rawValue)")
      inner.learnLedgerUntrusted(kind: kind, disposition: disposition)
    }
  }
#endif

@MainActor
final class LearnFromEditsWiring {
  let store: CorrectionProposalStore
  let coordinator: CorrectionProposalCoordinator
  let presenter: CorrectionProposalOverlayPresenter
  let observer: any PastedRegionObserving
  let watcher: ObservedCorrectionWatcher
  /// The step 7 selection, read ONCE at composition and shared by the watcher
  /// and the Settings row so the two cannot disagree.
  let selection: CorrectionJudgeArmSelection
  let settingsPresentation: LearnFromEditsSettingsPresentation
  /// The retained judge instances the selection maps onto; nil when unavailable.
  private let productionJudge: SelectedCorrectionJudge?
  #if DEBUG
    /// The UAT door's judge, once loaded. Until then (and in every launch
    /// without the door) `selectJudge` falls through to production.
    private(set) var debugOverride: SelectedCorrectionJudge?
    private(set) var debugDoor: DebugJudgeDoor?
  #endif

  init(
    settings: SettingsManager,
    customWords: CustomWordsCoordinator,
    packs: VocabularyPackManager,
    overlay: OverlayDirector,
    pasteCompletionRegistry: PasteCompletionRegistry,
    telemetry: any LearnFromEditsTelemetrySink,
    storeDirectory: URL = AppConstants.appSupportURL,
    osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    // Test seams, all defaulted to the live objects: a scripted observer and
    // frontmost app so a composition test can walk a paste to a card without
    // the accessibility API, and a selection override so it can stage a
    // serving judge while `qualified` stays empty.
    observer: (any PastedRegionObserving)? = nil,
    scheduler: (any PastedRegionScheduling)? = nil,
    frontmost: (@MainActor () -> FrontmostApplication?)? = nil,
    selectJudgeForTests: (@MainActor () -> SelectedCorrectionJudge?)? = nil,
    debugExportPath: String? = LearnFromEditsWiring.debugExportPathFromEnvironment()
  ) {
    let store = CorrectionProposalStore(directory: storeDirectory)
    let suggestionService = customWords.suggestionService
    let vocabulary = CorrectionVocabularyAccess(
      userWords: { [weak customWords] in customWords?.customWords ?? [] },
      packTerms: { [weak packs] in packs?.enabledPackTerms() ?? [] },
      refreshTrustworthy: { [weak customWords] in
        guard let customWords, customWords.refreshFromDiskIfPossible() else { return .unreadable }
        return .fresh(customWords.customWords)
      },
      save: { [weak customWords] word, spelling in
        guard let customWords else { return "Couldn't save" }
        return CustomWordSaveHelper.saveAndConfirm(word, carrying: spelling, through: customWords)
      },
      classify: { WordSuggestionService.classifyByHeuristic($0) })
    let coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: vocabulary, presenter: nil, telemetry: telemetry)
    coordinator.initialize()
    let presenter = CorrectionProposalOverlayPresenter(host: overlay, coordinator: coordinator)
    coordinator.attach(presenter: presenter)

    // Step 7, once: platform, measured qualification and availability.
    let selection = CorrectionJudgeArmSelection.select(
      osMajor: osMajor,
      afmAvailable: suggestionService.isAvailable,
      rulesDigest: RulesCorrectionJudge.configDigest(policy: .v2),
      afmDigest: WordSuggestionService.correctionJudgeConfigDigest)
    let productionJudge: SelectedCorrectionJudge?
    switch selection {
    case .arm(.rules):
      productionJudge = SelectedCorrectionJudge(arm: .rules, judge: RulesCorrectionJudge(policy: .v2))
    case .arm(.afm):
      productionJudge = SelectedCorrectionJudge(arm: .afm, judge: suggestionService)
    case .unavailable:
      productionJudge = nil
    }
    self.productionJudge = productionJudge
    self.selection = selection
    self.settingsPresentation = LearnFromEditsSettingsPresentation(selection: selection)

    // One scheduler for the observer and the watcher's paste clock, so the
    // deadline and the observation share a time base.
    let scheduler = scheduler ?? TaskPastedRegionScheduler()
    let observer = observer ?? PastedRegionObserver(ax: LivePastedRegionAXOperations(), scheduler: scheduler)
    // `self` is not available to the closures yet; a box hands the watcher a
    // stable reference the moment `self` exists.
    let box = SelectionBox()
    let watcher = ObservedCorrectionWatcher(
      dependencies: ObservedCorrectionWatcherDependencies(
        isLearnFromEditsOn: { [weak settings] in settings?.learnFromEdits ?? false },
        selectJudge: { selectJudgeForTests?() ?? box.wiring?.selectJudge() },
        frontmost: frontmost ?? {
          guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
          return FrontmostApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        },
        observer: observer,
        nowMs: { scheduler.nowMs },
        userWords: { [weak customWords] in customWords?.customWords ?? [] },
        packTerms: { [weak packs] in packs?.enabledPackTerms() ?? [] },
        coordinator: coordinator,
        telemetry: telemetry))
    pasteCompletionRegistry.subscribe(watcher)

    self.store = store
    self.coordinator = coordinator
    self.presenter = presenter
    self.observer = observer
    self.watcher = watcher
    box.wiring = self

    #if DEBUG
      if let debugExportPath {
        let door = DebugJudgeDoor(exportPath: debugExportPath)
        self.debugDoor = door
        door.load { [weak self] judge in self?.debugOverride = judge }
      }
    #endif
  }

  /// The env var is read here and nowhere else, and only in Debug: Release
  /// has no env-var read, no loader and no override.
  static func debugExportPathFromEnvironment() -> String? {
    #if DEBUG
      return ProcessInfo.processInfo.environment[DebugJudgeDoor.environmentKey]
    #else
      return nil
    #endif
  }

  /// What the watcher runs: the Debug door's judge when it has loaded, else
  /// production's (nil = `model_unavailable`).
  func selectJudge() -> SelectedCorrectionJudge? {
    #if DEBUG
      if let debugOverride { return debugOverride }
    #endif
    return productionJudge
  }

  /// `SettingsManager.onChange` fan-out for the one key this feature owns.
  func settingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
    guard key == .learnFromEdits else { return }
    watcher.learnFromEditsChanged(isOn: settings.learnFromEdits)
  }

  /// Each real transition into `.recording` (the pipeline-state owner calls it).
  func recordingStarted() {
    watcher.recordingStarted()
  }

  /// The Pending tab's app-name lookup: the app's display name from its bundle,
  /// nil when the id resolves to nothing (never the raw identifier).
  static func sourceAppName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    let bundle = Bundle(url: url)
    let candidates: [String?] = [
      bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
      url.deletingPathExtension().lastPathComponent,
    ]
    return candidates.compactMap { $0 }.first { !$0.isEmpty }
  }

  var sourceAppName: @MainActor (String) -> String? { { Self.sourceAppName(bundleID: $0) } }

  private final class SelectionBox {
    weak var wiring: LearnFromEditsWiring?
  }
}

#if DEBUG
  /// The founder-approved UAT door (plan §16, 2026-09-19): when
  /// `EW_LEARN_FROM_EDITS_JUDGE_EXPORT` names a locked candidate's FP32 export
  /// directory, this launch runs that judge as arm `classifier`. Read once at
  /// composition, loaded asynchronously; until it is ready the watcher sees
  /// production's selection. A load failure publishes nothing and is logged.
  /// Release compiles none of this: no env-var read, no loader, no override.
  @MainActor
  final class DebugJudgeDoor {
    static let environmentKey = "EW_LEARN_FROM_EDITS_JUDGE_EXPORT"

    enum State: Equatable {
      case loading
      case ready
      case failed(String)
      case rejected(String)
    }

    let exportPath: String
    private(set) var state: State = .loading
    private var task: Task<Void, Never>?

    init(exportPath: String) {
      self.exportPath = exportPath
    }

    func load(_ publish: @escaping @MainActor (SelectedCorrectionJudge) -> Void) {
      guard exportPath.hasPrefix("/") else {
        state = .rejected("not an absolute path")
        Self.log("learn-from-edits UAT door REJECTED: \(exportPath) is not an absolute path")
        return
      }
      let url = URL(fileURLWithPath: exportPath, isDirectory: true)
      task = Task { @MainActor [weak self] in
        do {
          let judge = try await CoreMLCorrectionJudge.load(exportDirectory: url)
          guard let self else { return }
          self.state = .ready
          let id = judge.identity
          Self.log(
            "learn-from-edits UAT door ACTIVE: export=\(id.exportDirectory.path) "
              + "threshold=\(id.threshold) languages=all "
              + "package_sha256=\(id.executionIdentity["package_sha256"] ?? "?") arm=classifier")
          publish(SelectedCorrectionJudge(arm: .classifier, judge: judge))
        } catch {
          self?.state = .failed("\(error)")
          Self.log("learn-from-edits UAT door FAILED to load \(url.path): \(error)")
        }
      }
    }

    private static func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }
  }
#endif
