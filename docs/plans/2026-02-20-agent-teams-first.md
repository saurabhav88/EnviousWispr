# Agent Teams First — Configuration Transformation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the project from fire-and-forget subagent dispatch (left diagram) to persistent Agent Teams with shared task lists, peer communication, and coordinated workflows (right diagram) — so teams are used 90%+ of the time.

**Architecture:** Create a `teamwork.md` knowledge file as the shared foundation. Add a standard "Team Participation" section to all 9 agent definitions. Enhance the coordinator's instructions in CLAUDE.md with decision criteria and team lifecycle. Elevate feature-planning into a team lead role.

**Tech Stack:** Markdown configuration files only — `.claude/agents/*.md`, `.claude/knowledge/*.md`, `CLAUDE.md`, `MEMORY.md`

---

## Task 1: Create Teamwork Knowledge File

**Files:**
- Create: `.claude/knowledge/teamwork.md`

**Step 1: Write the teamwork knowledge file**

Create `.claude/knowledge/teamwork.md` with this exact content:

```markdown
# Team Orchestration

How and when to use Agent Teams (TeamCreate + shared task lists + SendMessage).

## Decision Matrix — Teams vs Parallel Task

| Scenario | Use | Why |
|----------|-----|-----|
| Feature implementation (2+ agents) | **TeamCreate** | Sequential deps, peer communication needed |
| Bug fix spanning 2+ source directories | **TeamCreate** | Coordinated diagnosis + fix + validation |
| Release process | **TeamCreate** | Multi-step pipeline, needs coordination |
| Quality/security audit | **TeamCreate** | Systematic review with build validation |
| Refactor touching multiple domains | **TeamCreate** | Peer agents must see each other's output |
| Quick factual lookup (1 agent, 1 question) | **Parallel Task** | Fire-and-forget, no coordination |
| Independent searches across 2-3 agents | **Parallel Task** | No dependencies between results |
| Single-skill invocation | **Skill tool** | Not an agent task at all |
| Clarifying question to user | **AskUserQuestion** | No agent needed |

**Rule of thumb:** If the work involves 2+ agents whose outputs depend on each other → TeamCreate. If agents work in complete isolation → parallel Task.

## Standard Team Compositions

### feature-team

**Trigger:** Any feature request, multi-file feature, or cross-domain change.

| Name | Agent | Role |
|------|-------|------|
| `planner` | feature-planning | Reads spec, creates subtasks, coordinates sequence |
| `{domain}` | (varies by feature) | Implements core changes — audio-pipeline, macos-platform, etc. |
| `builder` | build-compile | Validates compilation after each change |
| `validator` | testing | Smoke test + relevant UI validation |

Add `auditor` (quality-security) if feature touches concurrency, secrets, or API keys.

### release-team

**Trigger:** Tagged release, distribution build, changelog generation.

| Name | Agent | Role |
|------|-------|------|
| `releaser` | release-maintenance | Leads the release pipeline |
| `auditor` | quality-security | Pre-release security sweep |
| `builder` | build-compile | Release build validation |
| `validator` | testing | Smoke test + benchmarks |

### fix-team

**Trigger:** Bug fix spanning 2+ source directories or requiring diagnosis.

| Name | Agent | Role |
|------|-------|------|
| `fixer` | (domain agent) | Diagnoses and fixes the issue |
| `builder` | build-compile | Validates compilation |
| `validator` | testing | Verifies fix didn't break anything |

### audit-team

**Trigger:** Pre-release quality check, security review, concurrency audit.

| Name | Agent | Role |
|------|-------|------|
| `auditor` | quality-security | Leads the audit, runs all 7 security skills |
| `builder` | build-compile | Validates any fixes |
| `validator` | testing | Smoke test after fixes |

## Team Lifecycle

```text
1. CREATE    → Coordinator calls TeamCreate (name + description)
2. SPAWN     → Coordinator spawns teammates via Task (team_name + name + subagent_type)
3. TASKS     → Coordinator (or lead teammate) creates tasks via TaskCreate
4. ASSIGN    → Tasks assigned via TaskUpdate with owner = teammate name
5. EXECUTE   → Teammates work on tasks, mark complete, claim next
6. COMMUNICATE → Teammates use SendMessage for peer coordination
7. COMPLETE  → All tasks done → coordinator sends shutdown_request to each
8. CLEANUP   → Coordinator calls TeamDelete
```

## Coordinator Protocol

The main agent (Claude Code session) is always the team lead. Responsibilities:

1. **Classify the task** — consult this decision matrix
2. **Choose composition** — pick from standard teams above, adapt if needed
3. **Create the team** — `TeamCreate` with a descriptive name (e.g., `feature-cancel-hotkey`)
4. **Spawn teammates** — `Task` tool with `team_name`, `name`, and `subagent_type` for each
5. **Create task breakdown** — use TaskCreate for each discrete work item
6. **Assign first-wave tasks** — TaskUpdate with owner for non-blocked tasks
7. **Monitor** — messages from teammates are auto-delivered; respond to questions/blockers
8. **Unblock** — reassign stuck tasks, spawn additional teammates if needed
9. **Shutdown** — SendMessage `shutdown_request` to each teammate when done
10. **Cleanup** — TeamDelete to remove team and task files

**Important:** The coordinator NEVER does implementation work. If a task needs doing and no teammate can handle it, spawn a new teammate — don't do it yourself.

## Teammate Protocol

When spawned as a teammate (with `team_name` parameter), every agent follows this protocol:

1. **Discover peers** — Read `~/.claude/teams/{team-name}/config.json` for teammate names and roles
2. **Check tasks** — TaskList to find tasks assigned to you (by your `name`)
3. **Claim work** — If unassigned tasks match your domain, claim with TaskUpdate (prefer lowest ID first)
4. **Execute** — Do the work using your skills and domain knowledge
5. **Mark complete** — TaskUpdate to set status = completed, then immediately check TaskList for next task
6. **Communicate results** — SendMessage to coordinator when task is done, include summary of what changed
7. **Peer messaging** — If you discover an issue in another agent's domain, SendMessage directly to that peer
8. **Create subtasks** — If your task reveals additional work needed, use TaskCreate to add it
9. **Idle gracefully** — After sending a message, you go idle. This is normal. You'll wake when new work arrives

## Communication Patterns

| From | To | When | Method |
|------|----|------|--------|
| Coordinator | One teammate | Task assignment, answer question | SendMessage (DM) |
| Coordinator | All teammates | Critical blocker, abort, direction change | SendMessage (broadcast) — **rare** |
| Teammate | Coordinator | Task complete, blocker found, question | SendMessage (DM) |
| Teammate | Peer teammate | Need their output, found issue in their domain | SendMessage (DM) |

**Never broadcast for routine updates.** DM the relevant teammate or coordinator instead.

## Anti-Patterns

| Don't | Do Instead |
|-------|-----------|
| Spawn parallel Tasks when agents need each other's output | TeamCreate so they can communicate |
| Use TeamCreate for a single quick lookup | Parallel Task — it's faster |
| Have coordinator implement code | Spawn a teammate to do it |
| Broadcast routine status updates | DM the coordinator only |
| Let teammates go idle without checking TaskList first | Always check for next task before going idle |
| Create a team of 1 | Use parallel Task for single-agent work |
```

