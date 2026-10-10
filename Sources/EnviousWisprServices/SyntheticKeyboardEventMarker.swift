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
