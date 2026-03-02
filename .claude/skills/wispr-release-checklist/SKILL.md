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

Update `CFBundleShortVersionString` in `Sources/EnviousWispr/Resources/Info.plist` — use bare semver **without** the `v` prefix (e.g., `1.0.0`, not `v1.0.0`). The `v` prefix is only for git tags.

```bash
# Confirm current version in Info.plist
grep -A1 "CFBundleShortVersionString" Sources/EnviousWispr/Resources/Info.plist
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
xcrun notarytool submit build/EnviousWispr.app.zip \
  --key "$API_KEY_PATH" \
  --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER_ID" \
  --wait
xcrun stapler staple build/EnviousWispr.app
```

Uses App Store Connect API key authentication (not the legacy `--apple-id`/`--password` method).

### 7. Build DMG

```bash
scripts/build-dmg.sh <version>
```

### 8. Sign DMG for Sparkle

Use the `sign_update` tool from the SPM artifact cache with the EdDSA private key. Substitute the actual version number:

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update \
  build/EnviousWispr-<version>.dmg \
  -s "$(cat /tmp/sparkle_eddsa_private_key.txt)"
```

Expected output contains two fields — verify both are present before proceeding:

```
sparkle:edSignature="<base64-signature>"
length="<byte-count>"
```

Copy these values into `appcast.xml` for the corresponding `<enclosure>` element. If `sign_update` exits non-zero or the output is missing either field, do not publish — re-check that the private key file is intact and matches the public key in `Info.plist` (`SUPublicEDKey`).

### 9. Merge release PR to main

All changes must go through a PR before tagging. Create a PR targeting `main`, ensure CI `build-check` passes, then merge:

```bash
# Create release branch and PR (if not already open)
git checkout -b release/v<version>
git push -u origin release/v<version>
gh pr create --title "chore(release): prepare v<version>" --body "Version bump and changelog for v<version>" --base main

# After CI passes:
gh pr merge --squash
```

### 10. Tag and push

Git tags use the `v` prefix; Info.plist does not. Tag **after** the release PR is merged to `main`:

```bash
git checkout main && git pull origin main
git tag v<version>          # e.g., v1.0.0 — triggers CI release workflow
git push origin v<version>
```

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which handles everything from step 3 onward automatically (build → sign → notarize → DMG → Sparkle sign → appcast.xml → GitHub Release). Steps 3–8 above are documented for local/manual use only.

### 11. CI appcast.xml generation (automated)

When the tag push triggers CI, the release workflow in `.github/workflows/release.yml` runs these steps in order:

1. **Build, sign, notarize, DMG** — `./scripts/build-dmg.sh <version>` with `CODESIGN_IDENTITY` and API key auth (`API_KEY_PATH`, `API_KEY_ID`, `API_ISSUER_ID`) secrets
2. **Generate Sparkle signature** — reads `SPARKLE_PRIVATE_KEY` secret, pipes it to `.build/artifacts/sparkle/Sparkle/bin/sign_update <dmg>` via `--ed-key-file /dev/stdin`, captures `sparkle:edSignature` and file `length`
3. **Build appcast entry** — writes `build/appcast-entry.xml` with `<item>` block containing `<title>`, `<pubDate>`, `<sparkle:version>`, `<sparkle:shortVersionString>`, and `<enclosure url=... length=... sparkle:edSignature=.../>`
   - Download URL: `https://github.com/saurabhav88/EnviousWispr/releases/download/v<version>/EnviousWispr-<version>.dmg`
4. **Update appcast.xml** — Python one-liner inserts the new `<item>` entry before `</channel>` in `appcast.xml`; creates the file from scratch if it does not exist
5. **Push appcast update to main** — CI pushes `appcast.xml` directly to `main` using `APPCAST_BOT_TOKEN` PAT (no PR needed)
6. **Create GitHub Release** — `gh release create v<version>` with `--generate-notes` and the signed DMG as attachment

After CI completes and the appcast is pushed, `appcast.xml` is live on `main` and Sparkle clients will pick up the new release on their next check cycle.

### 11a. Manual appcast.xml fallback (if CI fails)

Use this only when the CI workflow cannot complete (missing secrets, runner failure, etc.).

**Step 1 — Sign the DMG**

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update \
  build/EnviousWispr-<version>.dmg \
  -s "$(cat /tmp/sparkle_eddsa_private_key.txt)"
```

Expected output (both fields must be present):

```
sparkle:edSignature="<base64-signature>"
length="<byte-count>"
```

If either field is missing or `sign_update` exits non-zero, stop — verify that the private key matches the public key in `Info.plist` (`SUPublicEDKey`).

**Step 2 — Edit appcast.xml**

Insert a new `<item>` block before the closing `</channel>` tag. Replace `<version>`, `<DATE>`, `<SIGNATURE>`, and `<LENGTH>` with actual values:

```xml
    <item>
      <title>Version <version></title>
      <pubDate><DATE></pubDate>
      <sparkle:version><version></sparkle:version>
      <sparkle:shortVersionString><version></sparkle:shortVersionString>
      <enclosure
        url="https://github.com/saurabhav88/EnviousWispr/releases/download/v<version>/EnviousWispr-<version>.dmg"
        length="<LENGTH>"
        type="application/octet-stream"
        sparkle:edSignature="<SIGNATURE>"
      />
    </item>
```

**Step 3 — Commit and push to main**

Push the appcast update directly to main (APPCAST_BOT_TOKEN PAT, enforce admins is off):

```bash
git add appcast.xml
git commit -m "chore(release): update appcast for v<version>"
git pull --rebase origin main
git push origin main
```

**Step 4 — Create GitHub Release manually**

```bash
gh release create "v<version>" \
  --title "EnviousWispr v<version>" \
  --generate-notes \
  "build/EnviousWispr-<version>.dmg"
```

### 12. Verify GitHub release

```bash
gh release view v<version>
```
- Confirm DMG is attached
- Confirm appcast.xml on `main` has the new `<item>` entry with a non-empty `sparkle:edSignature`
- Confirm `SUFeedURL` in `Info.plist` resolves to the updated feed

## Rollback

If the release has issues, delete in this order — GitHub release first, then the tag.

```bash
# 1. Delete the GitHub release (detaches the DMG asset and release page)
gh release delete v<version> --yes

# 2. Delete local tag
git tag -d v<version>

# 3. Delete remote tag (stops any in-flight CI triggered by the tag)
git push origin :refs/tags/v<version>
```

If Sparkle has already served the appcast to users and they have the bad version downloaded, also revert `appcast.xml` to the previous release entry and force-push (or update via CI). Sparkle clients that have not yet applied the update will then see the previous version as the latest.

## Post-Release

- Monitor Sparkle update adoption
- Check crash reports / analytics
- Update `docs/feature-requests/TRACKER.md` with shipped features
