import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #4287 PR 2: EnviousMeet's Models tab (founder decisions 1-6): the Live words and Transcript
/// engine cards, each a summary with Change and engine choice cards like dictation's Live Preview
/// and Engine tabs, then the transcript's language under its engine. Every choice, status and
/// download still comes from the app-owned row models, so closing Settings never drops a
/// download and nothing here keeps a setting of its own.
struct MeetingModelsTab: View {
  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 20) {
        MeetingLiveWordsCard()
        VStack(alignment: .leading, spacing: 12) {
          MeetingTranscriptEngineCard()
          BrandedSection {
            BrandedRow(showDivider: false) { MeetingTranscriptLanguageRow() }
          }
        }
      }
    }
  }
}

/// The heading, short line and "?" above an engine card, as the Live Preview engine section shows
/// them. The heading names the card's setting; it is drawn as a plain heading because the card
/// itself carries the setting's Settings Map place.
private struct MeetingEngineCardIntro: View {
  let rowTitle: String
  let short: LocalizedStringResource
  let help: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      Text(rowTitle.uppercased())
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(.stAccent)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 6) {
        Text(short)
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        SettingsInfoButton(rowTitle: rowTitle, tooltip: String(localized: help)) {
          SettingsHelpText(text: String(localized: help))
        }
      }
    }
    .padding(.leading, 4)
  }
}

