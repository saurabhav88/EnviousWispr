import EnviousWisprCore

/// What the local polish runtime needs to know about a model's manifest, already interpreted
/// by the manifest's owner (#4473).
///
/// The runtime used to hold the EG-1 manifest type itself and call its validation, so the code
/// that starts and stops an engine also knew one engine's file format. It now consumes these
/// facts instead: the owner of a manifest format projects them once, and the runtime never
/// reads bundled JSON, interprets a URL or repeats a validation rule.
public struct LocalPolishManifestFacts: Sendable, Equatable {
  public let contextTokens: Int
  /// Nil when this app build does not know the manifest's prompt contract.
  public let promptFamily: PromptFamily?
  /// Why the manifest cannot activate on this app build, in the owner's order (empty = fine).
  public let activationBlockers: [String]

  public init(contextTokens: Int, promptFamily: PromptFamily?, activationBlockers: [String]) {
    self.contextTokens = contextTokens
    self.promptFamily = promptFamily
    self.activationBlockers = activationBlockers
  }
}
