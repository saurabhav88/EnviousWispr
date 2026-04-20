# Swift Prompt Drift Remediation Research

## 1. Problem recap

Today the offline eval in [scripts/eval/acceptance_gate.py](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/acceptance_gate.py) rebuilds production polish prompts in Python, while the user-facing logic lives in Swift under [Sources/EnviousWisprLLM/Prompting/](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/) and [Sources/EnviousWisprPostProcessing/CustomWordsManager.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprPostProcessing/CustomWordsManager.swift). That creates a predictable drift risk: prompt changes land in Swift first, and the eval harness can silently keep testing an older prompt shape.

## 2. Options

### Option A: Hidden Swift CLI prompt dumper

**Architecture sketch**

Add a small Swift CLI whose only job is to render the production prompt envelope and return it as JSON. It should call the same production path the app already uses for cloud providers: [DefaultPromptPlanner.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/DefaultPromptPlanner.swift), [OpenAIPromptBuilder.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/OpenAIPromptBuilder.swift), [GeminiPromptBuilder.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/GeminiPromptBuilder.swift), [GemmaPromptBuilder.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/GemmaPromptBuilder.swift), and [TranscriptAnalyzer.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/TranscriptAnalyzer.swift). For Apple Intelligence, the same CLI can expose the enriched production instruction from [LLMPolishStep.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprPipeline/LLMPolishStep.swift) instead of requiring Python to assemble `PolishInstructions.default + enrichment + custom vocab`. Python stays as the orchestration and judging layer, but stops owning prompt text.

**Tradeoffs**

- Latency: one subprocess call per case is acceptable for 1,590 cases if batched; one call per prompt would be too slow, so the CLI should accept many rows in one input file.
- Binary-size impact: low. This is a developer-only tool, similar in spirit to the existing [scripts/eval/apple_runner/](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/apple_runner/) package.
- Build-time coupling: moderate. Eval now depends on a built Swift helper, but only at dev/CI time, not in the shipped app.
- Debuggability: good. JSON prompt artifacts can be written alongside eval outputs, which makes “what prompt did we actually send?” easy to inspect.
- Ability to run eval without a full Swift build: reduced. Python-only eval disappears for prompt rendering; however, the build can stay scoped to a small helper package rather than the whole app product.

**Migration cost**

In [acceptance_gate.py](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/acceptance_gate.py), the mirrored prompt constants and builders would be removed or bypassed: `OPENAI_BASE`, `OPENAI_FORMATTING`, `OPENAI_TAIL`, `GEMINI_BASE`, `GEMINI_FORMATTING`, `USER_TEMPLATE`, `DEFAULT_CUSTOM_VOCAB`, `render_custom_vocab()`, `build_openai_system()`, `build_gemini_system()`, and the Apple `_build_afm_system_prompt()` path. The Python side would instead call the Swift dumper with transcript, provider, model, app context, language, and custom words, then pass the returned prompt straight to OpenAI/Gemini APIs. In [scripts/eval/apple_runner/](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/apple_runner/), either add a sibling executable or extend the existing package with a non-Apple mode that can emit prompts without invoking the connector.

**Verdict**

**Recommend.** It is the smallest change that removes the drift source while preserving the current evaluation architecture and keeping prompt logic owned by Swift.

---

### Option B: Swift sidecar service or batch bridge

**Architecture sketch**

Instead of a one-shot CLI, run a long-lived Swift helper process that accepts JSON requests and returns prompt envelopes for many cases over stdin/stdout. Internally it would still use the same production prompt code as Option A, but it would amortize startup cost and make large eval runs cheaper and cleaner. This could live beside the existing Apple runner and eventually become the single bridge between Python eval and Swift production logic.

**Tradeoffs**

- Latency: better than repeated CLI launches, especially if eval becomes a frequent CI job or grows beyond 1,590 cases.
- Binary-size impact: still low for shipping, but higher implementation complexity than a one-command dumper.
- Build-time coupling: same basic coupling as Option A, but operationally stronger because Python depends on protocol stability between the two processes.
- Debuggability: mixed. Once stable, it is efficient, but request/response protocol bugs are harder to inspect than a simple “run command, get JSON file.”
- Ability to run eval without a full Swift build: still no. You still need the Swift bridge built before eval.

**Migration cost**

