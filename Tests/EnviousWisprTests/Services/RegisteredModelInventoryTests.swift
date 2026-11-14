import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprEG1Engine
@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #4528 B1 (plan §3.2, G3): every model the Setup rules may pick is wired into the app.
///
/// **Drift Guard.** A rules file can re-rank and re-threshold, but a NEW model identity also needs
/// the app's compiled inventories: its identity, its artifact catalog entry, its runtime wiring and
/// its card presenter. When this fails, the message names the inventory a rules id lacks, so the
/// person adding a model knows the remaining step instead of shipping a recommendation Setup could
/// never download.
@Suite(.tags(.driftGuard))
struct RegisteredModelInventoryTests {
  /// The startup wiring constructs one runtime per EG-1 size; read it as source (it is not
  /// enumerable without booting the app).
  private static func bootstrapperSource() throws -> String {
    try String(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"),
      encoding: .utf8)
  }

  /// The inventories a polish rules id lacks, empty when it is fully wired: identity, artifact,
  /// runtime and presentation. Apple Intelligence is the one legitimate artifact exemption: Apple
  /// ships the model with macOS, so there is nothing to download.
  static func missingInventories(forPolish id: String, bootstrapper: String) -> [String] {
    guard let model = SetupRules.registeredPolish[id] else {
      return ["identity (SetupRules.registeredPolish)"]
    }
    var missing: [String] = []
    if let size = model.size {
      if EGOneArtifactCatalog.model(size).installFolder.isEmpty {
        missing.append("artifact: model (EGOneArtifactCatalog.model)")
      }
      if EGOneArtifactCatalog.checker(size).installFolder.isEmpty {
        missing.append("artifact: checker (EGOneArtifactCatalog.checker)")
      }
      // The call may wrap its first argument onto the next line (`makeEGOne(\n      .micro, ...`).
      let wiring = #"makeEGOne\(\s*\."# + size.rawValue + #"\b"#
      if bootstrapper.range(of: wiring, options: .regularExpression) == nil {
        missing.append("runtime (WisprBootstrapper makeEGOne)")
      }
      if !EGOneSizeCardPresenter.order.contains(size) {
        missing.append("presenter (EGOneSizeCardPresenter.order)")
      }
      return missing
    }
    switch model.provider {
    case .s1Mini:
      let manifest = RepoRoot.url.appending(path: "Sources/EnviousWispr/Resources/s1-delivery-manifest.json")
      if !FileManager.default.fileExists(atPath: manifest.path) {
        missing.append("artifact (s1-delivery-manifest.json)")
      }
      if !bootstrapper.contains("s1MiniRuntime = LocalPolishRuntime(") {
        missing.append("runtime (WisprBootstrapper s1MiniRuntime)")
      }
    case .appleIntelligence:
      // Artifact: exempt (ships with macOS). Runtime: the connector type is compiled in.
      _ = AppleIntelligenceConnector.self
    default:
      missing.append("identity (no Setup wiring known for \(model.provider.rawValue))")
    }
    if PolishRailCatalog.entry(for: model.provider) == nil {
      missing.append("presenter (PolishRailCatalog.entry)")
    }
    return missing
  }

  @Test("every polish model the bundled rules can pick is fully wired")
  func bundledPolishPicksAreWired() throws {
    let rules = try SetupRules.bundled()
    let source = try Self.bootstrapperSource()
    let picks = Set((rules.polishPrimary + rules.polishNeighbour).map(\.pick))
    #expect(!picks.isEmpty)
    for id in picks {
      let missing = Self.missingInventories(forPolish: id, bootstrapper: source)
      #expect(missing.isEmpty, "\(id) lacks: \(missing)")
    }
  }

  @Test("every registered polish identity is fully wired, so any rules edit among them is safe")
  func everyRegisteredPolishIdentityIsWired() throws {
    let source = try Self.bootstrapperSource()
    for id in SetupRules.registeredPolish.keys {
      let missing = Self.missingInventories(forPolish: id, bootstrapper: source)
      #expect(missing.isEmpty, "\(id) lacks: \(missing)")
    }
  }

  @Test("every EG-1 size the app knows has a rules identity")
  func everySizeHasARulesIdentity() {
    for size in EGOneSize.allCases {
      #expect(SetupRules.registeredPolish["eg1.\(size.rawValue)"] == .egOne(size))
    }
  }

  @Test("an unregistered id is reported, naming the missing inventory")
  func unregisteredIdIsNamed() throws {
    let missing = Self.missingInventories(
      forPolish: "eg1.huge", bootstrapper: try Self.bootstrapperSource())
    #expect(missing == ["identity (SetupRules.registeredPolish)"])
  }

  @Test("every speech engine the rules can pick is a shipped engine")
  func speechPicksAreShippedEngines() throws {
    let rules = try SetupRules.bundled()
    for row in rules.speechChoice {
      #expect(SetupRules.registeredSpeech[row.pick] != nil, "\(row.pick) is not a shipped engine")
    }
  }
}
