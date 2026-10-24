#if DEBUG
  import Foundation
  import Testing
  import os

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprCore
  @testable import EnviousWisprServices

  /// #3972 C6a: when these fail, an agent's meeting command reports a meeting that never
  /// started, stops or deletes the wrong meeting, or reads back text it was not asked for. No
  /// customer sees the door; the UAT that proves EnviousMeet does.
  @MainActor
  @Suite("EnviousMeet dev-control commands", .tags(.harnessContract), .timeLimit(.minutes(1)))
  struct DevControlMeetingTests {
    @MainActor
    final class Rig {
      let harness: MeetingCoordinatorTests.Harness
      let history: MeetingHistoryPresentationTests.Rig
      var explained = true
      var pageShown = 0
      var setUp = true
      lazy var flow = MeetingStartFlow(
        dependencies: .init(
          isSetUp: { [unowned self] in setUp },
          captureCallSound: { [unowned self] in harness.callSound },
          isExplained: { [unowned self] in explained },
          markExplained: { [unowned self] in explained = true },
          canStart: { [unowned self] in harness.coordinator.phase == .idle },
          start: { [unowned self] entry, callSound in
            await harness.coordinator.start(from: entry, captureCallSound: callSound)
          },
          microphoneNeedsAsking: { false },
          requestMicrophone: {},
          showMeetingPage: { [unowned self] in pageShown += 1 }))
      lazy var meetings = DevControlMeetings(
        sources: .init(
          coordinator: { [unowned self] in harness.coordinator },
          startFlow: { [unowned self] in flow },
          transcripts: { [unowned self] in history.coordinator }))
      let status = DevControlFixtures.StatusFake()
      let models = DevControlFixtures.ModelFake()
      lazy var dispatcher = DevControlDispatcher(
        settings: SettingsManager(
          defaults: TestDefaults.suite("ew.tests.3972.devControlMeetings.\(UUID().uuidString)")!),
        writeContext: DevControlSettings.WriteContext(
          modelCatalog: { DevControlSettings.ModelCatalog(provider: nil, models: []) },
          loadCachedModelCatalog: { _, _ in },
          connectedInputUIDs: { [] }, inputChannelCounts: { [:] },
          pillWordsCapability: { .available }),
        status: status.sources,
        history: DevControlFixtures.history([]),
        models: models.actions,
        dictation: DevControlFixtures.inertDictation(),
        credentials: DevControlFixtures.isolatedCredentials(),
        words: DevControlFixtures.unwrittenWords(), meetings: meetings)

      init() throws {
        harness = try MeetingCoordinatorTests.Harness()
        history = MeetingHistoryPresentationTests.Rig()
        history.coordinator.meetingInfo = { [unowned self] id in
          harness.coordinator.record(id: id).map(MeetingHistoryInfo.init(record:))
        }
      }

      func call(_ name: String, _ args: [String: Any] = [:]) async -> DevControlDispatcher.Result {
        await dispatcher.handle(DevControlDispatcher.Command(rawValue: name), args: args)
      }
    }

    static func ok(_ result: DevControlDispatcher.Result) -> [String: Any]? {
      if case .ok(let payload, _) = result { return payload }
      return nil
    }

    static func code(_ result: DevControlDispatcher.Result) -> String? {
      if case .error(let code, _) = result { return code }
      return nil
    }

    @Test("every meeting command is routed, and refuses without its owners")
    func unwiredRefuses() async {
      let unwired = DevControlMeetings.unwired()
      let id = UUID().uuidString
      #expect(Self.code(await unwired.start(["entryPoint": "menu"])) == "notWired")
      #expect(Self.code(await unwired.stop(["meetingID": id])) == "notWired")
      #expect(Self.code(unwired.status([:])) == "notWired")
      #expect(Self.code(unwired.list([:])) == "notWired")
      #expect(Self.code(unwired.get(["meetingID": id])) == "notWired")
      #expect(Self.code(await unwired.retry(["meetingID": id])) == "notWired")
      #expect(Self.code(await unwired.deleteAudio(["meetingID": id])) == "notWired")
      #expect(Self.code(await unwired.delete(["meetingID": id])) == "notWired")
      #expect(Self.code(await unwired.notesGet(["meetingID": id])) == "notWired")
      #expect(
        Self.code(await unwired.notesSet(["meetingID": id, "notes": "x"])) == "notWired")
      #expect(Self.code(await unwired.summaryGet(["meetingID": id])) == "notWired")
      #expect(Self.code(await unwired.summaryWrite(["meetingID": id])) == "notWired")
      #expect(Self.code(unwired.live([:])) == "notWired")
      let meetingCommands = DevControlDispatcher.Command.allCases.filter {
        $0.rawValue.hasPrefix("meeting.")
      }
      #expect(meetingCommands.count == 13)
    }

    @Test("malformed arguments are refused before any owner is called")
    func argumentsRefused() async throws {
      let rig = try Rig()
      let id = UUID().uuidString
      let refusals: [(String, [String: Any])] = [
        ("meeting.start", [:]),
        ("meeting.start", ["entryPoint": "dock"]),
        ("meeting.start", ["entryPoint": "menu", "callSound": 1]),
        ("meeting.start", ["entryPoint": "menu", "extra": true]),
        ("meeting.stop", ["meetingID": "not-a-uuid"]),
        ("meeting.stop", ["meetingID": id, "force": true]),
        ("meeting.status", ["x": 1]),
        ("meeting.list", ["limit": 0]),
        ("meeting.list", ["limit": DevControlMeetings.maxListLimit + 1]),
        ("meeting.list", ["limit": true]),
        ("meeting.list", ["limit": 2.5]),
        ("meeting.get", ["meetingID": id, "turnLimit": DevControlMeetings.maxTurnLimit + 1]),
        ("meeting.get", ["meetingID": id, "turnOffset": -1]),
        ("meeting.get", ["meetingID": id, "includeText": 1]),
        ("meeting.notes.get", ["meetingID": id, "x": 1]),
        ("meeting.notes.set", ["meetingID": id]),
        ("meeting.notes.set", ["meetingID": id, "notes": 3]),
        ("meeting.summary.get", ["meetingID": "nope"]),
        ("meeting.summary.write", ["meetingID": id, "replace": "yes"]),
        ("meeting.live", ["meetingID": id]),
      ]
      for (name, args) in refusals {
        #expect(Self.code(await rig.call(name, args)) == "badArgs", "\(name) \(args)")
      }
      #expect(rig.harness.recorders.isEmpty, "no refused Start reached the recorder")
    }

    @Test("start, status, stop: the reply names the meeting the owner actually started")
    func startStatusStop() async throws {
      let rig = try Rig()
      let started = try #require(Self.ok(await rig.call("meeting.start", ["entryPoint": "menu"])))
      #expect(started["outcome"] as? String == "recording")
      let meetingID = try #require(started["meetingID"] as? String)
      #expect(rig.harness.recorders.count == 1)

      let status = try #require(Self.ok(await rig.call("meeting.status")))
      let phase = try #require(status["phase"] as? [String: Any])
      #expect(phase["name"] as? String == "recording")
      #expect(phase["meetingID"] as? String == meetingID)

      let again = try #require(Self.ok(await rig.call("meeting.start", ["entryPoint": "history"])))
      #expect(again["outcome"] as? String == "notIdle")
      #expect(rig.harness.recorders.count == 1)

      let wrong = await rig.call("meeting.stop", ["meetingID": UUID().uuidString])
      #expect(Self.code(wrong) == "notRecording")
      #expect(rig.harness.recorders.first?.stopCalls == 0)

      let stopped = try #require(Self.ok(await rig.call("meeting.stop", ["meetingID": meetingID])))
      #expect(stopped["meetingID"] as? String == meetingID)
      #expect(rig.harness.recorders.first?.stopCalls == 1)
    }

    @Test("a call-sound Start that needs the explainer waits; the setting is never changed")
    func explainerWaits() async throws {
      let rig = try Rig()
      rig.explained = false
      let reply = try #require(
        Self.ok(await rig.call("meeting.start", ["entryPoint": "menu", "callSound": true])))
      #expect(reply["outcome"] as? String == "waitingForExplainer")
      #expect(rig.harness.recorders.isEmpty)
      #expect(rig.pageShown == 1)
      #expect(rig.harness.callSound == false, "the request's choice is not saved")
      let status = try #require(Self.ok(await rig.call("meeting.status")))
      #expect(status["pendingExplainer"] as? String == "menu")
    }

    @Test("list and get read back the saved meeting and its History row's turns")
    func listAndGet() async throws {
      let rig = try Rig()
      let coordinator = rig.harness.coordinator
      await coordinator.start(from: .menu)
      let meetingID = try #require(coordinator.meetings.first?.id)
      await coordinator.stop()
      await MeetingCoordinatorTests.eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready
      }
      let saved = try #require(rig.harness.saved.first)
      try await rig.history.coordinator.saveAndShowDurably(saved)

      let list = try #require(Self.ok(await rig.call("meeting.list", ["limit": 1])))
      let rows = try #require(list["meetings"] as? [[String: Any]])
      #expect(rows.map { $0["meetingID"] as? String } == [meetingID.uuidString])
      #expect(list["total"] as? Int == 1)

      let get = try #require(
        Self.ok(await rig.call("meeting.get", ["meetingID": meetingID.uuidString])))
      let transcript = try #require(get["transcript"] as? [String: Any])
      #expect(transcript["rowID"] as? String == saved.id.uuidString)
      #expect(transcript["text"] == nil, "text only when asked for")
      let turns = try #require(transcript["turns"] as? [[String: Any]])
      #expect(turns.count == (saved.turns ?? []).count)
      let echo = Set(try #require(coordinator.record(id: meetingID)).echoTurnIDs)
      for turn in turns {
        let id = try #require(turn["id"] as? String)
        #expect(turn["echo"] as? Bool == echo.contains(id))
      }

      let withText = try #require(
        Self.ok(
          await rig.call(
            "meeting.get", ["meetingID": meetingID.uuidString, "includeText": true])))
      #expect((withText["transcript"] as? [String: Any])?["text"] as? String == saved.text)

      let paged = try #require(
        Self.ok(
          await rig.call(
            "meeting.get",
            ["meetingID": meetingID.uuidString, "turnOffset": turns.count, "turnLimit": 1])))
      #expect(((paged["transcript"] as? [String: Any])?["turns"] as? [Any])?.isEmpty == true)

      let missing = await rig.call("meeting.get", ["meetingID": UUID().uuidString])
      #expect(Self.code(missing) == "notFound")
    }

    @Test("delete audio and delete read the meeting back; a recording meeting is busy")
    func changesReadBack() async throws {
      let rig = try Rig()
      let coordinator = rig.harness.coordinator
      await coordinator.start(from: .menu)
      let meetingID = try #require(coordinator.meetings.first?.id).uuidString
      let busy = await rig.call("meeting.deleteAudio", ["meetingID": meetingID])
      #expect(Self.code(busy) == "busy")
      await coordinator.stop()
      // Ready is published a moment before the pass ends; the door refuses while it runs.
      await MeetingCoordinatorTests.eventually("ready") {
        coordinator.record(id: UUID(uuidString: meetingID)!)?.state == .ready
          && coordinator.processing == nil
      }

      let audio = try #require(
        Self.ok(await rig.call("meeting.deleteAudio", ["meetingID": meetingID])))
      #expect(audio["meetingID"] as? String == meetingID)
      #expect(coordinator.record(id: UUID(uuidString: meetingID)!)?.audioKept == false)
      let twice = await rig.call("meeting.deleteAudio", ["meetingID": meetingID])
      #expect(Self.code(twice) == "rejected")

      let deleted = try #require(
        Self.ok(await rig.call("meeting.delete", ["meetingID": meetingID])))
      #expect(deleted["deleted"] as? Bool == true)
      #expect(coordinator.record(id: UUID(uuidString: meetingID)!) == nil)
      let gone = await rig.call("meeting.delete", ["meetingID": meetingID])
      #expect(Self.code(gone) == "notFound")
    }

    /// A ready meeting with its History row, through the coordinator like a real meeting.
    static func readyMeeting(_ rig: Rig) async throws -> UUID {
      let coordinator = rig.harness.coordinator
      await coordinator.start(from: .menu)
      let meetingID = try #require(coordinator.meetings.first?.id)
      await coordinator.stop()
      await MeetingCoordinatorTests.eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready
      }
      return meetingID
    }

    @Test("retry of a stalled meeting: a failed save is refused, the next retry is accepted")
    func retryStalledMeeting() async throws {
      let rig = try Rig()
      let coordinator = rig.harness.coordinator
      // The inventory save (second processing write) fails: the meeting stays processing.
      let writes = OSAllocatedUnfairLock(initialState: 0)
      rig.harness.writeGate.failWrites { record in
        guard record.state == .processing else { return false }
        return writes.withLock {
          $0 += 1
          return $0 == 2
        }
      }
      await coordinator.start(from: .history)
      let meetingID = try #require(coordinator.meetings.first?.id)
      await coordinator.stop()
      await MeetingCoordinatorTests.eventually("stalled") {
        coordinator.processing == nil && !coordinator.hasFinalPassWork
          && coordinator.record(id: meetingID)?.state == .processing
      }
      // The queued save fails: refused, though the record still reads processing (#4008).
      rig.harness.writeGate.failNext(1)
      #expect(Self.code(await rig.call("meeting.retry", ["meetingID": meetingID.uuidString])) == "rejected")
      #expect(Self.ok(await rig.call("meeting.retry", ["meetingID": meetingID.uuidString])) != nil)
      await MeetingCoordinatorTests.eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      // Ready again, it is offered again.
      #expect(coordinator.canTranscribeAgain(meetingID))
    }

    @Test("notes set saves them now, and notes get reads back exactly what is on disk")
    func notesRoundTrip() async throws {
      let rig = try Rig()
      let meetingID = try await Self.readyMeeting(rig)
      let id = meetingID.uuidString
      let set = try #require(
        Self.ok(await rig.call("meeting.notes.set", ["meetingID": id, "notes": "Ask Priya"])))
      #expect(set["saved"] as? Bool == true)
      let onDisk = try rig.harness.store.loadDocuments(meeting: meetingID).notes
      #expect(onDisk == "Ask Priya", "saved before the reply")
      let get = try #require(Self.ok(await rig.call("meeting.notes.get", ["meetingID": id])))
      #expect(get["notes"] as? String == "Ask Priya")
      #expect(get["unsaved"] as? Bool == false)
      #expect(get["loadState"] as? String == "loaded")
      let missing = await rig.call("meeting.notes.get", ["meetingID": UUID().uuidString])
      #expect(Self.code(missing) == "notFound")
      let tooBig = String(repeating: "a", count: DevControlMeetings.maxTextBytes + 1)
      #expect(
        Self.code(await rig.call("meeting.notes.set", ["meetingID": id, "notes": tooBig]))
          == "tooLarge")
    }

    @Test("summary write starts the owner's attempt; get reports it; an edit needs replace")
    func summaryWriteAndGet() async throws {
      let rig = try Rig()
      let summaryRig = try MeetingSummaryOwnerTests.Rig()
      summaryRig.world.enabled = false  // no automatic summary: the command writes it
      let coordinator = rig.harness.coordinator
      coordinator.summaries = summaryRig.makeOwner(documents: coordinator.documents)
      let meetingID = try await Self.readyMeeting(rig)
      rig.history.coordinator.meetingInfo = { id in
        coordinator.record(id: id).map(MeetingHistoryInfo.init(record:))
      }
      summaryRig.world.transcript = "You: ship it"
      let id = meetingID.uuidString

      let before = try #require(Self.ok(await rig.call("meeting.summary.get", ["meetingID": id])))
      #expect(before["summary"] is NSNull)
      #expect(before["writing"] as? Bool == false)

      let started = try #require(
        Self.ok(await rig.call("meeting.summary.write", ["meetingID": id])))
      #expect(started["outcome"] as? String == "started")
      await MeetingCoordinatorTests.eventually("written") { summaryRig.world.finished.count == 1 }
      let after = try #require(Self.ok(await rig.call("meeting.summary.get", ["meetingID": id])))
      #expect(after["summary"] as? String == summaryRig.world.answer)
      #expect(after["origin"] as? String == "generated")
      #expect(after["outOfDate"] as? Bool == false)

      // The user's own summary is replaced only when asked.
      coordinator.documents.setSummary(meetingID, "My own words")
      #expect(await coordinator.documents.flushSummary(meetingID))
      let asks = try #require(Self.ok(await rig.call("meeting.summary.write", ["meetingID": id])))
      #expect(asks["outcome"] as? String == "needsConfirmation")
      #expect(summaryRig.world.finished.count == 1, "nothing started")
      let replaced = try #require(
        Self.ok(await rig.call("meeting.summary.write", ["meetingID": id, "replace": true])))
      #expect(replaced["outcome"] as? String == "started")
      await MeetingCoordinatorTests.eventually("rewritten") { summaryRig.world.finished.count == 2 }
      let final = try #require(Self.ok(await rig.call("meeting.summary.get", ["meetingID": id])))
      #expect(final["summary"] as? String == summaryRig.world.answer)

      // With no provider nothing starts.
      summaryRig.world.provider = .none
      let refused = await rig.call("meeting.summary.write", ["meetingID": id])
      #expect(Self.code(refused) == "rejected")
      #expect(summaryRig.world.finished.count == 2)
    }

    @Test("live is null with nothing recording, and reads the live words while one records")
    func live() async throws {
      let rig = try Rig()
      let idle = try #require(Self.ok(await rig.call("meeting.live")))
      #expect(idle["live"] is NSNull)

      let preview = try MeetingLivePreviewTests.rig()
      defer { preview.idle.open() }
      let meetings = DevControlMeetings(
        sources: .init(
          coordinator: { preview.coordinator }, startFlow: { nil }, transcripts: { nil }))
      await preview.coordinator.start(from: .menu)
      let meetingID = try #require(preview.coordinator.meetings.first?.id)
      let file = try MeetingLivePreviewTests.closeFile(
        preview, meetingID: meetingID, track: .microphone, index: 1, startMs: 0)
      await MeetingCoordinatorTests.eventually("one line") {
        preview.coordinator.liveTranscript?.lines.count == 1
      }
      let reply = try #require(Self.ok(meetings.live([:])))
      let live = try #require(reply["live"] as? [String: Any])
      #expect(live["meetingID"] as? String == meetingID.uuidString)
      let lines = try #require(live["lines"] as? [[String: Any]])
      #expect(lines.map { $0["text"] as? String } == ["words of \(file)"])
      #expect(lines.first?["track"] as? String == "microphone")
      #expect(live["waitingOnSummary"] as? Bool == false)
      await preview.coordinator.stop()
    }
  }
#endif
