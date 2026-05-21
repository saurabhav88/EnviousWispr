import Foundation

// MARK: - Scenario inventory (epic #827, PR-2 plan §3.8; PR-1 §11.1)
//
// The 33 canonical-ID heart-path scenarios, each encoded as data with a full
// `ExpectedOutcome`. `ScenarioInventoryTests` asserts the EXACT ID set is
// present (by ID, not a count — a count passes while a scenario is silently
// swapped). In PR-2 these are data; from PR-3 the `ScenarioRunner` executes
// each against the real kernel and they become merge-blocking.
//
// The two §1.3 regression locks (`R1`, `R2`) are non-negotiable: PR-H1 (#828)
// was dropped because this inventory locks the WhisperKit stop-during-startup
// case. `ScenarioInventoryTests` asserts `R1` and `R2` by ID specifically.
//
// Step scripts are representative — they describe the path PR-3 wires the
// kernel to walk. The `ExpectedOutcome` is the contract every row carries.
//
// ── PR-3 OBLIGATIONS (founder call 2026-05-21: ship the inventory now, finish
//    these two when the kernel lands) ───────────────────────────────────────
// Two scenarios cannot be precisely driven until PR-3's kernel seams exist,
// because the stimulus they need IS a kernel-seam question:
//
//  • R2 (Parakeet stale-latch): needs a directive that emits a callback /
//    completion stamped with a PRIOR session's `SessionID`. PR-2's DSL has no
//    stale-callback injection because "what a stale callback looks like" is
//    defined by the kernel's task/callback seam (PR-3). PR-3 adds the
//    directive and R2's script gains an explicit prior-session stale signal.
//
//  • A18 (engine switch during active session): PR-2 models a behavior change
//    by mutating the live `FakeEngine` (`EngineDirective.setBehavior`). A real
//    mid-session switch is a request against the adapter FACTORY (PR-6), not a
//    mutation of the running adapter. PR-3/PR-6 model the switch as factory
//    state so A18 proves the active session keeps its original adapter.
//
// Both rows ship now with correct IDs + `ExpectedOutcome` so the inventory is
// complete and `R1`/`R2` stay drop-resistant; PR-3 tightens their stimulus.

enum ScenarioInventory {

  /// All 33 canonical scenarios.
  static let all: [Scenario] =
    asrSide + regressionLocks + captureSide + limbSide

  /// The concurrency-tagged subset rerun under the interleaving sweep (§3.5).
  static var concurrencySensitive: [Scenario] {
    all.filter(\.isConcurrencySensitive)
  }

  // MARK: ASR-side (A1–A19)

