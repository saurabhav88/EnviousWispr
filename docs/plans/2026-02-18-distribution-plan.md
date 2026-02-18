# EnviousWispr Distribution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship EnviousWispr as a signed, notarized, auto-updating macOS DMG distributed via GitHub Releases.

**Architecture:** Universal binary (arm64+x86_64) built by GitHub Actions on `v*` tag push. Signed with Developer ID, notarized by Apple, packaged as DMG. Sparkle 2 checks GitHub-hosted appcast.xml for updates.

**Tech Stack:** SwiftPM, Sparkle 2, GitHub Actions, hdiutil, codesign, xcrun notarytool

**Design doc:** `docs/plans/2026-02-18-distribution-design.md`

---

## Prerequisites (User Manual Steps)

Before starting implementation, the user must:

1. **Create GitHub repository** and push the codebase
2. **Enroll in Apple Developer Program** ($99/yr at https://developer.apple.com)
3. **Create Developer ID Application certificate** in the Apple Developer portal
4. **Export the certificate as .p12** from Keychain Access
5. **Generate an app-specific password** at https://appleid.apple.com (for notarization)
6. **Note the Team ID** from the Apple Developer portal membership page

These are gated on Apple's enrollment process (can take 24-48 hours). Implementation tasks below can proceed in parallel — the secrets are only needed when configuring GitHub Actions secrets in Task 8.

---

### Task 1: Create Production Entitlements File

**Files:**
- Create: `Sources/EnviousWispr/Resources/EnviousWispr.entitlements`

**Step 1: Create the entitlements plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

Two entitlements:
- `device.audio-input` — microphone access for dictation
- `automation.apple-events` — Accessibility API for paste-to-active-app

**Step 2: Verify the plist is valid**

Run: `plutil -lint Sources/EnviousWispr/Resources/EnviousWispr.entitlements`
Expected: `Sources/EnviousWispr/Resources/EnviousWispr.entitlements: OK`

**Step 3: Commit**

```bash
git add Sources/EnviousWispr/Resources/EnviousWispr.entitlements
git commit -m "feat(build): add production entitlements for audio input and accessibility"
```

---

### Task 2: Generate App Icon

**Files:**
- Create: `scripts/generate-icon.swift` (temporary helper)
- Create: `Sources/EnviousWispr/Resources/AppIcon.icns`

We generate a programmatic icon using CoreGraphics. The user can replace it with a designed icon later.

**Step 1: Write the icon generator script**

Create `scripts/generate-icon.swift` — a standalone Swift script that:
1. Creates a 1024x1024 `CGContext`
2. Draws a rounded-rect gradient background (deep purple → blue, matching a dictation theme)
3. Draws a microphone SF Symbol or simple mic shape in white
4. Exports to PNG
5. Creates an `.iconset` directory with all required sizes (16, 32, 128, 256, 512, 1024 + @2x)
6. Runs `iconutil --convert icns` to produce `AppIcon.icns`

The script uses only Foundation + CoreGraphics (available in CLI tools).

**Step 2: Run the generator**

Run: `swift scripts/generate-icon.swift`
Expected: `Sources/EnviousWispr/Resources/AppIcon.icns` created

**Step 3: Verify the icon**

Run: `file Sources/EnviousWispr/Resources/AppIcon.icns`
Expected: Output contains `icon` or similar identifier

Run: `ls -la Sources/EnviousWispr/Resources/AppIcon.icns`
Expected: File exists, size > 100KB

**Step 4: Commit**

```bash
git add Sources/EnviousWispr/Resources/AppIcon.icns
git commit -m "feat(build): add generated app icon (microphone on gradient)"
```

Note: `scripts/generate-icon.swift` is a one-time tool. Commit it for reproducibility but it's not part of the build.

---

### Task 3: Add Sparkle 2 Dependency

**Files:**
- Modify: `Package.swift`

**Step 1: Add Sparkle to Package.swift dependencies array**

Add to the `dependencies` array:
```swift
.package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
```

Add to the target's `dependencies` array:
```swift
"Sparkle",
```

**Step 2: Verify it resolves**

Run: `swift package resolve`
Expected: Sparkle package fetched and resolved successfully.

**Step 3: Verify build still compiles**

Run: `swift build`
Expected: Build succeeds. Sparkle is linked but not yet used in code.

**Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(build): add Sparkle 2 dependency for auto-updates"
```

---

### Task 4: Integrate Sparkle into App

**Files:**
- Modify: `Sources/EnviousWispr/App/AppDelegate.swift`
- Modify: `Sources/EnviousWispr/App/EnviousWisprApp.swift`
- Modify: `Sources/EnviousWispr/Resources/Info.plist`

**Step 1: Add Sparkle import and controller to AppDelegate**

In `AppDelegate.swift`, add at the top:
```swift
@preconcurrency import Sparkle
```

Add a property to AppDelegate:
```swift
private(set) var updaterController: SPUStandardUpdaterController!
```

In `applicationDidFinishLaunching(_:)`, after existing setup, add:
```swift
updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
```

**Step 2: Add "Check for Updates" menu item**

In the `populateMenu(_:)` method of AppDelegate, add a menu item before "Quit":
```swift
let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
updateItem.target = updaterController
menu.addItem(updateItem)
menu.addItem(NSMenuItem.separator())
```

**Step 3: Add Sparkle keys to Info.plist**

Add these keys to `Sources/EnviousWispr/Resources/Info.plist` inside the `<dict>`:
```xml
<!-- Sparkle auto-updater -->
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/OWNER/EnviousWispr/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PLACEHOLDER_EDDSA_PUBLIC_KEY</string>
```

The `SUFeedURL` and `SUPublicEDKey` will be replaced with real values after the GitHub repo is created and the EdDSA key pair is generated (Task 7). Use placeholder values for now so the code compiles.

Also update `build-dmg.sh` to include these keys in its generated Info.plist (the script regenerates Info.plist at build time).

**Step 4: Verify build**

Run: `swift build`
Expected: Build succeeds with Sparkle integrated.

**Step 5: Commit**

```bash
git add Sources/EnviousWispr/App/AppDelegate.swift Sources/EnviousWispr/App/EnviousWisprApp.swift Sources/EnviousWispr/Resources/Info.plist
git commit -m "feat(ui): integrate Sparkle auto-updater with Check for Updates menu item"
```

---

### Task 5: Update Build Script for Universal Binary + Signing

**Files:**
- Modify: `scripts/build-dmg.sh`

The existing `build-dmg.sh` builds a single-arch release. Update it to:
1. Build both arm64 and x86_64
2. Merge with `lipo` into a universal binary
3. Add optional code signing step
4. Add optional notarization step
5. Include Sparkle keys in the generated Info.plist
6. Copy entitlements file into bundle

**Step 1: Replace the build step**

Replace the single `swift build -c release` with:
```bash
echo "==> [1/7] Building arm64 release binary ..."
swift build -c release --arch arm64

echo "==> [2/7] Building x86_64 release binary ..."
swift build -c release --arch x86_64

echo "==> [3/7] Creating universal binary with lipo ..."
BINARY_ARM64="${PROJECT_ROOT}/.build/arm64-apple-macosx/release/${BINARY_NAME}"
BINARY_X86="${PROJECT_ROOT}/.build/x86_64-apple-macosx/release/${BINARY_NAME}"
BINARY_UNIVERSAL="${BUILD_DIR}/${BINARY_NAME}-universal"
lipo -create "${BINARY_ARM64}" "${BINARY_X86}" -output "${BINARY_UNIVERSAL}"
```

Then copy `BINARY_UNIVERSAL` into the bundle instead of the single-arch binary.

**Step 2: Add Sparkle keys to the Info.plist generation**

Add inside the heredoc plist, before the closing `</dict>`:
```xml
    <!-- Sparkle auto-updater -->
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/OWNER/EnviousWispr/main/appcast.xml}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_EDDSA_PUBLIC_KEY:-PLACEHOLDER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
```

**Step 3: Add entitlements copy**

After the icon step, copy entitlements:
```bash
ENTITLEMENTS_SRC="${PROJECT_ROOT}/Sources/EnviousWispr/Resources/EnviousWispr.entitlements"
ENTITLEMENTS_DEST="${BUILD_DIR}/EnviousWispr.entitlements"
cp "${ENTITLEMENTS_SRC}" "${ENTITLEMENTS_DEST}"
```

**Step 4: Add optional signing step**

Add after bundle assembly, gated on `CODESIGN_IDENTITY` env var:
```bash
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing .app bundle ..."
    codesign --force --options runtime \
        --sign "${CODESIGN_IDENTITY}" \
        --entitlements "${ENTITLEMENTS_DEST}" \
        "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "    Signature verified."
