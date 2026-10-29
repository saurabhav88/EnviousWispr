import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Which call apps hold the microphone now, and what each one's window or page shows (#4013
/// 13B, from #4012's call detection). The one owner of the microphone watcher and its evidence
/// reads: call prompts (`CallDetectionCoordinator`) and a recording's speaker capture both read
/// from it, so there is never a second poller.
///
/// It watches while anyone needs it: call prompts are on, or a meeting records (whatever
/// started it). With neither, no watcher, no polling and no Accessibility reads run. Readings
/// come from the watcher's own queue; evidence reads run one at a time off the main actor, each
/// for the reading that started it (C2). A limb: when anything here fails, recording and
/// dictation go on unchanged.
@MainActor
final class CallSourceDiscovery {
  struct Dependencies {
    /// The evidence for one holder, read off the main actor with its own bound.
    var evidence: @Sendable (CallAppCatalog.Rule, Int32) async -> CallEvidenceReader.Evidence
    /// Seconds since the Mac started, as a Date (`CallDetectionCoordinator.Dependencies.now`).
    var now: @MainActor () -> Date = {
      Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }
    /// One whole microphone reading, off the main actor; nil reads Core Audio (tests stand in).
    var scan: CallMicrophoneWatcher.Scan?
  }

  /// Seconds between polls while a call may be on; without the process-list listener, between
  /// every poll.
  static let pollInterval: TimeInterval = 2
  static let unlistenedPollInterval: TimeInterval = 10

  private let deps: Dependencies
  private lazy var watcher = CallMicrophoneWatcher(
    candidateBundleID: { bundle, path in Self.callBundleID(bundle: bundle, executablePath: path) },
    mayBeCandidate: { CallAppCatalog.mayBeCallApp(bundleID: $0) },
    // The owning app is read with the reading, off the main actor, so a speaker tick only looks.
    owner: { CallSpeakerTarget.owner(ofHolder: $0) },
    scan: deps.scan,
    onReading: { [weak self] reading in self?.received(reading) })
  /// Bumped whenever discovery stops: evidence reads from before it apply and report nothing.
  private var lifecycle = 0
  private var timer: Timer?
  private(set) var watching = false

  /// Call prompts are on (`CallDetectionCoordinator`).
  var promptDemand = false {
    didSet { if promptDemand != oldValue { updateWatching() } }
  }
  /// Recordings that read their call's speakers, one per running recording.
  private var recordingDemand = 0
  /// Asked every tick by the prompt policy: keep polling while it tracks a call.
  var keepPolling: @MainActor () -> Bool = { false }
  /// Told after every new reading and every applied evidence read.
  var onChange: @MainActor () -> Void = {}

  /// The last watcher reading, as it came.
  private(set) var holders: [CallMicrophoneWatcher.Holder] = [] {
    didSet { noteSpeakerSources() }
  }
  private(set) var complete = false {
    didSet { noteSpeakerSources() }
  }
  private(set) var ambiguous = false {
    didSet { noteSpeakerSources() }
  }
  private(set) var takenAt = Date.distantPast
  /// Goes up with every reading; evidence counts only with the reading it was read for.
  private(set) var sequence = 0
  private var lastPoll = Date.distantPast
  /// The last evidence per process, with the process run it was read for and the reading it
  /// belongs to. It counts only with that reading: a later reading waits for its own read, so
  /// an answer about an earlier page never meets a newer microphone reading (C2).
  private var evidence:
    [Int32: (
      holder: CallMicrophoneWatcher.Holder, value: CallEvidenceReader.Evidence, reading: Int
    )] =
      [:]
  {
    didSet { noteSpeakerSources() }
  }
  /// The evidence read running now; `refreshNow` waits for it.
  private var evidenceTask: Task<Void, Never>?
  private var rereadWanted = false

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  // MARK: - Demand

  /// A recording's speaker capture needs sources; pair with `endRecordingDemand()`.
  func beginRecordingDemand() {
    recordingDemand += 1
    if recordingDemand == 1 { updateWatching() }
    // A recording reads its source at once, not at the next poll.
    if watching { pollNow() }
  }

  func endRecordingDemand() {
    guard recordingDemand > 0 else { return }
    recordingDemand -= 1
    if recordingDemand == 0 { updateWatching() }
  }

  private var wanted: Bool {
    (promptDemand || recordingDemand > 0) && CallMicrophoneWatcher.isSupported
  }

  private func updateWatching() {
    #if DEBUG
      // A simulation owns the readings: the real watcher stays off until it is cleared.
      if simulation != nil {
        stopReal()
        return
      }
    #endif
    if wanted == watching {
      // Prompts turned on while a recording already watches: read now, as a fresh start would.
      if watching { pollNow() }
      return
    }
    if wanted {
      watching = true
      watcher.start()
      startTimer()
    } else {
      stopReal()
    }
  }

