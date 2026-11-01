import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #4105: EnviousMeet > Models' Transcript language row (on General until #3973 PR B). Auto plus the final engine's
/// languages; a change applies to the next meeting. The note under it says when live words use
/// another language, and never blocks either choice.
struct MeetingTranscriptLanguageRow: View {
  @Environment(MeetingLiveWordsRowModel.self) private var model
  /// #3973 C3: the language list and its unsupported note follow the transcript engine.
  @Environment(MeetingTranscriptEngineRowModel.self) private var engine

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
        ForEach(engine.transcriptLanguageOptions, id: \.lockCode) { entry in
          Text(entry.displayName).tag(entry.lockCode)
        }
        // A saved language the engine cannot transcribe stays shown, named by the note below.
        if let code = engine.unsupportedTranscriptLanguage {
          Text(LanguageCatalog.entry(for: code).displayName).tag(code)
        }
      }
      .labelsHidden()
      .settingsArrivalFocusControl()
      .fixedSize()
    }
    .rowStatus {
      VStack(alignment: .leading, spacing: 4) {
        if let code = engine.unsupportedTranscriptLanguage {
          Text(
            MeetingsCopy.transcriptLanguageUnsupported(
              language: LanguageCatalog.entry(for: code).displayName,
              engine: engine.selectedEngine.backendType.displayName)
          )
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if model.languagesDiffer {
          Text(MeetingsCopy.languagesDiffer)
            .font(.stRowHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