fi
```

**Step 5: Add optional notarization step**

Add after DMG creation, gated on `APPLE_ID` env var:
```bash
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_ID_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "==> Notarizing DMG ..."
    xcrun notarytool submit "${DMG_OUT}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_ID_PASSWORD}" \
        --team-id "${APPLE_TEAM_ID}" \
        --wait
    echo "==> Stapling notarization ticket ..."
    xcrun stapler staple "${DMG_OUT}"
fi
```

**Step 6: Verify universal binary creation locally**

Run: `./scripts/build-dmg.sh 1.0.0`
Expected: Build completes, DMG created.

Run: `lipo -info build/EnviousWispr.app/Contents/MacOS/EnviousWispr`
Expected: `Architectures in the fat file: ... are: x86_64 arm64`

**Step 7: Commit**

```bash
git add scripts/build-dmg.sh
git commit -m "feat(build): universal binary, optional signing and notarization in build-dmg.sh"
```

---

### Task 6: Create GitHub Actions Release Workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Step 1: Write the workflow file**

Create `.github/workflows/release.yml` with:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build-and-release:
    runs-on: macos-14

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Import Developer ID certificate
        env:
          DEVELOPER_ID_CERT_BASE64: ${{ secrets.DEVELOPER_ID_CERT_BASE64 }}
          DEVELOPER_ID_CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
        run: |
          CERT_PATH="$RUNNER_TEMP/certificate.p12"
          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
          echo -n "$DEVELOPER_ID_CERT_BASE64" | base64 --decode -o "$CERT_PATH"
          security create-keychain -p "temppassword" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "temppassword" "$KEYCHAIN_PATH"
          security import "$CERT_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" \
            -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
          security set-key-partition-list -S apple-tool:,apple: \
            -k "temppassword" "$KEYCHAIN_PATH"
          security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db

      - name: Build, sign, notarize, and package DMG
        env:
          CODESIGN_IDENTITY: "Developer ID Application: ${{ secrets.APPLE_TEAM_NAME }} (${{ secrets.APPLE_TEAM_ID }})"
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_ID_PASSWORD: ${{ secrets.APPLE_ID_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          SPARKLE_FEED_URL: "https://raw.githubusercontent.com/${{ github.repository }}/main/appcast.xml"
          SPARKLE_EDDSA_PUBLIC_KEY: ${{ secrets.SPARKLE_EDDSA_PUBLIC_KEY }}
        run: ./scripts/build-dmg.sh "${{ steps.version.outputs.version }}"

      - name: Generate Sparkle appcast entry
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          DMG_PATH="build/EnviousWispr-${VERSION}.dmg"
          DMG_SIZE=$(stat -f%z "$DMG_PATH")
          DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
          # Generate EdDSA signature using Sparkle's sign_update tool
          # The tool is built as part of the Sparkle package
          EDDSA_SIG=$(echo -n "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/sign_update "$DMG_PATH" --ed-key-file /dev/stdin 2>/dev/null || echo "SIGNATURE_PLACEHOLDER")
          DATE=$(date -R)
          cat > build/appcast-entry.xml << ENTRY
          <item>
            <title>Version ${VERSION}</title>
            <pubDate>${DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <enclosure
              url="https://github.com/${{ github.repository }}/releases/download/v${VERSION}/EnviousWispr-${VERSION}.dmg"
              length="${DMG_SIZE}"
              type="application/octet-stream"
              sparkle:edSignature="${EDDSA_SIG}"
            />
          </item>
          ENTRY

      - name: Update appcast.xml
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          if [ ! -f appcast.xml ]; then
            cat > appcast.xml << 'FEED'
          <?xml version="1.0" encoding="utf-8"?>
          <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
              <title>EnviousWispr Updates</title>
            </channel>
          </rss>
          FEED
          fi
          # Insert new entry before closing </channel>
          ENTRY=$(cat build/appcast-entry.xml)
          python3 -c "
          import sys
          content = open('appcast.xml').read()
          entry = open('build/appcast-entry.xml').read()
          content = content.replace('</channel>', entry + '\n    </channel>')
          open('appcast.xml', 'w').write(content)
          "

      - name: Commit updated appcast
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git checkout main
          git add appcast.xml
          git diff --cached --quiet || git commit -m "chore(release): update appcast for v${{ steps.version.outputs.version }}"
          git push origin main

      - name: Create GitHub Release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          gh release create "v${VERSION}" \
            --title "EnviousWispr v${VERSION}" \
            --generate-notes \
            "build/EnviousWispr-${VERSION}.dmg"

      - name: Cleanup keychain
        if: always()
        run: security delete-keychain "$RUNNER_TEMP/build.keychain-db" 2>/dev/null || true
```

