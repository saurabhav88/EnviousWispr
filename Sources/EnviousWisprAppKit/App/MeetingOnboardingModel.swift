import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// One visit to EnviousMeet's setup: which screen shows, whether the consent box is ticked, and
/// what each permission answered (#4017 O2, R3). Owned by `WisprBootstrapper` for the app run,
/// so leaving the EnviousMeet page and coming back keeps the place; quitting starts over at
/// Welcome. Only `SettingsManager.meetingOnboardingComplete` persists.
@MainActor
@Observable
final class MeetingOnboardingModel {
  enum Screen: String, CaseIterable, Equatable {
    case welcome, legal, permissions, done
  }

  /// What one permission row shows. Call sound is "requested" when macOS was asked but its
  /// answer cannot be read (R7): never shown as allowed without a successful read.
  enum PermissionState: String, Equatable {
    case granted
    case requested
    case denied
    case skipped
    case notAsked
    case unavailable
    /// This Mac gives no way to ask ahead; macOS asks the first time a recording needs it.
    case askedAtFirstRecording
  }

  struct Dependencies {
    var microphoneStatus: @MainActor () -> AVAuthorizationStatus
    var requestMicrophone: @MainActor () async -> Void
    var callSoundStatus: @MainActor () -> SystemAudioPermission.Status
    /// Nil when no request could be made (the TCC functions are missing on this macOS).
    var requestCallSound: @MainActor () async -> SystemAudioPermission.Status?
    var calendarStatus: @MainActor () -> CalendarAccess.Status
    var requestCalendar: @MainActor () async -> CalendarAccess.Status
    var openCallSoundSettings: @MainActor () -> Void
    var openCalendarSettings: @MainActor () -> Void
    /// Whether this Mac can record the call sound at all (#4346: macOS 14.2+, the same floor as
    /// `CallMicrophoneWatcher.isSupported`). Below it, setup does not require call sound.
    var callSoundSupported: @MainActor () -> Bool
    var settings: SettingsManager
    var emit: @MainActor (MeetingSetupTelemetry) -> Void
    var now: @MainActor () -> Date = { Date() }
  }

  private(set) var screen: Screen = .welcome
  var consented = false
  private(set) var microphone: PermissionState = .notAsked
  private(set) var callSound: PermissionState = .notAsked
  private(set) var calendar: PermissionState = .notAsked
  /// A permission request is waiting on macOS; its button is disabled meanwhile.
  private(set) var asking = false
  /// Times the user set "Name meetings from my calendar" on the EnviousMeet page, so a late
  /// calendar answer never overrides that choice.
  @ObservationIgnored private var calendarNamesChoices = 0

  /// The page's "Name meetings from my calendar" switch was set by the user.
  func noteCalendarNamesChoice() { calendarNamesChoices += 1 }

  private let deps: Dependencies
  private var visitStart: Date?
  /// One `meeting.setup` row per visit (R8): set when the visit reaches a terminal.
  private var visitReported = false
  /// The furthest screen this visit reached, for `meeting.setup` (R8).
  private var furthest: Screen = .welcome

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  var isComplete: Bool { deps.settings.meetingOnboardingComplete }

  /// The page appeared: starts a visit and reads the current permission answers.
  func begin() {
    if visitStart == nil || visitReported {
      visitStart = deps.now()
      visitReported = false
      furthest = screen
    }
    refresh()
  }

  /// Reads what macOS says now. Called on appear and when the app becomes active again (the
  /// user may have changed a permission in System Settings). A skip the user chose stays a
  /// skip unless macOS now reports access.
  func refresh() {
    microphone = Self.microphoneState(deps.microphoneStatus(), current: microphone)
    switch deps.callSoundStatus() {
    case .granted: callSound = .granted
    case .denied: callSound = .denied
    case .unknown: break
    }
    switch deps.calendarStatus() {
    case .granted: calendar = .granted
    case .denied: calendar = calendar == .skipped ? .skipped : .denied
    case .unavailable: calendar = .unavailable
    case .notAsked: break
    }
  }

  func getStarted() { move(to: .legal) }

  private func move(to next: Screen) {
    screen = next
    let order = Screen.allCases
    if let a = order.firstIndex(of: next), let b = order.firstIndex(of: furthest), a > b {
      furthest = next
    }
  }

  func back() {
    switch screen {
    case .legal: screen = .welcome
    case .permissions: screen = .legal
    case .welcome, .done: break
    }
  }

  /// Accept moves on only with the consent box ticked (O4).
  func accept() {
    guard consented else { return }
    move(to: .permissions)
  }

  func allowMicrophone() async {
    guard !asking else { return }
    asking = true
    await deps.requestMicrophone()
    asking = false
    refresh()
  }

