import Foundation

/// Whether a Zoom window is a meeting, in any Zoom language (#4036).
///
/// First sign: the meeting window's Accessibility identifier. Live check 2026-10-25, Zoom 7.1.9
/// (88375), solo meetings: `zm.meeting.window.main` in English ("Zoom Meeting") and French
/// ("Réunion Zoom"), also while minimized and on the join preview; the home window
/// "Zoom Workplace" has none.
/// Backup: the whole title equals one of Zoom 7.1.9's localized meeting or webinar names
/// (keys `LN_Meeting_Title_148329` and `LN_Webinar_Title_148329` in its `*.lproj`), for webinars
/// (not live-checked) and for a Zoom build without the identifier.
enum ZoomCallWindow {
  static let meetingIdentifier = "zm.meeting.window.main"

  /// Zoom 7.1.9's 17 meeting and 17 webinar names (28 distinct), in `normalized` form.
  static let localizedNames: Set<String> = Set(
    [
      // Meeting
      "Zoom Meeting", "Reunión de Zoom", "Réunion Zoom", "Riunione Zoom", "Zoom ミーティング",
      "Zoom 회의", "Zoom-vergadering", "Spotkanie Zoom", "Reunião Zoom", "Конференция Zoom",
      "Zoom-möte", "Zoom Toplantısı", "Cuộc họp Zoom", "Zoom会议", "Zoom會議",
      // Webinar
      "Zoom Webinar", "Zoom-Webinar", "Seminario web de Zoom", "Webinaire Zoom", "Webinar Zoom",
      "Zoom ウェビナー", "Zoom 웨비나", "Webinar w Zoomie", "Вебинар Zoom", "Zoom Web Semineri",
      "Hội thảo trực tuyến Zoom", "Zoom网络研讨会", "Zoom網路研討會",
    ].map(normalized))

  /// One Accessibility attribute read.
  enum Read: Equatable {
    case value(String)
    /// The window has no such attribute, or no value for it now.
    case missing
    /// The read itself failed (timeout, app busy): could not tell.
    case failed
  }

  enum Verdict: Equatable { case call, none, unknown }

  /// Window by window: a meeting identifier or an exact meeting title is a call at once, so a
  /// later failed read cannot hide it. With no call found, any failed read is `.unknown`.
  /// The title is read only when the identifier did not prove a call.
  static func classify(
    windowCount: Int, identifier: (Int) -> Read, title: (Int) -> Read
  ) -> Verdict {
    var failed = false
    for index in 0..<windowCount {
      switch identifier(index) {
      case .value(let value) where value == meetingIdentifier: return .call
      case .failed: failed = true
      case .value, .missing: break
      }
      switch title(index) {
      case .value(let value) where localizedNames.contains(normalized(value)): return .call
      case .failed: failed = true
      case .value, .missing: break
      }
    }
    return failed ? .unknown : .none
  }

  /// Trimmed, NFC-composed, lowercased: Zoom's own Vietnamese strings are decomposed.
  static func normalized(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
      .lowercased()
  }
}
