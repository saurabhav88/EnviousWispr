# Smart UAT v2 — Faster, Visual, Context-Aware

## Problem Statement

Our smart UAT is a **fast guardrail for an AI coding agent** — not a QA suite. It needs to confirm in 10-30 seconds that the agent didn't obviously break something. Today it can only check AX tree state (element exists, value changed, enabled/disabled). It cannot:

- Verify **visual changes** ("make the logo bigger" → is it actually bigger?)
- Assert **element ordering** ("move setting X above setting Y" → did it move?)
- Do **bulk copy verification** ("does screen text match the mockup?")
- Run **cross-flow data checks** ("API key entered in onboarding → present in Settings?")
- Validate **complex workflows fast** (onboarding screen 1→2→3 in one sweep)

The test scenarios are endless and app-specific. The uat-generator agent needs richer primitives and better instructions to handle them all.

## Design Principles

1. **30-second budget** — every test must complete within this window
2. **Primitives, not tests** — we add capabilities to the framework; the LLM generates the tests
3. **The generator is the bottleneck** — it needs to know what's possible so it can write the right tests
4. **Visual ≠ pixel diff** — use AX frame (points) for ALL size/position assertions. Screenshots are for human review only, never for geometric math
5. **Polling, not sleeping** — `ctx.wait()` is deprecated. ALL waits must use `wait_for_condition()` on a specific state change
6. **Spatial proximity for controls** — find labeled controls (toggles, pickers, text fields) by locating the label element first, then searching for the nearest control of the expected role

## Changes

### Phase 1: New Primitives in `ui_helpers.py`

#### 1a. Position & Ordering Assertions

The AI agent often rearranges UI. We need to assert "X is above Y" or "X moved from position A to position B."

```python
def element_position(element) -> tuple[float, float]:
    """Return (x, y) top-left of element in points."""

def element_frame(element) -> dict:
    """Return {x, y, width, height} of element in points.
    ALL size/position assertions use this — never pixel-based measurements.
    Points are display-independent (no Retina scaling issues)."""

def is_above(element_a, element_b) -> bool:
    """True if element_a's y-center < element_b's y-center (points)."""

def is_left_of(element_a, element_b) -> bool:
    """True if element_a's x-center < element_b's x-center (points)."""

def get_element_order(parent, role=None) -> list:
    """Return children of parent matching role, sorted by y-position (top-to-bottom).
    Uses element_frame for positioning, NOT AX tree order (which may differ for ZStack)."""
```

Add to `uat_runner.py` assertion helpers:
```python
def assert_element_above(pid, elem_a_kwargs, elem_b_kwargs, msg=None):
    """Assert element A is visually above element B.
    Fallback: if AX tree order is ambiguous, uses paired is_above() check."""

def assert_element_order(pid, role, expected_titles_or_values, msg=None):
    """Assert elements of given role appear in the expected top-to-bottom visual order.
    Uses element_frame y-position, not AX tree child order."""
```

#### 1b. Bulk Text Extraction

For copy verification — one AX traversal, all visible text.

```python
def get_all_visible_text(element, max_depth=10) -> list[str]:
    """Walk AX tree, return all non-empty AXValue, AXTitle, and AXDescription strings."""

def assert_text_present(pid, expected_strings: list[str], msg=None):
    """Assert all expected strings appear somewhere in the visible AX text."""

def assert_text_absent(pid, unexpected_strings: list[str], msg=None):
    """Assert none of the unexpected strings appear in visible AX text."""
```

#### 1c. Element-Focused Screenshots (Visual Review Only)

Extend `screenshot_verify.py` to capture a single element's bounding box.
**These are for human/agent visual review — NOT for geometric assertions.**
All size/position checks use `element_frame()` (points) instead.

```python
def capture_element(element, name: str) -> str:
    """Screenshot just this element's bounding box. Returns path.
    Uses screencapture -R with frame converted to screen pixels.
    For visual review only — use element_frame() for size assertions."""
```

Add to `uat_runner.py`:
```python
def assert_element_visible_in_window(pid, role, title, window_title=None, msg=None):
    """Assert element's frame is within the window's visible bounds (not clipped/offscreen).
    Uses element_frame() points comparison — no screenshots needed."""
```

#### 1d. Spatial Proximity Control Locator

Find form controls (toggles, pickers, text fields) by their spatial relationship to labels.
More resilient than parent/sibling AX tree traversal.

```python
def find_control_for_label(element, label_text: str, control_role: str,
                           search_direction="right_or_below", max_distance=200) -> element:
    """Find a control near a label using spatial proximity.
    1. Find AXStaticText with matching value/title
    2. Get its frame
    3. Search for nearest element of control_role within max_distance points
    4. Prefer elements to the right (same row) or below (next row)
    Returns the control element or None."""
```

