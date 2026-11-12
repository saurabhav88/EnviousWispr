import Foundation
import Testing

@testable import EnviousWisprServices

/// #4528 B2 (plan §11): the rules the website publishes are the rules the app ships.
///
/// **Drift Guard.** When this fails, the website copy of `setup-rules.json` differs from the app's
/// bundled copy, so a Mac that downloads it would get advice the release was never tested with.
/// Publication itself is verified after deployment (chunk H).
@Suite(.tags(.driftGuard))
struct SetupRulesFileTests {
  private static let bundled = "Sources/EnviousWisprServices/Resources/setup-rules.json"
  private static let website = "website/public/setup-rules.json"

  @Test("the website rules file is byte-identical to the bundled file")
  func websiteMatchesBundled() throws {
    let a = try Data(contentsOf: RepoRoot.url.appending(path: Self.bundled))
    let b = try Data(contentsOf: RepoRoot.url.appending(path: Self.website))
    #expect(!a.isEmpty)
    #expect(
      a == b, "\(Self.website) differs from \(Self.bundled); copy the bundled file and re-sign")
  }

  @Test("the website rules file validates as rules")
  func websiteRulesValidate() throws {
    let data = try Data(contentsOf: RepoRoot.url.appending(path: Self.website))
    let rules = try SetupRules.validated(from: data)
    #expect(rules == SetupRules.builtIn)
  }
}
