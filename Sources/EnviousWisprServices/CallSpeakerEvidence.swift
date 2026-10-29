import Darwin
import EnviousWisprCore
import Foundation

/// Which talker surface a recording's call app is, from the call family the recording was
/// started for and the kind of app that held the microphone (#4013 chunk 13A). Bound by app
/// family, one surface per recording, as Granola binds its speaker monitors
/// (`competitor-meeting-notes.md` FACT: granola-speaker-name-coverage-and-fallback).
package enum CallSpeakerSurfaceChoice {
  package static func surface(family: CallAppFamily, rule: CallAppCatalog.Rule)
    -> CallSpeakerSurface?
  {
    let inBrowser: Bool
    switch rule {
    case .browser: inBrowser = true
    case .callApp, .callWindow: inBrowser = false
    }
    switch family {
    case .zoom: return inBrowser ? .zoomWeb : .zoomApp
    case .teams: return inBrowser ? .teamsWeb : .teamsApp
    case .googleMeet: return inBrowser ? .meet : nil
    case .slack: return inBrowser ? .slackWeb : .slackApp
    case .facetime: return .facetime
    case .webex: return .webex
    case .dialpadMeetings: return .dialpad
    case .gather: return .gather
    case .lark: return .lark
    case .voov: return .voov
    case .whereby: return .whereby
    case .jitsi: return .jitsi
    }
  }

  /// The source a surface's reader writes, as `MeetingSpeakerNamer.evidenceRefusal` expects.
  package static func source(for surface: CallSpeakerSurface) -> CallSpeakerSource {
    switch surface {
    case .zoomApp, .teamsApp, .zoomWeb: .app
    case .meet, .teamsWeb, .slackApp, .slackWeb: .rules
    case .facetime, .webex, .dialpad, .gather, .lark, .voov, .whereby, .jitsi: .roster
    }
  }

  /// Whether a surface has a talker reader this build runs live.
  package static func hasTalkerReader(_ surface: CallSpeakerSurface) -> Bool {
    source(for: surface) != .roster
  }

  /// Whether a web page belongs to `family`'s meeting: the only pages a capture copies.
  package static func isMeetingPage(_ url: String, family: CallAppFamily) -> Bool {
    CallMeetingURL.classify(url)?.family == family
  }
}

/// Reads one capture with the surface's reader. `nil` when the reader found nothing to read
/// (no meeting page, two meeting pages, or no reader for the surface).
package enum CallSpeakerSurfaceReader {
  package static func read(
    surface: CallSpeakerSurface, capture: CallAXCapture, rules: TalkerRules
  ) -> CallSpeakerReading? {
    switch surface {
    // Only the meeting window; `scope` withholds a capture with meeting content elsewhere.
    case .zoomApp: ZoomAppSpeakerReader.read(windows: capture.windows.filter(isZoomMeeting))
    case .teamsApp: TeamsAppSpeakerReader.read(windows: capture.windows)
    case .zoomWeb: ZoomWebSpeakerReader.read(documents: capture.documents)
    case .meet, .teamsWeb, .slackWeb:
      RulesSpeakerReader.read(documents: capture.documents, rule: rules.rule(for: surface))
    case .slackApp:
      RulesSpeakerReader.read(windows: capture.windows, rule: rules.rule(for: surface))
    case .facetime, .webex, .dialpad, .gather, .lark, .voov, .whereby, .jitsi: nil
    }
  }

  /// Whether the capture is about one call. A browser capture: exactly one meeting page of the
  /// family. The Teams app: every window showing meeting content belongs to one meeting, the
  /// compact view matched to its main window by title (observed 2026-10-27: "Meeting with
  /// <title>" and "Meeting compact view | Meeting with <title>"). The Zoom app: exactly one
  /// meeting window (`ZoomCallWindow`) and no meeting content in any other window. Any other app
  /// capture comes from the one app instance resolved for the recording.
  package static func scope(
    surface: CallSpeakerSurface, capture: CallAXCapture, family: CallAppFamily
  ) -> CallCaptureContext.Scope {
    switch surface {
    case .zoomWeb, .teamsWeb, .meet, .slackWeb:
      let pages = capture.documents.filter {
        $0.url.map { CallSpeakerSurfaceChoice.isMeetingPage($0, family: family) } ?? false
      }
      return pages.count == 1 ? .resolved : .unresolved
    case .teamsApp:
      guard let titles = TeamsAppSpeakerReader.meetingTitles(windows: capture.windows) else {
        return .unresolved
      }
      return titles.count <= 1 ? .resolved : .unresolved
    case .zoomApp:
      // Exactly one meeting window, and no other window showing tiles, a talker or a
      // participants list (a popped-out panel or a second meeting's content is not matched).
      let meetings = capture.windows.filter(isZoomMeeting)
      let elsewhere = capture.windows.filter { !isZoomMeeting($0) }.contains { window in
        let reading = ZoomAppSpeakerReader.read(windows: [window])
        return !reading.participants.isEmpty || !reading.speaking.isEmpty
          || !reading.roster.names.isEmpty
      }
      return meetings.count == 1 && !elsewhere ? .resolved : .unresolved
    default:
      return .resolved
    }
  }

  static func isZoomMeeting(_ window: CallAXWindow) -> Bool {
    ZoomCallWindow.isMeeting(identifier: window.root.identifier, title: window.title)
  }
}

