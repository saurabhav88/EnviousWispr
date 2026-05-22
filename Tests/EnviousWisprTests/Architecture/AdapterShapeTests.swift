import Foundation
import Testing

// MARK: - AdapterShapeTests (epic #827, PR-4 §3.11)
//
// The lightweight precursor to PR-9's permanent kernel-ownership freeze test.
// An `ASREngineAdapter` owns its own ASR and rescue and NOTHING else (epic §4):
// it must never grow a second orchestration brain. This suite scans the
// adapter source for tokens that signal a recording-session FSM leaking into
// the adapter — `RecordingSessionState`, `transition(`, kernel trigger method
// DEFINITIONS, FSM-style `state =` mutation.
//
// It does NOT ban legitimate engine-session bookkeeping (a streaming-active
// flag, the retained PCM buffer, an in-flight-load flag, a terminal flag) —
// those are required to satisfy the `ASREngineAdapter` MUST / MUST NOT clauses
// (Codex finding 46). The positive / adversarial / negative-control tests
// below pin that boundary.

@Suite struct AdapterShapeTests {

  /// A token that, present in an adapter source file, signals a second
  /// orchestration brain. Each pattern is a whole-token regex.
  private static let fsmTokenPatterns: [String] = [
    #"\bRecordingSessionState\b"#,  // the kernel's FSM state enum
    #"\btransition\("#,  // an FSM transition call
    #"func\s+requestStop\b"#,  // a kernel trigger method, DEFINED in the adapter
    #"func\s+cancelRecording\b"#,  // a kernel trigger method, DEFINED in the adapter
    #"\bstate\s*="#,  // FSM-style mutation of a property named `state`
  ]

  private static let adapterRelativePath =
    "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift"

  // MARK: Positive — the real adapter passes

  @Test("the production ParakeetEngineAdapter carries no FSM tokens")
  func realAdapterIsClean() throws {
    let url = repoRoot().appending(path: Self.adapterRelativePath)
    let source = try String(contentsOf: url, encoding: .utf8)
    let violations = Self.scan(source)
    #expect(
      violations.isEmpty,
      """
      ParakeetEngineAdapter.swift carries orchestration-FSM tokens:
      \(violations.joined(separator: "\n"))
      An adapter owns ASR + rescue only — the kernel owns the recording-session
      FSM (epic §4, PR-4 §3.11).
      """)
  }

  // MARK: Adversarial — an adapter with FSM tokens fails

  @Test("an adapter source with a transition call is flagged")
  func adversarialTransitionCall() {
    let source = """
      @MainActor final class RogueAdapter: ASREngineAdapter {
        private var state: RecordingSessionState = .idle
        func finalize() async -> ASREngineOutcome {
          transition(to: .completed)
          return .cancelled
        }
      }
      """
    let violations = Self.scan(source)
    #expect(!violations.isEmpty, "RecordingSessionState + transition( + state = must be flagged")
  }

  @Test("an adapter that defines a kernel trigger method is flagged")
  func adversarialTriggerDefinition() {
    let source = """
      @MainActor final class RogueAdapter: ASREngineAdapter {
        func requestStop() { }
      }
      """
    #expect(!Self.scan(source).isEmpty, "a defined kernel trigger method must be flagged")
  }

  // MARK: Negative control — legitimate session bookkeeping passes

  @Test("an adapter with legitimate engine-session bookkeeping is not flagged")
  func negativeControlBookkeepingPasses() {
    let source = """
      @MainActor final class CleanAdapter: ASREngineAdapter {
        private var streamingActive = false
        private var isTerminal = false
        private var isCancelled = false
        private var isLoadInFlight = false
        private var retainedPCM: [Float] = []
        func cancel() async {
          isCancelled = true
          isTerminal = true
          retainedPCM.removeAll()
        }
      }
      """
    #expect(
      Self.scan(source).isEmpty,
      "session bookkeeping flags / buffers are allowed — only FSM tokens are banned")
  }

  // MARK: Scanner

  /// Return `"line N: text"` for every line carrying an FSM token.
  static func scan(_ source: String) -> [String] {
    let regexes = fsmTokenPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    var violations: [String] = []
    for (idx, line) in source.split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      let text = String(line)
      let ns = text as NSString
      let range = NSRange(location: 0, length: ns.length)
      for regex in regexes where regex.firstMatch(in: text, range: range) != nil {
        violations.append("line \(idx + 1): \(text.trimmingCharacters(in: .whitespaces))")
        break
      }
    }
    return violations
  }

  /// Repo root, anchored off `#filePath` — this file lives at
  /// `Tests/EnviousWisprTests/Architecture/`, four levels below the root.
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
