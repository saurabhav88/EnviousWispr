# Rebuild Skill Overhaul — Phased Plan

**Context**: The `wispr-rebuild-and-relaunch` skill was written during early development. Now that EnviousWispr is a commercial product (v1.0.0 released), the dev sandbox workflow needs to catch up. An internal audit found 10 issues; an external review (Gemini) confirmed and prioritized them.

**Approach**: Three phases, each self-contained and independently shippable. Brainstorm → plan → implement per phase.

**Team**: Solo indie dev + Claude (AI agent). Skills are AI-executed .md instructions, not human-run scripts.

---

## Phase 1 — Fix What's Broken (7 items)

Correctness and reliability. The skill has checks that always fail, missing exit code handling, and guidance that's wrong.

- [ ] **Add exit code checking after `swift build`** — failed build silently bundles old binary (CRITICAL)
- [ ] **Add PROJ_ROOT variable** — hardcoded paths throughout both skills
- [ ] **Fix mtime staleness check** — compare against `.build/release/EnviousWispr` (raw build output), not signed bundle binary
- [ ] **Remove hash check → `codesign --verify`** — SHA always mismatches after install_name_tool + codesign; replace with bundle integrity verification
- [ ] **Add preflight cert check** — in `wispr-bundle-app`, warn if "EnviousWispr Dev" cert missing
- [ ] **Add pgrep wait loop** — replace `killall + sleep 2` race condition with deterministic polling
- [ ] **Make UAT conditional** — mandatory quick smoke test always; full Smart UAT opt-in only. Fix sleep comment (says 1, code says 2)

**Outcome**: Rebuild flow works without false failures; builds fail fast on real errors.

**Brainstorm**: [rebuild-phase1-brainstorm.md](rebuild-phase1-brainstorm.md)

---

## Phase 2 — Dev/Prod Isolation (6 items)

Separate dev and prod identity so TCC, Keychain, and Sparkle don't interfere.

- [ ] **Auto-create + persist self-signed dev cert** — stable "EnviousWispr Dev" cert via openssl + security import; create once, reuse forever (CRITICAL for TCC)
- [ ] **Stamp dev bundle ID** — `plutil -replace CFBundleIdentifier -string "com.enviouswispr.app.dev"` + verification step
- [ ] **Disable Sparkle in dev builds** — blank `SUFeedURL` via plutil
- [ ] **Rich version stamping** — git hash in CFBundleVersion (e.g., `1.0.0-dev+abcdef`) instead of `0.0.0-local`
- [ ] **Update TCC guidance** — rewrite gotchas.md once signing + bundle ID are stable
- [ ] **Dev icon badge** — visual "DEV" distinction on app icon (nice-to-have)

**Decisions made**:
- Keep self-signed cert (no Xcode/Apple Developer dependency)
- No hardened runtime for dev builds (too restrictive)
- No entitlements file needed (no HRT = no restrictions to opt out of)
- Keep Sparkle.framework embedded (binary dynamically linked, would crash without it)

**Outcome**: Dev and prod builds fully isolated; TCC persists across rebuilds.

**Brainstorm**: [rebuild-phase2-brainstorm.md](rebuild-phase2-brainstorm.md)

---

## Phase 3 — Streamline & Modernize (5 items)

Optimize the dev loop for speed and simplicity.

- [ ] **Configurable variables** — app name, bundle ID, cert name, PROJ_ROOT at top of both skills
- [ ] **`pkill -f` + `pgrep` polling** — deterministic, specific process termination
- [ ] **Switch to `open` for launch** — proper Launch Services registration, no `disown` needed
- [ ] **Benchmark debug vs release** — if debug is significantly faster, create `wispr-rebuild-debug` skill
- [ ] **Create `wispr-rebuild-hardened`** — opt-in HRT testing skill (niche, only if needed)

**Items rejected**:
- `set -eou pipefail` — irrelevant for AI-executed skills
- Omit Sparkle.framework — infeasible (dyld crash)
- Consolidate bundle-app delegation — keep skills separate (separation of concerns)

**Outcome**: Fast, clean, modern dev loop purpose-built for a commercial macOS app.

**Brainstorm**: [rebuild-phase3-brainstorm.md](rebuild-phase3-brainstorm.md)

---

## Summary

| Phase | Theme | Items | Key Decision |
|-------|-------|-------|-------------|
| 1 | Fix What's Broken | 7 | Exit code checking is #1 priority |
| 2 | Dev/Prod Isolation | 6 | Self-signed cert, no HRT, no Xcode |
| 3 | Streamline & Modernize | 5 | Variables + `open` + debug builds |
| **Total** | | **18** | |

## Audit Sources

- Internal audit: `release-maintenance` agent (10 issues)
- External brainstorm: Gemini 2.5 Pro via buddies MCP (session: `rebuild-skill-overhaul-brainstorm`)
- Second opinion: Gemini 2.5 Flash via buddies MCP (session: `rebuild-phase1-openai-review`)
- Related files: `.claude/skills/wispr-rebuild-and-relaunch/SKILL.md`, `.claude/skills/wispr-bundle-app/SKILL.md`, `scripts/build-dmg.sh`, `.claude/knowledge/gotchas.md`, `.claude/knowledge/distribution.md`