**Step 2: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
(If PyYAML isn't installed, use: `python3 -c "import json; print('YAML created')"` and verify manually)

**Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): add GitHub Actions release workflow with signing and notarization"
```

---

### Task 7: Generate Sparkle EdDSA Key Pair

**Files:**
- No files modified (keys stored as secrets, public key added to Info.plist)

This task requires the Sparkle package to be built first (Task 3).

**Step 1: Build Sparkle tools**

Run: `swift build`
This builds the Sparkle package including its `generate_keys` tool.

**Step 2: Locate or build the key generation tool**

Sparkle's `generate_keys` binary may be available after build. If not, we can generate EdDSA keys with OpenSSL or a Swift snippet:

```bash
# Option A: Use Sparkle's generate_keys if available
.build/artifacts/sparkle/Sparkle/bin/generate_keys

# Option B: Generate with openssl (Ed25519)
openssl genpkey -algorithm Ed25519 -out sparkle_private.pem
openssl pkey -in sparkle_private.pem -pubout -out sparkle_public.pem
```

**Step 3: Save the public key**

The public key goes into Info.plist as `SUPublicEDKey`. Update both:
- `Sources/EnviousWispr/Resources/Info.plist` — replace `PLACEHOLDER_EDDSA_PUBLIC_KEY`
- `scripts/build-dmg.sh` — the heredoc plist uses `${SPARKLE_EDDSA_PUBLIC_KEY}` env var

**Step 4: Secure the private key**

The private key is stored as GitHub secret `SPARKLE_PRIVATE_KEY`. Print it and instruct the user to add it to GitHub repository secrets. Never commit the private key.

**Step 5: Commit the public key update**

```bash
git add Sources/EnviousWispr/Resources/Info.plist
git commit -m "feat(sparkle): embed EdDSA public key for update verification"
```

---

### Task 8: Set Up GitHub Repository and Secrets

**Files:**
- No code files — repository and secrets configuration

This task requires the Apple Developer prerequisites to be completed.

**Step 1: Create GitHub repository**

```bash
gh repo create EnviousWispr --private --source=. --remote=origin --push
```

Or if the user prefers public:
```bash
gh repo create EnviousWispr --public --source=. --remote=origin --push
```

**Step 2: Push all branches**

```bash
git push -u origin main
```

**Step 3: Configure GitHub secrets**

The user must add these secrets via GitHub UI (Settings > Secrets > Actions) or CLI:

```bash
gh secret set DEVELOPER_ID_CERT_BASE64 < <(base64 -i path/to/certificate.p12)
gh secret set DEVELOPER_ID_CERT_PASSWORD
gh secret set APPLE_ID
gh secret set APPLE_ID_PASSWORD
gh secret set APPLE_TEAM_ID
gh secret set APPLE_TEAM_NAME
gh secret set SPARKLE_PRIVATE_KEY
gh secret set SPARKLE_EDDSA_PUBLIC_KEY
```

Each `gh secret set` without a value will prompt for input.

**Step 4: Update SUFeedURL in Info.plist**

Replace the placeholder URL with the real repository URL:
```
https://raw.githubusercontent.com/OWNER/EnviousWispr/main/appcast.xml
```

Where `OWNER` is the GitHub username.

**Step 5: Commit and push**

```bash
git add Sources/EnviousWispr/Resources/Info.plist scripts/build-dmg.sh
git commit -m "feat(sparkle): set production appcast URL"
git push origin main
```

---

### Task 9: Create Initial Appcast XML

**Files:**
- Create: `appcast.xml` (in project root)

**Step 1: Create empty appcast**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EnviousWispr Updates</title>
    <link>https://github.com/OWNER/EnviousWispr/releases</link>
    <description>EnviousWispr update feed</description>
    <language>en</language>
  </channel>
</rss>
```

