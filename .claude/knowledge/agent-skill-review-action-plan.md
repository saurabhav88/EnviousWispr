# Agent & Skill Infrastructure Review — Action Plan

**Date**: 2026-03-01
**Reviewed by**: 6 parallel review agents + Gemini consultation
**Scope**: 10 agents, 47 skills, all knowledge files

---

## Exemplary — No Changes Needed

These are model-quality and should be used as templates for fixing others:

- `wispr-rebuild-and-relaunch` — exemplary defensive patterns, staleness checks, mandatory UAT
- `wispr-validate-keychain-usage` — 10/10 security checklist
- `wispr-resolve-naming-collisions` — comprehensive FluidAudio gotcha coverage
- `wispr-flag-sensitive-logging` — commercial-grade logging security
- `wispr-bundle-app` — exemplary inside-out signing, pre-wipe, Sparkle embedding
- `wispr-optimize-memory-management` — accurate patterns, commercial-grade

---

## P0 — Must Fix (15 items)

### Code-Breaking (generates wrong/non-compiling code)

**1. wispr-scaffold-asr-backend — hallucinated API**
- File: `.claude/skills/wispr-scaffold-asr-backend/prompt.md`
- Problem: Shows non-existent `modelInfo()`, `transcribeStream()`, `supportsStreamingPartials`, `ASRModelInfo`
- Fix: Rewrite scaffold to match actual `ASRBackend` protocol in `ASRProtocol.swift`:
  - `supportsStreaming: Bool { get }` (computed property)
  - `startStreaming()`, `feedAudio()`, `finalizeStreaming()`, `cancelStreaming()` (4 methods)
  - Add `options: TranscriptionOptions` parameter to `transcribe()`
  - Remove all hallucinated types/methods

**2. wispr-configure-language-settings — stale function names**
- File: `.claude/skills/wispr-configure-language-settings/prompt.md`
- Problem: `makeDecodingOptions()` should be `makeDecodeOptions()`, missing 7 quality params from TranscriptionOptions
- Fix: Cross-check with `WhisperKitBackend.swift` lines 65-79, show `mapResults()` helper usage

**3. wispr-handle-macos-permissions — WRONG Accessibility statement**
- File: `.claude/skills/wispr-handle-macos-permissions/prompt.md`
- Problem: Says paste needs NO Accessibility. Per gotchas.md, `CGEvent.post()` REQUIRES Accessibility on macOS 14+
- Fix:
  - Correct permission map: Paste = Accessibility REQUIRED
  - Add `@preconcurrency import AVFoundation` to example
  - Add runtime revocation monitoring + re-arm pattern (gotchas.md line 78)
  - Clarify Carbon hotkey requires NO Accessibility

### Distribution/Release (will burn you on launch day)

**4. Notarization contradiction**
- Files: `.claude/skills/wispr-codesign-without-xcode/prompt.md`, `.claude/knowledge/distribution.md`
- Problem: Codesign skill says full Xcode needed for notarization; distribution.md says CLT sufficient
- Fix: Verify actual requirement on CLT-only machine. Update whichever is wrong.

**5. build-dmg.sh undocumented**
- File: `.claude/skills/wispr-release-checklist/prompt.md`
- Problem: Step 7 references `build-dmg.sh` but no skill documents it
- Fix: Either create `wispr-build-dmg` skill OR integrate detailed steps into release-checklist

**6. arm64 constraint missing**
- Files: `wispr-build-release-config/prompt.md`, `wispr-check-dependency-versions/prompt.md`
- Problem: Don't warn about FluidAudio Float16 = arm64 only
- Fix: Add explicit note: "arm64 only — FluidAudio uses Float16, unavailable on x86_64"

**7. Sparkle signing explicit + verified in release-checklist**
- File: `.claude/skills/wispr-release-checklist/prompt.md`
- Problem: Step 8 "Sign DMG for Sparkle" is vague — botched signature orphans user base
- Fix: Make explicit: what tool, what key, verification step, what happens if signature is wrong

**8. Release rollback procedure**
- Files: `.claude/agents/release-maintenance.md`, `.claude/skills/wispr-release-checklist/prompt.md`
- Problem: No documented way to yank a bad release
- Fix: Add rollback section: pull appcast.xml, have previous DMG ready, re-tag, notify users

### UAT/Testing (Definition of Done is broken)

**9. wispr-run-smart-uat scope resolution**
- File: `.claude/skills/wispr-run-smart-uat/prompt.md`
- Problem: TodoWrite syntax undefined, "conversation context" vague, no scope validation
- Fix:
  - Define exact TodoWrite format with examples + auto-reject behavior
  - Create "Extract scope from conversation" rules
  - Add scope validation: >10 files changed → warn about scope creep
  - Move `run_in_background: true` from NOTE to FIRM RULE

**10. UAT workflow confusion**
- Files: `wispr-generate-uat-tests/prompt.md`, `wispr-run-smart-uat/prompt.md`
- Problem: generate-uat-tests outputs markdown scenarios; run-smart-uat expects Python via uat-generator
- Fix: Clarify generate-uat-tests is optional planning/documentation. run-smart-uat → uat-generator is the primary executable path.

### Infrastructure Gaps

**11. user-management agent skeleton**
- Files: `.claude/agents/user-management.md`, new knowledge file needed
- Problem: Zero skills, no accounts-licensing knowledge file
- Fix:
  - Create `.claude/knowledge/accounts-licensing.md` (tier matrix, payment provider decision, license format, trial rules)
  - Create stub skills: `wispr-scaffold-account-system`, `wispr-validate-license-key`, `wispr-configure-analytics`
  - Update agent to reference new knowledge + skills

