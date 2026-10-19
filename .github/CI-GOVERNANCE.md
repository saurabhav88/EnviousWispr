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

`main` is protected via the `main-protection` ruleset (active). The ruleset
requires exactly one status check:

- `build-check`: the required aggregate gate (from `pr-check.yml`). It runs
  `scripts/ci/fast-checks.sh --ci`, the pre-push hook's quick-check list minus the members
  another job covers (#3524), and is green only when those pass with none skipped and all
  four lanes it needs succeed:
  - `build-and-test`: the macOS lane, a Release-configuration build and the full logic
    suite when the change needs a build (`scripts/ci/classify-changes.sh` decides)
  - `worker-tests`: the worker unit suites
  - `website-check`: the website build and help checks when `scripts/ci/classify-changes.sh`
    requires website validation
  - `recipe-check`: #2868, when the PR adds more than 100 lines under `Tests/` AND touches
    core-path source (`CORE_PATHS` in the script: audio, ASR and pipeline folders), the newest
    first-parent commit in the PR's `base..head` range carrying a `Recipe:` trailer decides
    and must carry exactly one valid value (`scripts/ci/check-test-recipe.py --trailers`;
    the PR template lists the shapes)
- Restrict deletions and block force pushes enabled

The drift checks run inside `build-check` (see "Drift detector" below). Strict
"branches up to date before merging" is OFF, so a moved `main` needs no rebase.

Direct pushes to `main` are allowed for the release bot (appcast updates) but
human changes should go through PRs.

## Drift detector

Six `scripts/ci/fast-checks.sh` members, run by the local `pre-push` hook and by the
required `build-check` job (#3729; until then the weekly `ci-drift-check.yml`). They
fail if:

1. `ci-action-pins`: a workflow or composite action uses an external action not pinned
   to a full commit SHA
2. `ci-script-refs`: a workflow or composite action names a `scripts/….sh` that doesn't
   exist
3. `ci-yaml`: `yamllint` reports a problem in a workflow or action manifest
4. `release-notes-self-test`: the release-notes renderer can no longer read
   `WhatsNewContent.swift`
5. `appcast-shellcheck`: ShellCheck reports a problem in `scripts/ci/appcast-delivery.sh`
6. `appcast-self-test`: the appcast delivery owner's deterministic self-test fails

The first three share one file list, `scripts/ci/check-cache-paths.py`'s `discover()`,
read by `scripts/ci/check-ci-drift.py`.

## Release flow

Branch protection on `main` blocks direct pushes — every change goes through a PR with
`build-check` passing. The operator procedure is owned by the release skill
(`.claude/skills/wispr-release-checklist/SKILL.md`, gitignored); the automation is:

1. `scripts/release.sh start <V>` makes the `release/v<V>` worktree, sets the version and
   writes `.github/release-notes/v<V>.md` (GitHub notes) and `v<V>.probes` skeletons.
2. `scripts/release.sh prepare` regenerates the derived files; the release PR merges after
   `build-check`.
3. `release-tag.yml` tags the recorded merge commit `v<V>` with the release bot token
   (`scripts/ci/release-tag-guard.sh`), which starts `release.yml`.
4. `release.yml` (nine jobs; its header is the job list): preflight requires the committed
   notes and probes for a new build; the build checks the probes in the Release binary;
   publish uses the committed notes; limbs publish the appcast, Sentry symbols and the
   Homebrew cask and verify the downloads; release-summary reports every job.
5. Recovery via `workflow_dispatch` modes `release-only`, `appcast-only`, `sentry-only`
   (with `source_run_id`), plus `full`/`build-only` and `dry_run` rehearsals.

Never move or reuse a release tag. If a release is broken, pull it from the appcast and
ship a higher patch version.

## When drift check fails

| Failure | Fix |
|---------|-----|
| Floating action ref | Pin to SHA — check Dependabot PRs first |
| Missing script | Create or update the script, or fix the workflow reference |
| YAML syntax error | Fix the YAML — usually a bad indent or missing quote |
