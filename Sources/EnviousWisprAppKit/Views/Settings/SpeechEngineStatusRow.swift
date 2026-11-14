import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// #4578: one speech engine's install state and the operation running on it, as both Settings
/// tabs show it (Dictation > Engine and EnviousMeet > Models). Pure: built from the installation
/// owner's facts (`SpeechModelLibrary`, Whisper's setup service) and the existing Parakeet
/// delivery row; never a second readiness read.
struct SpeechEngineStatus: Equatable {
  enum Install: Equatable {
    case checking
    case ready
    case notInstalled(leftovers: Bool)
    case removing
  }

  /// Who a button acts on. Parakeet keeps its three owners (#3546): the serving model's own
  /// download, the background Ultra upgrade, and the explicit Retry after loading failed.
  enum Owner: Equatable {
    case parakeetForeground, parakeetUpgrade, parakeetRetry
    case whisper
    /// Whisper's "Something went wrong": Try Again re-detects.
    case whisperDetect
  }

  enum Operation: Equatable {
    /// A download, check or verification in progress; `fraction` draws a bar.
    case working(title: String, detail: String?, fraction: Double?, cancel: Owner?)
    case paused(title: String, resume: Owner, cancel: Owner?)
    case failed(title: String, detail: String?, retry: Owner)
  }

  var install: Install
  var operation: Operation?

  /// Remove is offered on every downloaded engine, picked or not.
  var offersRemove: Bool { install == .ready }
  /// Set up model is offered when nothing is downloaded and nothing is under way.
  var offersSetUp: Bool {
    if case .notInstalled = install, operation == nil { return true }
    return false
  }
  var offersLeftoverRemoval: Bool { install == .notInstalled(leftovers: true) }
  var isPaused: Bool {
    if case .paused = operation { return true }
    return false
  }

  static func parakeet(
    installed: Bool?, removing: Bool, leftovers: Bool, installWanted: Bool = true,
    row: SpeechEngineSettingsView.ParakeetRow?
  ) -> SpeechEngineStatus {
    if removing { return SpeechEngineStatus(install: .removing, operation: nil) }
    let install: Install =
      switch installed {
      case true?: .ready
      case false?: .notInstalled(leftovers: leftovers)
      case nil: .checking
      }
    guard let row else { return SpeechEngineStatus(install: install, operation: nil) }
    // A recorded removal refuses Resume and Retry (only Set up model brings Parakeet back), so a
    // failed or interrupted removal offers Set up model and the leftover removal instead.
    if !installWanted, installed != true {
      return SpeechEngineStatus(install: install, operation: nil)
    }
    let owner: Owner =
      switch row.owner {
      case .foreground: .parakeetForeground
      case .backgroundUpgrade: .parakeetUpgrade
      case .retry: .parakeetRetry
      }
    // "Couldn't load" belongs to bytes that are there; with nothing downloaded the action is
    // Set up model, which also grants a fresh cycle.
    if owner == .parakeetRetry, installed == false {
      return SpeechEngineStatus(install: install, operation: nil)
    }
    let operation: Operation =
      if row.showsCancel {
        .working(title: row.title, detail: row.detail, fraction: nil, cancel: owner)
      } else if row.action == .fastModelResume {
        .paused(title: row.title, resume: owner, cancel: owner)
      } else if row.action == .fastModelTryAgain {
        .failed(title: row.title, detail: row.detail, retry: owner)
      } else {
        .working(title: row.title, detail: row.detail, fraction: nil, cancel: nil)
      }
    return SpeechEngineStatus(install: install, operation: operation)
  }