/// Places a capture on the meeting timeline: milliseconds from the recorder's anchor (the host
/// time its timeline starts at) to the middle of the reads. `nil` for a capture that began
/// before the anchor, which no meeting audio can match.
package enum CallSpeakerTimeline {
  package static func observationMs(
    readStart: UInt64, readEnd: UInt64, anchor: UInt64,
    timebase: mach_timebase_info_data_t = liveTimebase
  ) -> Int? {
    guard readStart >= anchor, readEnd >= readStart else { return nil }
    let middle = readStart + (readEnd - readStart) / 2
    let ticks = middle - anchor
    let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    let ms = nanos / 1_000_000
    guard ms < Double(Int.max) else { return nil }
    return Int(ms)
  }

  /// Microseconds between two host times; 0 when the end is not after the start.
  package static func microseconds(
    from start: UInt64, to end: UInt64, timebase: mach_timebase_info_data_t = liveTimebase
  ) -> Int {
    guard end > start else { return 0 }
    let nanos = Double(end - start) * Double(timebase.numer) / Double(timebase.denom)
    let us = nanos / 1_000
    return us < Double(Int.max) ? Int(us) : Int.max
  }

  package static let liveTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()
}

/// One segment's speaker evidence as it is collected (#4013 chunk 13A, 13B), and the log it saves.
///
/// Observations: only `CallSpeakerAdmission.observationSpeaking` results are appended; `nil`
/// (withheld) appends nothing, `[]` is a valid quiet observation.
///
/// Roster: every reading whose capture was complete and about one call contributes, admitted or
/// withheld for an ambiguous or unnamed talker. Each name is kept as many times as the most
/// times any one such reading showed it, so a repeated snapshot never invents a second person
/// and a later snapshot never erases two people already seen sharing a name. Self names are
/// the union of the names a reader marked as the user. A name a reader proved two people share
/// (`CallSpeakerReading.sharedNames`) is kept at least twice, so the namer never names it.
///
/// Presence (`CallPresencePolicy`): a name shown by such a reading opens or extends a sighting.
/// Only a run of complete participant lists that all leave it out, read close together, closes
/// it as confirmed gone; any other reading, a dropped copy or a pause breaks the run.
///
/// Capacity (#4013 13B.5): a reading is kept whole or not at all. It is applied to a copy first;
/// when the recording's evidence (`baseline`, the closed segments, plus this segment) would
/// pass a cap in `limits`, nothing of it is kept and collection stops for good
/// (`capacityReached`), keeping what it had. A reading with a name no log may hold
/// (`CallSpeakerLog.isName`) is not kept either, and breaks runs of missing names.
///
/// Health: counts of how captures and ticks went (`CallCaptureHealth`), no names.
package struct CallSpeakerAccumulator: Sendable, Equatable {
  package let surface: CallSpeakerSurface
  package let rules: FrozenTalkerRules?
  package let lag: CallSpeakerLag?
  package let presencePolicy: CallPresencePolicy
  /// Where this segment starts on the recording clock.
  package let startMs: Int
  package private(set) var status: CallSpeakerObservationStatus?
  package private(set) var observations: [CallSpeakerObservation] = []
  package private(set) var health = CallCaptureHealth()
  /// The cap that stopped collection, if one did.
  package private(set) var capacityReached: CallEvidenceCapacity?
  private var names = Names()
  /// Whether any capture was complete and about one call.
  private var usable = false
  private let limits: CallEvidenceLimits
  /// What the recording's earlier segments use.
  private let baseline: CallEvidenceUsage
  /// This segment's runs, talker references and talker names, kept as observations are added.
  private var runs = 0
  private var speakingReferences = 0
  /// The bytes of every talker name this segment kept.
  private var speakingSpellings: Set<[UInt8]> = []

  /// Rosters and presence: small, so a reading is tried on a copy of them.
  private struct Names: Sendable, Equatable {
    var nameCounts: [String: Int] = [:]
    var nameOrder: [String] = []
    var selfNames: [String] = []
    var fromParticipantList = false
    var presenceOrder: [String] = []
    var presence: [String: Tracked] = [:]
    /// The time of the last complete participant list in the current unbroken run.
    var lastListMs: Int?
  }

  private struct Tracked: Sendable, Equatable {
    var sightings: [CallNamePresence.Sighting] = []
    var open: (first: Int, last: Int)?
    var absences: [CallNamePresence.Absence] = []
    var missingSince: Int?
    var missingCount = 0
    /// Seen again when no sighting could be opened.
    var full = false

    static func == (a: Tracked, b: Tracked) -> Bool {
      a.sightings == b.sightings && a.open?.first == b.open?.first && a.open?.last == b.open?.last
        && a.absences == b.absences && a.missingSince == b.missingSince
        && a.missingCount == b.missingCount && a.full == b.full
    }
  }

  package init(
    surface: CallSpeakerSurface, rules: FrozenTalkerRules?, lag: CallSpeakerLag?,
    status: CallSpeakerObservationStatus? = nil, presencePolicy: CallPresencePolicy = .current,
    startMs: Int = 0, limits: CallEvidenceLimits = .current,
    baseline: CallEvidenceUsage = CallEvidenceUsage()
  ) {
    self.startMs = startMs
    self.surface = surface
    self.rules = rules
    self.lag = lag
    self.status = status
    self.presencePolicy = presencePolicy
    self.limits = limits
    self.baseline = baseline
  }

  /// Adds one reading of a capture taken at `observationMs`.
  package mutating func add(
    _ reading: CallSpeakerReading?, context: CallCaptureContext, observationMs: Int
  ) {
    health.captureAttempts += 1
    switch context.completeness {
    case .complete: health.completeCaptures += 1
    case .truncated: health.truncatedCaptures += 1
    case .unreadable, .unknown: health.unreadableCaptures += 1
    }
    guard context.completeness == .complete, context.scope == .resolved else {
      if context.completeness == .complete { health.unresolvedScopeCaptures += 1 }
      breakAbsenceRuns()
      if status == nil { status = .unreadable }
      return
    }
    usable = true
    status = .observed
    guard let reading else {
      breakAbsenceRuns()
      return
    }
    guard capacityReached == nil else {
      health.evidenceCapacityDrops += 1
      return
    }
    let admission = CallSpeakerAdmission.admission(of: reading, context: context)
    let speaking: [String]? =
      if case .admitted = admission {
        CallSpeakerAdmission.observationSpeaking(reading, context: context) ?? []
      } else {
        nil
      }
    let shown =
      reading.roster.names + reading.roster.selfNames + reading.sharedNames + (speaking ?? [])
    guard shown.allSatisfy(CallSpeakerLog.isName) else {
      health.invalidNameReadings += 1
      breakAbsenceRuns()
      return
    }
    var trial = names
    Self.addRoster(reading, to: &trial)
    Self.notePresence(reading, at: observationMs, policy: presencePolicy, in: &trial)
    let observation = speaking.map {
      CallSpeakerObservation(observationMs: observationMs, speaking: $0)
    }
    if let capacity = usage(of: trial, adding: observation).exceeded(limits) {
      capacityReached = capacity
      health.evidenceCapacityDrops += 1
      breakAbsenceRuns()
      return
    }
    names = trial
    switch admission {
    case .admitted:
      guard let observation else { return }
      if observation.speaking.isEmpty {
        health.admittedQuietObservations += 1
      } else {
        health.admittedSpeakingObservations += 1
      }
      if !CallSpeakerRun.continues(observations.last, with: observation) {
        runs += 1
        speakingReferences += observation.speaking.count
      }
      for name in observation.speaking { speakingSpellings.insert(Array(name.utf8)) }
      observations.append(observation)
    case .withheld(let reason):
      health.withheldByReason[reason.rawValue, default: 0] += 1
    }
  }

  /// What the recording would use with `names` as this segment's and `observation` added; the
  /// same count `CallEvidenceUsage` makes of the saved segments.
  private func usage(of names: Names, adding observation: CallSpeakerObservation?)
    -> CallEvidenceUsage
  {
    var usage = baseline
    usage.insertNames(names.nameOrder)
    usage.insertNames(names.selfNames)
    usage.insertNames(names.presenceOrder)
    usage.names.formUnion(speakingSpellings)
    usage.rosterReferences += names.nameCounts.values.reduce(0, +) + names.selfNames.count
    usage.presenceEntries += names.presenceOrder.count
    for tracked in names.presence.values {
      usage.sightings += tracked.sightings.count + (tracked.open == nil ? 0 : 1)
      usage.absences += tracked.absences.count
    }
    usage.runs += runs
    usage.samples += observations.count
    usage.speakingReferences += speakingReferences
    if let observation {
      usage.insertNames(observation.speaking)
      usage.samples += 1
      if !CallSpeakerRun.continues(observations.last, with: observation) {
        usage.runs += 1
        usage.speakingReferences += observation.speaking.count
      }
    }
    return usage
  }

  private static func addRoster(_ reading: CallSpeakerReading, to names: inout Names) {
    var counts: [String: Int] = [:]
    for name in reading.roster.names { counts[name, default: 0] += 1 }
    // In the order the reader showed them, each name once.
    for name in reading.roster.names where counts[name] != nil {
      if names.nameCounts[name] == nil { names.nameOrder.append(name) }
      names.nameCounts[name] = max(names.nameCounts[name] ?? 0, counts[name] ?? 0)
      counts[name] = nil
    }
    // A name the reader proved two people share stays at least twice, so a later reading that
    // shows it once never makes it nameable.
    for name in reading.sharedNames.sorted() {
      if names.nameCounts[name] == nil { names.nameOrder.append(name) }
      names.nameCounts[name] = max(names.nameCounts[name] ?? 0, 2)
    }
    for name in reading.roster.selfNames where !names.selfNames.contains(name) {
      names.selfNames.append(name)
    }
    if reading.rosterFromParticipantList { names.fromParticipantList = true }
  }

  private static func notePresence(
    _ reading: CallSpeakerReading, at ms: Int, policy: CallPresencePolicy, in names: inout Names
  ) {
    let shown = Set(reading.roster.names)
    for name in reading.roster.names {
      if names.presence[name] == nil {
        guard names.presenceOrder.count < CallSpeakerSegment.maximumPresenceNames else { continue }
        names.presenceOrder.append(name)
        names.presence[name] = Tracked()
      }
      guard var tracked = names.presence[name] else { continue }
      if let open = tracked.open {
        tracked.open = (open.first, ms)
      } else if tracked.sightings.count < CallNamePresence.maximumSightings {
        tracked.open = (ms, ms)
      } else {
        // Shown again with no room to record it: its last absence is no longer known to hold.
        tracked.full = true
      }
      tracked.missingSince = nil
      tracked.missingCount = 0
      names.presence[name] = tracked
    }
    guard reading.participantListComplete else {
      breakAbsenceRuns(in: &names)
      return
    }
    let continues = names.lastListMs.map { ms - $0 <= policy.maximumGapMs } ?? false
    for name in names.presenceOrder where !shown.contains(name) {
      guard var tracked = names.presence[name], let open = tracked.open else { continue }
      if let since = tracked.missingSince, continues {
        tracked.missingCount += 1
        if tracked.missingCount >= policy.absenceReadings,
          ms - since >= policy.minimumAbsenceSpanMs,
          tracked.absences.count < CallNamePresence.maximumSightings
        {
          tracked.sightings.append(
            .init(firstSeenMs: open.first, lastSeenMs: open.last, absenceConfirmed: true))
          tracked.absences.append(.init(firstMissingMs: since, confirmedAtMs: ms))
          tracked.open = nil
          tracked.missingSince = nil
          tracked.missingCount = 0
        }
      } else {
        tracked.missingSince = ms
        tracked.missingCount = 1
      }
      names.presence[name] = tracked
    }
    names.lastListMs = ms
  }

  /// Anything that is not a complete participant list read in time: no run of them goes on.
  private mutating func breakAbsenceRuns() {
    Self.breakAbsenceRuns(in: &names)
  }

  private static func breakAbsenceRuns(in names: inout Names) {
    names.lastListMs = nil
    for name in names.presenceOrder where names.presence[name]?.missingSince != nil {
      names.presence[name]?.missingSince = nil
      names.presence[name]?.missingCount = 0
    }
  }

  /// Accessibility trust was missing for a capture. Earlier usable evidence keeps `observed`.
  package mutating func noteNoPermission() {
    health.missingPermissionTicks += 1
    breakAbsenceRuns()
    if !usable { status = .noPermission }
  }

  /// Dictation started or ended since the last tick, with no copy in flight to drop: a pause
  /// that breaks any run of missing lists, counted nowhere else.
  package mutating func noteInterruption() {
    breakAbsenceRuns()
  }

  /// A tick took no copy because dictation was running.
  package mutating func noteDictationSkip() {
    health.skippedDictationTicks += 1
    breakAbsenceRuns()
  }

  /// A tick took no copy because one was still being taken.
  package mutating func noteBusySkip() {
    health.skippedBusyTicks += 1
  }

  /// A copy was dropped at delivery because something changed while it was taken.
  package mutating func noteStaleDrop() {
    health.staleResultDrops += 1
    breakAbsenceRuns()
  }

  /// One copy's walk time and size.
  package mutating func noteWalk(durationUs: Int, nodes: Int) {
    health.noteWalk(durationUs: durationUs, nodes: nodes)
  }

  /// The log of this one segment, still open.
  package var log: CallSpeakerLog {
    CallSpeakerLog(
      rules: rules, presencePolicy: presencePolicy,
      segments: [segment(endMs: nil, endReason: nil)])
  }

  /// This segment as saved, open (`endMs` nil) or ended. A sighting still open at the end is
  /// saved unconfirmed: collection stopped, which says nothing about who left.
  package func segment(endMs: Int?, endReason: CallSpeakerSegmentEnd?) -> CallSpeakerSegment {
    CallSpeakerSegment(
      startMs: startMs, endMs: endMs, endReason: endReason, surface: surface,
      source: CallSpeakerSurfaceChoice.source(for: surface), status: status, lag: lag,
      roster: CallSpeakerRoster(
        names: names.nameOrder.flatMap {
          Array(repeating: $0, count: names.nameCounts[$0] ?? 0)
        },
        selfNames: names.selfNames),
      rosterFromParticipantList: names.fromParticipantList, observations: observations,
      presence: names.presenceOrder.compactMap { name in
        guard let tracked = names.presence[name] else { return nil }
        let open = tracked.open.map {
          CallNamePresence.Sighting(
            firstSeenMs: $0.first, lastSeenMs: $0.last, absenceConfirmed: false)
        }
        return CallNamePresence(
          name: name, sightings: tracked.sightings + (open.map { [$0] } ?? []),
          absences: tracked.absences, sightingsFull: tracked.full ? true : nil)
      },
      health: health)
  }
}