private func meetingStatusText(_ text: String) -> some View {
  Text(text)
    .font(.stRowHelper)
    .foregroundStyle(.stTextSecondary)
    .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Live words

/// #4105 / #4287 PR 2: the Live words card. The summary names the engine; the status region keeps
/// the row's language menu, state lines and Download, Try Again or Cancel; Change opens the Apple
/// and Universal cards. A choice goes through `MeetingLiveWordsRowModel`, never Live Preview's own
/// setting (decision `macos-4105-independent-meeting-languages`).
struct MeetingLiveWordsCard: View {
  @Environment(MeetingLiveWordsRowModel.self) private var model
  @State private var choicesOpen: Bool?

  /// A user with no engine sees the choices open; Keep current closes them.
  private var isExpanded: Binding<Bool> {
    Binding(
      get: { choicesOpen ?? (model.selectedEngine == nil) },
      set: { choicesOpen = $0 })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MeetingEngineCardIntro(
        rowTitle: String(localized: MeetingsCopy.liveWordsTitle),
        short: MeetingsCopy.liveWordsShort, help: MeetingsCopy.liveWordsHelp)
      SettingsSummaryCard(
        map: .id(.meetingLiveWords),
        isExpanded: isExpanded,
        changeAccessibilityLabel: MeetingsCopy.changeLiveWordsEngine,
        change: .meetingLiveWordsChange,
        keepCurrent: .meetingLiveWordsKeepCurrent
      ) {
        summary
      } status: {
        status
      } choices: {
        choiceGrid
      }
      .onChange(of: model.selectedEngine) { _, _ in choicesOpen = false }
    }
    // Runs on appear and again whenever the stored choice changes, so a choice a meeting Start
    // saves while Settings stays open shows here (appear is a no-op save once a choice exists).
    .task(id: model.choiceGeneration) { await model.appear() }
  }

  @ViewBuilder
  private var summary: some View {
    if let engine = model.selectedEngine {
      EngineSummaryContent(
        icon: MeetingLiveWordsEngineCards.icon(engine),
        name: MeetingLiveWordsEngineCards.title(engine),
        short: languageLine(engine))
    } else {
      noEngineSummary
    }
  }

  private var noEngineSummary: some View {
    EngineSummaryContent(
      icon: "captions.bubble", name: String(localized: MeetingsCopy.chooseEngine),
      short: String(localized: MeetingsCopy.liveWordsShort))
  }

  private func languageLine(_ engine: LivePreviewEngineChoice) -> String {
    guard let code = model.selectedLanguage else {
      return String(localized: MeetingsCopy.chooseLanguage)
    }
    return model.languageName(engine: engine, code: code)
  }

  /// The language menu, the state lines and the one action, outside the disclosure so they are
  /// reachable with the cards closed.
  @ViewBuilder
  private var status: some View {
    if model.selectedEngine != nil {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(MeetingsCopy.liveWordsLanguageLabel)
            .font(.stRowHelper)
            .foregroundStyle(.stTextSecondary)
          languagePicker
          Spacer(minLength: 8)
          action
        }
        statusLine
      }
      .padding(.leading, 4)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        statusLine
        action
      }
      .padding(.leading, 4)
    }
  }

  private var languagePicker: some View {
    let engine = model.selectedEngine
    let options = engine.map { model.languages(for: $0) } ?? []
    return Picker(
      String(localized: MeetingsCopy.chooseLanguage),
      selection: Binding(
        get: { model.selectedLanguage },
        set: { code in
          guard let code else { return }
          Task { await model.selectLanguage(code) }
        })
    ) {
      if model.selectedLanguage == nil
        || !options.contains(where: { $0.code == model.selectedLanguage })
      {
        Text(MeetingsCopy.chooseLanguage).tag(String?.none)
      }
      ForEach(options) { option in
        Text(option.name).tag(String?.some(option.code))
      }
    }
    .labelsHidden()
    .disabled(engine == nil || options.isEmpty)
    .fixedSize()
  }

  @ViewBuilder private var statusLine: some View {
    switch model.status {
    case .loading:
      meetingStatusText(String(localized: MeetingsCopy.liveWordsChecking))
    case .notSetUp(let suggestion?):
      meetingStatusText(
        MeetingsCopy.liveWordsSuggested(
          model.languageName(engine: suggestion.engine, code: suggestion.language)))
    case .notSetUp(nil):
      meetingStatusText(String(localized: MeetingsCopy.liveWordsNotSetUp))
    case .ready:
      meetingStatusText(EngineSummaryCopy.ready)
    case .notDownloaded(let engine, let language):
      meetingStatusText(
        MeetingsCopy.liveWordsNotDownloaded(model.languageName(engine: engine, code: language)))
    case .downloading(let engine, let language, let fraction):
      VStack(alignment: .leading, spacing: 4) {
        meetingStatusText(
          MeetingsCopy.liveWordsDownloading(model.languageName(engine: engine, code: language)))
        // Apple reports no progress before it finishes: an indeterminate bar, never a percentage.
        if let fraction {
          ProgressView(value: fraction).frame(maxWidth: 220)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    case .failed:
      meetingStatusText(String(localized: MeetingsCopy.liveWordsFailed))
    case .appleUnavailable:
      meetingStatusText(String(localized: MeetingsCopy.liveWordsAppleUnavailable))
    }
  }

  /// Download, Try Again or (Universal only) Cancel. While a meeting is active the card says when
  /// a download can start instead; the model refuses the command too.
  @ViewBuilder private var action: some View {
    switch model.status {
    case .notDownloaded, .notSetUp(.some):
      downloadButton(SettingsItemCopy.LivePreview.universalDownload)
    case .failed:
      downloadButton(SettingsItemCopy.LivePreview.universalRetry)
    case .downloading(.universal, _, _):
      Button(String(localized: SettingsItemCopy.LivePreview.universalCancel)) {
        model.cancelDownload()
      }
    case .loading, .notSetUp(nil), .ready, .downloading, .appleUnavailable:
      EmptyView()
    }
  }

  @ViewBuilder private func downloadButton(_ title: LocalizedStringResource) -> some View {
    if let refusal = model.downloadRefusal {
      meetingStatusText(refusal)
    } else if model.universalDownloadUnavailable, model.selectedEngine != .apple {
      // The refusal, with Download kept beside it: a press after the cause is fixed retries.
      HStack(spacing: 8) {
        meetingStatusText(String(localized: MeetingsCopy.liveWordsDownloadUnavailable))
        Button(String(localized: title)) { model.download() }
      }
    } else {
      Button(String(localized: title)) { model.download() }
    }
  }

  /// With no engine chosen the card opens on its choices, which replace the summary slot, so the
  /// no-engine line leads the choices.
  private var choiceGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.selectedEngine == nil { noEngineSummary }
      Grid(horizontalSpacing: 12, verticalSpacing: 12) {
        GridRow(alignment: .top) {
          ForEach(MeetingLiveWordsEngineCards.order, id: \.self) { engine in
            card(engine).frame(maxWidth: .infinity, alignment: .top)
          }
        }
      }
    }
  }

  private func card(_ engine: LivePreviewEngineChoice) -> some View {
    let selectable = MeetingLiveWordsEngineCards.isSelectable(
      engine, appleAvailable: model.isAppleAvailable)
    return EngineCard(
      icon: MeetingLiveWordsEngineCards.icon(engine),
      map: .id(engine.meetingLiveWordsMapID),
      tagline: MeetingLiveWordsEngineCards.tagline(engine),
      unavailability: selectable ? nil : String(localized: MeetingsCopy.liveWordsAppleNeedsMacOS),
      isSelectable: selectable,
      isSelected: model.selectedEngine == engine,
      onSelect: {
        Task { await model.selectEngine(engine) }
        choicesOpen = false
      },
      fillsHeight: true,
      footer: { EmptyView() })
  }
}

/// #4287 PR 2: what the Live words engine cards say. Apple is listed where its meeting speech
/// cannot run, so the user sees why it is missing, and cannot be picked (the model refuses it
/// too).
enum MeetingLiveWordsEngineCards {
  static let order: [LivePreviewEngineChoice] = LivePreviewEngineChoice.allCases