**12. Missing "Before Acting" sections**
- Files: `.claude/agents/quality-security.md`, `.claude/agents/release-maintenance.md`, `.claude/agents/testing.md`
- Problem: Don't list required knowledge files to read before starting work
- Fix: Add "Before Acting" section to each listing which knowledge files are mandatory reading

**13. when-shit-breaks.md knowledge file**
- File: `.claude/knowledge/when-shit-breaks.md` (new)
- Problem: No agent defines cross-domain problem handling or incident response
- Fix: Simple checklist — not corporate matrices. Covers:
  - Build fails → first steps, who owns it
  - Critical bug in production → rollback procedure
  - Secret leaked → rotation workflow
  - API down → user notification strategy
  - Permission broken after update → TCC recovery

**14. Secret rotation workflow**
- File: New skill `wispr-rotate-secrets/prompt.md`
- Problem: No process for rotating API keys, signing certs under pressure
- Fix: Skill that covers: identify affected key, generate new key, update storage, verify, revoke old key

**15. TCC persistence cross-referenced in codesign skill**
- File: `.claude/skills/wispr-codesign-without-xcode/prompt.md`
- Problem: Doesn't mention Developer ID signing allows TCC persistence across rebuilds
- Fix: Add note linking TCC persistence to signing identity, reference gotchas.md and rebuild-and-relaunch skill

---

## P1 — Should Fix (19 items)

### Skills Fixes

| # | Issue | File | Fix |
|---|-------|------|-----|
| 16 | wispr-scaffold-llm-connector hallucinated `validateCredentials()` | prompt.md | Remove or mark optional |
| 17 | wispr-swift-format-check `disable-model-invocation: true` | prompt.md | Remove flag or convert to bash workflow |
| 18 | @preconcurrency imports missing from scaffold templates | 3 scaffold skills | Add note about required imports per swift-patterns.md |
| 19 | wispr-validate-api-contracts missing rate limiting + versioning | prompt.md | Add sections on rate limit handling and API deprecation strategy |
| 20 | UI testing skills missing Accessibility prerequisite | ax-inspect, simulate-input | Add "Prerequisites: Grant Accessibility" section |
| 21 | wispr-check-feature-tracker missing format examples | prompt.md | Link to TRACKER.md format and Definition of Done |
| 22 | Version format unspecified in release-checklist | prompt.md | Specify: `v1.0.0` for git tags, `1.0.0` in Info.plist |
| 23 | Appcast.xml generation unclear in release-checklist | prompt.md | Clarify CI generates it on tag push; add manual fallback |
| 24 | Smoke test vs rebuild-and-relaunch confusion in testing.md | testing agent | Rewrite to clarify: smoke test = compile gate, rebuild = full cycle |

### Agent Fixes

| # | Issue | File | Fix |
|---|-------|------|-----|
| 25 | No error recovery runbooks in any agent | All 10 agents | Add "Error Handling" section with common failure modes + recovery |
| 26 | Domain agents lack testing requirements | 5+ agents | Add "Testing Requirements" section linking to Definition of Done |
| 27 | Weak team participation protocols | All 10 agents | Add decision trees for peer blocked, peer disagreement, incomplete deliverable |
| 28 | Incomplete gotcha checklists per agent | All 10 agents | Audit each against gotchas.md; add "Gotchas Relevant to This Agent" checklist |

### New Items

| # | Issue | Fix |
|---|-------|-----|
| 29 | Delete mcp-builder from project skills | Remove `.claude/skills/mcp-builder/` |
| 30 | Data migration strategy | Create `.claude/knowledge/data-migration.md` covering settings format changes between versions. Consider a `wispr-scaffold-migration-handler` skill. |

---

## P2 — Nice to Have (9 items)

1. Code examples in 3-5 agents (show best practices concretely)
2. Domain boundary conflict resolution docs
3. Section naming standardization across agent files
4. Performance baselines in testing agent (RTF thresholds, memory limits)
5. TSan / thread-safety testing guidance
6. Animation gotcha in scaffold skills (per-element .animation() pitfall)
7. Screenshot baseline management for CI/CD
8. wispr-find-dead-code uses hardcoded absolute paths → switch to relative
9. File-index.md links in all agents for cold-start navigation

---

## Execution Strategy

### Phase 1: Code-Breaking P0s (items 1-3)
Fix skills that generate wrong/non-compiling code. These are the highest-risk items — a fresh session using these skills will produce broken output.

### Phase 2: Distribution P0s (items 4-8)
Fix release pipeline contradictions and gaps. These block shipping.

### Phase 3: UAT P0s (items 9-10)
Fix the Definition of Done pipeline so it actually works reliably.

### Phase 4: Infrastructure P0s (items 11-15)
Build missing infrastructure: user-management skeleton, incident response, secret rotation, TCC cross-refs.

### Phase 5: P1 Sweep
Fix all P1 items. Skills fixes first (lower effort), then agent fixes (bulk cross-cutting changes).

### Phase 6: P2 Polish
Nice-to-haves if time permits.

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Promoted rollback, secret rotation, Sparkle signing, TCC to P0 | Gemini review: "will burn you on launch day" |
| Reframed "error escalation matrix" to `when-shit-breaks.md` | Simpler, more actionable for 2-person team |
| Deleted mcp-builder | Generic MCP guide, not project-specific |
| Discarded App Sandboxing concern | Direct distribution via Sparkle/DMG, not App Store. App needs Accessibility + CGEvent. |
| Discarded crash reporting as P0 | Valid long-term but it's a feature decision, not agent/skill infrastructure gap |
| Added data migration as P1 | Gemini flagged: settings format changes between versions need a migration path |
