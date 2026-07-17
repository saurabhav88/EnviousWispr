import Foundation
import Testing

/// #1386 PR-2 — freezes the ONE guarantee this change exists to make: the
/// multilingual model is never mapped except behind its relocation gate.
///
/// The gate is only worth the code if every route reaches it. Before PR-2 three
/// did not: `ASRManager` built its own `WhisperKitBackend` (a duplicate no real
/// dictation used), `ASRManagerProxy` sent WhisperKit loads across XPC, and
/// `ASRServiceHandler` built a third backend inside the helper — where an
/// in-process gate cannot reach. CoreML load/decode is not cooperatively
/// cancellable, so a model mapped behind the gate's back can be reading bytes
/// that relocation is still moving.
///
/// This is a STRUCTURAL freeze, not a behavior test: those routes were deleted,
/// and re-adding one must fail the build rather than wait for a rare, timing-
/// dependent bug in the field. It reads source text, so it catches a new caller
/// that no runtime test happens to exercise.
@Suite struct WhisperKitGatedLoadFreezeTests {

  /// The ONLY production file allowed to construct a real `WhisperKit`. It is
  /// where the gate is invoked, immediately before the map.
  private static let gatedMapSite = "Sources/EnviousWisprASR/WhisperKitBackend.swift"

  /// Benchmark-only, caller-supplied folder, never linked into an app flow.
  private static let benchmarkException =
    "Sources/EnviousWisprASR/TailBenchmarkHarness.swift"

  /// Matches a CONSTRUCTION of the toolkit type — `WhisperKit(` or
  /// `WhisperKit.init(` as a whole identifier. The lookbehind is the point: a
  /// naive `contains("WhisperKit(")` also matches `makeForWhisperKit(`, which is
  /// a factory function name, not a model map. This guard's value is entirely in
  /// its precision — a gate that cries wolf gets routed around, and then it
  /// protects nothing. `WhisperKitBackend(` stays unmatched: the character after
  /// the identifier is `B`, not a paren or `.init` (Codex code-diff r3).
  private static let constructionPattern = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9_])WhisperKit\\s*(\\(|\\.init\\b)")

  private func constructsWhisperKit(_ line: String) -> Bool {
    let range = NSRange(line.startIndex..., in: line)
    return Self.constructionPattern.firstMatch(in: line, range: range) != nil
  }

  /// Comments are where the retirement is explained, and they legitimately name
  /// `WhisperKit(config)` while describing it. Only code counts.
  private func isComment(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*")
  }

  private func swiftFiles(under relativePath: String) throws -> [URL] {
    let root = RepoRoot.sourceURL(relativePath)
    guard
      let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  private func repoRelative(_ url: URL) -> String {
    url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
  }

  @Test("only the gated backend may construct a WhisperKit — plus the named benchmark")
  func whisperKitConstructionIsConfinedToTheGatedSite() throws {
    var offenders: [String] = []
    for file in try swiftFiles(under: "Sources") {
      let path = repoRelative(file)
      guard path != Self.gatedMapSite, path != Self.benchmarkException else { continue }
      let source = try String(contentsOf: file, encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        guard !isComment(text), constructsWhisperKit(text) else { continue }
        offenders.append("\(path):\(index + 1)")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      A WhisperKit model is constructed outside the gated map site: \(offenders).
      CoreML load is not cancellable, so every map must first await the \
      relocation gate in \(Self.gatedMapSite) (performLoad). Route the caller \
      through WhisperKitEngineAdapter's backend instead of building one here.
      """)
  }

  /// The test above skips the gated file wholesale, which leaves the hole in the
  /// most likely place (Codex code-diff r3): the one file allowed to map is also
  /// the one where a SECOND, ungated map would plausibly be added — a new helper
  /// that builds its own kit and never awaits the gate. Proving "every
  /// construction in this file is gated" needs a parser; freezing the COUNT does
  /// not, and buys the same protection. One map site, gated at `performLoad`. A
  /// second one must argue for itself here rather than appear silently.
  @Test("the gated map site maps EXACTLY once — a second map must not slip in unnoticed")
  func gatedSiteConstructsExactlyOnce() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(Self.gatedMapSite), encoding: .utf8)
    let sites = source.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .filter { !isComment(String($0.element)) && constructsWhisperKit(String($0.element)) }
      .map { "\(Self.gatedMapSite):\($0.offset + 1)" }
    #expect(
      sites.count == 1,
      """
      Expected exactly ONE WhisperKit map in the gated site, found \(sites.count): \(sites).
      Every map must await the relocation gate first (CoreML load is not \
      cancellable, so a map can be reading bytes relocation is still moving). If \
      a second map site is genuinely needed, it must await the gate too — and \
      this count must be updated deliberately, with that reasoning.
      """)
  }

  @Test("the ASR manager, its XPC proxy, and the helper own no WhisperKit backend")
  func managerAndHelperNeverOwnAWhisperKitBackend() throws {
    // These three are the routes PR-2 deleted. The helper is a separate process
    // where the in-process gate provably cannot reach; the manager pair is the
    // path recovery and Diagnostics used to take to get there.
    let retiredRoutes = [
      "Sources/EnviousWisprASR/ASRManager.swift",
      "Sources/EnviousWisprASR/ASRManagerProxy.swift",
      "Sources/EnviousWisprASRService/ASRServiceHandler.swift",
    ]
    var offenders: [String] = []
    for path in retiredRoutes {
      let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        // A construction or a stored backend — either one re-opens the hole.
        let text = String(line)
        guard !isComment(text) else { continue }
        guard
          text.contains("WhisperKitBackend(")
            || text.contains(": WhisperKitBackend")
            || text.contains("whisperKitBackend")
        else { continue }
        offenders.append(
          "\(path):\(index + 1) — \(text.trimmingCharacters(in: .whitespaces))")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      A retired route owns a WhisperKit backend again: \(offenders).
      WhisperKit loads in-process behind its relocation gate, via \
      WhisperKitEngineAdapter. The manager and its XPC helper are Parakeet-only; \
      recovery and Diagnostics reach the active engine through \
      ActiveEngineOperation.
      """)
  }

  @Test("the helper process never reads the user's Documents folder")
  func helperNeverTouchesDocuments() throws {
    // The helper used to probe ~/Documents/huggingface for readability in
    // `ping()`. It is a second TCC toucher, in a process with no UI to explain
    // the prompt, reporting on a folder the app no longer uses.
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprASRService/ASRServiceHandler.swift"),
      encoding: .utf8)
    #expect(
      !source.contains("Documents/huggingface"),
      "the ASR helper must not reach into the user's Documents folder")
  }
}