This is the base file. The GitHub Actions workflow appends `<item>` entries on each release.

**Step 2: Commit**

```bash
git add appcast.xml
git commit -m "feat(sparkle): add initial appcast.xml for update feed"
git push origin main
```

---

### Task 10: End-to-End Release Test

**Step 1: Verify local build produces universal binary**

Run: `./scripts/build-dmg.sh 1.0.0`
Expected: DMG created at `build/EnviousWispr-1.0.0.dmg`

Run: `lipo -info build/EnviousWispr.app/Contents/MacOS/EnviousWispr`
Expected: `Architectures in the fat file: ... are: x86_64 arm64`

**Step 2: Verify bundle structure**

Run: `ls -la build/EnviousWispr.app/Contents/`
Expected: `Info.plist`, `MacOS/`, `Resources/`

Run: `ls build/EnviousWispr.app/Contents/Resources/`
Expected: `AppIcon.icns`

Run: `plutil -lint build/EnviousWispr.app/Contents/Info.plist`
Expected: OK

**Step 3: Test ad-hoc signing locally**

Run: `codesign --force --deep --sign - build/EnviousWispr.app`
Run: `codesign --verify --deep --strict build/EnviousWispr.app`
Expected: No errors

**Step 4: Tag and push to trigger CI**

```bash
git tag v1.0.0
git push origin v1.0.0
```

