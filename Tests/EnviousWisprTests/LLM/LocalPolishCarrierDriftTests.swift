import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprLlamaEngine
@testable import EnviousWisprLocalPolish
@testable import EnviousWisprModelDelivery

/// #4493: the loopback carrier stays gone. When a row fails, a bundled polish helper is
/// reachable on a network port again, a request bypasses the one owner, or the bearer is
/// readable in the process list.
@Suite("Local polish carrier drift guards (#4493)", .tags(.driftGuard))
struct LocalPolishCarrierDriftTests {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // LLM
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  /// The code that talks to a bundled helper: the three engine modules, the helper itself and
  /// the summary engine.
  static let scopes = [
    "Sources/EnviousWisprLocalPolish", "Sources/EnviousWisprEG1Engine",
    "Sources/EnviousWisprLlamaEngine", "Sources/EnviousDecodeHelper",
    "Sources/EnviousWisprAppKit/App/EGOneSummaryEngine.swift",
  ]

  /// Spellings of the removed carrier.
  static let removed = ["URLSession", "127.0.0.1", "findFreePort", "no_free_port", ".hostPort("]

  /// Code lines of a Swift source: whole-line comments (`//`, `///`, `*` inside a block) are
  /// left out; a trailing comment is cut at `//` outside a string.
  static func codeLines(_ source: String) -> [String] {
    source.components(separatedBy: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
        return nil
      }
      var inString = false
      var previous: Character = " "
      var cut = line.endIndex
      for index in line.indices {
        let character = line[index]
        if character == "\"" && previous != "\\" { inString.toggle() }
        if !inString && character == "/" && previous == "/" {
          cut = line.index(before: index)
          break
        }
        previous = character
      }
      return String(line[..<cut])
    }
  }

  static func hits(_ tokens: [String], in source: String) -> [String] {
    codeLines(source).flatMap { line in tokens.filter { line.contains($0) } }
  }

  static func swiftFiles(_ scope: String) throws -> [URL] {
    let url = repoRoot.appendingPathComponent(scope)
    if scope.hasSuffix(".swift") { return [url] }
    let enumerator = try #require(
      FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  @Test("the scanner finds each removed spelling in code and ignores it in comments")
  func scannerControls() {
    for token in Self.removed {
      #expect(Self.hits([token], in: "let x = \(token)") == [token], "\(token)")
      #expect(Self.hits([token], in: "  /// \(token) was the old carrier").isEmpty, "\(token)")
      #expect(Self.hits([token], in: "let y = 1  // \(token)").isEmpty, "\(token)")
    }
  }

  @Test("no code that talks to a helper uses the removed loopback carrier")
  func noLoopbackCarrier() throws {
    var offenders: [String] = []
    var scanned = 0
    for scope in Self.scopes {
      for file in try Self.swiftFiles(scope) {
        scanned += 1
        let found = Self.hits(Self.removed, in: try String(contentsOf: file, encoding: .utf8))
        if !found.isEmpty { offenders.append("\(file.lastPathComponent): \(found)") }
      }
    }
    #expect(scanned >= 20, "scanned only \(scanned) files")
    #expect(offenders.isEmpty, "\(offenders)")
  }

  @Test("only the helper exchange calls the socket client in the app")
  func oneRequestOwner() throws {
    let callers = try Self.swiftFiles("Sources").filter { file in
      !Self.hits(
        ["LocalPolishHelperClient.perform("], in: try String(contentsOf: file, encoding: .utf8)
      )
      .isEmpty
    }
    #expect(callers.map(\.lastPathComponent) == ["LocalPolishHelperExchange.swift"])
  }

  static let secret = "secret-0123456789-abcdef"
  static let inputs = LocalPolishLaunchConnection.Inputs(
    socketPath: "/l/ewlp/7-1-1-abcdef01/s.sock",
    keyFileURL: URL(fileURLWithPath: "/l/ewlp/7-1-1-abcdef01/k"), secret: secret)

  static func launches() -> [(String, LocalPolishLaunchCommand)] {
    let identity = ModelIdentity(
      family: .egOne, name: "m", revision: "r", variant: "v", runtimeABI: "a")
    let decode = EnviousDecodeEngine(
      draftModelURL: URL(fileURLWithPath: "/models/draft", isDirectory: true),
      draftArtifactIdentity: identity, cacheLimitBytes: 1)
    var result: [(String, LocalPolishLaunchCommand)] = []
    for adapter in [nil, URL(fileURLWithPath: "/models/checker/adapters.safetensors")] {
      let egOne = decode.makeLaunchConfiguration(
        .egOne(.full), identity, URL(fileURLWithPath: "/h"),
        URL(fileURLWithPath: "/models/eg1", isDirectory: true), 4096, adapter)
      result.append(("envious-decode", egOne.makeLaunch(egOne.spec, inputs)))
      let s1 = LlamaServerEngine().makeLaunchConfiguration(
        .s1Mini, identity, URL(fileURLWithPath: "/s"), URL(fileURLWithPath: "/m.gguf"), 4096,
        adapter.map { _ in URL(fileURLWithPath: "/models/s1-checker.gguf") })
      result.append(("llama-server", s1.makeLaunch(s1.spec, inputs)))
    }
    return result
  }

  @Test(
    "no rendered launch has a port, a loopback host or the secret in its arguments or environment")
  func renderedLaunchesKeepTheSecretOut() {
    for (engine, launch) in Self.launches() {
      for flag in ["--port", "--token", "--api-key"] {
        #expect(!launch.arguments.contains(flag), "\(engine) \(flag)")
      }
      #expect(!launch.arguments.contains { $0.contains("127.0.0.1") }, "\(engine)")
      #expect(!launch.arguments.contains { $0.contains(Self.secret) }, "\(engine)")
      #expect(
        !launch.environment.contains {
          $0.key.contains(Self.secret) || $0.value.contains(Self.secret)
        },
        "\(engine)")
      switch engine {
      case "envious-decode":
        #expect(launch.stdinPreamble == Data((Self.secret + "\n").utf8))
        #expect(!launch.writesKeyFile)
      default:
        #expect(launch.stdinPreamble == nil)
        #expect(launch.writesKeyFile)
        #expect(launch.environment == ["EW_STOP_ON_STDIN_EOF": "1"])
      }
    }
  }
}
