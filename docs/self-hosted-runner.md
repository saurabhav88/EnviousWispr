# Self-Hosted GitHub Actions Runner

> **FULLY DECOMMISSIONED (#1087, 2026-07-02).** The release pipeline (`release.yml`)
> migrated to GitHub-hosted runners (PR #1113, 2026-06-20) with ephemeral-keychain
> signing — no machine at rest holds the signing cert. Two real releases shipped
> clean end-to-end on hosted (v2.2.0 2026-06-24, v2.2.1 2026-07-01). The runner
> (`enviouswispr-release`) has now been fully removed: unregistered from GitHub
> (`gh api --method DELETE .../actions/runners/22`) and the local install at
> `~/actions-runner/` deleted. Everything below — Current Setup, Workflow Split,
> Managing the Runner, Recovery — is HISTORICAL, describing a runner that no longer
> exists. Retained only as the re-registration recipe if a self-hosted lane is ever
> needed again.

## Why (obsolete — see banner)

Release builds require the macOS 26 SDK for FoundationModels (Apple Intelligence).
GitHub's hosted runners (`macos-15`) don't have it. Larger runners (`macos-26-large`)
require a Team/Enterprise org plan. A self-hosted runner on our macOS 26 machine is
free, fast, and fully controlled.

## Current Setup

- **Machine:** M4 Pro MacBook (m4pro_sv)
- **Runner name:** `enviouswispr-release`
- **Labels:** `self-hosted`, `macOS`, `ARM64`, `apple-silicon`, `enviouswispr-release`
- **Install path:** `~/actions-runner/`
- **Service plist:** `~/Library/LaunchAgents/actions.runner.saurabhav88-EnviousWispr.enviouswispr-release.plist`
- **Logs:** `~/Library/Logs/actions.runner.saurabhav88-EnviousWispr.enviouswispr-release/`

## Workflow Split (historical — as of decommission)

| Workflow | Runner | Purpose |
|----------|--------|---------|
| `pr-check.yml` → `build-debug` / `build-release` | `macos-26` (hosted) | Xcode/Tuist build lanes — debug build + XPC hygiene + debug tests ‖ release build + FoundationModels compile probe |
| `pr-check.yml` → `build-check` | `ubuntu-latest` (hosted) | Required-gate aggregator over both build lanes (`needs: [build-debug, build-release]`) |
| `release.yml` → `build-release-artifacts` | `macos-26` (hosted, since #1113) | Full release: Xcode/Tuist archive + inside-out sign (embeds the Developer ID provisioning profile) + notarize + DMG. Formerly `self-hosted, enviouswispr-release`; that runner no longer exists. |

## Release Toolchain (Xcode engine, #913)

Release builds run on the Xcode build engine via Tuist (not SwiftPM). The runner needs:

- **mise** (installed via Homebrew at `/opt/homebrew/bin/mise`) — version manager.
- **Tuist `4.195.11`** — managed by mise (`mise x tuist@4.195.11 -- tuist ...`); the `release.yml` build job's "Ensure Tuist available" step runs `mise install tuist@4.195.11` (idempotent) before building, so a fresh runner self-provisions.
- **Xcode 26.5** + **create-dmg** (the workflow installs create-dmg via Homebrew per run).

The build/sign/DMG mechanics live in `scripts/build-release-dmg.sh` (the release workflow calls it), so a local release proof runs identical code to CI. GitHub Action `run:` steps are non-interactive, so the script resolves `mise` by absolute path (the interactive `mise` shell function is absent in CI shells).

## Managing the Runner (historical — commands assume a runner exists again; see Recovery below)

```bash
# Check status
cd ~/actions-runner && ./svc.sh status

# Stop
cd ~/actions-runner && ./svc.sh stop

# Start
cd ~/actions-runner && ./svc.sh start

# Uninstall service (keeps runner files)
cd ~/actions-runner && ./svc.sh uninstall

# View logs
tail -f ~/Library/Logs/actions.runner.saurabhav88-EnviousWispr.enviouswispr-release/*.log
```

## Recovery: Re-register Runner

If the runner token expires or the runner needs re-registration:

```bash
cd ~/actions-runner

# Get new token
TOKEN=$(gh api repos/saurabhav88/EnviousWispr/actions/runners/registration-token --method POST --jq '.token')

# Remove old config
./config.sh remove --token "$TOKEN"

# Re-register
./config.sh --url https://github.com/saurabhav88/EnviousWispr \
  --token "$TOKEN" \
  --name enviouswispr-release \
  --labels self-hosted,macOS,apple-silicon,enviouswispr-release \
  --unattended --replace

# Restart service
./svc.sh install && ./svc.sh start
```

## Updating the Runner

GitHub releases new runner versions regularly. To update:

```bash
cd ~/actions-runner && ./svc.sh stop
# Download latest from https://github.com/actions/runner/releases
curl -o actions-runner-osx-arm64-VERSION.tar.gz -L https://github.com/actions/runner/releases/download/vVERSION/actions-runner-osx-arm64-VERSION.tar.gz
tar xzf actions-runner-osx-arm64-VERSION.tar.gz
./svc.sh start
```

## Security Notes

- The runner executes code from PRs. Since this is a private repo with controlled access, this is acceptable.
- If the repo becomes public, restrict the runner to only run on `push` events (not `pull_request` from forks) to prevent arbitrary code execution.
- Runner credentials are stored in `~/actions-runner/.credentials` and `~/actions-runner/.runner`.
- The runner runs as the current user (`m4pro_sv`) with full access to the machine's toolchain and keychain.
