# Self-Hosted GitHub Actions Runner

## Why

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

## Workflow Split

| Workflow | Runner | Purpose |
|----------|--------|---------|
| `pr-check.yml` → `build-check` | `macos-15` (hosted) | Fast compile gate — debug + release + test target |
| `pr-check.yml` → `ai-compile-gate` | `self-hosted, enviouswispr-release` | FoundationModels compile probe |
| `release.yml` → `build-release-artifacts` | `self-hosted, enviouswispr-release` | Full release: Xcode/Tuist archive + inside-out sign (embeds the Developer ID provisioning profile) + notarize + DMG |

## Release Toolchain (Xcode engine, #913)

Release builds run on the Xcode build engine via Tuist (not SwiftPM). The runner needs:

- **mise** (installed via Homebrew at `/opt/homebrew/bin/mise`) — version manager.
- **Tuist `4.195.11`** — managed by mise (`mise x tuist@4.195.11 -- tuist ...`); the `release.yml` build job's "Ensure Tuist available" step runs `mise install tuist@4.195.11` (idempotent) before building, so a fresh runner self-provisions.
- **Xcode 26.5** + **create-dmg** (the workflow installs create-dmg via Homebrew per run).

The build/sign/DMG mechanics live in `scripts/build-release-dmg.sh` (the release workflow calls it), so a local release proof runs identical code to CI. GitHub Action `run:` steps are non-interactive, so the script resolves `mise` by absolute path (the interactive `mise` shell function is absent in CI shells).

## Managing the Runner

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
