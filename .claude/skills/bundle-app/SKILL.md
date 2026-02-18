---
name: bundle-app
description: Use when the user asks to package the app, create a .app bundle, prepare for distribution, or assemble the macOS application bundle structure for EnviousWispr without Xcode.
---

# Bundle App (.app) Without Xcode

## Prerequisites

Complete a release build first (`swift build -c release`).

## Create the bundle directory structure

```bash
APP=EnviousWispr.app
BUNDLE=/tmp/$APP
BINARY=/Users/m4pro_sv/Desktop/EnviousWispr/.build/release/EnviousWispr

mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
```

## Copy the release binary

```bash
cp "$BINARY" "$BUNDLE/Contents/MacOS/EnviousWispr"
chmod +x "$BUNDLE/Contents/MacOS/EnviousWispr"
```

## Create Info.plist

```bash
cat > "$BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>      <string>com.enviouswispr.app</string>
  <key>CFBundleName</key>            <string>EnviousWispr</string>
  <key>CFBundleExecutable</key>      <string>EnviousWispr</string>
  <key>CFBundleShortVersionString</key> <string>1.0.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSMicrophoneUsageDescription</key>
    <string>EnviousWispr needs microphone access for speech transcription.</string>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
</dict>
</plist>
EOF
```

`LSUIElement = true` makes the app menu-bar-only (no Dock icon), matching the current UI architecture.

## Create PkgInfo

```bash
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
```

## Verify bundle structure

```bash
find "$BUNDLE" -type f
```

Expected output:
```
/tmp/EnviousWispr.app/Contents/Info.plist
/tmp/EnviousWispr.app/Contents/PkgInfo
/tmp/EnviousWispr.app/Contents/MacOS/EnviousWispr
```

## Move to Applications (optional)

```bash
cp -r "$BUNDLE" /Applications/EnviousWispr.app
```

## Notes

- Model weights downloaded by FluidAudio/WhisperKit are stored in `~/Library/Application Support/` at runtime — no bundling needed.
- App data lives at `~/Library/Application Support/EnviousWispr/transcripts/`.
- Code-signing is a separate step (see `codesign-without-xcode` skill).