**Step 2: Verify the file exists and is well-formed**

Run: `wc -l .claude/knowledge/teamwork.md`
Expected: ~130-140 lines

**Step 3: Commit**

```bash
git add .claude/knowledge/teamwork.md
git commit -m "docs(knowledge): add teamwork.md — team orchestration patterns and lifecycle"
```

---

## Task 2: Add Team Participation to Agent Definitions (Batch 1 — audio-pipeline, build-compile, macos-platform)

**Files:**
- Modify: `.claude/agents/audio-pipeline.md` (append after Coordination section)
- Modify: `.claude/agents/build-compile.md` (append after Coordination section)
- Modify: `.claude/agents/macos-platform.md` (append after Coordination section)

**Step 1: Add Team Participation section to audio-pipeline**

Append to `.claude/agents/audio-pipeline.md` after the `## Coordination` section:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve Audio/, ASR/, Pipeline/, or VAD — claim them (lowest ID first)
4. **Execute**: Use your skills. Read `.claude/knowledge/gotchas.md` before any code change
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with summary of changes (files modified, key decisions)
7. **Peer handoff**: If you find a build error → message `builder`. Concurrency issue → message `auditor`
8. **Create subtasks**: If implementation reveals additional work, TaskCreate to add it
```

**Step 2: Add Team Participation section to build-compile**

Append to `.claude/agents/build-compile.md` after the `## Coordination` section:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve build validation, compiler errors, or dependency updates — claim them (lowest ID first)
4. **Execute**: Run `swift build` (or `swift build -c release`). Parse and fix errors using your skills
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator confirming build status (pass/fail, error count)
7. **Peer handoff**: If error is in another agent's domain, message that peer with the exact error and file location
8. **Rapid response**: When a peer messages you about a build break, prioritize it — build validation is on the critical path
```

**Step 3: Add Team Participation section to macos-platform**

Append to `.claude/agents/macos-platform.md` after the `## Coordination` section:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve Services/, Views/, permissions, hotkeys, paste, or SwiftUI — claim them (lowest ID first)
4. **Execute**: Use your skills. Follow SwiftUI conventions from `.claude/knowledge/conventions.md`
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with summary of UI/platform changes
7. **Peer handoff**: Build errors → message `builder`. Security concerns in UI → message `auditor`
8. **Create subtasks**: If a UI change requires new accessibility labels or permission checks, TaskCreate to track them
```

**Step 4: Commit batch 1**

```bash
git add .claude/agents/audio-pipeline.md .claude/agents/build-compile.md .claude/agents/macos-platform.md
git commit -m "docs(agents): add team participation to audio-pipeline, build-compile, macos-platform"
```

---

## Task 3: Add Team Participation to Agent Definitions (Batch 2 — quality-security, feature-scaffolding, testing)

**Files:**
- Modify: `.claude/agents/quality-security.md` (append after Coordination section)
- Modify: `.claude/agents/feature-scaffolding.md` (append after Coordination section)
- Modify: `.claude/agents/testing.md` (append after Coordination section)

**Step 1: Add Team Participation section to quality-security**

Append to `.claude/agents/quality-security.md`:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve concurrency audit, Sendable checks, secret detection, or security review — claim them (lowest ID first)
4. **Execute**: Run your audit skills systematically. Check all items on your Concurrency and Security Checklists
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with audit findings (issues found, severity, files affected)
7. **Peer handoff**: If audit finds a fix needed → message the domain agent. If fix breaks build → message `builder`
8. **Blocking issues**: If you find a security vulnerability, SendMessage immediately — don't wait for task completion
```

