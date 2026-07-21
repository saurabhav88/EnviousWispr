import Foundation

// MARK: - Scenario inventory (epic #827, PR-2 plan §3.8; PR-1 §11.1)
//
// The 37 canonical-ID heart-path scenarios, each encoded as data with a full
// `ExpectedOutcome`. `ScenarioInventoryTests` asserts the EXACT ID set is
// present (by ID, not a count — a count passes while a scenario is silently
// swapped). In PR-2 these are data; from PR-3 the `ScenarioRunner` executes
// each against the real kernel and they become merge-blocking.
//
// The two §1.3 regression locks (`R1`, `R2`) are non-negotiable: PR-H1 (#828)
// was dropped because this inventory locks the WhisperKit stop-during-startup
// case. `ScenarioInventoryTests` asserts `R1` and `R2` by ID specifically.
//
// Step scripts drive the real kernel (PR-3): the `ScenarioRunner` executes
// each against the `RecordingSessionKernel` behind the test-side wrapper. The
// `ExpectedOutcome` is the contract every row carries.
//
// PR-3 closed the two PR-2-deferred obligations (R2 stale-callback injection,
// A18 mid-session engine switch) and tightened the wedge scripts (A4, A13)
// and the cancel-while-transcribing script (A8) so each lands its trigger in
// a deterministic FSM state against the real kernel (PR-3 plan §3.6, §3.7,
// §14a).

enum ScenarioInventory {

