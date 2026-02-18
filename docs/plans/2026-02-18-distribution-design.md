# EnviousWispr Distribution Design

## Goal

Convert EnviousWispr from a development project into a distributable macOS product. Friends can download a DMG, drag to Applications, and run it — with automatic updates via Sparkle.

## Decisions

| Component | Decision |
|-----------|----------|
| Target | Universal binary (arm64 + x86_64), macOS 14+ |
| Build system | SwiftPM (`swift build`) |
| Signing | Developer ID Application certificate ($99/yr) |
| Notarization | `xcrun notarytool` via GitHub Actions |
| Packaging | DMG (compressed UDZO, drag-to-Applications) |
| Auto-updates | Sparkle 2 (EdDSA signed, daily check) |
| Hosting | GitHub Releases + appcast.xml |
| CI/CD | GitHub Actions, triggered on `v*` tag push |
| Icon | To be created |
| Name | EnviousWispr |

## Architecture

### Build Chain

```
git tag v1.0.0 → push → GitHub Actions (macOS-14 runner, Xcode 15+)
  → swift build -c release --arch arm64
  → swift build -c release --arch x86_64
  → lipo -create → universal binary
  → assemble .app bundle
  → codesign with Developer ID Application
  → notarize with xcrun notarytool
  → staple notarization ticket
  → create DMG (hdiutil)
  → generate Sparkle appcast entry (EdDSA signed)
  → upload DMG to GitHub Release
  → update appcast.xml
```

### App Bundle Structure

```
EnviousWispr.app/
  Contents/
    Info.plist
    MacOS/
      EnviousWispr          (universal binary)
    Resources/
      AppIcon.icns
    Frameworks/             (Sparkle.framework if needed)
    _CodeSignature/
```

## Code Signing & Notarization

### Prerequisites (user action)

1. Apple Developer Program membership ($99/year)
2. Developer ID Application certificate (generated in Apple Developer portal)
3. App-specific password (generated at appleid.apple.com)

### Entitlements File

`Sources/EnviousWispr/Resources/EnviousWispr.entitlements`:

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

### GitHub Secrets

| Secret | Contents |
|--------|----------|
| `DEVELOPER_ID_CERT_BASE64` | Base64-encoded .p12 certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the .p12 file |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for Sparkle update signing |

## Sparkle Auto-Updater

### Integration

- Add `sparkle-project/Sparkle` as SwiftPM dependency
- Initialize `SPUStandardUpdaterController` in app startup
- Add "Check for Updates" menu item to the app menu
- Configure appcast URL in Info.plist: `SUFeedURL` pointing to GitHub-hosted appcast.xml
- Embed EdDSA public key in Info.plist: `SUPublicEDKey`

### Update Flow

1. App checks `appcast.xml` on GitHub (daily by default)
2. New version found → native Sparkle update dialog
3. User clicks "Install Update" → downloads DMG → applies → relaunches

### Appcast Hosting

`appcast.xml` hosted on GitHub Pages or raw GitHub URL. CI generates new entries using `generate_appcast` or scripted XML on each release.

## GitHub Actions Workflow

### Trigger

Push a git tag matching `v*` (e.g., `v1.0.0`).

### Workflow: `.github/workflows/release.yml`

Steps:
1. Checkout code
2. Set up macOS-14 runner (Xcode 15+)
3. Import Developer ID certificate into temporary Keychain
4. Build arm64 release binary
5. Build x86_64 release binary
6. Create universal binary with `lipo`
7. Assemble .app bundle (binary, Info.plist with version injection, icon, frameworks)
8. Code sign the .app bundle with entitlements
9. Create DMG with hdiutil
10. Notarize DMG with `xcrun notarytool submit --wait`
11. Staple notarization ticket with `xcrun stapler staple`
12. Sign DMG appcast entry with Sparkle EdDSA key
13. Create GitHub Release with DMG attached
14. Update appcast.xml and commit/push

### Cost

GitHub free tier: 2,000 min/month for private repos on macOS (10x multiplier = ~200 actual minutes). Each release build ~10-15 min. Plenty of headroom.

## Local Release Script

`scripts/release-local.sh` mirrors the CI flow for local testing:
- Same build/sign/notarize/DMG steps
- Uses local Keychain certificates
- Useful for validating changes before tagging

## App Icon

Need to create `AppIcon.icns` with standard macOS sizes:
- 16x16, 32x32, 128x128, 256x256, 512x512, 1024x1024
- Plus @2x variants

Created with `iconutil --convert icns` from an `.iconset` directory.

## Intel Support Notes

WhisperKit and FluidAudio CoreML models run on CPU on Intel Macs (no Neural Engine). Transcription will be slower but functional. App system requirements should note "Apple Silicon recommended for best performance."
