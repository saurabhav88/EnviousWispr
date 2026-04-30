# Phase E — Architecture regression tests (#502)

Parent epic: #319 (Hardening & Refactors). Bible §11. Depends on: Phase F (#501) — SHIPPED in PR #503; ceiling inputs measured against post-F state.

## Preface — Lane + Live UAT declaration (PR #498 — MANDATORY)

- **Declared lane:** Code (mixed_pr: true — also touches CI/workflow + Docs/dev-tooling)
- **Phase 3 obligations (per lane):**
  - Code: tests + codex-review + skip-note for live-uat (pure-test PR, no user-visible surface)
  - CI/workflow: workflow-run on pr-check.yml syntax
  - Docs/dev-tooling: shellcheck on `scripts/check-dependency-direction.sh` + codex-prose on plan + arch-rules edits
- **Live UAT:** N — no user-visible surface; tests are the validation. `skip-note.txt` will state: "Phase E ships only architecture regression tests + a CI script. No code path that runs at runtime in the shipped app changed. Tests passing IS the validation."

## Preface — User Rubric

User Rubric: N/A — Hardening & Refactors is internal-only (Bible §0.7). No user-facing surface.

## 0. TL;DR

Three new architecture-regression tests in `Tests/EnviousWisprTests/Architecture/` lock the post-Phase-F state of AppState so it does not silently re-accrete: a concrete-property-count ceiling (≤ 19), a line-count ceiling (≤ 1050 = post-F 954 + 10%), and a cross-module public-TODO grep guard that fails when a non-App module declares `public` with a confessional `TODO` comment containing one of "narrow", "temporary", "Phase N", or "cross-module" within ±3 lines. Re-introduces `scripts/check-dependency-direction.sh` (deleted with the brain system) and wires it into `.github/workflows/pr-check.yml` as a new `lint` job (none exists today) to enforce dep-direction at PR time. Narrows `WhisperKitBackend.makeDecodeOptions` from `public` → `package` (the existing TODO offender — fixable now that Swift 6 `package` access lets Pipeline call into ASR without app-public exposure). Documents the ceilings + cross-module grep pattern + dep-direction rules in `.claude/rules/architecture-rules.md`. Tier: SMALL. Est. LOC delta: ~250 (test code + bash + workflow YAML + 1-line ASR access change + docs).

**Revised 2026-04-30 post-grounded-review:** Codex (`docs/audits/2026-04-30-phase-e-grounded-review.txt`) returned PROCEED-WITH-REVISIONS with four fixable issues: (1) cross-module-TODO regex was too broad — 5 false positives in current code (DictationActivityProviding, SilenceDetector, AudioCaptureManager, TelemetryService, ProgressCallback) plus 1 real offender (`WhisperKitBackend.makeDecodeOptions:156-157`); tightened to require `TODO` AND a structural keyword. (2) Dep-graph in §3.3 mismatched `Package.swift`; rebuilt against actual deps including the two XPC service executables. (3) `pr-check.yml` has no `lint` job today; create one deliberately. (4) Phase F's plan predicted post-F count of 17 but live is 19 because Phase F used a looser metric; Bible changelog notes the metric tightening. Real WhisperKitBackend offender is fixed in scope by narrowing `public func` → `package func` (1-line access change; no behavior change).

## 1. Problem

Phases A/B/C/D/F shaved AppState from a god-object trajectory toward a small set of cohesive collaborators. Without enforcement, the next session that adds "just one more service to AppState for convenience" recreates the trajectory. Bible §11 names this the fitness-function gap. The brain-system-era `scripts/check-dependency-direction.sh` was deleted when that system retired; the current `.git/hooks/pre-commit` is a no-op stub. SPM's implicit cyclic-import compile failure catches the worst case, but does not catch slow drift like "Audio module starts importing UI types via a typealias chain." Phase E re-introduces the lost enforcement and adds three architectural fitness tests calibrated to post-F state.

## 2. Goals & non-goals

### 2.1 Goals

