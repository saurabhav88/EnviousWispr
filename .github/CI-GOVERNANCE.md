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

`main` is protected with required status checks:

- `build-check` (from `pr-check.yml`) — debug build, release build, test compilation
- `drift-check` (from `ci-drift-check.yml`) — SHA pinning, script existence, YAML validity

Direct pushes to `main` are allowed for the release bot (appcast updates) but
human changes should go through PRs.

## Drift detector

`ci-drift-check.yml` runs weekly (Monday noon UTC) and on manual trigger. It fails if:

1. Any workflow uses a floating action ref instead of a full SHA
2. Any script referenced by a workflow doesn't exist in the repo
3. Any workflow YAML has syntax errors

## Release flow

1. `./scripts/release-preflight.sh` — validates branch, clean state, release build, tests
2. Version bump + commit
3. Annotated tag + push (triggers `release.yml`)
4. CI builds, signs, notarizes, creates DMG, updates appcast, creates GitHub Release

Published releases are immutable. Never retag or force-push a release tag.
If a release is broken, cut a new patch version.

## When drift check fails

| Failure | Fix |
|---------|-----|
| Floating action ref | Pin to SHA — check Dependabot PRs first |
| Missing script | Create or update the script, or fix the workflow reference |
| YAML syntax error | Fix the YAML — usually a bad indent or missing quote |