**Step 2: Add Team Participation section to feature-scaffolding**

Append to `.claude/agents/feature-scaffolding.md`:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve scaffolding new backends, connectors, views, or settings tabs — claim them (lowest ID first)
4. **Execute**: Use scaffolding skills. Follow patterns from `.claude/knowledge/conventions.md`
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator listing all files created/modified
7. **Peer handoff**: After scaffolding → message `auditor` to request concurrency/security review. Message `builder` for build validation
8. **Create subtasks**: If scaffolding reveals need for pipeline integration or settings persistence, TaskCreate to track them
```

**Step 3: Add Team Participation section to testing**

Append to `.claude/agents/testing.md`:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve smoke tests, UI tests, benchmarks, or API contract checks — claim them (lowest ID first)
4. **Execute**: Use your validation hierarchy: compile → build tests → bundle + launch → UI tests → benchmarks
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with test results (pass/fail, specific failures, screenshots if UI test)
7. **Peer handoff**: Build failures → message `builder`. Test reveals domain bug → message the domain agent
8. **Final gate**: You are typically the last agent to run. Only report success when ALL validation passes
```

**Step 4: Commit batch 2**

```bash
git add .claude/agents/quality-security.md .claude/agents/feature-scaffolding.md .claude/agents/testing.md
git commit -m "docs(agents): add team participation to quality-security, feature-scaffolding, testing"
```

