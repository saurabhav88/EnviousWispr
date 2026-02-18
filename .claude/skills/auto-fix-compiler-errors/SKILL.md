---
name: auto-fix-compiler-errors
description: Use when `swift build` produces compiler errors that need to be parsed, categorized, and resolved. Covers Swift 6 concurrency violations, type mismatches, missing imports, and actor isolation errors specific to this project.
---

# Auto-Fix Compiler Errors

## Step 1 — Capture Raw Output

```bash
swift build 2>&1 | tee /tmp/build-errors.txt
```

Read the output in full before making any changes. Count error vs warning lines.

## Step 2 — Categorize Each Error

Group errors into buckets before touching any code:

| Bucket | Signature in output |
|---|---|
| Non-Sendable crossing boundary | `non-sendable type … crossing actor boundary` |
| Capture in @Sendable closure | `capture of … with non-sendable type` |
| C global unavailable | `… is unavailable: … C global` |
| Actor-isolated access | `expression is 'async' but is not marked with 'await'` |
| Missing / wrong import | `cannot find type … in scope`, `no such module` |
| Type mismatch | `cannot convert value of type` |

## Step 3 — Apply Fixes by Category

### Non-Sendable crossing boundary
- Preferred: add `@preconcurrency import` for the offending module.
- If the type is our own: add `Sendable` conformance or mark `@unchecked Sendable` with a comment.

### Capture in @Sendable closure
Extract Sendable values before the closure:
```swift
// Before
Task { use(nsEvent.keyCode) }
// After
let keyCode = nsEvent.keyCode   // UInt16 is Sendable
Task { use(keyCode) }
```

### C global unavailable (e.g. kAXTrustedCheckOptionPrompt)
Replace C global with string literal cast:
```swift
// Before
kAXTrustedCheckOptionPrompt as CFString
// After
"AXTrustedCheckOptionPrompt" as CFString
```

### Actor-isolated access
Add `await` at the call site, or wrap in `Task { @MainActor in … }`.

### Missing import for FluidAudio / WhisperKit / AVFoundation
```swift
@preconcurrency import FluidAudio
@preconcurrency import WhisperKit
@preconcurrency import AVFoundation
```

### FluidAudio module name collision
Never qualify FluidAudio types with the module prefix (`FluidAudio.AsrManager`).
Use bare names: `AsrManager`, `AsrModels`, `VadManager`. Let type inference resolve.

## Step 4 — Rebuild and Confirm

```bash
swift build 2>&1
```

Repeat Steps 1-4 until output contains `Build complete!` with zero errors.
If warning count increased, note them but do not treat as blocking.
