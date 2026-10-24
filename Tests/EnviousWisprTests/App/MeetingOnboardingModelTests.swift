import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #4017: EnviousMeet's setup. When these fail, the user can unlock recording without the
/// consent promise, cannot finish setup, is told a permission is on when it is not, or
/// EnviousMeet stays locked after setup.
@Suite("EnviousMeet setup", .tags(.productOutcome))
@MainActor
struct MeetingOnboardingModelTests {
  @MainActor
  final class Rig {
    let settings: SettingsManager
    var microphone: AVAuthorizationStatus = .authorized
    var callSoundStatus: SystemAudioPermission.Status = .unknown
    var callSoundAnswer: SystemAudioPermission.Status? = .unknown
    /// When set, the call-sound request waits for `releaseCallSound()`.
    var holdCallSound = false
    private var heldCallSound: CheckedContinuation<Void, Never>?
    func releaseCallSound() {
      heldCallSound?.resume()
      heldCallSound = nil
    }
    var calendarStatus: CalendarAccess.Status = .notAsked
    var calendarAnswer: CalendarAccess.Status = .granted
    var emitted: [MeetingSetupTelemetry] = []
    var clock = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
      settings = SettingsManager(
        defaults: try #require(TestDefaults.suite("ew.tests.4017.setup.\(UUID().uuidString)")))
    }

    lazy var model = MeetingOnboardingModel(
      dependencies: .init(
        microphoneStatus: { [unowned self] in microphone },
        requestMicrophone: { [unowned self] in microphone = .authorized },
        callSoundStatus: { [unowned self] in callSoundStatus },
        requestCallSound: { [unowned self] in
          if holdCallSound { await withCheckedContinuation { heldCallSound = $0 } }
          return callSoundAnswer
        },
        calendarStatus: { [unowned self] in calendarStatus },
        requestCalendar: { [unowned self] in
          calendarStatus = calendarAnswer
          return calendarAnswer
        },
        openCallSoundSettings: {}, openCalendarSettings: {},
        settings: settings,
        emit: { [unowned self] in emitted.append($0) },
        now: { [unowned self] in clock }))
  }

  @Test("Accept does nothing until the consent box is ticked")
  func consentRequired() throws {
    let rig = try Rig()
    rig.model.begin()
    rig.model.getStarted()
    #expect(rig.model.screen == .legal)
    rig.model.accept()
    #expect(rig.model.screen == .legal)
    rig.model.consented = true
    rig.model.accept()
    #expect(rig.model.screen == .permissions)
  }

  @Test("skipping both optional permissions still finishes and unlocks EnviousMeet")
  func finishWithSkips() throws {
    let rig = try Rig()
    rig.model.begin()
    rig.model.getStarted()
    rig.model.consented = true
    rig.model.accept()
    rig.model.skipCallSound()
    rig.model.skipCalendar()
    rig.model.continueToDone()
    #expect(rig.model.unresolved.count == 2)
    rig.clock = rig.clock.addingTimeInterval(42)
    rig.model.finish()
    #expect(rig.settings.meetingOnboardingComplete)
    #expect(rig.emitted.count == 1)
    let row = try #require(rig.emitted.first)
    #expect(row.outcome == .finished)
    #expect(row.screen == .done)
    #expect(row.seconds == 42)
    #expect(row.callSound == .skipped)
    #expect(row.calendar == .skipped)
    #expect(row.microphone == .granted)
  }

  @Test("a call-sound request whose answer cannot be read is never shown as allowed")
  func callSoundUnknownIsRequested() async throws {
    let rig = try Rig()
    rig.callSoundAnswer = .unknown
    rig.model.begin()
    await rig.model.allowCallSound()
    #expect(rig.model.callSound == .requested)
    // macOS was asked here, so the first call-sound recording does not explain it again.
    #expect(rig.settings.meetingCallSoundExplained)
    rig.callSoundAnswer = .granted
    await rig.model.allowCallSound()
    #expect(rig.model.callSound == .granted)
  }

