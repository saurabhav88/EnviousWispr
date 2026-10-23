import Foundation

/// The one identity this app writes into every keyboard event it posts, and the keyboard listener
/// reads back, so our own copy and paste chords never count as the user's keys (#3544 P3).
///
/// Written to `CGEventField.eventSourceUserData` before posting. P0 measured that our current posts
/// (`postToPid`, `.cgAnnotatedSessionEventTap`) never reach the listener's session tap, so this is
/// defence for a post that someday does, not the reason they are ignored today. It is a label, not
/// authentication: another process could write the same value, and a virtual keyboard driver that
/// re-posts events can erase it.
package enum SyntheticKeyboardEventMarker {
  /// "EWSYNKEY" in ASCII.
  package static let userData: Int64 = 0x4557_5359_4E4B_4559
}

/// How long every chord we post holds its character key down before releasing it (#3978).
///
/// A key-down and key-up posted in the same instant is a press no keyboard makes, and TinyMCE 5 in
/// Chrome answers it by inserting the paste twice (ENVIOUSWISPR-7V). Measured on #3978: no gap
/// doubled every time, 1-2 ms about half the time, 5-20 ms never on a calm machine. Wispr Flow
/// holds 5 ms; 20 ms keeps a margin over the 1-2 ms failures. A browser page that freezes longer
/// than the hold still receives both events together, so this fixes the ordinary case, not that one.
///
/// Synchronous on purpose: the release must follow on every path, and a sleep here cannot fail or
/// return early, so the chord's posting stays unconditional. A synthetic key-down did not auto-repeat
/// when held: a 2 s letter hold typed once and a 3 s Cmd+V hold pasted once (#3978); longer stalls
/// are not measured.
package enum SyntheticKeyHold {
  package static let milliseconds = 20

  /// Blocks the calling thread for the hold. `sleep` is a seam for tests only.
  package static func beforeRelease(
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    sleep(Double(milliseconds) / 1000)
  }
}
