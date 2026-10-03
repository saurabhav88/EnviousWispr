import EnviousWisprServices
import SwiftUI

/// Privacy controls and safe restart behavior in App Settings.
struct PrivacySettingsView: View {
  @Environment(SettingsManager.self) private var settings
  /// Optional so a view harness can render the page without the dictation pipeline; the app
  /// always supplies it. The same busy check the language relaunch uses.
  @Environment(LiveRecordingState.self) private var liveRecordingState: LiveRecordingState?
  @Environment(FileImportCoordinator.self) private var fileImportCoordinator: FileImportCoordinator?

  /// A relaunch now would lose work in flight (`AppRelauncher.workInFlight` says which).
  private var isBusy: Bool {
    AppRelauncher.workInFlight(
      dictationActive: liveRecordingState?.isDictationActive ?? false,
      fileImport: fileImportCoordinator)
  }

  /// Whether the stored crash switch differs from the mode Sentry started in this run. Sentry's
  /// mode is fixed at launch (`ObservabilityBootstrap.initialize`), so a change waits for a
  /// restart; switching back hides the notice at once. False before launch has run.
  static func needsRestart(stored: Bool, launched: Bool?) -> Bool {
    guard let launched else { return false }
    return stored != launched
  }

  /// "Restart now": refuses while work is in flight, otherwise hands the relaunch a LIVE busy
  /// check, which `AppRelauncher.relaunchWhenSafe` reads again before quitting. Returns whether it
  /// handed off. `relaunch` is the real helper in the app and a recorder in tests.
  @discardableResult
  static func restartNow(
    isBusy: @escaping @MainActor () -> Bool,
    relaunch: (@escaping @MainActor () -> Bool) -> Void
  ) -> Bool {
    guard !isBusy() else { return false }
    relaunch(isBusy)
    return true
  }

  var body: some View {
    @Bindable var settings = settings
    SettingsContentView {
      VStack(alignment: .leading, spacing: 10) {
        SettingsSectionHeading(title: "PRIVACY")
        BrandedSection {
          BrandedRow {
            SettingsRow(
              icon: "chart.bar", resolvedTitle: PrivacySettingsCopy.metricsLabel,
              resolvedShort: PrivacySettingsCopy.metricsShort,
              resolvedHelp: PrivacySettingsCopy.metricsHelp
            ) {
              Toggle("", isOn: $settings.shareUsageMetrics)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(PrivacySettingsCopy.metricsLabel)
            }
          }
          BrandedRow(showDivider: false) {
            SettingsRow(
              icon: "exclamationmark.triangle", resolvedTitle: PrivacySettingsCopy.crashLabel,
              resolvedShort: PrivacySettingsCopy.crashShort,
              resolvedHelp: PrivacySettingsCopy.crashHelp
            ) {
              Toggle("", isOn: $settings.sendCrashReports)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(PrivacySettingsCopy.crashLabel)
            }
            .rowStatus {
              if Self.needsRestart(
                stored: settings.sendCrashReports,
                launched: ObservabilityBootstrap.launchedCrashReports)
              {
                VStack(alignment: .leading, spacing: 8) {
                  Text(PrivacySettingsCopy.restartNotice)
                    .font(.stRowHelper)
                    .foregroundStyle(.stTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                  SettingsActionButton(
                    verbatimTitle: PrivacySettingsCopy.restartAction, isEnabled: !isBusy
                  ) {
                    Self.restartNow(isBusy: { isBusy }) {
                      AppRelauncher.relaunchWhenSafe(stillBusy: $0)
                    }
                  }
                }
                .padding(.top, 4)
              }
            }
          }
        }
        BrandedSection {
          BrandedRow(showDivider: false) {
            HStack(alignment: .top, spacing: 11) {
              SettingsRowIcon(systemName: "lock.shield")
              VStack(alignment: .leading, spacing: 6) {
                Text("What we collect").settingsRowLabel()
                Text(PrivacySettingsCopy.promise).settingsReadingCopy()
                Text(PrivacySettingsCopy.openSource).settingsReadingCopy()
                Link(destination: URL(string: PrivacySettingsCopy.learnMoreURL)!) {
                  Label(PrivacySettingsCopy.learnMoreLabel, systemImage: "arrow.up.right")
                    .font(.stRowHelper)
                }
                .foregroundStyle(.stAccent)
              }
            }
          }
        }
      }
    }
  }
}

/// The Privacy section's words (#3269), one owner so the view and its tests read the same
/// localized values. English is the catalog key, as elsewhere in Settings.
enum PrivacySettingsCopy {
  /// The help article that lists exactly what each switch sends.
  static let learnMoreURL = "https://enviouswispr.com/help/what-data-is-collected/"
  static var promise: String {
    String(
      localized:
        "We receive metadata only, never your audio, transcripts, polished text, prompts or surrounding document text. We never collect your history, snippets, dictionary words, API keys or screen text. Feedback text reaches us only when you press Send. Pressing Send also sends your message text through enviouswispr.com to TypeSafe to suggest a help section, even if you choose “Yes, that helped” and nothing reaches Sentry. Your optional reply email reaches us via Sentry only when you choose to send feedback. We do not store the TypeSafe help-suggestion message.",
      comment: "Permissions settings, Privacy: the section's privacy promise, above both switches.")
  }
  static var openSource: String {
    String(
      localized: "EnviousWispr is open source, so you can check exactly what we send.",
      comment: "Permissions settings, Privacy: line before the link to the data help article.")
  }
  static var learnMoreLabel: String {
    String(
      localized: "See details",
      comment: "Permissions settings, Privacy: link to the What Data Is Collected help article.")
  }
  static var metricsLabel: String {
    String(localized: "Share usage metrics", comment: "Permissions settings, Privacy: switch label.")
  }
  static var metricsShort: String {
    String(localized: "Help us catch broken updates.")
  }
  static var crashShort: String {
    String(localized: "Help us fix crashes and errors.")
  }
  static var metricsHelp: String {
    String(
      localized:
        "Anonymous usage, settings, performance, and error data to help us catch broken updates.",
      comment: "Permissions settings, Privacy: explains the usage metrics switch.")
  }
  static var crashLabel: String {
    String(localized: "Send crash reports", comment: "Permissions settings, Privacy: switch label.")
  }
  static var crashHelp: String {
    String(
      localized: "Stack traces and diagnostic details to help us fix crashes and errors.",
      comment: "Permissions settings, Privacy: explains the crash reports switch.")
  }
  static var restartNotice: String {
    String(
      localized: "Takes effect when EnviousWispr restarts",
      comment: "Permissions settings, Privacy: shown after the crash reports switch changes.")
  }
  static var restartAction: String {
    String(
      localized: "Restart now",
      comment: "Permissions settings, Privacy: button that quits and reopens the app.")
  }
}
