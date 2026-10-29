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
    case .zoomApp: ZoomAppSpeakerReader.read(windows: capture.windows)
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
  /// <title>" and "Meeting compact view | Meeting with <title>"). The Zoom app: at most one
  /// meeting window (`zm.meeting.window.main`, the identifier Granola reads). Any other app
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
      let meetings = capture.windows.filter { $0.root.identifier == zoomMeetingWindowID }
      return meetings.count <= 1 ? .resolved : .unresolved
    default:
      return .resolved
    }
  }

  /// The Zoom app's meeting window.
  static let zoomMeetingWindowID = "zm.meeting.window.main"
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

  package static let liveTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()
}

/// One recording's speaker evidence as it is collected (#4013 chunk 13A), and the log it saves.
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
package struct CallSpeakerAccumulator: Sendable, Equatable {
  package let surface: CallSpeakerSurface
  package let rules: FrozenTalkerRules?
  package let lag: CallSpeakerLag?
  package private(set) var status: CallSpeakerObservationStatus?
  package private(set) var observations: [CallSpeakerObservation] = []
  private var nameCounts: [String: Int] = [:]
  private var nameOrder: [String] = []
  private var selfNames: [String] = []
  private var fromParticipantList = false
  /// Captures taken; and whether any was complete and about one call.
  private var captures = 0
  private var usable = false

  package init(
    surface: CallSpeakerSurface, rules: FrozenTalkerRules?, lag: CallSpeakerLag?,
    status: CallSpeakerObservationStatus? = nil
  ) {
    self.surface = surface
    self.rules = rules
    self.lag = lag
    self.status = status
  }

  /// Adds one reading of a capture taken at `observationMs`.
  package mutating func add(
    _ reading: CallSpeakerReading?, context: CallCaptureContext, observationMs: Int
  ) {
    captures += 1
    guard context.completeness == .complete, context.scope == .resolved else {
      if status == nil { status = .unreadable }
      return
    }
    usable = true
    status = .observed
    guard let reading else { return }
    var counts: [String: Int] = [:]
    for name in reading.roster.names { counts[name, default: 0] += 1 }
    // In the order the reader showed them, each name once.
    for name in reading.roster.names where counts[name] != nil {
      if nameCounts[name] == nil { nameOrder.append(name) }
      nameCounts[name] = max(nameCounts[name] ?? 0, counts[name] ?? 0)
      counts[name] = nil
    }
    for name in reading.roster.selfNames where !selfNames.contains(name) {
      selfNames.append(name)
    }
    // A name the reader proved two people share stays at least twice, so a later reading that
    // shows it once never makes it nameable.
    for name in reading.sharedNames.sorted() {
      if nameCounts[name] == nil { nameOrder.append(name) }
      nameCounts[name] = max(nameCounts[name] ?? 0, 2)
    }
    if reading.rosterFromParticipantList { fromParticipantList = true }
    if let speaking = CallSpeakerAdmission.observationSpeaking(reading, context: context) {
      observations.append(CallSpeakerObservation(observationMs: observationMs, speaking: speaking))
    }
  }

  /// Accessibility trust was missing for a capture. Earlier usable evidence keeps `observed`.
  package mutating func noteNoPermission() {
    if !usable { status = .noPermission }
  }

  package var log: CallSpeakerLog {
    CallSpeakerLog(
      surface: surface, source: CallSpeakerSurfaceChoice.source(for: surface), status: status,
      lag: lag, rules: rules,
      roster: CallSpeakerRoster(
        names: nameOrder.flatMap { Array(repeating: $0, count: nameCounts[$0] ?? 0) },
        selfNames: selfNames),
      rosterFromParticipantList: fromParticipantList, observations: observations)
  }
}
