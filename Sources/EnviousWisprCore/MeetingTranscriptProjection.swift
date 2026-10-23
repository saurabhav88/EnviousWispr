import Foundation

/// What a meeting transcript SHOWS, from what it STORES (#3972 R5, R19).
///
/// Echo turns (microphone lines that repeat the call sound) are stored and hidden by default.
/// Every reader that shows or exports a meeting (the detail view, Copy, Save) goes through this
/// one function, so the screen and the exported text can never disagree. When every turn is
/// hidden the answer is an EMPTY list, never a fallback to the raw text, which would show the
/// hidden lines again.
public enum MeetingTranscriptProjection {
  public struct Visible: Sendable, Equatable {
    public let turns: [Turn]
    /// True when turns exist but the echo setting hides all of them.
    public let everythingHidden: Bool
  }

  public static func visible(turns: [Turn], echoTurnIDs: Set<String>, showEcho: Bool) -> Visible {
    guard !showEcho, !echoTurnIDs.isEmpty else {
      return Visible(turns: turns, everythingHidden: false)
    }
    let shown = turns.filter { !echoTurnIDs.contains($0.id) }
    return Visible(turns: shown, everythingHidden: shown.isEmpty && !turns.isEmpty)
  }

  /// Plain text of the visible turns, one paragraph per turn, prefixed with the speaker's name
  /// when it has one: "You: …". Reserved classifications (`both`, `unknown`) carry no prefix.
  /// `line` rewrites each turn's own words before the name is added (the app puts gap markers
  /// in the interface language there), so a speaker name is never rewritten.
  public static func plainText(
    text: String, turns: [Turn], speakerNames: [String: String], echoTurnIDs: Set<String>,
    showEcho: Bool, line: (String) -> String = { $0 }
  ) -> String {
    let utf16 = Array(text.utf16)
    return visible(turns: turns, echoTurnIDs: echoTurnIDs, showEcho: showEcho).turns.compactMap {
      turn in
      let lower = max(0, min(turn.originalTextRange.lowerBound, utf16.count))
      let upper = max(lower, min(turn.originalTextRange.upperBound, utf16.count))
      let words = String(decoding: utf16[lower..<upper], as: UTF16.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      let shown = line(words)
      if let name = speakerNames[turn.speakerId], !name.isEmpty { return "\(name): \(shown)" }
      return shown
    }.joined(separator: "\n\n")
  }
}
