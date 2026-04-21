# Issue #428 — Phase C: TranscriptCoordinator owns history — 2026-04-20

GitHub issue: `#428`. Parent / epic: `#319` (Refactor Bible). Tier: **REFACTOR** (MEDIUM per Bible §9, but heart-adjacent persistence means reviewer scope matches REFACTOR). Status: **DRAFT**.

> This plan hydrates Bible §9 into TEMPLATE.md shape. Bible §9 is the substantive design; this file is the council-ready artifact.

User Rubric: N/A — Epic #319 Hardening & Refactors is internal-only, no user-visible surface.

## 0. TL;DR

AppState currently calls `transcriptCoordinator.load()` (O(n) full-directory scan via `TranscriptStore.loadAll()`) on every `.complete` state. `TranscriptFinalizer.swift:126` has already persisted the new transcript by the time AppState observes `.complete`, so the reload is pure redundant I/O on the heart-completion path. Phase C moves transcript-history ownership into `TranscriptCoordinator` and replaces the reload with an in-memory `append(_:)`. Persistence boundary is locked: finalizer owns disk, coordinator owns in-memory cache. Ship requires fixture-based read-compat characterization test + founder-folder dogfood per Bible Phase C Invariant (zero production history loss).

## 1. Problem

Concrete evidence from grep (2026-04-20):

- `Sources/EnviousWispr/App/AppState.swift:395` (Parakeet `.complete` branch) and `:452` (WhisperKit `.complete` branch) both call `self.transcriptCoordinator.load()`.
- `TranscriptCoordinator.load()` in turn calls `try await store.loadAll()` (coordinator.swift:33), which scans every JSON file in `~/Library/Application Support/EnviousWispr/transcripts/` and decodes each. O(n) in user history size.
- `TranscriptFinalizer.swift:126` already runs `try save(transcript)` BEFORE `.complete` is emitted. So every completion triggers one write-one + one full-scan-read-everything.
- Consequence: completion latency grows linearly with user history. A long-time user with 1,000+ transcripts pays disk-scan time on every dictation finish. This is invisible at 5 transcripts; observable at 1,000.

This is also an ownership smell: `AppState` should not be deciding "refresh history now." The coordinator owns that domain and should expose `append(_:)` so the completion handler just announces "new row, integrate it."

## 2. Goals & non-goals

### 2.1 Goals

- Eliminate O(n) `loadAll()` from the heart-completion path. Post-change: `grep -n "transcriptCoordinator.load()" Sources/App/AppState.swift` returns zero hits.
- `TranscriptCoordinator.append(_:)` exists, is `@MainActor`, inserts into `transcripts` at index 0, performs no disk I/O.
- `TranscriptStore` gains `public init(directory: URL)` so Phase C's 1000-transcript perf test can seed a temp directory.
- `AppState` no longer holds a direct `transcriptStore` property; the coordinator is the sole production construction point (single-owner invariant per D8).
- Zero production history loss (Phase C Invariant §27 + Phase C doc).
- Race between startup `load()` and concurrent `append(_:)` resolved by union-by-ID merge on `load()`, not wholesale replace.

### 2.2 Non-goals

- Unifying Parakeet and WhisperKit pipelines. They remain intentionally separate (architecture-rules §Intentional Duplication).
- Replacing finalizer persistence with coordinator write-through. Explicitly forbidden by §27.2 superseded decision + Bible §9.2 v1.6 + finalizer:126 evidence.
- Fixing `TranscriptPolishService.swift:163` (`transcriptStore.loadAll()` inside deletion-existence check). **Explicitly deferred (GPT sign-off 2026-04-20):** stay disciplined on Phase C blast radius. File a separate post-epic issue after merge; do not fold in opportunistically even though it is a small diff. Noted in Bible §9.2 as heart-adjacent but out of scope here.
- Any change to `Views/Main/HistoryContentView.swift:31` (`.task { load }`). That is the correct startup path and stays as-is.
- Touching `TranscriptFinalizer` persistence logic. Only its return value is read differently (Option A wiring).

## 3. Design

### 3.1 Ownership move

`transcriptStore` property moves from `AppState` → `TranscriptCoordinator` as the single production owner. `TranscriptCoordinator` continues to be constructed by `AppState` (AppState.swift:21), but AppState no longer holds a direct reference to the store. All production readers of transcript history go through the coordinator.

Pipelines (`TranscriptionPipeline`, `WhisperKitPipeline`) and `TranscriptPolishService` continue sharing the SAME `TranscriptStore` instance they share today — they must not accidentally construct a second store.

**Composition-root wiring (council-locked 2026-04-20).** AppState init creates one local `let transcriptStore = TranscriptStore()`. That local is passed by init into `TranscriptCoordinator`, `TranscriptionPipeline`, `WhisperKitPipeline`, and `TranscriptPolishService`. AppState does NOT retain it as a property. `TranscriptCoordinator` does NOT expose a store accessor. No consumer constructs its own. This is a composition-root pattern, not a service-locator pattern — the "coordinator exposes the store via an accessor" option proposed in an earlier draft is rejected as weakening the boundary.