- Three regression tests in `Tests/EnviousWisprTests/Architecture/AppStateCeilingsTests.swift` and `Tests/EnviousWisprTests/Architecture/CrossModulePublicGuardTests.swift`.
- Ceilings calibrated to post-Phase-F measurement (taken from worktree at HEAD of `feat/issue-502-phase-e-arch-tests`):
  - AppState concrete-collaborator count ≤ 19 (counts top-level `let` declarations of types that are not stdlib/Foundation primitives, including existentials like `any AudioCaptureInterface`).
  - AppState file line count ≤ 1050 (954 measured + 10% rounded down to a clean number).
- Cross-module `public` TODO guard: any line in `Sources/EnviousWispr*/` (excluding `Sources/EnviousWispr/`, the App target, AND excluding the two XPC service executables `EnviousWisprAudioService` + `EnviousWisprASRService`) that declares `public` AND has a comment within ±3 lines containing both `TODO` AND one of [`narrow`, `temporary`, `cross-module`, or `phase\s*[a-z\d]+`] fails the test. The "TODO + structural-keyword" conjunction avoids the 5 false positives Codex grounded review identified (function names like `phaseString`, comment words like `narrow_margin` or "single-phase" used in their literal sense).
- Narrow the existing real offender at `Sources/EnviousWisprASR/WhisperKitBackend.swift:155-157` from `public func makeDecodeOptions` → `package func makeDecodeOptions` and remove the confessional `TODO: Phase 2 — narrow ...` comment. Pipeline is in the same SPM package so `package` access is sufficient. This is a 1-line access modifier change + 2 lines of comment cleanup; no behavior change.
- `scripts/check-dependency-direction.sh` re-introduced. Greps `import` statements per module, validates against an authoritative dep-graph encoded inline in the script, fails on backward edges (Pipeline importing App, Audio importing Pipeline, etc.). Wired into `.github/workflows/pr-check.yml` as a new step in the existing `lint` job.
- Ceilings + cross-module rule + dep-direction graph documented in `.claude/rules/architecture-rules.md` under a new "Architectural Ceilings (enforced by tests)" section so future sessions discover the rule before tripping the test.
- Audit meta-rec #1 (CI guard on cross-module public exposure) marked RESOLVED in Bible §11 changelog.

### 2.2 Non-goals

- No mutation of AppState or any Sources/. Phase E adds tests + a script + workflow + docs.
- No reflection-based property counting. Stored-property detection runs against `AppState.swift` source text. Reasoning: AppState init has heavy side effects (audio capture, ASR manager, pipelines). Constructing a real instance in a test is fragile and pulls the heart path into a test that should only need the source file.
- No coverage of `var` stored properties. Plain `var` and `lazy var` slots are mostly UI-affordance state (`isRecordingLocked`, `pendingNavigationSection`, `pendingPassiveChip`) or ObservationIgnored handler holders; they do not represent architectural collaborators in the Phase F sense. Future tightening can extend the test if needed.
- No moving the dep-direction script's source-of-truth graph to a YAML/JSON file. Inline in bash for first cut. Phase E ships enforcement; future work can refactor the encoding.
- No replacement for the no-op `.git/hooks/pre-commit` stub. CI is the enforcement layer; pre-commit hook stub stays as historical no-op for now.

## 3. Design

### 3.1 AppStateCeilingsTests.swift

Two `@Test` cases. Both read `Sources/EnviousWispr/App/AppState.swift` from disk (path resolved relative to package root, since SwiftPM tests run with cwd = package root).

