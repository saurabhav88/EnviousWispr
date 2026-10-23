import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #3972 C5 (coverage C5): when these fail, macOS's "record the sound your Mac plays" prompt
/// appears with no explanation, a microphone-only meeting waits on an explainer it does not
/// need, or one click starts two meetings.
@MainActor
@Suite(
  "Meeting Start and the call-sound explainer", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingStartFlowTests {
  @MainActor
  final class Rig {
    var callSound = true
    var explained = false
    var idle = true
    var starts: [MeetingEntryPoint] = []
    var pageShown = 0
    var settings: SettingsManager?
    var startedWithCallSound: [Bool] = []
    let startedMeetingID = UUID()
    var microphoneUnasked = false
    var microphoneRequests = 0
    /// Runs while the macOS microphone prompt would be up.
    var onMicrophoneRequest: @MainActor () async -> Void = {}

    lazy var flow = MeetingStartFlow(
      dependencies: .init(
        captureCallSound: { [unowned self] in settings?.meetingCaptureCallSound ?? callSound },
        isExplained: { [unowned self] in settings?.meetingCallSoundExplained ?? explained },
        markExplained: { [unowned self] in
          if let settings { settings.meetingCallSoundExplained = true } else { explained = true }
        },
        canStart: { [unowned self] in idle },
        start: { [unowned self] entry, callSound in
          starts.append(entry)
          startedWithCallSound.append(callSound)
          idle = false
          return .recording(meetingID: startedMeetingID)
        },
        microphoneNeedsAsking: { [unowned self] in microphoneUnasked },
        requestMicrophone: { [unowned self] in
          microphoneRequests += 1
          await onMicrophoneRequest()
          microphoneUnasked = false
        },
        showMeetingPage: { [unowned self] in pageShown += 1 }))
  }

  @Test("the first call-sound Start waits for the explainer; Continue starts it once")
  func explainerThenStart() async {
    let rig = Rig()
    await rig.flow.requestStart(from: .history)
    #expect(rig.starts.isEmpty)
    #expect(rig.flow.pendingExplainer == .history)
    #expect(rig.pageShown == 0)
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts == [.history])
    #expect(rig.explained)
    #expect(rig.flow.pendingExplainer == nil)
    // A second Continue (a double click) starts nothing more.
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts == [.history])
  }

  @Test("once explained, or with the call sound off, a Start goes straight through")
  func noExplainerNeeded() async {
    let explained = Rig()
    explained.explained = true
    await explained.flow.requestStart(from: .menu)
    #expect(explained.starts == [.menu])
    #expect(explained.pageShown == 0)

    let micOnly = Rig()
    micOnly.callSound = false
    await micOnly.flow.requestStart(from: .history)
    #expect(micOnly.starts == [.history])
    #expect(micOnly.explained == false, "a microphone-only Start explained nothing")
  }

  @Test("a menu Start that needs the explainer opens the page and keeps its menu entry point")
  func menuRoutesToPage() async {
    let rig = Rig()
    await rig.flow.requestStart(from: .menu)
    #expect(rig.pageShown == 1)
    #expect(rig.starts.isEmpty)
    // The page's own Start while the explainer shows does not replace the menu's request.
    await rig.flow.requestStart(from: .history)
    #expect(rig.flow.pendingExplainer == .menu)
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts == [.menu])
  }

  @Test("cancel shows the explainer again next time; a meeting started meanwhile wins")
  func cancelAndSupersede() async {
    let rig = Rig()
    await rig.flow.requestStart(from: .history)
    rig.flow.cancelExplainer()
    #expect(rig.flow.pendingExplainer == nil)
    #expect(rig.explained == false)
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts.isEmpty)

    await rig.flow.requestStart(from: .history)
    rig.idle = false  // another route started a meeting while the explainer showed
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts.isEmpty)
    #expect(rig.flow.pendingExplainer == nil)
  }

  @Test("call sound switched off while the explainer shows: a microphone-only Start")
  func callSoundTurnedOffMeanwhile() async {
    let rig = Rig()
    await rig.flow.requestStart(from: .history)
    rig.callSound = false
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts == [.history])
    #expect(rig.explained == false)
  }

  @Test("a direct Start ends a request still waiting on the explainer; its Continue does nothing")
  func directStartConsumesPending() async {
    for change in ["callSoundOff", "explainedElsewhere"] {
      let rig = Rig()
      await rig.flow.requestStart(from: .menu)
      #expect(rig.flow.pendingExplainer == .menu)
      if change == "callSoundOff" { rig.callSound = false } else { rig.explained = true }
      await rig.flow.requestStart(from: .history)
      #expect(rig.starts == [.history], "\(change)")
      #expect(rig.flow.pendingExplainer == nil, "\(change)")
      // That meeting ends; the old explainer's Continue must not start another.
      rig.idle = true
      await rig.flow.continueAfterExplainer()
      #expect(rig.starts == [.history], "\(change)")
    }
  }

  @Test("the Start carries the call-sound choice it was admitted with")
  func startCarriesTheAdmittedChoice() async {
    let micOnly = Rig()
    micOnly.callSound = false
    await micOnly.flow.requestStart(from: .history)
    #expect(micOnly.startedWithCallSound == [false])

    let explained = Rig()
    explained.explained = true
    await explained.flow.requestStart(from: .history)
    #expect(explained.startedWithCallSound == [true])

    // Switched off while the explainer showed: Continue starts microphone-only.
    let switched = Rig()
    await switched.flow.requestStart(from: .history)
    switched.callSound = false
    await switched.flow.continueAfterExplainer()
    #expect(switched.startedWithCallSound == [false])
  }

  @Test("a never-asked microphone is asked on Start; a meeting started meanwhile wins")
  func microphoneAskedOnStart() async {
    let rig = Rig()
    rig.explained = true
    rig.microphoneUnasked = true
    await rig.flow.requestStart(from: .history)
    #expect(rig.microphoneRequests == 1)
    #expect(rig.starts == [.history])

    let asked = Rig()
    asked.explained = true
    await asked.flow.requestStart(from: .history)
    #expect(asked.microphoneRequests == 0, "an answered microphone is never asked again")
    #expect(asked.starts == [.history])

    let superseded = Rig()
    superseded.explained = true
    superseded.microphoneUnasked = true
    superseded.onMicrophoneRequest = { superseded.idle = false }
    await superseded.flow.requestStart(from: .menu)
    #expect(superseded.microphoneRequests == 1)
    #expect(superseded.starts.isEmpty)

    let fix = Rig()
    await fix.flow.fixMicrophone()
    #expect(fix.microphoneRequests == 1)
    #expect(fix.starts.isEmpty, "Allow Microphone starts nothing")
  }

  @Test("Starts during the microphone prompt join the first; a cancelled one never starts")
  func overlappingStartsDuringThePrompt() async {
    for explained in [true, false] {
      let rig = Rig()
      rig.explained = explained
      rig.microphoneUnasked = true
      let prompt = MeetingCoordinatorTests.Gate()
      // Only the first prompt stays up; a second ask (the bug) returns at once and is counted.
      rig.onMicrophoneRequest = { if rig.microphoneRequests == 1 { await prompt.wait() } }
      let menu = Task { await rig.flow.requestStart(from: .menu) }
      await MeetingCoordinatorTests.eventually("prompt up") { prompt.parked }
      #expect(rig.flow.waitingForMicrophone == .menu)
      await rig.flow.requestStart(from: .history)
      #expect(rig.microphoneRequests == 1, "macOS is asked once")
      prompt.open()
      await menu.value
      #expect(rig.flow.waitingForMicrophone == nil)
      if explained {
        #expect(rig.starts == [.menu], "the first request keeps its entry point")
      } else {
        #expect(rig.starts.isEmpty)
        #expect(rig.flow.pendingExplainer == .menu)
      }
    }

    // Cancelled while the prompt is up: the Start that comes back starts nothing, now or later.
    let rig = Rig()
    rig.explained = true
    rig.microphoneUnasked = true
    let prompt = MeetingCoordinatorTests.Gate()
    rig.onMicrophoneRequest = { if rig.microphoneRequests == 1 { await prompt.wait() } }
    let start = Task { await rig.flow.requestStart(from: .history) }
    await MeetingCoordinatorTests.eventually("prompt up") { prompt.parked }
    rig.flow.cancelExplainer()
    prompt.open()
    await start.value
    #expect(rig.starts.isEmpty)
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts.isEmpty)
  }

  @Test("no Start while a meeting is starting, recording or stopping")
  func busyRefuses() async {
    let rig = Rig()
    rig.idle = false
    await rig.flow.requestStart(from: .menu)
    #expect(rig.starts.isEmpty)
    #expect(rig.flow.pendingExplainer == nil)
    #expect(rig.pageShown == 0)
  }

  @Test("the explainer acknowledgement is saved in isolated settings and read back")
  func acknowledgementPersists() async throws {
    let defaults = try #require(
      TestDefaults.suite("ew.tests.3972.meetingStartFlow.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingCallSoundExplained == false)
    let rig = Rig()
    rig.settings = settings
    await rig.flow.requestStart(from: .history)
    await rig.flow.continueAfterExplainer()
    #expect(rig.starts == [.history])
    #expect(SettingsManager(defaults: defaults).meetingCallSoundExplained == true)
  }
}
