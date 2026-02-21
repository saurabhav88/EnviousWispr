---
name: wispr-release-checklist
description: End-to-end release workflow — version bump, changelog, build, sign, notarize, Sparkle appcast, GitHub release, DMG upload. Use before any tagged release.
---

# Release Checklist

Complete release workflow from version bump to published release.

## Prerequisites

- Apple Developer certificate configured (codesigning)
- GitHub secrets set (see `.claude/knowledge/distribution.md`)
- Sparkle EdDSA key available

## Steps

### 1. Version bump

Update version in `Sources/EnviousWispr/App/AppDelegate.swift` or `Info.plist` if applicable.

```bash
# Confirm current version
grep -r "CFBundleShortVersionString\|marketingVersion" Sources/ build/ 2>/dev/null | head -5
```

### 2. Generate changelog

Invoke `/wispr-generate-changelog` or manually:

```bash
git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo "HEAD~20")..HEAD
```

### 3. Build release binary

```bash
swift build -c release 2>&1
```
- PASS: exits 0, no errors
- FAIL: invoke `/wispr-auto-fix-compiler-errors` then retry

### 4. Bundle the app

Invoke `/wispr-bundle-app` — creates `build/EnviousWispr.app` from release binary with Sparkle.framework embedded and rpath set.

### 5. Codesign

Invoke `/wispr-codesign-without-xcode` — signs binary + bundle with Developer ID.

### 6. Notarize

```bash
xcrun notarytool submit build/EnviousWispr.app.zip --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PASSWORD" --wait
xcrun stapler staple build/EnviousWispr.app
```

### 7. Build DMG

```bash
scripts/build-dmg.sh <version>
```

### 8. Sign DMG for Sparkle

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update build/EnviousWispr-<version>.dmg
```

### 9. Tag and push

```bash
git tag v<version>
git push origin v<version>
```
- This triggers `.github/workflows/release.yml`

### 10. Verify GitHub release

```bash
gh release view v<version>
```
- Confirm DMG is attached
- Confirm appcast.xml is updated

## Rollback

If the release has issues:
```bash
gh release delete v<version> --yes
git tag -d v<version>
git push origin :refs/tags/v<version>
```

## Post-Release

- Monitor Sparkle update adoption
- Check crash reports / analytics
- Update `docs/feature-requests/TRACKER.md` with shipped features
