import EnviousWisprServices
import SwiftUI

/// Microphone and Accessibility permission status, and the two privacy switches (#3269).
struct PermissionsSettingsView: View {
  @Environment(PermissionsService.self) private var permissions
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
      BrandedSection(header: "Microphone") {
        BrandedRow(showDivider: false) {
          BrandedStatusRow(
            isGranted: permissions.hasMicrophonePermission,
            grantedText: LocalizedStringResource(
              "Microphone access granted", comment: "Permissions settings: status when granted."),
            deniedText: LocalizedStringResource(
              "Microphone access denied", comment: "Permissions settings: status when denied."),
            actionLabel: LocalizedStringResource(
              "Request Access",
              comment: "Permissions settings: button that asks macOS for microphone access."),
            action: {
              Task {
                // #2549: `requestMicrophoneAccess()` is a guaranteed no-op once
                // already denied — Apple never re-shows the system dialog after
                // an explicit deny. This shared method sends the user to System
                // Settings instead when that is the case.
                await permissions.requestMicrophoneAccessOrOpenSettings()
              }
            }
          )
        }
      }

      BrandedSection(header: "Accessibility") {
        BrandedRow(showDivider: false) {
          BrandedStatusRow(
            isGranted: permissions.hasAccessibilityPermission,
            grantedText: LocalizedStringResource(
              "Accessibility access granted", comment: "Permissions settings: status when granted."),
            deniedText: LocalizedStringResource(
              "Accessibility access required for paste",
              comment:
                "Permissions settings: status when missing; pasting text needs Accessibility access."
            ),
            helperText: "After rebuilding the app you may need to re-grant this permission.",
            actionLabel: LocalizedStringResource(
              "Open System Settings",
              comment: "Permissions settings: button that opens macOS System Settings."),
            action: {
              _ = permissions.requestAccessibilityAccess()
            }
          )
        }
      }

      BrandedSection(header: "Privacy") {
        // The promise is stated once for the section, so each switch says only what it sends.
        BrandedRow {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "lock.shield")
            VStack(alignment: .leading, spacing: 6) {
              Text(PrivacySettingsCopy.promise)
                .settingsReadingCopy()
              Text(PrivacySettingsCopy.openSource)
                .settingsReadingCopy()
              Link(destination: URL(string: PrivacySettingsCopy.learnMoreURL)!) {
                HStack(spacing: 4) {
                  Text(PrivacySettingsCopy.learnMoreLabel)
                  Image(systemName: "arrow.up.right")
                }
                .font(.stHelper)
              }
              .foregroundStyle(.stAccent)
            }
          }
        }
        BrandedRow {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "chart.bar")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.shareUsageMetrics) {
                Text(PrivacySettingsCopy.metricsLabel).settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(PrivacySettingsCopy.metricsHelp)
                .settingsReadingCopy()
            }
          }
        }
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.sendCrashReports) {
                Text(PrivacySettingsCopy.crashLabel).settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(PrivacySettingsCopy.crashHelp)
                .settingsReadingCopy()
              if Self.needsRestart(
                stored: settings.sendCrashReports,
                launched: ObservabilityBootstrap.launchedCrashReports)
              {
                HStack(spacing: 12) {
                  Text(PrivacySettingsCopy.restartNotice)
                    .font(.stHelper)
                    .foregroundStyle(.stTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                  Button {
                    Self.restartNow(isBusy: { isBusy }) {
                      AppRelauncher.relaunchWhenSafe(stillBusy: $0)
                    }
                  } label: {
                    Text(PrivacySettingsCopy.restartAction)
                  }
                  .disabled(isBusy)
                }
                .padding(.top, 4)
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
        "We value your privacy. We never collect your audio, dictated or transcribed text, history, snippets, dictionary words, API keys, or any text on your screen. The only words that reach us are feedback you choose to send.",
      comment: "Permissions settings, Privacy: the section's privacy promise, above both switches.")
  }
  static var openSource: String {
    String(
      localized: "EnviousWispr is open source, so you can check exactly what we send.",
      comment: "Permissions settings, Privacy: line before the link to the data help article.")
  }
  static var learnMoreLabel: String {
    String(
      localized: "See what we collect",
      comment: "Permissions settings, Privacy: link to the What Data Is Collected help article.")
  }
  static var metricsLabel: String {
    String(localized: "Share usage metrics", comment: "Permissions settings, Privacy: switch label.")
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