#### 1e. `wait_for_condition()` Primitive

Replace ALL sleep-based patterns. `ctx.wait()` is deprecated.

```python
def wait_for_condition(predicate, timeout=3.0, interval=0.2, description="condition") -> bool:
    """Poll predicate until True or timeout. Returns True/False.
    Default interval=0.2s (not 0.1s) to avoid CPU spikes during parallel runs.
    Default timeout=3.0s (not 5.0s) to stay within 30s test budget."""

# Refactor existing wait_for_element, wait_for_element_gone, wait_for_value
# to use wait_for_condition internally (non-breaking API change)
```

#### 1f. Pre-Test Environment Validation

Sanity-check the test environment before running.

```python
def validate_test_environment(pid) -> dict:
    """Check environment preconditions. Returns dict of checks.
    - screen_resolution: current display resolution
    - app_frontmost: is EnviousWispr the frontmost app?
    - window_count: number of app windows
    - accessibility_granted: can we read AX tree?
    Logs warnings for unexpected conditions, does not fail."""
```

### Phase 2: New TestContext Methods

Add high-level convenience methods to `TestContext` so generated tests are concise.

```python
# In TestContext class:

def get_all_text(self, window_title=None) -> list[str]:
    """Get all visible text from app or specific window."""

def assert_text_on_screen(self, *expected: str):
    """Assert all strings visible somewhere in current window."""

def assert_text_not_on_screen(self, *unexpected: str):
    """Assert strings NOT visible."""

def element_is_above(self, elem_a_kwargs, elem_b_kwargs) -> bool:
    """Check if element A is visually above element B."""

def get_element_size(self, role=None, title=None, description=None) -> tuple[float, float]:
    """Return (width, height) in POINTS from element_frame().
    Points are display-independent — no Retina scaling issues."""

def screenshot_element(self, role=None, title=None, description=None, name="element") -> str:
    """Capture screenshot of specific element for visual review. Returns path.
    NOT for size assertions — use get_element_size() instead."""

def read_picker_value(self, label_text: str) -> str:
    """Find picker by spatial proximity to its label, return current selection text.
    Uses find_control_for_label(label_text, "AXPopUpButton")."""

def read_toggle_state(self, label_text: str) -> bool:
    """Find toggle by spatial proximity to its label, return True/False.
    Uses find_control_for_label(label_text, "AXCheckBox")."""

def read_text_field(self, label_text: str) -> str:
    """Find text field by spatial proximity to its label, return current value.
    Uses find_control_for_label(label_text, "AXTextField")."""

def set_cache(self, key: str, value):
    """Store a value for use later in the same test (cross-flow state).
    Example: read API key on screen 1, verify on screen 2."""

def get_cache(self, key: str, default=None):
    """Retrieve a cached value set earlier in the same test."""
```

**Deprecated:**
```python
def wait(self, seconds):
    """DEPRECATED. Use wait_for_condition() or assertion polling instead.
    Logs a deprecation warning when called. Will be removed in v3."""
```

### Phase 3: Update uat-generator Agent

Update `.claude/agents/uat-generator.md` with:

#### 3a. New Capability Reference Section

Tell the generator what new primitives exist and when to use them:

```markdown
## Available Verification Capabilities

### Position & Order (use for: "move X above Y", "reorder settings")
- `ctx.element_is_above({"role": "AXStaticText", "value": "A"}, {"role": "AXStaticText", "value": "B"})`
- `assert_element_order(pid, role="AXStaticText", expected_titles_or_values=["First", "Second", "Third"])`
- `assert_element_above(pid, {"title": "API Key"}, {"title": "Model Selection"})`

### Visual Size (use for: "make logo bigger", "increase font size")
- `size = ctx.get_element_size(role="AXImage", description="AppLogo")` — returns (width, height) in POINTS
- `assert size[0] > 100, "Logo should be wider than 100pt"`
- NEVER use screenshots for size assertions — always use get_element_size() (points, Retina-safe)

### Copy & Text (use for: "update button text", "verify mockup copy", "check model names")
- `ctx.assert_text_on_screen("Gemini 2.5 Pro", "GPT-4o", "Claude Sonnet")`
- `ctx.assert_text_not_on_screen("deprecated_model_name")`
- `all_text = ctx.get_all_text()` — one AX traversal, all visible strings

### Form State (use for: "verify API key carried over", "check default selection")
- `value = ctx.read_picker_value("AI Model")` — finds picker by spatial proximity to label
- `state = ctx.read_toggle_state("Auto-paste")` — finds toggle by spatial proximity to label
- `text = ctx.read_text_field("API Key")` — finds text field by spatial proximity to label

### Cross-Flow State (use for: data that must persist across screens/flows)
- `ctx.set_cache("api_key", key_value)` — store value during one screen
- `stored = ctx.get_cache("api_key")` — retrieve on another screen
- Use for: onboarding → settings data persistence, form → confirmation checks

### Workflow Validation (use for: onboarding flows, multi-screen sequences)
- Chain: `assert_element_appears → action → assert_element_disappears → assert_element_appears`
- Single function, no per-screen overhead
- NEVER use ctx.wait() — always poll for the expected state change
- Always validate final state, not intermediate steps
```