[acceptance_gate.py](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/acceptance_gate.py) would change more deeply than in Option A because it would need bridge lifecycle management: start process, stream requests, handle partial failures, retry, and fall back if the helper dies mid-run. [scripts/eval/apple_runner/Sources/AppleIntelligenceRunner/main.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/apple_runner/Sources/AppleIntelligenceRunner/main.swift) would likely stop being “Apple-only bench runner” and become a more general eval bridge package with subcommands or protocol modes. This is still manageable, but it is real systems work, not just a helper command.

**Verdict**

**Conditional-recommend.** Choose this only if eval cadence is high enough that process startup cost and repeated Swift invocations are already a pain. If not, it is more architecture than the current problem needs.

---

### Option C: Python-to-Swift extension or dynamic library

**Architecture sketch**

Package the production prompt renderer as a Swift dynamic library or Python extension so Python can call Swift functions directly in-process. In theory this gives the eval harness “real Swift prompts” without a subprocess and could expose fine-grained APIs for prompt planning, mode analysis, and vocabulary rendering. In practice it creates a cross-language packaging surface the team now has to own.

**Tradeoffs**

- Latency: best at runtime once everything is built and loaded.
- Binary-size impact: not important for the app, but operational complexity goes up because the eval environment now needs compatible compiled artifacts, loader paths, and ABI discipline.
- Build-time coupling: highest of the options. Python eval becomes tightly coupled to Swift packaging details.
- Debuggability: weak. When this breaks, it tends to fail in less obvious ways than a CLI: import issues, loader issues, symbol issues, environment mismatches.
- Ability to run eval without a full Swift build: no. In fact this option usually makes setup stricter, not looser.

**Migration cost**

[acceptance_gate.py](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/acceptance_gate.py) would need a new native integration layer and packaging assumptions that do not exist today. [scripts/eval/apple_runner/](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/apple_runner/) would either become obsolete or need to coexist with an even more complex native bridge. This is a larger infrastructure change than the drift problem justifies.

**Verdict**

**Do-not-recommend.** It solves the narrow drift issue by introducing a bigger, more fragile dependency surface than the team needs.

## 3. Evidence we should collect before commitment

- How often do the Swift prompt builders change in practice?
  Current concern is high, but one month of actual change frequency would tell us whether a simple CLI is enough or whether a richer bridge is justified.
- How often does the 1,590-case eval run?
  If this is only run on PRs touching polish code, startup overhead matters less. If founders or CI run it many times per day, batching matters more.
- What is the actual cold-build and warm-build time for a small Swift helper package on CI machines?
  This is the key cost of any Swift-owned prompt source.
- Does the eval need to stay runnable on machines that cannot build the Swift package?
  If yes, that pushes toward keeping a fallback mode. If no, the cleanest answer is to make Swift build a hard prerequisite.
- How much of the real production path should the eval own?
  Prompt rendering only, or also mode selection, Apple enrichment, custom vocabulary filtering, and validator behavior.
- Is macOS already a hard requirement for the acceptance gate?
  The current Apple runner targets macOS 14. If the gate must also run on non-macOS CI later, the bridge shape should avoid accidental Apple-only coupling.

## 4. Current-best bet and why

**Current-best bet: Option A, the hidden Swift CLI prompt dumper.**

It fits the codebase as it exists today. The repo already has a working pattern for a Swift sidecar tool in [scripts/eval/apple_runner/Package.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/scripts/eval/apple_runner/Package.swift), and the actual prompt source of truth is already centralized in Swift in [DefaultPromptPlanner.swift](/Users/m4pro_sv/Developer/EnviousLabs/worktrees/target-6-drift-research/Sources/EnviousWisprLLM/Prompting/DefaultPromptPlanner.swift) plus the provider builders. That means the team can remove the risky Python mirror without redesigning the whole eval harness.

It also keeps the architecture honest. Swift continues to own prompt construction; Python continues to own corpus iteration, API calling, judging, and reporting. That is a clean boundary, easy to explain to a founder and easy to debug in CI.

## 5. Deferred questions

- Should the Swift bridge return only rendered prompts, or also the chosen `PolishMode` and prompt-family metadata for artifacting?
- Should Apple Intelligence use the same bridge as cloud providers, or remain a separate runner that also owns execution?
- Do we want a temporary fallback path if the Swift helper is missing, or should eval fail fast to avoid ever reintroducing silent drift?
- Should custom vocabulary in eval come from shipped defaults only, or also support corpus-specific overlays the way Python does today?
- How should custom prompt modes, especially `legacyTemplate`, be represented in the bridge API so the eval can still test those cases intentionally?
- When the prompt source changes, do we want the eval artifacts to always persist the exact rendered prompt JSON for auditability?
