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
/// come from the watcher's own queue; evidence reads run one at a time off the main actor.
/// Speakers require the exact starting frame (C2); policy continuity has independent scope and
/// freshness. A limb: when anything here fails, recording and
/// dictation go on unchanged.
@MainActor
final class CallSourceDiscovery {
  typealias SnapshotRead = @Sendable (CallAppCatalog.Rule, Int32, CallEvidenceReader.RetainedTarget?) async -> CallEvidenceReader.Snapshot

  struct Dependencies {
    var snapshot: SnapshotRead
    var now: @MainActor () -> Date
    var scan: CallMicrophoneWatcher.Scan?
    var listens: Bool
    /// Controlled frames without real hardware, used by the existing coordinator fixtures.
    var pollMicrophone: (@MainActor () -> Void)?

    init(snapshot: @escaping SnapshotRead,
      now: @escaping @MainActor () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) },
      scan: CallMicrophoneWatcher.Scan? = nil, listens: Bool = true,
      pollMicrophone: (@MainActor () -> Void)? = nil) {
      self.snapshot = snapshot
      self.now = now
      self.scan = scan
      self.listens = listens
      self.pollMicrophone = pollMicrophone
    }

    /// Legacy Evidence-only fixtures feed the same engine, without inventing continuity/owners.
    init(evidence: @escaping @Sendable (CallAppCatalog.Rule, Int32) async -> CallEvidenceReader.Evidence,
      now: @escaping @MainActor () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) },
      scan: CallMicrophoneWatcher.Scan? = nil, listens: Bool = true) {
      self.init(snapshot: { rule, pid, retained in
        guard retained == nil else { return .init(startEvidence: .unknown) }
        return .init(startEvidence: await evidence(rule, pid))
      }, now: now, scan: scan, listens: listens)
    }
  }

  static let pollInterval: TimeInterval = 1
  static let unlistenedPollInterval: TimeInterval = 10

  private let deps: Dependencies
  private lazy var watcher = CallMicrophoneWatcher(
    candidateBundleID: { bundle, path in Self.callBundleID(bundle: bundle, executablePath: path) },
    mayBeCandidate: { CallAppCatalog.mayBeCallApp(bundleID: $0) },
    // The owning app is read with the reading, off the main actor, so a speaker tick only looks.
    owner: { CallSpeakerTarget.owner(ofHolder: $0, bundleID: $1) },
    scan: deps.scan,
    listens: deps.listens,
    onReading: { [weak self] reading in self?.received(reading) })
  private var timer: Timer?
  private(set) var watching = false

  var promptDemand = false {
    didSet {
      guard promptDemand != oldValue else { return }
      invalidatePolicyProjection()
      updateWatching()
      onChange()
    }
  }
  private var recordingDemand = 0
  var keepPolling: @MainActor () -> Bool = { false }
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
  /// Goes up with every microphone reading; speaker evidence stays exact-frame.
  private(set) var sequence = 0
  private var lastPoll = Date.distantPast
  private struct CachedEvidence {
    let holder: CallMicrophoneWatcher.Holder
    let value: CallEvidenceReader.Evidence
    var reading: Int
    var source: CallDetectionPolicy.Source? = nil
    var activityRevision = 0
    var beganAt = Date.distantPast
    var policyEpoch = 0
  }
  fileprivate struct SourceState {
    var holder: CallMicrophoneWatcher.Holder
    var source: CallDetectionPolicy.Source
    var activityRevision = 0
    var present = true
    /// Historical query address after wake; never a fabricated microphone/start fact.
    var retainedAfterWake = false
    var owner: CallEvidenceReader.AppRun? = nil
    var knownCalls: [CallEvidenceReader.RetainedTarget] = []
  }
  fileprivate struct ReadTarget {
    let state: SourceState
    let retained: CallEvidenceReader.RetainedTarget?
    var key: RequestKey { .init(sourceID: state.source.id, retained: retained) }
  }
  fileprivate struct RequestKey: Equatable {
    let sourceID: Int
    let retained: CallEvidenceReader.RetainedTarget?
  }
  struct RefreshRequest {
    let target: CallDetectionPolicy.RefreshTarget
    fileprivate let read: ReadTarget?
  }
  private var evidence: [Int32: CachedEvidence] = [:] { didSet { noteSpeakerSources() } }
  private var sources: [Int32: SourceState] = [:]
  /// These survive microphone polls and absence; no cached observation is re-dated.
  private var continuity: [CallDetectionPolicy.ContinuityObservation] = []
  private var pendingSources: [CallDetectionPolicy.Source] = []
  private var nextSourceID = 0
  private var nextObservationID = 0
  private var readLifetime = 0
  private var nextReadID = 0
  private var currentReadID: Int?
  private var readStopped = false
  private var refreshInProgress = false
  private var cycle: [ReadTarget] = []
  private var cycleWanted = false
  private var lastCycleStart: RequestKey?
  /// The evidence read running now; `refreshNow` waits for it.
  private var evidenceTask: Task<Void, Never>?
  private var policyEpoch = 0
  private var minimumPolicySequence = 0
  /// Collection is shared; these callbacks only query policy tracking/interaction ownership.
  var tracksRule: @MainActor (CallAppCatalog.Rule) -> Bool = { _ in false }
  var tracksTarget: @MainActor (CallEvidenceReader.RetainedTarget) -> Bool = { _ in false }
  var isCurrentTarget: @MainActor (CallDetectionPolicy.RefreshTarget) -> Bool = { _ in false }
  var hasQueuedPress: @MainActor () -> Bool = { false }
  /// A projection changes without running policy commands reentrantly inside a read launch.
  var onProjectionChange: @MainActor () -> Void = {}

  private func isTrackingRule(_ rule: CallAppCatalog.Rule) -> Bool { promptDemand && tracksRule(rule) }
  private func isTrackingTarget(_ target: CallEvidenceReader.RetainedTarget) -> Bool {
    promptDemand && tracksTarget(target)
  }

  /// Prompt eligibility has a separate epoch from collection demanded by a recording.
  private func invalidatePolicyProjection() {
    policyEpoch += 1
    minimumPolicySequence = sequence + 1
    continuity = []
    pendingSources = []
    refreshInProgress = false
    observe()
  }

  /// Reading lifetime is independent of microphone-frame sequence. A cancelled bounded read
  /// retains its task slot until it really returns; no new AX work is piled behind it.
  private func invalidateSharedWork() {
    readLifetime += 1
    evidenceTask?.cancel()
    cycleWanted = false
    cycle = []
    lastCycleStart = nil
    pendingSources = []
    refreshInProgress = false
  }

  private func updateReadLifetime() -> Bool { !readStopped }
  private func observe() { onProjectionChange() }

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
      // A simulation owns the readings: the real watcher stays off until it is cleared, and its
      // standing reading is kept.
      if simulation != nil {
        stopCollecting()
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
      readStopped = false
      if deps.pollMicrophone == nil { watcher.start() }
      startTimer()
    } else {
      stopReal()
    }
  }

  /// Stops the watcher, its timer and any evidence read, and forgets the last reading.
  private func stopReal() {
    stopCollecting()
    holders = []
    evidence = [:]
    sources = [:]
    continuity = []
    pendingSources = []
    complete = false
    ambiguous = false
    takenAt = .distantPast
    observe()
  }

  /// Stops the watcher, its timer and any evidence read; the last reading stays.
  private func stopCollecting() {
    readStopped = true
    invalidateSharedWork()
    if watching { watcher.stop() }
    watching = false
    timer?.invalidate()
    timer = nil
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
    invalidatePolicyProjection()
    // Historical addresses survive wake, never microphone activity or completed proof.
    // Keep the raw speaker frame separate rather than pretending its holders disappeared.
    for pid in Array(sources.keys) {
      guard var state = sources[pid], let owner = state.owner else { continue }
      state.knownCalls = state.knownCalls.filter {
        $0.owner == owner && $0.rule == state.source.rule && $0.holderPID == state.source.pid
          && isTrackingTarget($0)
      }
      state.retainedAfterWake = !state.knownCalls.isEmpty
      sources[pid] = state
    }
    readEvidence()
    if watching { pollNow() }
  }

  // MARK: - Readings

  private func tick() {
    guard watching else { return }
    let mayBeOn = !holders.isEmpty || !complete || ambiguous || keepPolling() || recordingDemand > 0
    let interval = mayBeOn ? Self.pollInterval : Self.unlistenedPollInterval
    // Microphone facts keep moving during UI work; the faster presentation tick does not
    // itself request AX work. Even listener-backed no-call checks remain conservative.
    if deps.now().timeIntervalSince(lastPoll) >= interval { pollNow() }
  }

  private func pollNow() {
    // Counted from the ask, so a slow read is not asked for again on every tick.
    lastPoll = deps.now()
    if let poll = deps.pollMicrophone { poll() } else { watcher.poll() }
  }

  private func pollAndWait() async {
    lastPoll = deps.now()
    if let poll = deps.pollMicrophone { poll() } else { await watcher.pollAndWait() }
  }

  private func received(_ reading: CallMicrophoneWatcher.Reading, injected: Bool = false) {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard watching || injected else { return }
    if injected { readStopped = false }
    lastPoll = deps.now()
    record(holders: reading.holders, complete: reading.complete, ambiguous: reading.ambiguous)
    readEvidence()
    onChange()
  }

  /// Keeps a reading and hands it to the policy with the evidence of its processes.
  private func record(holders list: [CallMicrophoneWatcher.Holder], complete: Bool, ambiguous: Bool)
  {
    sequence += 1
    #if DEBUG
      // A simulation's evidence is part of its standing reading.
      if simulation != nil {
        evidence = evidence.mapValues { cached in
          var standing = cached
          standing.reading = sequence
          return standing
        }
      }
    #endif
    takenAt = deps.now()
    self.complete = complete
    self.ambiguous = ambiguous
    holders = list
    var seen: Set<Int32> = []
    for holder in list {
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
      seen.insert(holder.pid)
      if var state = sources[holder.pid], Self.sameProcess(state.holder, holder) {
        if !state.present || state.holder.input != holder.input { state.activityRevision += 1 }
        state.holder = holder
        state.present = true
        state.retainedAfterWake = false
        sources[holder.pid] = state
      } else {
        if let previous = sources[holder.pid] {
          publishContinuity(.unknown, owner: nil, for: previous.source, beganAt: deps.now())
        }
        nextSourceID += 1
        sources[holder.pid] = .init(holder: holder,
          source: .init(id: nextSourceID, pid: holder.pid, rule: rule))
      }
    }
    if complete {
      evidence = evidence.filter { _, read in list.contains { Self.sameProcess($0, read.holder) } }
      for pid in Array(sources.keys) where !seen.contains(pid) {
        guard var state = sources[pid] else { continue }
        if state.present { state.activityRevision += 1 }
        state.present = false
        sources[pid] = state
      }
      // Hold the last independent observation for tracked calls, not for every past process.
      sources = sources.filter { seen.contains($0.key) || isTrackingRule($0.value.source.rule) }
      continuity = continuity.filter { value in
        sources[value.source.pid]?.source == value.source || isTrackingRule(value.source.rule)
      }
    }
    observe()
  }

  func policyReading(at decisionTime: Date? = nil) -> CallDetectionPolicy.Reading {
    let projectionTime = decisionTime ?? deps.now()
    var eligible = promptDemand && sequence >= minimumPolicySequence
    #if DEBUG
      if simulation != nil { eligible = promptDemand }
    #endif
    let mapped: [CallDetectionPolicy.Holder] = holders.compactMap { holder in
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { return nil }
      let input: CallDetectionPolicy.Input =
        switch holder.input {
        case .active: .active
        case .inactive: .inactive
        case .unknown: .unknown
        }
      let read = evidence[holder.pid].flatMap { cached -> CallEvidenceReader.Evidence? in
        guard Self.sameProcess(cached.holder, holder) else { return nil }
        #if DEBUG
          if simulation != nil { return cached.reading == sequence ? cached.value : nil }
        #endif
        guard cached.policyEpoch == policyEpoch,
          let state = sources[holder.pid], cached.source == state.source,
          cached.activityRevision == state.activityRevision
        else { return nil }
        let age = projectionTime.timeIntervalSince(cached.beganAt)
        return age >= 0 && age <= CallDetectionPolicy.staleAfter ? cached.value : nil
      }
      return .init(pid: holder.pid, rule: rule, input: input, evidence: read)
    }
    return .init(
        sequence: sequence, takenAt: takenAt, complete: complete && eligible, holders: eligible ? mapped : [],
        ambiguous: ambiguous,
        sources: eligible ? holders.compactMap { sources[$0.pid]?.source } : [],
        continuity: promptDemand ? continuity.sorted { $0.id < $1.id } : [],
        pendingSources: promptDemand ? pendingSources.filter { sources[$0.pid]?.source == $0 } : [])
  }

  /// Speaker admission is exact-frame, even when policy continuity can use an older query.
  func currentEvidence(for holder: CallMicrophoneWatcher.Holder) -> CallEvidenceReader.Evidence? {
    evidence[holder.pid].flatMap {
      Self.sameProcess($0.holder, holder) && $0.reading == sequence ? $0.value : nil
    }
  }

  /// Reads active or unknown holders and the apps of tracked calls, even when their microphones
  /// are off. Results belong to their source/request, independently of microphone sequence.
  private func readEvidence() {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard updateReadLifetime() else { return }
    cycleWanted = true
    scheduleNextRead()
  }

  private func eligibleTargets() -> [ReadTarget] {
    let listed = holders.filter { holder in
      let tracked = CallAppCatalog.rule(forBundleID: holder.bundleID)
        .map { isTrackingRule($0) } ?? false
      return holder.input == .active || evidence[holder.pid]?.value == .unknown || tracked
    }.compactMap { holder -> SourceState? in
      guard let state = sources[holder.pid], state.present,
        Self.sameProcess(state.holder, holder) else { return nil }
      return state
    }
    var targets = listed.map { ReadTarget(state: $0, retained: nil) }
    for state in sources.values.sorted(by: { $0.source.id < $1.source.id })
      where !state.present || state.retainedAfterWake {
      for target in state.knownCalls where target.owner == state.owner && isTrackingTarget(target) {
        targets.append(.init(state: state, retained: target))
      }
    }
    var unique: [ReadTarget] = []
    for target in targets where !unique.contains(where: { $0.key == target.key }) { unique.append(target) }
    return unique.sorted {
      if $0.state.source.id != $1.state.source.id { return $0.state.source.id < $1.state.source.id }
      return ($0.retained?.room ?? "") < ($1.retained?.room ?? "")
    }
  }

  private func makeCycle() -> [ReadTarget] {
    let targets = eligibleTargets()
    let primary = targets.filter {
      $0.retained != nil || $0.state.holder.input == .active || isTrackingRule($0.state.source.rule)
    }
    let secondary = targets.filter { target in !primary.contains { $0.key == target.key } }
    let group = primary.isEmpty ? secondary : primary
    guard !group.isEmpty else { return [] }
    let start: Int
    if let lastCycleStart, let previous = group.firstIndex(where: { $0.key == lastCycleStart }) {
      start = (previous + 1) % group.count
    } else if let lastCycleStart {
      start = group.firstIndex { $0.state.source.id > lastCycleStart.sourceID } ?? 0
    } else { start = 0 }
    lastCycleStart = group[start].key
    let rotated = Array(group[start...]) + Array(group[..<start])
    return primary.isEmpty ? rotated : rotated + secondary
  }

  private func scheduleNextRead() {
    guard evidenceTask == nil, !refreshInProgress, !hasQueuedPress(),
      updateReadLifetime(), !readStopped else { return }
    // At most the leftover captured cycle and one newly requested cycle. New arrivals never
    // restart a finite cycle or push its already-enrolled targets behind them forever.
    for _ in 0..<2 {
      if cycle.isEmpty {
        guard cycleWanted else { pendingSources = []; observe(); return }
        cycleWanted = false
        cycle = makeCycle()
      }
      let bound = cycle.count
      for _ in 0..<bound {
        let target = cycle.removeFirst()
        guard let state = sources[target.state.source.pid], state.source == target.state.source,
          canQuery(state, retained: target.retained) else { continue }
        launchRead(.init(state: state, retained: target.retained))
        return
      }
    }
    pendingSources = []
    observe()
  }

  private func launchRead(_ target: ReadTarget) {
    let read = deps.snapshot
    let lifetime = readLifetime
    let capturedFrame = sequence
    let capturedPolicyEpoch = policyEpoch
    nextReadID += 1
    let requestID = nextReadID
    currentReadID = requestID
    pendingSources = ([target] + cycle).map(\.state.source)
    observe()
    evidenceTask = Task {
      defer { self.finishRead(requestID) }
      do {
        guard self.currentReadID == requestID, self.readLifetime == lifetime,
          !Task.isCancelled, self.updateReadLifetime() else { return }
        guard let current = self.sources[target.state.source.pid],
          current.source == target.state.source,
          self.canQuery(current, retained: target.retained)
        else {
          self.removePending(target.state.source)
          return
        }
        let beganAt = self.deps.now()
        let value = await read(current.source.rule, current.holder.pid, target.retained)
        guard self.currentReadID == requestID, self.readLifetime == lifetime,
          !Task.isCancelled, self.updateReadLifetime() else { return }
        self.removePending(current.source)
        if let retained = target.retained {
          self.acceptRetained(value, requested: current, target: retained, beganAt: beganAt, epoch: capturedPolicyEpoch)
        } else { self.accept(value, requested: current, beganAt: beganAt, frame: capturedFrame, epoch: capturedPolicyEpoch) }
        // A healthy early source is useful now, not after every other app has answered.
        self.observe()
        self.onChange()
      }
    }
  }

  private func canQuery(_ state: SourceState, retained: CallEvidenceReader.RetainedTarget?) -> Bool {
    if let retained {
      return (!state.present || state.retainedAfterWake)
        && state.owner == retained.owner && state.knownCalls.contains(retained)
        && isTrackingTarget(retained)
    }
    return state.present && holders.contains { Self.sameProcess($0, state.holder) }
  }

  private func removePending(_ source: CallDetectionPolicy.Source) {
    if let index = pendingSources.firstIndex(of: source) { pendingSources.remove(at: index) }
  }

  private func accept(
    _ value: CallEvidenceReader.Snapshot, requested: SourceState, beganAt: Date, frame: Int, epoch: Int
  ) {
    let pid = requested.source.pid
    guard var current = sources[pid], current.present, current.source == requested.source,
      holders.contains(where: { Self.sameProcess($0, requested.holder) })
    else { return }
    if let expected = requested.owner, let actual = value.owner, expected != actual {
      // This request belongs to the replaced run. Publish loss of its identity, never its
      // positive result; a new microphone frame and query must establish the replacement.
      publishContinuity(.unknown, owner: nil, for: requested.source, beganAt: beganAt, epoch: epoch)
      nextSourceID += 1
      current.source = .init(id: nextSourceID, pid: pid, rule: current.source.rule)
      current.activityRevision += 1
      current.present = false
      current.owner = actual
      current.knownCalls = []
      sources[pid] = current
      evidence[pid] = nil
      cycleWanted = true
      return
    }
    let sameRun = requested.owner == nil || requested.owner == value.owner
    publishContinuity(sameRun && value.owner != nil ? value.continuity : .unknown,
      owner: sameRun ? value.owner : nil, for: requested.source, beganAt: beganAt, epoch: epoch)
    if let owner = value.owner { current.owner = owner }
    if sameRun, let target = capturedTarget(value, source: current.source), !current.knownCalls.contains(target) {
      current.knownCalls.append(target)
    }
    sources[pid] = current
    if current.activityRevision == requested.activityRevision {
      let start: CallEvidenceReader.Evidence
      if !sameRun, case .call = value.startEvidence { start = .unknown }
      else { start = value.startEvidence }
      evidence[pid] = .init(holder: current.holder, value: start, reading: frame,
        source: current.source, activityRevision: current.activityRevision, beganAt: beganAt, policyEpoch: epoch)
    }
  }

  private func capturedTarget(
    _ value: CallEvidenceReader.Snapshot, source: CallDetectionPolicy.Source
  ) -> CallEvidenceReader.RetainedTarget? {
    guard let owner = value.owner else { return nil }
    let call: (CallAppFamily, String)
    switch value.continuity {
    case .ongoing(let family, let room), .ended(let family, let room): call = (family, room)
    case .unknown:
      switch value.startEvidence {
      case .call(let family, let room), .microphoneOnly(let family, let room): call = (family, room)
      case .none, .unknown: return nil
      }
    }
    return .init(rule: source.rule, holderPID: source.pid, owner: owner, family: call.0, room: call.1)
  }

  private func acceptRetained(
    _ value: CallEvidenceReader.Snapshot, requested: SourceState,
    target: CallEvidenceReader.RetainedTarget, beganAt: Date, epoch: Int
  ) {
    guard let current = sources[requested.source.pid], current.source == requested.source,
      current.owner == target.owner, current.knownCalls.contains(target), isTrackingTarget(target)
    else { return }
    let valid = value.owner == target.owner && target.accepts(value.continuity)
    publishContinuity(valid ? value.continuity : .unknown, owner: valid ? value.owner : nil,
      for: requested.source, beganAt: beganAt, retainedTarget: target, epoch: epoch)
    // No start cache or microphone field is written by a retained completion.
  }

  private func publishContinuity(
    _ value: CallEvidenceReader.Continuity, owner: CallEvidenceReader.AppRun?,
    for source: CallDetectionPolicy.Source, beganAt: Date,
    retainedTarget: CallEvidenceReader.RetainedTarget? = nil, epoch: Int? = nil
  ) {
    guard promptDemand, epoch == nil || epoch == policyEpoch else { return }
    nextObservationID += 1
    continuity.removeAll { $0.source == source && $0.retainedTarget == retainedTarget }
    continuity.append(.init(id: nextObservationID, source: source, beganAt: beganAt,
      completedAt: deps.now(), owner: owner, value: value, retainedTarget: retainedTarget))
  }

  private func finishRead(_ id: Int) {
    guard currentReadID == id else { return }
    evidenceTask = nil
    currentReadID = nil
    pendingSources = cycle.map(\.state.source)
    guard !readStopped else { return }
    observe()
    onChange()
    scheduleNextRead()
  }

  /// A fresh microphone poll and the evidence reads it starts, finished: a Yes and a switch
  /// act on what the call shows now, not on a read from before (review r4 F3, r12 F1).
  func refreshRequest(_ target: CallDetectionPolicy.RefreshTarget?) -> RefreshRequest? {
    guard let target else { return nil }
    let candidates = eligibleTargets().filter { $0.state.source.rule == target.rule }
    let listed = candidates.filter { $0.retained == nil }
    let known = listed.filter { $0.state.knownCalls.contains(where: target.matches) }
    let choices = known.isEmpty ? listed : known
    let selected: ReadTarget?
    if !choices.isEmpty {
      let owners = choices.compactMap(\.state.owner)
      let unambiguous = choices.count == 1
        || (owners.count == choices.count && owners.allSatisfy { $0 == owners.first })
      // Ambiguity is checked across every matching owner before preferring activity.
      selected = unambiguous
        ? (choices.first { $0.state.holder.input == .active } ?? choices.first) : nil
    } else {
      selected = candidates.first { $0.retained.map(target.matches) == true }
    }
    return .init(target: target, read: selected)
  }

  private func discardStartProof(for target: CallDetectionPolicy.RefreshTarget) {
    for pid in Array(evidence.keys) where sources[pid]?.source.rule == target.rule { evidence[pid] = nil }
    observe()
  }

  func refreshNow(_ request: RefreshRequest?) async {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard promptDemand, let request, updateReadLifetime(), isCurrentTarget(request.target) else { return }
    guard !refreshInProgress else { discardStartProof(for: request.target); return }
    let lifetime = readLifetime
    let epoch = policyEpoch
    refreshInProgress = true
    defer {
      if epoch == policyEpoch, lifetime == readLifetime {
        refreshInProgress = false
        scheduleNextRead()
      }
    }
    // A task is one bounded request, never the rest of the ordinary cycle.
    if let running = evidenceTask { await running.value }
    guard epoch == policyEpoch, lifetime == readLifetime, updateReadLifetime(), isCurrentTarget(request.target)
    else { return }
    if watching { await pollAndWait() }
    discardStartProof(for: request.target)
    // The captured read pins identity, not the microphone choice: this poll may
    // have handed input to another already-verified source of the same call.
    guard epoch == policyEpoch, lifetime == readLifetime, isCurrentTarget(request.target), let previous = request.read,
      let captured = refreshRequest(request.target)?.read,
      let current = sources[captured.state.source.pid], current.source == captured.state.source,
      (previous.state.owner == nil || current.owner == previous.state.owner),
      (current.source == previous.state.source
        || (previous.state.owner != nil && current.owner == previous.state.owner
          && current.knownCalls.contains(where: request.target.matches))),
      canQuery(current, retained: captured.retained)
    else { return }
    cycle.removeAll { $0.key == captured.key }
    launchRead(.init(state: current, retained: captured.retained))
    if let fresh = evidenceTask { await fresh.value }
  }

  /// A whole fresh scan for source-only clients; coalesces with an in-flight CoreAudio scan.
  func refreshNow() async {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard watching else { return }
    let lifetime = readLifetime
    if let running = evidenceTask { await running.value }
    guard lifetime == readLifetime, watching else { return }
    await pollAndWait()
    if let running = evidenceTask { await running.value }
  }

  func pruneTrackedCalls() {
    for pid in Array(sources.keys) {
      guard var state = sources[pid] else { continue }
      state.knownCalls.removeAll { !isTrackingTarget($0) }
      sources[pid] = state
    }
  }

  func resumeReads() { scheduleNextRead() }
  var evidenceReadPending: Bool { evidenceTask != nil }
  var refreshPending: Bool { refreshInProgress }

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
    for holder in holders where holder.input != .inactive {
      var page = ""
      if case .call(let family, _)? = evidence[holder.pid]?.value { page = "\(family)" }
      sources.insert("\(holder.pid)|\(holder.bundleID)|\(holder.input)|\(page)")
    }
    guard sources != speakerSources else { return }
    speakerSources = sources
    speakerSourceRevision += 1
  }

  /// #4013 13B: the one call a recording's speaker session reads now, whatever started the
  /// recording. A call app holding the microphone, or a browser whose page reads as a call, is a
  /// candidate, grouped by family and owning app instance. One candidate: `unique`. None: `none`.
  /// Two or more (two calls, two app instances, two browser copies): `ambiguous`. A reading that
  /// was incomplete or ambiguous, a call app or browser whose microphone use could not be read,
  /// or a browser holding the microphone whose page is not read yet: `unavailable`. Never a
  /// guess, never a preference between calls.
  func speakerSource() -> CallSpeakerSourceAnswer {
    guard complete, !ambiguous else { return .unavailable }
    var candidates: [CallSpeakerSourceAnswer.Source] = []
    var undecided = false
    for holder in holders where holder.input != .inactive {
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
      // It may be holding the microphone for a second call.
      guard holder.input == .active else {
        undecided = true
        continue
      }
      let family: CallAppFamily
      switch rule {
      case .callApp(let ruleFamily), .callWindow(let ruleFamily): family = ruleFamily
      case .browser:
        switch currentEvidence(for: holder) {
        case .call(let pageFamily, _)?: family = pageFamily
        case .unknown?, nil:
          undecided = true
          continue
        case .none?, .microphoneOnly?: continue
        }
      }
      guard let owner = holder.ownerPID else {
        undecided = true
        continue
      }
      let source = CallSpeakerSourceAnswer.Source(
        family: family, target: CallSpeakerTarget(pid: owner, rule: rule))
      if !candidates.contains(source) { candidates.append(source) }
    }
    if candidates.count > 1 { return .ambiguous }
    if undecided { return .unavailable }
    return candidates.first.map { .unique($0) } ?? .none
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
      invalidatePolicyProjection()
    invalidateSharedWork()
    sources = [:]
    continuity = []
    simulation = list
      if let list {
        // The real watcher stops while a simulation owns the readings.
        stopCollecting()
        evidence = Dictionary(
          list.map { ($0.holder.pid, CachedEvidence(holder: $0.holder, value: $0.evidence, reading: sequence)) },
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

    func tickForTesting() { tick() }
    func enablePollingForTesting() { readStopped = false; watching = true }
    var recordingDemandForTesting: Int { recordingDemand }
    var waitingForNextScanForTesting: Int { watcher.waitingForNextScanForTesting }
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

/// What a recording's speaker session may read now (`CallSourceDiscovery.speakerSource()`).
enum CallSpeakerSourceAnswer: Equatable, Sendable {
  struct Source: Equatable, Sendable {
    let family: CallAppFamily
    let target: CallSpeakerTarget
  }

  case unique(Source)
  case none
  case ambiguous
  case unavailable
}

/// What a speaker session needs from call-source discovery; tests stand in for it.
@MainActor
protocol CallSpeakerSources: AnyObject {
  func beginRecordingDemand()
  func endRecordingDemand()
  func speakerSource() -> CallSpeakerSourceAnswer
  var speakerSourceRevision: Int { get }
}

extension CallSourceDiscovery: CallSpeakerSources {}
