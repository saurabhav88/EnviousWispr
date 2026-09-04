import Foundation

// S1-mini's three control-line axes (#2649).
//
// S1-mini is one model in one file. Its published input format puts a single
// control line at the top of every request, and that line is the model's whole
// API surface: `[Styling: …] [Structure: …] [Context: …]`. Every combination of
// the values below was trained; any value outside them is off-distribution and
// the card warns it makes the model hallucinate or garble its output. So each
// axis is a closed enum whose raw value IS the wire token, and nothing else can
// reach the line.
//
// Founder decision 2026-09-04: all three are user settings, each defaulting to
// the value the app shipped with, so anyone who never opens the picker sees no
// change. Automatic per-destination selection is a later upgrade over the
// pickers, not a replacement for them.

/// Register. `semi-formal` is the card's own default and the one its published
/// examples use. `casual` and `semi-casual` deliberately keep sentence starts
/// lowercase and drop the final period, which reads as a formatting bug in
/// dictated text destined for other people's documents; that is why the app
/// ships on `semiFormal` rather than on the loosest register.
public enum S1Styling: String, CaseIterable, Codable, Sendable {
  case casual
  case semiCasual = "semi-casual"
  case semiFormal = "semi-formal"
  case formal
}

/// Told `lists` the model emits one for genuinely enumerable content and leaves
/// everything else as prose; told `prose` it scores zero on list-demanding
/// input. This is a SETTING the model obeys, not a judgement it makes, so the
/// choice is the user's and it is never inferred per transcript.
public enum S1Structure: String, CaseIterable, Codable, Sendable {
  case prose
  case lists
}

/// Destination conventions. `email` is a PERMISSION, not a forcing instruction:
/// measured on the shipped weights, a note-to-self and a code comment were
/// byte-identical under both values, and only text that already carried a
/// greeting or a sign-off gained email layout. `general` is the neutral value
/// and the one every measurement in the plan was taken at.
public enum S1Context: String, CaseIterable, Codable, Sendable {
  case general
  case email
}

/// The three axes together, and the one place the control line is composed.
public struct S1ControlSettings: Codable, Sendable, Equatable {
  public var styling: S1Styling
  public var structure: S1Structure
  public var context: S1Context

  public init(styling: S1Styling, structure: S1Structure, context: S1Context) {
    self.styling = styling
    self.structure = structure
    self.context = context
  }

  /// What every install runs until the user changes something. These are the
  /// exact values that shipped as constants before the pickers existed, which
  /// is what makes the pickers a no-op for anyone who ignores them.
  public static let `default` = S1ControlSettings(
    styling: .semiFormal, structure: .lists, context: .general)

  /// The first line of the user message, exactly as the card specifies it.
  public var controlLine: String {
    "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
  }
}