  static func whisper(_ state: WhisperSetupState, removing: Bool, leftovers: Bool = false)
    -> SpeechEngineStatus
  {
    // A removal drains through intermediate delivery states; none of them offers an action.
    if removing { return SpeechEngineStatus(install: .removing, operation: nil) }
    switch state {
    case .checking:
      return SpeechEngineStatus(install: .checking, operation: nil)
    case .notDownloaded:
      return SpeechEngineStatus(install: .notInstalled(leftovers: leftovers), operation: nil)
    case .downloading(let progress, let status):
      return SpeechEngineStatus(
        install: .notInstalled(leftovers: leftovers),
        operation: .working(
          title: SpeechEngineStatusCopy.downloading, detail: status, fraction: progress,
          cancel: .whisper))
    case .paused:
      return SpeechEngineStatus(
        install: .notInstalled(leftovers: leftovers),
        operation: .paused(title: SpeechEngineStatusCopy.paused, resume: .whisper, cancel: .whisper))
    case .ready:
      return SpeechEngineStatus(install: .ready, operation: nil)
    case .error(let message):
      return SpeechEngineStatus(
        install: .notInstalled(leftovers: leftovers),
        operation: .failed(
          title: SpeechEngineStatusCopy.somethingWentWrong, detail: message,
          retry: .whisperDetect))
    }
  }

  /// The confirm box before Remove, or nil when the engine is neither the dictation nor the
  /// meeting engine (it is removed at once). An engine in use always asks; its sentences depend
  /// on what stays downloaded: meetings use another downloaded engine on their own, so they get
  /// a sentence only when none is left, and the box may then carry only its title.
  static func removalConfirmation(
    engine: ASRBackendType, dictationEngine: ASRBackendType, meetingEngine: ASRBackendType,
    otherInstalled: Bool
  ) -> (title: String, message: String)? {
    let forDictation = dictationEngine == engine
    let forMeetings = meetingEngine == engine
    guard forDictation || forMeetings else { return nil }
    let other: ASRBackendType = engine == .parakeet ? .whisper : .parakeet
    var lines: [String] = []
    if forDictation {
      lines.append(
        otherInstalled
          ? SpeechEngineStatusCopy.dictationUntilChoose(
            other: other.displayName, engine: engine.displayName)
          : SpeechEngineStatusCopy.dictationUntilDownload)
    }
    if forMeetings, !otherInstalled { lines.append(SpeechEngineStatusCopy.meetingsUntilDownload) }
    return (SpeechEngineStatusCopy.removeTitle(engine.displayName), lines.joined(separator: " "))
  }
}

/// #4578: the status line on each engine card and under the selected engine's summary, the
/// same on both Settings tabs. Remove asks first only when the engine is in use.
struct SpeechEngineStatusRow: View {
  /// Where the row sits. Only the Dictation summary registers Settings Map places (one place
  /// per id) and reports the preparing impression; the cards and EnviousMeet's tab do not.
  enum Place { case dictationSummary, dictationCard, meetings }

  let engine: ASRBackendType
  let place: Place

  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(SpeechModelLibrary.self) private var library: SpeechModelLibrary?
  @Environment(ModelDeliveryHome.self) private var modelDelivery: ModelDeliveryHome?
  @Environment(EngineCoordinator.self) private var engineCoordinator: EngineCoordinator?
  @State private var pendingConfirmation: (title: String, message: String)?

  private var registers: Bool { place == .dictationSummary }

  private var status: SpeechEngineStatus {
    switch engine {
    case .parakeet:
      SpeechEngineStatus.parakeet(
        installed: library?.installedSnapshot(.parakeet),
        removing: library?.isRemovingParakeet ?? false,
        leftovers: library?.parakeetHasLeftovers ?? false,
        installWanted: library?.parakeetInstallWanted ?? true,
        row: modelDelivery.flatMap { SpeechEngineSettingsView.parakeetRow(of: $0) })
    case .whisper:
      SpeechEngineStatus.whisper(
        setup.whisperSetup.setupState, removing: setup.whisperSetup.isRemoving,
        leftovers: library?.whisperHasLeftovers ?? false)
    }
  }

  private var meetingActive: Bool { setup.whisperSetup.isMeetingActive?() == true }

  private var removeNotice: WhisperRemoveNotice? {
    switch engine {
    case .parakeet: library?.parakeetRemoveNotice
    case .whisper: setup.whisperSetup.removeNotice
    }
  }

