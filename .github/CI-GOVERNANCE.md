# CI Governance

How EnviousWispr keeps its CI deterministic and drift-free.

## Action pinning

All third-party GitHub Actions are pinned to **full commit SHAs**, not floating major tags.
This makes workflows immutable — a pinned SHA cannot be changed after the fact.

```yaml
# Correct — immutable
uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

# Wrong — floating, can change without notice
uses: actions/checkout@v6
```

The human-readable version tag is kept as a comment for readability.

## Dependabot

`.github/dependabot.yml` is configured to scan GitHub Actions weekly and open PRs
when pinned SHAs are outdated. Dependabot updates both the SHA and the comment.

Actions updates are grouped into a single PR per week to reduce noise.

## Required checks

`main` is protected via the `main-protection` ruleset (active) with required status checks:

- `build-check` (from `pr-check.yml`) — debug build, release build, test compilation
- `drift-check` (from `ci-drift-check.yml`) — SHA pinning, script existence, YAML validity
- Branches must be up to date before merging
- Restrict deletions and block force pushes enabled

Direct pushes to `main` are allowed for the release bot (appcast updates) but
human changes should go through PRs.

## Drift detector

`ci-drift-check.yml` runs weekly (Monday noon UTC) and on manual trigger. It fails if:

1. Any workflow uses a floating action ref instead of a full SHA
2. Any script referenced by a workflow doesn't exist in the repo
3. Any workflow YAML has syntax errors

## Release flow

Branch protection on `main` blocks direct pushes — every change goes through a PR with
`build-check` passing. The release flow:

1. Worktree from `origin/main`, bump version + What's New, commit on `release/v<version>`
2. Open PR → auto-merge once `build-check` passes
3. Sync local main, annotated tag the merge commit, push tag (triggers `release.yml`)
4. `release.yml` runs a 4-job idempotent pipeline:
   - **Preflight** — validates tag format (semver), required secrets, probes existing release/appcast state
   - **Build** — SDK probe → build → sign → notarize → DMG → Sparkle sign → upload artifacts (30-day retention)
   - **Publish Release** — idempotent: probes if release exists, creates or skips (clobber only in explicit `release-only` recovery mode)
   - **Publish Appcast** — inject entry → validate XML → push to main via App bypass token (falls back to PR if push fails)
5. Recovery via `workflow_dispatch` with modes: `full`, `release-only`, `appcast-only`, `assets-only`

Published releases are immutable. Never retag or force-push a release tag.
If a release is broken, use recovery modes or cut a new patch version.

## When drift check fails

| Failure | Fix |
|---------|-----|
| Floating action ref | Pin to SHA — check Dependabot PRs first |
| Missing script | Create or update the script, or fix the workflow reference |
| YAML syntax error | Fix the YAML — usually a bad indent or missing quote |