#### 3b. Test Pattern Examples

Add concrete examples the generator can follow:

```markdown
## Test Patterns for Common Requests

### "Move X above Y" / "Reorder settings"
```python
@uat_test("verify_setting_order", suite="settings", context="settings")
def test_setting_reordered(ctx):
    """GIVEN the General settings tab is open,
    WHEN the user views the settings,
    THEN 'Auto-paste' appears above 'Launch at Login'.
    """
    ctx.ensure_tab_selected("General")
    assert_element_above(ctx.pid,
        {"role": "AXStaticText", "value": "Auto-paste"},
        {"role": "AXStaticText", "value": "Launch at Login"})
```

### "Confirm models are showing in picker"
```python
@uat_test("verify_gemini_models", suite="polish", context="settings")
def test_gemini_models_visible(ctx):
    """GIVEN the Polish settings tab is open,
    WHEN the AI provider is Gemini,
    THEN the model picker contains expected Gemini models.
    """
    settings_win = ctx.ensure_tab_selected("Polish")
    ctx.assert_text_on_screen("Gemini 2.5 Pro", "Gemini 2.0 Flash")
```

### "API key entered in onboarding carries to Settings"
```python
@uat_test("api_key_persists_post_onboarding", suite="onboarding", context="none")
def test_api_key_carries_over(ctx):
    """GIVEN an API key was entered during onboarding,
    WHEN the user opens Settings > Polish,
    THEN the API key field contains the same value.
    """
    settings_win = ctx.ensure_tab_selected("Polish")
    key_value = ctx.read_text_field("API Key")
    assert key_value and len(key_value) > 10, f"API key not carried over: '{key_value}'"
```

### "Confirm onboarding flow works end-to-end"
```python
@uat_test("onboarding_happy_path", suite="onboarding", context="none")
def test_onboarding_flow(ctx):
    """GIVEN onboarding is triggered,
    WHEN the user completes all screens,
    THEN the app reaches the main state.
    """
    # Screen 1 → 2
    assert_element_appears(ctx.pid, title="Welcome", timeout=3)
    ctx.click_element(role="AXButton", description="Continue")
    assert_element_disappears(ctx.pid, title="Welcome", timeout=2)

    # Screen 2 → 3
    assert_element_appears(ctx.pid, title="Setting Up", timeout=3)
    ctx.click_element(role="AXButton", description="Continue")

    # Screen 3 → Done
    assert_element_appears(ctx.pid, title="Ready", timeout=3)
    ctx.click_element(role="AXButton", description="Get Started")
    assert_element_disappears(ctx.pid, title="Ready", timeout=2)
```

### "Make the logo bigger"
```python
@uat_test("verify_logo_size", suite="main_window", context="none")
def test_logo_size_increased(ctx):
    """GIVEN the main window is visible,
    WHEN the logo has been resized,
    THEN the logo width is greater than the previous size.
    """
    size = ctx.get_element_size(role="AXImage", description="AppLogo")
    assert size[0] >= 120, f"Logo width {size[0]}pt is less than expected 120pt"
```

### "Cross-flow data persistence"
```python
@uat_test("api_key_cross_flow", suite="onboarding", context="none")
def test_api_key_persists_across_flows(ctx):
    """GIVEN an API key is visible in onboarding,
    WHEN the user completes onboarding and opens Settings,
    THEN the same key appears in the API Key field.
    """
    # Read from onboarding screen
    key = ctx.read_text_field("API Key")
    ctx.set_cache("onboarding_key", key)

    # Complete onboarding...
    ctx.click_element(role="AXButton", description="Get Started")
    assert_element_disappears(ctx.pid, title="Setup", timeout=3)

    # Verify in Settings
    ctx.ensure_tab_selected("Polish")
    settings_key = ctx.read_text_field("API Key")
    assert settings_key == ctx.get_cache("onboarding_key"), \
        f"Key mismatch: onboarding='{ctx.get_cache('onboarding_key')}' settings='{settings_key}'"
```
```

#### 3c. Decision Guidance

Add a section helping the generator choose the RIGHT verification for each scenario:

```markdown
## Choosing Verification Strategy

| Change Type | Verification | Example |
|------------|-------------|---------|
| Element moved/reordered | `assert_element_above` / `assert_element_order` | "Move API Key above Model picker" |
| Size changed | `ctx.get_element_size()` + comparison (POINTS, Retina-safe) | "Make the logo bigger" |
| Text content changed | `ctx.assert_text_on_screen()` | "Update button label to 'Save'" |
| Models/options in picker | `ctx.assert_text_on_screen()` on picker items | "Show Gemini models" |
| Toggle/setting value | `ctx.read_toggle_state()` / `ctx.read_picker_value()` | "Default auto-paste to ON" |
| Cross-flow data | `ctx.set_cache()` + `ctx.read_text_field()` after navigation | "API key from onboarding in Settings" |
| Multi-screen flow | Chain of appear/disappear/click (NO ctx.wait()) | "Onboarding screens 1→2→3" |
| Element visibility | `assert_element_appears/disappears` | "Show debug panel when toggled" |
| Element state | `assert_element_enabled/disabled` | "Disable Save when no changes" |

### NEVER DO:
- `ctx.wait(N)` — DEPRECATED. Always poll for expected state change
- Screenshot-based size assertions — use `ctx.get_element_size()` (points)
- Assume AX tree child order = visual order — use `element_frame()` y-position
```

### Phase 4: Update `wispr-run-smart-uat` Skill

Update `.claude/skills/wispr-run-smart-uat/SKILL.md`:

- In the "SETTINGS UI ARCHITECTURE" section passed to the generator, add the new primitives reference
- Add a note: "When scope includes visual/layout changes, instruct the generator to use position assertions and element size checks, not just existence checks"
- Add the new imports to the template: `from ui_helpers import ... element_frame, is_above, is_left_of, get_element_order, get_all_visible_text, find_control_for_label, wait_for_condition`

### Phase 5: Speed Audit & ctx.wait() Deprecation

1. **Deprecate `ctx.wait(N)`** — log warning on every call, point to `wait_for_condition`
2. **Refactor existing waits** — `wait_for_element`, `wait_for_element_gone`, `wait_for_value` now use `wait_for_condition` internally
3. **Reduce default timeouts** — 3.0s default (was 5-10s), 0.2s poll interval (was 0.3s)
4. **Add timeout parameter** to new TestContext methods so the generator can tune per-assertion
5. **Pre-test environment check** — run `validate_test_environment()` at start of each run, log warnings

## File Changes Summary

| File | Action | What |
|------|--------|------|
| `Tests/UITests/ui_helpers.py` | Edit | Add position/ordering, `get_all_visible_text()`, `find_control_for_label()`, `wait_for_condition()`, `validate_test_environment()` |
| `Tests/UITests/uat_runner.py` | Edit | Add assertion helpers, new TestContext methods, `set_cache/get_cache`, deprecate `ctx.wait()` |
| `Tests/UITests/screenshot_verify.py` | Edit | Add `capture_element()` (visual review only) |
| `.claude/agents/uat-generator.md` | Edit | Add capability reference, test patterns, decision guidance, deprecation warnings |
| `.claude/skills/wispr-run-smart-uat/SKILL.md` | Edit | Reference new primitives in generator dispatch, update import template |

## Implementation Order

1. **Phase 1** (primitives) — foundation everything else depends on
2. **Phase 2** (TestContext) — convenience layer on top of primitives
3. **Phase 3** (generator update) — teach the LLM what's now possible
4. **Phase 4** (skill update) — pass new context to generator
5. **Phase 5** (speed audit) — optimize existing patterns, deprecate ctx.wait()

## What This Does NOT Include

- Pixel-diff mockup comparison (too slow, too brittle)
- `element_visual_size()` from screenshots (Retina scaling trap — use `element_frame()` instead)
- Selenium/headless browser for HTML mockup rendering (overkill)
- Declarative YAML test plans (adds indirection without value for our use case)
- Localization, security, or performance testing (out of scope per design)
- Refactoring uat_runner.py into separate modules (acknowledged debt, not blocking yet)

## Success Criteria

After implementation, the uat-generator should be able to handle ALL of these scenarios with the right test:

- "Move the settings from the bottom of the page to the top" → `assert_element_order` / `assert_element_above`
- "Confirm Gemini models are showing in polish" → `ctx.assert_text_on_screen("Gemini 2.5 Pro")`
- "Make the logo bigger" → `ctx.get_element_size()` comparison (points, Retina-safe)
- "Push to talk, wait, check audio captured in history" → workflow chain with `assert_element_appears`
- "API key in onboarding carries to Settings" → `ctx.set_cache()` + `ctx.read_text_field()` cross-flow
- "Button text should say 'Save Changes'" → `ctx.assert_text_on_screen("Save Changes")`
- "Debug toggle should be OFF by default" → `ctx.read_toggle_state("Enable debug mode")` == False
