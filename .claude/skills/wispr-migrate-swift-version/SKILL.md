---
name: wispr-migrate-swift-version
description: Use when the user asks to upgrade the Swift tools version, migrate to a new Swift language version, address new deprecation warnings after a Swift update, or update Package.swift for a newer toolchain in EnviousWispr.
---

# Migrate Swift Version

## Check the current toolchain

```bash
swift --version
```

Note the Swift version. The project currently targets swift-tools-version 6.0.

## Update Package.swift swift-tools-version

Open `/Users/m4pro_sv/Desktop/EnviousWispr/Package.swift` and change line 1:

```swift
// swift-tools-version: 6.1   // or target version
```

Keep `swiftLanguageVersions: [.version("6")]` in each target unless migrating to Swift 7+.

## Run a full build and capture all warnings

```bash
swift build -C /Users/m4pro_sv/Desktop/EnviousWispr 2>&1 | tee /tmp/swift-build-output.txt
```

Scan the output for:
- `warning: X is deprecated` — note the replacement API
- `error: X is unavailable` — requires immediate fix
- Sendable / concurrency errors — often new in each Swift release

## Fix deprecation warnings

Common patterns between Swift 6.x minor versions:

| Deprecated | Replacement |
|---|---|
| `Task.detached` without isolation | Add `@Sendable` closure annotation |
| `MainActor.run` inside already-isolated code | Remove the wrapper |
| Old `withTaskGroup` signatures | Update to labeled form |
| `@preconcurrency` no longer needed | Remove if the upstream package is now Sendable-annotated |

## Check new concurrency requirements

```bash
grep -rn "nonisolated\|@MainActor\|actor " /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ 2>/dev/null | head -40
```

New Swift versions may require explicit `nonisolated(unsafe)` for globals, or enforce `sending` parameter annotations.

## Verify test target compiles

```bash
swift build --build-tests -C /Users/m4pro_sv/Desktop/EnviousWispr 2>&1
```

Note: XCTest is unavailable (CLI tools only); this only verifies compilation, not execution.

## Common migration issues

- **FluidAudio / WhisperKit `@preconcurrency`** — if the upstream package adds Sendable conformances, remove `@preconcurrency import` to avoid a warning.
- **`kAXTrustedCheckOptionPrompt` C global** — remains as string literal workaround: `"AXTrustedCheckOptionPrompt" as CFString`.
- **`AVFoundation` types** — keep `@preconcurrency import AVFoundation` until Apple fully annotates AVAudioEngine callbacks.
- **Strict concurrency** — if upgrading past Swift 6, check for `complete` strict concurrency mode requiring `sending` on all cross-actor parameters.

## Commit after successful migration

```bash
git -C /Users/m4pro_sv/Desktop/EnviousWispr add Package.swift
git -C /Users/m4pro_sv/Desktop/EnviousWispr commit -m "build: migrate to swift-tools-version X.Y"
```