```swift
import Foundation
import Testing

@Suite struct AppStateCeilingsTests {

  /// Concrete collaborator count ceiling. Locked at post-Phase-F baseline = 19.
  /// Counts top-level `let` declarations on AppState whose type is non-primitive
  /// (excludes Bool, Int, String, Optional<closure>, Task<...>, and other plain
  /// values). Existentials (`any X`) count as collaborators.
  ///
  /// Increasing this ceiling is allowed but requires a Bible changelog entry
  /// justifying the new collaborator. Run `swift test` to verify post-bump.
  @Test func appStateConcreteCollaboratorCeilingHolds() throws {
    let body = try classBodyOfAppState()
    let count = countTopLevelLetCollaborators(in: body)
    #expect(count <= 19, "AppState concrete-collaborator ceiling exceeded: \(count) > 19. See .claude/rules/architecture-rules.md `Architectural Ceilings`.")
  }

  /// Line-count ceiling. Locked at post-Phase-F (954 lines) + 10% rounded
  /// to 1050. Soft backstop against scope creep.
  @Test func appStateLineCountCeilingHolds() throws {
    let url = appStateURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(lineCount <= 1050, "AppState line count exceeded: \(lineCount) > 1050. See .claude/rules/architecture-rules.md `Architectural Ceilings`.")
  }
}

private func appStateURL() -> URL {
  URL(fileURLWithPath: "Sources/EnviousWispr/App/AppState.swift")
}

private func classBodyOfAppState() throws -> String {
  let source = try String(contentsOf: appStateURL(), encoding: .utf8)
  guard let openRange = source.range(of: "final class AppState {") else {
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  throw POSIXError(.EILSEQ)
}

private func countTopLevelLetCollaborators(in body: String) -> Int {
  // Top-level = brace-depth 0 within class body. Match `let <ident>(:|\s*=)`
  // (concrete or existential let). Skip primitives.
  var depth = 0
  var collaborators = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let isLet = trimmed.hasPrefix("let ") || trimmed.hasPrefix("private let ")
        || trimmed.hasPrefix("internal let ")
      if isLet && !isPrimitiveTyped(trimmed) {
        collaborators += 1
      }
    }
    depth += opens - closes
  }
  return collaborators
}

private func isPrimitiveTyped(_ line: String) -> Bool {
  let primitives = [": Bool", ": Int", ": String", ": Double", ": Float",
                    "Task<", ": ((", "= false", "= true"]
  return primitives.contains { line.contains($0) }
}
```

The line/brace-depth approximation is intentional: AppState's class body uses standard formatting (one declaration per line, no inline closures at top scope after Phase A). If a future declaration spans multiple lines or includes a top-level closure literal, the test will need refinement; this is documented in the rules file.

### 3.2 CrossModulePublicGuardTests.swift

```swift
import Foundation
import Testing

@Suite struct CrossModulePublicGuardTests {

  /// Audit meta-rec #1: confessional `public` exposure across module boundaries
  /// is a known architecture smell. This test fails if a `public` declaration
  /// in any non-App module has a confessional-TODO comment within ±3 lines.
  ///
  /// Patterns flagged in the surrounding window: "narrow", "temporary",
  /// "phase <X>", "cross-module", "TODO". Adjust the regex if a legitimate use
  /// of one of these words triggers a false positive — but justify in the
  /// Bible §11 changelog.
  @Test func noConfessionalCrossModulePublicExists() throws {
    let sourcesRoot = URL(fileURLWithPath: "Sources")
    var offenders: [String] = []

    // Exclude the executable targets: app shell + XPC services. These are not
    // libraries that other modules consume, so cross-module-public is not a
    // meaningful concept for them.
    let executableTargets: Set<String> = [
      "EnviousWispr",
      "EnviousWisprAudioService",
      "EnviousWisprASRService",
    ]
    let modules = try FileManager.default.contentsOfDirectory(
      at: sourcesRoot, includingPropertiesForKeys: nil
    ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .filter { !executableTargets.contains($0.lastPathComponent) }

    for module in modules {
      let files = try filesRecursively(at: module).filter { $0.pathExtension == "swift" }
      for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
          .map(String.init)
        for (idx, line) in lines.enumerated() {
          if line.contains("public ") {
            let lo = max(0, idx - 3)
            let hi = min(lines.count - 1, idx + 3)
            let window = lines[lo...hi].joined(separator: " ").lowercased()
            // Tightened pattern post-Codex grounded review: require TODO AND a
            // structural-cross-module keyword. Avoids false positives like
            // `phaseString`, `narrow_margin`, "single-phase" in non-architectural
            // contexts.
            let hasTodo = window.contains("todo")
            let hasStructural = window.contains("narrow")
              || window.contains("temporary")
              || window.contains("cross-module") || window.contains("cross module")
              || window.range(of: #"phase\s*[a-z\d]+"#, options: .regularExpression) != nil
            if hasTodo && hasStructural {
              offenders.append("\(file.path):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
          }
        }
      }
    }

    #expect(offenders.isEmpty, "Confessional cross-module public found:\n\(offenders.joined(separator: "\n"))")
  }
}

private func filesRecursively(at dir: URL) throws -> [URL] {
  guard let enumerator = FileManager.default.enumerator(
    at: dir, includingPropertiesForKeys: [.isRegularFileKey]
  ) else { return [] }
  return enumerator.compactMap { $0 as? URL }
    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}
```