---

## Task 4: Add Team Participation to Agent Definitions (Batch 3 — release-maintenance, user-management)

**Files:**
- Modify: `.claude/agents/release-maintenance.md` (append after Coordination section)
- Modify: `.claude/agents/user-management.md` (append after Coordination section)

**Step 1: Add Team Participation section to release-maintenance**

Append to `.claude/agents/release-maintenance.md`:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve bundling, signing, changelog, migration, or dead code — claim them (lowest ID first)
4. **Execute**: Use your skills. Reference `.claude/knowledge/distribution.md` for release pipeline details
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with release artifacts produced (bundle path, changelog entries, version)
7. **Peer handoff**: Build issues → message `builder`. Need security audit before release → message `auditor`
8. **Sequencing**: Release tasks are often sequential — wait for audit and build validation before proceeding to signing
```

**Step 2: Add Team Participation section to user-management**

Append to `.claude/agents/user-management.md`:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve accounts, licensing, entitlements, trials, payments, or analytics — claim them (lowest ID first)
4. **Execute**: Use your patterns. Sensitive data to Keychain, non-sensitive to UserDefaults
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with summary of user management changes
7. **Peer handoff**: Keychain/secrets → message `auditor`. New settings tab → message scaffolding peer. Build issues → message `builder`
8. **Create subtasks**: If payment integration reveals need for webhook handling or receipt validation, TaskCreate to track them
```

**Step 3: Commit batch 3**

```bash
git add .claude/agents/release-maintenance.md .claude/agents/user-management.md
git commit -m "docs(agents): add team participation to release-maintenance, user-management"
```

---

## Task 5: Enhance Feature-Planning with Team Lead Protocol

**Files:**
- Modify: `.claude/agents/feature-planning.md`

This is the most critical change — feature-planning becomes the primary team lead that coordinates multi-agent implementations within a team.

**Step 1: Add Team Lead Protocol section to feature-planning**

Insert a new section `## Team Lead Protocol` after the existing `## Implementing a Feature` section. Also update the `## Implementing a Feature` section to reference team-based execution.

Replace the existing `## Implementing a Feature` section with:

```markdown
## Implementing a Feature (Team-Based)

When spawned as the `planner` teammate in a feature-team:

1. Read the completed implementation plan from `docs/feature-requests/NNN-*.md`
2. Map each step to the owning teammate (discovered via team config):
   - Hotkey/permissions/UI → peer named for macos-platform
   - Audio/VAD/ASR → peer named for audio-pipeline
   - New backends/connectors/views → peer named for feature-scaffolding
   - Concurrency/security → peer named for quality-security
   - Build issues → peer named `builder` (build-compile)
3. Create tasks via TaskCreate for each implementation step, in dependency order
4. Assign first-wave tasks (non-blocked ones) to the appropriate teammates
5. Monitor progress — when a teammate completes a task, assign the next one that's unblocked
6. After each domain agent completes a change, assign a build validation task to `builder`
7. After all implementation is done, assign smoke test + validation tasks to `validator`
8. Report final status to coordinator via SendMessage

## Team Lead Protocol

As `planner` in a feature-team, you coordinate the other teammates:

### Task Creation Pattern

For a typical feature, create tasks in this order:

1. `[domain] Implement core changes` — assigned to domain agent
2. `[build] Validate compilation` — blocked on task 1, assigned to builder
3. `[domain] Wire into AppState / pipeline` — blocked on task 2
4. `[build] Validate compilation` — blocked on task 3
5. `[audit] Review concurrency and security` — blocked on task 4 (if applicable)
6. `[build] Fix any audit findings` — blocked on task 5 (if applicable)
7. `[test] Smoke test + UI validation` — blocked on all above
8. `[planner] Update TRACKER.md status` — blocked on task 7

### Communication Rules

- **Don't micromanage**: Assign the task, let the teammate execute using their own skills
- **Unblock quickly**: If a teammate reports a blocker, reassign or create a new task to resolve it
- **Sequence matters**: Never assign a build validation before the code change it validates
- **Final gate**: Only update TRACKER.md to complete after validator confirms all tests pass
```

