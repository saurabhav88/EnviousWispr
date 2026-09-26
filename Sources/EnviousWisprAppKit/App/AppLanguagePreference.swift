import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// #3142 Phase 5B: the language of EnviousWispr's own interface, chosen in Settings >
/// Appearance without changing macOS.
///
/// The choice is the app's per-app `AppleLanguages` override, in its bundle's defaults domain: the
/// same value macOS System Settings > Language & Region sets for an app, so this panel and that one
/// read and write one owner. Launched with `-AppleLanguages (de)`, `Bundle.main` and
/// `Locale.current` both follow it (`interface-localization.md` FACT:
/// app-language-drives-locale-current); the saved override, permission prompts, the Services title
/// and number and date formatting will be checked in the #3142 Phase 5 live checks. "System default"
/// removes the override, whichever panel set it, and the app follows the Mac's language list again.
/// macOS applies it at launch, so a change takes effect after a relaunch.
struct AppLanguagePreference {
  static let key = "AppleLanguages"

  let defaults: UserDefaults
  /// The defaults domain the choice lives in: the bundle identifier (a test passes its suite).
  let domain: String
  /// `Bundle.localizations` of the app: the list can only offer what the bundle ships.
  let shipped: [String]

  static var live: AppLanguagePreference {
    AppLanguagePreference(
      defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "",
      shipped: Bundle.main.localizations)
  }

  /// The languages to offer, English first, never `Base`.
  var languages: [String] {
    shipped.filter { $0 != "Base" }.sorted { ($0 == "en" ? 0 : 1, $0) < ($1 == "en" ? 0 : 1, $1) }
  }

  /// The effective per-app override (set here or in System Settings), or nil for "System
  /// default". Read from the app's domain only: `UserDefaults.standard` would also return the
  /// Mac's global list, which is not an override.
  var choice: String? {
    let list = defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
    guard let first = list?.first else { return nil }
    if languages.contains(first) { return first }
    // System Settings can store a regional code ("de-DE"); macOS then shows the shipped "de".
    let base = Locale(identifier: first).language.languageCode?.identifier
    return base.flatMap { languages.contains($0) ? $0 : nil }
  }

  /// Sets the app's language; nil ("System default") removes the override. A language the bundle
  /// does not ship changes nothing.
  func choose(_ code: String?) {
    guard let code else {
      defaults.removeObject(forKey: Self.key)
      return
    }
    guard languages.contains(code) else { return }
    defaults.set([code], forKey: Self.key)
  }

  /// Removes a saved override the bundle does not ship (an older version's language, or one
  /// written by hand). `choice` reads it as "System default", so it must not stay in effect where
  /// the picker cannot show or clear it. Run once at launch by `WisprBootstrapper`.
  func forgetUnshippedOverride() {
    guard defaults.persistentDomain(forName: domain)?[Self.key] != nil, choice == nil else { return }
    defaults.removeObject(forKey: Self.key)
  }

  /// The language the app would show if launched now: the override, else the first of the Mac's
  /// preferred languages (`systemPreferences`, the global `AppleLanguages`) that the bundle ships,
  /// else English.
  func languageAtNextLaunch(systemPreferences: [String]) -> String {
    language(forChoice: choice, systemPreferences: systemPreferences)
  }

  /// The language a given choice resolves to (nil is "System default"), without reading or
  /// writing the saved override; the picker asks this of its own selection.
  func language(forChoice code: String?, systemPreferences: [String]) -> String {
    if let code, languages.contains(code) { return code }
    return Bundle.preferredLocalizations(from: languages, forPreferences: systemPreferences).first ?? "en"
  }

  /// The Mac's own preferred languages, read from the global domain (never the app's override).
  static var systemPreferences: [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? []
  }

  /// A language named in its own language ("Deutsch", "English"), never translated.
  static func name(of code: String) -> String {
    Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
  }
}

/// Quits EnviousWispr and opens it again once it has gone, so a new interface language applies.
enum AppRelauncher {
  /// Whether quitting now would lose work in flight that SwiftUI can observe: a dictation
  /// (recording to polishing), a file transcription (reading the chosen file, transcribing or
  /// polishing, or the engine still held after Stop), or a speaker-analysis retry that has not
  /// written its result yet. Model downloads resume on their own after a relaunch. The clipboard
  /// restore just after a dictation is not observable, so `relaunchWhenSafe` waits it out at the
  /// click instead of it disabling the button (which could then stay disabled). The ONE owner
  /// for the language relaunch.
  @MainActor static func workInFlight(
    dictationActive: Bool, fileImport: FileImportCoordinator?
  ) -> Bool {
    if dictationActive { return true }
    guard let fileImport else { return false }
    if case .reading = fileImport.state { return true }  // decoding the chosen file
    return fileImport.isRunning || fileImport.isEngineHeld || fileImport.speakerStepState == .inProgress
  }

  /// A shell waits for this process to exit (up to 5 minutes; quitting runs
  /// `applicationWillTerminate` cleanup first) and only then opens the same bundle, so `open` can
  /// never activate the old copy; `-n` makes it launch this bundle even while another copy with
  /// the same bundle identifier runs. If the process never exits, the shell opens nothing and the
  /// running app stays; the wait is bounded so a refused quit never leaves a shell that would
  /// reopen the app whenever the user later quits it. Quit cleanup takes seconds, so an exit that
  /// lands just after the last check is not a practical case. Terminate is requested only once the
  /// shell is running. The case left without an app is `open` itself failing after the quit; the
  /// user then opens it by hand.
  /// Whether a recovered recording is being replayed (`RecoveryCoordinator.isRecovering`) or a
  /// recording is starting but not yet active (`EngineCoordinator.isMintingAnySession`, the
  /// window recovery also treats as dictation). A quit then abandons the replay, which can lose the
  /// only saved audio, or the recording the user just started, silently. Not observable, so read
  /// at the click like the clipboard restore. Wired once by `WisprBootstrapper`.
  @MainActor static var backgroundWorkInFlight: @MainActor () -> Bool = { false }

  /// Relaunches once the clipboard restore that follows a dictation has finished
  /// (`ClipboardCleanup.hasPending`, the window the update installer also refuses; about 200 ms),
  /// waiting up to 2 seconds. Does nothing if `stillBusy` turns true, `backgroundWorkInFlight` is
  /// true, or the restore never settles.
  @MainActor static func relaunchWhenSafe(stillBusy: @escaping @MainActor () -> Bool) {
    Task { @MainActor in
      for _ in 0..<40 where ClipboardCleanup.hasPending {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard !ClipboardCleanup.hasPending, !backgroundWorkInFlight(), !stillBusy() else { return }
      relaunch()
    }
  }

  @MainActor static func relaunch() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // The bundle path arrives as $0, never interpolated into the script.
    process.arguments = [
      "-c",
      "for _ in $(seq 1 1500); do kill -0 \(pid) 2>/dev/null || exec /usr/bin/open -n \"$0\"; sleep 0.2; done",
      Bundle.main.bundleURL.path,
    ]
    do {
      try process.run()
    } catch {
      Task {
        await AppLogger.shared.log(
          "[AppLanguage] relaunch helper did not start: \(error.localizedDescription)", level: .info,
          category: "AppLanguage")
      }
      return
    }
    Task {
      await AppLogger.shared.log(
        "[AppLanguage] relaunching for a new interface language", level: .info,
        category: "AppLanguage")
    }
    NSApp.terminate(nil)
  }
}
