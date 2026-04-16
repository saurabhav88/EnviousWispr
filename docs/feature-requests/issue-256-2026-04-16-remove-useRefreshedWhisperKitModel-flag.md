# Issue #256 — Delete WhisperKit variant-swap infrastructure — 2026-04-16

GitHub issue: `#256`. Parent / epic: #242 (Multilingual v1, closed). Tier: **MEDIUM** (touches ASR, Services, App, XPC protocol). Status: DRAFT.

## 0. TL;DR

EnviousWispr has one WhisperKit model: `openai_whisper-large-v3-v20240930_turbo` (shipped with Multilingual v1 on 2026-04-12). No UI exposes the model picker. The `useRefreshedWhisperKitModel` flag (#246 emergency rollback) and the `whisperKitModel` setting it controlled are plumbing for a dial that doesn't exist in the product. The flag is also broken (#256: XPC cold-start sends empty variant, ignoring the flag). This plan deletes the entire variant-swap subsystem — flag, setting, persistence, onChange plumbing, and the XPC `modelVariant` parameter — leaving `WhisperKitBackend.defaultModelVariant()` as the single source of truth for the canonical model string. If we ever reintroduce variant choice, we'll design it intentionally with UI + tests, not resurrect cold plumbing.

## 1. Problem

### 1a. Feature without a surface
`SettingsManager.whisperKitModel`, `SettingKey.whisperKitModel`, `ASRManagerInterface.updateWhisperKitModel`, `ASRManagerProxy.lastModelVariant`, `PipelineSettingsSync.handleSettingChanged(.whisperKitModel)`, and the XPC `loadModel(modelVariant:)` parameter collectively implement: *when the user changes the WhisperKit model setting, propagate the new variant to the ASR subsystem*. There is no UI that changes the setting. Grep verified: `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift` has the WhisperKit section but no model picker; nowhere in `Views/` writes `settings.whisperKitModel`. The only way to mutate this state is `defaults write com.enviouswispr.app whisperKitModel ...`, which is not a product feature.

### 1b. Broken emergency lever
`useRefreshedWhisperKitModel` (the flag) was meant as an emergency rollback for W4's model swap. Since `ASRManagerProxy.lastModelVariant` starts `""` at app launch and is only populated by the `.whisperKitModel` onChange callback (`PipelineSettingsSync.swift:141`), the first XPC `loadModel` call after cold start sends `""` to the service. `ASRServiceHandler.swift:82-84` falls back to the refreshed variant unconditionally. Net effect: rollback doesn't work, even if someone runs `defaults write useRefreshedWhisperKitModel -bool false`.

### 1c. Stale documentation
`SettingsManager.swift:65-69`, `WhisperKitBackend.swift:42-46`, `WhisperKitSetupService.swift:42-43`, and `ASRServiceHandler.swift:73-81` all describe the flag. `.claude/knowledge/whisperkit-research.md:95,158-160` describes the legacy variant as the "current default" — stale since 2026-04-12. `docs/feature-requests/multilingual-v1-followup.md:54-58,85` flags the XPC sync gap as a P3 follow-up; this PR closes it by deleting the need for sync.

## 2. Goals & non-goals

### 2.1 Goals
Delete 12 pieces of variant-swap infrastructure (enumerated in §10), keep 4 building blocks that have secondary value (enumerated in §10 "Preserved"), update 4 sources of stale documentation. After this PR:
- `git grep -n 'useRefreshedWhisperKitModel' Sources/ Tests/` returns 0.
- `git grep -n 'whisperKitModel' Sources/ Tests/` returns only references to the cache-path constant `whisperKitModelRoot` (unrelated).
- The XPC `loadModel` signature is simplified to `(backendType:reply:)` — `modelVariant` parameter gone.
- `WhisperKitBackend.defaultModelVariant()` is the single canonical accessor; its body returns the literal string, no UserDefaults read.
- GitHub issue #256 closed with link to merged PR.

### 2.2 Non-goals
- Adding a new variant-picker UI. If/when we want one, design from scratch.
- Migrating orphan UserDefaults keys (`whisperKitModel`, `useRefreshedWhisperKitModel`) off users' disks. Harmless; costly migration code would add risk for cosmetic cleanup.
- Refactoring the WhisperKitPipeline backend instantiation (`AppState.swift:133` creates a separate WhisperKitBackend for pipeline telemetry). Out of scope; it already uses the default constructor and will continue to.
- Touching `WhisperKitBackend`'s `modelVariant` ivar or constructor param — kept for test parameterization.

## 3. Design

### 3a. Delete the flag
Every reference removed. UserDefaults key becomes orphan (intentional, harmless).

### 3b. Delete the setting
`SettingsManager.whisperKitModel` goes away. `SettingKey.whisperKitModel` goes away. The `.whisperKitModel` onChange case goes away. The `AppState.swift:332` sync line goes away. `WhisperKitSetupService.modelVariant` becomes `let modelVariant = WhisperKitBackend.defaultModelVariant()` (was `var`, fed from the setting).

### 3c. Simplify the XPC interface
`ASRServiceProtocol.loadModel(backendType: String, modelVariant: String, reply:)` becomes `loadModel(backendType: String, reply:)`. Service hardcodes `WhisperKitBackend()` — default constructor uses `defaultModelVariant()`. No cross-process coordination needed; the canonical constant lives in one Swift file (`WhisperKitBackend.defaultModelVariant()`), is used at the WhisperKit backend construction site, and imported transitively by both the app target and the XPC service target (both import `EnviousWisprASR`).

### 3d. Collapse the canonical constant
`WhisperKitBackend.defaultModelVariant()` already exists. Its body currently reads UserDefaults; new body returns the literal directly:

```swift
public static func defaultModelVariant() -> String {
  "openai_whisper-large-v3-v20240930_turbo"
}
```

One function, one literal, one place to change when we next swap models.

### 3e. Knowledge and doc updates
`whisperkit-research.md` lines 95 and 158-160 rewritten to match reality (refreshed is default, single accessor). `multilingual-v1.md` and `multilingual-v1-followup.md` get a resolution footer.

## 4. Contract deltas

### Removed public API
- **`SettingsManager.useRefreshedWhisperKitModel: Bool`** (property + `didSet` + persistence)
- **`SettingsManager.whisperKitModel: String`** (property + `didSet` + persistence)
- **`SettingKey.useRefreshedWhisperKitModel`** (enum case)
- **`SettingKey.whisperKitModel`** (enum case)
- **`ASRManagerInterface.updateWhisperKitModel(_:)`** (protocol method)
- **`ASRServiceProtocol.loadModel(backendType:modelVariant:reply:)`** → `loadModel(backendType:reply:)` (parameter removed)

### Changed
- **`WhisperKitBackend.defaultModelVariant()`**: body simplified; returns literal directly. Signature unchanged. Consumers (WhisperKitBackend init default, WhisperKitSetupService init default) unaffected.
- **`WhisperKitSetupService.modelVariant`**: `var` → `let`, initialized to `WhisperKitBackend.defaultModelVariant()`. No external mutator was needed after deleting the setting.
- **`SettingsManager.init()`**: lines 407-431 (flag-aware default, one-time migration) deleted with no replacement. The setting they computed no longer exists.

### Legacy data compatibility
Two UserDefaults keys on users' disks become orphan:
- `"useRefreshedWhisperKitModel"` (Bool) — never read again.
- `"whisperKitModel"` (String) — never read again.

UserDefaults tolerates orphan keys. No crash, no side effect. Explicitly not migrating them away (cosmetic cleanup, zero benefit).

Behavior change for users who had either key set:
- `useRefreshedWhisperKitModel=false`: was already getting refreshed on cold start due to the flag bug. Same outcome.
- `whisperKitModel=legacy` (via `defaults write`): was getting refreshed on cold start due to the XPC sync bug. Same outcome; now it's also deterministic instead of accidental.
- `whisperKitModel=refreshed`: same as today.

No observable behavior change for any actual user.

## 5. E2E state & lifecycle audit

| Path | Before | After |
|---|---|---|
| Fresh install, WhisperKit Multi-Language | Init reads flag, sets whisperKitModel=refreshed, persists. First loadModel XPC sends `""` → fallback loads refreshed. | Init skips the whole block; `WhisperKitSetupService.modelVariant` inits to refreshed via `defaultModelVariant()`. First loadModel XPC doesn't pass a variant; service loads refreshed. Same loaded model; fewer moving parts. |
| Returning user on refreshed (~100% of users) | As above. | As above. No behavior change. |
| Returning user with `whisperKitModel=legacy` persisted in UserDefaults (near-zero) | XPC sent `""` → refreshed (bug). | Setting no longer read; service loads refreshed directly. Same outcome. |
| Returning user with `useRefreshedWhisperKitModel=false` persisted (near-zero) | Flag ignored on first loadModel (bug). | Flag key not read; service loads refreshed. Same outcome. |
| Cold restart | XPC sync gap → empty variant → fallback. | No variant to sync; XPC call is simpler. Gap closed by elimination, not repair. |
| Settings → Models picker | No picker exists. | No picker exists. Unchanged. |
| User switches backend Fast English → Multi-Language at runtime | `selectedBackend` onChange fires → `switchBackend(.whisperKit)` → next loadModel uses whatever variant propagation state was left behind (`""` on first time, `refreshed` on subsequent). Service applies fallback if needed. | `selectedBackend` onChange fires → `switchBackend(.whisperKit)` → next loadModel sends backendType only → service loads `WhisperKitBackend()` (refreshed). Deterministic. |
| XPC service crash + reconnect | `resendConfigIfNeeded()` is a no-op today (clears a flag, nothing else); next loadModel replays with `lastModelVariant` state. | `resendConfigIfNeeded()` unchanged (still a no-op); next loadModel replays with no variant param, service uses its hardcoded default. Same outcome. |
| Force-quit during init | Next launch re-runs init. | Next launch re-runs init. No persisted derived state. |

### Upstream sources
`SettingsManager.init()` runs once at `AppState` construction; `WhisperKitBackend.defaultModelVariant()` is called at WhisperKitBackend init and WhisperKitSetupService init. No other entry points.

### UI side effects
None. The deleted `SettingKey` cases had no UI binding.

### Persistence
Two UserDefaults keys orphaned on disk (§4). No schema change, no file rewrite.

### Concurrency guard
All deleted code ran on `@MainActor` (SettingsManager, PipelineSettingsSync, AppState). No cross-actor contracts broken.

## 6. Downstream consumer matrix

Discovery method (repo-wide):
```
git grep -n 'useRefreshedWhisperKitModel'
git grep -n 'whisperKitModel'            # excluding whisperKitModelRoot
git grep -n 'updateWhisperKitModel'
git grep -n 'lastModelVariant'
git grep -n 'modelVariant:'              # loadModel call sites
git grep -n 'defaultModelVariant'
```

| Contract delta | Consumer | Required behavior | Code change | Verified by |
|---|---|---|---|---|
| Flag deleted | `SettingsManager.swift` lines 9, 46, 64-75, 411-430, 548-549 | all removed | Yes | file edit |
| Flag deleted | `WhisperKitBackend.swift:42-52` | UserDefaults read → literal return | Yes | file edit |
| Flag deleted | `WhisperKitSetupService.swift:42-43` | comment rewritten | Yes | file edit |
| Flag deleted | `PipelineSettingsSync.swift:299-302` | case removed | Yes | file edit |
| Setting deleted | `SettingsManager.swift` lines 9, 58-62, 407-431 | all removed | Yes | file edit |
| Setting deleted | `PipelineSettingsSync.swift:137-144` | case removed | Yes | file edit |
| Setting deleted | `AppState.swift:332` | line removed | Yes | file edit |
| `updateWhisperKitModel` protocol method | `ASRManagerInterface.swift:28` | method removed | Yes | file edit |
| `updateWhisperKitModel` impl (in-process) | `ASRManager.swift:61-67` | method removed | Yes | file edit |
| `updateWhisperKitModel` impl (XPC) | `ASRManagerProxy.swift:169-174` + `lastModelVariant:32` | both removed | Yes | file edit |
| XPC `loadModel` signature | `ASRServiceProtocol.swift:22-24` | parameter removed, doc updated | Yes | file edit |
| XPC `loadModel` caller (proxy) | `ASRManagerProxy.swift:74-80` | call simplified | Yes | file edit |
| XPC `loadModel` callee (service) | `ASRServiceHandler.swift:40, 82-86` | param removed, fallback branch removed, backend constructed with default | Yes | file edit |
| `WhisperKitSetupService.modelVariant` | `WhisperKitSetupService.swift:45` | `var` → `let` | Yes | file edit |
| `backend.modelVariantName` telemetry reader | `WhisperKitPipeline.swift:864` | unchanged — still reads the backend's configured variant | No | existing code |
| `WhisperKitBackend(modelVariant:)` default-arg caller | `ASRManager.swift:24`, `AppState.swift:133`, `WhisperKitSetupService.swift:45` | unchanged — default arg still works | No | existing code |
| Stale knowledge | `.claude/knowledge/whisperkit-research.md:95,158-160` | rewritten | Yes | file edit |
| Historical docs | `docs/feature-requests/multilingual-v1.md:155`, `multilingual-v1-followup.md:12,56,85,339` | resolution footer appended | Yes | file edit |

**No consumers missed.** Verified:
- Tests: 0 references via `git grep ... Tests/`.
- Scripts/CI/website: 0 references via repo-wide grep.
- Telemetry: `SentryBreadcrumb.updateASRBackend` uses only `"whisperkit"`/`"parakeet"`; PostHog `asr.completed` reads `backend.modelVariantName` (kept).
- Benchmark docs: one mention in `benchmark-results/superwhisper-modes-analysis.md:362` (competitor research, historical, no action).

## 7. Failure-mode × caller table

No new failure modes introduced.

Existing failure paths preserved:
| Failure | Origin | Current behavior | After this PR |
|---|---|---|---|
| WhisperKit download throws (offline, first run) | `WhisperKitBackend.prepare` | Error surfaces through loadModel → pipeline error path → user sees download error UX | Unchanged |
| XPC service crash mid-session | existing handler | `onServiceInterrupted` fires, next loadModel reconnects | Unchanged |
| Unknown backendType string in XPC loadModel | `ASRServiceHandler.swift:89-93` | Returns NSError | Unchanged |

## 8. Caller-visible signals audit

- **Removed properties** (`useRefreshedWhisperKitModel`, `whisperKitModel`): no UI binding, no persistence-read consumer besides self, no telemetry tag. Verified by repo-wide grep for each property name.
- **Removed `updateWhisperKitModel`**: was called from exactly one site (`PipelineSettingsSync`). That site is also being removed. No stale caller.
- **Removed XPC `modelVariant` parameter**: was passed from exactly one site (`ASRManagerProxy.loadModel`) and consumed at exactly one site (`ASRServiceHandler.loadModel`). Both updated in this PR.
- **Preserved `WhisperKitBackend.modelVariantName`**: read by `WhisperKitPipeline.swift:864` for PostHog `asr.completed.model`. Value now always reports the canonical variant. Telemetry dashboards that bucket by model will see one bucket instead of two — data-quality improvement.

No implicit signals beyond literal values.

## 9. Fallback source-of-truth audit

One fallback branch is being deleted: `ASRServiceHandler.swift:82-85` (`modelVariant.isEmpty ? refreshed : modelVariant`). Justification: with the `modelVariant` parameter gone, there is no input to be empty; the service simply constructs `WhisperKitBackend()` which uses `defaultModelVariant()`. Branch deletion is load-bearing simplification, not a behavior change — the `.empty` path was always the bug path, and the non-empty path was always "use what was passed" which is now equivalent to "use the default."

Source of truth post-PR: `WhisperKitBackend.defaultModelVariant()` body. Literal `"openai_whisper-large-v3-v20240930_turbo"` appears exactly once in `Sources/`.

## 10. File-by-file changes

### Deleted items

| # | Target | File:line | What happens |
|---|---|---|---|
| 1 | `SettingKey.useRefreshedWhisperKitModel` | `SettingsManager.swift:46` | case removed |
| 2 | `SettingKey.whisperKitModel` | `SettingsManager.swift:9` | case removed |
| 3 | `SettingsManager.useRefreshedWhisperKitModel` property | `SettingsManager.swift:64-75` | property + didSet removed |
| 4 | `SettingsManager.whisperKitModel` property | `SettingsManager.swift:58-62` | property + didSet removed |
| 5 | `SettingsManager.init` flag-aware migration block | `SettingsManager.swift:407-431` | block removed (no replacement) |
| 6 | `SettingsManager.init` flag assignment | `SettingsManager.swift:548-549` | lines removed |
| 7 | `WhisperKitBackend.defaultModelVariant` UserDefaults read | `WhisperKitBackend.swift:42-52` | body collapses to literal return |
| 8 | `PipelineSettingsSync` `.useRefreshedWhisperKitModel` case | `PipelineSettingsSync.swift:299-302` | case removed |
| 9 | `PipelineSettingsSync` `.whisperKitModel` case | `PipelineSettingsSync.swift:137-144` | case removed |
| 10 | `AppState.swift` sync line | `AppState.swift:332` | line removed |
| 11 | `ASRManagerInterface.updateWhisperKitModel` | `ASRManagerInterface.swift:28` | protocol method removed |
| 12 | `ASRManager.updateWhisperKitModel` | `ASRManager.swift:61-67` | method removed |
| 13 | `ASRManagerProxy.updateWhisperKitModel` + `lastModelVariant` | `ASRManagerProxy.swift:32, 169-174` | ivar + method removed; `proxy.loadModel` call at line 74-80 drops `modelVariant:` arg |
| 14 | XPC `loadModel` `modelVariant` parameter | `ASRServiceProtocol.swift:20-24` | parameter removed from declaration + doc comment |
| 15 | `ASRServiceHandler.loadModel` `modelVariant` param + fallback | `ASRServiceHandler.swift:40, 72-86` | signature simplified; fallback branch removed; backend constructed as `WhisperKitBackend()` |

### Modified items

| # | Target | Change |
|---|---|---|
| 16 | `WhisperKitSetupService.modelVariant` | `var` → `let`, initialized inline to `WhisperKitBackend.defaultModelVariant()` |
| 17 | Comments in `SettingsManager`, `WhisperKitBackend`, `WhisperKitSetupService`, `ASRServiceHandler` | Flag references removed; described to match post-PR reality |

### Knowledge / docs

| # | Target | Change |
|---|---|---|
| 18 | `.claude/knowledge/whisperkit-research.md:95,158-160` | "current default" annotation updated to refreshed; "Hardcoded default across all 3 locations" rewritten to describe single source of truth |
| 19 | `docs/feature-requests/multilingual-v1.md:155` | footer appended: "Flag removed in <PR>, 2026-04-16." |
| 20 | `docs/feature-requests/multilingual-v1-followup.md:12,56,85,339` | footer appended: "XPC sync gap closed by deleting the variant-swap subsystem entirely in <PR>, 2026-04-16." |

### Preserved (enumerated for clarity)

- `WhisperKitBackend.modelVariant` private ivar + constructor param (useful for tests, zero cost).
- `WhisperKitBackend.modelVariantName` public getter (read by WhisperKitPipeline telemetry).
- `WhisperKitBackend.defaultModelVariant()` static method (single canonical accessor; two callers still use it as default-arg value).
- `WhisperKitSetupService.whisperKitModelRoot` URL constant — UNRELATED to the setting; it is the HF cache directory path. Naming collision only.

## 11. Testing

### Unit tests
No tests to add. The deleted code had no test coverage (verified: `git grep ... Tests/` returns 0 for every deleted symbol). Adding tests for deleted code is anti-pattern. Existing `SettingsManagerTests` (if any) will catch any accidental break of remaining settings.

### UAT plan (all under `/wispr-rebuild-and-relaunch`)

1. **Fresh install Parakeet path** — launch app, onboard, complete Parakeet download, dictate in English, confirm transcript pastes. Sanity check that nothing in the main heart path was touched.
2. **Switch to Multi-Language** — in Settings, toggle Transcription Engine to Multi-Language. Confirm WhisperKit setup UI appears, download triggers (or detects cached), dictate in a non-English language, confirm transcript pastes.
3. **Cold restart on WhisperKit** — with Multi-Language selected, fully quit app (`pkill EnviousWispr`, `pkill EnviousWisprASRService`), relaunch, dictate immediately without touching Settings. Confirm log shows variant loaded, no empty-variant warning, transcript pastes.
4. **Flag ghost** — `defaults write com.enviouswispr.app useRefreshedWhisperKitModel -bool false`, quit + kill XPC, relaunch, dictate on WhisperKit. Confirm refreshed still loads (flag key is orphan).
5. **Setting ghost** — `defaults write com.enviouswispr.app whisperKitModel openai_whisper-large-v3_turbo`, quit + kill XPC, relaunch, dictate on WhisperKit. Confirm refreshed still loads (setting key is orphan; hardcoded default wins).
6. **Backend swap at runtime** — start on Fast English, dictate, switch to Multi-Language, dictate. Confirm both paths work.
7. **XPC service crash recovery** — during a WhisperKit session, `kill -9 $(pgrep EnviousWisprASRService)`, attempt next dictation, confirm reconnection + refreshed variant still loads.
8. **Build + Periphery** — `scripts/swift-test.sh` passes; `swift build -c release` exits 0; Periphery scan (scope: touched modules) shows no new unused symbols from the deletion.

### Benchmarks
Not applicable. Load path unchanged; no LLM change.

## 12. Blast radius & rollback

**Modules touched:**
- `EnviousWisprCore` — `ASRServiceProtocol` signature change.
- `EnviousWisprASR` — ASRManager, ASRManagerProxy, ASRManagerInterface, WhisperKitBackend, WhisperKitSetupService.
- `EnviousWisprServices` — SettingsManager.
- `EnviousWispr` (App) — AppState, PipelineSettingsSync.
- `EnviousWisprASRService` — ASRServiceHandler.

**Modules NOT touched:**
- Pipeline (TranscriptionPipeline, WhisperKitPipeline).
- PostProcessing, LLM, Audio, Storage, UI views.

**XPC interface change:** `loadModel(backendType:reply:)`. App and service ship in the same bundle; always rebuilt together. No versioning concern.

**Rollback plan:** single-commit revert. No schema migration. Orphan UserDefaults keys on user disks are unaffected by rollback; they remain orphan.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exits 0
- [ ] `git grep -n 'useRefreshedWhisperKitModel' Sources/ Tests/` returns 0
- [ ] `git grep -n 'whisperKitModel' Sources/ Tests/` returns only `whisperKitModelRoot` hits (unrelated)
- [ ] `git grep -n 'updateWhisperKitModel' Sources/ Tests/` returns 0
- [ ] `git grep -n 'lastModelVariant' Sources/ Tests/` returns 0
- [ ] `openai_whisper-large-v3-v20240930_turbo` literal appears once in `Sources/` (in `WhisperKitBackend.defaultModelVariant()`)
- [ ] UAT plan §11 green (all 8 scenarios)
- [ ] Codex review on diff: findings validated and addressed
- [ ] Periphery scan: no new unused symbols from this change
- [ ] Zero em-dashes / en-dashes in new code and docs
- [ ] Architecture DoD satisfied (MEDIUM tier): placement justified; no new god object; access control narrow; dependency direction clean
- [ ] Knowledge file `whisperkit-research.md` updated
- [ ] Historical plans get resolution footers
- [ ] GitHub issue #256 closed with merged PR link

## 14. Open questions

None at Gate 2. Every decision has been validated against the code or chosen explicitly (e.g., drop XPC param vs keep → drop, for simplification).

## 15. Related

- Parent issue: #256.
- Parent epic: #242 (Multilingual v1, closed 2026-04-12).
- Flag introduction: PR #257, workstream #246.
- Prior investigation notes: `docs/feature-requests/multilingual-v1-followup.md:54-58,85`.
- Stale knowledge: `.claude/knowledge/whisperkit-research.md:95,158-160`.
- Related active issues (NOT touched here): #276 (Gemma4 cold-path polish), #294 (warm-engine zero-buffer), #297 (XPC AudioService SIGABRT).