  /// A permission answer can arrive long after the press (the user may finish setup, or
  /// change the settings, while macOS asks). So a press saves the user's choice at once, and a
  /// late answer changes only what the row shows; settings an answer decides are written only
  /// while setup is still open (`finish` writes the rest).
  func allowCallSound() async {
    guard !asking else { return }
    asking = true
    // Allow is the choice to record the call sound, whatever macOS answers.
    deps.settings.meetingCaptureCallSound = true
    let answer = await deps.requestCallSound()
    asking = false
    guard let answer else {
      // Nothing was asked: the first recording with the call sound explains and asks.
      callSound = .askedAtFirstRecording
      return
    }
    switch answer {
    case .granted: callSound = .granted
    case .denied: callSound = .denied
    case .unknown: callSound = .requested
    }
    // macOS was asked here, so the first call-sound recording does not explain it again.
    deps.settings.meetingCallSoundExplained = true
  }

  func allowCalendar() async {
    guard !asking else { return }
    asking = true
    // A late grant still turns calendar names on, unless the user set the switch meanwhile.
    let choiceBefore = calendarNamesChoices
    let answer = await deps.requestCalendar()
    asking = false
    switch answer {
    case .granted:
      calendar = .granted
      if !isComplete || calendarNamesChoices == choiceBefore {
        deps.settings.meetingUseCalendarForNames = true
      }
    case .denied: calendar = .denied
    case .unavailable: calendar = .unavailable
    case .notAsked: calendar = .notAsked
    }
  }

  func skipCalendar() { if calendar != .granted, !asking { calendar = .skipped } }

  func openCallSoundSettings() { deps.openCallSoundSettings() }
  func openCalendarSettings() { deps.openCalendarSettings() }

  /// #4346 (founder 2026-11-02, reverses #4017 O5): setup needs the microphone and, where this
  /// Mac can record it, the call sound. Calendar never blocks.
  var callSoundRequired: Bool { deps.callSoundSupported() }

  /// The microphone is allowed; every other state blocks.
  var microphoneSatisfied: Bool { microphone == .granted }

  /// The call sound is allowed, asked with an answer that cannot be read, or cannot be asked
  /// ahead (macOS asks at the first recording); or this Mac cannot record it at all. These
  /// exceptions let setup continue; they do not mean recording permission is granted.
  var callSoundSatisfied: Bool {
    guard callSoundRequired else { return true }
    switch callSound {
    case .granted, .requested, .askedAtFirstRecording: return true
    case .denied, .skipped, .notAsked, .unavailable: return false
    }
  }

  /// The single gate for the Continue button and `continueToDone()`.
  var canContinue: Bool { microphoneSatisfied && callSoundSatisfied }

  /// Continue on the permissions screen: only once `canContinue` holds.
  func continueToDone() {
    guard canContinue else { return }
    move(to: .done)
  }

  /// macOS may still ask about the call sound at the first recording (#4346 §16.2): shown on the
  /// done screen independently of `unresolved`.
  var callSoundMayAskLater: Bool {
    callSoundRequired && (callSound == .requested || callSound == .askedAtFirstRecording)
  }

  /// The optional permissions that are not allowed, for the done screen (R7). Only Calendar can
  /// be unresolved once `canContinue` let the user through.
  var unresolved: [String] {
    calendar == .granted
      ? [] : [String(localized: "Calendar", comment: "EnviousMeet setup: a permission name.")]
  }

  /// "Open EnviousMeet": the lock opens and the page shows the settings.
  func finish() {
    // Calendar names follow the calendar answer at the end, so access allowed later in System
    // Settings still names meetings.
    if calendar == .granted { deps.settings.meetingUseCalendarForNames = true }
    report(outcome: .finished)
    deps.settings.meetingOnboardingComplete = true
    screen = .welcome
    consented = false
  }

  /// The page went away before setup finished (another sidebar page, or the window closed).
  func left() {
    guard !isComplete else { return }
    report(outcome: .left)
  }

  private func report(outcome: MeetingSetupTelemetry.Outcome) {
    guard !visitReported, let visitStart else { return }
    visitReported = true
    deps.emit(
      MeetingSetupTelemetry(
        outcome: outcome,
        screen: MeetingSetupTelemetry.Screen(rawValue: furthest.rawValue) ?? .welcome,
        seconds: max(0, deps.now().timeIntervalSince(visitStart)),
        microphone: Self.telemetryAnswer(microphone), callSound: Self.telemetryAnswer(callSound),
        calendar: Self.telemetryAnswer(calendar)))
  }

  private static func microphoneState(_ status: AVAuthorizationStatus, current: PermissionState)
    -> PermissionState
  {
    switch status {
    case .authorized: return .granted
    case .denied: return .denied
    case .restricted: return .unavailable
    case .notDetermined: return current == .skipped ? .skipped : .notAsked
    @unknown default: return .unavailable
    }
  }

  private static func telemetryAnswer(_ state: PermissionState) -> MeetingSetupTelemetry.Answer {
    switch state {
    case .granted: return .granted
    case .requested: return .requestedUnknown
    case .denied: return .denied
    case .skipped: return .skipped
    case .notAsked, .unavailable, .askedAtFirstRecording: return .unknown
    }
  }
}