**Step 2: Add Team Participation section**

Append to `.claude/agents/feature-planning.md` after the updated sections:

```markdown

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names and roles
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Lead role**: As `planner`, you typically create and assign tasks for other teammates rather than implementing code yourself
4. **Execute planning tasks**: Read feature specs, write implementation plans, update TRACKER.md
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Coordinate**: Use SendMessage to assign work, answer questions, and unblock peers
7. **Track progress**: Periodically check TaskList to see if any tasks are stuck or unassigned
8. **Report up**: SendMessage to coordinator with overall feature status (% complete, blockers, ETA)
```

**Step 3: Commit**

```bash
git add .claude/agents/feature-planning.md
git commit -m "docs(agents): elevate feature-planning to team lead with task creation protocol"
```

---

## Task 6: Update CLAUDE.md with Team-First Rules

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Expand Rule 7 and add Rule 8**

Replace the current Rules section (lines 18-26) with:

```markdown
## Rules

1. **Read [gotchas](.claude/knowledge/gotchas.md) before any code change.** FluidAudio naming collision and Sparkle rpath will bite you.
2. **Always delegate to an Agent first.** You are a coordinator, not a laborer.
3. **Never do an agent's job.** If a task falls in an agent's domain, that agent handles it.
4. **If no agent or skill exists, create one.** Scaffold in `.claude/agents/` or `.claude/skills/` before doing the work yourself.
5. **Compose, don't improvise.** Chain agents: Audio Pipeline diagnoses → Build fixes → Testing validates.
6. **Read knowledge files before acting.** Consult `.claude/knowledge/` first.
7. **Teams first for multi-agent work.** If 2+ agents are needed and their outputs depend on each other → `TeamCreate`. See [teamwork](.claude/knowledge/teamwork.md) for compositions, lifecycle, and decision matrix. Only use parallel `Task` for independent single-agent lookups.
8. **You are the team lead.** Create teams, spawn teammates, assign tasks via shared task list, monitor progress via auto-delivered messages, shut down when complete. Never implement code yourself — if no teammate can handle it, spawn one.
```

**Step 2: Add teamwork.md to the Knowledge table**

Add a row to the Knowledge table:

```markdown
| [teamwork](.claude/knowledge/teamwork.md) | Team compositions, lifecycle, decision matrix, communication patterns |
```

So the full Knowledge table becomes:

```markdown
## Knowledge

| File | Contents |
| ---- | -------- |
| [architecture](.claude/knowledge/architecture.md) | Structure, key types, pipeline state machine, data flow |
| [gotchas](.claude/knowledge/gotchas.md) | FluidAudio collision, Swift 6, audio format, Keychain |
| [conventions](.claude/knowledge/conventions.md) | Commit style, DI patterns, view patterns, imports |
| [distribution](.claude/knowledge/distribution.md) | Release pipeline, Sparkle, DMG build, CI/CD, codesigning |
| [roadmap](.claude/knowledge/roadmap.md) | Feature requests, tracker, priority system, implementation workflow |
| [teamwork](.claude/knowledge/teamwork.md) | Team compositions, lifecycle, decision matrix, communication patterns |
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): expand rules for team-first orchestration, add teamwork knowledge ref"
```

---

## Task 7: Update Project Memory

