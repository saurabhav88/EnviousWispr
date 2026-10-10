import EnviousWisprServices
import SwiftUI

/// Privacy controls and safe restart behavior in App Settings.
struct PrivacySettingsView: View {
  @Environment(SettingsManager.self) private var settings
  /// Optional so a view harness can render the page without the dictation pipeline; the app
  /// always supplies it. The same busy check the language relaunch uses.
  @Environment(LiveRecordingState.self) private var liveRecordingState: LiveRecordingState?
  @Environment(FileImportCoordinator.self) private var fileImportCoordinator: FileImportCoordinator?
  /// The crash-report mode this run started in. The app passes nothing and reads
  /// `ObservabilityBootstrap`; a render test passes a value (#3482).
  private let launchedCrashReports: @MainActor () -> Bool?

  init(launchedCrashReports: @escaping @MainActor () -> Bool? = {
    ObservabilityBootstrap.launchedCrashReports
  }) {
    self.launchedCrashReports = launchedCrashReports
  }

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
        SettingsSectionHeading(map: .id(.sectionPrivacy))
        BrandedSection {
          BrandedRow {
            SettingsRow(
              map: .id(.shareUsageMetrics),
              icon: "chart.bar",
              resolvedHelp: PrivacySettingsCopy.metricsHelp
            ) {
              Toggle("", isOn: $settings.shareUsageMetrics)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(PrivacySettingsCopy.metricsLabel)
            }
          }
          BrandedRow {
            SettingsRow(
              map: .id(.sendCrashReports),
              icon: "exclamationmark.triangle",
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
                launched: launchedCrashReports())
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
                  .settingsMapRegistration(.sendCrashReportsRestart)
                }
                .padding(.top, 4)
              }
            }
          }
          // The mockup's third row of the same card (founder, 2026-10-03). Main's full
          // promise and open-source line stay word for word behind "?".
          BrandedRow(showDivider: false) {
            SettingsRow(
              map: .id(.whatWeCollect),
              icon: "lock.shield",
              resolvedHelp: PrivacySettingsCopy.promise + " " + PrivacySettingsCopy.openSource
            ) {
              Link(destination: URL(string: PrivacySettingsCopy.learnMoreURL)!) {
                HStack(spacing: 6) {
                  Text(PrivacySettingsCopy.seeDetailsLabel)
                  Image(systemName: "arrow.up.right")
                }
                .font(.stHelper.weight(.semibold))
                .foregroundStyle(.stTextPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                  RoundedRectangle(cornerRadius: 8).strokeBorder(Color.stInputBorder, lineWidth: 1)
                    .allowsHitTesting(false))
                .settingsHoverRow(cornerRadius: 8)
              }
              .buttonStyle(.plain)
              .fixedSize()
              .accessibilityLabel(PrivacySettingsCopy.learnMoreLabel)
              .settingsArrivalFocusControl()
              .settingsMapRegistration(.whatWeCollectSeeDetails)
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
        "We value your privacy. We never collect your audio, dictated or transcribed text, history, snippets, dictionary words, API keys, or any text on your screen. The only words that reach us are what you type into the feedback form, once you click Send.",
      comment: "Permissions settings, Privacy: the section's privacy promise, above both switches.")
  }
  static var openSource: String {
    String(
      localized: "EnviousWispr is open source, so you can check exactly what we send.",
      comment: "Permissions settings, Privacy: line before the link to the data help article.")
  }
  static let collectTitleResource = LocalizedStringResource("What we collect", comment: "Permissions settings, Privacy: row title.")
  /// Mockup wording for the row's short line (founder, 2026-10-03).
  static let collectShortResource = LocalizedStringResource("Never your audio, text, history, snippets, dictionary or API keys. Only what you type into the feedback form.",
      comment: "Permissions settings, Privacy: short line under What we collect.")
  static let seeDetailsLabelResource = LocalizedStringResource("See details",
      comment: "Permissions settings, Privacy: button that opens the What Data Is Collected help article.")
  static var seeDetailsLabel: String { String(localized: seeDetailsLabelResource) }
  static var learnMoreLabel: String {
    String(
      localized: "See what we collect",
      comment: "Permissions settings, Privacy: link to the What Data Is Collected help article.")
  }
  static let metricsLabelResource = LocalizedStringResource("Share usage metrics", comment: "Permissions settings, Privacy: switch label.")
  static var metricsLabel: String { String(localized: metricsLabelResource) }
  static let metricsShortResource = LocalizedStringResource("Help us catch broken updates.")
  static let crashShortResource = LocalizedStringResource("Help us fix crashes and errors.")
  static var metricsHelp: String {
    String(
      localized:
        "Anonymous usage, settings, performance, and error data to help us catch broken updates.",
      comment: "Permissions settings, Privacy: explains the usage metrics switch.")
  }
  static let crashLabelResource = LocalizedStringResource("Send crash reports", comment: "Permissions settings, Privacy: switch label.")
  static var crashLabel: String { String(localized: crashLabelResource) }
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
  static let restartActionResource = LocalizedStringResource("Restart now",
      comment: "Permissions settings, Privacy: button that quits and reopens the app.")
  static var restartAction: String { String(localized: restartActionResource) }
}
