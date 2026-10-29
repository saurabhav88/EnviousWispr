import EnviousWisprAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

#if DEBUG
  // Uses DEBUG-only test seams.
  /// #4013 13B.1: when these fail, a slow microphone read piles up more reads behind it, a read
  /// from before discovery stopped comes back as a fresh reading, evidence reads go on after no
  /// one needs them, or a simulation leaves the real watcher polling.
  ///
  /// The microphone reads are a stand-in scan that can be held; everything else is the real
  /// discovery and watcher.
  @MainActor
  @Suite(
    "Call source discovery", .tags(.productOutcome), .timeLimit(.minutes(1)),
    .enabled(if: CallMicrophoneWatcher.isSupported))
  struct CallSourceDiscoveryTests {
    /// A scan that counts its calls, how many ran at once, and waits while `hold` is set.
    final class Scan: Sendable {
      let calls = OSAllocatedUnfairLock(initialState: 0)
      let running = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
      let hold = OSAllocatedUnfairLock(initialState: false)
      let release = DispatchSemaphore(value: 0)
      /// What each call returns, by call number (1-based); later calls repeat the last.
      let answers: OSAllocatedUnfairLock<[CallMicrophoneWatcher.Reading]>

      init(_ answers: [CallMicrophoneWatcher.Reading] = [.init(complete: true, holders: [])]) {
        self.answers = OSAllocatedUnfairLock(initialState: answers)
      }

      func read() -> CallMicrophoneWatcher.Reading {
        let call = calls.withLock { n -> Int in
          n += 1
          return n
        }
        running.withLock { $0 = (now: $0.now + 1, most: max($0.most, $0.now + 1)) }
        defer { running.withLock { $0.now -= 1 } }
        // deadline-fallback: bound a missing release; the test fails on its own expectations
        if hold.withLock({ $0 }) { _ = release.wait(timeout: .now() + 10) }
        return answers.withLock { $0[min(call, $0.count) - 1] }
      }

      func letGo() {
        hold.withLock { $0 = false }
        release.signal()
      }

      /// Lets the held call return and keeps holding the next.
      func step() { release.signal() }
    }

    private static let zoom = CallMicrophoneWatcher.Holder(
      pid: 900_010, bundleID: "us.zoom.xos", input: .active, ownerPID: 900_010)
    private static let zoomTarget = CallSpeakerTarget(pid: 900_010, rule: .callWindow(.zoom))

    @Test("One source preserves policy continuity across a poll without relabelling old browser evidence for speakers")
    func separateConsumerFreshness() async {
      let first = MeetingCoordinatorTests.Gate()
      let second = MeetingCoordinatorTests.Gate()
      defer { first.open(); second.open() }
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let chrome = CallMicrophoneWatcher.Holder(
        pid: 900_030, bundleID: "com.google.chrome", input: .active, ownerPID: 900_030)
      let value = CallEvidenceReader.Snapshot(
        startEvidence: .call(family: .googleMeet, room: "bridge"),
        continuity: .ongoing(family: .googleMeet, room: "bridge"),
        owner: .init(pid: 900_030, bundleIdentifier: "com.google.Chrome",
          birthSeconds: 1, birthMicroseconds: 0))
      let sources = CallSourceDiscovery(dependencies: .init(snapshot: { _, _, _ in
        let count = reads.withLock { $0 += 1; return $0 }
        if count == 1 { await first.wait() }
        if count == 2 { await second.wait() }
        return value
      }, now: { Date(timeIntervalSince1970: 2_000_000) }, pollMicrophone: {}))
      defer { sources.shutDown() }
      sources.promptDemand = true
      sources.beginRecordingDemand()
      sources.deliverWatcherReading([chrome])
      await eventually("first browser read parked") { first.parked }
      sources.deliverWatcherReading([chrome])
      first.open()
      await eventually("current-frame read parked") { second.parked }
      let policy = sources.policyReading()
      #expect(policy.continuity.contains { $0.value == value.continuity && $0.owner == value.owner })
      #expect(policy.holders.first?.evidence == value.startEvidence)
      #expect(sources.speakerSource() == .unavailable, "the old read is not from the current microphone frame")
      second.open()
      await eventually("current-frame read completed") { !sources.evidenceReadPending }
      if case .unique(let source) = sources.speakerSource() {
        #expect(source.family == .googleMeet)
      } else { Issue.record("current-frame browser evidence did not restore speaker eligibility") }
    }

    @Test("Prompt restart rejects old policy work while the same recording-demanded source keeps speaker evidence")
    func promptEpochDoesNotStopSpeakers() async {
      let gate = MeetingCoordinatorTests.Gate()
      defer { gate.open() }
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let chrome = CallMicrophoneWatcher.Holder(
        pid: 900_030, bundleID: "com.google.chrome", input: .active, ownerPID: 900_030)
      let value = CallEvidenceReader.Snapshot(
        startEvidence: .call(family: .googleMeet, room: "bridge"),
        continuity: .ongoing(family: .googleMeet, room: "bridge"),
        owner: .init(pid: 900_030, bundleIdentifier: "com.google.Chrome",
          birthSeconds: 1, birthMicroseconds: 0))
      let sources = CallSourceDiscovery(dependencies: .init(snapshot: { _, _, _ in
        let count = reads.withLock { $0 += 1; return $0 }
        if count == 1 { await gate.wait() }
        return value
      }, now: { Date(timeIntervalSince1970: 2_000_000) }, pollMicrophone: {}))
      defer { sources.shutDown() }
      sources.promptDemand = true
      sources.beginRecordingDemand()
      sources.deliverWatcherReading([chrome])
      await eventually("pre-disable browser read parked") { gate.parked }
      sources.promptDemand = false
      #expect(sources.watching && sources.recordingDemandForTesting == 1)
      sources.promptDemand = true
      #expect(!sources.policyReading().complete, "enabling cannot reuse a pre-enable microphone frame")
      gate.open()
      await eventually("old query completed for the recording") { !sources.evidenceReadPending }
      #expect(sources.policyReading().continuity.isEmpty)
      #expect(!sources.policyReading().complete)
      if case .unique(let source) = sources.speakerSource() {
        #expect(source.family == .googleMeet, "strict-frame evidence remains usable by speaker capture")
      } else { Issue.record("prompt-only restart retired recording speaker evidence") }
      sources.deliverWatcherReading([chrome])
      await eventually("fresh enabled frame completed") { !sources.evidenceReadPending }
      #expect(sources.policyReading().complete)
      #expect(sources.policyReading().continuity.contains { $0.value == value.continuity })
    }

    @Test("a browser holding the microphone is a call only once its page reads as one")
    func browserNeedsItsPage() async throws {
      let chrome = CallMicrophoneWatcher.Holder(
        pid: 900_030, bundleID: "com.google.chrome", input: .active, ownerPID: 900_030)
      let page = OSAllocatedUnfairLock<CallEvidenceReader.Evidence>(initialState: .unknown)
      let sources = discovery(
        Scan([.init(complete: true, holders: [chrome])]),
        evidence: { _, _ in
          page.withLock { $0 }
        })
      defer { sources.shutDown() }
      sources.beginRecordingDemand()
      await sources.refreshNow()
      #expect(sources.speakerSource() == .unavailable, "an unread or unknown page decides nothing")
      page.withLock { $0 = .call(family: .googleMeet, room: "abc") }
      await sources.refreshNow()
      #expect(
        sources.speakerSource()
          == .unique(
            .init(
              family: .googleMeet, target: CallSpeakerTarget(pid: 900_030, rule: .browser(.chrome)))
          ))
      page.withLock { $0 = .none }
      await sources.refreshNow()
      #expect(sources.speakerSource() == .none, "a tab that is not a call")
    }

    private func discovery(
      _ scan: Scan,
      evidence:
        @escaping @Sendable (CallAppCatalog.Rule, Int32) async ->
        CallEvidenceReader.Evidence =
        { _, _ in .unknown }
    ) -> CallSourceDiscovery {
      CallSourceDiscovery(
        dependencies: .init(evidence: evidence, scan: { scan.read() }, listens: false))
    }

    private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
      #expect(await waitUntil(deadlineMs: 10_000, condition), "\(label)")
    }

    @Test("a slow read never builds a queue: asks meanwhile share exactly one more read")
    func oneScanAtATime() async throws {
      let scan = Scan()
      scan.hold.withLock { $0 = true }
      let sources = discovery(scan)
      defer { sources.shutDown() }
      sources.beginRecordingDemand()
      await eventually("first read started") { scan.calls.withLock { $0 } == 1 }
      for _ in 0..<5 { sources.noteWake() }
      var refreshed = false
      let refresh = Task { @MainActor in
        await sources.refreshNow()
        refreshed = true
      }
      await eventually("refresh waits for the read after it") {
        sources.waitingForNextScanForTesting == 1
      }
      #expect(scan.calls.withLock { $0 } == 1, "no second read while one runs")
      scan.step()
      await eventually("one follow-up read started") { scan.calls.withLock { $0 } == 2 }
      #expect(!refreshed, "the refresh waits for the follow-up read, not the one before it")
      scan.letGo()
      await refresh.value
      #expect(refreshed)
      #expect(scan.calls.withLock { $0 } == 2, "six asks during one read cost exactly one more")
    }

    @Test("a call app whose microphone use cannot be read makes the answer unavailable")
    func unreadableMicrophoneUse() async throws {
      func answer(_ holders: [CallMicrophoneWatcher.Holder]) async -> CallSpeakerSourceAnswer {
        let sources = discovery(Scan([.init(complete: true, holders: holders)]))
        defer { sources.shutDown() }
        sources.beginRecordingDemand()
        await sources.refreshNow()
        return sources.speakerSource()
      }
      func teams(_ input: CallMicrophoneWatcher.Input) -> CallMicrophoneWatcher.Holder {
        .init(pid: 900_020, bundleID: "com.microsoft.teams2", input: input, ownerPID: 900_020)
      }
      #expect(
        await answer([Self.zoom, teams(.unknown)]) == .unavailable, "it may be a second call")
      #expect(await answer([teams(.unknown)]) == .unavailable)
      #expect(
        await answer([Self.zoom, teams(.inactive)])
          == .unique(.init(family: .zoom, target: Self.zoomTarget)), "control")
    }

    @Test("a simulation survives prompts and recordings starting and stopping")
    func simulationSurvivesDemand() {
      let sources = discovery(Scan())
      defer { sources.shutDown() }
      sources.simulate([.init(holder: Self.zoom, evidence: .call(family: .zoom, room: "sim"))])
      sources.promptDemand = true
      sources.beginRecordingDemand()
      sources.repeatSimulation()
      #expect(sources.speakerSource() == .unique(.init(family: .zoom, target: Self.zoomTarget)))
      sources.endRecordingDemand()
      sources.promptDemand = false
      sources.repeatSimulation()
      #expect(sources.holders == [Self.zoom])
      #expect(!sources.watching)
    }

    @Test("a read from before a stop is never kept after a restart")
    func staleReadAfterRestart() async throws {
      let scan = Scan([
        .init(complete: true, holders: [Self.zoom]),
        .init(complete: true, holders: []),
      ])
      scan.hold.withLock { $0 = true }
      let sources = discovery(scan)
      defer { sources.shutDown() }
      var sawZoom = false
      sources.onChange = { if sources.holders.contains(Self.zoom) { sawZoom = true } }
      sources.beginRecordingDemand()
      await eventually("first read started") { scan.calls.withLock { $0 } == 1 }
      sources.endRecordingDemand()
      sources.beginRecordingDemand()
      scan.letGo()
      await eventually("the restart's own read landed") { scan.calls.withLock { $0 } >= 2 }
      await sources.refreshNow()
      #expect(!sawZoom, "the held read from before the stop was dropped")
      #expect(sources.speakerSource() == .none)
    }

    @Test("evidence reads stop when no one needs discovery any more")
    func evidenceRetiredOnStop() async throws {
      let second = CallMicrophoneWatcher.Holder(
        pid: 900_011, bundleID: "com.microsoft.teams2", input: .active, ownerPID: 900_011)
      let scan = Scan([.init(complete: true, holders: [Self.zoom, second])])
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let gate = AsyncStream<Void>.makeStream()
      let sources = discovery(
        scan,
        evidence: { _, _ in
          let n = reads.withLock { n -> Int in
            n += 1
            return n
          }
          if n == 1 { for await _ in gate.stream { break } }
          return .call(family: .zoom, room: "pid-900010")
        })
      defer { sources.shutDown() }
      var changes = 0
      sources.onChange = { changes += 1 }
      sources.beginRecordingDemand()
      await eventually("first evidence read parked") { reads.withLock { $0 } == 1 }
      let before = changes
      sources.endRecordingDemand()
      gate.continuation.yield()
      gate.continuation.finish()
      // settle: absence check; the parked read returns and must neither read on nor report
      try await Task.sleep(for: .milliseconds(200))
      #expect(reads.withLock { $0 } == 1, "the second holder is never read")
      #expect(changes == before, "nothing reported after the stop")
    }

    @Test("a simulation stops the real watcher, and quit stops everything")
    func simulationStopsRealWatcher() async throws {
      let scan = Scan()
      let sources = discovery(scan)
      sources.beginRecordingDemand()
      #expect(sources.watching)
      await eventually("first read") { scan.calls.withLock { $0 } >= 1 }
      sources.simulate([.init(holder: Self.zoom, evidence: .call(family: .zoom, room: "sim"))])
      #expect(!sources.watching, "the real watcher is off while simulated")
      let calls = scan.calls.withLock { $0 }
      sources.noteWake()
      // settle: absence check; a wake would poll a running watcher at once
      try await Task.sleep(for: .milliseconds(100))
      #expect(scan.calls.withLock { $0 } == calls)
      sources.shutDown()
      #expect(sources.simulation == nil)
      #expect(!sources.watching)
    }
  }
#endif
