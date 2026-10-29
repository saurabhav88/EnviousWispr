#if DEBUG
  import AppKit
  import Foundation
  import Testing
  import os

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprAudio
  @testable import EnviousWisprCore
  @testable import EnviousWisprServices

  /// #4012: what the call panel shows and what its answers do. When these fail, Yes records
  /// nothing or the wrong app, No starts a recording, the tips nag or never come, or a meeting
  /// keeps recording after the call ended.
  @MainActor
  @Suite("Call detection panel and answers", .tags(.productOutcome), .timeLimit(.minutes(1)))
  struct CallDetectionCoordinatorTests {
    @MainActor
    final class FakePanel: CallPromptPresenting {
      var isShowing = false
      var content: CallPromptContent?
      var actions = CallPromptActions()
      var shown: [CallPromptContent] = []

      func show(_ content: CallPromptContent, actions: CallPromptActions) {
        self.content = content
        self.actions = actions
        isShowing = true
        shown.append(content)
      }

      func hide() {
        isShowing = false
        content = nil
      }
    }

    @MainActor
    final class Rig {
      let settings: SettingsManager
      let panel = FakePanel()
      var phase: MeetingCoordinator.Phase = .idle
      var starts: [CallAppFamily?] = []
      var stops = 0
      var pageShown = 0
      var events: [MeetingCallPromptTelemetry] = []
      var clock = Date(timeIntervalSince1970: 3_000_000)
      var nextOutcome: MeetingStartFlow.Outcome?
      var userStarts: [CallAppFamily?] = []
      /// What every evidence read answers, and how many reads ran (the real async path).
      let evidenceAnswer = OSAllocatedUnfairLock<CallEvidenceReader.Evidence>(
        initialState: .unknown)
      let evidenceReads = OSAllocatedUnfairLock(initialState: 0)
      var blocked = false
      /// Runs at the end of a stop (a newer recording beginning meanwhile).
      var onStop: (@MainActor () -> Void)?
      /// Runs inside a detected Start, before it returns (detection changed meanwhile).
      var duringStart: (@MainActor () async -> Void)?
      private(set) var coordinator: CallDetectionCoordinator!

      init() throws {
        let defaults = try #require(
          TestDefaults.suite("ew.tests.4012.callDetection.\(UUID().uuidString)"))
        settings = SettingsManager(defaults: defaults)
        settings.meetingOnboardingComplete = true
        coordinator = CallDetectionCoordinator(
          dependencies: .init(
            settings: settings,
            meetingPhase: { [weak self] in self?.phase ?? .idle },
            stopMeeting: { [weak self] in
              guard let self else { return }
              self.stops += 1
              self.phase = .idle
              self.onStop?()
            },
            requestStart: { [weak self] family in
              guard let self else { return .notIdle }
              self.starts.append(family)
              await self.duringStart?()
              if let outcome = self.nextOutcome { return outcome }
              let id = UUID()
              self.phase = .recording(meetingID: id, startedAt: self.clock)
              return .started(.recording(meetingID: id))
            },
            startByUser: { [weak self] family in
              guard let self else { return .notIdle }
              self.userStarts.append(family)
              return self.nextOutcome ?? .notIdle
            },
            detectedStartIsBlocked: { [weak self] in self?.blocked ?? true },
            dictationActive: { false },
            showMeetingPage: { [weak self] in self?.pageShown += 1 },
            anchor: { nil },
            emit: { [weak self] in self?.events.append($0) },
            now: { [weak self] in self?.clock ?? Date() },
            makePresenter: { [panel] _ in panel }),
          discovery: CallSourceDiscovery(
            dependencies: .init(
              evidence: { [evidenceAnswer, evidenceReads] _, _ in
                evidenceReads.withLock { $0 += 1 }
                return evidenceAnswer.withLock { $0 }
              },
              now: { [weak self] in self?.clock ?? Date() })))
      }

      /// One faked Zoom process with its meeting window open, the microphone `input`.
      func zoom(_ input: CallMicrophoneWatcher.Input, pid: Int32 = 900_001) {
        coordinator.simulate([
          .init(
            holder: .init(pid: pid, bundleID: "us.zoom.xos", input: input),
            evidence: .call(family: .zoom, room: "pid-\(pid)"))
        ])
      }

      func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

      /// A real watcher reading for one Teams or Zoom process, through the evidence reads.
      func reading(_ bundleID: String, _ input: CallMicrophoneWatcher.Input, pid: Int32 = 900_010) {
        coordinator.deliverWatcherReading([.init(pid: pid, bundleID: bundleID, input: input)])
      }

      func press(_ button: String) -> Bool { coordinator.press(button) }
    }

    /// Lets every Start and Stop task the press began run, so "nothing started" is observed
    /// after them, not before.
    func settleStarts() async {
      for _ in 0..<20 { await Task.yield() }
    }

    @Test("the live call: one names it; none, two, or an unreadable or ambiguous reading do not")
    func speakerSource() throws {
      let rig = try Rig()
      let sources = rig.coordinator.discovery
      func zoom(_ pid: Int32 = 900_010) -> CallMicrophoneWatcher.Holder {
        .init(pid: pid, bundleID: "us.zoom.xos", input: .active, ownerPID: pid)
      }
      let zoomCall = CallSpeakerSourceAnswer.unique(
        .init(family: .zoom, target: CallSpeakerTarget(pid: 900_010, rule: .callWindow(.zoom))))
      rig.coordinator.deliverWatcherReading([])
      #expect(sources.speakerSource() == .none)
      rig.coordinator.deliverWatcherReading([zoom()])
      #expect(sources.speakerSource() == zoomCall)
      let first = sources.speakerSourceRevision
      rig.coordinator.deliverWatcherReading(
        [zoom()])
      #expect(sources.speakerSourceRevision == first, "the same reading again is no change")
      rig.coordinator.deliverWatcherReading(
        [zoom()], ambiguous: true)
      #expect(sources.speakerSource() == .unavailable)
      #expect(sources.speakerSourceRevision > first)
      let ambiguous = sources.speakerSourceRevision
      rig.coordinator.deliverWatcherReading(
        [zoom()])
      #expect(sources.speakerSourceRevision > ambiguous, "back to the same source is a change")
      rig.coordinator.deliverWatcherReading(
        [zoom(), zoom(900_011)])
      #expect(sources.speakerSource() == .ambiguous, "two app instances")
      rig.coordinator.deliverWatcherReading(
        [
          zoom(),
          .init(pid: 900_020, bundleID: "com.microsoft.teams2", input: .active, ownerPID: 900_020),
        ])
      #expect(sources.speakerSource() == .ambiguous, "two different calls")
      rig.coordinator.deliverWatcherReading(nil)
      #expect(sources.speakerSource() == .unavailable, "an unreadable list")
    }

    @Test("the watcher runs while prompts are on or a recording needs it, and not otherwise")
    func watcherDemand() throws {
      let rig = try Rig()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.off.rawValue
      rig.coordinator.start()
      defer { rig.coordinator.shutDown() }
      let sources = rig.coordinator.discovery
      #expect(!sources.watching, "prompts off and nothing recording: no watcher")
      sources.beginRecordingDemand()
      #expect(sources.watching == CallMicrophoneWatcher.isSupported, "a recording keeps it on")
      sources.endRecordingDemand()
      #expect(!sources.watching)
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.ask.rawValue
      rig.coordinator.tickForTesting()
      #expect(sources.watching == CallMicrophoneWatcher.isSupported, "prompts on")
      sources.beginRecordingDemand()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.off.rawValue
      rig.coordinator.tickForTesting()
      #expect(sources.watching == CallMicrophoneWatcher.isSupported, "prompts off mid-recording")
      sources.endRecordingDemand()
      #expect(!sources.watching)
    }

    @Test("with prompts off, a recording's readings never ask about a call")
    func promptsOffNeverAsk() async throws {
      let rig = try Rig()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.off.rawValue
      rig.coordinator.start()
      defer { rig.coordinator.shutDown() }
      rig.coordinator.discovery.beginRecordingDemand()
      defer { rig.coordinator.discovery.endRecordingDemand() }
      rig.evidenceAnswer.withLock { $0 = .call(family: .zoom, room: "pid-900010") }
      rig.coordinator.deliverWatcherReading(
        [.init(pid: 900_010, bundleID: "us.zoom.xos", input: .active, ownerPID: 900_010)])
      await settleStarts()
      #expect(rig.panel.content == nil)
      #expect(rig.starts.isEmpty)
      #expect(
        rig.coordinator.discovery.speakerSource()
          == .unique(
            .init(family: .zoom, target: CallSpeakerTarget(pid: 900_010, rule: .callWindow(.zoom))))
      )
    }

    @Test("a Zoom call asks; Yes records a Zoom meeting")
    func yesRecords() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      #expect(rig.panel.isShowing == false)
      #expect(rig.events.map(\.answer) == [.yes])
    }

    @Test("No records nothing; the first No ever shows the tip once")
    func noShowsTheFirstTip() throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("no"))
      #expect(rig.starts.isEmpty)
      #expect(rig.panel.content == .firstTip)
      #expect(rig.settings.meetingCallFirstTipShown)
      #expect(rig.press("openSettings"))
      #expect(rig.pageShown == 1)
      #expect(rig.settings.meetingCallNoCounts == "zoom=1")
    }

    @Test("an unanswered tip closes by itself after 15 seconds")
    func tipCloses() throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("no"))
      #expect(rig.panel.content == .firstTip)
      rig.advance(14)
      rig.zoom(.active)
      #expect(rig.panel.content == .firstTip)
      rig.advance(1)
      rig.zoom(.active)
      #expect(rig.panel.isShowing == false)
    }

    @Test("the third No for one app shows the last reminder naming it, and nothing turns off")
    func thirdNoShowsTheLastReminder() throws {
      let rig = try Rig()
      for call in 0..<3 {
        // Each call ends (the microphone off for longer than the confirm time) before the next.
        rig.zoom(.active)
        #expect(rig.panel.content == .ask(appName: "Zoom"), "call \(call)")
        #expect(rig.press("no"))
        rig.zoom(.inactive)
        rig.advance(2)
        rig.zoom(.inactive)
        rig.advance(1)
      }
      #expect(rig.panel.shown.filter { $0 == .firstTip }.count == 1)
      #expect(rig.panel.content == nil || rig.panel.content == .lastTip(appName: "Zoom"))
      #expect(rig.panel.shown.contains(.lastTip(appName: "Zoom")))
      #expect(rig.settings.meetingCallAppsOff.isEmpty)
      #expect(rig.starts.isEmpty)
    }

    @Test("Start by itself records without asking")
    func startByItself() async throws {
      let rig = try Rig()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.startByItself.rawValue
      rig.zoom(.active)
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      #expect(rig.panel.shown.isEmpty)
      #expect(await settleUntilObserved { rig.events.map(\.answer) == [.autoStarted] })
    }

    @Test("a detected meeting counts down after the call, then stops and offers a new recording")
    func countdownStopsTheDetectedMeeting() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(10)
      rig.zoom(.inactive)
      #expect(
        await settleUntilObserved { rig.stops == 1 && rig.panel.content == .stopped })
      #expect(rig.press("startNewRecording"))
      #expect(await settleUntilObserved { rig.userStarts == [.zoom] })
      #expect(rig.starts == [.zoom], "the user's Start goes through the manual route")
    }

    @Test("Keep recording stops the countdown and the meeting goes on")
    func keepRecording() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      #expect(rig.press("keepRecording"))
      rig.advance(30)
      rig.zoom(.inactive)
      #expect(rig.stops == 0)
      #expect(rig.panel.isShowing == false)
    }

    @Test("a hand-started meeting never stops when a call ends")
    func handStartedMeetingKeepsRecording() throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoom(.active)
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      #expect(rig.press("no"))
      rig.zoom(.inactive)
      rig.advance(30)
      rig.zoom(.inactive)
      #expect(rig.stops == 0)
      #expect(rig.starts.isEmpty)
    }

    @Test("a Start that needs a permission or the explainer says so instead of recording")
    func needsAttention() async throws {
      let rig = try Rig()
      rig.nextOutcome = .needsAttention
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.panel.content == .needsAttention })
      #expect(rig.press("openSettings"))
      #expect(rig.pageShown == 1)
    }

    @Test("Zoom switched off in settings, or setup not finished, never asks")
    func switchedOff() throws {
      let rig = try Rig()
      rig.settings.meetingCallAppsOff = "zoom"
      rig.zoom(.active)
      #expect(rig.panel.shown.isEmpty)
      let locked = try Rig()
      locked.settings.meetingOnboardingComplete = false
      locked.zoom(.active)
      #expect(locked.panel.shown.isEmpty)
    }

    @Test("a button the panel does not show is not pressed")
    func pressRefusesHiddenButtons() throws {
      let rig = try Rig()
      #expect(rig.press("yes") == false)
      rig.zoom(.active)
      #expect(rig.press("keepRecording") == false)
      #expect(rig.starts.isEmpty)
    }

    @Test("unknown evidence never starts a call, even a calling app with Start by itself")
    func unknownEvidenceNeverStarts() async throws {
      let rig = try Rig()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.startByItself.rawValue
      rig.reading("com.microsoft.teams2", .active)
      #expect(await settleUntilObserved { rig.evidenceReads.withLock { $0 } >= 1 })
      // Positive control: the same reading with known evidence starts.
      rig.evidenceAnswer.withLock { $0 = .call(family: .teams, room: "pid-900010") }
      rig.reading("com.microsoft.teams2", .active)
      #expect(await settleUntilObserved { rig.starts == [.teams] })
      #expect(rig.starts == [.teams], "the unknown read before it started nothing")
    }

    @Test("a failed microphone read never ends a detected meeting")
    func failedReadNeverStops() async throws {
      let rig = try Rig()
      rig.evidenceAnswer.withLock { $0 = .call(family: .zoom, room: "pid-900010") }
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { rig.panel.content == .ask(appName: "Zoom") })
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      // The microphone reads off once, then every read fails: off is not proven for long.
      rig.reading("us.zoom.xos", .inactive)
      rig.coordinator.deliverWatcherReading(nil)
      rig.advance(30)
      rig.coordinator.deliverWatcherReading(nil)
      rig.advance(30)
      rig.coordinator.deliverWatcherReading(nil)
      #expect(rig.stops == 0)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
    }

    @Test("a switch Yes that a new Start could not finish keeps the meeting recording")
    func blockedSwitchKeepsRecording() async throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoom(.active)
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      rig.blocked = true
      #expect(rig.press("yes"))
      await settleStarts()
      #expect(rig.stops == 0)
      #expect(rig.starts.isEmpty)
      #expect(rig.panel.content == .needsAttention)
    }

    @Test("Yes after the app was switched off starts nothing")
    func yesAfterSwitchedOff() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      rig.settings.meetingCallAppsOff = "zoom"
      _ = rig.press("yes")
      await settleStarts()
      #expect(rig.starts.isEmpty)
      #expect(rig.panel.isShowing == false)
    }

    @Test("a switch question pauses the old meeting's countdown; after No it counts down in view")
    func switchQuestionPausesCountdown() async throws {
      let rig = try Rig()
      rig.zoom(.active, pid: 900_001)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      let both: (CallMicrophoneWatcher.Input) -> Void = { first in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_001, bundleID: "us.zoom.xos", input: first),
            evidence: .call(family: .zoom, room: "pid-900001")),
          .init(
            holder: .init(pid: 900_002, bundleID: "com.microsoft.teams2", input: .active),
            evidence: .call(family: .teams, room: "pid-900002")),
        ])
      }
      both(.inactive)
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      for _ in 0..<14 {
        rig.advance(1)
        both(.inactive)
      }
      #expect(rig.stops == 0, "no stop behind the question")
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      #expect(rig.press("no"))
      rig.advance(1)
      both(.inactive)
      rig.advance(1.6)
      both(.inactive)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(10)
      both(.inactive)
      #expect(await settleUntilObserved { rig.stops == 1 })
    }

    @Test("after Off and back, a new call in the same app is asked about again")
    func offStartsFresh() throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("no"))
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.off.rawValue
      rig.zoom(.inactive)
      rig.zoom(.active)
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.ask.rawValue
      rig.panel.hide()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("Yes while the reading is unknown starts nothing and keeps the question")
    func yesWhileUnknownKeepsQuestion() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      rig.zoom(.unknown)
      #expect(rig.press("yes"))
      await settleStarts()
      #expect(rig.starts.isEmpty)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("with two calls, Yes records the one the panel asked about")
    func yesAnswersTheShownCall() async throws {
      let rig = try Rig()
      let two = {
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_001, bundleID: "us.zoom.xos", input: .active),
            evidence: .call(family: .zoom, room: "pid-900001")),
          .init(
            holder: .init(pid: 900_002, bundleID: "com.microsoft.teams2", input: .active),
            evidence: .call(family: .teams, room: "pid-900002")),
        ])
      }
      two()
      // Either call may be asked first; Yes records the one on the panel.
      let shown = try #require(rig.panel.content)
      let family: CallAppFamily = shown == .ask(appName: "Zoom") ? .zoom : .teams
      #expect(shown == .ask(appName: family.displayName))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [family] })
    }

    @Test("the panel stays on the screen that holds the menu bar icon")
    func panelOnIconScreen() {
      // A lower-left main display and an upper-right display with the menu bar icon.
      let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
      let upper = NSRect(x: 1440, y: 900, width: 1920, height: 1055)
      let icon = NSRect(x: 3200, y: 1955, width: 24, height: 24)
      let size = NSSize(width: 300, height: 120)
      let origin = CallPromptPanel.origin(
        for: size, anchor: icon, screens: [main, upper], mainScreen: main)
      #expect(upper.contains(origin))
      #expect(upper.contains(NSPoint(x: origin.x + size.width, y: origin.y + size.height)))
    }

    @Test("a refused Start says so on the panel")
    func refusedStartIsShown() async throws {
      let rig = try Rig()
      rig.nextOutcome = .started(.refused(.lowDisk))
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.panel.content == .couldNotStart })
      #expect(rig.press("openSettings"))
      #expect(rig.pageShown == 1)
    }

    @Test("a late stop never detaches a newer recording")
    func lateStopKeepsNewerRecording() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      // The stop returns only after a newer recording started.
      let newer = UUID()
      rig.onStop = { rig.phase = .recording(meetingID: newer, startedAt: rig.clock) }
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      rig.advance(10)
      rig.zoom(.inactive)
      #expect(await settleUntilObserved { rig.stops == 1 })
      #expect(rig.panel.content != .stopped)
    }

    @Test("a slow stop that flushes while the timer ticks still offers a new recording")
    func slowStopKeepsOffer() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      // Production goes idle before the notes flush; a tick runs during that wait.
      rig.onStop = { rig.zoom(.inactive) }
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      rig.advance(10)
      rig.zoom(.inactive)
      #expect(await settleUntilObserved { rig.panel.content == .stopped })
    }

    @Test("detection switched off during a detected Start is reported as no longer wanted")
    func startNoLongerWanted() async throws {
      let rig = try Rig()
      var wanted: [Bool] = []
      rig.duringStart = {
        wanted.append(rig.coordinator.detectedStartStillWanted())
        rig.settings.meetingCallAppsOff = "zoom"
        wanted.append(rig.coordinator.detectedStartStillWanted())
      }
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { wanted.count == 2 })
      #expect(wanted == [true, false])
    }

    @Test("an unknown reading during a detected Start keeps it wanted: it is never dropped")
    func unknownDuringStartStaysWanted() async throws {
      let rig = try Rig()
      var wanted: [Bool] = []
      rig.duringStart = {
        rig.zoom(.unknown)
        wanted.append(rig.coordinator.detectedStartStillWanted())
      }
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { wanted.count == 1 })
      #expect(wanted == [true])
      // The Start recorded, so the call's end is watched.
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
    }

    @Test("Start a new recording that is refused says so on the panel")
    func refusedNewRecordingIsShown() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      rig.advance(10)
      rig.zoom(.inactive)
      #expect(await settleUntilObserved { rig.panel.content == .stopped })
      rig.nextOutcome = .started(.refused(.lowDisk))
      #expect(rig.press("startNewRecording"))
      #expect(await settleUntilObserved { rig.panel.content == .couldNotStart })
    }

    @Test("two browser processes showing one meeting are one call")
    func oneBrowserMeetingIsOneCall() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let both: (CallMicrophoneWatcher.Input) -> Void = { second in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_031, bundleID: "com.google.chrome", input: .active),
            evidence: meet),
          .init(
            holder: .init(pid: 900_032, bundleID: "com.google.chrome.helper", input: second),
            evidence: meet),
        ])
      }
      both(.inactive)
      #expect(rig.panel.content == .ask(appName: "Google Meet"))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      both(.active)
      #expect(rig.panel.content != .switchMeeting(appName: "Google Meet"))
      #expect(rig.panel.shown.filter { $0 == .switchMeeting(appName: "Google Meet") }.isEmpty)
    }

    @Test("Recording stopped goes away when a new recording starts elsewhere")
    func stoppedOfferEndsOnNewRecording() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.zoom(.inactive)
      rig.advance(1.6)
      rig.zoom(.inactive)
      rig.advance(10)
      rig.zoom(.inactive)
      #expect(await settleUntilObserved { rig.panel.content == .stopped })
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoom(.inactive)
      #expect(rig.panel.isShowing == false)
    }

    @Test("another tab or an unknown microphone never stops a browser meeting's recording")
    func browserMeetingSurvivesTabsAndUnknown() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let chrome: (CallMicrophoneWatcher.Input, CallEvidenceReader.Evidence) -> Void = {
        input, evidence in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_041, bundleID: "com.google.chrome", input: input),
            evidence: evidence)
        ])
      }
      chrome(.active, meet)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      // Another tab for 12 seconds while the call goes on.
      for second in 0..<12 {
        rig.advance(1)
        chrome(.active, .none)
        #expect(rig.panel.content != .countdown(secondsLeft: 10), "second \(second)")
      }
      // The microphone reading goes unknown for 30 seconds.
      for _ in 0..<30 {
        rig.advance(1)
        chrome(.unknown, .none)
      }
      #expect(rig.stops == 0)
      // A confirmed off still ends it.
      chrome(.inactive, .none)
      rig.advance(1.6)
      chrome(.inactive, .none)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
    }

    @Test("another meeting's page asks to switch and never stops the meeting being recorded")
    func otherMeetingPageKeepsRecording() async throws {
      let rig = try Rig()
      let roomA = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "aaa-aaaa-aaa")
      let roomB = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "bbb-bbbb-bbb")
      let chrome: (CallEvidenceReader.Evidence) -> Void = { evidence in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_051, bundleID: "com.google.chrome", input: .active),
            evidence: evidence)
        ])
      }
      chrome(roomA)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      chrome(roomB)
      #expect(rig.panel.content == .switchMeeting(appName: "Google Meet"))
      #expect(rig.press("no"))
      for _ in 0..<20 {
        rig.advance(1)
        chrome(roomB)
      }
      #expect(rig.stops == 0)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
    }

    @Test("Chrome off the microphone ends a browser meeting even when its page cannot be read")
    func offMicrophoneEndsBrowserMeeting() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let chrome: (CallMicrophoneWatcher.Input, CallEvidenceReader.Evidence) -> Void = {
        input, evidence in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_061, bundleID: "com.google.chrome", input: input),
            evidence: evidence)
        ])
      }
      chrome(.active, meet)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      chrome(.inactive, .unknown)
      rig.advance(1.6)
      chrome(.inactive, .unknown)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
    }

    @Test("the microphone coming back on another tab cancels the countdown")
    func microphoneBackOnOtherTabCancelsCountdown() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let chrome: (CallMicrophoneWatcher.Input, CallEvidenceReader.Evidence) -> Void = {
        input, evidence in
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_071, bundleID: "com.google.chrome", input: input),
            evidence: evidence)
        ])
      }
      chrome(.active, meet)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      chrome(.inactive, .none)
      rig.advance(1.6)
      chrome(.inactive, .none)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(2)
      chrome(.active, .none)
      #expect(rig.panel.isShowing == false)
      rig.advance(30)
      chrome(.active, .none)
      #expect(rig.stops == 0)
    }

    @Test("Slack's app and helper holding the microphone for one huddle are one call")
    func nativeHelperIsSameCall() async throws {
      let rig = try Rig()
      let huddle = { (pid: Int32) in
        CallEvidenceReader.Evidence.call(family: .slack, room: "pid-900080")
      }
      rig.coordinator.simulate([
        .init(
          holder: .init(pid: 900_080, bundleID: "com.tinyspeck.slackmacgap", input: .active),
          evidence: huddle(900_080))
      ])
      #expect(rig.panel.content == .ask(appName: "Slack"))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.slack] })
      rig.coordinator.simulate([
        .init(
          holder: .init(pid: 900_080, bundleID: "com.tinyspeck.slackmacgap", input: .active),
          evidence: huddle(900_080)),
        .init(
          holder: .init(pid: 900_081, bundleID: "com.tinyspeck.slackmacgap.helper", input: .active),
          evidence: huddle(900_081)),
      ])
      #expect(rig.panel.shown.filter { $0 == .switchMeeting(appName: "Slack") }.isEmpty)
    }

    @Test("a browser handing its microphone to a new process on another tab keeps recording")
    func browserHandoverKeepsRecording() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      rig.coordinator.simulate([
        .init(
          holder: .init(pid: 900_091, bundleID: "com.google.chrome", input: .active), evidence: meet
        )
      ])
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      for _ in 0..<30 {
        rig.advance(1)
        rig.coordinator.simulate([
          .init(
            holder: .init(pid: 900_092, bundleID: "com.google.chrome.helper", input: .active),
            evidence: .none)
        ])
      }
      #expect(rig.stops == 0)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
    }

    @Test("Yes after a recording started from the menu asks to switch instead")
    func yesAfterManualStartAsksToSwitch() async throws {
      let rig = try Rig()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      #expect(rig.press("yes"))
      await settleStarts()
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      #expect(rig.starts.isEmpty)
    }

    @Test("the last reminder for a browser meeting names Meetings in a browser")
    func browserLastTipNamesTheSwitch() throws {
      let rig = try Rig()
      rig.settings.meetingCallFirstTipShown = true
      rig.settings.meetingCallNoCounts = "browser=2"
      rig.coordinator.simulate([
        .init(
          holder: .init(pid: 900_101, bundleID: "com.google.chrome", input: .active),
          evidence: .call(family: .googleMeet, room: "abc-defg-hij"))
      ])
      #expect(rig.press("no"))
      #expect(rig.panel.content == .lastTip(appName: "Meetings in a browser"))
      #expect(rig.settings.meetingCallNoCounts == "browser=3")
    }

    @Test("a switch whose new call goes unknown after the stop says so and offers a Start")
    func switchThatCannotConfirmSaysSo() async throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoom(.active)
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      rig.onStop = { rig.zoom(.unknown) }
      #expect(rig.press("yes"))
      #expect(
        await settleUntilObserved { rig.stops == 1 && rig.panel.content == .switchNotConfirmed })
      #expect(rig.starts.isEmpty)
      #expect(rig.press("startNewRecording"))
      #expect(await settleUntilObserved { rig.userStarts == [.zoom] })
    }

    @Test("a Start withdrawn for a moment of uncertainty asks again once the call reads known")
    func withdrawnStartAsksAgain() async throws {
      let rig = try Rig()
      rig.nextOutcome = .started(.superseded(meetingID: nil))
      rig.zoom(.active)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.nextOutcome = nil
      rig.panel.hide()
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("a switch question becomes Record this call? once the recording stops from the menu")
    func menuStopTurnsSwitchIntoAsk() throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoom(.active)
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      rig.phase = .idle
      rig.zoom(.active)
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("Start by itself sends no started event when the Start needs attention")
    func autoStartedOnlyWhenRecording() async throws {
      let rig = try Rig()
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.startByItself.rawValue
      rig.nextOutcome = .needsAttention
      rig.zoom(.active)
      #expect(await settleUntilObserved { rig.panel.content == .needsAttention })
      #expect(!rig.events.map(\.answer).contains(.autoStarted))
    }
  }
#endif
