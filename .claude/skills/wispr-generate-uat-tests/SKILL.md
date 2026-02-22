---
name: wispr-generate-uat-tests
description: "Use when a feature has been implemented and needs UAT test scenarios generated. Given a feature spec from docs/feature-requests/, systematically enumerate all test scenarios covering happy paths, edge cases, negative tests, state transitions, and timing-dependent behavior."
---

# Generate UAT Test Scenarios from Feature Spec

## When to Use

After implementing a feature, BEFORE declaring it complete. This skill generates comprehensive behavioral test scenarios that verify the feature actually works as a user would experience it.

## Input

A feature spec file from `docs/feature-requests/NNN-feature-name.md`, or a bug report / feature description.

## Process

### Step 1: Extract Inputs, Outputs, and State

Read the feature spec and identify:
- **Actors**: Who triggers this? (user via hotkey, user via menu, user via settings, system timer)
- **Inputs**: What actions trigger the feature? (key press, click, setting change, time elapsed)
- **Outputs**: What should the user observe? (UI change, clipboard content, overlay, sound)
- **State preconditions**: What state must the app be in? (idle, recording, transcribing)
- **State postconditions**: What state should the app be in after?

### Step 2: Generate Scenarios Using 6 Techniques

For each feature, systematically apply ALL of these:

#### A. Happy Path
The golden path where everything works perfectly.
```
GIVEN [all preconditions met]
WHEN [user performs the action]
THEN [expected outcome occurs]
```

#### B. Equivalence Partitioning
Divide inputs into classes:
- Different trigger methods (hotkey vs menu vs button)
- Different app states when triggered
- Different settings configurations
- Different recording modes (toggle vs push-to-talk)

#### C. Boundary Value Analysis
Test at the edges:
- Immediate action (press and release < 100ms)
- Action at state transition boundaries
- Maximum/minimum values for any setting
- Empty/null input cases

#### D. State Transition Coverage
For each state in the pipeline (idle, recording, transcribing, polishing, complete, error):
- What happens if the feature is triggered in THIS state?
- Is the transition valid? Should it be blocked? Should it be queued?

Use this matrix template:
```
| Current State  | Action         | Expected Result          | Side Effects to Verify        |
|----------------|----------------|--------------------------|-------------------------------|
| .idle          | [feature]      | [expected]               | [verify these things]         |
| .recording     | [feature]      | [expected]               | [verify these things]         |
| .transcribing  | [feature]      | [expected]               | [verify these things]         |
| .polishing     | [feature]      | [expected]               | [verify these things]         |
| .complete      | [feature]      | [expected]               | [verify these things]         |
| .error         | [feature]      | [expected]               | [verify these things]         |
```

#### E. Negative Testing
What should NOT happen:
- Feature triggered without required permissions
- Feature triggered with invalid configuration
- Feature triggered during an incompatible operation
- Repeated rapid triggering (double-tap, spam-click)

#### F. Sequence/Interaction Testing
How does this feature interact with other features?
- Feature A then Feature B in rapid succession
- Feature A during Feature B
- Feature A, cancel, Feature A again (clean state recovery)

### Step 3: Write Given/When/Then Acceptance Criteria

For each scenario, write precise acceptance criteria following these rules:

1. **Quantify timing**: "within 500ms" not "quickly"
2. **Name exact states**: `.recording` not "recording mode"
3. **Multiple verification points**: check state AND visual AND data
4. **Specify preconditions completely**: settings, permissions, prior state
5. **One behavior per THEN clause**

### Step 4: Classify by Priority

| Priority | Criteria | Example |
|----------|----------|---------|
| P0 (Critical) | Feature completely broken if this fails | Happy path, basic cancel |
| P1 (High) | Significant user impact | Edge cases, permission failures |
| P2 (Medium) | Inconvenient but workaround exists | Visual glitches, timing |
| P3 (Low) | Cosmetic or unlikely | Multi-monitor, rare sequences |

### Step 5: Map to Verification Layers

For each test, specify which verification layers are needed:

| Layer | When to Use |
|-------|-------------|
| **AX tree value** | State changes, element enabled/disabled, text content |
| **AX tree structure** | Element appears/disappears, window opens/closes |
| **CGEvent simulation** | Hotkey triggers, button clicks, keyboard input |
| **Clipboard check** | Paste operations, clipboard save/restore |
| **Screenshot** | Visual appearance, overlay visibility |
| **Log check** | Internal state transitions, error paths |
| **Process metrics** | Memory leaks, CPU spikes, process survival |

## Output Format

Generate a markdown file at `Tests/UITests/scenarios/NNN-feature-name.md` with:

```markdown
# UAT Scenarios: [Feature Name]

## Feature Summary
[1-2 sentence description]

## Test Scenarios

### P0: Critical

#### test_[feature]_happy_path
**Suite**: [suite_name]
**Layers**: AX value, CGEvent, clipboard
```
GIVEN [preconditions]
WHEN [action]
THEN [expected outcome 1]
  AND [expected outcome 2]
```

#### test_[feature]_edge_case
...

### P1: High
...

### P2: Medium
...

## State Transition Matrix
[filled in matrix from Step 2D]

## Negative Test Checklist
- [ ] Triggered without permission X
- [ ] Triggered in invalid state Y
- [ ] Rapid double-trigger
- [ ] Cancel mid-operation
```

## Example: Cancel Hotkey (001)

For the ESC cancel feature, this process would have generated:

- **P0**: ESC cancels toggle-mode recording (happy path)
- **P0**: ESC cancels push-to-talk recording
- **P0**: ESC cancels menu-bar-initiated recording (**this is the bug we missed**)
- **P1**: ESC is no-op when idle
- **P1**: ESC does not write to clipboard on cancel
- **P1**: Rapid start-cancel-start sequence
- **P1**: ESC during .transcribing state (should be no-op)
- **P2**: ESC with other modifiers held
- **P2**: ESC when app is not frontmost (global monitor)
- **P3**: Custom cancel key (non-ESC) configured
