---
name: build-release-config
description: Use when the user asks to create a release build, build for distribution, build with optimizations, or verify the production binary for VibeWhisper.
---

# Build Release Configuration

## Run the release build

```bash
swift build -c release 2>&1
```

Swift PM applies `-O` (whole-module optimization) and `-Onone` is absent. No extra flags are needed; the compiler defaults are correct for Apple Silicon.

## Verify the binary exists and check size

```bash
ls -lh /Users/m4pro_sv/Desktop/EnviousWispr/.build/release/VibeWhisper
```

Expected: single Mach-O universal or arm64 binary, typically 5–25 MB before stripping.

## Strip debug symbols (optional, reduces size)

```bash
strip -rSTx /Users/m4pro_sv/Desktop/EnviousWispr/.build/release/VibeWhisper
```

## Verify the binary runs

```bash
/Users/m4pro_sv/Desktop/EnviousWispr/.build/release/VibeWhisper --help 2>&1 || true
file /Users/m4pro_sv/Desktop/EnviousWispr/.build/release/VibeWhisper
```

Confirm output shows `Mach-O 64-bit executable arm64`.

## Differences from debug build

| Aspect | Debug | Release |
|---|---|---|
| Optimization | `-Onone` | `-O` (WMO) |
| Assertions | Active | Disabled |
| Binary size | Larger | Smaller |
| Build time | Fast | Slower (~2–3x) |
| dSYM | Inline | Separate (`.dSYM`) |

## Check for dSYM (crash symbolication)

```bash
ls /Users/m4pro_sv/Desktop/EnviousWispr/.build/release/VibeWhisper.dSYM 2>/dev/null && echo "dSYM present"
```

Keep the `.dSYM` alongside any distributed binary for symbolication of crash reports.

## Common issues

- **Build fails with concurrency errors only in release** — WMO surfaces additional Swift 6 isolation issues not seen in debug. Fix actor isolation on the affected type.
- **Binary not found** — confirm `swift build -c release` completed without error; check `.build/release/` not `.build/debug/`.
