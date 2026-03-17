# Feature: Homebrew Cask Distribution

**ID:** 018
**Category:** Platform & Distribution
**Priority:** Medium
**Inspired by:** Handy — `brew install --cask handy`
**Status:** Ready for Implementation

## Problem

Users must manually download the DMG from GitHub Releases and drag-install. Homebrew is the de facto package manager for macOS developers — many prefer `brew install` over manual downloads.

## Proposed Solution

Create a Homebrew cask formula and submit it to homebrew-cask:

```ruby
cask "enviouswispr" do
  version "1.0.0"
  sha256 "..."
  url "https://github.com/saurabhav88/EnviousWispr/releases/download/v#{version}/EnviousWispr-#{version}.dmg"
  name "EnviousWispr"
  desc "Local-first macOS dictation app"
  homepage "https://github.com/saurabhav88/EnviousWispr"
  app "EnviousWispr.app"
end
```

Automate cask updates in the CI release workflow.

## Files to Modify

- `.github/workflows/release.yml` — add a final job `update-homebrew-tap` that runs after `build-and-release`, computes the DMG SHA256, and pushes an updated `Casks/enviouswispr.rb` to the tap repo via SSH deploy key

## New Files

These files live in a separate GitHub repository `saurabhav88/homebrew-tap`, not in the main EnviousWispr repo:

- `Casks/enviouswispr.rb` — the cask formula (maintained in tap repo)
- `README.md` — tap installation instructions (maintained in tap repo)

In the main EnviousWispr repo:

- `scripts/update-cask.sh` — helper script to compute SHA256 and render the cask formula; called by CI

## Implementation Plan

### Phase 1: Self-Hosted Tap (implement now)

A self-hosted tap at `saurabhav88/homebrew-tap` allows immediate distribution without the homebrew-cask review requirements (which mandate a notarized, signed binary and an established user base). Users install via:

```bash
brew tap saurabhav88/tap
brew install --cask enviouswispr
```

#### Step 1: Create the tap repository

Create a new public GitHub repository named `homebrew-tap` under `saurabhav88`. The repository must follow Homebrew's naming convention exactly — `homebrew-tap` maps to the `saurabhav88/tap` tap identifier.

Directory structure:
```
homebrew-tap/
  Casks/
    enviouswispr.rb
  README.md
```

#### Step 2: Write the initial cask formula

```ruby
# Casks/enviouswispr.rb
cask "enviouswispr" do
  version "1.0.0"
  sha256 "PLACEHOLDER_SHA256"

  url "https://github.com/saurabhav88/EnviousWispr/releases/download/v#{version}/EnviousWispr-#{version}.dmg"

  name "EnviousWispr"
  desc "Local-first macOS dictation app powered by Apple Silicon"
  homepage "https://github.com/saurabhav88/EnviousWispr"

  # Requires Apple Silicon — EnviousWispr uses CoreML Neural Engine
  depends_on arch: :arm64

  app "EnviousWispr.app"

  zap trash: [
    "~/Library/Application Support/EnviousWispr",
    "~/Library/Logs/EnviousWispr",
    "~/Library/Preferences/com.enviouswispr.app.plist",
    "~/Library/Saved Application State/com.enviouswispr.app.savedState",
  ]
end
```

Notes on the formula:
- `depends_on arch: :arm64` correctly blocks installation on Intel Macs where the app will not run (FluidAudio requires Apple Silicon).
- `zap trash:` lists all directories that EnviousWispr creates during its lifetime. The `zap` stanza runs when the user does `brew uninstall --zap --cask enviouswispr`, removing all app data. Paths are derived from `AppConstants.appSupportURL` (Application Support), the log directory used by `AppLogger` (feature 019), and the standard macOS preference/saved-state paths.
- The Keychain entry (`com.enviouswispr.app` service) cannot be deleted via `zap` (Homebrew has no Keychain stanza) — document this in the tap README.

