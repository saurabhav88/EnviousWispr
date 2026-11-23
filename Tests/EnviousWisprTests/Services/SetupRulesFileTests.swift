import Foundation
import Testing

@testable import EnviousWisprServices

/// #4528 B2 (plan §11): the rules the website publishes are the rules the app ships.
///
/// **Drift Guard.** When this fails, the website copy of `setup-rules.json` differs from the app's
/// bundled copy, so a Mac that downloads it would get advice the release was never tested with.
/// Its signature must verify with the pinned production key. Publication itself is verified after
/// deployment (chunk H).
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

  @Test("the website rules file carries a valid signature from the pinned production key")
  func websiteSignatureVerifies() throws {
    let payload = try Data(contentsOf: RepoRoot.url.appending(path: Self.website))
    let signature = try Data(contentsOf: RepoRoot.url.appending(path: Self.website + ".sig"))
    // The app's own verifier and the key the app pins: what a downloading Mac will check.
    try SetupRulesSignature.verify(
      payload: payload, signatureText: signature,
      publicKeyBase64: PinnedSetupRulesKey.publicKeyBase64)
    // A one-byte change must fail, so the pass above is not a verifier that accepts anything.
    var tampered = payload
    tampered[tampered.startIndex] ^= 0x01
    #expect(throws: SetupRulesSignature.Failure.signatureMismatch) {
      try SetupRulesSignature.verify(
        payload: tampered, signatureText: signature,
        publicKeyBase64: PinnedSetupRulesKey.publicKeyBase64)
    }
  }

  @Test("the website rules file validates as rules")
  func websiteRulesValidate() throws {
    let data = try Data(contentsOf: RepoRoot.url.appending(path: Self.website))
    let rules = try SetupRules.validated(from: data)
    #expect(rules == SetupRules.builtIn)
  }
}