  @Test("allowing the calendar turns on calendar names; a refusal leaves them off")
  func calendarAnswerSetsTheSetting() async throws {
    let rig = try Rig()
    rig.model.begin()
    rig.calendarAnswer = .denied
    await rig.model.allowCalendar()
    #expect(rig.model.calendar == .denied)
    #expect(rig.settings.meetingUseCalendarForNames == false)
    rig.calendarAnswer = .granted
    await rig.model.allowCalendar()
    #expect(rig.model.calendar == .granted)
    #expect(rig.settings.meetingUseCalendarForNames)
  }

  @Test("leaving mid-setup reports once and keeps EnviousMeet locked")
  func leftReportsOnce() throws {
    let rig = try Rig()
    rig.model.begin()
    rig.model.getStarted()
    rig.model.left()
    rig.model.left()
    #expect(rig.emitted.map(\.outcome) == [.left])
    #expect(rig.emitted.first?.screen == .legal)
    #expect(rig.settings.meetingOnboardingComplete == false)
    // Coming back keeps the place and starts a new visit.
    rig.model.begin()
    #expect(rig.model.screen == .legal)
    rig.model.left()
    #expect(rig.emitted.count == 2)
  }

  @Test("a permission granted in System Settings shows as granted on return")
  func refreshReadsSystemSettings() throws {
    let rig = try Rig()
    rig.model.begin()
    rig.model.skipCalendar()
    #expect(rig.model.calendar == .skipped)
    rig.calendarStatus = .granted
    rig.callSoundStatus = .granted
    rig.model.refresh()
    #expect(rig.model.calendar == .granted)
    #expect(rig.model.callSound == .granted)
  }

  @Test("Not now while macOS asks about the call sound does nothing; the answer decides")
  func skipWhileAskingIsRefused() async throws {
    let rig = try Rig()
    rig.callSoundAnswer = .denied
    rig.holdCallSound = true
    let request = Task { await rig.model.allowCallSound() }
    #expect(await settleUntilObserved { rig.model.asking })
    rig.model.skipCallSound()
    #expect(rig.model.callSound != .skipped)
    rig.releaseCallSound()
    await request.value
    #expect(rig.model.callSound == .denied)
    #expect(rig.settings.meetingCaptureCallSound == true)
  }

  @Test("Not now on call sound turns the call sound off for the next meeting")
  func skipCallSoundTurnsItOff() throws {
    let rig = try Rig()
    #expect(rig.settings.meetingCaptureCallSound)
    rig.model.begin()
    rig.model.skipCallSound()
    #expect(rig.settings.meetingCaptureCallSound == false)
  }

  @Test("calendar access allowed later in System Settings still turns on calendar names")
  func calendarGrantedLaterNamesMeetings() async throws {
    let rig = try Rig()
    rig.model.begin()
    rig.calendarAnswer = .denied
    await rig.model.allowCalendar()
    #expect(rig.settings.meetingUseCalendarForNames == false)
    rig.calendarStatus = .granted
    rig.model.refresh()
    rig.model.continueToDone()
    rig.model.finish()
    #expect(rig.settings.meetingUseCalendarForNames)
  }

  @Test("when nothing can be asked, setup never says asked and keeps the first-recording explainer")
  func callSoundRequestUnavailable() async throws {
    let rig = try Rig()
    rig.callSoundAnswer = nil
    rig.model.begin()
    await rig.model.allowCallSound()
    #expect(rig.model.callSound == .askedAtFirstRecording)
    #expect(rig.settings.meetingCallSoundExplained == false)
    #expect(rig.model.unresolved.count == 2)
  }

  @Test("the setup row reports the furthest screen, not the one shown when the user left")
  func furthestScreenIsReported() throws {
    let rig = try Rig()
    rig.model.begin()
    rig.model.getStarted()
    rig.model.back()
    #expect(rig.model.screen == .welcome)
    rig.model.left()
    #expect(rig.emitted.first?.screen == .legal)
  }
}