#### Step 3: Create the update-cask.sh helper script

```bash
#!/usr/bin/env bash
# scripts/update-cask.sh — Render an updated cask formula with the real SHA256
# Called by CI after the DMG is built and uploaded to GitHub Releases.
#
# Required env vars:
#   VERSION        — e.g. "1.0.1"
#   DMG_PATH       — local path to the signed DMG file
#   CASK_REPO_DIR  — path to a checkout of saurabhav88/homebrew-tap
set -euo pipefail

VERSION="${VERSION:?VERSION must be set}"
DMG_PATH="${DMG_PATH:?DMG_PATH must be set}"
CASK_REPO_DIR="${CASK_REPO_DIR:?CASK_REPO_DIR must be set}"

# Compute SHA256 of the DMG
SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
echo "==> SHA256: ${SHA256}"

CASK_FILE="${CASK_REPO_DIR}/Casks/enviouswispr.rb"

# Replace version and sha256 in the formula
sed -i '' "s|version \".*\"|version \"${VERSION}\"|" "${CASK_FILE}"
sed -i '' "s|sha256 \".*\"|sha256 \"${SHA256}\"|" "${CASK_FILE}"

echo "==> Updated ${CASK_FILE}"
echo "    version: ${VERSION}"
echo "    sha256:  ${SHA256}"
```

#### Step 4: Add a deploy key for CI to push to the tap repo

1. Generate an SSH keypair: `ssh-keygen -t ed25519 -f tap_deploy_key -N ""`
2. Add `tap_deploy_key.pub` as a Deploy Key in the `saurabhav88/homebrew-tap` repo settings (with write access).
3. Add `tap_deploy_key` (private key contents) as a GitHub Actions secret named `TAP_DEPLOY_KEY` in the main `EnviousWispr` repo.

#### Step 5: Extend release.yml with a tap-update job

Add a new job after `build-and-release` in `.github/workflows/release.yml`:

```yaml
  update-homebrew-tap:
    runs-on: macos-14
    needs: build-and-release
    steps:
      - name: Checkout EnviousWispr (for the update script)
        uses: actions/checkout@v4

      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Download the release DMG
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          gh release download "v${VERSION}" \
            --pattern "EnviousWispr-${VERSION}.dmg" \
            --dir /tmp

      - name: Set up SSH deploy key for tap repo
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.TAP_DEPLOY_KEY }}" > ~/.ssh/tap_deploy_key
          chmod 600 ~/.ssh/tap_deploy_key
          ssh-keyscan github.com >> ~/.ssh/known_hosts
          cat >> ~/.ssh/config <<'EOF'
          Host github-tap
            HostName github.com
            User git
            IdentityFile ~/.ssh/tap_deploy_key
          EOF

      - name: Clone the tap repository
        run: |
          git clone git@github-tap:saurabhav88/homebrew-tap.git /tmp/homebrew-tap

      - name: Update cask formula
        env:
          VERSION: ${{ steps.version.outputs.version }}
          DMG_PATH: /tmp/EnviousWispr-${{ steps.version.outputs.version }}.dmg
          CASK_REPO_DIR: /tmp/homebrew-tap
        run: ./scripts/update-cask.sh

      - name: Commit and push updated cask
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          cd /tmp/homebrew-tap
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Casks/enviouswispr.rb
          git diff --cached --quiet || git commit \
            -m "chore: update enviouswispr to v${VERSION}"
          git push
```

### Phase 2: Submit to homebrew-cask (after notarization)

Once the Apple Developer certificate is active and the app is notarized, submit to the official `homebrew/homebrew-cask` repository. Requirements:

1. The binary must be codesigned with a Developer ID certificate.
2. The binary must be notarized by Apple.
3. The download URL must be stable and versioned (already satisfied by GitHub Releases).
4. The cask must pass `brew audit --cask --online enviouswispr`.
5. The repository must have at least one stable release with a real version number.