**⚠ First-class implementation tripwire (council-tightened 2026-04-20).** Shared-store wiring is where subtle persistence bugs sneak in. Codex code-diff review round 1 MUST explicitly verify:
- Exactly ONE `TranscriptStore(` construction exists in production code across `Sources/` (grep: `grep -rnE "TranscriptStore\s*\(" Sources/ | grep -v "Sources/EnviousWisprStorage/TranscriptStore.swift:"` returns 1 hit). The widened pattern catches `TranscriptStore(directory:)` and whitespace variants, not just `TranscriptStore()`.
- The single production construction lives in `AppState` composition root only (not inside any consumer's init default-argument or inline `TranscriptCoordinator(store: TranscriptStore())`).
- That local instance is threaded by init into: `TranscriptCoordinator`, both pipelines, `TranscriptPolishService`.
- No consumer holds a distinct store instance.
If the diff shows two constructions, an inline construction at a consumer site, or any consumer holding its own store, Codex blocks the round.

### 3.2 In-memory append contract

```swift
// TranscriptCoordinator.swift — @MainActor @Observable
// Precondition: transcript has already been persisted by TranscriptFinalizer.
// Postcondition: transcript is the newest row in `transcripts` (index 0).
// No disk I/O in this method.
func append(_ transcript: Transcript) {
  transcripts.insert(transcript, at: 0)
}
```

### 3.3 Wiring (Option A — locked)

AppState reads `pipeline.currentTranscript` on `.complete` and calls `coordinator.append(t)`. Finalizer signature is unchanged. AppState is the glue that knows which pipeline just completed. Option B (finalizer `didSave:` callback) is rejected: larger blast radius, two subscribers to coordinate, no testing win.

`currentTranscript` timing is verified safe — both `TranscriptionPipeline.swift:940` and `WhisperKitPipeline.swift:1016` populate `currentTranscript` BEFORE emitting `.complete`, so AppState's `.complete` observer reads the correct value.

### 3.4 Race: append vs in-flight load

`TranscriptCoordinator.load()` currently assigns `transcripts = try await store.loadAll()` — wholesale replace. If a slow startup `load()` (from `HistoryContentView.task`) finishes AFTER an `append(t)` from a dictation completion, the load's stale snapshot overwrites the newly-appended row until the next reload.

Fix: union-by-ID merge on `load()`, preserving in-memory order.

```swift
func load() {
  loadTask?.cancel()
  loadTask = Task {
    do {
      let diskRows = try await store.loadAll()
      let diskIDs = Set(diskRows.map(\.id))
      // In-memory rows with IDs not yet on disk (race window: appended during slow load).
      // Preserve their order so newest-first invariant holds for N concurrent appends.
      let inFlightRows = transcripts.filter { !diskIDs.contains($0.id) }
      transcripts = inFlightRows + diskRows
    } catch { /* log, unchanged */ }
  }
}
```

**Decision (council sign-off 2026-04-20):** union-by-ID merge. History is user-authored data; defensive correctness beats the small LOC savings of cancel-in-flight. Cancel-in-flight rejected, not deferred.

**Merge algorithm (council-tightened 2026-04-20).** Both reviewers independently flagged that the earlier sketch reversed order under multiple concurrent appends (inserting each missing row at index 0 produces reversed order) and could crash via `Dictionary(uniqueKeysWithValues:)` if duplicate IDs existed in memory. Replaced with filter + concatenate: in-memory rows retain original order, then disk rows follow. Set-based lookup avoids trap. Additional test required: `testLoadDuringMultipleAppendsPreservesNewestFirstOrder` (§11).

**Ordering contract (Grounded Review clarification 2026-04-20).** Merge preserves **append order**, not strict global `createdAt`-descending sort across arbitrary data. Normal app-generated transcripts are always newer than disk rows by wall-clock construction (finalizer-generated `createdAt` is monotonic vs. what's on disk), so the two degenerate to the same thing in practice. Edge case that could misorder: a future-dated or manually imported legacy JSON already on disk, then a new live transcript appended during load — the new row goes to the front even if its `createdAt` is earlier than the imported-forward row. Accepted limitation. If a user imports future-dated transcripts they already know ordering is their responsibility. Not worth re-sorting on every merge.

### 3.5 Directory-injectable store (D8)

```swift
public final class TranscriptStore {
  private let directory: URL
  public init() {
    self.directory = AppConstants.appSupportURL
      .appendingPathComponent(AppConstants.transcriptsDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  // Tests only. Reached via `@testable import EnviousWisprStorage`.
  internal init(directory: URL) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
}
```

**Safety invariant:** AppState uses `TranscriptStore()` (public default init) in production. `init(directory:)` is `internal` — production call sites outside `EnviousWisprStorage` cannot reach it. Tests reach it via `@testable import`. This is stronger than a doc-comment invariant: the compiler enforces it.

---

## 4. **MANDATORY** Contract deltas

### New API

- **`TranscriptCoordinator.append(_ transcript: Transcript)`** — internal (not `public`; coordinator is not exported).
  - **Semantics.** In-memory cache update. Caller asserts the transcript is already persisted (Grounded Review confirmed `.complete` only fires post-save; finalizer throw path emits `.error` instead). Not a persistence operation. Not a telemetry emission site. Not idempotent by contract — caller must not call twice for the same transcript (no-op on duplicate ID would mask heart-path bugs).
  - **Invariants.** Caller must be `@MainActor`. Transcript must already exist on disk. No-op if coordinator is being deallocated (standard @MainActor @Observable lifecycle).

- **`TranscriptStore.init(directory: URL)`** — `internal`, new overload. Tests reach it via `@testable import EnviousWisprStorage`.
  - **Semantics.** Constructs a store rooted at a caller-supplied directory. No default fallback to `AppConstants.appSupportURL`. Creates the directory if missing (matches existing init behavior).
  - **Invariants.** Production code MUST use the default `public init()`. The directory-injectable init is `internal` precisely to keep production callers unable to mis-point the store — only test code reaches it via `@testable`. Phase C's implementation will add a `// Tests only. Reached via @testable import.` comment on this init.
  - **Decision (GPT sign-off 2026-04-20):** chose `internal` + `@testable import` over `public`. architecture-rules § "public is expensive" applies; SPM `@testable` works across the existing library target boundary (verified 2026-04-20, no current `@testable import EnviousWisprStorage` usage to conflict with).

### Modified behavior (no signature change)

- **`AppState.onPipelineStateChange` Parakeet `.complete` branch (AppState.swift:395).** Before: `self.transcriptCoordinator.load()` + telemetry. After: `self.transcriptCoordinator.append(t)` where `let t = self.pipeline.currentTranscript` + telemetry. Telemetry emission unchanged.
- **`AppState.onPipelineStateChange` WhisperKit `.complete` branch (AppState.swift:452).** Same transformation.
- **`TranscriptCoordinator.load()` (coordinator.swift:29).** Now performs union-by-ID merge instead of wholesale replace (see §3.4). Postcondition: `transcripts` contains all on-disk rows; in-memory rows with IDs NOT present on disk are preserved at index 0 (defensive against append-during-load).

### Removed

- **`AppState.transcriptStore` property.** No longer exists on AppState. Accessed only via `transcriptCoordinator`.

### Legacy data compatibility

- **No on-disk schema change.** `Transcript`'s `Codable` surface is not touched. Existing JSON files in `~/Library/Application Support/EnviousWispr/transcripts/` load with byte-for-byte identical behavior.
- **New code reading old data:** no-op change. Coverage: fixture-based characterization test seeds a directory with transcripts captured from a v1.17 production build, loads them through the new coordinator, asserts count + field-for-field equality.
- **New code writing to a directory containing old data:** new saves append via normal finalizer path; load-merge preserves pre-existing rows. Coverage: write-after-read test (Phase C Invariant safeguard #2).

---

## 5. **MANDATORY** E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new item (primary path) | Heart completes → finalizer saves to disk (unchanged) → AppState observes `.complete` → AppState calls `coordinator.append(currentTranscript)` → `transcripts` gets the new row at index 0 → `@Observable` emits → `HistoryContentView` re-renders. Net: one disk write (unchanged), zero disk reads (was: full-scan read). **Edge case: if `currentTranscript == nil` at `.complete` (pipeline bug — should not happen per §3.3), no `append` and no `load()` fallback. Accepted as transient stale-cache, NOT data loss — finalizer already persisted; row is on disk and visible on next `load()`.** |
| Saved / reloaded item | Unchanged. Startup `load()` path (`Views/Main/HistoryContentView.swift:31` `.task`) still calls `coordinator.load()` → full-directory scan + union-by-ID merge. |
| Retry or re-run | N/A. `.complete` fires once per recording; re-polish path (`TranscriptPolishService`) operates on an existing row and does not append. |
| Background / async completion arriving after state changed | **Race guarded.** §3.4 union-by-ID merge on `load()`. If startup `load` finishes AFTER a dictation `append`, the new row is preserved. |
| User manual override / edit path | Unchanged. Edit flow writes via finalizer → no append required (row already in cache, edit mutates in place via separate coordinator API which is out of Phase C scope). |

**Upstream sources (every execution path that reaches the changed code; grep-verified 2026-04-20):**
- Live dictation (`TranscriptionPipeline`, `WhisperKitPipeline` heart path) → AppState `.complete` handler → `append(_:)`.
- Startup history load (`HistoryContentView.task` at `Views/Main/HistoryContentView.swift:31`) → `coordinator.load()` → union-merge. **Grep confirms sole production caller of `coordinator.load()`** after Phase C eliminates the two AppState `.complete` sites.
- Delete flow (`coordinator.delete(_:)`) → unchanged, still removes from cache + disk. Grep confirms no `appState.transcriptStore.delete` callers — all delete routing already goes through coordinator.
- Delete-all flow (`coordinator.deleteAll()`) → unchanged.
- `TranscriptPolishService.swift:163` `loadAll()` call → unchanged, deferred to post-epic issue per §2.2 non-goals.
- **External file modifications** (user drags a JSON into the transcripts folder, or Sparkle upgrade-time folder copy): previously opportunistically synced on next dictation `.complete`. Post-Phase-C: no heart-path reload, so external mods require app restart to appear. Acceptable at current scale (5 users, no external-mod workflow). Documented so future "why didn't my hand-placed transcript show up" is expected behavior.

**UI side effects.** `HistoryContentView` lists `coordinator.filteredTranscripts` (coordinator.swift:16). Detail pane resolves `AppState.activeTranscript` (AppState.swift:700-707) which falls back to `pipeline.currentTranscript`. Phase C does not touch the detail-pane path — the comment at AppState.swift:924 already accounts for fallback freshness.

**Persistence.** Unchanged. `TranscriptFinalizer.swift:126` `try save(transcript)` is the single production write site. `append(_:)` is in-memory only.

**App-kill scenario.** Kill 1ms after `.complete`: transcript is already on disk (finalizer ran before the state emit). Next launch: `coordinator.load()` loads it from disk. No loss. Current behavior identical.

**Concurrency guard.** Coordinator is `@MainActor`. Both `append(_:)` and `load()` are main-actor-isolated. `loadTask` is cancellation-aware; union-by-ID merge defends against the narrow "load completes after append" window. No new race surface introduced.

**Swift 6 heavy-IO isolation (council-verified 2026-04-20).** `TranscriptStore.loadAll()` at `Sources/EnviousWisprStorage/TranscriptStore.swift:34` already uses `Task.detached(priority: .userInitiated)` for the directory scan + JSON decode. Heavy IO runs off-MainActor today; `await store.loadAll()` from the coordinator does not hang the UI. No change needed, noted explicitly so reviewers don't flag it as a Swift 6 concern.

---

## 6. **MANDATORY** Downstream consumer matrix

Discovery method:

```
grep -rn "appState\.transcriptStore\b" Sources/
grep -rn "appState\.transcriptCoordinator\b" Sources/
grep -rn "\.transcripts\b" Sources/EnviousWispr/Views/
grep -rn "appState\.activeTranscript\b" Sources/
grep -rn "transcriptCoordinator\.load\|transcriptStore\.loadAll\|transcriptCoordinator\.append" Sources/
```

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| `AppState.transcriptStore` removed | All reads of `appState.transcriptStore` | Direct store access | Composition-root pattern: AppState threads the single store into coordinator + pipelines + polish service via init; no property, no accessor. | **Yes** (audit step 7) | grep returns 0 hits post-change + build passes |
| `coordinator.append(_:)` new | AppState `.complete` Parakeet (`AppState.swift:395`) | calls `load()` | calls `append(t)` | Yes | unit test `testCompleteAppendsInMemoryOnly` |
| `coordinator.append(_:)` new | AppState `.complete` WhisperKit (`AppState.swift:452`) | calls `load()` | calls `append(t)` | Yes | unit test `testCompleteAppendsInMemoryWhisperKit` |
| `coordinator.load()` semantics change | `Views/Main/HistoryContentView.swift:31` `.task` | wholesale replace | union-by-ID merge (filter + concatenate) | No (caller unchanged; coordinator internal change) | unit tests `testLoadDuringAppendMergesCorrectly` + `testLoadDuringMultipleAppendsPreservesNewestFirstOrder` |
| `coordinator.delete(_:)` + `deleteAll()` routing | Any view / service that deletes transcripts | grep 2026-04-20 confirms zero `appState.transcriptStore.delete` or `.deleteAll` callers exist; all delete routing already goes through coordinator | Unchanged; no re-wiring needed | No | grep re-verified post-diff |
| `coordinator.transcripts` read | `HistoryContentView`, `TranscriptDetailView`, `TranscriptHistoryView` (`:21`), `SidebarStatsHeader` (`:13`), any view using `filteredTranscripts` | reads cache | reads cache (unchanged) | No | live smoke: history view + sidebar stats + transcript-history list all update within one frame of `.complete` |
| `AppState.activeTranscript` read-through (`AppState.swift:700`, `:918`) | detail pane + refresh-trigger comment | resolves via `pipeline.currentTranscript` fallback | unchanged (pipelines still expose `currentTranscript`) | No | live smoke: detail pane shows newest transcript immediately post-`.complete` |
| `TranscriptStore.init(directory:)` new | Tests only (via `@testable import EnviousWisprStorage`) | N/A | Seed temp dir | Yes (new test files) | characterization/perf tests run; `internal` visibility enforced by compiler |
| `pipeline.currentTranscript` read on `.complete` | `AppState.onPipelineStateChange` | already read | same read, now passed into `append` | No (already read at `:396` and `:453` for telemetry) | visible in diff |

**TranscriptPolishService.swift:163** reads `transcriptStore.loadAll()` but accesses the store directly — NOT through `AppState.transcriptStore`. It is constructed elsewhere and already holds its own reference. Grep confirms: `grep -n "transcriptStore" Sources/EnviousWisprPipeline/TranscriptPolishService.swift` shows internal references to a locally-held store, not `appState.transcriptStore`. So removing `AppState.transcriptStore` does NOT break this call site. Separate issue (deferred) tracks switching that `loadAll()` to `exists(id:)`.

---

## 7. **MANDATORY** Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| `pipeline.currentTranscript == nil` on `.complete` | pipeline bug (should never happen per §3.3 timing proof) | AppState `.complete` handler | `append` is NOT called. **No `load()` fallback.** Telemetry skip (current `if let t = ...` block already guards). This is an **accepted transient stale-cache condition, NOT data loss** — finalizer already persisted on its own path, so the row exists on disk; it just isn't in the in-memory list until the next `load()`. | Transcript was saved by finalizer (finalizer is on a separate path). History will be stale until next `load()`; user-observable on their next dictation or next time they open History. | None — failure is silent. | User-driven: next dictation or Settings refresh triggers reload. Council/Codex ask: pressure-test whether any downstream telemetry or UX path implicitly depends on seeing a non-nil `currentTranscript` at `.complete`. |
| `append` called twice for same ID | programmer bug | AppState | Duplicate row in `transcripts` list. Not guarded by contract — no-op on duplicate would hide heart-path bugs. Caught by characterization test. | Disk unchanged (append is in-memory only). | None | Not retriable — duplicate must be prevented upstream. |
| `load()` throws | disk I/O failure | `HistoryContentView.task` startup | Log to `AppLogger`, keep existing in-memory `transcripts` unchanged. Current behavior preserved. | Disk-read failed, but prior cache is intact. | None | Next launch retries. |
| `append` during `load` → union merge | see §3.4 | coordinator internal | In-memory row preserved, disk rows merged in. Both visible to UI. | Disk is authoritative for its rows; in-memory covers the race window. | None | N/A — resolved by design. |
| `TranscriptStore(directory:)` called in production | programmer mistake | AppState or service | Heart still works — but history would load from wrong path. | Fresh (empty) directory, production history invisible until fix. | None | Revert and ship hotfix. **Prevented structurally by `internal` visibility; compile error at any `@testable`-less call site.** |
| Finalizer `save(_:)` throws (disk full, permission) | disk I/O failure | pipeline `.complete` handler never runs | **`.complete` is NOT emitted.** Pipeline sets `.error("Failed to save transcript")` (`TranscriptionPipeline.swift:898`, `WhisperKitPipeline.swift:977`), so AppState's `.complete` observer — and therefore `coordinator.append` — never runs. No orphan in-memory row. (Grounded Review 2026-04-20 correction: an earlier draft wrongly said `.complete` still fires and left an in-memory ghost; the pipeline emits `.error` instead.) | Disk write failed; row does NOT exist anywhere. User sees the `.error` state. | None — no completion telemetry fires. | User retries via normal heart-path. |
| Multiple concurrent appends during in-flight `load` | Race scenario from legitimate rapid dictation + delayed startup load | coordinator | Merge filters disk-IDs out of in-memory rows, then concatenates `inFlightRows + diskRows`. Order preserved. | Disk authoritative for its rows; in-memory preserves newest-first for rows not yet on disk. | None | N/A — resolved by §3.4 merge. Test: `testLoadDuringMultipleAppendsPreservesNewestFirstOrder`. |
| Delete during in-flight `load` | Preexisting (not introduced by Phase C) | User-driven delete while `HistoryContentView.task` load runs | Deleted row may briefly reappear in merged list if deletion ran AFTER disk-snapshot read. Unchanged from today. | Disk authoritative. | None | Non-goal for Phase C; unchanged preexisting behavior. Acknowledged per council pressure-test. |

---

## 8. **MANDATORY** Caller-visible signals audit

Fields whose presence/absence or value has semantic meaning beyond their Swift type:

- **`transcripts[0]`** → conventionally the "newest." `HistoryContentView` renders top-down; the list-order contract (index 0 == newest) is the signal. `append(_:)` preserves this by inserting at index 0.
- **`coordinator.transcripts.count`** → drives empty-state UI in `HistoryContentView`. Append-then-delete round trips must keep count invariants. Phase C doesn't change count semantics, but the characterization test includes a count assertion after `append`.
- **`AppState.transcriptStore`** (being removed) → grep of Sources confirms it's read nowhere outside AppState construction. Removal is safe.

No new truthy/nullable signals introduced by Phase C. `append(_:)` has no return value; `load()`'s observable output (`transcripts` array) has unchanged semantics.

---

## 9. **MANDATORY** Fallback source-of-truth audit

One fallback path exists:

- **If `pipeline.currentTranscript == nil` on `.complete`:** `append` is skipped; we fall back to NOT calling `load()` either (because the whole purpose of Phase C is to remove the load from the heart-completion path). The source of truth for history in that case is disk; next startup or next completion repairs cache visibility.

  - **Exact value returned:** nothing. `append` is simply not called.
  - **Where that value comes from:** not applicable — this is a guard-skip, not a value fallback.
  - **Why that's the right source:** the finalizer already persisted. Disk is authoritative. A missing in-memory row is a transient UI staleness bug, not data loss. The alternative (calling `load()` as fallback) would reintroduce the O(n) scan we are removing.

No other fallback branches introduced.

---

## 10. File-by-file changes

- **`Sources/EnviousWispr/App/TranscriptCoordinator.swift`**
  - Add `func append(_ transcript: Transcript)` — one-line insert at index 0.
  - Modify `load()` to union-merge disk rows with in-memory rows by ID (§3.4).
  - No other changes.

- **`Sources/EnviousWisprStorage/TranscriptStore.swift`**
  - Add `internal init(directory: URL)` alongside existing `public init()`.
  - Add inline comment: `// Tests only. Reached via @testable import EnviousWisprStorage.`

- **`Sources/EnviousWispr/App/AppState.swift`**
  - Convert `transcriptStore` from a property into a local `let` inside AppState's init composition root. The construction site stays `AppState` (grep `TranscriptStore(` in `Sources/` will still show one hit, inside AppState's init).
  - In the Parakeet `.complete` handler (`:395`): replace `self.transcriptCoordinator.load()` with `if let t = self.pipeline.currentTranscript { self.transcriptCoordinator.append(t) }`. Reconcile with existing `if let t = self.pipeline.currentTranscript { ... }` block at `:396–:397` (telemetry). Combine into one guarded block.
  - In the WhisperKit `.complete` handler (`:452`): same transformation against `self.whisperKitPipeline.currentTranscript`.
  - Init flow: pass the single local `transcriptStore` into `TranscriptCoordinator(store:)` (already takes `store:` per coordinator.swift:25), `TranscriptionPipeline(transcriptStore:)` (per pipeline.swift:107), `WhisperKitPipeline(transcriptStore:)` (per pipeline.swift:129), and `TranscriptPolishService(transcriptStore:)` (per polish-service.swift:42). **No consumer init-signature changes needed** — Grounded Review confirmed all four already accept injected stores.

- **`Package.swift`**
  - Add `EnviousWispr` and `EnviousWisprStorage` to `EnviousWisprTests` target dependencies at line 125. Current deps are Core + PostProcessing + LLM + Pipeline. Without this, `@testable import EnviousWisprStorage` and coordinator tests will not compile. Grounded Review 2026-04-20 caught this.

- **`Tests/EnviousWisprTests/App/TranscriptCoordinatorTests.swift`** (new file)
  - `testAppendInsertsAtIndexZero` — unit test `append(_:)` contract.
  - `testAppendDoesNotMutateDisk` — seed temp directory, call `append`, assert directory contents (`FileManager.default.contentsOfDirectory`) are byte-identical before and after. **Structural check via real `TranscriptStore(directory:)` — no protocol / spy abstraction introduced.** (Council tightening 2026-04-20.)
  - `testLoadDuringAppendMergesCorrectly` — simulate slow `load` + one concurrent `append`; assert both rows present post-merge.
  - `testLoadDuringMultipleAppendsPreservesNewestFirstOrder` — simulate slow `load` + N concurrent `append` calls; assert merged order is in-memory rows in original-append-order, followed by disk rows. Catches the order-reversal bug flagged by council.
  - `testStartupLoadPreservesPreexisting` — load from seeded directory, assert expected count + identity.

- **`Tests/EnviousWisprTests/App/TranscriptCoordinatorCharacterizationTests.swift`** (new file — Phase C Invariant safeguard #1 + #2)
  - Seed a temp directory with JSON fixtures captured from v1.17 production format.
  - Load through new coordinator; assert field-for-field equality of every transcript.
  - Write a new transcript via finalizer into the same directory; reload; assert all old + new rows present.

- **Upgrade-time folder-copy production hook — DECISION: Option B (2026-04-20).** Grep of `Sources/` for `appSupportURL`, `Library/Application Support`, `iCloud`, `Mobile Documents`, `group.com.enviouswispr`, and `legacy.*transcript` confirmed the app has always written transcripts to `AppConstants.appSupportURL/transcripts` (`TranscriptStore.swift:10-11`). No legacy path, no group container, no iCloud sync target. The migrator would be a no-op. Implementation collapses to a one-line readable-directory assertion added during AppState init (or inside `TranscriptStore.init()` itself). Full Option A/B background kept below for audit.
  
  **Options considered:**
  - **Option A (preferred):** add a concrete `TranscriptUpgradeMigrator` or inline-in-`TranscriptStore` migrator that runs once on first launch of a new build, copies any legacy-path transcripts into `AppConstants.appSupportURL`, keyed off a `UserDefaults.bool("transcripts.upgrade.copied")` flag so it never double-runs.
  - **Option B (fallback):** if grep confirms the app has ALWAYS written to `AppConstants.appSupportURL` and no historical path exists, the copy hook is vestigial. Replace it with a one-time runtime assertion in `AppState.init` that the expected directory exists and is readable; safeguard #3 (founder dogfood) covers the rest.

  Grounded Review found no group-container or iCloud path in `Sources/`; only `AppConstants.appSupportURL` + a temp-directory fallback. If grep re-confirms no legacy path, Option B is correct.

- **`Tests/EnviousWisprTests/App/TranscriptUpgradeFolderCopyTests.swift`** (new file — Phase C Invariant safeguard #4)
  - Under Option A: seed a "legacy" directory, trigger the migrator, assert destination has every expected JSON with matching contents.
  - Under Option B: assert `AppConstants.appSupportURL` exists and is readable post-init; no migrator test.
  - Covers the zero-production-history-loss gap council flagged.

- **`Tests/EnviousWisprTests/App/TranscriptCoordinatorPerfTests.swift`** (new file — **manual / evidence-capture, NOT a blocking CI check**)
  - Seed 1000-transcript directory via `TranscriptStore(directory:)` (via `@testable import`).
  - Measure completion-to-visible latency (via a synthetic `.complete` event).
  - **Decision (GPT sign-off 2026-04-20):** no hard threshold. Shared self-hosted runners make absolute-time assertions noisy. Run locally, capture numbers, paste them in the PR body as evidence. CI stays green on correctness only.

---

## 11. Testing

### Unit tests (new)

| Module | Test case | Purpose |
|---|---|---|
| TranscriptCoordinator | `testAppendInsertsAtIndexZero` | Contract: newest-first invariant |
| TranscriptCoordinator | `testAppendDoesNotMutateDisk` | Contract: in-memory only (structural check, no spy) |
| TranscriptCoordinator | `testLoadDuringAppendMergesCorrectly` | Race fix (§3.4), single concurrent append |
| TranscriptCoordinator | `testLoadDuringMultipleAppendsPreservesNewestFirstOrder` | Race fix (§3.4), N concurrent appends; catches order-reversal bug |
| TranscriptCoordinator | `testStartupLoadPreservesPreexisting` | Regression guard |
| TranscriptCoordinator | `testDeleteAfterAppendRemoves` | Cross-method invariant |
| TranscriptStore | `testInitWithDirectoryUsesProvidedPath` | D8 safety surface |
| Characterization | `testV117FixtureLoadsIdentically` | Phase C Invariant #1 |
| Characterization | `testWriteAfterReadPreservesOld` | Phase C Invariant #2 |
| UpgradeFolderCopy | `testLegacyFolderCopyPreservesAllTranscripts` | Phase C Invariant #4 (upgrade-path) |

### UAT

**Manual, live dictation, both backends:**

1. Start app at current branch HEAD, confirm history view loads founder's real transcripts (>100 rows expected).
2. Dictate 3 fresh transcripts via Parakeet.
   - PASS: each appears at top of history list within one frame of `.complete`.
   - PASS: no stutter/hitch during completion (measurable via subjective feel or instrumented trace).
3. Switch backend to WhisperKit, dictate 2 more.
   - PASS: same behavior.
4. Quit app. Relaunch.
   - PASS: all 5 new transcripts persist.
   - PASS: all prior transcripts persist.
5. Phase C Invariant safeguard #3 (dogfood): founder runs the Phase C build as daily driver for at least 24 hours before merge.

### Benchmarks

Manual, not CI-gated. Seeded 1000-transcript directory via `TranscriptStore(directory:)`. Measure:
- `.complete → UI update` latency. Pre-change: proportional to history size (O(n) loadAll). Post-change: constant (in-memory insert). Numbers captured in PR body as evidence, not asserted in test.

---

## 12. Blast radius & rollback

### Modules touched

- `Sources/EnviousWispr/App/` — `AppState.swift`, `TranscriptCoordinator.swift` (app target).
- `Sources/EnviousWisprStorage/` — `TranscriptStore.swift` (library target).
- `Tests/EnviousWisprTests/App/` — new test files.

### Modules NOT touched (negative space)

- `Sources/EnviousWisprPipeline/` — `TranscriptFinalizer.swift` persistence unchanged. `TranscriptPolishService.swift` `loadAll()` call deferred (separate issue).
- `Sources/EnviousWisprCore/Transcript.swift` — `Codable` shape unchanged.
- Pipelines (`TranscriptionPipeline.swift`, `WhisperKitPipeline.swift`) — `.complete` emission timing unchanged. `currentTranscript` population unchanged.
- Views — `Views/Main/HistoryContentView.swift:31` startup `.task { load }` unchanged. Detail pane unchanged.

### Rollback

`git revert` on the squash-merge commit. Because the on-disk format is unchanged, revert is clean and carries no migration risk. Heart completion falls back to the pre-Phase-C `load()`-based behavior — same code that has been in production since v1.0.

---

## 13. Ship criteria

Mirrors Bible §9.4 + Phase C Invariant + workflow-process §12.

- [ ] `scripts/swift-test.sh` passes (all tests, including new Phase C tests)
- [ ] `swift build -c release` exit 0
- [ ] `grep -n "transcriptCoordinator.load()" Sources/EnviousWispr/App/AppState.swift` returns zero hits
- [ ] `grep -cn "transcriptStore" Sources/EnviousWispr/App/AppState.swift` returns exactly 1 (the composition-root `let transcriptStore = TranscriptStore()` inside init, plus zero property-level declarations). Grounded Review 2026-04-20 noted the earlier "zero hits" formulation contradicted the composition-root pattern.
- [ ] UAT steps 1–4 above all pass
- [ ] Phase C Invariant safeguard #1 (read-compat characterization test) green
- [ ] Phase C Invariant safeguard #2 (write-after-read test) green
- [ ] Phase C Invariant safeguard #3 (24-hour founder dogfood) confirmed
- [ ] Phase C Invariant safeguard #4 (upgrade-time folder-copy test) green — covers the zero-history-loss gap council flagged
- [ ] Seeded 1000-transcript perf measurement captured in PR body (manual, non-blocking)
- [ ] Council approval on this plan (§2 workflow-process)
- [ ] Grounded Review returns YES or YES_WITH_REVISIONS
- [ ] Codex diff review clean after build (multiple rounds until clean)
- [ ] Zero em-dashes / en-dashes in new code and this plan
- [ ] Architecture DoD satisfied (REFACTOR requires full checklist)
- [ ] Architecture Closeout section added to issue closure comment
- [ ] CI `build-check` + `polish-eval-smoke` green on PR
- [ ] #428 closed with closeout comment

---

## 14. Open questions

All five pre-council questions resolved by GPT sign-off 2026-04-20. Recorded here for audit trail.

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Race: union-by-ID merge vs. cancel-in-flight `loadTask` | **Union-by-ID merge** | History is user-authored data. Defensive correctness wins over the small LOC savings. |
| 2 | 1000-transcript perf test: hard threshold, ratio, or manual? | **Manual / non-blocking.** Evidence captured in PR body. | Shared self-hosted runners make absolute-time assertions noisy. CI stays on correctness. |
| 3 | `TranscriptPolishService.swift:163` `loadAll()` — opportunistic fix here? | **Defer.** Separate post-epic issue. | Blast-radius discipline. Phase C stays scoped to the completion-path reload. |
| 4 | `init(directory:)` visibility: `public` or `internal` + `@testable`? | **`internal` + `@testable import`** | architecture-rules § "public is expensive." SPM `@testable` is confirmed clean across the library boundary. |
| 5 | Telemetry contract: does load-cost disappearing change observability? | **Treat as "same event, lower latency."** Verify nothing downstream implicitly depended on the slower completion path. | No contract change. Observability audit step added to substep ordering (§10). |

**Council round 1 complete (2026-04-20).** Both reviewers (GPT + Gemini) returned YES_WITH_REVISIONS. Convergent finding: §3.4 merge algorithm had an order-reversal bug + a `Dictionary(uniqueKeysWithValues:)` crash risk. Independent findings folded in:

- **GPT:** composition-root wiring locked (no coordinator store accessor); widened `TranscriptStore(` grep; upgrade-folder-copy test added; `testAppendDoesNotMutateDisk` reworded to avoid protocolization; multi-append and delete-during-load rows added to §7.
- **Gemini:** delete/deleteAll consumer row added (grep confirms zero external callers); finalizer-save-failure row added to §7 as accepted degradation; Swift 6 concurrency note added (existing `Task.detached` in `loadAll` already off-MainActor); external-file-modifications behavioral note added to §5.

All revisions additive, no contradictions, no scope changes. Ready for Grounded Review.

**Grounded Review complete (2026-04-20).** Codex (gpt-5.4, high reasoning, read-only sandbox) returned YES_WITH_REVISIONS. All 8 factual claims verified against HEAD. Real corrections folded in:

- **§7 failure-mode table.** Removed the bogus "finalizer throws but `.complete` fires anyway" row. Pipelines emit `.error("Failed to save transcript")` on save failure (TranscriptionPipeline.swift:898, WhisperKitPipeline.swift:977) — `.complete` is never observed, so `coordinator.append` never runs. No orphan in-memory row exists. Row reframed as evidence of the safety property, not a failure to guard against.
- **§10 `Package.swift` addition.** `EnviousWisprTests` target does NOT currently depend on `EnviousWispr` or `EnviousWisprStorage`. `@testable import EnviousWisprStorage` + coordinator tests require adding both to line 125. Explicit substep added.
- **§5 / §6 / §13 path fix.** `HistoryContentView.swift` lives at `Sources/EnviousWispr/Views/Main/HistoryContentView.swift`, not the shorter path the plan used. Fixed globally.
- **§3.1 / §13 wording fix.** AppState composition root IS the construction point (plan earlier implied coordinator was). Corrected so the ship criterion greps for exactly one composition-root `let` instead of zero.
- **§3.4 ordering contract note.** Merge preserves append order, not strict global `createdAt`-desc sort across arbitrary data. Future-dated or imported-forward transcripts are an accepted edge case.
- **§6 missing consumers.** Added rows for `TranscriptHistoryView`, `SidebarStatsHeader`, and `AppState.activeTranscript` resolve-through at `:700` + `:918`. Grounded Review flagged these as transcript-history consumers not explicitly called out.
- **§10 / §11 / §13 safeguard #4 ownership gap.** Upgrade-folder-copy hook had no owner in production code. Added explicit Option A (write migrator) / Option B (replace with readable-directory assertion) decision substep. `TranscriptUpgradeFolderCopyTests` now covers whichever path is chosen.

**No net-new open questions.** All Grounded Review findings resolved by revisions above.

---

## 15. Related

- **Parent:** #319 (Refactor Bible epic)
- **Predecessors:** #196 (Phase A, shipped PR #422), #195 (Phase B, shipped PR #424)
- **Bible sections:** §9 (Phase C design), §27.2 (persistence boundary — superseded by §9.2 v1.6), §3.1 + §3.5 (ownership laws), §4.1 + §4.2 + §4.3 + §4.9 (AppState / coordinator / store current state)
- **Decisions doc:** `docs/feature-requests/issue-319-open-decisions-2026-04-18.md` — D7, D8, Phase C Invariant (3 safeguards + reinstated upgrade-time folder copy)
- **Memory entries:** none directly blocking; `reference-copy-drift.md` (careful when reading "reference" copies of on-disk formats)
- **Gotchas:** `conventions.md` DI patterns; `gotchas.md` "stale bundle" and persistence-ordering items
- **Rule files in scope:** architecture-rules.md (full DoD), swift-patterns.md (@MainActor @Observable contract), validation-discipline.md §11 (characterization test before refactor)

---

## Checklist for the plan author

- [x] Sections 4–9 are filled with real greps and real file refs.
- [x] Every new error case has a row in the failure-mode table.
- [x] Every new nullable/signal field has a row in the signals audit or explicit "none" with proof.
- [x] Every fallback branch has a defined source-of-truth.
- [x] File-by-file changes reference actual file paths that exist (grep-confirmed 2026-04-20).
- [x] Testing section names actual test files to be added.
- [x] Architecture DoD applies (REFACTOR): addressed in §13 ship criteria.

## Checklist for the council reviewer

- [ ] Contract deltas complete — any missed semantic signal?
- [ ] State & lifecycle audit covers every upstream source, including rare/test paths?
- [ ] Consumer matrix lists every real consumer, not just obvious ones?
- [ ] Failure modes cleanly distinguish Failure / Bypass / Fallback?
- [ ] Signals audit catches implicit truthy checks?
- [ ] Every fallback branch names a concrete source-of-truth?
- [ ] Scope proportional to risk, or is template filled mechanically?
- [ ] Phase C Invariant safeguards (read-compat + write-after-read + dogfood + upgrade-time folder copy) all covered?
- [ ] Race design (§3.4 union-merge) is the right call vs. alternatives?
