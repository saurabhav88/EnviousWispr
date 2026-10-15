import Foundation
import Testing

/// #1386 PR-2; #3735. Freezes the guarantee that a Whisper model is opened in exactly one place.
///
/// Before #1386 PR-2 three routes mapped the multilingual model outside its gate (the ASR
/// manager's own backend, an XPC proxy, the helper behind it). #3735 replaced WhisperKit with
/// transcribe.cpp, whose native calls are not cooperatively cancellable either, so the same
/// hole has a new shape: native code reached from anywhere but `TranscribeCppExecutor`, which
/// keeps at most one native run and drains an aborted run before any unload or free.
///
/// This is a STRUCTURAL freeze, not a behavior test: a new caller must fail the build rather
/// than wait for a rare, timing-dependent bug in the field. It reads source text, so it catches
/// a caller no runtime test exercises. The admission halves (the dictation model loads only an
/// admitted path; the preview refuses an unadmitted model) are behavior tests:
/// `TranscribeCppPreviewRealBoundaryTests` and the Whisper adapter/backend suites.
@Suite(.tags(.driftGuard)) struct WhisperGatedLoadFreezeTests {

  /// The ONLY production file that may import the native transcribe.cpp module.
  private static let nativeBoundary =
    "Sources/EnviousWisprTranscribeCpp/TranscribeCppSession.swift"

  /// The ONLY production file that may open a native session (which loads a model).
  private static let sessionOwner =
    "Sources/EnviousWisprTranscribeCpp/TranscribeCppExecutor.swift"

  private static let importPattern = try! NSRegularExpression(
    pattern: "^\\s*(@[A-Za-z_]+\\s+)*import\\s+CTranscribe\\b")

  /// `TranscribeCppSession(` or `TranscribeCppSession.init(` as a whole identifier.
  private static let constructionPattern = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9_])TranscribeCppSession\\s*(\\(|\\.init\\b)")

  private func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
    pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
  }

  /// Comments explain the boundary and legitimately name these calls. Only code counts.
  private func isComment(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
  }

  private func codeLines(in path: String) throws -> [(number: Int, text: String)] {
    let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
      .map { ($0.offset + 1, String($0.element)) }
      .filter { !isComment($0.1) }
  }

  private func swiftSources() throws -> [String] {
    let root = RepoRoot.sourceURL("Sources")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      Issue.record("could not walk \(root.path)")
      return []
    }
    let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
      .map { $0.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "") }
    #expect(files.count > 100, "the walk must reach the source tree, found \(files.count)")
    return files
  }

  @Test("only the session file imports the native transcribe.cpp module")
  func nativeImportIsConfined() throws {
    var importers: [String] = []
    for path in try swiftSources() {
      for line in try codeLines(in: path) where matches(Self.importPattern, line.text) {
        importers.append("\(path):\(line.number)")
      }
    }
    #expect(
      importers.map { $0.components(separatedBy: ":")[0] } == [Self.nativeBoundary],
      """
      CTranscribe is imported outside \(Self.nativeBoundary): \(importers). Native calls \
      must go through TranscribeCppExecutor, which serializes them and drains an aborted run \
      before an unload or free.
      """)
  }

  @Test("only the executor opens a native session, exactly once")
  func sessionConstructionIsConfined() throws {
    var sites: [String] = []
    for path in try swiftSources() where path != Self.nativeBoundary {
      for line in try codeLines(in: path) where matches(Self.constructionPattern, line.text) {
        sites.append("\(path):\(line.number)")
      }
    }
    #expect(
      sites.count == 1 && sites.first?.hasPrefix(Self.sessionOwner + ":") == true,
      """
      A native session (and so a model load) is opened outside \(Self.sessionOwner), or \
      more than once there: \(sites). Route the caller through TranscribeCppExecutor.
      """)
  }

  @Test("the ASR manager owns no Whisper backend")
  func managerNeverOwnsAWhisperBackend() throws {
    // #1386 PR-2 deleted this route from the manager; #1908 deleted the XPC proxy and helper.
    // The manager is Parakeet-only; recovery and Diagnostics reach the active engine through
    // ActiveEngineOperation.
    let path = "Sources/EnviousWisprASR/ASRManager.swift"
    let offenders = try codeLines(in: path).filter {
      $0.text.contains("TranscribeCppWhisperBackend") || $0.text.contains("TranscribeCppExecutor")
    }.map { "\(path):\($0.number)" }
    #expect(offenders.isEmpty, "the ASR manager owns a Whisper backend again: \(offenders)")
  }
}
