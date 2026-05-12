# Issue #716 — Keychain Migration — 2026-05-11

GitHub issue: `#716`. Parent / epic: n/a. Tier: MEDIUM. Status: Implemented.

## Preface — Lane + Live UAT Declaration

**Lane:** Code.

**Live UAT:** Y. Success means a user can save an OpenAI or Gemini key, restart the app, and still use LLM polish. Release-mode UAT must also prove the key is stored in Apple Keychain, not left as a plaintext customer key file.

## Preface — User Rubric

User Rubric: N/A — internal security/storage fix. The only user-visible effect should be that existing keys keep working after migration and new keys persist securely.

## 0. TL;DR

Move customer OpenAI/Gemini key storage from plaintext files to Apple Keychain for release builds, while keeping the existing file path for debug builds so local development does not reintroduce Keychain password prompts. Existing release users with `~/.enviouswispr-keys/openai-api-key` or `gemini-api-key` migrate on first read: copy to Keychain, then delete the legacy file only after the Keychain write succeeds.

## 1. Problem

`Sources/EnviousWisprLLM/KeychainManager.swift` is named like a Keychain wrapper but currently stores customer OpenAI and Gemini keys as plaintext files under `~/.enviouswispr-keys/`. The current source comment says this was chosen because ad-hoc SPM builds caused Keychain entitlement / cdhash prompt issues. That is still relevant for local debug builds, but it is no longer the right production default for shipped Developer-ID-signed customer builds.

Prior context from `.claude/knowledge/session-log.md`: the May 10 local key cleanup left only the files the shipped app still reads, and explicitly tracks this customer-facing migration as `EnviousWispr#716`.

## 2. Goals & Non-Goals

### 2.1 Goals

- Release builds store OpenAI/Gemini customer API keys in Apple Keychain using generic password items.
- Debug builds keep the current secure file backend at `~/.enviouswispr-keys/` for dev friendliness.
- Existing release users migrate from legacy files without re-entering keys.
- Legacy files are deleted only after a successful Keychain write.
- Save, retrieve, and clear keep the current public `KeychainManager` call surface so connectors and settings code do not need broad rewiring.

### 2.2 Non-Goals

- Do not migrate Sentry, PostHog, Discord, MCP, or local developer keys. Those are separate local/ops paths.
- Do not move `KeychainManager` out of `EnviousWisprLLM`.
- Do not add AppState state or AppState-owned migration wiring.
- Do not change LLM provider selection, model discovery, or polish contracts.
- Do not change CI/eval scripts that intentionally read local developer keys.

## 3. Design

Keep `KeychainManager` as the narrow API-key storage owner. Internally split storage:

- `#if DEBUG`: use the existing POSIX-secured file backend.
- release-config `.dev` bundle ID (`com.enviouswispr.app.dev`): also use the existing POSIX-secured file backend, because `scripts/bundle-dev.sh` compiles release config for local dev smoke runs.
- production bundle ID (`com.enviouswispr.app`): use an Apple Keychain backend with legacy-file migration.

Release backend behavior:

0. Release migration/Keychain storage is scoped only to `KeychainManager.openAIKeyID` and `KeychainManager.geminiKeyID`. Unknown/local/ops filenames under `~/.enviouswispr-keys` must not be migrated or deleted.
1. `store(key:value:)`: add or update a generic password item scoped by service name and account key.
2. After a successful release `store`, remove the matching legacy plaintext file if present. If this cleanup fails, restore the previous Keychain value when one existed, or delete the new Keychain item when none existed, then throw so settings do not falsely report a passing secure-storage outcome.
3. `retrieve(key:)`: read the Keychain item first. Only `errSecItemNotFound` triggers legacy-file fallback. Other Keychain read errors surface as retrieve failure.
4. If a Keychain item is found, also try to remove any stale matching legacy file. Cleanup failure does not make the key unavailable, but it is a validation/UAT failure and should be visible in local logging.
5. If Keychain is cleanly not found, look for the legacy file. If the file exists, write it to Keychain, then delete the file, then return the value.
6. If legacy-file read succeeds but Keychain write fails, return the legacy value for the current session and leave the legacy file in place so an existing user's LLM polish does not break. Retry migration on the next read.
7. `delete(key:)`: delete the legacy file first, then delete the Keychain item. Missing Keychain item or missing file is harmless. Any non-missing deletion failure throws so clear/delete cannot appear successful while credentials can be resurrected.