Submission process:

```bash
# Fork homebrew/homebrew-cask on GitHub
# Clone the fork locally
git clone https://github.com/YOUR_FORK/homebrew-cask.git
cd homebrew-cask

# Copy the formula from the tap, filling in real SHA256
cp Casks/e/enviouswispr.rb <path-to-your-cask>

# Audit the formula
brew audit --cask --online Casks/e/enviouswispr.rb

# Test installation from local formula
brew install --cask Casks/e/enviouswispr.rb

# Open a PR against homebrew/homebrew-cask main branch
```

The homebrew-cask PR template requires:
- Why the cask should be in homebrew-cask (not a self-hosted tap)
- Verification that the app is notarized
- Confirmation that the URL pattern is stable

After merge, users can install without adding a tap:

```bash
brew install --cask enviouswispr
```

### AppConstants paths for the zap stanza

The `zap` stanza must list every directory the app touches. From `TranscriptStore.swift`:

```swift
// TranscriptStore uses:
AppConstants.appSupportURL  // ~/Library/Application Support/EnviousWispr/
    .appendingPathComponent(AppConstants.transcriptsDir)  // transcripts/
```

From feature 019 (AppLogger), logs go to:

```swift
// ~/Library/Logs/EnviousWispr/
FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/EnviousWispr")
```

Standard macOS paths always created for any app with bundle ID `com.enviouswispr.app`:

- `~/Library/Preferences/com.enviouswispr.app.plist`
- `~/Library/Saved Application State/com.enviouswispr.app.savedState`
- `~/Library/Caches/com.enviouswispr.app` (if any caching is added)

The WAV recording history (feature 020) stores files alongside JSON transcripts in Application Support — covered by the Application Support path.

## Testing Strategy

1. **Local tap install test:** On a development machine, run `brew tap saurabhav88/tap && brew install --cask enviouswispr`. Verify the app installs to `/Applications/EnviousWispr.app` and launches correctly.

2. **SHA256 verification:** After CI runs `update-cask.sh`, manually verify the SHA256 in the committed cask matches `shasum -a 256 EnviousWispr-VERSION.dmg`.

3. **brew audit:** Run `brew audit --cask --online Casks/enviouswispr.rb` against the tap formula. All checks must pass (no warnings about URL pattern, architecture, etc.).

4. **Uninstall + zap test:** Run `brew uninstall --zap --cask enviouswispr` and verify all listed paths in the `zap` stanza are removed. Verify the Keychain entry (not handled by zap) persists — document this in the README.

5. **arch guard test:** Attempt `brew install --cask enviouswispr` on an Intel Mac (or simulate via `arch -x86_64`). Homebrew must reject the install with a clear architecture error due to `depends_on arch: :arm64`.

6. **CI integration test:** Tag a test release (e.g., `v0.9.99`) and observe that the `update-homebrew-tap` job runs, updates the formula, and pushes to the tap repo correctly.

7. **Version bump idempotency:** Run `update-cask.sh` twice with the same version. The second run must produce an identical commit (or a no-op diff), not corrupt the formula.

## Risks & Considerations

- Requires a stable first release (v1.0.0) before submitting — self-hosted tap allows iteration before then
- homebrew-cask has review requirements (signed binary, stable URL pattern) — mitigated by Phase 1 self-hosted tap approach
- CI must update the cask SHA256 on each release — handled by `update-homebrew-tap` job
- The deploy key grants write access to the tap repo — rotate annually and store only in GitHub Actions secrets, never in the repo
- If the DMG upload to GitHub Releases fails, the tap-update job must not run — the `needs: build-and-release` dependency ensures this
- Formula must be updated for every release — if CI tap-update job fails, the cask becomes stale; add a GitHub Actions alert or issue-creation step on failure
- homebrew-cask submission may be rejected if the app is not yet well-known — self-hosted tap has no such restriction