  static func isSelectable(_ engine: LivePreviewEngineChoice, appleAvailable: Bool) -> Bool {
    switch engine {
    case .apple: appleAvailable
    case .universal: true
    }
  }

  static func icon(_ engine: LivePreviewEngineChoice) -> String {
    switch engine {
    case .apple: "apple.logo"
    case .universal: "globe"
    }
  }

  static func title(_ engine: LivePreviewEngineChoice) -> String {
    switch engine {
    case .apple: LivePreviewEngineCopy.appleTitle
    case .universal: LivePreviewEngineCopy.universalTitle
    }
  }

  static func tagline(_ engine: LivePreviewEngineChoice) -> String {
    switch engine {
    case .apple: String(localized: MeetingsCopy.liveWordsAppleTagline)
    case .universal: String(localized: MeetingsCopy.liveWordsUniversalTagline)
    }
  }
}

// MARK: - Transcript engine

/// #3973 C3 / #4287 PR 2: the Transcript engine card. Parakeet and Whisper Large v3 Turbo cards
/// with their model, download size, languages and chip (no transcribe times: those are measured
/// for dictation), and an Apple card that says Coming soon and cannot be picked. Whisper cannot be
/// picked until its model is downloaded; the shared Whisper download's Download, Resume and Cancel
/// stay in the status region (refused during a meeting).
struct MeetingTranscriptEngineCard: View {
  @Environment(MeetingTranscriptEngineRowModel.self) private var model
  @Environment(\.settingsNavigate) private var navigate
  @Environment(ModelDeliveryHome.self) private var modelDelivery: ModelDeliveryHome?
  @State private var choicesOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MeetingEngineCardIntro(
        rowTitle: String(localized: MeetingsCopy.transcriptEngineTitle),
        short: MeetingsCopy.transcriptEngineShort, help: MeetingsCopy.transcriptEngineHelp)
      SettingsSummaryCard(
        map: .id(.meetingTranscriptEngine),
        isExpanded: $choicesOpen,
        changeAccessibilityLabel: MeetingsCopy.changeTranscriptEngine,
        change: .meetingTranscriptEngineChange,
        keepCurrent: .meetingTranscriptEngineKeepCurrent
      ) {
        EngineSummaryContent(
          icon: MeetingTranscriptEngineCards.icon(.engine(model.selectedEngine)),
          name: MeetingTranscriptEngineCards.title(.engine(model.selectedEngine)),
          short: MeetingTranscriptEngineCards.tagline(.engine(model.selectedEngine)))
      } status: {
        status
      } choices: {
        choiceGrid
      }
      .onChange(of: model.selectedEngine) { _, _ in choicesOpen = false }
    }
    .task { await model.appear() }
  }

  private var parakeetModel: String {
    modelDelivery?.parakeetModelLabel ?? ParakeetModel.v3.displayName
  }

  @ViewBuilder private var status: some View {
    let lines = statusLines
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) { lines }
        Spacer(minLength: 8)
        action
      }
      if let engine = model.engineMismatch {
        meetingStatusText(
          String(
            localized: engine == .whisper
              ? MeetingsCopy.warningWhisperMeeting : MeetingsCopy.warningParakeetMeeting))
        Button(String(localized: MeetingsCopy.turnsOffDictationTitle)) {
          navigate(.meetings(.general))
        }
        .buttonStyle(.link)
        .font(.stRowHelper)
      }
    }
    .padding(.leading, 4)
  }

  @ViewBuilder private var statusLines: some View {
    if model.isChosenWhisperGone {
      meetingStatusText(String(localized: MeetingsCopy.whisperGone))
    }
    switch model.whisperState {
    case .notDownloaded:
      meetingStatusText(String(localized: MeetingsCopy.whisperNotDownloaded))
    case .downloading(let progress, _):
      meetingStatusText(String(localized: MeetingsCopy.whisperDownloading))
      ProgressView(value: progress).frame(maxWidth: 220)
    case .paused:
      meetingStatusText(String(localized: MeetingsCopy.whisperPaused))
    case .error:
      meetingStatusText(String(localized: MeetingsCopy.whisperFailed))
    case .checking, .ready:
      EmptyView()
    }
  }

  /// Download, Resume, Try Again or Cancel of the shared Whisper download. While a meeting is
  /// active the card says when a download can start instead; the model refuses it too.
  @ViewBuilder private var action: some View {
    switch model.whisperState {
    case .notDownloaded:
      downloadButton(SettingsItemCopy.LivePreview.universalDownload)
    case .paused:
      downloadButton(SettingsItemCopy.Engine.whisperResume)
    case .error:
      downloadButton(SettingsItemCopy.Engine.whisperTryAgain)
    case .downloading:
      Button(String(localized: SettingsItemCopy.Engine.whisperCancel)) { model.cancelDownload() }
    case .checking, .ready:
      EmptyView()
    }
  }

  @ViewBuilder private func downloadButton(_ title: LocalizedStringResource) -> some View {
    if let refusal = model.downloadRefusal {
      meetingStatusText(refusal)
    } else {
      Button(String(localized: title)) { model.download() }
    }
  }

  private var choiceGrid: some View {
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
      GridRow(alignment: .top) {
        ForEach(MeetingTranscriptEngineCards.order, id: \.self) { item in
          card(item).frame(maxWidth: .infinity, alignment: .top)
        }
      }
    }
  }

  private func card(_ item: MeetingTranscriptEngineCards.Item) -> some View {
    let selectable = MeetingTranscriptEngineCards.isSelectable(
      item, whisperReady: model.isWhisperReady)
    return EngineCard(
      icon: MeetingTranscriptEngineCards.icon(item),
      map: .id(item.mapID),
      tagline: MeetingTranscriptEngineCards.tagline(item),
      specs: MeetingTranscriptEngineCards.specs(item, parakeetModel: parakeetModel),
      unavailability: MeetingTranscriptEngineCards.unavailability(
        item, whisperReady: model.isWhisperReady),
      isSelectable: selectable,
      isSelected: item == .engine(model.selectedEngine),
      onSelect: {
        guard case .engine(let engine) = item else { return }
        Task { await model.select(engine) }
        choicesOpen = false
      },
      fillsHeight: true,
      footer: { EmptyView() })
  }
}