### 3.3 scripts/check-dependency-direction.sh

```bash
#!/usr/bin/env bash
# Validates SPM target dependency direction by grepping `import` statements per module.
# Fails on backward edges. Run from package root.
#
# Authoritative dep graph (post-Phase-F) — verified against Package.swift on 2026-04-30.
# Edit this when Package.swift changes (and update the Bible if a new edge represents
# an architectural decision).
#   EnviousWispr           -> Core, Storage, PostProcessing, Audio, Services, ASR, LLM, Pipeline (executable, top of stack)
#   EnviousWisprAudioService -> Core, Audio (XPC executable)
#   EnviousWisprASRService -> Core, ASR, Audio (XPC executable)
#   EnviousWisprPipeline   -> Core, ASR, Audio, LLM, PostProcessing, Services, Storage
#   EnviousWisprASR        -> Core, Audio
#   EnviousWisprServices   -> Core
#   EnviousWisprLLM        -> Core
#   EnviousWisprAudio      -> Core
#   EnviousWisprPostProcessing -> Core
#   EnviousWisprStorage    -> Core
#   EnviousWisprCore       -> (no app deps)

set -euo pipefail

declare -A allowed
allowed["EnviousWisprCore"]=""
allowed["EnviousWisprAudio"]="EnviousWisprCore"
allowed["EnviousWisprASR"]="EnviousWisprCore EnviousWisprAudio"
allowed["EnviousWisprPostProcessing"]="EnviousWisprCore"
allowed["EnviousWisprStorage"]="EnviousWisprCore"
allowed["EnviousWisprLLM"]="EnviousWisprCore"
allowed["EnviousWisprServices"]="EnviousWisprCore"
allowed["EnviousWisprPipeline"]="EnviousWisprCore EnviousWisprASR EnviousWisprAudio EnviousWisprLLM EnviousWisprPostProcessing EnviousWisprServices EnviousWisprStorage"
# XPC service executables — narrower than the app target.
allowed["EnviousWisprAudioService"]="EnviousWisprCore EnviousWisprAudio"
allowed["EnviousWisprASRService"]="EnviousWisprCore EnviousWisprASR EnviousWisprAudio"
# App executable — top of stack, allowed to import any library module.
allowed["EnviousWispr"]="EnviousWisprCore EnviousWisprStorage EnviousWisprPostProcessing EnviousWisprAudio EnviousWisprServices EnviousWisprASR EnviousWisprLLM EnviousWisprPipeline"

violations=0

for module_dir in Sources/*/; do
  module=$(basename "$module_dir")
  permitted="${allowed[$module]:-__UNDECLARED__}"
  if [ "$permitted" = "__UNDECLARED__" ]; then
    echo "DEP-DIRECTION: unknown target '$module' under Sources/ — add to allowed[] or remove" >&2
    violations=$((violations + 1))
    continue
  fi
  while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    imp=$(echo "$line" | sed -E 's/.*import +([A-Za-z_]+).*/\1/')
    case "$imp" in
      EnviousWispr*)
        if ! echo " $permitted " | grep -q " $imp "; then
          echo "DEP-DIRECTION: $file: '$module' imports '$imp' (not in allowed: $permitted)"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done < <(grep -rn "^import EnviousWispr" "$module_dir" || true)
done

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations dep-direction violation(s)" >&2
  exit 1
fi
echo "OK: dep-direction clean across $(ls -d Sources/*/ | wc -l | tr -d ' ') modules"
```

The dep-graph above is a working draft; Codex grounded review (§7) will fact-check it against current `Package.swift`. Final graph lands in the script after grounded review.

