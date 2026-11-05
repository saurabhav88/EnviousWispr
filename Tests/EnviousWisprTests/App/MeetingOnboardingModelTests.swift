import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #4017: EnviousMeet's setup. When these fail, the user can unlock recording without the
/// consent promise, cannot finish setup, is told a permission is on when it is not, or
/// EnviousMeet stays locked after setup. #4346: setup needs the microphone and (macOS 14.2+)
/// the call sound before Continue; Calendar stays optional.
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
    /// When set, the calendar request waits for `releaseCalendar()`.
    var holdCalendar = false
    private var heldCalendar: CheckedContinuation<Void, Never>?
    func releaseCalendar() {
      heldCalendar?.resume()
      heldCalendar = nil
    }
    var callSoundSupported = true
    var emitted: [MeetingSetupTelemetry] = []
    var speakerLabelsRequests = 0
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
          if holdCalendar { await withCheckedContinuation { heldCalendar = $0 } }
          calendarStatus = calendarAnswer
          return calendarAnswer
        },
        openCallSoundSettings: {}, openCalendarSettings: {},
        callSoundSupported: { [unowned self] in callSoundSupported },
        settings: settings,
        emit: { [unowned self] in emitted.append($0) },
        requestSpeakerLabelsModel: { [unowned self] in speakerLabelsRequests += 1 },
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

  @Test("skipping the optional calendar still finishes and unlocks EnviousMeet")
  func finishWithSkips() throws {
    let rig = try Rig()
    rig.callSoundStatus = .granted
    rig.model.begin()
    rig.model.getStarted()
    rig.model.consented = true
    rig.model.accept()
    rig.model.skipCalendar()
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
    #expect(rig.model.unresolved.count == 1)
    rig.clock = rig.clock.addingTimeInterval(42)
    #expect(rig.speakerLabelsRequests == 0, "nothing downloads before setup finishes")
    rig.model.finish()
    #expect(rig.settings.meetingOnboardingComplete)
    // #4355 PR C: finishing setup asks for the speaker labels model once, without waiting.
    #expect(rig.speakerLabelsRequests == 1)
    #expect(rig.emitted.count == 1)
    let row = try #require(rig.emitted.first)
    #expect(row.outcome == .finished)
    #expect(row.screen == .done)
    #expect(row.seconds == 42)
    #expect(row.callSound == .granted)
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

  @Test("Not now while macOS asks about the calendar does nothing; the answer decides")
  func skipWhileAskingIsRefused() async throws {
    let rig = try Rig()
    rig.calendarAnswer = .denied
    rig.holdCalendar = true
    let request = Task { await rig.model.allowCalendar() }
    #expect(await settleUntilObserved { rig.model.asking })
    rig.model.skipCalendar()
    #expect(rig.model.calendar != .skipped)
    rig.releaseCalendar()
    await request.value
    #expect(rig.model.calendar == .denied)
  }

  @Test("an answer that arrives after setup finished never undoes a later settings choice")
  func lateAnswersKeepLaterChoices() async throws {
    let rig = try Rig()
    // Setup can finish only with the required permissions satisfied (#4346).
    rig.callSoundStatus = .granted
    rig.model.begin()
    rig.callSoundAnswer = .granted
    rig.holdCallSound = true
    let sound = Task { await rig.model.allowCallSound() }
    #expect(await settleUntilObserved { rig.model.asking })
    #expect(rig.settings.meetingCaptureCallSound == true, "Allow saves the choice at once")
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
    rig.model.finish()
    rig.settings.meetingCaptureCallSound = false
    rig.releaseCallSound()
    await sound.value
    #expect(rig.settings.meetingCaptureCallSound == false)

    let again = try Rig()
    again.callSoundStatus = .granted
    again.model.begin()
    again.calendarAnswer = .granted
    again.holdCalendar = true
    let calendar = Task { await again.model.allowCalendar() }
    #expect(await settleUntilObserved { again.model.asking })
    again.model.continueToDone()
    #expect(again.model.screen == .done)
    again.model.finish()
    // The user turns the page switch on, then off again, while macOS still asks.
    again.model.noteCalendarNamesChoice()
    again.settings.meetingUseCalendarForNames = false
    again.releaseCalendar()
    await calendar.value
    #expect(again.settings.meetingUseCalendarForNames == false)
  }

  @Test("a calendar grant that arrives after setup finished still turns on calendar names")
  func lateCalendarGrantStillApplies() async throws {
    let rig = try Rig()
    rig.callSoundStatus = .granted
    rig.model.begin()
    rig.calendarAnswer = .granted
    rig.holdCalendar = true
    let calendar = Task { await rig.model.allowCalendar() }
    #expect(await settleUntilObserved { rig.model.asking })
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
    rig.model.finish()
    #expect(rig.settings.meetingUseCalendarForNames == false)
    rig.releaseCalendar()
    await calendar.value
    #expect(rig.settings.meetingUseCalendarForNames == true)
  }

  @Test("calendar access allowed later in System Settings still turns on calendar names")
  func calendarGrantedLaterNamesMeetings() async throws {
    let rig = try Rig()
    rig.callSoundStatus = .granted
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
    #expect(rig.model.unresolved.count == 1)
    #expect(rig.model.canContinue)
    #expect(rig.model.callSoundMayAskLater)
  }

  /// Puts the model on the permissions screen with the consent promise given.
  private func toPermissions(_ rig: Rig) {
    rig.model.begin()
    rig.model.getStarted()
    rig.model.consented = true
    rig.model.accept()
  }

  @Test("Continue stays off until the microphone and the call sound are allowed")
  func continueNeedsMicrophoneAndCallSound() async throws {
    let rig = try Rig()
    rig.microphone = .notDetermined
    rig.callSoundAnswer = .granted
    toPermissions(rig)
    #expect(rig.model.canContinue == false)
    rig.model.continueToDone()
    #expect(rig.model.screen == .permissions)
    await rig.model.allowMicrophone()
    #expect(rig.model.microphoneSatisfied)
    #expect(rig.model.canContinue == false, "call sound is still missing")
    rig.model.continueToDone()
    #expect(rig.model.screen == .permissions)
    await rig.model.allowCallSound()
    #expect(rig.model.canContinue)
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
    #expect(rig.model.callSoundMayAskLater == false)
  }

  @Test("an unreadable call-sound answer lets setup continue and says macOS may ask later")
  func unreadableCallSoundContinues() async throws {
    let rig = try Rig()
    rig.callSoundAnswer = .unknown
    toPermissions(rig)
    await rig.model.allowCallSound()
    #expect(rig.model.callSound == .requested)
    #expect(rig.model.canContinue)
    #expect(rig.model.callSoundMayAskLater)
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
  }

  @Test("a refused call sound or a blocked microphone keeps Continue off")
  func refusedPermissionsBlock() throws {
    let rig = try Rig()
    rig.callSoundStatus = .denied
    toPermissions(rig)
    #expect(rig.model.callSound == .denied)
    #expect(rig.model.canContinue == false)

    let blocked = try Rig()
    blocked.microphone = .restricted
    blocked.callSoundStatus = .granted
    toPermissions(blocked)
    #expect(blocked.model.microphone == .unavailable)
    #expect(blocked.model.canContinue == false)
    blocked.model.continueToDone()
    #expect(blocked.model.screen == .permissions)
  }

  @Test("below macOS 14.2 only the microphone is required")
  func olderMacNeedsOnlyMicrophone() throws {
    let rig = try Rig()
    rig.callSoundSupported = false
    toPermissions(rig)
    #expect(rig.model.callSound == .notAsked)
    #expect(rig.model.callSoundRequired == false)
    #expect(rig.model.canContinue)
    #expect(rig.model.callSoundMayAskLater == false)
    rig.model.continueToDone()
    #expect(rig.model.screen == .done)
  }

  @Test("the calendar never blocks Continue, refused or never asked")
  func calendarNeverBlocks() async throws {
    let rig = try Rig()
    rig.callSoundStatus = .granted
    toPermissions(rig)
    #expect(rig.model.calendar == .notAsked)
    #expect(rig.model.canContinue)
    rig.calendarAnswer = .denied
    await rig.model.allowCalendar()
    #expect(rig.model.calendar == .denied)
    #expect(rig.model.canContinue)
    #expect(rig.model.unresolved.count == 1)
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
