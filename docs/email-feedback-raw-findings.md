# Raw Email Findings — 2026-03-01/02

## Source: chatgpt-codex-connector[bot] (OpenAI Codex PR Reviews)

### Finding 1: [P0] PR #10 — Self-copy aborts release step
- **PR**: fix(release): push appcast directly to main instead of via PR
- **Commit**: 2728467ca8
- **Issue**: After `git checkout main`, `cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml` resolves to same file. `cp` exits non-zero (`same file`), step stops under `bash -e`. Release workflow fails before committing/pushing appcast or creating GitHub release.
- **File**: `.github/workflows/release.yml`
- **Impact**: Release pipeline broken on every run

### Finding 2: [P1] PR #13 — Missing read scopes in CodeQL permissions
- **PR**: chore: audit cleanup + add CodeQL security scanning
- **Commit**: 085aca7fa3
- **Issue**: Workflow sets `permissions: security-events: write` only, implicitly sets all other scopes to `none`. `actions/checkout` and CodeQL need `contents: read` and `actions: read`. Fails in private repos and Dependabot PRs.
- **File**: `.github/workflows/codeql.yml` (or wherever CodeQL workflow lives)
- **Impact**: CodeQL workflow fails consistently

### Finding 3: [P1] PR #11 — Sparkle feed URL not aligned in release builds
- **PR**: fix: switch Sparkle feed URL to GitHub Pages
- **Commit**: ca5cada9a1
- **Issue**: Info.plist changed to `https://saurabhav88.github.io/EnviousWispr/appcast.xml` but `release.yml` still exports `SPARKLE_FEED_URL` as `https://raw.githubusercontent.com/...`, and `scripts/build-dmg.sh` rewrites SUFeedURL from that env var. Release builds still use old raw URL.
- **File**: `.github/workflows/release.yml` (line 67), `scripts/build-dmg.sh` (lines 104-105)
- **Impact**: Production users still polling old cached URL

### Finding 4: [P1] PR #4 — Dynamic app name breaks window-title matching
- **PR**: fix: CG-rendered idle icon + dynamic app name
- **Commit**: 6a550ef6ed
- **Issue**: `AppConstants.appName` now reads `CFBundleName` (resolves to `"EnviousWispr"` in release), but SwiftUI window title hardcoded as `"EnviousWispr Local"`. `AppDelegate` matches `window.title == AppConstants.appName` — never captures `mainWindow` in release. Closing settings doesn't restore `.accessory` mode.
- **File**: `Sources/EnviousWispr/App/AppConstants.swift`, `Sources/EnviousWispr/App/EnviousWisprApp.swift`
- **Impact**: App stuck in Dock in production builds

### Finding 5: [P1] PR #3 — Same issue as Finding 4
- **PR**: fix: CG-rendered idle icon + dynamic app name from Info.plist
- **Commit**: 6a550ef6ed
- **Issue**: Identical to Finding 4 — `CFBundleName` vs window title mismatch in release builds breaks `mainWindow` detection.
- **Duplicate of**: Finding 4

### Finding 6: [P2] PR #7 — Onboarding close doesn't restore accessory mode
- **PR**: feat: first-run onboarding (#022)
- **Commit**: 8c13106586
- **Issue**: When user closes setup window via red close button, close observer calls `updateIcon()` but never restores `NSApp` to `.accessory`. `openOnboardingWindow()` switched to `.regular`, so app stays in Dock after dismissal.
- **File**: Onboarding window management code
- **Impact**: Menu-bar app visible in Dock after aborting onboarding

### Finding 7: [P2] PR #12 — TCC docs reference non-existent .dev bundle ID
- **PR**: docs: add TCC reset procedure for dev+prod coexistence
- **Commit**: 22a52cbd38
- **Issue**: Reset procedure uses `com.enviouswispr.app.dev` but codebase only defines `com.enviouswispr.app`. The `tccutil reset` command won't clear dev build permissions, leaving broken Accessibility state.
- **File**: `.claude/knowledge/gotchas.md` (or wherever TCC docs live)
- **Impact**: Misleading documentation, broken dev workflow instructions

### Finding 8: [P2] PR #12 — Incorrect UserDefaults isolation claim
- **PR**: docs: add TCC reset procedure for dev+prod coexistence
- **Commit**: 22a52cbd38
- **Issue**: Claims dev/prod UserDefaults "don't interfere" because of separate bundle IDs, but `.dev` bundle ID doesn't exist. Engineers may assume data isolation they don't have.
- **Duplicate/related**: Finding 7

### Finding 9: [P2] PR #5 — Non-retryable appcast branch names
- **PR**: fix: repair malformed Sparkle appcast EdDSA signatures
- **Commit**: 73d9d81210
- **Issue**: Fixed branch name `ci/appcast-v${VERSION}` causes `git push` to fail as non-fast-forward on re-runs. Makes release pipeline non-retryable if a run fails after push but before merge.
- **File**: `.github/workflows/release.yml`
- **Impact**: Release pipeline not idempotent

## Source: dependabot[bot]

### Finding 10: Sparkle 2.8.1 → 2.9.0 update available
- **PR**: #2 — chore(deps): bump sparkle from 2.8.1 to 2.9.0
- **Key changes in 2.9.0**:
  - Markdown support for release notes (macOS 12+)
  - Signed/verified appcast feeds
  - `sparkle:hardwareRequirements` for arm64 enforcement
  - `sparkle:minimumUpdateVersion` for staged upgrades
  - Swift concurrency API annotations
  - In-memory temp file downloads
  - Impatient update check interval for auto-updates
- **Note**: Dependabot couldn't add `dependencies` label (doesn't exist in repo)
- **Impact**: Using outdated Sparkle; new version has Swift concurrency fixes relevant to our Swift 6 mode

## Source: GitHub Actions CI

### CI Failures (noise — not actionable code fixes)
- v1.0.0 Release: 5 failures/cancellations (3df6ffd, b7a0d1f, 12ef124, 3c55c34, 8c60447, ab3a190)
- v1.0.1 Release: 1 failure (eb058fd)
- v1.0.2 Release: 2 failures (50795ce x2)
- PR Check cancelled: feature/022-onboarding (26b025f)
- Pages build cancelled: main (47b4cd1, cdf0916)
- CodeQL failed: chore/audit-cleanup-and-codeql (7806894)
- PR Check + CodeQL cancelled: chore/audit-cleanup-and-codeql (085aca7)

## Source: GitHub (Account notifications)
- Fine-grained PAT "EnviousWispr Appcast Bot" added — expected, part of release infra
- 2x sudo verification codes — expected, from PAT creation

## Source: Google (Security)
- New sign-in on Mac alert — expected, saurabhav@gmail.com
