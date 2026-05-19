import EnviousWisprCore
import Foundation
import Testing

/// V2 fault-injection — Lane C invariant C4 (issue #291).
///
/// Asserts that the pipeline-state observer resets `isRecordingLocked` for
/// every terminal state (.complete, .error, .idle). This closes the
/// hands-free lock loop: the user double-presses to lock, dictates, and
/// when the pipeline reaches a terminal state the lock must clear so the
/// next recording starts in normal PTT mode.
///
/// PR9 of #763: the observer moved from `AppState` to
/// `DictationLifecycleCoordinator`. AppState still owns `isRecordingLocked`
/// state; the coordinator clears it via the injected `recordingLockedAccess.set`
/// closure. The test now scans the coordinator's per-pipeline `switch newState`
/// blocks and asserts each terminal arm calls `recordingLockedAccess.set(false)`.
@Suite("V2 Lane C — hands-free lock cleared on every terminal pipeline state")
struct HandsFreeLockTests {

  @Test("Parakeet observer resets isRecordingLocked on .error / .idle / .complete")
  func testHandsFreeLockClearedOnComplete_parakeet() throws {
    let body = try Self.classBodyOfCoordinator()
    let parakeetSwitch = try Self.extractSwitch(
      in: body,
      switchedOn: "newState",
      after: "private func handleParakeet(newState: PipelineState) {"
    )
    Self.assertResetsLockForCases(parakeetSwitch, cases: [".error", ".idle", ".complete"])
  }

  @Test(
    "WhisperKit observer resets isRecordingLocked on .error / .idle / .ready / .complete")
  func testHandsFreeLockClearedOnComplete_whisperKit() throws {
    let body = try Self.classBodyOfCoordinator()
    let whisperKitSwitch = try Self.extractSwitch(
      in: body,
      switchedOn: "newState",
      after: "private func handleWhisperKit(newState: WhisperKitPipelineState) {"
    )
    Self.assertResetsLockForCases(
      whisperKitSwitch, cases: [".error", ".idle", ".ready", ".complete"])
  }

  // MARK: - Source-level helpers

  private static func coordinatorURL() -> URL {
    let here = URL(fileURLWithPath: #filePath)
    return
      here
      .deletingLastPathComponent()  // V2/
      .deletingLastPathComponent()  // Services/
      .deletingLastPathComponent()  // EnviousWisprTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // <repo root>/
      .appendingPathComponent(
        "Sources/EnviousWispr/App/DictationRuntime/DictationLifecycleCoordinator.swift")
  }

  private static func classBodyOfCoordinator() throws -> String {
    try String(contentsOf: coordinatorURL(), encoding: .utf8)
  }

  /// Extract the body of the `switch` statement that follows `marker`. Cheap
  /// brace-balance scanner; no Swift parser dependency.
  private static func extractSwitch(
    in source: String, switchedOn variable: String, after marker: String
  ) throws -> String {
    guard let markerRange = source.range(of: marker) else {
      throw V2Error.markerNotFound(marker)
    }
    let scanned = source[markerRange.upperBound...]
    let switchHeader = "switch \(variable) {"
    guard let switchRange = scanned.range(of: switchHeader) else {
      throw V2Error.switchNotFound(variable, marker)
    }
    var depth = 1
    var idx = switchRange.upperBound
    while idx < scanned.endIndex {
      let ch = scanned[idx]
      if ch == "{" { depth += 1 }
      if ch == "}" {
        depth -= 1
        if depth == 0 {
          return String(scanned[switchRange.upperBound..<idx])
        }
      }
      idx = scanned.index(after: idx)
    }
    throw V2Error.unbalancedBraces
  }

  /// Each case enum value must appear in a `case` statement whose body
  /// includes `self.isRecordingLocked = false`. Cases may share one arm
  /// (e.g. `case .error, .idle, .complete:`) — the assertion is on
  /// presence-in-arm, not arm count.
  private static func assertResetsLockForCases(_ switchBody: String, cases: [String]) {
    // Split into arms by lines starting with "case "; for each case-token,
    // find the arm that mentions it and check the arm's body.
    let arms =
      switchBody
      .split(separator: "\n", omittingEmptySubsequences: false)
      .reduce(into: [(header: String, body: [String])]()) { partial, line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("case ") {
          partial.append((header: trimmed, body: []))
        } else if !partial.isEmpty {
          partial[partial.count - 1].body.append(String(line))
        }
      }

    for caseToken in cases {
      let matchingArm = arms.first { arm in
        arm.header.contains(caseToken)
      }
      #expect(
        matchingArm != nil,
        "AppState observer must have an arm matching `\(caseToken)` (regression?)")
      if let arm = matchingArm {
        let armBody = arm.body.joined(separator: "\n")
        #expect(
          armBody.contains("recordingLockedAccess.set(false)"),
          """
          Coordinator arm `\(arm.header)` must call `recordingLockedAccess.set(false)` for `\(caseToken)`. \
          Removing this reset breaks hands-free lock cleanup on terminal pipeline state.
          Arm body:
          \(armBody)
          """)
      }
    }
  }

  enum V2Error: Error {
    case markerNotFound(String)
    case switchNotFound(String, String)
    case unbalancedBraces
  }
}