**Files:**
- Modify: `/Users/m4pro_sv/.claude/projects/-Users-m4pro-sv-Desktop-EnviousWispr/memory/MEMORY.md`

**Step 1: Add team-first section to MEMORY.md**

Add a new section after "### Delegation Discipline" block:

```markdown
### Team-First Orchestration (2026-02-20 refactor)

- **Default to TeamCreate** for any task involving 2+ agents with dependent outputs
- **Parallel Task only** for independent single-agent lookups
- **Knowledge file**: `.claude/knowledge/teamwork.md` — decision matrix, compositions, lifecycle
- **Standard teams**: feature-team, release-team, fix-team, audit-team
- **All 9 agents** have `## Team Participation` sections with: discover peers, claim tasks, peer messaging, idle protocol
- **feature-planning** is the primary team lead — creates subtasks, assigns to peers, monitors progress
- **Coordinator never implements** — always spawn a teammate
- **Team lifecycle**: TeamCreate → spawn → TaskCreate → assign → monitor → shutdown → TeamDelete
```

**Step 2: Commit**

This file is outside the repo, so no git commit needed.

---

## Task 8: Validate All Changes

**Files:**
- Read: All modified files

**Step 1: Verify all 9 agents have Team Participation section**

Run grep across all agent files:

```bash
grep -l "Team Participation" .claude/agents/*.md
```

Expected: All 9 agent files listed:
- audio-pipeline.md
- build-compile.md
- feature-planning.md
- feature-scaffolding.md
- macos-platform.md
- quality-security.md
- release-maintenance.md
- testing.md
- user-management.md

**Step 2: Verify CLAUDE.md references teamwork.md**

```bash
grep "teamwork" CLAUDE.md
```

Expected: Two matches — one in Rules (Rule 7), one in Knowledge table.

**Step 3: Verify teamwork.md exists and is complete**

```bash
grep "^## " .claude/knowledge/teamwork.md
```

Expected sections:
- Decision Matrix
- Standard Team Compositions
- Team Lifecycle
- Coordinator Protocol
- Teammate Protocol
- Communication Patterns
- Anti-Patterns

**Step 4: Verify feature-planning has Team Lead Protocol**

```bash
grep "^## " .claude/agents/feature-planning.md
```

Expected: Should include `Team Lead Protocol` and `Implementing a Feature (Team-Based)`.

**Step 5: Final commit if any fixups needed**

```bash
git status
# If any unstaged changes from fixups:
git add -A && git commit -m "docs: fixup team-first configuration consistency"
```

---

## Summary of Changes

| File | Change | Purpose |
|------|--------|---------|
| `.claude/knowledge/teamwork.md` | **New** | Foundation — decision matrix, compositions, lifecycle, protocols |
| `.claude/agents/audio-pipeline.md` | Append section | Team participation: claim Audio/ASR tasks, peer handoff |
| `.claude/agents/build-compile.md` | Append section | Team participation: rapid build validation, peer error routing |
| `.claude/agents/macos-platform.md` | Append section | Team participation: claim UI/platform tasks, peer handoff |
| `.claude/agents/quality-security.md` | Append section | Team participation: audit tasks, blocking security issues |
| `.claude/agents/feature-scaffolding.md` | Append section | Team participation: scaffolding tasks, request peer reviews |
| `.claude/agents/testing.md` | Append section | Team participation: final validation gate |
| `.claude/agents/release-maintenance.md` | Append section | Team participation: release pipeline, sequential awareness |
| `.claude/agents/user-management.md` | Append section | Team participation: commercialization tasks, keychain handoff |
| `.claude/agents/feature-planning.md` | Rewrite + append | Team Lead Protocol: task creation, peer assignment, monitoring |
| `CLAUDE.md` | Modify rules + table | Rules 7-8 expanded, teamwork.md in knowledge table |
| `MEMORY.md` | Append section | Persistent memory of team-first patterns |

**Total: 12 files (1 new, 11 modified). All markdown. No Swift code changes.**
