---
name: wispr-bundle-app
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

## Copy AppIcon.icns and menu bar icons

```bash
cp "$RESOURCES_SRC/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$RESOURCES_SRC"/menubar-*.png "$BUNDLE/Contents/Resources/"
```

## Embed Sparkle.framework

The binary links Sparkle dynamically — it must be embedded in the bundle and the rpath patched.

```bash
SPARKLE_FW=/Users/m4pro_sv/Desktop/EnviousWispr/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
mkdir -p "$BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$BUNDLE/Contents/MacOS/EnviousWispr"
```

## Create PkgInfo

```bash
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
```

## Dev-sign the bundle

Sign with the local self-signed "EnviousWispr Dev" certificate so Keychain ACLs persist across rebuilds (no Keychain prompts on every rebuild). Sign inside-out: Sparkle framework first, then the app.

```bash
codesign --force --sign "EnviousWispr Dev" --timestamp=none "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "EnviousWispr Dev" --timestamp=none "$BUNDLE"
```

- The `codesign -v` verification may warn about Sparkle's "ambiguous bundle format" — this is cosmetic. The main binary signature is valid.
- If `security find-identity -p codesigning` shows no "EnviousWispr Dev", the cert needs to be recreated (see `codesign-without-xcode` skill).

## Verify bundle structure

```bash
find "$BUNDLE" -type f
```

Expected output (must include Sparkle.framework and menu bar icons):
```
/tmp/EnviousWispr.app/Contents/Info.plist
/tmp/EnviousWispr.app/Contents/PkgInfo
/tmp/EnviousWispr.app/Contents/MacOS/EnviousWispr
/tmp/EnviousWispr.app/Contents/Resources/AppIcon.icns
/tmp/EnviousWispr.app/Contents/Resources/menubar-idle.png
/tmp/EnviousWispr.app/Contents/Resources/menubar-idle@2x.png
/tmp/EnviousWispr.app/Contents/Resources/menubar-recording.png
/tmp/EnviousWispr.app/Contents/Resources/menubar-recording@2x.png
/tmp/EnviousWispr.app/Contents/Resources/menubar-processing.png
/tmp/EnviousWispr.app/Contents/Resources/menubar-processing@2x.png
/tmp/EnviousWispr.app/Contents/Frameworks/Sparkle.framework/...
```

## Move to Applications (optional)

```bash
cp -r "$BUNDLE" /Applications/EnviousWispr.app
```

## Notes

- Model weights downloaded by FluidAudio/WhisperKit are stored in `~/Library/Application Support/` at runtime — no bundling needed.
- App data lives at `~/Library/Application Support/EnviousWispr/transcripts/`.
- Code-signing is a separate step (see `codesign-without-xcode` skill).
