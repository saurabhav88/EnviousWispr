import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #4105: EnviousMeet > Models' Live words row (on General until #3973 PR B). The engine and language menus, the row's
/// state and its Download, all from the app-owned `MeetingLiveWordsRowModel`; this view keeps no
/// state of its own, so closing Settings never drops a download.
///
/// Download is an action of this row, not its own search place (#4105 plan R1.10): a search for
/// it arrives here, where the row says whether a download is needed.
struct MeetingLiveWordsRow: View {
  @Environment(MeetingLiveWordsRowModel.self) private var model

  var body: some View {
    SettingsRow(
      map: .id(.meetingLiveWords), icon: "captions.bubble", help: MeetingsCopy.liveWordsHelp
    ) {
      HStack(spacing: 8) {
        enginePicker
        languagePicker
      }
    }
    .rowStatus { statusLine }
    .rowSupplementaryControl(belowWidth: 560) { action }
    // Runs on appear and again whenever the stored choice changes, so a choice a meeting Start
    // saves while Settings stays open shows here (appear is a no-op save once a choice exists).
    .task(id: model.choiceGeneration) { await model.appear() }
  }

  private var enginePicker: some View {
    Picker(
      String(localized: MeetingsCopy.liveWordsTitle),
      selection: Binding(
        get: { model.selectedEngine },
        set: { engine in
          guard let engine else { return }
          Task { await model.selectEngine(engine) }
        })
    ) {
      if model.selectedEngine == nil {
        Text(MeetingsCopy.chooseEngine).tag(LivePreviewEngineChoice?.none)
      }
      ForEach(Self.engineItems(appleAvailable: model.isAppleAvailable), id: \.choice) { item in
        Text(item.label).tag(LivePreviewEngineChoice?.some(item.choice)).disabled(!item.isEnabled)
      }
    }
    .labelsHidden()
    .settingsArrivalFocusControl()
    .fixedSize()
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

  struct EngineItem: Equatable {
    let choice: LivePreviewEngineChoice
    let label: String
    let isEnabled: Bool
  }

  /// The engine menu, in order, as the menu draws it: Apple is listed where its meeting speech
  /// cannot run, so the user sees why it is missing, and greyed so it cannot be picked (the model
  /// refuses it too).
  static func engineItems(appleAvailable: Bool) -> [EngineItem] {
    LivePreviewEngineChoice.allCases.map { choice in
      switch choice {
      case .apple:
        EngineItem(
          choice: .apple,
          label: appleAvailable
            ? LivePreviewEngineCopy.appleTitle : String(localized: MeetingsCopy.appleNotOnThisMac),
          isEnabled: appleAvailable)
      case .universal:
        EngineItem(
          choice: .universal, label: LivePreviewEngineCopy.universalTitle, isEnabled: true)
      }
    }
  }

  @ViewBuilder private var statusLine: some View {
    switch model.status {
    case .loading:
      status(String(localized: MeetingsCopy.liveWordsChecking))
    case .notSetUp(let suggestion?):
      status(
        MeetingsCopy.liveWordsSuggested(
          model.languageName(engine: suggestion.engine, code: suggestion.language)))
    case .notSetUp(nil):
      status(String(localized: MeetingsCopy.liveWordsNotSetUp))
    case .ready:
      status(EngineSummaryCopy.ready)
    case .notDownloaded(let engine, let language):
      status(
        MeetingsCopy.liveWordsNotDownloaded(model.languageName(engine: engine, code: language)))
    case .downloading(let engine, let language, let fraction):
      VStack(alignment: .leading, spacing: 4) {
        status(
          MeetingsCopy.liveWordsDownloading(model.languageName(engine: engine, code: language)))
        // Apple reports no progress before it finishes: an indeterminate bar, never a percentage.
        if let fraction {
          ProgressView(value: fraction).frame(maxWidth: 220)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    case .failed:
      status(String(localized: MeetingsCopy.liveWordsFailed))
    case .appleUnavailable:
      status(String(localized: MeetingsCopy.liveWordsAppleUnavailable))
    }
  }

  private func status(_ text: String) -> some View {
    Text(text)
      .font(.stRowHelper)
      .foregroundStyle(.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Download, Try Again or (Universal only) Cancel. While a meeting is active the row says when
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
      status(refusal)
    } else if model.universalDownloadUnavailable, model.selectedEngine != .apple {
      // The refusal, with Download kept beside it: a press after the cause is fixed retries.
      HStack(spacing: 8) {
        status(String(localized: MeetingsCopy.liveWordsDownloadUnavailable))
        Button(String(localized: title)) { model.download() }
      }
    } else {
      Button(String(localized: title)) { model.download() }
    }
  }
}

/// #4105: EnviousMeet > Models' Transcript language row (on General until #3973 PR B). Auto plus the final engine's
/// languages; a change applies to the next meeting. The note under it says when live words use
/// another language, and never blocks either choice.
struct MeetingTranscriptLanguageRow: View {
  @Environment(MeetingLiveWordsRowModel.self) private var model

  var body: some View {
    SettingsRow(
      map: .id(.meetingTranscriptLanguage), icon: "text.bubble",
      help: MeetingsCopy.transcriptLanguageHelp
    ) {
      // The menu's key: "" is Auto, otherwise the locked language code.
      Picker(
        String(localized: MeetingsCopy.transcriptLanguageTitle),
        selection: Binding(
          get: {
            if case .locked(let code) = model.transcriptLanguage { return code }
            return ""
          },
          set: { model.transcriptLanguage = $0.isEmpty ? .auto : .locked($0) })
      ) {
        Text(MeetingsCopy.transcriptLanguageAuto).tag("")
        ForEach(model.transcriptLanguageOptions, id: \.lockCode) { entry in
          Text(entry.displayName).tag(entry.lockCode)
        }
      }
      .labelsHidden()
      .settingsArrivalFocusControl()
      .fixedSize()
    }
    .rowStatus {
      if model.languagesDiffer {
        Text(MeetingsCopy.languagesDiffer)
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
