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

## Copy Info.plist

Copy the committed Info.plist, which includes CFBundleIconFile, Sparkle keys, and all other required entries.

```bash
RESOURCES_SRC=/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Resources
cp "$RESOURCES_SRC/Info.plist" "$BUNDLE/Contents/Info.plist"
```

## Copy AppIcon.icns

```bash
cp "$RESOURCES_SRC/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
```

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
/tmp/EnviousWispr.app/Contents/Resources/AppIcon.icns
```

## Move to Applications (optional)

```bash
cp -r "$BUNDLE" /Applications/EnviousWispr.app
```

## Notes

- Model weights downloaded by FluidAudio/WhisperKit are stored in `~/Library/Application Support/` at runtime — no bundling needed.
- App data lives at `~/Library/Application Support/EnviousWispr/transcripts/`.
- Code-signing is a separate step (see `codesign-without-xcode` skill).
