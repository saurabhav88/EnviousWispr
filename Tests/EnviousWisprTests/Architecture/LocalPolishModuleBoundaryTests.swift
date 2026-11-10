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
  /// needs it. `os` and `Observation`: the runtime. `os` and (DEBUG) `Darwin`: the process
  /// manager. `os`: the coordinator and the child-process observation. `CryptoKit`: the
  /// upgrade coordinator's artifact fingerprint.
  static let permittedPlatform: Set<String> = [
    "Foundation", "os", "Observation", "CryptoKit", "Darwin",
  ]

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
    try #require(files.count >= 14, "expected the module's source files, found \(files.count)")
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

  // MARK: - The llama-server engine (#4473)

  /// The engine module. Nothing below the app shell may import it: an engine that LocalPolish,
  /// LLM or Pipeline can import is an engine they come to depend on, and then S1-mini's engine
  /// and EG-1's engine can no longer be built, loaded or removed apart. Silent until it breaks.
  static let engineModule = "EnviousWisprLlamaEngine"
  /// What the engine itself may import: its four declared dependencies and Foundation.
  static let enginePermitted: Set<String> = [
    "EnviousWisprCore", "EnviousWisprModelDelivery", "EnviousWisprLocalPolish",
    "EnviousWisprLLM", "Foundation",
  ]

  /// Every imported module, in source order (plain, scoped, attributed, every `#if` branch).
  static func importedModules(in tree: SourceFileSyntax) -> [String] {
    let collector = ImportCollector(viewMode: .sourceAccurate)
    collector.walk(tree)
    return collector.modules
  }

  private static func swiftFiles(under directory: String) throws -> [URL] {
    let root = RepoRoot.url.appending(path: directory)
    let enumerator = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
      "missing source folder \(directory)")
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
      .sorted { $0.path < $1.path }
  }

  @Test("LocalPolish, LLM and Pipeline never import the llama engine")
  func lowerModulesDoNotImportTheEngine() throws {
    for directory in [
      "Sources/EnviousWisprLocalPolish", "Sources/EnviousWisprLLM", "Sources/EnviousWisprPipeline",
    ] {
      let files = try Self.swiftFiles(under: directory)
      // Control: an empty or missing folder would pass without reading anything.
      try #require(!files.isEmpty, "no Swift files under \(directory)")
      for file in files {
        // Cheap first: a file whose text never names the engine cannot import it. Only a
        // file that does name it is parsed, to tell an import from a comment or a string.
        let text = try String(contentsOf: file, encoding: .utf8)
        guard text.contains(Self.engineModule) else { continue }
        let imports = Self.importedModules(in: try CachedSwiftParser.snapshot(at: file).tree)
        #expect(
          !imports.contains(Self.engineModule),
          "\(directory)/\(file.lastPathComponent) imports \(Self.engineModule)")
      }
    }
  }

  @Test("the llama engine imports only its four declared dependencies and Foundation")
  func engineImportsOnlyItsDeclaredDependencies() throws {
    let files = try Self.swiftFiles(under: "Sources/\(Self.engineModule)")
    try #require(files.count >= 8, "expected the engine's source files, found \(files.count)")
    for file in files {
      let offenders = Self.importedModules(in: try CachedSwiftParser.snapshot(at: file).tree)
        .filter { !Self.enginePermitted.contains($0) }
      #expect(offenders.isEmpty, "\(file.lastPathComponent) imports \(offenders)")
    }
  }

  @Test(
    "the engine checks read every import shape and nothing else",
    arguments: [
      ("import EnviousWisprLlamaEngine", ["EnviousWisprLlamaEngine"]),
      ("import enum EnviousWisprLlamaEngine.LlamaServerHealthProbe", ["EnviousWisprLlamaEngine"]),
      ("@testable import EnviousWisprLlamaEngine", ["EnviousWisprLlamaEngine"]),
      (
        "#if DEBUG\nimport EnviousWisprLlamaEngine\n#else\nimport MLX\n#endif",
        ["EnviousWisprLlamaEngine", "MLX"]
      ),
      (
        "import EnviousWisprEG1Engine\nimport EnviousDecodeKit",
        ["EnviousWisprEG1Engine", "EnviousDecodeKit"]
      ),
      (
        "import EnviousWisprCore\nimport EnviousWisprLLM\nimport Foundation",
        ["EnviousWisprCore", "EnviousWisprLLM", "Foundation"]
      ),
      ("// import EnviousWisprLlamaEngine\nlet note = \"import EnviousWisprLlamaEngine\"", []),
    ] as [(String, [String])])
  func engineChecksReadEveryImportShape(source: String, imported: [String]) {
    let modules = Self.importedModules(in: CachedSwiftParser.parse(source: source))
    #expect(modules == imported)
    // The two rules, applied to the same fixture: rule 1 flags the engine import, rule 2
    // flags anything outside the engine's allowlist (MLX, another engine).
    #expect(modules.contains(Self.engineModule) == imported.contains(Self.engineModule))
    #expect(
      modules.filter { !Self.enginePermitted.contains($0) }
        == imported.filter { !Self.enginePermitted.contains($0) })
  }

  // MARK: - The EnviousDecode engine (#4473 P2)

  /// What `EnviousDecodeKit` may import: Foundation and MLX's array, layer and language-model
  /// libraries. No app module. The kit runs inside the helper process, so an app module there
  /// would bring app state and app policy into a process built to hold only the model.
  static let decodeKitPermitted: Set<String> = [
    "Foundation", "MLX", "MLXLLM", "MLXLMCommon", "MLXNN",
  ]
  /// The engine's modules share this prefix: the kit and the helper executable.
  static let decodeModulePrefix = "EnviousDecode"

  /// One test, with its controls inside it. What breaks without it: an app module that imports
  /// the kit loads the EG-1 model code inside the app, so the model's memory and any engine
  /// crash land in the process that records and pastes; the helper process exists to keep them
  /// out. Silent until a crash or a memory spike, so it is checked here.
  @Test(
    "the EnviousDecode kit imports only MLX and Foundation, and no app module imports the engine")
  func decodeEngineStaysApartFromTheApp() throws {
    func kitOffenders(_ tree: SourceFileSyntax) -> [String] {
      Self.importedModules(in: tree).filter { !Self.decodeKitPermitted.contains($0) }
    }
    func engineImports(_ tree: SourceFileSyntax) -> [String] {
      Self.importedModules(in: tree).filter { $0.hasPrefix(Self.decodeModulePrefix) }
    }

    // Controls: both readers report each import shape, and neither reads comments or strings.
    let kitFixtures: [(String, [String])] = [
      ("import Foundation\nimport MLX\nimport MLXLLM\nimport MLXLMCommon\nimport MLXNN", []),
      ("import EnviousWisprCore", ["EnviousWisprCore"]),
      (
        "@preconcurrency import EnviousWisprLocalPolish\nimport MLXEmbedders",
        ["EnviousWisprLocalPolish", "MLXEmbedders"]
      ),
      (
        "#if DEBUG\nimport struct EnviousWisprLLM.LLMError\n#else\nimport MLX\n#endif",
        ["EnviousWisprLLM"]
      ),
      ("// import EnviousWisprCore\nlet note = \"import EnviousWisprCore\"", []),
    ]
    for (source, expected) in kitFixtures {
      #expect(
        kitOffenders(CachedSwiftParser.parse(source: source)) == expected, "fixture: \(source)")
    }
    let appFixtures: [(String, [String])] = [
      ("import EnviousDecodeKit", ["EnviousDecodeKit"]),
      ("@testable import EnviousDecodeHelper\nimport Foundation", ["EnviousDecodeHelper"]),
      ("#if DEBUG\nimport enum EnviousDecodeKit.DFlashKernels\n#endif", ["EnviousDecodeKit"]),
      ("import EnviousWisprCore\n// import EnviousDecodeKit\nlet note = \"EnviousDecodeKit\"", []),
    ]
    for (source, expected) in appFixtures {
      #expect(
        engineImports(CachedSwiftParser.parse(source: source)) == expected, "fixture: \(source)")
    }

    let kitFiles = try Self.swiftFiles(under: "Sources/\(Self.decodeModulePrefix)Kit")
    // Control: an empty or missing folder would pass without reading anything.
    try #require(kitFiles.count >= 2, "expected the kit's source files, found \(kitFiles.count)")
    for file in kitFiles {
      let offenders = kitOffenders(try CachedSwiftParser.snapshot(at: file).tree)
      #expect(offenders.isEmpty, "\(file.lastPathComponent) imports \(offenders)")
    }

    // Every app module: each folder under Sources/ named EnviousWispr*.
    let appModules = try FileManager.default.contentsOfDirectory(
      atPath: RepoRoot.url.appending(path: "Sources").path
    ).filter { $0.hasPrefix("EnviousWispr") }.sorted()
    try #require(appModules.count >= 20, "expected the app's modules, found \(appModules.count)")
    for module in appModules {
      for file in try Self.swiftFiles(under: "Sources/\(module)") {
        // Cheap first, as above: only a file that names the engine is parsed.
        let text = try String(contentsOf: file, encoding: .utf8)
        guard text.contains(Self.decodeModulePrefix) else { continue }
        let imports = engineImports(try CachedSwiftParser.snapshot(at: file).tree)
        #expect(imports.isEmpty, "\(module)/\(file.lastPathComponent) imports \(imports)")
      }
    }
  }
}
