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
      let evidenceAnswer = OSAllocatedUnfairLock<CallEvidenceReader.Evidence>(initialState: .unknown)
      let evidenceReads = OSAllocatedUnfairLock(initialState: 0)
      /// Explicitly supplied only by independent call-state stories; defaults invent no continuity.
      let snapshotAnswer = OSAllocatedUnfairLock<CallEvidenceReader.Snapshot?>(initialState: nil)
      var blocked = false
      var dictation = false
      var polls = 0
      var polledHolders: [CallMicrophoneWatcher.Holder] = []
      var pollAmbiguous = false
      /// Runs at the end of a stop (a newer recording beginning meanwhile).
      var onStop: (@MainActor () -> Void)?
      /// Runs inside a detected Start, before it returns (detection changed meanwhile).
      var duringStart: (@MainActor () async -> Void)?
      var duringManualStart: (@MainActor () async -> Void)?
      private(set) var coordinator: CallDetectionCoordinator!
      let manualMeetingID = UUID()
      /// The actual admission flow with fake recording effects, used by manual-fallback stories.
      lazy var manualFlow = MeetingStartFlow(dependencies: .init(
        isSetUp: { [unowned self] in settings.meetingOnboardingComplete },
        captureCallSound: { false }, isExplained: { true }, markExplained: {},
        canStart: { [unowned self] in phase == .idle },
        start: { [unowned self] _, _, family in
          userStarts.append(family)
          phase = .recording(meetingID: manualMeetingID, startedAt: clock)
          await duringManualStart?()
          return .recording(meetingID: manualMeetingID)
        },
        microphoneNeedsAsking: { false }, requestMicrophone: {}, showMeetingPage: {},
        acceptedStartNow: { [unowned self] in clock },
        acceptedStart: { [unowned self] in coordinator.acceptedStart($0) },
        settledStart: { [unowned self] in coordinator.settledStart($0, recordingID: $1) }))

      init(
        evidenceRead: (@Sendable (CallAppCatalog.Rule, Int32) async -> CallEvidenceReader.Evidence)? = nil,
        snapshotRead: (@Sendable (CallAppCatalog.Rule, Int32) async -> CallEvidenceReader.Snapshot)? = nil,
        retainedRead: (@Sendable (CallEvidenceReader.RetainedTarget) async -> CallEvidenceReader.Snapshot)? = nil
      ) throws {
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
            dictationActive: { [weak self] in self?.dictation ?? false },
            showMeetingPage: { [weak self] in self?.pageShown += 1 },
            anchor: { nil },
            emit: { [weak self] in self?.events.append($0) },
            snapshot: { [evidenceAnswer, evidenceReads, snapshotAnswer] rule, pid, retained in
              evidenceReads.withLock { $0 += 1 }
              if let retained, let retainedRead { return await retainedRead(retained) }
              if let snapshotRead { return await snapshotRead(rule, pid) }
              if let snapshot = snapshotAnswer.withLock({ $0 }) { return snapshot }
              let answer = if let evidenceRead { await evidenceRead(rule, pid) }
                else { evidenceAnswer.withLock { $0 } }
              return Self.snapshotValue(rule: rule, pid: pid, evidence: answer)
            },
            now: { [weak self] in self?.clock ?? Date() },
            makePresenter: { [panel] _ in panel },
            pollMicrophone: { [weak self] in
              guard let self else { return }
              self.polls += 1
              self.coordinator.deliverWatcherReading(self.polledHolders, ambiguous: self.pollAmbiguous)
            }))
      }

      /// One faked Zoom process with its meeting window open, the microphone `input`.
      func zoom(_ input: CallMicrophoneWatcher.Input, pid: Int32 = 900_001) {
        coordinator.simulate([
          .init(
            holder: .init(pid: pid, bundleID: "us.zoom.xos", input: input),
            evidence: .call(family: .zoom, room: "pid-\(pid)"))
        ])
      }

      /// Explicit readiness for legacy panel/answer stories, without inventing call-state proof.
      func zoomReady(_ input: CallMicrophoneWatcher.Input = .active, pid: Int32 = 900_001) {
        zoom(input, pid: pid)
        advance(CallDetectionPolicy.questionReadiness)
        zoom(input, pid: pid)
      }

      /// A vendor-neutral completed snapshot through the real asynchronous coordinator path.
      /// This validates transport/policy, not the native vendor reader.
      func proof(_ continuity: CallEvidenceReader.Continuity, input: CallMicrophoneWatcher.Input = .active,
        rule: CallAppCatalog.Rule = .callWindow(.zoom),
        family: CallAppFamily = .zoom, room: String = "owned-call") async {
        snapshotAnswer.withLock {
          $0 = Self.snapshotValue(rule: rule, pid: 900_010,
            evidence: .call(family: family, room: room), continuity: continuity)
        }
        guard let owner = Self.snapshotValue(rule: rule, pid: 900_010, evidence: .unknown).owner else {
          Issue.record("snapshot fixture requires an explicit owner"); return
        }
        reading(owner.bundleIdentifier, input)
        #expect(await settleUntilObserved { !self.coordinator.evidenceReadPendingForTesting },
          "explicit snapshot must reach policy before asserting its outcome")
      }

      func ongoingZoom() async {
        await proof(.ongoing(family: .zoom, room: "owned-call"))
        advance(CallDetectionPolicy.questionReadiness)
        coordinator.stepForTesting()
      }

      func endedZoom() async {
        await proof(.ended(family: .zoom, room: "owned-call"), input: .inactive)
      }

      func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

      /// A real watcher reading for one Teams or Zoom process, through the evidence reads.
      func reading(_ bundleID: String, _ input: CallMicrophoneWatcher.Input, pid: Int32 = 900_010)
      {
        polledHolders = [.init(pid: pid, bundleID: bundleID, input: input)]
        coordinator.deliverWatcherReading(polledHolders)
      }

      func press(_ button: String) -> Bool { coordinator.press(button) }

      nonisolated static func snapshotValue(
        rule: CallAppCatalog.Rule, pid: Int32, evidence: CallEvidenceReader.Evidence,
        continuity: CallEvidenceReader.Continuity = .unknown, birth: UInt64 = 100
      ) -> CallEvidenceReader.Snapshot {
        let bundle: String
        switch rule {
        case .callApp(let family), .callWindow(let family):
          bundle = CallAppCatalog.nativeApps.first { $0.family == family }?.appBundleIDs.first ?? ""
        case .browser(let browser): bundle = browser.appBundleIDs.first ?? ""
        }
        return .init(startEvidence: evidence, continuity: continuity,
          owner: .init(pid: pid, bundleIdentifier: bundle, birthSeconds: birth, birthMicroseconds: 1))
      }
    }

    /// Lets every Start and Stop task the press began run, so "nothing started" is observed
    /// after them, not before.
    func settleStarts() async {
      for _ in 0..<20 { await Task.yield() }
    }

    private func heldReadGate() -> (
      stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation
    ) {
      let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      // deadline-fallback: fixture cleanup only; never used as a timing assertion.
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        gate.continuation.yield(())
        gate.continuation.finish()
      }
      return gate
    }

    @Test("Yes refresh follows the matching active microphone source, including a handoff in its poll",
      arguments: [false, true])
    func yesRefreshFollowsCurrentActiveSource(handoffInPoll: Bool) async throws {
      let laterReads = heldReadGate()
      defer { laterReads.continuation.yield(()); laterReads.continuation.finish() }
      let afterPress = OSAllocatedUnfairLock(initialState: (enabled: false, pids: [Int32]()))
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = afterPress.withLock { state -> Int? in
          guard state.enabled else { return nil }
          state.pids.append(pid)
          return state.pids.count
        }
        // Only the requested fresh read completes before the answer. Ordinary later
        // work cannot accidentally restore the other holder's discarded start proof.
        if let index, index > 1 { for await _ in laterReads.stream { break } }
        return Rig.snapshotValue(rule: rule, pid: 900_100,
          evidence: .call(family: .zoom, room: "handoff-call"),
          continuity: .ongoing(family: .zoom, room: "handoff-call"))
      })
      defer { rig.coordinator.shutDown() }
      let older: Int32 = 900_010
      let newer: Int32 = 900_011
      rig.coordinator.enablePollingForTesting()
      rig.polledHolders = [
        .init(pid: older, bundleID: "us.zoom.xos", input: .active),
        .init(pid: newer, bundleID: "us.zoom.xos", input: .active),
      ]
      rig.coordinator.deliverWatcherReading(rig.polledHolders)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.polledHolders = [
        .init(pid: older, bundleID: "us.zoom.xos", input: handoffInPoll ? .active : .inactive),
        .init(pid: newer, bundleID: "us.zoom.xos", input: handoffInPoll ? .inactive : .active),
      ]
      rig.coordinator.deliverWatcherReading(rig.polledHolders)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      #expect(rig.coordinator.inputForTesting?.continuity.compactMap(\.owner).allSatisfy { $0.pid == 900_100 } == true)
      // In the timing control, the displayed question still reflects the older active
      // holder. The required fresh poll supplies the handoff, not a second click.
      rig.polledHolders = [
        .init(pid: older, bundleID: "us.zoom.xos", input: .inactive),
        .init(pid: newer, bundleID: "us.zoom.xos", input: .active),
      ]
      afterPress.withLock { $0.enabled = true }
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] },
        "one Yes must start from current active proof without waiting for later ordinary reads")
      #expect(rig.polls == 1)
      #expect(afterPress.withLock { $0.pids.first } == newer)
      #expect(rig.coordinator.inputForTesting?.holders.contains {
        $0.pid == newer && $0.input == .active && $0.evidence == .call(family: .zoom, room: "handoff-call")
      } == true)
      laterReads.continuation.yield(()); laterReads.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.starts == [.zoom])
      guard case .recording = rig.phase else { Issue.record("Yes must settle as recording"); return }
    }

    @Test("Yes refresh waits for the current request, not unrelated later batch work",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
    func yesRefreshDoesNotWaitForUnrelatedBatch() async throws {
      let browser = heldReadGate()
      let slack = heldReadGate()
      defer {
        browser.continuation.yield(()); browser.continuation.finish()
        slack.continuation.yield(()); slack.continuation.finish()
      }
      let browserEntered = OSAllocatedUnfairLock(initialState: false)
      let zoomReads = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        switch rule {
        case .browser:
          browserEntered.withLock { $0 = true }
          for await _ in browser.stream { break }
          return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none)
        case .callWindow(.slack):
          for await _ in slack.stream { break }
          return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none)
        default:
          zoomReads.withLock { $0 += 1 }
          return Rig.snapshotValue(rule: rule, pid: pid,
            evidence: .call(family: .zoom, room: "wanted"),
            continuity: .ongoing(family: .zoom, room: "wanted"))
        }
      })
      rig.polledHolders = [
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active),
        .init(pid: 900_011, bundleID: "com.google.chrome", input: .active),
        .init(pid: 900_012, bundleID: "com.tinyspeck.slackmacgap", input: .active),
      ]
      rig.coordinator.enablePollingForTesting()
      rig.coordinator.deliverWatcherReading(rig.polledHolders)
      #expect(await settleUntilObserved { browserEntered.withLock { $0 } })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        browserEntered.withLock { $0 } && rig.panel.content == .ask(appName: "Zoom")
      })
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.coordinator.refreshPendingForTesting })
      #expect(rig.press("yes"), "a repeated click is coalesced while the same refresh is pending")
      browser.continuation.yield(()); browser.continuation.finish()
      #expect(await settleUntilObserved { rig.starts == [.zoom] },
        "Yes must not await the later held Slack request")
      #expect(zoomReads.withLock { $0 } >= 2, "the intended call needs one fresh read before Start")
      slack.continuation.yield(()); slack.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.starts.count == 1)
    }

    private func releaseWorker(_ lane: CallEvidenceRead.Lane, gate: DispatchSemaphore) async -> Bool {
      let acknowledged = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer { acknowledged.continuation.finish() }
      lane.queue.async {
        acknowledged.continuation.yield(true)
        acknowledged.continuation.finish()
      }
      // deadline-fallback: missing queue reconciliation fails instead of hanging the test.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        acknowledged.continuation.yield(false)
        acknowledged.continuation.finish()
      }
      gate.signal()
      for await value in acknowledged.stream { return value }
      return false
    }

    @Test("After the occupied lane releases, round robin gives the later healthy source a real read")
    func recoveredLaneIsFairToLaterSource() async throws {
      let lane = CallEvidenceRead.Lane()
      let slow = DispatchSemaphore(value: 0)
      defer { slow.signal() }
      let slowEntries = OSAllocatedUnfairLock(initialState: 0)
      let healthyEntries = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        let frozen = rule == .callWindow(.zoom)
        return await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid,
          bound: frozen ? .zero : .seconds(10), lane: lane, read: { _, _ in
            if frozen {
              slowEntries.withLock { $0 += 1 }
              // deadline-fallback: deliberately occupied physical lane, released by the fixture.
              _ = slow.wait(timeout: .now() + 30)
              return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none)
            }
            healthyEntries.withLock { $0 += 1 }
            return Rig.snapshotValue(rule: rule, pid: pid,
              evidence: .call(family: .googleMeet, room: "abc-defg-hij"),
              continuity: .ongoing(family: .googleMeet, room: "abc-defg-hij"))
          })
      })
      let zoom = CallMicrophoneWatcher.Holder(pid: 900_010, bundleID: "us.zoom.xos", input: .active)
      let chrome = CallMicrophoneWatcher.Holder(pid: 900_011, bundleID: "com.google.chrome", input: .active)
      rig.coordinator.deliverWatcherReading([zoom, chrome])
      #expect(await settleUntilObserved {
        slowEntries.withLock { $0 == 1 } && !rig.coordinator.evidenceReadPendingForTesting
          && rig.coordinator.inputForTesting?.continuity.count == 2
      })
      #expect(healthyEntries.withLock { $0 } == 0, "busy is not an actual healthy reader entry")
      #expect(await releaseWorker(lane, gate: slow))
      #expect(!lane.reading.withLock { $0 })
      rig.advance(1)
      // Reordering the microphone list must not reset the persistent source cursor.
      rig.coordinator.deliverWatcherReading([chrome, zoom])
      #expect(await settleUntilObserved {
        healthyEntries.withLock { $0 >= 1 } && !rig.coordinator.evidenceReadPendingForTesting
      })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == .ask(appName: "Google Meet"))
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(await releaseWorker(lane, gate: slow))
      #expect(rig.coordinator.inputForTesting?.continuity.contains {
        $0.value == .ongoing(family: .googleMeet, room: "abc-defg-hij")
      } == true)
    }

    @Test("Ambiguous startup polls actively, fractional ticks avoid extra AX and no-call polling stays slow")
    func livePollingCadenceUsesFrameState() throws {
      let rig = try Rig()
      rig.pollAmbiguous = true
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 1)
      rig.advance(0.5)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 1)
      rig.advance(0.5)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 2, "complete but ambiguous empty startup still needs active polling")
      rig.pollAmbiguous = false
      rig.advance(1)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 3)
      rig.advance(9)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 3)
      rig.advance(1)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 4)
      #expect(rig.evidenceReads.withLock { $0 } == 0)
      rig.coordinator.shutDown()
    }

    @Test("A due microphone poll runs while UI evidence is pending without starting parallel AX work")
    func microphonePollingContinuesDuringRead() async throws {
      let gate = heldReadGate()
      defer { gate.continuation.yield(()); gate.continuation.finish() }
      let entered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        entered.withLock { $0 = true }
        for await _ in gate.stream { break }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "same-call"))
      })
      rig.coordinator.enablePollingForTesting()
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { entered.withLock { $0 } })
      rig.advance(0.5)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 0)
      rig.advance(0.5)
      rig.coordinator.tickForTesting()
      #expect(rig.polls == 1)
      #expect(rig.coordinator.inputForTesting?.sequence == 2)
      #expect(rig.evidenceReads.withLock { $0 } == 1)
      gate.continuation.yield(()); gate.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
    }

    @Test("A No during a held Yes refresh invalidates the captured token and prevents a late Start")
    func replacedQuestionCannotStartAfterRefresh() async throws {
      let lane = CallEvidenceRead.Lane()
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let entered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = reads.withLock { $0 += 1; return $0 }
        if index == 2 {
          return await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid, bound: .seconds(10), lane: lane,
            read: { _, _ in
              entered.withLock { $0 = true }
              // deadline-fallback: cancellation must not hide a late real-worker result.
              _ = gate.wait(timeout: .now() + 30)
              return Rig.snapshotValue(rule: rule, pid: pid,
                evidence: .call(family: .zoom, room: "wanted"))
            })
        }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "wanted"))
      })
      rig.coordinator.enablePollingForTesting()
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .ask(appName: "Zoom") && !rig.coordinator.evidenceReadPendingForTesting
      })
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { entered.withLock { $0 } })
      #expect(rig.press("no"))
      gate.signal()
      #expect(await settleUntilObserved {
        !rig.coordinator.refreshPendingForTesting && !rig.coordinator.evidenceReadPendingForTesting
      })
      #expect(rig.starts.isEmpty)
      #expect(rig.events.contains { $0.answer == .no })
    }

    @Test("Yes on a newer question is preserved while an obsolete question's refresh finishes")
    func newerQuestionYesIsNotLost() async throws {
      let lane = CallEvidenceRead.Lane()
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let zoomReads = OSAllocatedUnfairLock(initialState: 0)
      let teamsReads = OSAllocatedUnfairLock(initialState: 0)
      let held = OSAllocatedUnfairLock(initialState: false)
      let holdNextZoom = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        if rule == .callApp(.teams) {
          teamsReads.withLock { $0 += 1 }
          return Rig.snapshotValue(rule: rule, pid: pid,
            evidence: .call(family: .teams, room: "call-b"),
            continuity: .ongoing(family: .teams, room: "call-b"))
        }
        zoomReads.withLock { $0 += 1 }
        if holdNextZoom.withLock({ let hold = $0; $0 = false; return hold }) {
          return await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid, bound: .seconds(10), lane: lane,
            read: { _, _ in
              held.withLock { $0 = true }
              // deadline-fallback: hold the obsolete request through actual worker completion.
              _ = gate.wait(timeout: .now() + 30)
              return Rig.snapshotValue(rule: rule, pid: pid,
                evidence: .call(family: .zoom, room: "call-a"))
            })
        }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "call-a"))
      })
      rig.polledHolders = [
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active),
        .init(pid: 900_011, bundleID: "com.microsoft.teams2", input: .active),
      ]
      rig.coordinator.enablePollingForTesting()
      rig.coordinator.deliverWatcherReading(rig.polledHolders)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      rig.advance(CallDetectionPolicy.questionInterval - 0.5)
      rig.coordinator.deliverWatcherReading(rig.polledHolders)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      holdNextZoom.withLock { $0 = true }
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { held.withLock { $0 } })
      rig.advance(0.5)
      #expect(rig.press("no"))
      #expect(await settleUntilObserved { rig.panel.content == .ask(appName: "Microsoft Teams") })
      #expect(rig.press("yes"))
      gate.signal()
      #expect(await settleUntilObserved { rig.starts == [.teams] },
        "the newer claimed Yes needs no second click after the obsolete refresh completes")
      #expect(teamsReads.withLock { $0 } >= 2)
      #expect(rig.starts.count == 1)
      #expect(await settleUntilObserved {
        !rig.coordinator.refreshPendingForTesting && !rig.coordinator.evidenceReadPendingForTesting
      })
    }

    @Test("An arriving source cannot restart a captured cycle ahead of a tracked retained call")
    func arrivalsDoNotStarveRetainedTarget() async throws {
      let browser = heldReadGate()
      let slack = heldReadGate()
      defer {
        browser.continuation.yield(()); browser.continuation.finish()
        slack.continuation.yield(()); slack.continuation.finish()
      }
      let browserEntered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        if case .browser = rule {
          browserEntered.withLock { $0 = true }
          for await _ in browser.stream { break }
          return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none)
        }
        if rule == .callWindow(.slack) {
          for await _ in slack.stream { break }
          return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none)
        }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "tracked"),
          continuity: .ongoing(family: .zoom, room: "tracked"))
      }, retainedRead: { target in
        .init(startEvidence: .unknown,
          continuity: .ongoing(family: target.family, room: target.room), owner: target.owner)
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .ask(appName: "Zoom") && !rig.coordinator.evidenceReadPendingForTesting
      })
      rig.advance(1)
      let chrome = CallMicrophoneWatcher.Holder(pid: 900_011, bundleID: "com.google.chrome", input: .active)
      rig.coordinator.deliverWatcherReading([chrome])
      #expect(await settleUntilObserved { browserEntered.withLock { $0 } })
      rig.coordinator.deliverWatcherReading([
        .init(pid: 900_012, bundleID: "com.tinyspeck.slackmacgap", input: .active), chrome,
      ])
      browser.continuation.yield(()); browser.continuation.finish()
      #expect(await settleUntilObserved {
        rig.coordinator.inputForTesting?.continuity.contains {
          $0.retainedTarget?.family == .zoom && $0.value == .ongoing(family: .zoom, room: "tracked")
        } == true
      })
      slack.continuation.yield(()); slack.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
    }

    @Test("Switch completion refreshes its captured room after stop changes the current page")
    func switchRefreshDoesNotBorrowChangedPage() async throws {
      let gate = heldReadGate()
      defer { gate.continuation.yield(()); gate.continuation.finish() }
      let stopped = OSAllocatedUnfairLock(initialState: false)
      let afterStop = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        if stopped.withLock({ $0 }) {
          let index = afterStop.withLock { $0 += 1; return $0 }
          if index == 1 { for await _ in gate.stream { break } }
          return Rig.snapshotValue(rule: rule, pid: pid,
            evidence: .call(family: .googleMeet, room: "xyz-wxyz-xyz"),
            continuity: .ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"))
        }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .googleMeet, room: "abc-defg-hij"),
          continuity: .ongoing(family: .googleMeet, room: "abc-defg-hij"))
      })
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.coordinator.enablePollingForTesting()
      rig.onStop = { [weak rig] in
        stopped.withLock { $0 = true }
        rig?.reading("com.google.chrome", .active)
      }
      rig.reading("com.google.chrome", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .switchMeeting(appName: "Google Meet") && !rig.coordinator.evidenceReadPendingForTesting
      })
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { afterStop.withLock { $0 == 1 } })
      gate.continuation.yield(()); gate.continuation.finish()
      #expect(await settleUntilObserved {
        afterStop.withLock { $0 >= 2 } && !rig.coordinator.refreshPendingForTesting
      })
      #expect(afterStop.withLock { $0 } >= 2, "switch completion needs its own fresh target read")
      #expect(rig.stops == 1 && rig.starts.isEmpty)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.coordinator.inputForTesting?.holders.first?.evidence
        == .call(family: .googleMeet, room: "xyz-wxyz-xyz"))
    }

    @Test("A tracked call still receives continuity when its microphone holder disappears",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
    func missingHolderStillReceivesContinuity() async throws {
      let rig = try Rig(snapshotRead: { rule, pid in
        Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "retained-call"),
          continuity: .ongoing(family: .zoom, room: "retained-call"))
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .ask(appName: "Zoom") && !rig.coordinator.evidenceReadPendingForTesting
      })
      let original = try #require(rig.coordinator.inputForTesting?.continuity.last)
      #expect(original.owner != nil)
      rig.advance(1)
      let missingAt = rig.clock
      rig.coordinator.deliverWatcherReading([])
      #expect(await settleUntilObserved {
        rig.coordinator.inputForTesting?.continuity.last?.id == 2
          && !rig.coordinator.evidenceReadPendingForTesting
      }, "a complete missing-holder frame must not end independent owner queries")
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(frame.sequence == 2 && frame.takenAt == missingAt)
      #expect(frame.holders.isEmpty)
      #expect(frame.continuity.last?.source == original.source)
      #expect(frame.continuity.last?.owner == original.owner)
      #expect(frame.continuity.last?.value == .ongoing(family: .zoom, room: "retained-call"))
      #expect(rig.starts.isEmpty && rig.stops == 0)
    }

    @Test("Retained browser targets keep established rooms instead of borrowing the latest page")
    func retainedRoomsStayDistinct() async throws {
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rooms = OSAllocatedUnfairLock(initialState: [String]())
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = stage.withLock { $0 += 1; return $0 }
        let room = index == 1 ? "abc-defg-hij" : "xyz-wxyz-xyz"
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .googleMeet, room: room),
          continuity: .ongoing(family: .googleMeet, room: room))
      }, retainedRead: { target in
        rooms.withLock { $0.append(target.room) }
        // A room-A request sees the current room-B page: never relabel its ended proof.
        return .init(startEvidence: .call(family: .googleMeet, room: "xyz-wxyz-xyz"),
          continuity: target.room == "abc-defg-hij"
            ? .ended(family: .googleMeet, room: "xyz-wxyz-xyz")
            : .ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"), owner: target.owner)
      })
      rig.reading("com.google.chrome", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(1)
      rig.reading("com.google.chrome", .active)
      #expect(await settleUntilObserved {
        stage.withLock { $0 == 2 } && !rig.coordinator.evidenceReadPendingForTesting
      })
      rig.advance(1)
      let at = rig.clock
      rig.coordinator.deliverWatcherReading([])
      #expect(await settleUntilObserved {
        rooms.withLock { $0.count == 2 } && !rig.coordinator.evidenceReadPendingForTesting
      })
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(rooms.withLock { $0 } == ["abc-defg-hij", "xyz-wxyz-xyz"])
      #expect(frame.continuity.first { $0.retainedTarget?.room == "abc-defg-hij" }?.value == .unknown)
      #expect(frame.continuity.first { $0.retainedTarget?.room == "xyz-wxyz-xyz" }?.value
        == .ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"))
      #expect(frame.holders.isEmpty && frame.takenAt == at && frame.sequence == 3)
      #expect(frame.pendingSources.isEmpty)
      #expect(rig.starts.isEmpty && rig.stops == 0)
    }

    @Test("Missing holders without verified owner attribution never gain a guessed retained read")
    func unverifiedMissingHolderIsNotQueried() async throws {
      let rig = try Rig(snapshotRead: { _, _ in
        .init(startEvidence: .call(family: .zoom, room: "unverified"))
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .ask(appName: "Zoom") && !rig.coordinator.evidenceReadPendingForTesting
      })
      let before = rig.evidenceReads.withLock { $0 }
      rig.coordinator.deliverWatcherReading([])
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.coordinator.inputForTesting?.sequence == 2)
      #expect(rig.evidenceReads.withLock { $0 } == before)
      #expect(rig.coordinator.inputForTesting?.pendingSources.isEmpty == true)
    }

    @Test("Off or replacement rejects a late retained result from the actual bounded worker",
      arguments: [true, false])
    func lateRetainedResultIsRejected(off: Bool) async throws {
      let lane = CallEvidenceRead.Lane()
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let entered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "retained-old"),
          continuity: .ongoing(family: .zoom, room: "retained-old"))
      }, retainedRead: { target in
        await CallEvidenceRead.boundedSnapshot(rule: target.rule, pid: target.holderPID,
          retained: target, bound: .seconds(10), lane: lane,
          read: { _, _ in
            entered.withLock { $0 = true }
            // deadline-fallback: bounded fixture release, not a latency threshold.
            _ = gate.wait(timeout: .now() + 30)
            return .init(startEvidence: .call(family: target.family, room: target.room),
              continuity: .ended(family: target.family, room: target.room), owner: target.owner)
          })
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved {
        rig.panel.content == .ask(appName: "Zoom") && !rig.coordinator.evidenceReadPendingForTesting
      })
      rig.advance(1)
      rig.coordinator.deliverWatcherReading([])
      #expect(await settleUntilObserved { entered.withLock { $0 } })
      if off {
        rig.settings.meetingCallDetection = "off"
        rig.coordinator.tickForTesting()
      } else {
        rig.coordinator.deliverWatcherReading([
          .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active, object: 2)
        ])
      }
      gate.signal()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(!frame.continuity.contains { if case .ended = $0.value { return true }; return false })
      #expect(frame.pendingSources.isEmpty)
      #expect(rig.starts.isEmpty && rig.stops == 0)
    }

    @Test("A waiting call cannot reuse expired start proof while a refresh is pending")
    func pendingRefreshDoesNotKeepExpiredStartEligible() async throws {
      let gate = heldReadGate()
      defer { gate.continuation.yield(()); gate.continuation.finish() }
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = stage.withLock { $0 += 1; return $0 }
        if index > 1 { for await _ in gate.stream { break } }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: index == 1 ? .call(family: .zoom, room: "waiting") : .unknown,
          continuity: index == 1 ? .ongoing(family: .zoom, room: "waiting") : .unknown)
      })
      rig.dictation = true
      let original = rig.clock
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.panel.content == nil)
      rig.advance(9)
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { stage.withLock { $0 == 2 } })
      #expect(rig.coordinator.inputForTesting?.holders.first?.evidence
        == .call(family: .zoom, room: "waiting"))
      rig.advance(2)
      rig.dictation = false
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == nil, "the newer microphone frame cannot freshen old start proof")
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(frame.holders.first?.evidence == nil)
      #expect(frame.takenAt == original.addingTimeInterval(9))
      #expect(frame.continuity.first?.id == 1)
      #expect(frame.continuity.first?.beganAt == original)
      gate.continuation.yield(()); gate.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
    }

    @Test("Microphone polls preserve completed continuity identity and pending refresh is not unknown")
    func continuityIsIndependentOfMicrophoneFrames() async throws {
      let first = heldReadGate()
      let second = heldReadGate()
      defer {
        first.continuation.yield(()); first.continuation.finish()
        second.continuation.yield(()); second.continuation.finish()
      }
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = stage.withLock { $0 += 1; return $0 }
        let stream = index == 1 ? first.stream : second.stream
        for await _ in stream { break }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "same-call"),
          continuity: index == 1 ? .ongoing(family: .zoom, room: "same-call") : .unknown)
      })
      let original = rig.clock
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { stage.withLock { $0 == 1 } })
      rig.advance(1)
      rig.reading("us.zoom.xos", .active)
      first.continuation.yield(()); first.continuation.finish()
      #expect(await settleUntilObserved {
        stage.withLock { $0 == 2 } && rig.coordinator.inputForTesting?.continuity.first?.id == 1
      })
      let pending = try #require(rig.coordinator.inputForTesting)
      #expect(pending.sequence == 2)
      #expect(pending.takenAt == original.addingTimeInterval(1))
      let observed = try #require(pending.continuity.first)
      #expect(observed.beganAt == original)
      #expect(observed.completedAt == original.addingTimeInterval(1))
      #expect(observed.value == .ongoing(family: .zoom, room: "same-call"))
      #expect(pending.pendingSources == [observed.source])
      second.continuation.yield(()); second.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      let finished = try #require(rig.coordinator.inputForTesting)
      #expect(finished.sequence == 2)
      #expect(finished.takenAt == pending.takenAt)
      #expect(finished.continuity.first?.id == 2)
      #expect(finished.continuity.first?.value == .unknown)
      #expect(finished.pendingSources.isEmpty)
    }

    @Test("An activity change withholds stale start proof but still delivers independent continuity")
    func activityChangeDoesNotReadmitOldStart() async throws {
      let gate = heldReadGate()
      defer { gate.continuation.yield(()); gate.continuation.finish() }
      let entered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        entered.withLock { $0 = true }
        for await _ in gate.stream { break }
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: .zoom, room: "same-call"),
          continuity: .ongoing(family: .zoom, room: "same-call"))
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { entered.withLock { $0 } })
      rig.advance(1)
      rig.reading("us.zoom.xos", .inactive)
      gate.continuation.yield(()); gate.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(frame.holders.first?.evidence == nil)
      #expect(frame.continuity.first?.value == .ongoing(family: .zoom, room: "same-call"))
      #expect(rig.panel.content == nil)
      #expect(rig.starts.isEmpty)
    }

    @Test("A replacement CoreAudio object cannot receive the old object's late ended result")
    func replacedObjectRejectsLateContinuity() async throws {
      let gate = heldReadGate()
      defer { gate.continuation.yield(()); gate.continuation.finish() }
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = stage.withLock { $0 += 1; return $0 }
        if index == 1 { for await _ in gate.stream { break } }
        return Rig.snapshotValue(rule: rule, pid: pid, evidence: .none,
          continuity: index == 1 ? .ended(family: .zoom, room: "old-call") : .unknown)
      })
      rig.coordinator.deliverWatcherReading([
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active, object: 1)
      ])
      #expect(await settleUntilObserved { stage.withLock { $0 == 1 } })
      rig.coordinator.deliverWatcherReading([
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active, object: 2)
      ])
      gate.continuation.yield(()); gate.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(frame.sources.first?.id == 2)
      #expect(frame.continuity.count == 1)
      #expect(frame.continuity.first?.source == frame.sources.first)
      #expect(frame.continuity.first?.value == .unknown)
      #expect(rig.starts.isEmpty && rig.stops == 0)
    }

    @Test("Off and shutdown reject a real worker's late snapshot and settle its task slot",
      arguments: [true, false])
    func lateWorkerCannotReviveStoppedDetection(shutdown: Bool) async throws {
      let lane = CallEvidenceRead.Lane()
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let entered = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid, bound: .seconds(10), lane: lane,
          read: { _, _ in
            entered.withLock { $0 = true }
            // deadline-fallback: release the fixture even if its consumer fails.
            _ = gate.wait(timeout: .now() + 30)
            return Rig.snapshotValue(rule: rule, pid: pid,
              evidence: .call(family: .zoom, room: "late"),
              continuity: .ended(family: .zoom, room: "late"))
          })
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { entered.withLock { $0 } })
      if shutdown { rig.coordinator.shutDown() }
      else {
        rig.settings.meetingCallDetection = "off"
        rig.coordinator.tickForTesting()
      }
      gate.signal()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.coordinator.inputForTesting?.continuity.isEmpty == true)
      #expect(!rig.panel.isShowing)
      #expect(rig.starts.isEmpty && rig.stops == 0)
    }

    @Test("Old lifetime cleanup cannot clear the restarted lifetime's pending read")
    func oldReadCannotClearNewWork() async throws {
      let lane = CallEvidenceRead.Lane()
      let first = DispatchSemaphore(value: 0)
      let second = DispatchSemaphore(value: 0)
      defer { first.signal(); second.signal() }
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid, bound: .seconds(10), lane: lane,
          read: { _, _ in
            let index = stage.withLock { $0 += 1; return $0 }
            // deadline-fallback: hold actual worker completion, even when its caller cancels.
            _ = (index == 1 ? first : second).wait(timeout: .now() + 30)
            return Rig.snapshotValue(rule: rule, pid: pid,
              evidence: .call(family: .zoom, room: index == 1 ? "old" : "new"),
              continuity: index == 1 ? .ended(family: .zoom, room: "old")
                : .ongoing(family: .zoom, room: "new"))
          })
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { stage.withLock { $0 == 1 } })
      rig.settings.meetingCallDetection = "off"
      rig.coordinator.tickForTesting()
      rig.settings.meetingCallDetection = "ask"
      rig.reading("us.zoom.xos", .active)
      first.signal()
      #expect(await settleUntilObserved { stage.withLock { $0 == 2 } })
      #expect(rig.coordinator.evidenceReadPendingForTesting)
      #expect(rig.coordinator.inputForTesting?.continuity.isEmpty == true)
      #expect(rig.coordinator.inputForTesting?.pendingSources.first?.id == 2)
      second.signal()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.coordinator.inputForTesting?.continuity.first?.source.id == 2)
      #expect(rig.coordinator.inputForTesting?.continuity.first?.value
        == .ongoing(family: .zoom, room: "new"))
    }

    @Test("Completed owner loss or replacement is explicit unknown, not pending or ended",
      arguments: [true, false])
    func ownerLossIsExplicitUnknown(replaced: Bool) async throws {
      let stage = OSAllocatedUnfairLock(initialState: 0)
      let rig = try Rig(snapshotRead: { rule, pid in
        let index = stage.withLock { $0 += 1; return $0 }
        if index == 1 {
          return Rig.snapshotValue(rule: rule, pid: pid,
            evidence: .call(family: .zoom, room: "same-call"),
            continuity: .ongoing(family: .zoom, room: "same-call"))
        }
        if replaced {
          return Rig.snapshotValue(rule: rule, pid: pid,
            evidence: .call(family: .zoom, room: "replacement"),
            continuity: .ended(family: .zoom, room: "replacement"), birth: 101)
        }
        return .init(startEvidence: .call(family: .zoom, room: "unverified"),
          continuity: .ended(family: .zoom, room: "unverified"))
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved {
        !rig.coordinator.evidenceReadPendingForTesting
          && rig.coordinator.inputForTesting?.continuity.first?.id == 1
      })
      rig.advance(1)
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved {
        !rig.coordinator.evidenceReadPendingForTesting
          && rig.coordinator.inputForTesting?.continuity.first?.id == 2
      })
      let frame = try #require(rig.coordinator.inputForTesting)
      #expect(frame.continuity.first?.value == .unknown)
      #expect(frame.continuity.first?.owner == nil)
      #expect(frame.pendingSources.isEmpty)
      #expect(rig.starts.isEmpty && rig.stops == 0)
      if replaced { #expect(frame.continuity.first?.source != frame.sources.first) }
      else { #expect(frame.holders.first?.evidence == .unknown) }
    }

    @Test("A healthy source reaches its consumer before a later source finishes",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
    func firstSourceIsNotWithheldByLaterRead() async throws {
      let arrived = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer {
        release.continuation.yield(())
        release.continuation.finish()
        arrived.continuation.finish()
      }
      // deadline-fallback: fail missing reader arrival, never wait forever on a broken fixture.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        arrived.continuation.yield(false)
        arrived.continuation.finish()
      }
      // deadline-fallback: bound fixture cleanup to half the suite limit; not a latency claim.
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        release.continuation.yield(())
        release.continuation.finish()
      }
      let rig = try Rig(evidenceRead: { rule, _ in
        if case .browser = rule {
          arrived.continuation.yield(true)
          arrived.continuation.finish()
          for await _ in release.stream { break }
          return .none
        }
        return .call(family: .zoom, room: "healthy-first")
      })
      rig.coordinator.deliverWatcherReading([
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .active),
        .init(pid: 900_011, bundleID: "com.google.chrome", input: .active),
      ])
      var entered = false
      for await value in arrived.stream { entered = value; break }
      #expect(entered)
      guard entered else { return }
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved { rig.panel.content == .ask(appName: "Zoom") },
        "the first completed source must not wait for the later held read")
      release.continuation.yield(())
      release.continuation.finish()
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
    }

    @Test("a tracked call is read again when its microphone becomes inactive",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
    func inactiveTrackedSourceGetsFreshEvidence() async throws {
      let rig = try Rig()
      rig.evidenceAnswer.withLock { $0 = .call(family: .zoom, room: "tracked-call") }
      rig.reading("us.zoom.xos", .active)
      // The visible question proves the completed read enrolled this call, not just reader entry.
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved { rig.panel.content == .ask(appName: "Zoom") })
      let readsBefore = rig.evidenceReads.withLock { $0 }
      #expect(readsBefore > 0)

      rig.reading("us.zoom.xos", .inactive)

      #expect(await settleUntilObserved { rig.evidenceReads.withLock { $0 } > readsBefore })
      #expect(rig.starts.isEmpty)
      #expect(rig.stops == 0)
    }

    @Test("tracking a call does not enroll unrelated inactive apps for evidence reads")
    func unrelatedInactiveSourceIsNotRead() async throws {
      let rig = try Rig()
      rig.evidenceAnswer.withLock { $0 = .call(family: .zoom, room: "tracked-call") }
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(await settleUntilObserved { rig.panel.content == .ask(appName: "Zoom") })
      let readsBefore = rig.evidenceReads.withLock { $0 }

      rig.coordinator.deliverWatcherReading([
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .inactive),
        .init(pid: 900_011, bundleID: "com.google.chrome", input: .inactive),
      ])

      #expect(rig.coordinator.evidenceReadPendingForTesting)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      #expect(rig.evidenceReads.withLock { $0 } == readsBefore + 1)
      #expect(rig.starts.isEmpty)
      #expect(rig.stops == 0)
    }

    @Test("a Zoom call asks; Yes records a Zoom meeting")
    func yesRecords() async throws {
      let rig = try Rig()
      rig.zoomReady()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      #expect(rig.panel.isShowing == false)
      #expect(rig.events.map(\.answer) == [.yes])
    }

    @Test("No records nothing; the first No ever shows the tip once")
    func noShowsTheFirstTip() throws {
      let rig = try Rig()
      rig.zoomReady()
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
      rig.zoomReady()
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
    func thirdNoShowsTheLastReminder() async throws {
      let rig = try Rig()
      for call in 0..<3 {
        await rig.ongoingZoom()
        #expect(rig.panel.content == .ask(appName: "Zoom"), "call \(call)")
        #expect(rig.press("no"))
        await rig.endedZoom()
        rig.advance(2)
        await rig.endedZoom()
        rig.advance(CallDetectionPolicy.questionInterval)
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
      rig.zoomReady()
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      #expect(rig.panel.shown.isEmpty)
      #expect(await settleUntilObserved { rig.events.map(\.answer) == [.autoStarted] })
    }

    @Test("a detected meeting counts down after the call, then stops and offers a new recording")
    func countdownStopsTheDetectedMeeting() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(10)
      await rig.endedZoom()
      #expect(
        await settleUntilObserved { rig.stops == 1 && rig.panel.content == .stopped })
      #expect(rig.press("startNewRecording"))
      #expect(await settleUntilObserved { rig.userStarts == [.zoom] })
      #expect(rig.starts == [.zoom], "the user's Start goes through the manual route")
    }

    @Test("A completed unknown snapshot cancels a real asynchronous countdown after microphone polls")
    func completedUnknownCancelsCountdown() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      await rig.endedZoom()
      let firstID = try #require(rig.coordinator.inputForTesting?.continuity.last?.id)
      rig.advance(1)
      rig.coordinator.stepForTesting()
      #expect(rig.coordinator.inputForTesting?.continuity.last?.id == firstID)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
      rig.advance(0.6)
      await rig.endedZoom()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      await rig.proof(.unknown, input: .inactive)
      #expect(rig.panel.content == nil)
      rig.advance(10)
      await rig.proof(.unknown, input: .inactive)
      #expect(rig.stops == 0)
    }

    @Test("A real Flow manual fallback on the admitted call gains owned-ID end behavior without another Start",
      .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
    func matchingFlowManualFallbackFollowsCallEnd() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      let result = await rig.manualFlow.requestStart(from: .menu)
      #expect(result == .started(.recording(meetingID: rig.manualMeetingID)))
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == nil, "the manual fallback already records the asked-about call")
      #expect(rig.userStarts.count == 1 && rig.starts.isEmpty)
      #expect(rig.events.isEmpty, "manual adoption sends neither duplicate Yes nor autoStarted")
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(10)
      await rig.endedZoom()
      #expect(await settleUntilObserved { rig.stops == 1 && rig.phase == .idle })
      #expect(rig.userStarts.count == 1 && rig.starts.isEmpty)
    }

    @Test("A recording visible before Flow returns has no transient question and rejects its old Yes")
    func visibleRecordingBeforeManualSettlement() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      let oldYes = rig.panel.actions.yes
      let gate = MeetingCoordinatorTests.Gate()
      defer { gate.open() }
      rig.duringManualStart = {
        rig.coordinator.stepForTesting()
        #expect(rig.panel.content == nil)
        await gate.wait()
      }
      let start = Task { await rig.manualFlow.requestStart(from: .menu) }
      await MeetingCoordinatorTests.eventually("manual recording visible before outcome", drainFiles: false) { gate.parked }
      #expect(rig.phase == .recording(meetingID: rig.manualMeetingID, startedAt: rig.clock))
      oldYes()
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == nil && rig.starts.isEmpty)
      gate.open()
      #expect(await start.value == .started(.recording(meetingID: rig.manualMeetingID)))
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      #expect(rig.userStarts.count == 1 && rig.starts.isEmpty && rig.events.isEmpty)
    }

    @Test("A real history Flow fallback links the already-identified ongoing browser room")
    func browserManualFlowUsesHistoricalRoom() async throws {
      let rig = try Rig()
      let rule = CallAppCatalog.Rule.browser(.chrome)
      let room = "abc-defg-hij"
      await rig.proof(.ongoing(family: .googleMeet, room: room), rule: rule, family: .googleMeet, room: room)
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == .ask(appName: "Google Meet"))
      #expect(await rig.manualFlow.requestStart(from: .history)
        == .started(.recording(meetingID: rig.manualMeetingID)))
      #expect(rig.panel.content == nil)
      await rig.proof(.ended(family: .googleMeet, room: room), rule: rule, family: .googleMeet, room: room)
      rig.advance(1.6)
      await rig.proof(.ended(family: .googleMeet, room: room), rule: rule, family: .googleMeet, room: room)
      #expect(rig.panel.content == .countdown(secondsLeft: 10), "active browser microphone cannot veto scoped end")
      #expect(rig.userStarts.count == 1 && rig.starts.isEmpty && rig.events.isEmpty)
    }

    @Test("Read-lifetime invalidation discards a parked manual ticket instead of suppressing later questions forever")
    func invalidatedManualTicketCannotBlockNewLifetime() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      let gate = MeetingCoordinatorTests.Gate()
      defer { gate.open() }
      rig.duringManualStart = { await gate.wait() }
      let start = Task { await rig.manualFlow.requestStart(from: .menu) }
      await MeetingCoordinatorTests.eventually("manual ticket parked before invalidation", drainFiles: false) { gate.parked }
      let newer = [CallDetectionCoordinator.SimulatedHolder(
        holder: .init(pid: 900_022, bundleID: "com.microsoft.teams2", input: .active),
        evidence: .call(family: .teams, room: "new-lifetime-call"))]
      rig.coordinator.simulate(newer)
      rig.advance(CallDetectionPolicy.questionInterval)
      rig.coordinator.simulate(newer)
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      gate.open()
      await start.value
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      #expect(rig.userStarts.count == 1 && rig.starts.isEmpty)
    }

    @Test("Keep recording stops the countdown and the meeting goes on")
    func keepRecording() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      #expect(rig.press("keepRecording"))
      rig.advance(30)
      await rig.endedZoom()
      #expect(rig.stops == 0)
      #expect(rig.panel.isShowing == false)
    }

    @Test("a hand-started meeting never stops when a call ends")
    func handStartedMeetingKeepsRecording() async throws {
      let rig = try Rig()
      let original = UUID()
      rig.phase = .recording(meetingID: original, startedAt: rig.clock)
      await rig.ongoingZoom()
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      #expect(rig.press("no"))
      await rig.endedZoom()
      rig.advance(2)
      await rig.endedZoom()
      rig.advance(30)
      await rig.endedZoom()
      #expect(rig.stops == 0)
      #expect(rig.starts.isEmpty)
      #expect(rig.phase == .recording(meetingID: original, startedAt: Date(timeIntervalSince1970: 3_000_000)))
      #expect(rig.panel.content == nil)
      #expect(rig.coordinator.inputForTesting?.continuity.contains {
        $0.value == .ended(family: .zoom, room: "owned-call")
      } == true, "actual completed end proof reached policy")
    }

    @Test("a Start that needs a permission or the explainer says so instead of recording")
    func needsAttention() async throws {
      let rig = try Rig()
      rig.nextOutcome = .needsAttention
      rig.zoomReady()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.panel.content == .needsAttention })
      #expect(rig.press("openSettings"))
      #expect(rig.pageShown == 1)
    }

    @Test("Zoom switched off in settings, or setup not finished, never asks")
    func switchedOff() throws {
      let rig = try Rig()
      rig.settings.meetingCallAppsOff = "zoom"
      rig.zoomReady()
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
      rig.zoomReady()
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
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
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
      rig.zoomReady()
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
      rig.zoomReady()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
      rig.settings.meetingCallAppsOff = "zoom"
      _ = rig.press("yes")
      await settleStarts()
      #expect(rig.starts.isEmpty)
      #expect(rig.panel.isShowing == false)
    }

    @Test("a switch question pauses the old meeting's countdown; after No it counts down in view")
    func switchQuestionPausesCountdown() async throws {
      let ended = OSAllocatedUnfairLock(initialState: false)
      let rig = try Rig(snapshotRead: { rule, pid in
        let family: CallAppFamily = rule == .callApp(.teams) ? .teams : .zoom
        let value: CallEvidenceReader.Continuity = family == .zoom && ended.withLock({ $0 })
          ? .ended(family: .zoom, room: "owned-call") : .ongoing(family: family, room: "owned-call")
        return Rig.snapshotValue(rule: rule, pid: pid,
          evidence: .call(family: family, room: "owned-call"), continuity: value)
      })
      rig.reading("us.zoom.xos", .active)
      #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.advance(CallDetectionPolicy.questionInterval)
      ended.withLock { $0 = true }
      let both: [CallMicrophoneWatcher.Holder] = [
        .init(pid: 900_010, bundleID: "us.zoom.xos", input: .inactive),
        .init(pid: 900_011, bundleID: "com.microsoft.teams2", input: .active),
      ]
      func readBoth() async {
        rig.polledHolders = both
        rig.coordinator.deliverWatcherReading(both)
        #expect(await settleUntilObserved { !rig.coordinator.evidenceReadPendingForTesting })
      }
      await readBoth()
      rig.advance(CallDetectionPolicy.questionReadiness)
      await readBoth()
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      for _ in 0..<7 {
        rig.advance(2)
        await readBoth()
      }
      #expect(rig.stops == 0, "no stop behind the question")
      #expect(rig.panel.content == .switchMeeting(appName: "Microsoft Teams"))
      #expect(rig.press("no"))
      rig.advance(1)
      await readBoth()
      rig.advance(1.6)
      await readBoth()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(10)
      await readBoth()
      #expect(await settleUntilObserved { rig.stops == 1 })
    }

    @Test("after Off and back, a new call in the same app is asked about again")
    func offStartsFresh() throws {
      let rig = try Rig()
      rig.zoomReady()
      #expect(rig.press("no"))
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.off.rawValue
      rig.zoom(.inactive)
      rig.zoom(.active)
      rig.settings.meetingCallDetection = CallDetectionPolicy.Mode.ask.rawValue
      rig.panel.hide()
      rig.advance(CallDetectionPolicy.questionInterval)
      rig.zoomReady()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("Yes while the reading is unknown starts nothing and keeps the question")
    func yesWhileUnknownKeepsQuestion() async throws {
      let rig = try Rig()
      rig.zoomReady()
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
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
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
      rig.zoomReady()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.panel.content == .couldNotStart })
      #expect(rig.press("openSettings"))
      #expect(rig.pageShown == 1)
    }

    @Test("a late stop never detaches a newer recording")
    func lateStopKeepsNewerRecording() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      // The stop returns only after a newer recording started.
      let newer = UUID()
      rig.onStop = { rig.phase = .recording(meetingID: newer, startedAt: rig.clock) }
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      rig.advance(10)
      await rig.endedZoom()
      #expect(await settleUntilObserved { rig.stops == 1 })
      #expect(rig.panel.content != .stopped)
    }

    @Test("a slow stop that flushes while the timer ticks still offers a new recording")
    func slowStopKeepsOffer() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      // Production goes idle before the notes flush; a tick runs during that wait.
      rig.onStop = { rig.coordinator.stepForTesting() }
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      rig.advance(10)
      await rig.endedZoom()
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
      rig.zoomReady()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { wanted.count == 2 })
      #expect(wanted == [true, false])
    }

    @Test("an unknown reading during a detected Start keeps it wanted: it is never dropped")
    func unknownDuringStartStaysWanted() async throws {
      let rig = try Rig()
      var wanted: [Bool] = []
      rig.duringStart = {
        await rig.proof(.unknown, input: .unknown)
        wanted.append(rig.coordinator.detectedStartStillWanted())
      }
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { wanted.count == 1 })
      #expect(wanted == [true])
      // The Start recorded, so the call's end is watched.
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
    }

    @Test("Start a new recording that is refused says so on the panel")
    func refusedNewRecordingIsShown() async throws {
      let rig = try Rig()
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      rig.advance(10)
      await rig.endedZoom()
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
          .init(holder: .init(pid: 900_031, bundleID: "com.google.chrome", input: .active), evidence: meet),
          .init(holder: .init(pid: 900_032, bundleID: "com.google.chrome.helper", input: second), evidence: meet),
        ])
      }
      both(.inactive)
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
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
      await rig.ongoingZoom()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      await rig.endedZoom()
      rig.advance(1.6)
      await rig.endedZoom()
      rig.advance(10)
      await rig.endedZoom()
      #expect(await settleUntilObserved { rig.panel.content == .stopped })
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      await rig.endedZoom()
      #expect(rig.panel.isShowing == false)
    }

    @Test("another tab or an unknown microphone never stops a browser meeting's recording")
    func browserMeetingSurvivesTabsAndUnknown() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let chrome: (CallMicrophoneWatcher.Input, CallEvidenceReader.Evidence) -> Void = {
        input, evidence in
        rig.coordinator.simulate([
          .init(holder: .init(pid: 900_041, bundleID: "com.google.chrome", input: input), evidence: evidence)
        ])
      }
      chrome(.active, meet)
      rig.advance(CallDetectionPolicy.questionReadiness)
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
      // Losing input still supplies no independent end proof.
      chrome(.inactive, .none)
      rig.advance(1.6)
      chrome(.inactive, .none)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
      #expect(rig.stops == 0)
    }

    @Test("another meeting's page asks to switch and never stops the meeting being recorded")
    func otherMeetingPageKeepsRecording() async throws {
      let rig = try Rig()
      let roomA = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "aaa-aaaa-aaa")
      let roomB = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "bbb-bbbb-bbb")
      let chrome: (CallEvidenceReader.Evidence) -> Void = { evidence in
        rig.coordinator.simulate([
          .init(holder: .init(pid: 900_051, bundleID: "com.google.chrome", input: .active), evidence: evidence)
        ])
      }
      chrome(roomA)
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      rig.advance(CallDetectionPolicy.questionInterval)
      chrome(roomB)
      rig.advance(CallDetectionPolicy.questionReadiness)
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

    @Test("Chrome losing its microphone with an unreadable page never independently ends a meeting")
    func offMicrophoneEndsBrowserMeeting() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      let chrome: (CallMicrophoneWatcher.Input, CallEvidenceReader.Evidence) -> Void = {
        input, evidence in
        rig.coordinator.simulate([
          .init(holder: .init(pid: 900_061, bundleID: "com.google.chrome", input: input), evidence: evidence)
        ])
      }
      chrome(.active, meet)
      rig.advance(CallDetectionPolicy.questionReadiness)
      chrome(.active, meet)
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      chrome(.inactive, .unknown)
      rig.advance(20)
      chrome(.inactive, .unknown)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
      #expect(rig.stops == 0)
    }

    @Test("fresh ongoing browser-call proof cancels the countdown")
    func microphoneBackOnOtherTabCancelsCountdown() async throws {
      let rig = try Rig()
      let rule = CallAppCatalog.Rule.browser(.chrome)
      let room = "abc-defg-hij"
      await rig.proof(.ongoing(family: .googleMeet, room: room), rule: rule, family: .googleMeet, room: room)
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      await rig.proof(.ended(family: .googleMeet, room: room), input: .inactive,
        rule: rule, family: .googleMeet, room: room)
      rig.advance(1.6)
      await rig.proof(.ended(family: .googleMeet, room: room), input: .inactive,
        rule: rule, family: .googleMeet, room: room)
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(2)
      await rig.proof(.ongoing(family: .googleMeet, room: room),
        rule: rule, family: .googleMeet, room: room)
      #expect(rig.panel.isShowing == false)
      rig.advance(30)
      await rig.proof(.ongoing(family: .googleMeet, room: room),
        rule: rule, family: .googleMeet, room: room)
      #expect(rig.stops == 0)
    }

    @Test("Slack's app and helper holding the microphone for one huddle are one call")
    func nativeHelperIsSameCall() async throws {
      let rig = try Rig()
      let huddle = { (pid: Int32) in
        CallEvidenceReader.Evidence.call(family: .slack, room: "pid-900080")
      }
      rig.coordinator.simulate([
        .init(holder: .init(pid: 900_080, bundleID: "com.tinyspeck.slackmacgap", input: .active), evidence: huddle(900_080)),
      ])
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.panel.content == .ask(appName: "Slack"))
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.slack] })
      rig.coordinator.simulate([
        .init(holder: .init(pid: 900_080, bundleID: "com.tinyspeck.slackmacgap", input: .active), evidence: huddle(900_080)),
        .init(holder: .init(pid: 900_081, bundleID: "com.tinyspeck.slackmacgap.helper", input: .active), evidence: huddle(900_081)),
      ])
      #expect(rig.panel.shown.filter { $0 == .switchMeeting(appName: "Slack") }.isEmpty)
    }

    @Test("a browser handing its microphone to a new process on another tab keeps recording")
    func browserHandoverKeepsRecording() async throws {
      let rig = try Rig()
      let meet = CallEvidenceReader.Evidence.call(family: .googleMeet, room: "abc-defg-hij")
      rig.coordinator.simulate([
        .init(holder: .init(pid: 900_091, bundleID: "com.google.chrome", input: .active), evidence: meet)
      ])
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.googleMeet] })
      for _ in 0..<30 {
        rig.advance(1)
        rig.coordinator.simulate([
          .init(holder: .init(pid: 900_092, bundleID: "com.google.chrome.helper", input: .active), evidence: .none)
        ])
      }
      #expect(rig.stops == 0)
      #expect(rig.panel.content != .countdown(secondsLeft: 10))
    }

    @Test("Yes after a recording started from the menu asks to switch instead")
    func yesAfterManualStartAsksToSwitch() async throws {
      let rig = try Rig()
      rig.zoomReady()
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
      rig.advance(CallDetectionPolicy.questionReadiness)
      rig.coordinator.stepForTesting()
      #expect(rig.press("no"))
      #expect(rig.panel.content == .lastTip(appName: "Meetings in a browser"))
      #expect(rig.settings.meetingCallNoCounts == "browser=3")
    }

    @Test("a switch whose new call goes unknown after the stop says so and offers a Start")
    func switchThatCannotConfirmSaysSo() async throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoomReady()
      #expect(rig.panel.content == .switchMeeting(appName: "Zoom"))
      rig.onStop = { rig.zoom(.unknown) }
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.stops == 1 && rig.panel.content == .switchNotConfirmed })
      #expect(rig.starts.isEmpty)
      #expect(rig.press("startNewRecording"))
      #expect(await settleUntilObserved { rig.userStarts == [.zoom] })
    }

    @Test("a Start withdrawn for a moment of uncertainty asks again once the call reads known")
    func withdrawnStartAsksAgain() async throws {
      let rig = try Rig()
      rig.nextOutcome = .started(.superseded(meetingID: nil))
      rig.zoomReady()
      #expect(rig.press("yes"))
      #expect(await settleUntilObserved { rig.starts == [.zoom] })
      rig.nextOutcome = nil
      rig.panel.hide()
      rig.advance(CallDetectionPolicy.questionInterval)
      rig.zoomReady()
      #expect(rig.panel.content == .ask(appName: "Zoom"))
    }

    @Test("a switch question becomes Record this call? once the recording stops from the menu")
    func menuStopTurnsSwitchIntoAsk() throws {
      let rig = try Rig()
      rig.phase = .recording(meetingID: UUID(), startedAt: rig.clock)
      rig.zoomReady()
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
      rig.zoomReady()
      #expect(await settleUntilObserved { rig.panel.content == .needsAttention })
      #expect(!rig.events.map(\.answer).contains(.autoStarted))
    }
  }
#endif