  /// Stops the watcher, its timer and any evidence read, and forgets the last reading.
  private func stopReal() {
    lifecycle += 1
    evidenceTask = nil
    rereadWanted = false
    if watching { watcher.stop() }
    watching = false
    timer?.invalidate()
    timer = nil
    holders = []
    evidence = [:]
    complete = false
  }

  private func startTimer() {
    guard timer == nil else { return }
    let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(clock, forMode: .common)
    timer = clock
  }

  /// App quit: the watcher and its timer go away.
  func shutDown() {
    promptDemand = false
    recordingDemand = 0
    #if DEBUG
      simulation = nil
    #endif
    stopReal()
  }

  /// Wake from sleep: read again at once.
  func noteWake() {
    if watching { pollNow() }
  }

  // MARK: - Readings

  private func tick() {
    guard watching else { return }
    let mayBeOn = !holders.isEmpty || !complete || keepPolling() || recordingDemand > 0
    let interval = watcher.isListening ? Self.pollInterval : Self.unlistenedPollInterval
    // No poll while an evidence read runs: the read belongs to the reading that started it,
    // so a reading and its evidence stay together (C2).
    // Every poll reads the evidence afresh: a tab switched to a meeting while the microphone
    // stays on is seen, and an unknown read is retried (review r4 F2).
    if evidenceTask == nil, mayBeOn || !watcher.isListening,
      deps.now().timeIntervalSince(lastPoll) >= interval
    {
      pollNow()
    }
  }

  private func pollNow() {
    // Counted from the ask, so a slow read is not asked for again on every tick.
    lastPoll = deps.now()
    watcher.poll()
  }

  private func received(_ reading: CallMicrophoneWatcher.Reading, injected: Bool = false) {
    #if DEBUG
      // A dev-control simulation owns the readings until it is cleared.
      guard simulation == nil else { return }
    #endif
    // A reading that lands after the watcher stopped is not kept.
    guard watching || injected else { return }
    lastPoll = deps.now()
    record(holders: reading.holders, complete: reading.complete, ambiguous: reading.ambiguous)
    readEvidence()
    onChange()
  }

  private func record(holders list: [CallMicrophoneWatcher.Holder], complete: Bool, ambiguous: Bool)
  {
    sequence += 1
    #if DEBUG
      // A simulation's evidence is part of its standing reading.
      if simulation != nil { evidence = evidence.mapValues { ($0.holder, $0.value, sequence) } }
    #endif
    takenAt = deps.now()
    self.complete = complete
    self.ambiguous = ambiguous
    holders = list
    if complete {
      evidence = evidence.filter { _, read in list.contains { Self.sameProcess($0, read.holder) } }
    }
  }

  /// The evidence for `holder` read for the current reading, or nil when none was.
  func currentEvidence(for holder: CallMicrophoneWatcher.Holder) -> CallEvidenceReader.Evidence? {
    evidence[holder.pid].flatMap {
      Self.sameProcess($0.holder, holder) && $0.reading == sequence ? $0.value : nil
    }
  }

  /// Reads the evidence for every holder whose microphone is on or whose last read was unknown,
  /// one at a time; each result applies only while its process is still listed.
  private func readEvidence() {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard evidenceTask == nil else {
      rereadWanted = true
      return
    }
    let targets = holders.filter { holder in
      holder.input == .active || evidence[holder.pid]?.value == .unknown
    }
    guard !targets.isEmpty else { return }
    let read = deps.evidence
    let forReading = sequence
    let started = lifecycle
    evidenceTask = Task {
      var fresh: [Int32: (CallMicrophoneWatcher.Holder, CallEvidenceReader.Evidence)] = [:]
      for holder in targets {
        // Discovery stopped meanwhile: no more reads, nothing applied or reported.
        guard self.lifecycle == started else { return }
        guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
        fresh[holder.pid] = (holder, await read(rule, holder.pid))
      }
      guard self.lifecycle == started else { return }
      // The answers belong to the reading they were read for (C2): a newer reading that came
      // meanwhile (the process list changed) gets its own read instead, and a process that
      // left, or a new run of it under the same pid, never gets these.
      if self.sequence == forReading {
        for (pid, read) in fresh
        where self.holders.contains(where: { Self.sameProcess($0, read.0) }) {
          self.evidence[pid] = (read.0, read.1, forReading)
        }
      } else {
        self.rereadWanted = true
      }
      self.evidenceTask = nil
      self.onChange()
      if self.rereadWanted {
        self.rereadWanted = false
        // An overdue microphone poll goes first (it starts its own read): reads never keep the
        // microphone from being checked.
        if self.watching, self.deps.now().timeIntervalSince(self.lastPoll) >= Self.pollInterval {
          self.pollNow()
        } else {
          self.readEvidence()
        }
      }
    }
  }

  /// A fresh microphone poll and the evidence reads it starts, finished: a Yes and a switch
  /// act on what the call shows now, not on a read from before (review r4 F3, r12 F1).
  func refreshNow() async {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard watching else { return }
    // A read already running belongs to an older reading: let it finish first.
    if let running = evidenceTask { await running.value }
    lastPoll = deps.now()
    await watcher.pollAndWait()
    // The reads for this poll, and at most one more if the process list changed meanwhile:
    // never an open-ended wait.
    for _ in 0..<2 {
      guard let running = evidenceTask else { break }
      await running.value
    }
  }