/// #4287 PR 2: what the Transcript engine cards say, in the order the grid shows them. The specs
/// reuse dictation's Engine cards' values (the same Parakeet model this Mac presents, the same
/// shared Whisper download), never their transcribe times.
enum MeetingTranscriptEngineCards {
  enum Item: Hashable {
    case engine(MeetingEngineChoice)
    /// Apple's speech engine for transcripts: shown, not ready yet (founder decision 3).
    case appleComingSoon

    var mapID: SettingsMapID {
      switch self {
      case .engine(let engine): engine.transcriptEngineMapID
      case .appleComingSoon: .meetingTranscriptEngineApple
      }
    }
  }

  static let order: [Item] = MeetingEngineChoice.allCases.map(Item.engine) + [.appleComingSoon]

  static func isSelectable(_ item: Item, whisperReady: Bool) -> Bool {
    switch item {
    case .engine(.parakeet): true
    case .engine(.whisper): whisperReady
    case .appleComingSoon: false
    }
  }

  static func unavailability(_ item: Item, whisperReady: Bool) -> String? {
    switch item {
    case .engine(.parakeet): nil
    case .engine(.whisper):
      whisperReady ? nil : String(localized: MeetingsCopy.whisperNotDownloaded)
    case .appleComingSoon: String(localized: MeetingsCopy.engineComingSoon)
    }
  }

  static func icon(_ item: Item) -> String {
    switch item {
    case .engine(.parakeet): "bolt.fill"
    case .engine(.whisper): "globe"
    case .appleComingSoon: "apple.logo"
    }
  }

  static func title(_ item: Item) -> String {
    switch item {
    case .engine(let engine): MeetingTranscriptEngineRowTitles.title(of: engine)
    case .appleComingSoon: LivePreviewEngineCopy.appleTitle
    }
  }

  static func tagline(_ item: Item) -> String {
    switch item {
    case .engine(.parakeet): String(localized: MeetingsCopy.transcriptParakeetTagline)
    case .engine(.whisper): String(localized: MeetingsCopy.transcriptWhisperTagline)
    case .appleComingSoon: String(localized: MeetingsCopy.transcriptAppleTagline)
    }
  }

  static func specs(_ item: Item, parakeetModel: String) -> [(label: String, value: String)] {
    let choice: EngineChoicePresentation.Choice
    switch item {
    case .engine(.parakeet): choice = EngineChoicePresentation.fast(parakeetModel: parakeetModel)
    case .engine(.whisper): choice = EngineChoicePresentation.allLanguages
    case .appleComingSoon: return []
    }
    return choice.specs.map { (String(localized: $0.label), $0.value.resolved) }
  }
}

/// The Transcript engine's names, shared by the cards, the Settings Map choices and the meeting
/// page's Transcribe again menu.
enum MeetingTranscriptEngineRowTitles {
  static func title(of choice: MeetingEngineChoice) -> String {
    switch choice {
    case .parakeet: String(localized: MeetingsCopy.engineParakeet)
    case .whisper: String(localized: MeetingsCopy.engineWhisper)
    }
  }
}
