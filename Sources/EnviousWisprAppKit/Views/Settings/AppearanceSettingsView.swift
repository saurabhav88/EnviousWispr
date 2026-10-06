import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// App appearance and interface language. Both theme surfaces bind the same preference.
struct AppearanceSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  /// Optional so a view harness can render the page without the dictation pipeline; the app
  /// always supplies it.
  @Environment(LiveRecordingState.self) private var liveRecordingState: LiveRecordingState?
  @Environment(FileImportCoordinator.self) private var fileImportCoordinator: FileImportCoordinator?
  /// "" is "System default".
  @State private var language = AppLanguagePreference.live.choice ?? ""
  /// The language this process launched with; macOS fixes it at launch.
  private static let launchLanguage = Bundle.main.preferredLocalizations.first ?? "en"
  /// A relaunch now would lose work in flight (`AppRelauncher.workInFlight` says which).
  private var isBusy: Bool {
    AppRelauncher.workInFlight(
      dictationActive: liveRecordingState?.isDictationActive ?? false,
      fileImport: fileImportCoordinator)
  }

  /// Whether the picker's selection resolves to a different language than the one on screen.
  /// Computed from the selection itself (not the saved value, which `onChange` writes after this
  /// view updates), and the selection starts from the saved value, so the offer also survives
  /// leaving and reopening this page.
  private var needsRelaunch: Bool {
    AppLanguagePreference.live.language(
      forChoice: language.isEmpty ? nil : language,
      systemPreferences: AppLanguagePreference.systemPreferences) != Self.launchLanguage
  }

  var body: some View {
    @Bindable var settings = settings
    SettingsContentView {
      VStack(alignment: .leading, spacing: 10) {
        SettingsSectionHeading(map: .id(.sectionAppearance))
        BrandedSection {
          BrandedRow {
            SettingsRow(
              map: .id(.theme),
              icon: "circle.lefthalf.filled",
              short: "Choose how EnviousWispr looks.",
              help: "Choose System to follow your Mac, or choose Light or Dark."
            ) {
              BrandedSegmentedPicker(
                options: ThemeChoicePresentation.choices.map {
                  (String(localized: $0.label), nil, $0.value)
                }, selection: $settings.appearancePreference
              )
              .fixedSize()
              // A group, so each option keeps its own name for VoiceOver; a label on the
              // picker itself replaced every option's name with this one.
              .accessibilityElement(children: .contain)
              .accessibilityLabel(Text(SettingsItemCopy.AppSettings.theme))
            }
          }
          // #3142 Phase 5B: macOS applies this app-only language at launch. The
          // saved choice initializes the picker on every return to this tab.
          BrandedRow {
            SettingsRow(
              map: .id(.appLanguage),
              icon: "globe",
              short: "The language of the app interface.",
              help: "This changes only EnviousWispr. The new language applies after relaunch. System default follows your Mac."
            ) {
              Picker(SettingsItemCopy.AppSettings.language, selection: $language) {
                Text(SettingsItemCopy.AppSettings.systemDefault).tag("")
                ForEach(AppLanguagePreference.live.languages, id: \.self) { code in
                  Text(verbatim: AppLanguagePreference.name(of: code)).tag(code)
                }
              }
              .labelsHidden()
              .accessibilityLabel(Text(SettingsItemCopy.AppSettings.language))
              .tint(.stAccent)
              .controlSize(.large)
              .fixedSize()
              .onChange(of: language) { _, code in
                AppLanguagePreference.live.choose(code.isEmpty ? nil : code)
              }
            }
            .rowStatus {
              if needsRelaunch {
                VStack(alignment: .leading, spacing: 8) {
                  Text("EnviousWispr uses the new language after it relaunches.")
                    .font(.stRowHelper)
                    .foregroundStyle(.stTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                  SettingsActionButton(title: SettingsItemCopy.AppSettings.relaunch, isEnabled: !isBusy) {
                    guard !isBusy else { return }
                    AppRelauncher.relaunchWhenSafe { isBusy }
                  }
                  .settingsMapRegistration(.appLanguageRelaunch)
                }
              }
            }
          }
          // #2480: the menu bar icon always stays, so hiding the Dock icon
          // cannot leave the app unreachable.
          BrandedRow {
            SettingsRow(
              map: .id(.showInDock),
              icon: "dock.rectangle",
              short: "Keep EnviousWispr in your Dock.",
              help: "When off, the Dock icon appears only while an EnviousWispr window is open. The menu bar icon always stays."
            ) {
              Toggle("", isOn: $settings.showInDock)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(Text(SettingsItemCopy.AppSettings.showInDock))
            }
          }
          // #3441: the gold wave on the menu bar icon while an update waits. Off keeps the
          // icon plain; the update still shows in the menu bar menu and What's New.
          BrandedRow(showDivider: false) {
            SettingsRow(
              map: .id(.updateAlertInMenuBar),
              icon: "menubar.rectangle",
              short: "Show gold lips when an update is ready.",
              help: "When off, the menu bar icon stays plain while an update waits. You can still install it from the menu bar menu or What's New."
            ) {
              Toggle("", isOn: $settings.showMenuBarUpdateAlert)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(Text(SettingsItemCopy.AppSettings.updateAlert))
            }
          }
        }
      }
    }
  }
}
