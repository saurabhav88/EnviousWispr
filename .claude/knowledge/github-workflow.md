# GitHub Workflow & Branch Protection

## Branch Protection on `main`

Lean setup for a 2-person human/AI team — no ceremony, maximum velocity:

| Rule | Setting |
|------|---------|
| Status checks | `build-check` runs on PRs for **visibility only** — not required for merge |
| Force pushes | Blocked |
| Branch deletion | Blocked |
| Required reviews | **None** — lean team |

**Direct pushes to `main` are the norm** for the AI agent and admin. PRs are optional for CI visibility.

**Appcast updates** push directly to `main` using the built-in `GITHUB_TOKEN`. No PATs needed.

## PR Check Workflow (`.github/workflows/pr-check.yml`)

Triggers on every pull request targeting `main`. Informational only — not required for merge.

### Job: `build-check`

- **Runner:** `macos-15` (Swift 6.0+ required)
- **Timeout:** 30 minutes
- **Concurrency:** grouped by PR number, cancels in-progress runs on new push

### Steps

1. **Checkout** — `actions/checkout@v4`
2. **Verify Swift version** — fails if not Swift 6+
3. **Cache SPM dependencies** — keyed on `Package.resolved` hash
4. **Build (debug)** — `swift build`
5. **Build (release)** — `swift build -c release --arch arm64`
6. **Verify test target compiles** — `swift build --build-tests`

## PR Template (`.github/PULL_REQUEST_TEMPLATE.md`)

Every PR auto-populates with a pre-merge checklist:

- **Build Verification**: debug, release, test-compile, CI green
- **Behavioral Testing**: rebuild + relaunch, Smart UAT, manual smoke test
- **Code Quality**: conventional commits, no secrets, no removed `@preconcurrency`
- **Release Housekeeping**: version bump and changelog (if targeting a release)

## Code Ownership (`.github/CODEOWNERS`)

| Pattern | Owner |
|---------|-------|
| `*` (default) | `@saurabhav88` |
| `.github/workflows/` | `@saurabhav88` |
| `scripts/` | `@saurabhav88` |
| `Sources/.../Info.plist` | `@saurabhav88` |

CODEOWNERS auto-requests review from the matching owner when a PR touches their files. As contributors join, add ownership lines for their domains (e.g., `Sources/.../Pipeline/Audio/ @audio-contributor`).

## Dependabot (`.github/dependabot.yml`)

- **Ecosystem:** Swift (SPM)
- **Schedule:** Weekly checks
- **Max open PRs:** 5
- **Labels:** `dependencies`

Dependabot opens PRs when dependency updates are available. These PRs go through the same `build-check` status check.

## Security Features

| Feature | Status |
|---------|--------|
| Dependabot alerts | Enabled |
| Secret scanning | Enabled |
| Push protection | Enabled — blocks commits containing detected secrets |

## Workflow for Code Changes

```
1. Create feature branch: git checkout -b feat/my-feature
2. Implement + commit (conventional commits)
3. Push branch: git push -u origin feat/my-feature
4. Open PR: gh pr create --base main
5. Optionally check build-check status (informational)
6. Squash-merge: gh pr merge --squash
```

## Workflow for Releases

```
1. All code changes merged to main via PRs (as above)
2. Tag the release: git tag v1.0.X
3. Push the tag: git push origin v1.0.X
4. release.yml triggers: build → sign → notarize → DMG → GitHub Release
5. Appcast update pushed directly to main by CI (via built-in GITHUB_TOKEN)
```

## CI Secrets for Release Workflow

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

## Key Constraints

- **Direct pushes and PRs both work** — PRs give CI visibility, direct pushes for speed
- **Appcast updates** pushed directly by CI after successful release (via `GITHUB_TOKEN`)
- **No force pushes** — blocked by branch protection
- **Release workflow is the true quality gate** — full build + sign + notarize
