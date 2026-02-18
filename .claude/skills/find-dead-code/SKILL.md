---
name: find-dead-code
description: Use when the user asks to find unused code, remove dead code, audit unreferenced types or functions, or reduce codebase size in EnviousWispr.
---

# Find Dead Code

## 1. List all type and protocol definitions

```bash
grep -rn "^struct \|^class \|^enum \|^protocol \|^actor " \
  /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ \
  --include="*.swift" | sort
```

## 2. For each type, check how many times it is referenced

```bash
TYPE="TranscriptionOptions"   # replace with type under inspection
grep -rn "$TYPE" /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ --include="*.swift" | wc -l
```

A count of 1 means the only occurrence is the definition itself — likely dead code.

## 3. List all function/method definitions

```bash
grep -rn "func " /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ --include="*.swift" \
  | grep -v "\/\/" | grep -Ev "override func|required func" | sort
```

## 4. Cross-reference a function name for usages

```bash
FUNC="resetBenchmark"
grep -rn "$FUNC" /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ --include="*.swift"
```

## 5. Find unused imports

```bash
grep -rln "^import " /Users/m4pro_sv/Desktop/EnviousWispr/Sources/ --include="*.swift" \
  | while read f; do
      imports=$(grep "^import " "$f" | awk '{print $2}')
      for imp in $imports; do
        count=$(grep -c "$imp" "$f")
        [ "$count" -le 1 ] && echo "Possibly unused import '$imp' in $f"
      done
    done
```

## Focus areas by directory

| Directory | What to check |
|---|---|
| `Models/` | Struct fields never read in Views or Pipeline |
| `ASR/` | Streaming protocol methods (`transcribeStream`) if only batch transcription is used |
| `LLM/` | Config types passed to polishers but never read |
| `Utilities/` | BenchmarkSuite entries for removed pipeline stages |
| `Services/` | HotkeyService helper methods superseded by NSEvent monitors |

## Common false positives — do NOT remove

- Types conforming to `ASRBackend` or `TranscriptPolisher` — loaded dynamically via protocol
- `@Observable` stored properties read implicitly by SwiftUI observation tracking
- `Codable` CodingKeys enums — used by the encoder/decoder, not by name in Swift source
- `Identifiable` `id` properties — required by SwiftUI ForEach even if not referenced directly
- Types referenced only in `Package.swift` targets or test files

## Report format

After the search, produce a summary:

```
UNUSED TYPES:      [list or "none found"]
UNUSED FUNCTIONS:  [list or "none found"]
UNUSED IMPORTS:    [list or "none found"]
FALSE POSITIVES EXCLUDED: [list protocol conformances and @Observable properties skipped]
```