  var body: some View {
    let status = status
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        installLine(status.install)
        Spacer(minLength: 8)
        if status.offersRemove { removeButton }
        if status.offersSetUp { setUpButton }
        if status.offersLeftoverRemoval { leftoverButton }
        // The re-check where it was before (#3385): always beside Parakeet's line; beside
        // Whisper's only when settled or paused.
        if status.install != .removing,
          engine == .parakeet || status.operation == nil || status.isPaused
        {
          recheckButton
        }
      }
      if let operation = status.operation { operationView(operation) }
      if status.offersRemove || status.offersSetUp, meetingActive {
        // #4325: Remove and a download wait for an active meeting; the commands refuse too.
        note(MeetingDownloadAdmission.refusal)
      }
      // Rendered outside the state: a failed removal can change the state, and its reason
      // must stay (Codex 2c-r1 P2).
      if let removeNotice {
        Text(SpeechEngineSettingsView.removeNoticeText(removeNotice))
          .font(.stHelper)
          .foregroundStyle(.stWarning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    // Leftover bytes are a disk fact: read again whenever this engine's install line changes.
    .task(id: status.install) { await library?.refreshLeftovers() }
    .confirmationDialog(
      Text(verbatim: pendingConfirmation?.title ?? ""),
      isPresented: Binding(
        get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
      titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        pendingConfirmation = nil
        remove()
      } label: {
        Text(SpeechEngineStatusCopy.removeButton)
      }
      Button(role: .cancel) {
        pendingConfirmation = nil
      } label: {
        Text(SpeechEngineStatusCopy.cancelButton)
      }
    } message: {
      Text(verbatim: pendingConfirmation?.message ?? "")
    }
  }

  // MARK: - Lines

  @ViewBuilder private func installLine(_ install: SpeechEngineStatus.Install) -> some View {
    switch install {
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        note(EngineSummaryCopy.checking)
      }
    case .ready:
      readyLine
    case .notInstalled:
      ProviderStatusChip(
        status: ProviderStatus(label: SpeechEngineStatusCopy.notDownloaded, tone: .needsSetup),
        isHeadline: place == .dictationSummary)
    case .removing:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        note(SpeechEngineStatusCopy.removing)
      }
    }
  }

  /// "Model ready", or Whisper's "Getting the model ready" while dictation's engine warms it
  /// (#1635: delivery ready means on disk; the load into memory takes about 30 seconds).
  @ViewBuilder private var readyLine: some View {
    let warming = engineCoordinator?.status.warmInFlight
    if engine == .whisper, ModelPreparingCopy.isPreparing(warmInFlight: warming) {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        note(ModelPreparingCopy.label(warmInFlight: warming))
      }
      .onAppear {
        // #1635: reported where the words entered the visible hierarchy, once per showing.
        if place == .dictationSummary {
          TelemetryService.shared.settingsModelPreparingImpression(
            engine: "whisper", reason: "engine_swap")
        }
      }
    } else {
      ProviderStatusChip(
        status: EngineSummaryPresentation.fastModelStatus(admitted: true),
        isHeadline: place == .dictationSummary)
    }
  }

  @ViewBuilder private func operationView(_ operation: SpeechEngineStatus.Operation) -> some View {
    switch operation {
    case .working(let title, let detail, let fraction, let cancel):
      VStack(alignment: .leading, spacing: 4) {
        Text(title).settingsRowLabel()
        if let fraction {
          ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 260)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if let detail { Text(detail).settingsReadingCopy().lineLimit(2) }
          Spacer(minLength: 8)
          if let cancel { actionButton(SettingsItemCopy.Engine.fastCancel, primary: false, cancel) }
        }
      }
    case .paused(let title, let resume, let cancel):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title).settingsReadingCopy()
        Spacer(minLength: 8)
        if let cancel { actionButton(SettingsItemCopy.Engine.fastCancel, primary: false, cancel) }
        actionButton(SettingsItemCopy.Engine.fastResume, primary: true, resume)
      }
    case .failed(let title, let detail, let retry):
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: "exclamationmark.triangle.fill")
          .font(.stHelper)
          .foregroundStyle(.stWarning)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if let detail { Text(detail).settingsReadingCopy() }
          Spacer(minLength: 8)
          actionButton(SettingsItemCopy.Engine.fastTryAgain, primary: true, retry)
        }
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.stHelper).foregroundStyle(.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func note(_ text: LocalizedStringResource) -> some View { note(String(localized: text)) }

  // MARK: - Buttons

  private var removeButton: some View {
    // The approved label "Remove" (plan §3.8). The Settings search title stays "Remove Model"
    // (`SettingsItemCopy.Engine.whisperRemove`), so searches keep landing on this button.
    Button(action: requestRemove) {
      Text(SpeechEngineStatusCopy.removeButton).font(.stHelper)
        .settingsHoverQuiet(tint: .stError)
    }
    .controlSize(.small)
    .buttonStyle(.borderless)
    .foregroundStyle(.stError)
    .disabled(meetingActive)
    .mapRegistration(registers && engine == .whisper ? .whisperModelRemove : nil)
  }

  private var setUpButton: some View {
    Button(action: setUp) {
      EnviousButtonLabel(DictationSettingsCopy.Engine.setUpModel, size: .medium)
    }
    .settingsButton(.filled, shape: .roundedRect, size: .medium, isEnabled: !meetingActive)
    .mapRegistration(registers && engine == .whisper ? .whisperModelSetUp : nil)
  }

  private var leftoverButton: some View {
    Button(action: remove) {
      Text(SpeechEngineStatusCopy.removeLeftovers).font(.stHelper)
        .settingsHoverQuiet(tint: .stError)
    }
    .controlSize(.small)
    .buttonStyle(.borderless)
    .foregroundStyle(.stError)
    .disabled(meetingActive)
    .mapRegistration(nil)
  }

  @ViewBuilder private var recheckButton: some View {
    if place == .dictationSummary {
      Button(action: recheck) {
        Image(systemName: "arrow.clockwise").settingsHoverQuiet()
      }
      .buttonStyle(.borderless)
      .help(Text(recheckLabel))
      .accessibilityLabel(Text(recheckLabel))
      .mapRegistration(engine == .whisper ? .whisperModelRecheck : .transcriptionEngineRecheckFast)
    }
  }

  private var recheckLabel: LocalizedStringResource {
    engine == .whisper
      ? SettingsItemCopy.Engine.whisperRecheck : EngineSummaryCopy.recheckFast
  }

  private func actionButton(
    _ title: LocalizedStringResource, primary: Bool, _ owner: SpeechEngineStatus.Owner
  ) -> some View {
    Button {
      run(owner, cancel: !primary)
    } label: {
      EnviousButtonLabel(title, size: .medium)
    }
    .settingsButton(primary ? .filled : .quiet, shape: .roundedRect, size: .medium, isEnabled: true)
    .mapRegistration(registers ? Self.mapID(owner, cancel: !primary) : nil)
  }

  /// The Settings Map place each existing action already had on the Engine tab.
  private static func mapID(_ owner: SpeechEngineStatus.Owner, cancel: Bool) -> SettingsMapID? {
    switch owner {
    case .parakeetForeground, .parakeetUpgrade:
      cancel ? .fastModelCancelDownload : .fastModelResume
    case .parakeetRetry: cancel ? .fastModelCancelDownload : .fastModelTryAgain
    case .whisper: cancel ? .whisperModelCancelDownload : .whisperModelResume
    case .whisperDetect: .whisperModelTryAgain
    }
  }

  // MARK: - Commands

  private func requestRemove() {
    let otherEngine: ASRBackendType = engine == .parakeet ? .whisper : .parakeet
    if let confirmation = SpeechEngineStatus.removalConfirmation(
      engine: engine, dictationEngine: settings.selectedBackend,
      meetingEngine: settings.meetingTranscriptEngine.backendType,
      otherInstalled: library?.installedSnapshot(otherEngine) == true)
    {
      pendingConfirmation = confirmation
    } else {
      remove()
    }
  }

  private func remove() {
    switch engine {
    case .parakeet: library?.removeParakeet()
    case .whisper: setup.whisperSetup.removeModel()
    }
  }

  private func setUp() {
    guard !meetingActive else { return }
    switch engine {
    case .parakeet: library?.installParakeet()
    case .whisper: setup.whisperSetup.downloadModel()
    }
  }

  private func recheck() {
    switch engine {
    case .parakeet: library?.invalidateParakeet()
    case .whisper: Task { await setup.whisperSetup.forceDetectState() }
    }
  }

  private func run(_ owner: SpeechEngineStatus.Owner, cancel: Bool) {
    switch owner {
    case .parakeetForeground:
      if cancel {
        modelDelivery?.cancelParakeetDownload()
      } else {
        modelDelivery?.resumeParakeetDownload()
      }
    case .parakeetUpgrade:
      if cancel {
        modelDelivery?.cancelParakeetUpgradeDownload()
      } else {
        modelDelivery?.resumeParakeetUpgradeDownload()
      }
    case .parakeetRetry:
      if cancel {
        modelDelivery?.cancelParakeetDownload()
      } else {
        modelDelivery?.retryParakeetUpgradeAndWarm()
      }
    case .whisper:
      if cancel { setup.whisperSetup.cancelDownload() } else { setup.whisperSetup.downloadModel() }
    case .whisperDetect:
      Task { await setup.whisperSetup.detectState() }
    }
  }
}

