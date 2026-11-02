import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #4105 / #4320 (founder decisions 3, 5, 8): EnviousMeet > Models' TRANSCRIPT LANGUAGE section,
/// under the Transcript engine card: an Auto-detect switch and the Transcript language row,
/// whose Change opens the shared language window (`LanguagePickerContent.meetingTranscript`)
/// with the transcript engine's languages. A change applies to the next meeting. The notes under
/// the row say when the saved language is one the engine cannot write, and when Live Preview
/// uses another language; neither blocks a choice.
///
/// The heading registers no Settings Map place: the switch (`meetingTranscriptAutoDetect`) and
/// the row (`meetingTranscriptLanguage`) are the places, each with one control.
struct MeetingTranscriptLanguageSection: View {
  @Environment(MeetingLiveWordsRowModel.self) private var model
  /// #3973 C3: the language list and its unsupported note follow the transcript engine.
  @Environment(MeetingTranscriptEngineRowModel.self) private var engine
  @State private var showLanguages = false

  private var isAuto: Bool { Self.isAuto(model) }

  /// Whether the transcript language is Auto (switch on, Change off).
  static func isAuto(_ model: MeetingLiveWordsRowModel) -> Bool {
    if case .auto = model.transcriptLanguage { return true }
    return false
  }

  /// The switch's write: on is Auto; off locks to `LanguageLockOptions.defaultLockCode`: the saved
  /// lock if the engine can write it, else `systemLanguage` if it can, else English.
  static func setAuto(
    _ on: Bool, model: MeetingLiveWordsRowModel, engine: MeetingEngineChoice,
    systemLanguage: String
  ) {
    model.transcriptLanguage =
      on
      ? .auto
      : .locked(
        LanguageLockOptions.defaultLockCode(
          current: model.transcriptLanguage, candidate: systemLanguage,
          lockable: LanguageLockOptions.lockableCodes(for: engine.backendType)))
  }

  /// The transcript engine's coverage, the Languages value of its dictation Engine card.
  static func coverage(_ engine: MeetingEngineChoice) -> String {
    String(localized: EngineChoicePresentation.coverage(for: engine.backendType))
  }

  var body: some View {
    BrandedSection(header: MeetingsCopy.transcriptLanguageTitle) {
      BrandedRow {
        SettingsRow(
          map: .id(.meetingTranscriptAutoDetect), icon: "globe",
          runtimeShort: MeetingsCopy.transcriptAutoDetectShort(Self.coverage(engine.selectedEngine)),
          resolvedHelp: String(localized: MeetingsCopy.transcriptLanguageHelp)
        ) {
          Toggle(
            "",
            isOn: Binding(
              get: { isAuto },
              set: {
                Self.setAuto(
                  $0, model: model, engine: engine.selectedEngine,
                  systemLanguage: Locale.current.language.languageCode?.identifier ?? "en")
              })
          )
          .labelsHidden()
          .toggleStyle(BrandedToggleStyle())
          .fixedSize()
          .accessibilityLabel(Text(DictationSettingsCopy.Engine.autoDetectTitle))
          .settingsArrivalFocusControl()
        }
      }
      BrandedRow(showDivider: false) {
        SettingsRow(
          map: .id(.meetingTranscriptLanguage), icon: "text.bubble",
          help: MeetingsCopy.transcriptLanguageHelp
        ) {
          HStack(spacing: 10) {
            Text(languageName)
              .font(.stRowHelper)
              .foregroundStyle(.stTextSecondary)
            Button(SettingsItemCopy.Engine.lockedLanguageChange) { showLanguages = true }
              .controlSize(.small)
              .font(.stHelper)
              .disabled(isAuto)
              .accessibilityLabel(String(localized: MeetingsCopy.transcriptLanguageTitle))
              .settingsArrivalFocusControl()
          }
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
    .sheet(isPresented: $showLanguages) {
      LanguageLockSheet { query, dismiss in
        LanguagePickerContent.meetingTranscript(
          model: model, engine: engine.selectedEngine, query: query, dismiss: dismiss)
      }
    }
  }

  /// "Auto", or the saved language (shown even when the engine cannot write it; the note says so).
  private var languageName: String {
    guard case .locked(let code) = model.transcriptLanguage else {
      return String(localized: MeetingsCopy.transcriptLanguageAuto)
    }
    return LanguageCatalog.entry(for: code).displayName
  }
}
