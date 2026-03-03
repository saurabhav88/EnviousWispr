# Distribution & Release Pipeline

## Two-Tier Build Model

### Local Builds
- **Produced by:** `swift build`, `/wispr-rebuild-and-relaunch`, or `./scripts/build-dmg.sh` (no version arg)
- **Version string:** Tagged with `-local` suffix (e.g., `0.0.0-local`)
- **Purpose:** Development and testing only
- **Bundle location:** `.build/debug/EnviousWispr.app` or `build/EnviousWispr.app`

### Commercial/Release Builds
- **Produced by:** CI on `git tag v*` push, or explicitly via `./scripts/build-dmg.sh 1.0.0`
- **Version string:** Clean semver (e.g., `1.0.0`)
- **Purpose:** Distribution via GitHub Releases; downloaded by friends/users
- **Bundle location:** Created by DMG build script; signed and notarized in CI

Use the version string (`CFBundleShortVersionString` in Info.plist) to identify build tier at runtime.

## Release Flow

`git tag v1.0.0` → GitHub Actions → build → sign → notarize (`--wait`) → staple → DMG → appcast push to main → GitHub Release

**v1.0.0 released 2026-03-02.** Full pipeline completes in ~3.5 min.

### Branch Protection (Minimal)

`main` is protected with a lean, 2-person-team setup:

- **No required status checks** — `build-check` runs on PRs for visibility but doesn't gate merges
- **No force pushes** — blocked
- **No branch deletion** — blocked
- **No required reviews** — lean team, self-approval is ceremony

The release workflow pushes appcast.xml directly to `main` using the built-in `GITHUB_TOKEN`. No PATs needed.

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/release.yml` | CI: triggered on `v*` tags, runs on `macos-15` |
| `.github/workflows/pr-check.yml` | CI: triggered on PRs to `main`, informational `build-check` (not required) |
| `scripts/build-dmg.sh` | Builds arm64 release, assembles .app, creates DMG |
| `Sources/EnviousWispr/Resources/Info.plist` | Source of truth for bundle metadata |
| `Sources/EnviousWispr/Resources/EnviousWispr.entitlements` | Entitlements for codesigning |
| `appcast.xml` | Sparkle update feed (tracked in git, committed by CI on release) |

## Sparkle Auto-Update

- Dependency: `sparkle-project/Sparkle` 2.6+
- `@preconcurrency import Sparkle` in AppDelegate
- `SPUStandardUpdaterController` initialized on launch (`startingUpdater: true`)
- "Check for Updates..." menu item wired to `updaterController.checkForUpdates(_:)`
- EdDSA signing (not DSA) — public key in Info.plist (`SUPublicEDKey`)
- Feed URL in Info.plist (`SUFeedURL`): `https://saurabhav88.github.io/EnviousWispr/appcast.xml` (GitHub Pages — more reliable caching than raw.githubusercontent.com)

## DMG Build (`scripts/build-dmg.sh`)

- `swift build -c release --arch arm64` (arm64-only: FluidAudio uses Float16)
- Assembles .app bundle manually (no Xcode)
- Copies Sparkle.framework into bundle, adds @rpath
- Optional codesigning via `CODESIGN_IDENTITY` env var
- Notarization via App Store Connect API key (`--key`, `--key-id`, `--issuer`) — NOT Apple ID auth
- Usage: `./scripts/build-dmg.sh 1.0.0`

## CI Secrets Required

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_CERT_BASE64` | Code signing certificate (p12, base64) |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate password |
| `APPLE_API_KEY_BASE64` | App Store Connect API key (.p8, base64) |
| `APPLE_API_KEY_ID` | API key ID |
| `APPLE_API_ISSUER_ID` | API issuer UUID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_TEAM_NAME` | Team name (for codesign identity string) |
| `SPARKLE_EDDSA_PUBLIC_KEY` | Sparkle EdDSA public key |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (for signing DMG) |

Appcast push uses the built-in `GITHUB_TOKEN` (no PAT needed). `APPLE_ID` and `APPLE_ID_PASSWORD` secrets are legacy (old `altool` auth) — unused but retained.

**Important:** See gotchas.md "CI / GitHub Actions Release Gotchas" for critical lessons learned during v1.0.0 release.

## GitHub

- Repo: `saurabhav88/EnviousWispr` (public)
- `gh` CLI at `~/bin/gh`, authenticated as `saurabhav88`
- Sparkle sign_update tool: `.build/artifacts/sparkle/Sparkle/bin/sign_update`
