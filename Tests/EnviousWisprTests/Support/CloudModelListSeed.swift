import Foundation

@testable import EnviousWisprLLM

/// #4353 D6: the committed seed list (`website/public/cloud-models.json`, byte-identical to the
/// bundled copy), validated by the production parser. Tests that need today's listed request
/// policy pass this as the operation's captured list.
enum CloudModelListSeed {
  static func list() throws -> CloudModelList {
    try CloudModelList.validated(
      from: Data(contentsOf: RepoRoot.sourceURL("website/public/cloud-models.json"))
    ).get()
  }
}

extension CloudModelListSeed {
  /// The seed as an operation's captured list. Nil only when the committed seed fails to
  /// load, which makes every listed expectation fail loudly instead of passing.
  static let current: CloudModelList? = try? list()
}