  /// All 37 canonical scenarios.
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
        .trigger(.start), .advanceClock(ticks: 4), .trigger(.cancel),
      ],
      // .wedgeOnLoad emits a few load-progress ticks then goes silent — the
      // kernel's wedge watcher arms on the first tick and, after a stall
      // window of logical time elapses with the adapter still not ready,
      // transitions to failed(.modelWedged) (PR-3 plan §3.7). The advanceClock
      // step supplies that window; the trailing cancel then hits a terminal
      // state and is ignored. A model load that THROWS is a separate behavior
      // (failed(.modelLoadFailed)).
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
      // A `slowFinalize` engine holds the kernel in `transcribing` (a genuine
      // in-flight finalize, no wedge) so the cancel lands deterministically
      // inside that state — distinct from L5, where a synchronous finalize
      // has already carried the kernel into `finalizing` (PR-3 plan §14a).
      id: "A8", name: "cancel while transcribing",
      steps: [
        .engine(.setBehavior(.slowFinalize(ticksToFinal: 3, text: "in flight"))),
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
      // .wedgeOnFinalize emits a few finalize-progress ticks then goes silent;
      // the kernel's finalize wedge watcher arms on the first tick and fires
      // after a stall window of logical time (PR-3 plan §3.7). The advanceClock
      // step supplies that window; the trailing cancel hits a terminal state.
      id: "A13", name: "adapter wedge on finalize",
      steps: [
        .engine(.setBehavior(.wedgeOnFinalize)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .advanceClock(ticks: 4), .trigger(.cancel),
      ],
      expected: ExpectedOutcome(
        terminalState: .failed(.asrWedged), pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .recoverableError)),
    Scenario(
      // #1707 Phase 2: a post-capture decode failure now spends one live
      // retry before a terminal `.failed`. The FakeEngine's `retryDecode`
      // default scripts a SUCCESSFUL retry (A23 covers that rescue path), so
      // this scenario must explicitly exhaust the retry too to keep testing
      // genuine, unrescuable engine failure.
      id: "A14", name: "adapter fails after audio captured, retry also exhausted",
      steps: [
        .engine(.setBehavior(.crashOnFinalize)),
        .engine(.setRetryDecodeResult(.failed(.decodeFailed))),
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
      // The mid-session switch is a factory-preference request (PR-6 owns the
      // factory). The kernel binds its adapter at `preparing` and holds it for
      // the session's lifetime, so the request is inert against the running
      // session — the transcript stays "kept" (PR-3 plan §3.6).
      id: "A18", name: "engine switch attempted during active session",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "kept"))),
        .trigger(.start), .capture(.deliverBuffer),
        .engine(.requestMidSessionSwitch),
        .trigger(.stop), .expectState(.completed),
      ],
      // .exact("kept"): the mid-session switch request must not affect the
      // running session. .nonEmpty would pass even on a wrong adapter swap.
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
    // A20–A22: #964 faint-speech recovery. Silero reports zero segments
    // (`.confirmedNoSpeech`), but the raw buffer above the dead-air floor must
    // reach ASR instead of being dropped.
    Scenario(
      id: "A20", name: "#964 zero segments + energy -> ASR recovers faint speech",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "actually let's go"))),
        .vad(.evidence(.confirmedNoSpeech)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
    Scenario(
      id: "A21", name: "#964 zero segments + energy + empty decode -> noSpeech (R2)",
      steps: [
        // Reaching ASR on the energy path then getting an empty decode is
        // fan/room noise, NOT a failure — the kernel must map it to `.noSpeech`,
        // never `.failed(.asrEmpty)`, despite the adapter's `hadSpeechEvidence`.
        .engine(.setBehavior(.empty(hadSpeechEvidence: true))),
        .vad(.evidence(.confirmedNoSpeech)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .noSpeech, pasteCount: 0, pasteOutcome: .none,
        transcript: .none)),
    Scenario(
      id: "A22", name: "#964 zero segments + dead air -> gate still skips ASR",
      steps: [
        // A silent tap (sub-floor amplitude) must still skip ASR entirely — the
        // engine is never consulted, so the configured batch success is unused.
        .engine(.setBehavior(.batchSuccess(text: "should never paste"))),
        .vad(.evidence(.confirmedNoSpeech)),
        .trigger(.start), .capture(.deliverSilentBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .noSpeech, pasteCount: 0, pasteOutcome: .none,
        transcript: .none)),
    Scenario(
      // #1707 Phase 2: the rescue counterpart to A14. A post-capture decode
      // failure spends its one live retry; `FakeEngine.retryDecodeResult`'s
      // default already scripts a successful "retried transcript" decode, so
      // this scenario proves the session completes and delivers it instead
      // of terminating on the first failure.
      id: "A23", name: "adapter fails once, Phase 2 retry rescues it",
      steps: [
        .engine(.setBehavior(.crashOnFinalize)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .exact("retried transcript"))),
  ]

  // MARK: §1.3 regression locks (R1, R2)

  private static let regressionLocks: [Scenario] = [
    Scenario(
      id: "R1", name: "WhisperKit stop-during-startup (regression lock)",
      // No trailing `expectState(.discarded)` — the terminal is clock-gated
      // (the warm-up completes only after the clock advances), and under the
      // interleaving sweep's `zeroTick` schedule that advance is zeroed, so a
      // mid-scenario terminal assertion cannot hold. `ExpectedOutcome`'s
      // `terminalState` is the authoritative check (PR-3 plan §3.7).
      steps: [
        .engine(.setBehavior(.slowLoad(ticksToReady: 5))),
        .trigger(.start), .trigger(.stop), .advanceClock(ticks: 5),
      ],
      expected: ExpectedOutcome(
        terminalState: .discarded, pasteCount: 0, pasteOutcome: .none,
        transcript: .none),
      tags: [.concurrencySensitive]),
    Scenario(
      // The stale auto-stop signal carries a PRIOR session's `SessionID`. The
      // kernel drops it (FSM invariant 7) — the current recording is not
      // terminated by a finished session's latch. `expectState(.recording)`
      // proves the drop; the real stop then completes normally (PR-3 §3.6).
      id: "R2", name: "Parakeet stale-latch (regression lock)",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "current"))),
        .trigger(.start), .capture(.deliverBuffer),
        .vad(.staleAutoStop), .expectState(.recording),
        .trigger(.stop), .expectState(.completed),
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
    // #1548 D2: a no-buffer stall with no audio ever received (`bufferCountThisSession
    // == 0`) is the dead-mic case — it concludes `.noTransport` (projected to
    // `.failed(.noAudioCaptured)`), not the live `.captureStall` exit. The
    // stall-AFTER-a-buffer case (genuine `.captureStalled`) is C4.
    Scenario(
      id: "C3", name: "capture stream stalls with no buffers received (no transport)",
      steps: [.trigger(.start), .capture(.stall), .trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .failed(.noAudioCaptured), pasteCount: 0, pasteOutcome: .none,
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
    // #1408: the device dies mid-sentence but the capture manager is still
    // holding what was said. We now transcribe and paste it instead of throwing
    // it away. This scenario asserted `.audioInterrupted` / pasteCount 0 until
    // salvage landed — the flip IS the feature.
    Scenario(
      id: "C5", name: "audio route / device change mid-session (salvaged)",
      steps: [.trigger(.start), .capture(.deliverBuffer), .capture(.routeChange)],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty, userVisibleError: nil)),
    // #1707: the ASR helper dies mid-sentence, but capture (in-process, #1543)
    // is completely unaffected and still holds every sample. We now confirm
    // the engine is ready (reconnect/reload if needed) and transcribe+paste
    // instead of throwing the take away. This scenario asserted
    // `.asrInterrupted` / pasteCount 0 until the salvage landed — the flip IS
    // the feature, same shape as C5's #1408 flip.
    Scenario(
      id: "C6", name: "XPC capture crash / reconnect (salvaged)",
      steps: [.trigger(.start), .capture(.deliverBuffer), .capture(.xpcCrash)],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty, userVisibleError: nil)),
    // #1548 D2: with the first-buffer gate gone, capture establishes straight to
    // `.live`, so a device that dies before the first buffer now routes through the
    // ONE `.live` interruption path (§3.7) — not the old Arming no-transport
    // fallback. It concludes `.audioInterrupted` (rendering `.interruption`); the
    // crash-recovery spool is still retained via that failure terminal. This is the
    // deliberate unification: one interruption path, not two. The salvage FLOOR for
    // a device that dies mid-recording WITH audio is C5 + the salvage-suite floor
    // tests.
    Scenario(
      id: "C8", name: "device dies before the first buffer (interruption, spool retained)",
      steps: [.trigger(.start), .capture(.interrupt), .capture(.stall)],
      expected: ExpectedOutcome(
        terminalState: .audioInterrupted, pasteCount: 0, pasteOutcome: .none,
        transcript: .none, userVisibleError: .interruption)),
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
      id: "L6", name: "transcript disk-save fails but delivery still completes (#1167)",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "delivered text"))),
        .limb(.storageWriteFails),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      // #1167: a history-save throw is best-effort — the kernel absorbs it and
      // still delivers the polished text, reaching `.completed` with no
      // user-visible error. (The pill + recovery-spool retention are App-layer
      // concerns covered in the wiring / planner / handler unit tests.)
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty)),
  ]

  /// The exact canonical ID set — `ScenarioInventoryTests` asserts the inventory
  /// matches this set with no addition, drop, or near-duplicate swap.
  static let canonicalIDs: Set<String> = [
    "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10",
    "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18", "A19",
    "A20", "A21", "A22", "A23",
    "R1", "R2",
    "C1", "C2", "C3", "C4", "C5", "C6", "C8",
    "L1", "L2", "L3", "L4", "L5", "L6",
  ]
}
