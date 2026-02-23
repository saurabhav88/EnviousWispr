# Plan: Redesign Smart UAT Step 3 — File-Targeted Execution

## Context

`wispr-run-smart-uat` step 3 runs ALL generated tests via `--generated-only`, regardless of what the generator just created. A trivial change triggers 12+ unrelated tests from prior work. The "reusable test library" concept in `generated/` doesn't work — tests are gitignored (ephemeral), the generator always creates fresh tests per diff, and the runner can't filter by relevance.

**Fix:** Add file-targeted execution to the runner (`--files`), update the skill to pass only the just-generated files, delete legacy generated tests, and clean up all docs that reference the broken library concept.

## Part A: Runner — File-Targeted Execution

### `Tests/UITests/uat_runner.py`

#### a) Defer auto-discovery (refactor lines 937-955)

Move the module-level auto-discovery block into a function. Guard against duplicate imports with a set tracking normalized full paths (not just filenames — future-proof for subfolders):

```python
_loaded_generated = set()  # tracks normalized absolute paths of loaded files

def _discover_generated_tests():
    """Auto-discover and load all test_*.py files from generated/ directory."""
    gen_dir = os.path.join(os.path.dirname(__file__), "generated")
    if not os.path.isdir(gen_dir):
        return
    if __name__ == "__main__" and "uat_runner" not in sys.modules:
        sys.modules["uat_runner"] = sys.modules[__name__]
    for f in sorted(os.listdir(gen_dir)):
        if f.startswith("test_") and f.endswith(".py"):
            _load_single_file(os.path.join(gen_dir, f))
```

Remove the module-level execution of lines 937-955.

#### b) Add `_load_single_file(full_path)` helper

Shared by both discovery and file-targeted loading. Idempotent via `_loaded_generated`. Guards against missing `spec.loader`:

```python
def _load_single_file(full_path):
    """Load a single test file via importlib. Registers tests via @uat_test decorator."""
    import importlib.util
    normalized = os.path.realpath(full_path)
    if normalized in _loaded_generated:
        return  # idempotent — skip if already loaded
    filename = os.path.basename(normalized)
    spec = importlib.util.spec_from_file_location(filename[:-3], normalized)
    if spec is None or spec.loader is None:
        print(f"WARN: could not create loader for {filename}", file=sys.stderr)
        return
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        _loaded_generated.add(normalized)
    except Exception as e:
        print(f"WARN: failed to load generated test {filename}: {e}", file=sys.stderr)
```

#### c) Add `_load_test_files(file_paths)` for file-targeted mode

Validates paths before loading. Uses `realpath` + `commonpath` for safe directory containment (not `startswith` which has prefix false-positive bugs). Preserves deterministic ordering from the `--files` argument:

```python
_GENERATED_ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "generated"))

def _is_inside_generated(path):
    """Check if path is inside the generated/ directory. Resolves symlinks."""
    try:
        return os.path.commonpath([os.path.realpath(path), _GENERATED_ROOT]) == _GENERATED_ROOT
    except ValueError:
        return False  # different drives on Windows, or empty path

def _load_test_files(file_paths):
    """Load specific test files. Returns (registered_names_list, skipped_paths)."""
    if __name__ == "__main__" and "uat_runner" not in sys.modules:
        sys.modules["uat_runner"] = sys.modules[__name__]

    before = set(_TESTS.keys())
    skipped = []

    for path in file_paths:
        resolved = os.path.realpath(path)
        filename = os.path.basename(resolved)

        # Validation: must exist, be .py, match test_*.py, be inside generated/
        if not os.path.isfile(resolved):
            print(f"WARN: missing test file: {path}", file=sys.stderr)
            skipped.append(path)
            continue
        if not filename.startswith("test_") or not filename.endswith(".py"):
            print(f"WARN: invalid generated test path: {path}", file=sys.stderr)
            skipped.append(path)
            continue
        if not _is_inside_generated(resolved):
            print(f"WARN: path outside generated/ directory: {path}", file=sys.stderr)
            skipped.append(path)
            continue

        _load_single_file(resolved)

    # Preserve ordering: return as list in load order, not a set
    registered = [t for t in _TESTS if t not in before]
    return registered, skipped
```

#### d) Add `--files` argument + selector conflict detection

Add to `run` subparser:

```python
run_p.add_argument("--files", nargs="+", type=str,
                   help="Run only tests from these specific generated file paths")
```

In `cmd_run`, enforce mutually exclusive selectors:

```python
def cmd_run(args):
    # Selector conflict detection
    selectors = sum(bool(x) for x in [args.files, args.test, args.suite, args.generated_only])
    if selectors > 1:
        print("Error: --files, --test, --suite, and --generated-only are mutually exclusive.",
              file=sys.stderr)
        sys.exit(1)

    if args.files:
        registered, skipped = _load_test_files(args.files)
        test_names = registered  # already an ordered list
        if not test_names:
            print("No tests loaded from specified files.", file=sys.stderr)
            sys.exit(0)
    elif args.test:
        _discover_generated_tests()
        test_names = [args.test]
    elif args.suite:
        _discover_generated_tests()
        # existing suite logic...
    elif args.generated_only:
        _discover_generated_tests()
        # existing generated-only logic...
    else:
        _discover_generated_tests()
        test_names = list(_TESTS.keys())
```

#### e) Ensure `cmd_list` and `cmd_signatures` call discovery

Both must call `_discover_generated_tests()` at the top of their function body, since module-level discovery is removed.

## Part B: Skill — Use File-Targeted Execution

### `.claude/skills/wispr-run-smart-uat/SKILL.md`

#### Unified output format (used in both skill and agent docs)

```text
GENERATED_FILES:
- Tests/UITests/generated/test_foo.py
- Tests/UITests/generated/test_bar.py
```

Or when no tests are generated:

```text
GENERATED_FILES: []
```

This is the ONLY format — no comma-separated, no `none` string. Used identically in the skill instructions and the agent spec.

#### Updated step 2: Task prompt

Ask the generator to end its response with the `GENERATED_FILES:` block in the format above.

#### Updated step 3: Parsing and execution

Explicit instructions for the coordinator:

1. Read the agent's response. Find the `GENERATED_FILES:` block.
2. If the list is `[]` or the block is missing entirely: report "No tests needed — change has no testable UI impact." Skip execution.
3. If the list has file paths: verify each exists with `ls` before passing to `--files`.
4. Run only verified paths:

```bash
python3 Tests/UITests/uat_runner.py run --files <verified paths> --verbose 2>&1
```

**Fallback** (if `GENERATED_FILES:` block is unparseable): Fail closed with message "Could not determine generated files — run `/wispr-run-uat` manually if needed." Do NOT fall back to running all generated files (that recreates the original noise problem).

## Part C: Generator Agent — Formalize Output

### `.claude/agents/uat-generator.md`

Add `## Output Format` section requiring the unified format from Part B.

Remove the `_generated` suite suffix requirement (lines 105-113). Suite names can be whatever makes sense — `--files` handles scoping, not suite naming.

## Part D: Delete Legacy Generated Tests

### `Tests/UITests/generated/`

Delete:

- `test_unified_window_architecture.py`
- `test_app_lifecycle_settings_window_isolation.py`

Keep `.gitignore` and `__init__.py`.

## Part E: Clean Up Docs — Remove Stale References

| File | Line(s) | Fix |
| ---- | ------- | --- |
| `CLAUDE.md` | 13 | Update `--generated-only` example to `--files` usage |
| `.claude/knowledge/conventions.md` | 100 | Remove "persist in git as reusable test library" |
| `.claude/knowledge/architecture.md` | 93 | Remove "(persists in git as reusable test library)" |
| `.claude/agents/testing.md` | 151 | Update "runs generated only" to "runs file-targeted tests" |
| `.claude/agents/uat-generator.md` | 96-113 | Remove `_generated` suffix requirement |
| `MEMORY.md` | UAT section | Fix "persists in git" claim, update flow description |
| `docs/plans/2026-02-22-smart-uat-*.md` | — | Historical, leave as-is |

## Verification

### Core functionality

1. `run --files Tests/UITests/generated/test_foo.py --verbose` — loads and runs only that file
2. `run --generated-only --verbose` — still discovers and runs all (backward compat)
3. `run --verbose` — runs all static + generated
4. `list` — shows all tests including generated (regression check after refactor)

### Edge cases

5. Missing file: `run --files Tests/UITests/generated/does_not_exist.py` — warns, no crash, no tests run
6. Mixed valid + invalid: one real file + one missing + one outside `generated/` — only valid runs, invalids warn
7. Selector conflict: `run --files X --generated-only` — explicit error, exit 1
8. Import failure: syntax error in generated file — warns and continues
9. No tests generated: generator outputs `GENERATED_FILES: []`, skill skips step 3 cleanly
10. Full smart UAT flow: trivial change → 0-1 tests, not 12+