  nonisolated static func sameProcess(
    _ a: CallMicrophoneWatcher.Holder, _ b: CallMicrophoneWatcher.Holder
  ) -> Bool {
    a.pid == b.pid && a.bundleID == b.bundleID && a.object == b.object
  }

  // MARK: - Speaker sources

  /// #4013 chunk 13A: goes up whenever the active microphone holders, the call a browser
  /// holder's page reads as, or whether the reading was complete and unambiguous change; a new
  /// reading of the same holders leaves it alone. Speaker capture drops a copy taken across a
  /// change, even one that changed back.
  private(set) var speakerSourceRevision = 0
  private var speakerSources: Set<String> = []

  private func noteSpeakerSources() {
    // Whether the reading may name a source at all is part of what changed.
    var sources: Set<String> = ["complete=\(complete) ambiguous=\(ambiguous)"]
    for holder in holders where holder.input == .active {
      var page = ""
      if case .call(let family, _)? = evidence[holder.pid]?.value { page = "\(family)" }
      sources.insert("\(holder.pid)|\(holder.bundleID)|\(page)")
    }
    guard sources != speakerSources else { return }
    speakerSources = sources
    speakerSourceRevision += 1
  }

  /// #4013 chunk 13A: the one app instance a meeting's speaker capture reads for `family`, from
  /// the microphone holders of the last reading: a call app of that family, or a browser whose
  /// page reads as that family's call. `nil` when there is none, more than one app instance
  /// (two calls, or two copies of one browser), or the reading itself was incomplete or
  /// ambiguous: the capture then reads nothing, never a guess.
  func speakerTarget(for family: CallAppFamily) -> CallSpeakerTarget? {
    guard complete, !ambiguous else { return nil }
    var owners: [pid_t: CallAppCatalog.Rule] = [:]
    for holder in holders where holder.input == .active {
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
      let matches: Bool
      switch rule {
      case .callApp(let ruleFamily), .callWindow(let ruleFamily): matches = ruleFamily == family
      case .browser:
        if case .call(let pageFamily, _)? = evidence[holder.pid]?.value {
          matches = pageFamily == family
        } else {
          matches = false
        }
      }
      guard matches, let owner = holder.ownerPID else { continue }
      owners[owner] = rule
    }
    guard owners.count == 1, let (pid, rule) = owners.first else { return nil }
    return CallSpeakerTarget(pid: pid, rule: rule)
  }

  // MARK: - Dev control (DEBUG)

  #if DEBUG
    /// One faked microphone holder and the evidence its read returns (`call.simulate`).
    struct SimulatedHolder {
      let holder: CallMicrophoneWatcher.Holder
      let evidence: CallEvidenceReader.Evidence
    }

    /// While set, these replace the watcher's readings and the Accessibility reads.
    private(set) var simulation: [SimulatedHolder]?

    func simulate(_ list: [SimulatedHolder]?) {
      simulation = list
      if let list {
        // The real watcher stops while a simulation owns the readings.
        stopReal()
        evidence = Dictionary(
          list.map { ($0.holder.pid, ($0.holder, $0.evidence, sequence)) },
          uniquingKeysWith: { a, _ in a })
        record(holders: list.map(\.holder), complete: true, ambiguous: false)
      } else {
        holders = []
        evidence = [:]
        complete = false
        // Back to the real microphone; its next reading is the next change.
        updateWatching()
        if watching { pollNow() }
        return
      }
      onChange()
    }

    /// A simulation is a standing reading, taken again every policy tick.
    func repeatSimulation() {
      guard simulation != nil else { return }
      record(holders: holders, complete: true, ambiguous: false)
    }

    /// Hands discovery a watcher reading (nil: the read failed), through the same path as the
    /// real watcher, evidence reads included. Tests only.
    func deliverWatcherReading(
      _ list: [CallMicrophoneWatcher.Holder]?, ambiguous: Bool = false
    ) {
      received(
        list.map { .init(complete: true, holders: $0, ambiguous: ambiguous) } ?? .failed,
        injected: true)
    }

    var recordingDemandForTesting: Int { recordingDemand }
  #endif

  // MARK: - Helpers

  /// The bundle identifier the catalog knows for a microphone-holding process: its own, or for
  /// a helper without one, its owning app's (§3.2).
  nonisolated static func callBundleID(bundle: String, executablePath: String?) -> String? {
    if !bundle.isEmpty, CallAppCatalog.rule(forBundleID: bundle) != nil {
      return bundle.lowercased()
    }
    guard let path = executablePath, let app = CallAppCatalog.owningAppPath(ofExecutable: path),
      let owner = Bundle(path: app)?.bundleIdentifier,
      CallAppCatalog.rule(forBundleID: owner) != nil
    else { return nil }
    return owner.lowercased()
  }
}
