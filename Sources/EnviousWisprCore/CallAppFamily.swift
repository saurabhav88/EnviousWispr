import Foundation

/// A call app or meeting service EnviousMeet can notice (#4012 D4). Persisted on a meeting by
/// its raw value (`MeetingRecord.callAppRaw`) and sent as telemetry `call_app`, so raw values
/// never change; a value this build does not know reads as nil.
public enum CallAppFamily: String, Sendable, CaseIterable, Equatable {
  case zoom
  case teams
  case facetime
  case webex
  case slack
  case googleMeet = "google_meet"
  case whereby
  case jitsi
  case dialpadMeetings = "dialpad_meetings"
  case gather
  case lark
  case voov

  /// The name a meeting from this app gets when nothing better is known, and the name the
  /// "Record this call?" panel shows. Product names, never translated.
  public var displayName: String {
    switch self {
    case .zoom: "Zoom"
    case .teams: "Microsoft Teams"
    case .facetime: "FaceTime"
    case .webex: "Webex"
    case .slack: "Slack"
    case .googleMeet: "Google Meet"
    case .whereby: "Whereby"
    case .jitsi: "Jitsi"
    case .dialpadMeetings: "Dialpad Meetings"
    case .gather: "Gather"
    case .lark: "Lark"
    case .voov: "VooV Meeting"
    }
  }
}