### 3.4 CI workflow change

`.github/workflows/pr-check.yml` currently has only a `build-check` job — no `lint` job exists today. Add a new `arch-lint` job (sibling of `build-check`, NOT making it a required check yet — gets promoted to required after one clean run):

```yaml
  arch-lint:
    runs-on: [self-hosted, enviouswispr-release]
    timeout-minutes: 5
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 1

      - name: Architecture dep-direction
        run: bash scripts/check-dependency-direction.sh
```

Self-hosted runner is fine — the script is grep-only, runs in seconds. NOT marked as required check on first ship to avoid the "skipped-required-check stalls auto-merge" trap (per `learning_skipped_blocks_required_check`); promote to required after one merged PR demonstrates green output.

### 3.5 architecture-rules.md addition

New section (after `## Audio/ASR Danger Zones`):

```markdown
## Architectural Ceilings (enforced by tests)

These ceilings prevent slow drift toward god-objects. Tests live in
`Tests/EnviousWisprTests/Architecture/`.

| Ceiling | Limit | Where | Enforced by |
|---------|------:|-------|-------------|
| AppState concrete collaborators (`let`, non-primitive) | ≤ 19 | `Sources/EnviousWispr/App/AppState.swift` | `AppStateCeilingsTests` |
| AppState file line count | ≤ 1050 | same | `AppStateCeilingsTests` |
| Confessional cross-module `public` | 0 | All `Sources/EnviousWispr*/` (excluding executable) | `CrossModulePublicGuardTests` |
| Module dep-direction (no backward import edges) | 0 violations | All Sources/ modules | `scripts/check-dependency-direction.sh` (CI) |

Raising a ceiling is allowed but requires:
1. A line in the Bible (`docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md`) justifying the new collaborator or new public surface.
2. A test update in the same PR.
3. Codex grounded review on the bump.

Lowering a ceiling is free; it represents progress.
```

## 4. Files touched

- NEW `Tests/EnviousWisprTests/Architecture/AppStateCeilingsTests.swift` (~110 LOC)
- NEW `Tests/EnviousWisprTests/Architecture/CrossModulePublicGuardTests.swift` (~60 LOC)
- NEW `scripts/check-dependency-direction.sh` (~60 LOC)
- `.github/workflows/pr-check.yml` (+12 LOC: new `arch-lint` job)
- `Sources/EnviousWisprASR/WhisperKitBackend.swift` (3-line edit: `public func` → `package func` at line 157, comment cleanup at lines 155-156)
- `.claude/rules/architecture-rules.md` (+25 LOC: new section)
- `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` (+5 LOC: changelog entry, Phase E status → SHIPPED, plus Phase F metric-tightening note)

Estimated net: ~+275 LOC across 7 files. Almost entirely test code, bash, YAML, and prose; the only non-test/non-script code change is a 1-line access-level narrowing in `WhisperKitBackend.swift`.

## 5. Plan of attack

1. Worktree already created (`feat/issue-502-phase-e-arch-tests`).
2. Codex grounded review on this plan with focus on:
   - Ceiling values (19 / 1050 — too tight? too loose?)
   - Stored-property detection logic (string-parse vs Mirror)
   - Dep-graph in §3.3 (verify against current `Package.swift`)
   - Cross-module-public regex (false-positive risk in third-party-named code paths)
3. Revise plan once. Lock final values.
4. Implement two test files + bash script + workflow edit + arch-rules edit + Bible entry.
5. `swift test` locally. All three new tests must pass at baseline. Run dep-direction script locally.
6. Codex code-diff review on uncommitted changes. Iterate to clean.
7. Phase 3 validation: `scripts/validate-pr.sh` writes `.validation/runs/<ts>-<sha>/`. Skip-note for live-uat (pure tests, no runtime change). shellcheck for the bash script. workflow-run for pr-check.yml syntax.
8. Push + PR + auto-merge. Council-skip tag: `council-skip: codex-grounded-review settled, no user surface, pure architecture-regression tests + CI script`.
9. Close #502 with Architecture Closeout per arch-rules §Architecture Closeout Format.

## 6. Risks

