# Team Orchestration

How and when to use Agent Teams (TeamCreate + shared task lists + SendMessage).

## Decision Matrix — Teams vs Parallel Task

| Scenario | Use | Why |
| -------- | --- | --- |
| Feature implementation (2+ agents) | TeamCreate | Sequential deps, peer communication needed |
| Bug fix spanning 2+ source directories | TeamCreate | Coordinated diagnosis + fix + validation |
| Release process | TeamCreate | Multi-step pipeline, needs coordination |
| Quality/security audit | TeamCreate | Systematic review with build validation |
| Refactor touching multiple domains | TeamCreate | Peer agents must see each other's output |
| Quick factual lookup (1 agent, 1 question) | Parallel Task | Fire-and-forget, no coordination |
| Independent searches across 2-3 agents | Parallel Task | No dependencies between results |
| Single-skill invocation | Skill tool | Not an agent task at all |
| Clarifying question to user | AskUserQuestion | No agent needed |

**Rule of thumb:** If 2+ agents whose outputs depend on each other → TeamCreate. Agents work in complete isolation → parallel Task.

## Standard Team Compositions

### feature-team

**Trigger:** Any feature request, multi-file feature, or cross-domain change.

| Name | Agent | Role |
| ---- | ----- | ---- |
| planner | feature-planning | Break down requirements, sequence work |
| {domain} | varies | Domain-specific implementation |
| builder | build-compile | Compile validation, dependency fixes |
| validator | testing | Smoke test, UI test, benchmark |

Add **auditor** (quality-security) if feature touches concurrency, secrets, or API keys.

### release-team

**Trigger:** Tagged release, distribution build, changelog generation.

| Name | Agent | Role |
| ---- | ----- | ---- |
| releaser | release-maintenance | Package, sign, bundle, changelog |
| auditor | quality-security | Pre-release security scan |
| builder | build-compile | Release build validation |
| validator | testing | Final smoke test + UI verification |

### fix-team

**Trigger:** Bug fix spanning 2+ source directories.

| Name | Agent | Role |
| ---- | ----- | ---- |
| fixer | domain agent (varies) | Diagnose and fix the bug |
| builder | build-compile | Compile validation |
| validator | testing | Regression test |

### audit-team

**Trigger:** Pre-release quality check, security review.

| Name | Agent | Role |
| ---- | ----- | ---- |
| auditor | quality-security | Concurrency, secrets, Sendable audit |
| builder | build-compile | Validate fixes compile |
| validator | testing | Run full test suite |

## Team Lifecycle

```
1. CREATE      → Coordinator calls TeamCreate
2. SPAWN       → Coordinator spawns teammates via Task (team_name + name + subagent_type)
3. TASKS       → Coordinator or lead teammate creates tasks via TaskCreate
4. ASSIGN      → Tasks assigned via TaskUpdate with owner
5. EXECUTE     → Teammates work on tasks, mark complete, claim next
6. COMMUNICATE → Teammates use SendMessage for peer coordination
7. COMPLETE    → All tasks done → coordinator sends shutdown_request
8. CLEANUP     → Coordinator calls TeamDelete
```

## Coordinator Protocol

The main agent (team lead) follows these 10 responsibilities:

1. **Classify the task** — consult the decision matrix above.
2. **Choose composition** — pick from standard teams, adapt if needed.
3. **Create the team** — TeamCreate with a descriptive name.
4. **Spawn teammates** — Task tool with `team_name`, `name`, `subagent_type`.
5. **Create task breakdown** — TaskCreate for each discrete work item.
6. **Assign first-wave tasks** — TaskUpdate with `owner` for non-blocked tasks.
7. **Monitor** — messages from teammates are auto-delivered; no polling needed.
8. **Unblock** — reassign stuck tasks, spawn additional teammates if needed.
9. **Shutdown** — SendMessage `shutdown_request` to each teammate.
10. **Cleanup** — TeamDelete to remove team and task files.

**The coordinator NEVER does implementation work.** It classifies, delegates, coordinates, and summarizes.

## Teammate Protocol

Any agent spawned as a teammate follows these 9 steps:

1. **Discover peers** — Read `~/.claude/teams/{team-name}/config.json`.
2. **Check tasks** — TaskList for assigned tasks.
3. **Claim work** — If unassigned tasks match your domain, claim with TaskUpdate (lowest ID first).
4. **Execute** — Do the work using skills and domain knowledge.
5. **Mark complete** — TaskUpdate to set completed, then immediately check TaskList for next task.
6. **Communicate results** — SendMessage to coordinator with summary.
7. **Peer messaging** — If issue falls in another agent's domain, SendMessage directly to that peer.
8. **Create subtasks** — If work reveals additional needs, TaskCreate.
9. **Idle gracefully** — After sending a message, going idle is normal. The system notifies the coordinator automatically.

## Communication Patterns

| From | To | When | Method |
| ---- | -- | ---- | ------ |
| Coordinator | One teammate | Task assignment, answer question | SendMessage (DM) |
| Coordinator | All teammates | Critical blocker, abort, direction change | SendMessage (broadcast) — rare |
| Teammate | Coordinator | Task complete, blocker found, question | SendMessage (DM) |
| Teammate | Peer teammate | Need their output, found issue in their domain | SendMessage (DM) |

**Never broadcast for routine updates.** DM the coordinator instead.

## Anti-Patterns

| Don't | Do Instead |
| ----- | ---------- |
| Spawn parallel Tasks when agents need each other's output | TeamCreate so they can communicate |
| Use TeamCreate for a single quick lookup | Parallel Task — it's faster |
| Have coordinator implement code | Spawn a teammate to do it |
| Broadcast routine status updates | DM the coordinator only |
| Let teammates go idle without checking TaskList first | Always check for next task before going idle |
| Create a team of 1 | Use parallel Task for single-agent work |