  private static let asrSide: [Scenario] = [
    Scenario(
      id: "A1", name: "normal batch success",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "hello world"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A2", name: "normal streaming success",
      steps: [
        .engine(.setBehavior(.streamingSuccess(partials: ["hel"], final: "hello"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A3", name: "slow warm-up then success",
      steps: [
        .engine(.setBehavior(.slowLoad(ticksToReady: 3))),
        .trigger(.start), .advanceClock(ticks: 3), .capture(.deliverBuffer),
        .trigger(.stop), .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A4", name: "warm-up wedge",
      steps: [
        .engine(.setBehavior(.wedgeOnLoad)),
        .trigger(.start), .trigger(.cancel),
      ],
      // .wedgeOnLoad is the silent-progress wedge — the kernel detects it via
      // loadProgress absence and transitions to failed(.modelWedged). A model
      // load that THROWS is a separate behavior (failed(.modelLoadFailed)).
      expected: ExpectedOutcome(
        terminalState: .failed(.modelWedged), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "A5", name: "record then immediate stop (sub-minimum duration)",
      steps: [.trigger(.start), .trigger(.stop), .expectState(.discarded)],
      expected: ExpectedOutcome(
        terminalState: .discarded, pasteCount: 0, pasteOutcome: .none,
        transcript: .none)),
    Scenario(
      id: "A6", name: "long recording",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "long dictation"))),
        .trigger(.start), .capture(.deliverBuffer), .capture(.deliverBuffer),
        .capture(.deliverBuffer), .trigger(.stop), .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A7", name: "cancel while recording",
      steps: [
        .trigger(.start), .capture(.deliverBuffer), .trigger(.cancel),
        .expectState(.cancelled),
      ],
      expected: ExpectedOutcome(
        terminalState: .cancelled, pasteCount: 0, pasteOutcome: .none,
        transcript: .none),
      tags: [.concurrencySensitive]),
    Scenario(
      id: "A8", name: "cancel while transcribing",
      steps: [
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .trigger(.cancel), .expectState(.cancelled),
      ],
      expected: ExpectedOutcome(
        terminalState: .cancelled, pasteCount: 0, pasteOutcome: .none,
        transcript: .none),
      tags: [.concurrencySensitive]),
    Scenario(
      id: "A9", name: "adapter partials then final",
      steps: [
        .engine(.setBehavior(.streamingSuccess(partials: ["a", "ab"], final: "abc"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A10", name: "adapter final without partials",
      steps: [
        .engine(.setBehavior(.streamingSuccess(partials: [], final: "abc"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A11", name: "adapter empty result with speech evidence",
      steps: [
        .engine(.setBehavior(.empty(hadSpeechEvidence: true))),
        .vad(.evidence(.voiced)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.asrEmpty), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "A12", name: "adapter empty result, no speech",
      steps: [
        .engine(.setBehavior(.empty(hadSpeechEvidence: false))),
        .vad(.evidence(.confirmedNoSpeech)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .noSpeech, pasteCount: 0, pasteOutcome: .none,
        transcript: .none)),
    Scenario(
      id: "A13", name: "adapter wedge on finalize",
      steps: [
        .engine(.setBehavior(.wedgeOnFinalize)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .trigger(.cancel),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.asrWedged), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "A14", name: "adapter fails after audio captured",
      steps: [
        .engine(.setBehavior(.crashOnFinalize)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.asrFailed), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "A15", name: "double-start / rapid hotkey",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "once"))),
        .trigger(.start), .trigger(.start), .capture(.deliverBuffer),
        .trigger(.stop), .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty),
      tags: [.concurrencySensitive]),
    Scenario(
      id: "A16", name: "stop without active session",
      steps: [.trigger(.stop), .expectState(.idle)],
      expected: ExpectedOutcome(
        terminalState: .idle, pasteCount: 0, pasteOutcome: .none,
        transcript: .none)),
    Scenario(
      id: "A17", name: "engine switch between sessions",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "first"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .trigger(.reset),
        .engine(.setBehavior(.batchSuccess(text: "second"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .exact("second"))),
    Scenario(
      // PR-3 OBLIGATION: model the mid-session switch as an adapter-FACTORY
      // request (PR-6 seam), not a mutation of the live FakeEngine — see the
      // PR-3 OBLIGATIONS block at the top of this file.
      id: "A18", name: "engine switch attempted during active session",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "kept"))),
        .trigger(.start), .capture(.deliverBuffer),
        .engine(.setBehavior(.batchSuccess(text: "ignored"))),
        .trigger(.stop), .expectState(.completed),
      ],
      // .exact("kept"): the mid-session switch must be ignored. .nonEmpty
      // would pass even if the active session wrongly used the new engine.
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .exact("kept")),
      tags: [.concurrencySensitive]),
    Scenario(
      id: "A19", name: "warm-up with nil loadProgress stream",
      steps: [
        .engine(.setLoadProgressAbsent(true)),
        .engine(.setBehavior(.slowLoad(ticksToReady: 2))),
        .trigger(.start), .advanceClock(ticks: 2), .capture(.deliverBuffer),
        .trigger(.stop), .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
  ]

  // MARK: §1.3 regression locks (R1, R2)

  private static let regressionLocks: [Scenario] = [
    Scenario(
      id: "R1", name: "WhisperKit stop-during-startup (regression lock)",
      steps: [
        .engine(.setBehavior(.slowLoad(ticksToReady: 5))),
        .trigger(.start), .trigger(.stop), .advanceClock(ticks: 5),
        .expectState(.discarded),
      ],
      expected: ExpectedOutcome(
        terminalState: .discarded, pasteCount: 0, pasteOutcome: .none,
        transcript: .none),
      tags: [.concurrencySensitive]),
    Scenario(
      // PR-3 OBLIGATION: add a stale-callback injection directive (a callback
      // stamped with a prior session's SessionID) and drive it here — see the
      // PR-3 OBLIGATIONS block at the top of this file. Until then this row
      // pins the happy path; it does not yet PROVE the stale-drop.
      id: "R2", name: "Parakeet stale-latch (regression lock)",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "current"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty),
      tags: [.concurrencySensitive]),
  ]

  // MARK: Capture-side (C1–C6)

  private static let captureSide: [Scenario] = [
    Scenario(
      id: "C1", name: "mic permission denied / revoked",
      steps: [.capture(.permissionDenied), .trigger(.start)],
      expected: ExpectedOutcome(
        terminalState: .failed(.permissionDenied), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "C2", name: "capture start failure",
      steps: [.capture(.startFailure), .trigger(.start)],
      expected: ExpectedOutcome(
        terminalState: .failed(.captureStartFailed), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "C3", name: "capture stream stalls before first buffer",
      steps: [.trigger(.start), .capture(.stall), .trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .failed(.captureStalled), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "C4", name: "capture stalls after speech evidence",
      steps: [
        .trigger(.start), .capture(.deliverBuffer), .capture(.stall),
        .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.captureStalled), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      id: "C5", name: "audio route / device change mid-session",
      steps: [.trigger(.start), .capture(.deliverBuffer), .capture(.routeChange)],
      expected: ExpectedOutcome(
        terminalState: .audioInterrupted, pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .interruption)),
    Scenario(
      id: "C6", name: "XPC capture crash / reconnect",
      steps: [.trigger(.start), .capture(.deliverBuffer), .capture(.xpcCrash)],
      expected: ExpectedOutcome(
        terminalState: .asrInterrupted, pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
  ]

  // MARK: Limb-side (L1–L6)

  private static let limbSide: [Scenario] = [
    Scenario(
      id: "L1", name: "LLM polish fails after transcript",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "raw asr text"))),
        .limb(.polishFails),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "L2", name: "custom-words injection fails",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "raw asr text"))),
        .limb(.customWordsFails),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "L3", name: "filler-removal fails",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "raw asr text"))),
        .limb(.fillerRemovalFails),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "L4", name: "paste fails after transcript (clipboard-only fallback)",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "delivered text"))),
        .paste(.fail),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 0, pasteOutcome: .clipboardOnly,
        transcript: .nonEmpty)),
    Scenario(
      id: "L5", name: "cancel arrives during finalizing (safe point)",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "delivered text"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .trigger(.cancel), .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty),
      tags: [.concurrencySensitive]),
    Scenario(
      id: "L6", name: "transcript disk-save fails after transcript",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "delivered text"))),
        .limb(.storageWriteFails),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.storageFailed), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
  ]

  /// The exact canonical ID set — `ScenarioInventoryTests` asserts the inventory
  /// matches this set with no addition, drop, or near-duplicate swap.
  static let canonicalIDs: Set<String> = [
    "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10",
    "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18", "A19",
    "R1", "R2",
    "C1", "C2", "C3", "C4", "C5", "C6",
    "L1", "L2", "L3", "L4", "L5", "L6",
  ]
}
