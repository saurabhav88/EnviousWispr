# Issue #384 — Move PR + main-post-merge CI to hosted macOS runners — 2026-04-25

GitHub issue: `#384`. Parent epic: `#319` Hardening & Refactors. Tier: SMALL (code diff) + REFACTOR-adjacent (security surface). Status: KNOWLEDGE — branch dissolved, work captured here for resumption.

User Rubric: N/A — `#319` Hardening & Refactors is internal-only (per workflow-process §1 Gate 0.5 carve-out for #315/#318/#319/internal #317).

> **Why this file exists.** The in-progress branch `sec/issue-384-move-pr-ci-to-hosted` was dissolved 2026-04-25 because (a) the runs-on diff is trivial and goes stale faster than it ships, (b) viability was already proven by the probe branch, (c) keeping a long-lived stale branch around invites confusion, (d) the broader migration is bigger than that diff and needs proper resumption framing. This file is the resumption point.

## TL;DR

Two CI workflows currently target the founder's M4 Pro laptop as a self-hosted runner. Switch both to GitHub-hosted `macos-26`. The trivial part is 4 lines per workflow file. The non-trivial part is everything else: 24 carried-over Actions secrets, GitHub App re-install if/when the LLC org transfer happens, Dependabot reliability layers held in reserve, and a deliberate one-shot migration that doesn't quietly break release signing.

## Why now (problem)

`.github/workflows/main-post-merge.yml` and `.github/workflows/pr-check.yml` both target `runs-on: [self-hosted, enviouswispr-release]`. That runner is Saurabh's M4 Pro. From the issue body (external reviewer feedback, summarized):

- Self-hosted runner reduces trustworthiness for any future external observer or contributor.
- The runner Mac holds Apple Developer signing cert, API keys in `~/.enviouswispr-keys/`, SSH keys, Keychain.
- A malicious fork PR could modify `Package.swift` to pull a dependency with a build-time plugin → arbitrary code on the key-holding Mac → supply-chain compromise.
- CI only runs while the laptop is awake. Sleep mid-build hangs CI. One laptop = one runner = no parallelism.

## What "done" looks like

Both workflows run on GitHub-hosted `macos-26`. Laptop is out of the CI loop entirely. PRs run in parallel on hosted infra. Release signing continues to work (this is the gotcha — must be verified on first hosted run, not assumed).

## Probe-branch evidence (already proven)

`sec/issue-384-runner-probe` was pushed during the 2026-04-19 evening session. End-to-end verified on a hosted runner:

- `macos-26` runner queues fast on the public repo
- Xcode 26.4 selected via `sudo xcode-select -s /Applications/Xcode_26.4.app`
- Full `swift build -c release` succeeds
- All 341 Swift tests pass
- Probe branch was reference-only — never merged. Safe to delete after the production migration ships, but keeping it costs nothing.

## Minimal production diff (preserved from the dissolved branch)

The actual code change is exactly this. Both workflow files, four lines each:

```diff
# .github/workflows/main-post-merge.yml
 jobs:
   main-post-merge-build:
-    runs-on: [self-hosted, enviouswispr-release]
-    timeout-minutes: 15
+    runs-on: macos-26
+    timeout-minutes: 45

# .github/workflows/pr-check.yml
 jobs:
   build-check:
-    runs-on: [self-hosted, enviouswispr-release]
-    timeout-minutes: 30
+    runs-on: macos-26
+    timeout-minutes: 45
```

Timeout bumps to 45 minutes because cold hosted runners include Xcode-select + dependency-fetch overhead. Probe wall-clock landed comfortably inside that.

A `sudo xcode-select -s /Applications/Xcode_26.4.app` step must be added before any `swift build` / `swift test` step in both workflows (the probe branch has the exact YAML shape — copy from there).

## Empirical learnings from the probe (all of these have bitten before)

| Learning | Implication for the production PR |
|---|---|
| `macos-26-arm64` runner label queues indefinitely on public repos | Use plain `macos-26`. Default is Apple Silicon M1 — already what we want. |
| Default `macos-26` ships Swift 6.2.3 which errors on `Task.detached` sending-closure captures that Swift 6.3 accepts | Pin Xcode: `sudo xcode-select -s /Applications/Xcode_26.4.app` step before any `swift` invocation. |
| `scripts/swift-test.sh` had a latent `${REMAINING_ARGS[@]}` unbound-variable bug under bash 5.x `set -u` | Fixed on probe branch. **Verify the fix is on main** before the migration PR runs (`grep -n 'REMAINING_ARGS' scripts/swift-test.sh` should show the conditional `+"${...}"` form, not bare expansion). |
| Apple Intelligence is not available on hosted runners (no real Apple Silicon AFM device) | Tests gated by `@Test(.enabled(if: SystemLanguageModel.default.availability == .available))` will skip on hosted, run on the founder's laptop locally when the founder runs them. Apple's official pattern. Council-validated 2026-04-19 (GPT + Gemini, rounds 2 & 3). Not a compromise. |

## Carry-over secrets inventory (verified in #384 comment 1, 2026-04-19)

24 Actions secrets — all carry over on a same-account migration. On an LLC org transfer, all carry over too, but the GitHub App needs re-install.

- **Apple (9):** APPLE_API_ISSUER_ID, APPLE_API_KEY_BASE64, APPLE_API_KEY_ID, APPLE_ID, APPLE_ID_PASSWORD, APPLE_TEAM_ID, APPLE_TEAM_NAME, DEVELOPER_ID_CERT_BASE64, DEVELOPER_ID_CERT_PASSWORD
- **Sparkle (2):** SPARKLE_EDDSA_PUBLIC_KEY, SPARKLE_PRIVATE_KEY
- **Cloudflare (3):** CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_KEY, CLOUDFLARE_EMAIL
- **LLM (2):** GEMINI_API_KEY, OPENAI_API_KEY
- **Observability (5):** POSTHOG_API_KEY, SENTRY_AUTH_TOKEN, SENTRY_DSN, SENTRY_ORG, SENTRY_PROJECT
- **Bot automation (3):** APP_ID, APP_PRIVATE_KEY, APPCAST_BOT_TOKEN

External integrations and their transfer impact:

| Integration | Mechanism | Transfer impact |
|---|---|---|
| Cloudflare Pages deploy | `wrangler` CLI in GHA, uses CLOUDFLARE_* secrets | None — secrets carry over |
| Sentry dSYM upload | `sentry-cli`, uses SENTRY_* secrets | None |
| PostHog telemetry | Hardcoded in CI step, uses POSTHOG_API_KEY | None |
| Apple notarization | Custom CI steps, uses Apple secrets | None |
| Appcast auto-push | **GitHub App** (APP_ID / APP_PRIVATE_KEY) | **Re-install required if and when LLC org transfer happens** |
| APPCAST_BOT_TOKEN | Likely a PAT | May need re-issue — check scope before LLC migration |

## Dependabot reliability on hosted runners (from #384 comment 2, 2026-04-21)

On the current self-hosted runner, Dependabot PRs mostly succeed. The one failure mode observed (#412's initial build) was a 32-min timeout on cold cache. **That failure class gets louder on hosted runners** (cold cache every run, shared concurrency, per-minute cost).

**Layer 1 — already shipped:**
- **PR #437** — skip `polish-eval-smoke` jobs on Dependabot PRs (they can't change prompts or models; mirroring secrets to Dependabot scope is an exfil vector explicitly rejected).
- **PR #438** — cut Dependabot PR volume: monthly cadence, all patch+minor grouped into ONE PR per ecosystem, majors ignored by default, drop the phantom `ci` label.

**Layers 2 & 3 — held pending empirical data after migration ships:**
- **Layer 2 — Self-healing build retry.** Wrap `swift build` in `nick-fields/retry@v3` with `max_attempts: 2, retry_on: error`, bump `timeout-minutes` 30 → 45. Solves transient runner flake + cold-cache variance. Only worth adding if hosted runners actually flake.
- **Layer 3 — Session-free auto-merge for Dependabot.** Workflow that auto-approves + squash-merges patch/minor grouped PRs when all required checks pass, independent of any active Claude session. On hosted runners with a cost meter, fire-and-forget matters more than on self-hosted.

Both layers' implementation sketches live on the [#384 comment](https://github.com/saurabhav88/EnviousWispr/issues/384#issuecomment-4286202152). Don't pre-build either. Watch the first ~2 weeks of hosted-runner Dependabot activity, then decide.

## Decoupled from other security work

Per the 2026-04-19 session log: "LLC org transfer + forking-disable explicitly DECOUPLED from CI migration. Can do either/neither whenever."

The runner migration does NOT require:
- LLC org transfer to complete
- Fork disablement
- Push-discipline hook to land (it did, 2026-04-19 — no longer a blocker either way)

The earlier "DEFERRED pending discipline hardening first" framing is stale. The push-discipline hook is in place. The runner migration is no longer blocked on anything internal.

## Resumption checklist (when ready to ship)

1. **Re-read** `gh issue view 384 --comments` for any newer context that landed since 2026-04-25.
2. **Confirm** `${REMAINING_ARGS[@]+` fix is present on main: `grep -n 'REMAINING_ARGS' scripts/swift-test.sh`. If absent, port from probe branch first.
3. **Worktree** off current main: `git worktree add -b sec/issue-384-hosted-runner ../EnviousWispr-worktrees/wt-384 origin/main`.
4. **Diff** — apply the 4-line swap to both workflow files (above), and add the `xcode-select` pin step before any `swift` invocation in both. Copy the YAML from probe branch `sec/issue-384-runner-probe` for exact shape.
5. **Plan + GPT-5.5 council + Codex grounded review** per workflow-process.md §1. This is ship-path, security-adjacent — full process applies. The diff is small but the blast radius (CI for the entire repo, including release pipeline) is large.
6. **Push, PR, watch the first hosted run carefully** — that's the real smoke test. Pay particular attention to any signing or notarization step on `main-post-merge.yml` (Apple cert + API keys flow through hosted-runner secrets — verify they actually deliver).
7. **After main-green:** manually deregister the self-hosted runner from GitHub repo Settings → Actions → Runners. Otherwise it sits there idle, still labeled, future workflow misfires possible.
8. **Log first 2 weeks of hosted runtime + Dependabot results.** Decide whether Layer 2 (retry) and/or Layer 3 (auto-merge) need to ship.

## What gets unlocked

- Multiple PRs run CI in parallel.
- Saurabh's laptop is no longer load-bearing for the project's CI lifecycle.
- External contributors (if any future lands) don't touch your hardware.
- Foundation for "Handy-pattern" 100% hosted ephemeral-keychain release signing later, if you decide to go that direction.
- The supply-chain exfil concern from the original issue body is closed (no fork PR can reach a key-holding machine).

## Related

- Origin issue: #384
- Probe branch: `sec/issue-384-runner-probe` (reference-only, not merged)
- Dissolved branch: `sec/issue-384-move-pr-ci-to-hosted` (commits `c1b1c05` WIP + `bc235fd` merge-from-main; deleted 2026-04-25 after capturing here)
- Push-discipline hook (now in place): `.claude/scripts/check-push-discipline.sh`
- CI security architecture knowledge: `.claude/knowledge/ci-security-architecture.md`
- Dependabot Layer 1 PRs: #437 (skip polish-eval-smoke for bot), #438 (monthly grouped cadence)
- Layer 2 + 3 implementation sketches: [#384 comment 4286202152](https://github.com/saurabhav88/EnviousWispr/issues/384#issuecomment-4286202152)
- Bible parent: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` (Hardening & Refactors)