extension View {
  /// Registers the control's Settings Map place when it has one here; otherwise it takes none
  /// (the same control on a card or on EnviousMeet's tab).
  @ViewBuilder fileprivate func mapRegistration(_ id: SettingsMapID?) -> some View {
    if let id {
      self.settingsArrivalFocusControl().settingsMapRegistration(id)
    } else {
      self.settingsArrivalWithoutInheritedPlace()
    }
  }
}

/// #4578: the words of the shared engine status line and its confirm box.
enum SpeechEngineStatusCopy {
  static let notDownloaded = String(
    localized: "Not downloaded",
    comment: "Speech engine settings, engine card: this speech engine's model is not on this Mac.")
  static let removing = String(
    localized: "Removing model...",
    comment: "Speech engine settings: the speech model is being deleted from this Mac.")
  static let downloading = String(
    localized: "Downloading...",
    comment: "Speech engine settings, Whisper model: the current setup step.")
  static let paused = String(
    localized: "Download paused. Resume anytime.",
    comment: "Speech engine settings: a model download is paused and can be resumed.")
  static let somethingWentWrong = String(
    localized: "Something went wrong",
    comment: "Speech engine settings, Whisper model: checking or setting up the model failed.")
  static let removeLeftovers = LocalizedStringResource(
    "Remove leftover files",
    comment:
      "Speech engine settings, engine card: a removal stopped part-way and left model files on this Mac; this deletes them."
  )
  static let removeButton = LocalizedStringResource(
    "Remove", comment: "Speech engine settings, remove confirm box: deletes the speech model.")
  static let cancelButton = LocalizedStringResource(
    "Cancel", comment: "Speech engine settings, remove confirm box: keeps the speech model.")

  static func removeTitle(_ engine: String) -> String {
    String(
      localized: "Remove \(engine)?",
      comment: "Speech engine settings, remove confirm box title; the speech engine's name.")
  }

  static func dictationUntilChoose(other: String, engine: String) -> String {
    String(
      localized: "Dictation won't work until you choose \(other) or download \(engine) again.",
      comment:
        "Speech engine settings, remove confirm box: the removed engine is the dictation engine and the other engine is downloaded. First the other engine's name, then the removed one's."
    )
  }

  static let dictationUntilDownload = String(
    localized: "Dictation won't work until you download a speech engine again.",
    comment:
      "Speech engine settings, remove confirm box: the removed engine is the dictation engine and no other speech engine is downloaded."
  )

  static let meetingsUntilDownload = String(
    localized: "Meetings won't get a transcript until you download a speech engine again.",
    comment:
      "Speech engine settings, remove confirm box: the removed engine is the meeting engine and no other speech engine is downloaded."
  )
}
