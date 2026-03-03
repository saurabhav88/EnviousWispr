# Release Infrastructure Fixes — Implementation Plan

**Date:** 2026-03-02
**Status:** COMPLETE — all 3 PRs merged, branch protection simplified
**Branch base:** `main` (no develop branch — we branch directly off main)
**Brainstormed with:** Gemini (sessions: `implementation-plan`, `release-workflow-fix`, `sparkle-version-quirk`, `dev-best-practices`, `cleanup-plan`)

## Fixes

| # | Fix | Branch | Files | Risk |
|---|-----|--------|-------|------|
| 1 | Release workflow: direct push with PAT (no PR) | `fix/release-direct-push` | `.github/workflows/release.yml` | Medium |
| 2 | Move appcast URL to GitHub Pages | `fix/appcast-github-pages` | `Info.plist`, `release.yml` (SPARKLE_FEED_URL env) | Low |
| 3 | Document TCC reset procedure for dev+prod coexistence | `docs/tcc-dev-workflow` | `.claude/knowledge/gotchas.md` | None |

## Phase 1: Manual Prerequisites (User)

- [x] **Create Fine-Grained PAT** on GitHub > Settings > Developer settings > Fine-grained tokens
  - Name: `EnviousWispr Appcast Bot`
  - Repo: `saurabhav88/EnviousWispr` only
  - Permission: `Contents: Read and write` (nothing else)
- [x] **Add repo secret** `APPCAST_BOT_TOKEN` in repo Settings > Secrets > Actions
- [x] **Enable GitHub Pages** in repo Settings > Pages > Deploy from branch `main`, folder `/`
- [x] **Verify** `https://saurabhav88.github.io/EnviousWispr/appcast.xml` serves the current appcast

## Phase 2: Parallel Implementation (3 agents)

All three workstreams are fully independent — execute in parallel.

### Agent A: release-maintenance — Fix 1 (release.yml rewrite)

Branch: `fix/release-direct-push` off `origin/main`

Rewrite `.github/workflows/release.yml` "Commit updated appcast via PR" step:
1. Remove the PR creation + auto-merge logic entirely
2. Replace with direct push approach:
   - `actions/checkout@v4` with `token: ${{ secrets.APPCAST_BOT_TOKEN }}` and `ref: main`
   - Checkout happens AFTER the appcast.xml is generated (keep in same job to avoid artifact passing)
   - `git config user.name/email` for bot identity
   - `git add appcast.xml && git diff --staged --quiet || (git commit + git push)`
3. Add `git pull --rebase origin main` before push to handle race conditions
4. Keep everything in one job (simpler than splitting into two jobs with artifact passing)

### Agent B: release-maintenance — Fix 2 (GitHub Pages URL)

Branch: `fix/appcast-github-pages` off `origin/main`

1. Update `SUFeedURL` in `Sources/EnviousWispr/Resources/Info.plist`:
   - From: `https://raw.githubusercontent.com/saurabhav88/EnviousWispr/main/appcast.xml`
   - To: `https://saurabhav88.github.io/EnviousWispr/appcast.xml`
2. Update `SPARKLE_FEED_URL` env var in `release.yml` (if it overrides Info.plist at build time)
3. Note: existing installs keep old URL until they update — must keep appcast.xml in repo (Pages serves from repo)

### Agent C: general-purpose — Fix 3 (TCC documentation)

Branch: `docs/tcc-dev-workflow` off `origin/main`

Add new section to `.claude/knowledge/gotchas.md`:
- "Running Dev + Production Builds Simultaneously (TCC Permissions)"
- Document: separate bundle IDs, tccutil reset commands, reboot, re-grant sequence
- Document: the two-app workflow is standard practice (Raycast, Alfred, etc.)
- Reference the bundle IDs: `com.enviouswispr.app` (prod) vs `com.enviouswispr.app.dev` (dev)

## Phase 3: PRs and Merge

Merge order (least to most risk):
1. `docs/tcc-dev-workflow` — no code impact
2. `fix/appcast-github-pages` — one-line Info.plist change, takes effect next release
3. `fix/release-direct-push` — workflow change, test on next tag push

## Phase 4: Branch Protection Simplification (added during execution)

**Decision**: The enterprise-grade branch protection (required reviews, enforce admins, conversation resolution) was over-engineered for a solo dev. Simplified to CI-only:

- **Removed**: Required reviews (1 approval), enforce admins, conversation resolution
- **Kept**: `build-check` required status check, linear history, no force pushes
- **Rationale**: Required reviews = self-approval theater. Enforce admins forced the PAT bypass. CI gate is the real protection.
- **PAT still needed**: `GITHUB_TOKEN` can't bypass status checks regardless of enforce admins. `APPCAST_BOT_TOKEN` (admin PAT) bypasses because enforce admins is off.

## Gotchas (from buddy brainstorm)

- **Appcast URL transition**: Old installs still fetch from `raw.githubusercontent.com`. Since GitHub Pages serves from the same repo file, both URLs resolve to the same `appcast.xml` — no dual-update needed.
- **Git race condition**: `git pull --rebase` before push in release.yml handles concurrent main updates.
- **GitHub Pages propagation**: ~1-2 min delay after push to main. Acceptable for appcast updates.
- **PAT expiration**: Set to no expiration. Scoped to single repo, Contents only.
- **Enforce admins off**: You (the admin) can now accidentally push directly to main. Don't. Use PRs for the CI gate.

## Execution Log

1. PRs #10, #11, #12 created and merged (all CI green)
2. Fine-Grained PAT created via browser automation, stored as `APPCAST_BOT_TOKEN`
3. GitHub Pages enabled (source: main, path: /)
4. Branch protection simplified via `gh api` PUT
5. Documentation updated: `github-workflow.md`, `distribution.md`, `MEMORY.md`
