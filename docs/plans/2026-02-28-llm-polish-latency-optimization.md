# Pipeline Latency Optimization

**Date:** 2026-02-28
**Status:** Draft — awaiting review
**Goal:** Reduce end-to-end time from recording stop to clipboard paste, targeting <1.5s for Gemini 2.5 Flash polish of a 2-minute recording (currently 3-7s). Achieve this by overlapping ASR with recording, streaming LLM polish, and eliminating unnecessary delays.

---

## 1. Problem Statement

Users experience 3-7 seconds between stopping a recording and seeing polished text pasted. SuperWhisper and competing apps achieve sub-second perceived latency for the same workflow. The delay breaks flow state and makes dictation feel sluggish compared to alternatives.

**Reframed goal** (per external review): We're optimizing the **post-release "pulsing" time** — everything the user waits through after releasing the hotkey. Anything that starts work only after release will always feel slow. The roadmap must:
1. Overlap work during recording (streaming ASR)
2. Reduce true polish latency (streaming LLM + connection reuse)
3. Improve perceived progress (UI feedback during polishing)

Current user configuration: **Gemini 2.5 Flash** — already the fastest mainstream cloud LLM option (0.35-0.46s TTFT, 215-248 tok/s per Artificial Analysis benchmarks). Model selection is not the bottleneck.

## 2. Current Pipeline Latency Budget

Traced from `TranscriptionPipeline.stopAndTranscribe()` through to `PasteService.pasteToActiveApp()`:

| Phase | File(s) | Estimated Time | Post-Release? |
|-------|---------|---------------|---------------|
| Audio stop + VAD filter | `TranscriptionPipeline.swift:120-182` | <1ms | Yes |
| **ASR transcription (Parakeet)** | `ParakeetBackend.swift:55-78` | **~1-2s** | **Yes — target for overlap** |
| Word correction | `WordCorrectionStep.swift` | <10ms | Yes |
| **LLM polish (Gemini API)** | `GeminiConnector.swift:16-96` | **1.5-5s** | **Yes — target for streaming** |
| Transcript save | `TranscriptStore.swift:19-24` | <5ms | Yes |
| App re-activation delay | `TranscriptionPipeline.swift:247` | **150ms** | Yes |
| Clipboard write + paste | `PasteService.swift:79-115` | <5ms | Yes |
| Clipboard restore delay | `TranscriptionPipeline.swift:260` | **300ms** | Yes |
| **Total post-release** | | **~3-7.5s** | **Everything** |

### Key Insight

Currently **100% of work happens post-release**. By moving ASR into the recording phase, we eliminate 1-2s from the post-release budget entirely.

**Target post-release budget after optimization:**

| Phase | Target Time | How |
|-------|-------------|-----|
| Finalize streaming ASR (last chunk) | ~50-100ms | Item 6 |
| LLM polish (streaming, warm connection) | ~1.2-1.8s | Items 2, 3, 5 |
| App re-activation | 150ms | Unchanged |
| Clipboard write + paste | <5ms | Unchanged |
| Clipboard restore | 200ms | Item 4 |
| **Total post-release** | **~1.6-2.3s** | |

## 3. Research Findings

### 3.1 Competitor Approaches

| App | Approach | Claimed Latency |
|-----|----------|----------------|
| **SuperWhisper** | Whisper.cpp local + optional cloud LLM (streamed). Hybrid local/cloud. | Sub-second perceived |
| **Dictly** | Live pipeline that refines as you speak. Entirely on-device. | Sub-100ms first-word |
| **Dictato** | Pure on-device, no LLM polish step. | 80ms |
| **HN Parakeet+MLX app** | Parakeet + local Qwen 0.6B-8B via SwiftMLX for polish. Zero network. | "Very low latency" |

**Key insight**: The fastest apps either skip LLM polish entirely, run it on-device, or overlap ASR with recording so the post-release tail is just the LLM step.

