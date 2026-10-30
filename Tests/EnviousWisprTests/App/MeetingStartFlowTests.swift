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
    var startedApps: [CallAppFamily?] = []
    let startedMeetingID = UUID()
    var microphoneUnasked = false
    var microphoneRequests = 0
    /// Runs while the macOS microphone prompt would be up.
    var onMicrophoneRequest: @MainActor () async -> Void = {}

    /// EnviousMeet's setup is finished (#4017); false locks every Start.
    var setUp = true
    var clock = Date(timeIntervalSinceReferenceDate: 1_000)
    var accepted: [CallDetectionPolicy.AcceptedStart] = []
    var settlements: [(CallDetectionPolicy.AcceptedStart, UUID?)] = []
    var onStart: @MainActor () async -> MeetingCoordinator.StartOutcome? = { nil }
    lazy var flow = MeetingStartFlow(
      dependencies: .init(
        isSetUp: { [unowned self] in setUp },
        captureCallSound: { [unowned self] in settings?.meetingCaptureCallSound ?? callSound },
        isExplained: { [unowned self] in settings?.meetingCallSoundExplained ?? explained },
        markExplained: { [unowned self] in
          if let settings { settings.meetingCallSoundExplained = true } else { explained = true }
        },
        canStart: { [unowned self] in idle },
        start: { [unowned self] entry, callSound, callApp in
          starts.append(entry)
          startedApps.append(callApp)
          startedWithCallSound.append(callSound)
          idle = false
          if let outcome = await onStart() { return outcome }
          return .recording(meetingID: startedMeetingID)
        },
        microphoneNeedsAsking: { [unowned self] in microphoneUnasked },
        requestMicrophone: { [unowned self] in
          microphoneRequests += 1
          await onMicrophoneRequest()
          microphoneUnasked = false
        },
        showMeetingPage: { [unowned self] in pageShown += 1 },
        acceptedStartNow: { [unowned self] in clock },
        acceptedStart: { [unowned self] in accepted.append($0) },
        settledStart: { [unowned self] in settlements.append(($0, $1)) }))
  }

  @Test("Both direct and explainer Continue freeze acceptance after gates and before the recording dependency",
    arguments: [true, false])
  func acceptedBoundaryPrecedesStart(direct: Bool) async throws {
    let rig = Rig()
    rig.callSound = !direct
    rig.microphoneUnasked = true
    rig.onMicrophoneRequest = { #expect(rig.accepted.isEmpty) }
    rig.onStart = {
      let accepted = try? #require(rig.accepted.last)
      #expect(accepted?.route == .menu && accepted?.acceptedAt == rig.clock)
      #expect(rig.settlements.isEmpty, "acceptance is synchronous, settlement follows actual outcome")
      return nil
    }
    let first = await rig.flow.requestStart(from: .menu, callApp: .zoom)
    if !direct {
      #expect(first == .waitingForExplainer && rig.accepted.isEmpty)
      rig.clock = rig.clock.addingTimeInterval(7)
      #expect(await rig.flow.continueAfterExplainer() == .started(.recording(meetingID: rig.startedMeetingID)))
    } else {
      #expect(first == .started(.recording(meetingID: rig.startedMeetingID)))
    }
    #expect(rig.accepted.count == 1 && rig.settlements.count == 1)
    #expect(rig.settlements.first?.0 == rig.accepted.first)
    #expect(rig.settlements.first?.1 == rig.startedMeetingID)
    #expect(rig.starts == [.menu] && rig.startedApps == [.zoom])
  }

  @Test("A refused or superseded accepted request never publishes a successful recording UUID")
  func failedAcceptedOutcomeHasNoRecordingFact() async {
    for outcome in [MeetingCoordinator.StartOutcome.refused(.lowDisk), .superseded(meetingID: nil)] {
      let rig = Rig()
      rig.callSound = false
      rig.onStart = { outcome }
      #expect(await rig.flow.requestStart(from: .history) == .started(outcome))
      #expect(rig.accepted.count == 1 && rig.settlements.count == 1)
      #expect(rig.settlements.first?.0.route == .history && rig.settlements.first?.1 == nil)
    }
  }

  @Test("Cancellation settles once and an old completion cannot overwrite a newer accepted generation")
  func acceptedCancellationAndLateCompletion() async {
    let rig = Rig()
    rig.callSound = false
    let gate = MeetingCoordinatorTests.Gate()
    defer { gate.open() }
    var startIndex = 0
    let newerID = UUID()
    rig.onStart = {
      startIndex += 1
      if startIndex == 1 { await gate.wait(); return .recording(meetingID: rig.startedMeetingID) }
      return .recording(meetingID: newerID)
    }
    let old = Task { await rig.flow.requestStart(from: .menu) }
    await MeetingCoordinatorTests.eventually("accepted start parked", drainFiles: false) { gate.parked }
    let oldRequest = rig.accepted.first
    rig.flow.cancelExplainer()
    #expect(rig.settlements.count == 1 && rig.settlements.first?.1 == nil)
    rig.idle = true
    #expect(await rig.flow.requestStart(from: .history) == .started(.recording(meetingID: newerID)))
    let current = rig.accepted.last
    #expect(current?.generation != oldRequest?.generation)
    #expect(rig.settlements.count == 2 && rig.settlements.last?.0 == current)
    #expect(rig.settlements.last?.1 == newerID)
    gate.open()
    await old.value
    #expect(rig.settlements.count == 2 && rig.settlements.last?.1 == newerID,
      "the old start's actual result does not publish or clear newer provenance")
  }

  @Test("Requests blocked before acceptance do not publish pending or settled facts")
  func blockedStartHasNoAcceptedProvenance() async {
    let rig = Rig()
    rig.setUp = false
    #expect(await rig.flow.requestStart(from: .menu) == .setupRequired)
    #expect(rig.accepted.isEmpty && rig.settlements.isEmpty)
    rig.setUp = true
    rig.idle = false
    #expect(await rig.flow.requestStart(from: .history) == .notIdle)
    #expect(rig.accepted.isEmpty && rig.settlements.isEmpty)
    rig.idle = true
    rig.microphoneUnasked = true
    #expect(await rig.flow.requestStart(from: .detected, callApp: .zoom) == .needsAttention)
    #expect(rig.accepted.isEmpty && rig.settlements.isEmpty)
  }

  @Test("#4012: a Start that waits for the explainer keeps its call app")
  func explainerKeepsCallApp() async {
    let rig = Rig()
    #expect(await rig.flow.requestStart(from: .menu, callApp: .zoom) == .waitingForExplainer)
    await rig.flow.continueAfterExplainer()
    #expect(rig.startedApps == [.zoom])
  }

  @Test("#4012: a detected call never asks macOS or shows the explainer; it needs attention")
  func detectedStartNeverPrompts() async {
    let unasked = Rig()
    unasked.callSound = false
    unasked.microphoneUnasked = true
    #expect(unasked.flow.detectedStartIsBlocked())
    #expect(await unasked.flow.requestStart(from: .detected, callApp: .zoom) == .needsAttention)
    #expect(unasked.microphoneRequests == 0)
    #expect(unasked.starts.isEmpty)
    #expect(unasked.pageShown == 0)

    let unexplained = Rig()
    #expect(unexplained.flow.detectedStartIsBlocked())
    #expect(await unexplained.flow.requestStart(from: .detected, callApp: .zoom) == .needsAttention)
    #expect(unexplained.flow.pendingExplainer == nil)
    #expect(unexplained.starts.isEmpty)

    let ready = Rig()
    ready.explained = true
    #expect(!ready.flow.detectedStartIsBlocked())
    #expect(
      await ready.flow.requestStart(from: .detected, callApp: .zoom)
        == .started(.recording(meetingID: ready.startedMeetingID)))
    #expect(ready.starts == [.detected])
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

  // MARK: - #4017 setup lock

  @Test("before setup, every Start route records nothing and shows the EnviousMeet page")
  func lockedStartRecordsNothing() async {
    for entry in [MeetingEntryPoint.menu, .history] {
      let rig = Rig()
      rig.setUp = false
      rig.microphoneUnasked = true
      let outcome = await rig.flow.requestStart(from: entry)
      #expect(outcome == .setupRequired)
      #expect(rig.starts.isEmpty)
      #expect(rig.microphoneRequests == 0)
      #expect(rig.flow.pendingExplainer == nil)
      #expect(rig.pageShown == 1)
    }
  }

  @Test("setup reset while the explainer waits: Continue records nothing")
  func lockedContinueRecordsNothing() async {
    let rig = Rig()
    rig.explained = false
    await rig.flow.requestStart(from: .history)
    #expect(rig.flow.pendingExplainer == .history)
    rig.setUp = false
    let outcome = await rig.flow.continueAfterExplainer()
    #expect(outcome == .setupRequired)
    #expect(rig.starts.isEmpty)
    #expect(rig.flow.pendingExplainer == nil)
  }

  @Test("setup reset while macOS asks for the microphone: that Start records nothing")
  func lockedDuringMicrophonePrompt() async {
    let rig = Rig()
    rig.microphoneUnasked = true
    rig.onMicrophoneRequest = { [unowned rig] in rig.setUp = false }
    let outcome = await rig.flow.requestStart(from: .menu)
    #expect(outcome == .setupRequired)
    #expect(rig.starts.isEmpty)
    #expect(rig.flow.waitingForMicrophone == nil)
  }

  @Test("after setup, the same Start records")
  func unlockedStartRecords() async {
    let rig = Rig()
    rig.explained = true
    let outcome = await rig.flow.requestStart(from: .menu)
    #expect(outcome == .started(.recording(meetingID: rig.startedMeetingID)))
    #expect(rig.starts == [.menu])
  }
}
