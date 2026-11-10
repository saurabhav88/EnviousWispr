import Foundation
import SwiftSyntax
import Testing

/// #4473: `EnviousWisprLocalPolish` holds what a local polish model IS to the app (identity,
/// launch spec, install state, manifest facts, transport failure) and must stay free of any
/// engine. What breaks when it does not: an import of the LLM module, an engine module or the
/// MLX family here drags that engine's code and model runtime into the code that owns a local
/// model's lifecycle, so the two engines can no longer be built, loaded or removed apart, and
/// nothing on screen shows it until one engine's fault takes the other down. That is silent,
/// which is why it is checked here and not left to review.
///
/// An ALLOWLIST, not a list of banned names: a banned list is bounded by what its author
/// thought of, and an engine added later would pass it. Every import in the module must be one
/// of the modules named below; a new one fails here and a person decides. The same rule is
/// enforced for first-party modules by `scripts/check-dependency-direction.sh`; this test also
/// covers third-party and platform imports, scoped imports and conditional branches.
@Suite("EnviousWisprLocalPolish imports no engine (#4473)", .tags(.driftGuard))
struct LocalPolishModuleBoundaryTests {
  /// The only first-party modules the neutral module may import.
  static let permittedFirstParty: Set<String> = ["EnviousWisprCore", "EnviousWisprModelDelivery"]
  /// Platform modules the files in the module need today. Add one only with the file that
  /// needs it.
  static let permittedPlatform: Set<String> = ["Foundation"]

  private final class ImportCollector: SyntaxVisitor {
    var modules: [String] = []

    /// The FIRST path component is the module, for a plain import and for a scoped one
    /// (`import struct EnviousWisprLLM.LLMError`), with or without attributes (`@testable`).
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
      if let module = node.path.first?.name.text { modules.append(module) }
      return .skipChildren
    }
  }

  /// Every imported module that is not permitted, in source order. The walk is syntactic, so
  /// every branch of a `#if` is read, whichever one the compiler would take.
  static func forbiddenImports(in tree: SourceFileSyntax) -> [String] {
    let collector = ImportCollector(viewMode: .sourceAccurate)
    collector.walk(tree)
    return collector.modules.filter {
      !permittedFirstParty.contains($0) && !permittedPlatform.contains($0)
    }
  }

  private static func moduleFiles() throws -> [URL] {
    let root = RepoRoot.url.appending(path: "Sources/EnviousWisprLocalPolish")
    let enumerator = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
      .sorted { $0.path < $1.path }
  }

  @Test("no file in the module imports LLM, an engine module, MLX or anything unlisted")
  func moduleImportsOnlyPermittedModules() throws {
    let files = try Self.moduleFiles()
    // Control: an empty file list would pass the loop below without reading anything.
    try #require(files.count >= 4, "expected the module's source files, found \(files.count)")
    for file in files {
      let offenders = Self.forbiddenImports(in: try CachedSwiftParser.snapshot(at: file).tree)
      #expect(offenders.isEmpty, "\(file.lastPathComponent) imports \(offenders)")
    }
  }

  @Test(
    "the check reports each import shape that would break the boundary",
    arguments: [
      ("import EnviousWisprLLM", ["EnviousWisprLLM"]),
      ("@testable import EnviousWisprLlamaEngine", ["EnviousWisprLlamaEngine"]),
      ("import struct EnviousWisprLLM.LLMError", ["EnviousWisprLLM"]),
      ("#if canImport(MLX)\nimport MLX\n#else\nimport MLXNN\n#endif", ["MLX", "MLXNN"]),
      ("import EnviousDecodeKit\nimport Foundation", ["EnviousDecodeKit"]),
      ("@preconcurrency import EnviousWisprPipeline", ["EnviousWisprPipeline"]),
    ] as [(String, [String])])
  func checkReportsForbiddenImports(source: String, expected: [String]) {
    #expect(Self.forbiddenImports(in: CachedSwiftParser.parse(source: source)) == expected)
  }

  @Test("the check accepts the permitted imports and ignores module names in comments and strings")
  func checkAcceptsPermittedImports() {
    let source = """
      import EnviousWisprCore
      import EnviousWisprModelDelivery
      import Foundation
      // import EnviousWisprLLM
      let note = "import MLX"
      """
    #expect(Self.forbiddenImports(in: CachedSwiftParser.parse(source: source)).isEmpty)
  }
}
