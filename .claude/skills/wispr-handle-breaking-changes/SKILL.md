---
name: wispr-handle-breaking-changes
description: Use when a dependency update (WhisperKit or FluidAudio) causes the build to break due to renamed, removed, or restructured APIs. Covers discovering what changed, mapping old to new call sites, and verifying recovery.
---

# Handle Breaking Changes After Dependency Update

## Step 1 — Capture the Full Error List

```bash
swift build 2>&1 | tee /tmp/breaking-errors.txt
grep "error:" /tmp/breaking-errors.txt | sort -u
```

Do not start editing until you have the complete list. Partial fixes waste build cycles.

## Step 2 — Identify the Source of Each Break

For each `cannot find type/method` error, determine whether it is:
- A **renamed type or method** (old name no longer exists)
- A **removed API** (feature dropped from the package)
- A **signature change** (same name, different parameters or return type)
- A **module restructure** (type moved to a sub-module)

## Step 3 — Consult the Changelog

```bash
curl -s https://api.github.com/repos/<owner>/<repo>/releases \
  | grep -A 10 '"tag_name"'
```

Read release notes between the old pinned version and the new version.
Map every breaking note to a call site in the EnviousWispr source tree.

## Step 4 — Locate All Call Sites

```bash
grep -rn "OldTypeName\|oldMethodName" \
  /Users/m4pro_sv/Desktop/EnviousWispr/Sources/
```

List files and line numbers before making any edits.

## Step 5 — Apply Renames / Signature Updates

Edit each call site using the old→new mapping from the changelog.
Keep changes minimal — do not refactor unrelated code in the same pass.

### FluidAudio-Specific Rules

FluidAudio exports a struct also named `FluidAudio`, which shadows the module name.

- NEVER write `FluidAudio.AsrManager`, `FluidAudio.VadManager`, etc.
- ALWAYS use bare unqualified names: `AsrManager`, `VadManager`, `AsrModels`, `VadConfig`.
- If a new FluidAudio release renames a type, update the bare name only.
- If a new type conflicts with a EnviousWispr type (e.g. `ASRResult`), resolve via
  explicit EnviousWispr type aliases or protocol return-type inference — not module prefix.

### WhisperKit-Specific Rules

- Use `@preconcurrency import WhisperKit` to suppress Sendable warnings.
- `WhisperKit` initialiser and `transcribe()` are async; always call with `await`.

## Step 6 — Handle Removed APIs

If an API was removed with no replacement:
1. Check whether EnviousWispr has its own implementation to fall back to.
2. If not, implement the missing behaviour locally in the appropriate layer
   (`ASR/`, `Audio/`, etc.) and remove the dependency on the removed symbol.

## Step 7 — Verify Recovery

Run the full build validation skill after all edits:

```bash
swift build 2>&1
swift build --build-tests 2>&1
```

Target: `Build complete!` with zero errors in both commands.
