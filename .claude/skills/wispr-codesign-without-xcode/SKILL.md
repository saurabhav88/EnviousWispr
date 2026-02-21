---
name: wispr-codesign-without-xcode
description: Use when the user asks to code-sign the app, sign the binary, verify the signature, or prepare the bundle for Gatekeeper — without Xcode or xcodebuild available.
---

# Code-Sign Without Xcode

## Find a valid signing identity

```bash
security find-identity -v -p codesigning
```

Look for a line like:
```
1) ABCDEF1234... "Apple Development: you@example.com (TEAMID)"
2) ABCDEF5678... "Developer ID Application: Your Name (TEAMID)"
```

Use "Developer ID Application" for distribution outside the App Store. Use "Apple Development" for local testing only.

If no identity is listed, you have no Developer certificate installed. Signing is limited to ad-hoc (`-`).

## Ad-hoc sign (no Apple account required)

```bash
codesign --force --deep --sign - /tmp/EnviousWispr.app
```

Ad-hoc signing satisfies local Gatekeeper (with SIP disabled or when quarantine is cleared) but will not pass Gatekeeper on other machines.

## Sign with a real identity

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)"
codesign --force --deep --options runtime \
  --sign "$IDENTITY" \
  /tmp/EnviousWispr.app
```

`--options runtime` enables the Hardened Runtime, required for notarization.

## Required entitlements

Create `entitlements.plist` before signing if the app uses microphone or accessibility:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
```

Then sign with entitlements:

```bash
codesign --force --deep --options runtime \
  --entitlements entitlements.plist \
  --sign "$IDENTITY" \
  /tmp/EnviousWispr.app
```

## Verify the signature

```bash
codesign --verify --deep --strict --verbose=2 /tmp/EnviousWispr.app
spctl --assess --type exec --verbose /tmp/EnviousWispr.app
```

`codesign` should return exit 0 with "valid on disk". `spctl` should show "accepted".

## Notarization note

Notarization (`xcrun notarytool`) requires the full Xcode Developer Tools package, not just Command Line Tools. It is not available in this environment. For notarization, use a CI machine with full Xcode installed.
