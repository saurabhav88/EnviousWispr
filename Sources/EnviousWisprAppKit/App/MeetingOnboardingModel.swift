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
  }

  struct Dependencies {
    var microphoneStatus: @MainActor () -> AVAuthorizationStatus
    var requestMicrophone: @MainActor () async -> Void
    var callSoundStatus: @MainActor () -> SystemAudioPermission.Status
    var requestCallSound: @MainActor () async -> SystemAudioPermission.Status
    var calendarStatus: @MainActor () -> CalendarAccess.Status
    var requestCalendar: @MainActor () async -> CalendarAccess.Status
    var openCallSoundSettings: @MainActor () -> Void
    var openCalendarSettings: @MainActor () -> Void
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

  private let deps: Dependencies
  private var visitStart: Date?
  /// One `meeting.setup` row per visit (R8): set when the visit reaches a terminal.
  private var visitReported = false

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  var isComplete: Bool { deps.settings.meetingOnboardingComplete }

  /// The page appeared: starts a visit and reads the current permission answers.
  func begin() {
    if visitStart == nil || visitReported {
      visitStart = deps.now()
      visitReported = false
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

  func getStarted() { screen = .legal }

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
    screen = .permissions
  }

  func allowMicrophone() async {
    guard !asking else { return }
    asking = true
    await deps.requestMicrophone()
    asking = false
    refresh()
  }

  func allowCallSound() async {
    guard !asking else { return }
    asking = true
    let answer = await deps.requestCallSound()
    asking = false
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
    let answer = await deps.requestCalendar()
    asking = false
    switch answer {
    case .granted:
      calendar = .granted
      deps.settings.meetingUseCalendarForNames = true
    case .denied: calendar = .denied
    case .unavailable: calendar = .unavailable
    case .notAsked: calendar = .notAsked
    }
  }

  func skipCallSound() { if callSound != .granted { callSound = .skipped } }
  func skipCalendar() { if calendar != .granted { calendar = .skipped } }

  func openCallSoundSettings() { deps.openCallSoundSettings() }
  func openCalendarSettings() { deps.openCalendarSettings() }

  /// Continue on the permissions screen: always possible (O5).
  func continueToDone() { screen = .done }

  /// The permissions that are not allowed, for the done screen (R7).
  var unresolved: [String] {
    var names: [String] = []
    if microphone != .granted {
      names.append(
        String(localized: "Microphone", comment: "EnviousMeet setup: a permission name."))
    }
    if callSound != .granted && callSound != .requested {
      names.append(
        String(localized: "Call sound", comment: "EnviousMeet setup: a permission name."))
    }
    if calendar != .granted {
      names.append(String(localized: "Calendar", comment: "EnviousMeet setup: a permission name."))
    }
    return names
  }

  /// "Open EnviousMeet": the lock opens and the page shows the settings.
  func finish() {
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
        screen: MeetingSetupTelemetry.Screen(rawValue: screen.rawValue) ?? .welcome,
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
    case .notAsked, .unavailable: return .unknown
    }
  }
}
