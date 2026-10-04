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
        SettingsSectionHeading(title: "APPEARANCE")
        BrandedSection {
          BrandedRow {
            SettingsRow(
              icon: "circle.lefthalf.filled", title: "Theme",
              short: "Choose how EnviousWispr looks.",
              help: "Choose System to follow your Mac, or choose Light or Dark."
            ) {
              BrandedSegmentedPicker(
                options: [
                  (String(localized: "System"), nil, AppearancePreference.system),
                  (String(localized: "Light"), nil, AppearancePreference.light),
                  (String(localized: "Dark"), nil, AppearancePreference.dark),
                ], selection: $settings.appearancePreference
              )
              .fixedSize()
              // A group, so each option keeps its own name for VoiceOver; a label on the
              // picker itself replaced every option's name with this one.
              .accessibilityElement(children: .contain)
              .accessibilityLabel("Theme")
            }
          }
          // #3142 Phase 5B: macOS applies this app-only language at launch. The
          // saved choice initializes the picker on every return to this tab.
          BrandedRow {
            SettingsRow(
              icon: "globe", title: "Language",
              short: "The language of the app interface.",
              help: "This changes only EnviousWispr. The new language applies after relaunch. System default follows your Mac."
            ) {
              Picker("Language", selection: $language) {
                Text("System default").tag("")
                ForEach(AppLanguagePreference.live.languages, id: \.self) { code in
                  Text(verbatim: AppLanguagePreference.name(of: code)).tag(code)
                }
              }
              .labelsHidden()
              .accessibilityLabel("Language")
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
                  SettingsActionButton(title: "Relaunch to apply", isEnabled: !isBusy) {
                    guard !isBusy else { return }
                    AppRelauncher.relaunchWhenSafe { isBusy }
                  }
                }
              }
            }
          }
          // #2480: the menu bar icon always stays, so hiding the Dock icon
          // cannot leave the app unreachable.
          BrandedRow(showDivider: false) {
            SettingsRow(
              icon: "dock.rectangle", title: "Show app in Dock",
              short: "Keep EnviousWispr in your Dock.",
              help: "When off, the Dock icon appears only while an EnviousWispr window is open. The menu bar icon always stays."
            ) {
              Toggle("", isOn: $settings.showInDock)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel("Show app in Dock")
            }
          }
        }
      }
    }
  }
}