The Apple Keychain item identity should be:

- service: `com.enviouswispr.app.api-keys`
- account: `openai-api-key` or `gemini-api-key`
- class: `kSecClassGenericPassword`
- access group: none. The app is not sandboxed and there is no current keychain-access-groups entitlement in `Sources/EnviousWispr/Resources/EnviousWispr.entitlements`.
- synchronizable: explicitly `false` for this PR. iCloud Keychain sync can be considered later, but local-only avoids changing the threat model while closing the plaintext-file gap.
- access control: no biometric/user-presence gate, so normal polish does not trigger prompts.
- Data Protection Keychain: not used. The release path uses regular generic password items and release UAT checks whether the shipped signing/entitlement shape prompts unexpectedly.

Error handling stays compatible with existing callers: missing keys still behave like retrieve failure to callers that currently use `try?`, while localized descriptions become more specific for save failures.

## 3b. Ownership Justification

Owner: `KeychainManager`.

Why this owner: this is not app-wide state, not view state, and not pipeline orchestration. It is the existing API-key storage utility already used by settings, model discovery, LLM connectors, prewarm, and pipelines. Keeping the behavior behind the same owner avoids pushing storage details into AppState or views.

Parent epic file path: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md`.

Direction signal for the proposed owner: the Q2 hardening epic is shrinking AppState and calls out `keychainManager = KeychainManager()` as a low-coupling utility that **stays** in AppState's composition root inventory, not as a decomposition target. It also flags AppState god-object growth as the problem to avoid.

Consistency with that direction: this plan adds zero AppState properties and keeps the existing storage utility narrow. It changes the storage backend, not the app's state ownership.

## 3a. Metric Definition + Earliest Failure Point

Metric Definition: no product metric or threshold changes. The release-mode storage assertion is binary:

- after any successful release `store`, no matching plaintext customer key file remains under `~/.enviouswispr-keys/`, and `security find-generic-password -s com.enviouswispr.app.api-keys -a <account>` finds the item;
- after successful first-read migration, no matching plaintext customer key file remains and the Keychain item exists;
- if a Keychain item already exists and a stale legacy file also exists, successful `retrieve` leaves the Keychain item usable and removes the stale file;
- after `delete`, both the Keychain item and matching legacy file are absent.

A Keychain write plus cleanup failure is not considered a passing secure-storage outcome. Release `store` rolls Keychain back and throws when stale-file cleanup fails. Release `delete` surfaces cleanup failures as thrown errors. Release `retrieve` may return a usable Keychain value despite cleanup failure, but emits a visible unified-log warning and validation must flag the leftover plaintext file.

Earliest Failure Point: build-time catches missing Security imports / Swift concurrency issues; focused unit tests catch file migration semantics and keychain CRUD; release UAT catches actual app signing/runtime behavior.

## 4. Contract Deltas

- `KeychainManager.store(key:value:)`
  - What changed: release builds write to Apple Keychain instead of a file.
  - Semantics: same caller meaning, more secure persistence backend.
  - Invariant: callers pass the existing stable key IDs; no API keys are logged; a successful release store means Keychain write succeeded and matching legacy cleanup did not fail. If cleanup fails, Keychain state is rolled back before the error surfaces. Release storage is limited to `openai-api-key` and `gemini-api-key`; unknown key IDs must not touch unrelated local/ops files.

- `KeychainManager.retrieve(key:)`
  - What changed: release builds read Keychain first, clean stale legacy files on Keychain hits, and migrate legacy files on Keychain misses.
  - Semantics: missing key remains a missing-key condition; migration write failure preserves current-session functionality by returning the legacy value while leaving the file for retry.
  - Invariant: only `errSecItemNotFound` triggers legacy fallback; legacy file deletion happens only after Keychain write succeeds, unless the key was already present in Keychain and the file is stale. Unknown key IDs must not trigger release migration or cleanup.

- `KeychainManager.delete(key:)`
  - What changed: release builds delete Keychain and clean any leftover legacy file.
  - Semantics: clearing a key still leaves the app with no API key for that provider.
  - Invariant: deleting a missing key remains harmless, but non-missing deletion failures throw. Delete removes the legacy file before deleting the Keychain item to avoid a later retrieve re-migrating a stale file after a user cleared the key. Unknown key IDs must not delete any release legacy files.

- `AIPolishSettingsView.clearKey(keychainId:)`
  - What changed: clear/delete errors become caller-visible instead of being swallowed with `try?`.
  - Semantics: clearing a key only updates the local field and resets model discovery after storage deletion succeeds.
  - Invariant: if delete fails, settings shows `Failed: ...`, preserves the typed/displayed key field, and does not falsely reset discovery as if the key were gone.

Legacy data compatibility: existing plaintext files are the legacy data. They are read, migrated to Keychain, and removed after successful migration. If both Keychain and legacy file exist, Keychain wins and the stale file is removed. No transcript or settings schema changes.

## 5. E2E State & Lifecycle Audit

| Path | Behavior under this change |
|---|---|
| Live / new item | User saves an API key in settings; debug writes file, release writes Keychain. |
| Saved / reloaded item | App restart retrieves the same key from the selected backend. |
| Retry or re-run | Re-saving the same provider updates the existing item. |
| Background / async completion after state changed | No new async migration task; migration runs inside synchronous retrieve. |
| User manual override / edit path | User can overwrite or clear a key through the existing settings buttons. |

Upstream sources: settings UI save/load/clear, `LLMModelDiscoveryCoordinator`, `OpenAIConnector`, `GeminiConnector`, `LLMNetworkSession.preWarmModel`, `TranscriptionPipeline`, `WhisperKitPipeline`, and app-launch `hasApiKeys` snapshot.

UI side effects: if saving fails, the existing settings validation message shows the localized error. If retrieving fails, current callers already treat that as missing/invalid key.

Persistence: only API-key storage changes. Debug persists files. Release persists Keychain items and removes matching legacy files after successful migration.

App-kill scenario: if the app is killed after Keychain write but before legacy deletion, the next launch sees the Keychain item and `retrieve` / `store` cleanup removes the stale legacy file. If killed before Keychain write completes, the legacy file remains and can retry on next launch.

Concurrency guard: operations are synchronous and idempotent per key. `SecItemAdd` handles new items, `SecItemUpdate` handles existing items, and migration writes the same value under the same account key.

## 6. Downstream Consumer Matrix

Discovery method: `rg -n "KeychainManager|keychainManager\\.(store|retrieve|delete)|openai-api-key|gemini-api-key" Sources Tests scripts docs .github Package.swift`

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| store backend changes | AI Polish settings save | writes file | debug writes file; release writes Keychain and cleans stale file | Maybe | KeychainManager tests + UAT |
| retrieve backend changes | AI Polish settings on appear | reads file or blank | release reads/migrates Keychain and cleans stale file; debug reads file | No UI rewrite expected | KeychainManager tests + UAT |
| retrieve backend changes | OpenAI/Gemini connectors | missing key maps to invalid API key | same caller behavior | No | existing connector tests + focused storage tests |
| retrieve backend changes | LLM model discovery | missing key shows no key found | same caller behavior | No | existing settings/model tests compile |
| retrieve backend changes | LLM prewarm | missing key silently skips | same caller behavior | No | build/tests |
| delete backend changes | AI Polish settings clear | currently swallows delete errors with `try?` and blanks local field | release/debug delete failures show `Failed: ...`; local key field and discovery are not reset unless delete succeeds | Yes | KeychainManager tests + settings clear UAT |

## 7. Failure-Mode x Caller Table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| Key not found | Keychain/file read | settings, discovery, connectors | blank key or invalid/no key message | no item | no new telemetry | user can save key |
| Keychain auth/user canceled | Keychain read/write | settings save/load, connectors | save shows failure; retrieve behaves as unavailable | no legacy delete unless write succeeded | no key metadata | user can retry |
| Migration write fails | release retrieve fallback | any first release read | key works for current session; migration retries later | legacy file preserved | has-key consumers see key for this read | next launch/read can retry |
| Legacy file delete fails after write | release migration/store cleanup | retrieve/store path | retrieve may still return Keychain value with warning; store reports failure | store rolls Keychain back; retrieve may leave Keychain item plus stale legacy until cleanup succeeds | has-key consumers see key on retrieve only | future cleanup/delete can remove |
| Legacy delete fails during clear | release delete | settings clear | clear reports failure; key must not be silently resurrected | previous credential state may remain | no new metadata | user/support can retry clear |
| Keychain delete fails during clear | release delete | settings clear | clear reports failure | Keychain item may remain; legacy already absent or missing | no new metadata | user/support can retry clear |
| Unknown/local/ops filename passed to release manager | release guard | any accidental caller | operation fails without touching unrelated files | unrelated file remains untouched | no key metadata | caller must use the proper storage path |

## 8. Caller-Visible Signals Audit

- `retrieve(...)` succeeds: model discovery can validate provider models; app-launch settings snapshot reports `hasApiKeys: true`; connectors can polish.
- `retrieve(...)` fails: settings fields appear blank on open; discovery reports no key or invalid key; connectors map failure to `LLMError.invalidAPIKey`.
- `store(...)` throws: settings save shows `Failed: ...` and discovery does not run.
- `delete(...)` succeeds or missing item: settings clears local field and discovery resets.
- `delete(...)` fails: settings shows `Failed: ...`, keeps the local field, and does not reset discovery.

No transcript `polishedText`, provider attribution, or saved-transcript semantics change.

## 9. Validation Strategy

- Add an injectable internal storage/backend seam so unit tests can exercise the Keychain backend even when the default test build is `DEBUG`.
- The injectable seam must include both the Keychain service name and the legacy-file base directory. Tests must point legacy files at a temporary directory, never at the real `~/.enviouswispr-keys/`.
- Focused unit tests for file backend permissions, store/retrieve/delete, Keychain CRUD with a test-only service name, release migration from legacy file to Keychain, stale-file cleanup on Keychain hit, stale-file cleanup after store, store cleanup failure, migration write-failure fallback, delete success with both stores present, delete with only Keychain present, delete with only legacy file present, and delete partial-failure behavior.
- Add a focused test that an unrelated legacy file such as `business-workspace-admin-sa.json` survives release store/retrieve/delete flows for OpenAI/Gemini keys.
- Test Keychain items use a unique service name like `com.enviouswispr.tests.api-keys.<UUID>` and fake values only. Tests delete that service/account before and after each run.
- `scripts/swift-test.sh --filter KeychainManager`
- `scripts/swift-test.sh -c release --filter KeychainManager` if the test harness supports the filter in release config; otherwise document the compile/runtime limitation and rely on injectable backend tests plus release UAT.
- Full `scripts/swift-test.sh`
- `swift build -c release`
- `scripts/validate-pr.sh`
- Debug UAT: rebuild in debug mode and confirm saving/retrieving still uses the dev file path.
- Dev-bundle smoke: `scripts/bundle-dev.sh` must not migrate/delete local developer key files even though it compiles release config, because the `.dev` bundle ID remains file-backed.
- Release UAT: before launching the release artifact, back up any real developer `openai-api-key` / `gemini-api-key` files from `~/.enviouswispr-keys/`, seed fake issue-specific values for UAT, and restore the developer files after UAT. This prevents release UAT from consuming the local debug keys needed by normal debug builds.
- Release UAT must run in a clean macOS user account/test machine, or must first check for existing `com.enviouswispr.app.api-keys` Keychain items for `openai-api-key` and `gemini-api-key`. If real production-service Keychain items exist, do not overwrite/delete them with fake UAT values unless the operator has deliberately backed them up or can re-enter them. Do not print or log real API key values while checking this state.
- Release UAT must use the shipped signing shape: the app from `scripts/build-dmg.sh` or an equivalently Developer-ID-signed bundle using `Sources/EnviousWispr/Resources/EnviousWispr.entitlements`. `scripts/validate-pr.sh` / `scripts/bundle-dev.sh` are not enough to prove release Keychain entitlement/prompt behavior because the dev bundle signs the main app without the main entitlements file.
- Before seeded legacy migration UAT, ensure the relevant production-service Keychain item is absent so `retrieve` actually exercises the legacy fallback path. Exception: the dedicated "Keychain item plus stale legacy file" case intentionally seeds both stores.
- Release UAT confirms migration removes the seeded legacy file and `security find-generic-password` finds the Keychain item.
- Release UAT also covers: new save; restart after migration; Keychain item plus stale legacy file; clear/delete. After clearing and restarting, Settings must not repopulate the key, provider polish/model discovery must behave as missing-key rather than using a resurrected legacy file, `security find-generic-password -s com.enviouswispr.app.api-keys -a <account>` must not find the item, and the matching `~/.enviouswispr-keys/<account>` file must be absent. Watch for any Keychain prompt during normal polish.
- After fake migration/new-save UAT, delete any fake issue-specific Keychain items and restore backed-up debug legacy files so future debug and release runs start from the intended state.
- Codex plan grounded review before coding; Codex code-diff review after build/UAT before push.

## 10. Code Reality Check

Observed current code:

- `Sources/EnviousWisprLLM/KeychainManager.swift` stores files under `~/.enviouswispr-keys`.
- `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` loads, saves, and clears keys through `appState.keychainManager`.
- `Sources/EnviousWispr/App/AppDelegate.swift` uses `retrieve` only to compute `hasApiKeys`.
- `Sources/EnviousWispr/App/LLMModelDiscoveryCoordinator.swift`, `OpenAIConnector`, `GeminiConnector`, and `LLMNetworkSession` all use `retrieve`.
- The Q2 hardening epic says `KeychainManager` stays as a low-coupling utility, while AppState is the owner to avoid growing.

Commands used:

```bash
gh issue view 716 --comments
grep -nE "#716([^0-9]|$)" .claude/knowledge/session-log.md
gh pr list --state open --limit 40 --json number,title,headRefName,url,labels
git log --oneline --decorate -n 30 --grep='716\|Keychain\|plaintext\|api key\|Apple Keychain' --all
rg -n "KeychainManager|enviouswispr-keys|openai-api-key|gemini-api-key|SecItem|kSecClassGenericPassword" Sources Tests docs scripts .github Package.swift
rg -n "KeychainManager|keychainManager\.(store|retrieve|delete)" Sources Tests --glob '*.swift'
```

## 11. Rollout / Customer Communication

No proactive user-facing message is needed if migration succeeds silently. If a user opens settings after migration, the key should still appear as before. If Keychain write fails, raw dictation still works because LLM polish is a limb; the user can re-save the provider key in Settings. Support/debug instructions must not ask users to send plaintext key files. A safe support reset can target only the service/account pair, for example `security delete-generic-password -s com.enviouswispr.app.api-keys -a openai-api-key`.

## 12. Architecture DoD Notes

- Module/owner chosen: `EnviousWisprLLM.KeychainManager`.
- Why placement is correct: API-key storage belongs with LLM provider integration and is already a narrow utility.
- Whether any central type grew: AppState gains no state or collaborator.
- Whether access control widened: avoid widening unless tests need internal test seams.
- Whether dependency direction remains clean: `EnviousWisprLLM` still depends only on Core/Foundation plus platform Security.
- Temporary compromise: debug builds intentionally keep file storage to avoid local Keychain prompt churn.

## 13. PR Notes To Carry Forward

- Link issue #716.
- State `council-skip` is not used; full MEDIUM workflow ran.
- Include validation run directory.
- Include explicit debug/release UAT results.
- Do not merge; leave final approval to Saurabh / Claude Code.
