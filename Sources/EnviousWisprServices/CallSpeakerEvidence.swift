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
  private var nameCounts: [String: Int] = [:]
  private var nameOrder: [String] = []
  private var selfNames: [String] = []
  private var fromParticipantList = false
  /// Whether any capture was complete and about one call.
  private var usable = false

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

  private var presenceOrder: [String] = []
  private var presence: [String: Tracked] = [:]
  /// The time of the last complete participant list in the current unbroken run.
  private var lastListMs: Int?

  package init(
    surface: CallSpeakerSurface, rules: FrozenTalkerRules?, lag: CallSpeakerLag?,
    status: CallSpeakerObservationStatus? = nil, presencePolicy: CallPresencePolicy = .current,
    startMs: Int = 0
  ) {
    self.startMs = startMs
    self.surface = surface
    self.rules = rules
    self.lag = lag
    self.status = status
    self.presencePolicy = presencePolicy
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
    var counts: [String: Int] = [:]
    for name in reading.roster.names { counts[name, default: 0] += 1 }
    // In the order the reader showed them, each name once.
    for name in reading.roster.names where counts[name] != nil {
      if nameCounts[name] == nil { nameOrder.append(name) }
      nameCounts[name] = max(nameCounts[name] ?? 0, counts[name] ?? 0)
      counts[name] = nil
    }
    // A name the reader proved two people share stays at least twice, so a later reading that
    // shows it once never makes it nameable.
    for name in reading.sharedNames.sorted() {
      if nameCounts[name] == nil { nameOrder.append(name) }
      nameCounts[name] = max(nameCounts[name] ?? 0, 2)
    }
    for name in reading.roster.selfNames where !selfNames.contains(name) {
      selfNames.append(name)
    }
    if reading.rosterFromParticipantList { fromParticipantList = true }
    notePresence(reading, at: observationMs)
    switch CallSpeakerAdmission.admission(of: reading, context: context) {
    case .admitted:
      let speaking = CallSpeakerAdmission.observationSpeaking(reading, context: context) ?? []
      if speaking.isEmpty {
        health.admittedQuietObservations += 1
      } else {
        health.admittedSpeakingObservations += 1
      }
      observations.append(CallSpeakerObservation(observationMs: observationMs, speaking: speaking))
    case .withheld(let reason):
      health.withheldByReason[reason.rawValue, default: 0] += 1
    }
  }

  private mutating func notePresence(_ reading: CallSpeakerReading, at ms: Int) {
    let shown = Set(reading.roster.names)
    for name in reading.roster.names {
      if presence[name] == nil {
        guard presenceOrder.count < CallSpeakerSegment.maximumPresenceNames else { continue }
        presenceOrder.append(name)
        presence[name] = Tracked()
      }
      guard var tracked = presence[name] else { continue }
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
      presence[name] = tracked
    }
    guard reading.participantListComplete else {
      breakAbsenceRuns()
      return
    }
    let continues = lastListMs.map { ms - $0 <= presencePolicy.maximumGapMs } ?? false
    for name in presenceOrder where !shown.contains(name) {
      guard var tracked = presence[name], let open = tracked.open else { continue }
      if let since = tracked.missingSince, continues {
        tracked.missingCount += 1
        if tracked.missingCount >= presencePolicy.absenceReadings,
          ms - since >= presencePolicy.minimumAbsenceSpanMs,
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
      presence[name] = tracked
    }
    lastListMs = ms
  }

  /// Anything that is not a complete participant list read in time: no run of them goes on.
  private mutating func breakAbsenceRuns() {
    lastListMs = nil
    for name in presenceOrder where presence[name]?.missingSince != nil {
      presence[name]?.missingSince = nil
      presence[name]?.missingCount = 0
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
        names: nameOrder.flatMap { Array(repeating: $0, count: nameCounts[$0] ?? 0) },
        selfNames: selfNames),
      rosterFromParticipantList: fromParticipantList, observations: observations,
      presence: presenceOrder.compactMap { name in
        guard let tracked = presence[name] else { return nil }
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