- **False positive on cross-module-public test.** The word "TODO" is broad; a comment like `// TODO: this code is fine, no work needed` near a legitimate `public` declaration would trip the test. Mitigation: the regex requires the TODO/narrow/phase/temporary/cross-module token AND the `public` keyword in a 3-line window, which is tight. Codex grounded review will scan current code for any existing match; if one exists, it is either a real offender (delete the TODO or extract the type) or a false positive that signals we need a tighter regex.
- **Ceiling math wrong.** If post-F line count is actually higher than 954 due to a missed file edit, the line-count ceiling is too tight. Codex grounded review will re-measure during plan review.
- **Dep-graph assertion is brittle.** Adding a legitimate new import requires editing the bash array. Mitigation: documented in arch-rules so the next session reads "edit the script first" before being surprised by a CI failure.
- **String-based property counting drifts.** Future refactor that uses multi-line declarations or top-level closure literals breaks the count. Mitigation: §3.1 names this as an explicit non-goal of cleverness; failing-loudly-on-format-drift is acceptable because AppState's format is conventional.

## 7. Validation strategy

- Unit tests: 2 new `@Test` cases in `AppStateCeilingsTests` + 1 in `CrossModulePublicGuardTests` — all must pass at baseline.
- Negative tests (manual, not committed): temporarily add a 20th `let` to AppState; verify the property-count test fails. Revert. Same for line count: add 100 blank lines. Revert. Same for dep-direction: add `import EnviousWisprPipeline` to a Core file; verify the script fails. Revert. Same for cross-module-public: add `public // TODO: narrow` to an EnviousWisprCore file; verify test fails. Revert. Results recorded in PR body.
- shellcheck on the bash script.
- Codex grounded review on plan.
- Codex code-diff review on PR.

## 8. Definition of Done

- [ ] AppStateCeilingsTests.swift created, 2 tests passing at baseline (count = 19, lines = 954)
- [ ] CrossModulePublicGuardTests.swift created, 1 test passing at baseline (0 offenders)
- [ ] scripts/check-dependency-direction.sh created, executable, exits 0 at baseline
- [ ] CI workflow runs the script as a `lint` step
- [ ] architecture-rules.md `Architectural Ceilings` section added
- [ ] Bible §11 changelog entry added (Phase E SHIPPED + Phase F metric reconciliation note: "Phase F's plan predicted 19→17 using a looser metric; live post-F is 19. Phase E locks the tighter `let`-only definition. Net: Phase F still removed two collaborators (ollamaSetup + whisperKitSetup) and added one (setup), the architectural win is real; the prior count was just nominal.")
- [ ] WhisperKitBackend.makeDecodeOptions narrowed `public` → `package`; Pipeline still builds + tests still pass
- [ ] All 4 negative-test scenarios verified locally (intentional violation → test fails) and reverted
- [ ] Codex grounded review on plan (PROCEED-AS-PLANNED or PROCEED-WITH-REVISIONS resolved)
- [ ] Codex code-diff review on PR (clean)
- [ ] CI build-check + lint green
- [ ] PR auto-merged, main green, #502 closed with Architecture Closeout
- [ ] Audit meta-rec #1 marked RESOLVED in Bible

## 9. Architecture Closeout (filled at PR time)

- Module/owner chosen: Tests live in EnviousWisprTests; script lives in `scripts/`; rules in `.claude/rules/architecture-rules.md`. Standard locations.
- Why this placement is correct: tests run with the rest of `swift test`; script runs with the rest of `lint` job; rules sit alongside other architectural guidance.
- Whether any central type grew: no.
- Whether access control widened: no.
- Whether any temporary compromise remains: stored-property detection is string-based (justified in §3.1).
- Whether dependency direction remains clean: verified by the new script.

## 10. Out-of-scope follow-ups

- Move dep-graph encoding from inline bash array to a YAML/JSON file consumed by both the script and a future Swift-side build-time check.
- Consider a similar ceiling for `TranscriptionPipeline` and `WhisperKitPipeline` once they reach a stable shape.
- Replace the no-op `.git/hooks/pre-commit` stub with a wrapper that calls the dep-direction script locally before push (in addition to CI).