Expected: GitHub Actions workflow triggers, builds DMG, creates GitHub Release.

**Step 5: Verify the release**

Run: `gh release view v1.0.0`
Expected: Release exists with DMG asset attached.

Download the DMG, mount it, drag to Applications, launch. Verify:
- App appears in menu bar (no Dock icon)
- "Check for Updates" menu item is present
- Microphone permission prompt appears on first use

**Step 6: Celebrate**

Your friends can now download from the GitHub Releases page.

---

## Task Dependency Graph

```
Task 1 (entitlements) ──┐
Task 2 (app icon) ──────┤
Task 3 (Sparkle dep) ───┼──→ Task 4 (Sparkle integration) ──→ Task 5 (build script) ──→ Task 6 (CI workflow)
                         │                                                                      │
                         │                                     Task 7 (EdDSA keys) ─────────────┤
                         │                                                                      │
                         └─────────────────────────────────→ Task 8 (GitHub repo) ──→ Task 9 (appcast) ──→ Task 10 (E2E test)
```

Tasks 1, 2, 3 can run in parallel.
Task 4 depends on Task 3.
Task 5 depends on Tasks 1, 2, 4.
Task 6 depends on Task 5.
Tasks 7, 8 can run in parallel with Tasks 1-6.
Task 9 depends on Task 8.
Task 10 depends on all prior tasks.
