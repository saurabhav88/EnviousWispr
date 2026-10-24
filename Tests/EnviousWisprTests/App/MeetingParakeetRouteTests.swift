import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #4052: when these fail, a Mac that dictates with Parakeet loads a second Parakeet for a
/// meeting transcript, a dictation records over a meeting decode on the same engine, the engine
/// stays locked after the transcript (dictation never comes back), or a transcript never starts.
@MainActor
@Suite("Meeting Parakeet route", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingParakeetRouteTests {

  static func selection(_ name: String) -> ParakeetModelSelection {
    ParakeetModelSelection(
      model: .ultra, revision: "r1",
      directory: URL(fileURLWithPath: "/tmp/meeting-route-\(name)", isDirectory: true),
      cacheOnly: true, displayBytes: 1, repairable: false, generation: 7)
  }

  static func key(_ selection: ParakeetModelSelection) -> String {
    MeetingModelUseGate.key(forInstallDirectory: selection.directory)
  }

  /// Dictation's side, faked at the boundary the route reads; the lease, the wake signal and
  /// the install gate are the real ones.
  @MainActor
  final class Rig {
    let lease = EngineLease()
    let wakes = MeetingWakeSignal()
    let gate = MeetingModelUseGate()
    var admitted = true
    var dictationIdle = true
    var selected: ASRBackendType = .parakeet
    var active: ASRBackendType = .parakeet
    var loaded = true
    var inFlight = false
    var published: ParakeetModelSelection? = MeetingParakeetRouteTests.selection("served")
    var ownSelection: ParakeetModelSelection? = MeetingParakeetRouteTests.selection("own")
    var readiness: MeetingParakeetRoute.Readiness = .ready
    var onEnsureReady: (@MainActor () -> Void)?
    var readyCalls = 0
    var sharedDecodes = 0
    var ownLoads: [ParakeetModelSelection] = []
    var ownDecodes = 0
    var ownUnloads = 0
    var disarms = 0
    var rearms = 0
    var holderAtRearm: SharedEngineHolder?
    var rechecks = 0
    var ownResidencyEnds = 0
    var claimHeldAtRecheck: Bool?
    static let meeting = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    var resolves = 0
    /// Runs on each resolve of the served model, after the count (a test changes it there).
    var onResolve: (@MainActor () -> Void)?
    lazy var sharedClaim = MeetingModelClaim(
      gate: gate,
      resolve: { [unowned self] in
        resolves += 1
        let answer = published
        onResolve?()
        return answer
      })
    var lines: [String] = []
    var clock = ContinuousClock.now

    func route() -> MeetingParakeetRoute {
      let route = makeRoute()
      route.beginPass(meetingID: Self.meeting, meetingSeconds: 3_600)
      return route
    }

    private func makeRoute() -> MeetingParakeetRoute {
      MeetingParakeetRoute(
        dependencies: .init(
          isAdmitted: { [unowned self] in admitted },
          isDictationIdle: { [unowned self] in dictationIdle },
          selectedBackend: { [unowned self] in selected },
          activeBackend: { [unowned self] in active },
          wakes: wakes,
          admission: .live(lease: lease, as: .meeting),
          ensureDictationReady: { [unowned self] in
            readyCalls += 1
            onEnsureReady?()
            return readiness
          },
          isModelLoaded: { [unowned self] in loaded },
          isLoadOrUnloadInFlight: { [unowned self] in inFlight },
          publishedSelection: { [unowned self] in published },
          transcribeShared: { [unowned self] samples in
            sharedDecodes += 1
            return Self.result(samples)
          },
          disarmEngineTimers: { [unowned self] in disarms += 1 },
          rearmEngineTimers: { [unowned self] in
            rearms += 1
            holderAtRearm = lease.currentHolder
          },
          recoveryRecheck: { [unowned self] in
            rechecks += 1
            claimHeldAtRecheck = sharedClaim.selection != nil
          },
          sharedClaim: sharedClaim,
          ownClaim: MeetingModelClaim(gate: gate, resolve: { [unowned self] in ownSelection }),
          ownLoad: { [unowned self] selection in ownLoads.append(selection) },
          ownTranscribe: { [unowned self] samples in
            ownDecodes += 1
            return Self.result(samples)
          },
          ownUnload: { [unowned self] in ownUnloads += 1 },
          ownWaitForAvailability: {},
          ownResidencyEnded: { [unowned self] in ownResidencyEnds += 1 },
          log: { [unowned self] line in lines.append(line) },
          now: { [unowned self] in clock }))
    }

    static func result(_ samples: [Float]) -> ASRResult {
      ASRResult(
        text: "w", language: nil, duration: Double(samples.count) / 16_000, processingTime: 0,
        backendType: .parakeet, wordTimings: nil)
    }
  }

  /// Runs `acquire()` in a task and returns once the subject reports it is parked in its
  /// `count`th wait (its own signal), so a release, switch or cancel after this proves the wake.
  private func startAcquire(_ route: MeetingParakeetRoute, waits count: Int = 1) async
    -> Task<Void, Error>
  {
    let task = Task { @MainActor in try await route.acquire() }
    let parked = await route.waitForWaitEnteredForTesting(count: count)
    #expect(parked, "acquire() never reached its wait")
    return task
  }

  static let id = Rig.meeting.uuidString

  @Test(
    "dictation on Parakeet: the pass borrows dictation's engine under the lease and loads no copy")
  func sharedRouteBorrowsAndReleases() async throws {
    let rig = Rig()
    let route = rig.route()
    try await route.acquire()
    #expect(route.route == .shared)
    #expect(rig.lease.currentHolder == .meeting)
    #expect(rig.disarms == 1)
    #expect(await rig.gate.isInUse(Self.key(rig.published!)))
    try await route.loadEngine()
    _ = try await route.transcribe([0, 0, 0])
    #expect(rig.sharedDecodes == 1)
    #expect(rig.ownLoads.isEmpty, "no second Parakeet on the shared route")
    #expect(route.isOwnParakeetResident == false)
    #expect(route.engineIdentity == "ultra:r1")

    rig.clock = rig.clock.advanced(by: .milliseconds(1_500))
    await route.unloadEngine()
    #expect(rig.lease.currentHolder == nil)
    #expect(rig.rearms == 1)
    #expect(rig.holderAtRearm == .meeting, "the timers are re-armed before the lease is freed")
    #expect(rig.rechecks == 1)
    #expect(rig.claimHeldAtRecheck == false, "the install claim is released before recovery's wake")
    #expect(await rig.gate.isInUse(Self.key(rig.published!)) == false)
    await route.endModelUse()
    #expect(rig.rearms == 1, "the release ran once")
    #expect(
      rig.lines == [
        "meeting engine route=shared claimed meeting=\(Self.id)",
        "meeting engine route=shared released meeting=\(Self.id) heldMs=1500",
        "meeting engine route=shared total meeting=\(Self.id) heldMs=1500 meetingSeconds=3600",
      ])
  }

  @Test("dictation on Whisper: the pass keeps its own Parakeet and never takes the lease")
  func ownRouteWhenDictationUsesWhisper() async throws {
    let rig = Rig()
    rig.selected = .whisper
    rig.active = .whisper
    let route = rig.route()
    try await route.acquire()
    #expect(route.route == .own)
    #expect(rig.lease.isBusy == false)
    #expect(rig.readyCalls == 0, "dictation's Whisper is never readied for a meeting")
    try await route.loadEngine()
    #expect(rig.ownLoads == [rig.ownSelection!])
    #expect(route.isOwnParakeetResident)
    _ = try await route.transcribe([0])
    #expect(rig.ownDecodes == 1)
    #expect(rig.sharedDecodes == 0)
    await route.unloadEngine()
    #expect(rig.ownUnloads == 1)
    #expect(route.isOwnParakeetResident, "resident until the claim is given back")
    await route.endModelUse()
    #expect(route.isOwnParakeetResident == false)
    #expect(await rig.gate.isInUse(Self.key(rig.ownSelection!)) == false)
  }

  @Test("a dictation holding the engine is waited for; its release wakes the pass")
  func waitsForDictationToRelease() async throws {
    let rig = Rig()
    guard case .granted(let dictation) = rig.lease.admit(.dictation) else {
      Issue.record("the rig's lease was already held")
      return
    }
    let route = rig.route()
    let task = await startAcquire(route)
    #expect(rig.lease.currentHolder == .dictation)
    #expect(route.route == nil)
    #expect(rig.readyCalls == 0, "nothing is readied while another workload holds the engine")
    rig.lease.release(dictation)
    rig.wakes.poke()
    try await task.value
    #expect(rig.lease.currentHolder == .meeting)
  }

  @Test("an engine switch in progress is waited for, then the route follows the new engine")
  func waitsForEngineSwitch() async throws {
    let rig = Rig()
    rig.selected = .whisper
    let route = rig.route()
    let task = await startAcquire(route)
    #expect(route.route == nil)
    rig.active = .whisper
    rig.wakes.poke()
    try await task.value
    #expect(route.route == .own)
  }

  @Test("waiting for a dictation reports Paused while you dictate, then clears it")
  func reportsDictationWait() async throws {
    let rig = Rig()
    rig.admitted = false
    rig.dictationIdle = false
    let route = rig.route()
    var reports: [Bool] = []
    route.onWaitingForDictation = { reports.append($0) }
    let task = await startAcquire(route)
    #expect(reports == [true])
    rig.admitted = true
    rig.dictationIdle = true
    rig.wakes.poke()
    try await task.value
    #expect(reports == [true, false])
  }

  @Test("waiting only for a summary call is not reported as a dictation pause")
  func summaryWaitIsNotADictationPause() async throws {
    let rig = Rig()
    rig.admitted = false  // a local summary call is running; dictation is idle
    let route = rig.route()
    var reports: [Bool] = []
    route.onWaitingForDictation = { reports.append($0) }
    let task = await startAcquire(route)
    #expect(reports.isEmpty)
    // A dictation starts during the wait: now it is reported, then cleared when it ends.
    rig.dictationIdle = false
    rig.wakes.poke()
    #expect(await route.waitForWaitEnteredForTesting(count: 2))
    #expect(reports == [true])
    rig.dictationIdle = true
    rig.admitted = true
    rig.wakes.poke()
    try await task.value
    #expect(reports == [true, false])
  }

  @Test("a cancel while waiting ends acquisition with nothing held")
  func cancelWhileWaiting() async throws {
    let rig = Rig()
    _ = rig.lease.admit(.fileImport)
    let route = rig.route()
    let task = await startAcquire(route)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(rig.lease.currentHolder == .fileImport)
    #expect(route.route == nil)
    #expect(rig.disarms == 0)
  }

  @Test("a cancel while the install claim waits behind a model change ends with nothing held")
  func cancelWhileInstallGateWaits() async throws {
    let rig = Rig()
    // A delivery change of the served install holds its gate; the claim must wait for it.
    try await rig.gate.beginMutation(Self.key(rig.published!))
    let route = rig.route()
    let task = Task { @MainActor in try await route.acquire() }
    #expect(await rig.gate.waitForParkedUseForTesting(), "the claim parked in the install gate")
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(rig.lease.admissionEpoch == 0, "no lease taken while waiting on the install")
    #expect(await rig.gate.isInUse(Self.key(rig.published!)) == false)
    await rig.gate.endMutation(Self.key(rig.published!))
  }

  @Test("the served model changing between readiness and the claim is retried on the new model")
  func servedModelChangesBeforeTheClaim() async throws {
    let rig = Rig()
    let next = Self.selection("upgraded")
    // The claim resolves twice per attempt. Right after its second resolve answers, the served
    // model changes (an engine reload), so the claim holds the old one and the final check sees
    // a mismatch once.
    rig.onResolve = { [unowned rig] in
      if rig.resolves == 2 { rig.published = next }
    }
    let route = rig.route()
    try await route.acquire()
    #expect(rig.lease.currentHolder == .meeting)
    #expect(rig.sharedClaim.selection == next, "the claim protects the model actually served")
    #expect(rig.readyCalls == 2)
    #expect(await rig.gate.isInUse(Self.key(next)))
  }

  @Test("the own route counts as resident from its choice to its release, not only once loaded")
  func ownResidencyCoversAcquisitionLoadAndDecode() async throws {
    let rig = Rig()
    rig.selected = .whisper
    rig.active = .whisper
    let own = Self.key(rig.ownSelection!)
    try await rig.gate.beginMutation(own)  // the own install's gate is busy: the claim waits
    let route = rig.route()
    let task = Task { @MainActor in try await route.acquire() }
    #expect(await rig.gate.waitForParkedUseForTesting())
    #expect(route.isOwnParakeetResident, "held while the own claim waits")
    await rig.gate.endMutation(own)
    try await task.value
    #expect(route.isOwnParakeetResident)
    try await route.loadEngine()
    _ = try await route.transcribe([0])
    await route.unloadEngine()
    #expect(route.isOwnParakeetResident, "until the claim is given back")
    await route.endModelUse()
    #expect(route.isOwnParakeetResident == false)
  }

  @Test("a switch to Parakeet requested while the own claim waits hands the pass to the shared route")
  func switchDuringOwnAcquisitionGoesShared() async throws {
    let rig = Rig()
    rig.selected = .whisper
    rig.active = .whisper
    let own = Self.key(rig.ownSelection!)
    try await rig.gate.beginMutation(own)
    let route = rig.route()
    let task = Task { @MainActor in try await route.acquire() }
    #expect(await rig.gate.waitForParkedUseForTesting())
    // The user picks Parakeet; gate 6d holds the switch while the meeting is resident.
    rig.selected = .parakeet
    await rig.gate.endMutation(own)
    #expect(await route.waitForWaitEnteredForTesting(), "back in step 1, waiting for the switch")
    #expect(route.isOwnParakeetResident == false, "the own copy was given back")
    #expect(rig.ownResidencyEnds == 1, "the held switch was woken")
    #expect(await rig.gate.isInUse(own) == false)
    // The switch completes and pokes the meeting.
    rig.active = .parakeet
    rig.wakes.poke()
    try await task.value
    #expect(route.route == .shared)
    #expect(rig.lease.currentHolder == .meeting)
  }

  @Test("readiness failing is terminal and takes no lease")
  func readinessFailureTakesNothing() async throws {
    let rig = Rig()
    rig.readiness = .notReady
    let route = rig.route()
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_not_ready")) {
      try await route.acquire()
    }
    #expect(rig.lease.admissionEpoch == 0)
    #expect(rig.disarms == 0)
    #expect(rig.rearms == 0)
  }

  @Test("a load or unload that keeps running is waited for, however long, and never fails the pass")
  func longInFlightWorkIsWaitedFor() async throws {
    let rig = Rig()
    rig.inFlight = true
    let route = rig.route()
    let task = await startAcquire(route)
    // Parked in the in-flight wait with the install claim given back and no lease.
    #expect(rig.lease.admissionEpoch == 0)
    #expect(await rig.gate.isInUse(Self.key(rig.published!)) == false)
    // More wakes while the work still runs do not end the wait or count as failures. A
    // negative has no signal of its own: after the wakes, a few turns, then nothing changed.
    rig.wakes.poke()
    rig.wakes.poke()
    for _ in 0..<20 { await Task.yield() }
    #expect(rig.lease.admissionEpoch == 0)
    #expect(rig.readyCalls == 1, "the wait did not end and start another attempt")
    rig.inFlight = false
    rig.wakes.poke()
    try await task.value
    #expect(rig.lease.currentHolder == .meeting)
    #expect(rig.lease.admissionEpoch == 1, "the lease was taken once, after the in-flight work")
  }

  @Test("a cancel while waiting for in-flight work ends with nothing held")
  func cancelDuringInFlightWait() async throws {
    let rig = Rig()
    rig.inFlight = true
    let route = rig.route()
    let task = await startAcquire(route)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(rig.lease.admissionEpoch == 0)
    #expect(await rig.gate.isInUse(Self.key(rig.published!)) == false)
  }

  @Test("a served model that keeps disappearing fails the pass after two tries, holding nothing")
  func unstablePublicationIsBounded() async throws {
    let rig = Rig()
    rig.loaded = false
    let route = rig.route()
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_unstable")) {
      try await route.acquire()
    }
    #expect(rig.readyCalls == 2)
    #expect(rig.lease.admissionEpoch == 0)
    #expect(await rig.gate.isInUse(Self.key(rig.published!)) == false)
  }

  @Test("no installed model is terminal and holds nothing")
  func noPublishedModel() async throws {
    let rig = Rig()
    rig.published = nil
    let route = rig.route()
    await #expect(throws: MeetingTranscriptionJob.JobError.self) { try await route.acquire() }
    #expect(rig.lease.admissionEpoch == 0)
  }

  @Test("a failed load reaches endModelUse alone, which still gives the engine back once")
  func endModelUseReleasesWithoutUnload() async throws {
    let rig = Rig()
    let route = rig.route()
    try await route.acquire()
    await route.endModelUse()
    #expect(rig.lease.currentHolder == nil)
    #expect(rig.rearms == 1)
    #expect(rig.rechecks == 1)
    await route.endModelUse()
    #expect(rig.rearms == 1)
  }

  @Test("a second residency in one pass re-acquires and both holds are summed")
  func intervalsAreSummed() async throws {
    let rig = Rig()
    let route = rig.route()
    try await route.acquire()
    rig.clock = rig.clock.advanced(by: .milliseconds(200))
    await route.unloadEngine()
    // Memory pressure: the job ends model use and later acquires again.
    await route.endModelUse()
    try await route.acquire()
    rig.clock = rig.clock.advanced(by: .milliseconds(300))
    await route.unloadEngine()
    await route.endModelUse()
    #expect(
      rig.lines.last
        == "meeting engine route=shared total meeting=\(Self.id) heldMs=500 meetingSeconds=3600")
    #expect(rig.lines.filter { $0.contains("released") }.count == 2)
  }
}