Sources:
- [Choosing the Right AI Dictation App](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac)
- [HN: Parakeet+MLX Dictation App](https://news.ycombinator.com/item?id=46777816)
- [HN: Whispering Dictation App](https://news.ycombinator.com/item?id=44942731)

### 3.2 Cloud Model Latency Benchmarks

From [Artificial Analysis](https://artificialanalysis.ai/) (median P50 over 72h):

| Provider/Model | TTFT | Output Speed | Est. Total (300 tok output) |
|---|---|---|---|
| **Gemini 2.5 Flash** (AI Studio) | 0.46s | 248 tok/s | **~1.7s** |
| **Gemini 2.5 Flash** (Vertex) | 0.35s | 215 tok/s | **~1.7s** |
| **Gemini 2.0 Flash** (Vertex) | 0.32s | 146 tok/s | **~2.4s** |
| **GPT-4o-mini** (OpenAI) | 0.53s | 50 tok/s | **~6.5s** |
| **GPT-4o-mini** (Azure) | 1.12s | 73 tok/s | **~5.2s** |

Sources:
- [GPT-4o-mini Benchmarks](https://artificialanalysis.ai/models/gpt-4o-mini/providers)
- [Gemini 2.0 Flash Benchmarks](https://artificialanalysis.ai/models/gemini-2-0-flash/providers)
- [Gemini 2.5 Flash Benchmarks](https://artificialanalysis.ai/models/gemini-2-5-flash/providers)

### 3.3 Streaming Implementation in Swift

**Approach**: Use `URLSession.bytes(for:)` (macOS 12+) which returns `AsyncBytes`. Iterate with `for try await line in stream.lines` to parse SSE `data:` prefixed lines.

**Gemini streaming endpoint**: `streamGenerateContent?alt=sse` — returns Server-Sent Events. Request body is **identical** to `generateContent` (including `systemInstruction`). Only the URL path changes. Each SSE chunk contains `candidates[0].content.parts[0].text` as a fragment to concatenate. `finishReason` appears only in the final chunk.

**Gotchas from developer community:**
- URLSession `bytes(for:)` `timeoutIntervalForRequest` applies to idle time between chunks, not total time — safe for streaming
- Must reuse a single `URLSession` instance — per-request sessions prevent HTTP/2 multiplexing
- URLSession keeps strong ref to delegate until invalidated — must call `finishTasksAndInvalidate()` on app termination
- Task cancellation with `for await` loops may not terminate cleanly — need explicit handling
- No client-side control over TLS caching — server decides; both Google and OpenAI support TLS 1.3 session resumption

Sources:
- [Streaming ChatGPT in Swift with AsyncSequence](https://zachwaugh.com/posts/streaming-messages-chatgpt-swift-asyncsequence)
- [nate-parrott/openai-streaming-completions-swift](https://github.com/nate-parrott/openai-streaming-completions-swift)
- [Swift Forums: Single URLSession vs Per-Request](https://forums.swift.org/t/single-urlsession-for-all-requests-versus-per-request-performance/68002)
- [Swift Forums: TLS Handshake Caching](https://forums.swift.org/t/caching-tls-handshake-when-using-urlsession/50323)
- [Apple: URLSession Memory Leak](https://developer.apple.com/forums/thread/673743)
- [OpenAI Latency Optimization Guide](https://developers.openai.com/api/docs/guides/latency-optimization)

### 3.4 FluidAudio StreamingAsrManager (Key Discovery)

FluidAudio already ships a **`StreamingAsrManager`** purpose-built for live transcription during recording:

- **API**: `streamAudio(_ buffer: AVAudioPCMBuffer)` — feed audio buffers directly from the tap
- **Sliding-window processing**: Only processes new audio incrementally (not the full buffer each time)
- **Two-tier output**: `volatileTranscript` (may change with more context) and `confirmedTranscript` (stable)
- **AsyncStream**: Emits `StreamingTranscriptionUpdate` with `text`, `isConfirmed`, `confidence`, `tokenTimings`
- **Decoder state preservation**: Maintains LSTM state across chunks for incremental decoding
- **No hardware contention**: CoreML uses Neural Engine, audio capture uses CPU real-time threads — completely separate paths. Verified: `computeUnits = .cpuAndNeuralEngine`, no GPU.

Also available: `StreamingAsrSession` for model sharing across streams without reloading.

**This eliminates the need for a "poll every 3 seconds" hack.** The streaming manager is architecturally correct and already handles chunking, state management, and incremental output.

Source: `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`

### 3.5 Output Token Reduction

From [OpenAI's latency guide](https://developers.openai.com/api/docs/guides/latency-optimization): "Cutting 50% of your output tokens may cut ~50% your latency." Our current `maxOutputTokens: 8192` is vastly oversized — typical polish output is 100-500 tokens. Reducing to 1024 won't affect quality but signals the model to be concise and reduces tail generation time.

### 3.6 Rejected Approaches

**Local MLX Polish**: Considered running Qwen 3B via SwiftMLX. Rejected — quality noticeably worse than Gemini Flash, 2-3GB additional RAM, new dependency. We already have Apple Intelligence connector for on-device.

**OpenAI Prompt Caching**: System prompt is ~170 tokens, below the 1024-token threshold. Not actionable now.

## 4. Optimization Plan

### 4.1 Items Overview

| # | Item | Expected Impact | Effort |
|---|------|----------------|--------|
| **1** | End-to-end timing instrumentation | Enables measurement (currently blind) | Low |
| **2** | Gemini SSE streaming + polishing overlay | ~0.5-1s real savings + perceived speed from UI feedback | Medium |
| **3** | Dedicated URLSession singleton + pre-warm | ~200-500ms on cold start | Low |
| **4** | Clipboard delay reduction (instrumented) | ~100ms, with data to inform further reduction | Low |
| **5** | Reduce maxOutputTokens + tighten prompt | ~0.2-0.5s from shorter generation | Low |
| **6** | Streaming ASR during recording | **~1-2s removed from post-release entirely** | Medium-High |
| **7** | Measurement & verification infrastructure | Prove improvements, catch regressions | Medium |

### 4.2 File-Level Changes

#### Item 1: End-to-End Timing Instrumentation

**`Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`**
- Add `CFAbsoluteTimeGetCurrent()` timestamps at each phase boundary in `stopAndTranscribe()`
- Log granular phase durations:
  - `stopRecording → ASR done` (or `→ streaming ASR finalized`)
  - `ASR done → LLM first token` (TTFB — proves connection pre-warm and streaming work)
  - `LLM first token → LLM final token` (generation time)
  - `LLM final token → paste complete` (tail overhead)
  - `total: stopRecording → paste complete` (the number that matters)
- Use existing `AppLogger` infrastructure, log at `.info` level (always visible, not just debug)

**`Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift`**
- Add timing around the `polisher.polish()` call
- Log LLM TTFB and total duration separately

**`Sources/EnviousWispr/LLM/GeminiConnector.swift`** (after streaming is implemented)
- Record TTFB: time from request sent to first SSE `data:` line received
- Record stream duration: first token to final token
- Surface via `URLSessionTaskMetrics` if possible for connection-level detail

#### Item 2: Gemini SSE Streaming + Polishing Overlay

**`Sources/EnviousWispr/LLM/GeminiConnector.swift`**
- Change endpoint from `:generateContent` to `:streamGenerateContent?alt=sse`
- Replace `URLSession.shared.data(for:)` with `session.bytes(for:)` (using dedicated session from Item 3)
- Parse SSE lines: `for try await line in stream.lines`
  - Skip empty lines and lines starting with `:`
  - Extract `data:` prefix, parse JSON chunk
  - Concatenate `candidates[0].content.parts[0].text` fragments
  - Check `finishReason` on each chunk (present only in final)
- Return complete `LLMResult` when stream ends
- Handle mid-stream errors: discard partial data, throw `LLMError`
- Handle task cancellation: clean up stream iterator on cancel

**`Sources/EnviousWispr/LLM/LLMProtocol.swift`**
- Add optional streaming callback to `TranscriptPolisher`:
  ```swift
  func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: ((String) -> Void)?  // nil = no streaming feedback
  ) async throws -> LLMResult
  ```
- Default implementation with `onToken: nil` preserves backward compat for OpenAI/Ollama/Apple Intelligence

**`Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift`** (or new `PolishingOverlayView`)
- Add a "Polishing..." mode to the overlay panel (reuse existing panel, different layout)
- Show minimal status: "Polishing..." with activity indicator
- Transition: `.recording` → overlay shows waveform → `.transcribing`/`.polishing` → overlay shows "Polishing..." → `.complete` → overlay hides

**`Sources/EnviousWispr/App/AppState.swift`**
- In `onStateChange`, show polishing overlay on `.polishing` state (currently does nothing visible)
- Hide on `.complete`, `.error`, `.idle`

#### Item 3: Dedicated URLSession + Pre-Warm

**New file: `Sources/EnviousWispr/LLM/LLMNetworkSession.swift`**
- Singleton `LLMNetworkSession` with a dedicated `URLSession` configured for:
  - `timeoutIntervalForRequest`: 60s
  - `waitsForConnectivity`: false
  - Service type: `.responsiveData`
- `preWarm(url:)` method: fires a lightweight HEAD request to establish TLS + HTTP/2 connection
- `invalidate()` method: calls `finishTasksAndInvalidate()` — called from `AppDelegate.applicationWillTerminate`

**Pre-warm triggers** (adjusted per external review):
- **On app activate** (`applicationDidBecomeActive`): warm the connection to the configured LLM provider
- **On recording stop** (`stopAndTranscribe`): re-warm immediately before polish starts — guarantees fresh connection regardless of recording duration
- **Guard**: only fire if provider is configured AND API key exists in Keychain. Silent no-op otherwise.

**`Sources/EnviousWispr/LLM/GeminiConnector.swift`**
- Use `LLMNetworkSession.shared.session` instead of `URLSession.shared`

**`Sources/EnviousWispr/App/AppDelegate.swift`**
- Call `LLMNetworkSession.shared.invalidate()` in `applicationWillTerminate`
- Call `LLMNetworkSession.shared.preWarm(url:)` in `applicationDidBecomeActive`

#### Item 4: Clipboard Delay Reduction (Instrumented)

**`Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`**
- **First**: instrument why the 300ms exists — add timing around the paste event and clipboard restore to measure if 300ms is actually needed or if it's a safety margin
- **Then**: reduce to 200ms as conservative first step
- Log whether clipboard restore races with paste (detect via `NSPasteboard.changeCount` comparison)

**`Sources/EnviousWispr/Services/PasteService.swift`**
- Add optional timing instrumentation to `pasteToActiveApp()` — how long does the CGEvent actually take to be processed?

#### Item 5: Reduce maxOutputTokens + Tighten Prompt

**`Sources/EnviousWispr/Utilities/Constants.swift`**
- Change `LLMConstants.defaultMaxTokens` from 8192 to 1024
- Change `LLMConstants.ollamaMaxTokens` from 8192 to 1024

**`Sources/EnviousWispr/Models/LLMResult.swift`** (default prompt)
- Tighten the default system prompt to emphasize minimal edits:
  - Add: "Make minimal changes. Do not add, rephrase, or expand. Output ONLY the corrected transcript."
  - This reduces verbosity triggers that cause the model to generate unnecessary tokens

#### Item 6: Streaming ASR During Recording

**This is the highest-impact item.** Moves ASR from post-release to during-recording.

**`Sources/EnviousWispr/ASR/ParakeetBackend.swift`**
- Add streaming support using FluidAudio's `StreamingAsrManager`:
  ```swift
  func startStreaming(models: AsrModels) async throws
  func feedAudio(_ buffer: AVAudioPCMBuffer) async
  func finalizeStreaming() async throws -> ASRResult
  var transcriptUpdates: AsyncStream<StreamingTranscriptionUpdate> { get }
  ```
- `startStreaming()`: create `StreamingAsrManager` with the already-loaded models
- `feedAudio()`: forward audio buffers from the capture tap
- `finalizeStreaming()`: call `finish()`, return final transcript as `ASRResult`
- Fall back to batch `transcribe(audioSamples:)` if streaming init fails

**`Sources/EnviousWispr/ASR/ASRProtocol.swift`**
- Extend `ASRBackend` protocol with optional streaming methods:
  ```swift
  protocol ASRBackend: Actor {
      // Existing batch API (unchanged)
      func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

      // New streaming API (optional, default no-op)
      var supportsStreaming: Bool { get }
      func startStreaming(options: TranscriptionOptions) async throws
      func feedAudio(_ buffer: AVAudioPCMBuffer) async throws
      func finalizeStreaming() async throws -> ASRResult
  }
  ```
- Default extensions return `supportsStreaming = false` and throw for streaming methods
- WhisperKitBackend keeps batch-only for now (can adopt later via WhisperKit's `AudioStreamTranscriber`)

**`Sources/EnviousWispr/ASR/ASRManager.swift`**
- Add streaming façade methods that delegate to the active backend
- If active backend doesn't support streaming, fall back to batch on stop

**`Sources/EnviousWispr/Audio/AudioCaptureManager.swift`**
- Expose the `AVAudioPCMBuffer` stream for consumption by the streaming ASR
- Currently the tap handler converts buffers and appends to `capturedSamples`
- Add: also forward the pre-conversion `AVAudioPCMBuffer` (or post-conversion buffer) to a callback/AsyncStream that the pipeline can route to the streaming ASR
- Keep `capturedSamples` accumulation for VAD and fallback batch transcription

**`Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`**
- Major state machine change. New flow:
  ```
  .idle → .recording (start streaming ASR + audio capture)
       → user releases hotkey
       → .transcribing (finalize streaming ASR — fast, just last chunk)
       → .polishing (LLM polish with full transcript — streaming Gemini)
       → .complete (paste)
  ```
- On `startRecording()`:
  1. Start audio capture (existing)
  2. Start streaming ASR via `asrManager.startStreaming()`
  3. Route audio buffers to both `capturedSamples` and streaming ASR
- On `stopAndTranscribe()`:
  1. Stop audio capture
  2. Finalize streaming ASR → get transcript immediately (~50-100ms for last chunk)
  3. Apply VAD filter to accumulated samples (for quality — compare with streaming result)
  4. If streaming transcript available, use it; otherwise fall back to batch ASR on VAD-filtered audio
  5. Proceed to polish → paste

**Important: VAD interaction with streaming ASR**
- VAD currently runs post-recording on the full audio to filter silence before batch ASR
- With streaming ASR, the model sees unfiltered audio (including silence) during recording
- This is acceptable: Parakeet handles silence well (produces empty segments), and the streaming model has full context
- VAD filtering is still useful for the batch fallback path and for logging voiced percentage

#### Item 7: Measurement & Verification Infrastructure

**Audio test samples:**
- Copy `jfk.wav` from WhisperKit test resources (`.build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav`) into `Tests/Resources/` as a known reference
- User to provide a ~60s natural dictation sample for realistic testing
- Load via FluidAudio's `AudioConverter().resampleAudioFile(url)` → `[Float]` at 16kHz mono

**`Sources/EnviousWispr/Utilities/BenchmarkSuite.swift`** — extend:
- Add `runPipelineBenchmark()` method that measures the full pipeline:
  1. Load test audio file to `[Float]`
  2. Run batch ASR → record transcript + timing
  3. Run streaming ASR on same audio (chunk into `AVAudioPCMBuffer` segments) → record transcript + timing
  4. Compare transcripts via WER (implement lightweight WER from FluidAudioCLI's `WERCalculator`)
  5. Run LLM polish on batch transcript → record timing (TTFB + total)
  6. Report: batch ASR time, streaming finalization time, WER delta, LLM TTFB, LLM total, end-to-end
- Add `PipelineBenchmarkResult` struct with all phase timings

**`Sources/EnviousWispr/Audio/AudioCaptureManager.swift`** — add injection:
- Add `injectSamples(_ samples: [Float], sampleRate: Double)` method for testing
- Sets `capturedSamples` directly, simulates a recording without mic
- Guarded: only available in debug builds or benchmark mode

**WER calculation** — add lightweight implementation:
- Port WER calculation from FluidAudioCLI's `WERCalculator.swift` (~50 lines, edit-distance based)
- Place in `Sources/EnviousWispr/Utilities/WERCalculator.swift`
- Used by BenchmarkSuite to compare streaming vs batch transcript quality

**Acceptance thresholds:**
- Streaming ASR WER must be within 2% of batch ASR WER on same audio
- Pipeline benchmark must show total post-release time <2.5s for 60s audio with Gemini 2.5 Flash
- No regression in batch ASR RTF (must remain >88x for Parakeet)

**Settings UI:**
- Add "Pipeline Benchmark" button alongside existing "Run Benchmark" in Diagnostics settings
- Shows results inline: phase timings, WER comparison, pass/fail against thresholds

### 4.3 Dependency Graph

```
Phase 1 — Parallel (independent file sets):

  Cluster A (Pipeline + Audio):          Cluster B (LLM layer):
  ┌──────────────────────────────┐       ┌────────────────────────────────┐
  │ #1 Instrumentation           │       │ #2 Gemini SSE streaming        │
  │ #4 Clipboard delay reduction │       │ #3 URLSession singleton        │
  │ #6 Streaming ASR             │       │ #5 maxOutputTokens + prompt    │
  │ #7 Benchmark infrastructure  │       │ #2 Polishing overlay (UI)      │
  │                              │       │                                │
  │ Files:                       │       │ Files:                         │
  │  TranscriptionPipeline       │       │  GeminiConnector               │
  │  AudioCaptureManager         │       │  LLMNetworkSession (new)       │
  │  ASRProtocol                 │       │  LLMProtocol                   │
  │  ASRManager                  │       │  Constants                     │
  │  ParakeetBackend             │       │  LLMResult (prompt)            │
  │  BenchmarkSuite              │       │  AppDelegate (pre-warm/inval)  │
  │  LLMPolishStep (timing)      │       │  RecordingOverlayPanel         │
  │  PasteService (timing)       │       │  AppState (overlay wiring)     │
  │  WERCalculator (new)         │       │                                │
  └──────────────────────────────┘       └────────────────────────────────┘
           │                                        │
           └────────────────┬───────────────────────┘
                            ▼
                 Phase 2 — Sequential:
                 ┌────────────────────────┐
                 │ Integration + wiring   │
                 │ Code review / cleanup  │
                 │ Build validation       │
                 │ Baseline benchmark     │
                 │ Smart UAT              │
                 └────────────────────────┘
```

**Note on Phase 2 integration**: After both clusters complete, the streaming ASR output needs to be wired to the polishing overlay, and the pre-warm triggers need to be placed in the pipeline. This integration step touches files from both clusters but is small (~20 lines of glue code).

### 4.4 Execution Strategy

**Agent team** (cross-domain dependencies require coordination):

| Agent | Domain | Items | Key Files |
|-------|--------|-------|-----------|
| **Agent A** | Audio + Pipeline | #1, #4, #6, #7 | TranscriptionPipeline, AudioCaptureManager, ASR*, BenchmarkSuite, PasteService |
| **Agent B** | LLM + UI | #2, #3, #5 | GeminiConnector, LLMNetworkSession, LLMProtocol, Constants, RecordingOverlayPanel, AppState |

After both complete:
- **Integration**: Wire streaming ASR → polishing overlay → pre-warm triggers
- **Code review** via `code-simplifier` agent
- **Build validation** via `wispr-run-smoke-test`
- **Baseline benchmark**: Run pipeline benchmark with test audio, record before/after metrics
- **Smart UAT** via `wispr-run-smart-uat`

### 4.5 Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| **StreamingAsrManager produces different transcripts than batch** | Quality regression | Item 7: WER comparison on same audio. Threshold: within 2%. If exceeded, fall back to batch. |
| **Streaming ASR adds latency to recording** | Audio glitches, dropped frames | CoreML runs on Neural Engine, audio on CPU RT thread — verified no contention. Monitor with instrumentation. |
| **Mid-stream error from Gemini SSE** | Partial text, user confusion | Discard partial data on error, throw `LLMError`. Never paste partial LLM output. |
| **Truncation detection regression** | Silent truncation after switching to SSE | Check `finishReason` in final SSE chunk. Same field name/values as non-streaming. |
| **`systemInstruction` with streaming endpoint** | Request rejected, polish fails | Confirmed: `streamGenerateContent` accepts identical request body including `systemInstruction`. |
| **URLSession delegate leak** | Connection/memory leak on long runs | `invalidate()` from `applicationWillTerminate`. Use `finishTasksAndInvalidate()`. |
| **Pre-warm connection dies during long recording** | First-polish-after-long-recording still cold | Re-warm on recording stop (in addition to app activate). Guarantees fresh connection. |
| **Clipboard restore delay too short at 200ms** | Paste not complete, text overwritten | Instrument paste timing first. Reduce conservatively. Detect race via `NSPasteboard.changeCount`. |
| **Streaming ASR + VAD interaction** | Model sees silence that VAD would have filtered | Acceptable: Parakeet handles silence (produces empty segments). VAD still used for batch fallback. |
| **AudioCaptureManager buffer forwarding** | Additional memory from dual consumption (capturedSamples + streaming) | Streaming manager processes and discards chunks incrementally. Peak memory unchanged (~7.7MB for 2 min). |

## 5. Success Criteria

### Must-Have
1. **Instrumentation logs** show full pipeline timing breakdown: stop → ASR finalize → LLM TTFB → LLM done → paste
2. **Streaming ASR active during recording** — Parakeet transcribes incrementally via `StreamingAsrManager`
3. **Gemini polish uses SSE streaming** — `streamGenerateContent` endpoint
4. **Connection pre-warmed** on app activate and recording stop
5. **Polishing overlay visible** during `.polishing` state with "Polishing..." indicator
6. **maxOutputTokens reduced** from 8192 to 1024
7. **Clipboard restore delay** reduced from 300ms to 200ms (with instrumentation proving safety)
8. **Pipeline benchmark** passes: post-release time <2.5s for 60s audio with Gemini 2.5 Flash
9. **Streaming ASR quality**: WER within 2% of batch ASR on same test audio
10. **No regressions**: Other LLM providers (OpenAI, Ollama, Apple Intelligence) unaffected
11. **Build clean** + **Smart UAT passes**

### Measurement Deliverables
- Pipeline benchmark runnable from Settings > Diagnostics
- Before/after timing comparison logged and reportable
- WER comparison between streaming and batch ASR on reference audio
- Test audio sample in `Tests/Resources/` for reproducible benchmarking

## 6. Future Follow-Ups (Not In Scope)

- Streaming for OpenAI connector (same SSE pattern, different response format)
- Streaming for Ollama connector (already supports SSE, `"stream": true`)
- WhisperKit streaming ASR (has `AudioStreamTranscriber`, can adopt same pattern)
- Speculative polish during recording (debounced LLM calls on partial transcript — highest risk/reward)
- Streamed text preview in overlay (show partial polish text arriving — UX enhancement)
- Adaptive clipboard restore delay (use instrumentation data to auto-tune)
- OpenAI prompt caching (requires >1024 token prompts)
- Audio injection protocol for fully automated pipeline testing without mic
