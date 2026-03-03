# Phase 3 Implementation Plan: History View Settings Sidebar Layout Bug

**Date**: 2026-03-02
**Severity**: High — Navigation sidebar collapses when window is resized below ~714pt
**Root Cause**: HSplitView minimum width constraints (200 + 350 = 550pt) combined with NavigationSplitView sidebar (160pt min) exceed window minimum (560pt)

---

## 1. File to Modify

**Primary File:**
```
/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Main/HistoryContentView.swift
```

**Secondary File (required for robustness):**
```
/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/App/EnviousWisprApp.swift
```

---

## 2. Exact Code Changes

### Fix 1: HistoryContentView.swift (REQUIRED)

**Location**: Lines 14–24 (HSplitView children frame modifiers)
**File**: `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Main/HistoryContentView.swift`
**Target**: The `.frame()` modifiers on `TranscriptHistoryView()` and the `Group { ... }` detail pane

#### BEFORE
```swift
TranscriptHistoryView()
    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

Group {
    if let transcript = appState.activeTranscript {
        TranscriptDetailView(transcript: transcript)
    } else {
        StatusView()
    }
}
.frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)
```

#### AFTER
```swift
TranscriptHistoryView()
    .frame(minWidth: 120, idealWidth: 200, maxWidth: 280)

Group {
    if let transcript = appState.activeTranscript {
        TranscriptDetailView(transcript: transcript)
    } else {
        StatusView()
    }
}
.frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
```

**Change Summary:**
- **TranscriptHistoryView (Transcript List Panel)**:
  - `minWidth`: 200 → 120 (80pt reduction)
  - `idealWidth`: 250 → 200 (50pt reduction)
  - `maxWidth`: 300 → 280 (20pt reduction)

- **Detail Pane (TranscriptDetailView or StatusView)**:
  - `minWidth`: 350 → 260 (90pt reduction)
  - `idealWidth`: 500 → 420 (80pt reduction)
  - `maxWidth`: `.infinity` → `.infinity` (no change)

---

### Fix 2: EnviousWisprApp.swift — Raise Window Minimum Width (REQUIRED FOR ROBUSTNESS)

**File**: `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/App/EnviousWisprApp.swift`
**Location**: Window scene `.frame()` modifier on the `WindowGroup` or main window definition
**Target**: The line containing `.frame(minWidth: 560, minHeight: 400)`

#### BEFORE
```swift
.frame(minWidth: 560, minHeight: 400)
```

#### AFTER
```swift
.frame(minWidth: 580, minHeight: 400)
```

**Rationale:**
- Provides a 20pt buffer above the 560pt constraint sum (160 sidebar + 120 list + 260 detail + 20 chrome)
- Protects against divider hit-testing areas, future system UI changes, and minor rounding errors
- Without this buffer, the layout is mathematically correct but fragile (zero margin for error)
- The 20pt increase is imperceptible to users but provides critical engineering robustness
- This is a **required change**, not optional — per Gemini review, zero-margin layouts are brittle

---

## 3. Mathematical Verification

### Minimum Width Budget (560pt Window → MUST RAISE TO 580pt)

**Before Fix (BROKEN):**
```
NavigationSplitView sidebar min:  160pt
HSplitView transcript list min:   200pt
HSplitView detail pane min:       350pt
Chrome/dividers (~2pt × 2):       ~4pt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL MINIMUM REQUIRED:           714pt

Window minimum available:         560pt
DEFICIT:                         -154pt ✗
```

**After Frame Modifier Fix (INSUFFICIENT BUFFER):**
```
NavigationSplitView sidebar min:  160pt
HSplitView transcript list min:   120pt
HSplitView detail pane min:       260pt
Chrome/dividers (~20pt):          ~20pt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL MINIMUM REQUIRED:           560pt

Window minimum available:         560pt
MARGIN:                          ±0pt ⚠️ (ZERO BUFFER — FRAGILE)
```

**After Complete Fix: Raise Window minWidth to 580pt (ROBUST):**
```
NavigationSplitView sidebar min:  160pt
HSplitView transcript list min:   120pt
HSplitView detail pane min:       260pt
Chrome/dividers:                  ~20pt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL MINIMUM REQUIRED:           560pt

Window minimum available:         580pt
MARGIN:                          +20pt ✓ (BUFFER FOR ROBUSTNESS)
```

**Why the 20pt buffer is essential:**
- Hit-testing areas around dividers can expand beyond visible width (~2–3pt each)
- Future macOS releases may add system-level padding or UI chrome
- Running at exactly 560pt leaves zero margin for error and is brittle
- The 20pt buffer (560→580) is a standard engineering practice for resilient layouts

### Ideal Width Distribution (820pt Default Window)

**After Fix:**
```
NavigationSplitView sidebar ideal:  180pt (per .navigationSplitViewColumnWidth modifier)
HSplitView transcript list ideal:   200pt
HSplitView detail pane ideal:       420pt
Chrome/dividers:                    ~20pt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL AT IDEAL:                     820pt ✓

Window default width:               820pt
FIT:                               Perfect ✓
```

### Verification at Multiple Resolutions

| Window Width | Sidebar | Transcript | Detail | Chrome | Total | Status |
|---|---|---|---|---|---|---|
| 560 (min) | 160 | 120 | 260 | ~20 | 560 | ✓ Fits |
| 640 | 160 | 140 | 320 | ~20 | 640 | ✓ Fits |
| 720 | 170 | 170 | 350 | ~30 | 720 | ✓ Fits |
| 820 (default) | 180 | 200 | 420 | ~20 | 820 | ✓ Fits perfectly |
| 1000 | 190 | 250 | 530 | ~30 | 1000 | ✓ Fits, good spacing |

**Verification Method**: Frame modifiers use `minWidth`, `idealWidth`, and `maxWidth`. SwiftUI/AppKit will:
1. Never shrink below `minWidth` (hard constraint)
2. Try to use `idealWidth` at layout time
3. Allow growth up to `maxWidth`

All combinations satisfy `minWidth` constraints at and above 560pt.

---

## 4. Visual Test Plan

### Test 1: Minimum Window Width (560pt)

**Procedure:**
1. Build and launch app: `/wispr-rebuild-and-relaunch`
2. Navigate to **History** tab
3. Resize window to exactly **560pt width** (use menu: Window > Zoom Down or drag corner)
4. **Verify:**
   - Settings sidebar (left nav) is **visible** (not collapsed)
   - Transcript list (left pane of HSplitView) is **visible** at ~120pt width (narrow but readable)
   - Detail pane (right side) is **visible** at ~260pt (may be tight, but functional)
   - No panes are cut off or hidden

**Expected Result:** All three horizontal sections remain visible. Sidebar shows nav items. History tab renders completely.

---

### Test 2: Default Window Width (820pt)

**Procedure:**
1. Resize window to default width (820pt), or use Window > Zoom
2. **Verify:**
   - Settings sidebar: ideal width ~180pt (comfortable)
   - Transcript list: ideal width ~200pt (good readability)
   - Detail pane: ideal width ~420pt (spacious)
   - All content is well-spaced, no crowding

**Expected Result:** Layout is balanced and spacious. Transcript list shows full item previews. Detail view is uncluttered.

---

### Test 3: Intermediate Width (640pt)

**Procedure:**
1. Resize window to ~640pt width (user's common narrow size)
2. **Verify:**
   - All three sections remain visible
   - Sidebar is still present
   - Transcript list and detail pane are both functional (though narrower)

**Expected Result:** No collapse. User can still see settings sidebar while working with History.

---

### Test 4: Transcript List Content Legibility at 120pt

**Procedure:**
1. At 560pt window width, examine the transcript list pane closely
2. **Verify:**
   - Transcript titles are truncated intelligibly (no important info hidden beyond recovery)
   - Timestamps are readable or elided gracefully
   - Hover tooltips (if present) work
   - Item selection/highlighting is clear

**Expected Result:** Content is compact but not illegible. Users can still identify and select transcripts.

---

### Test 5: Detail Pane Content Legibility at 260pt

**Procedure:**
1. At 560pt window width, examine the detail pane (TranscriptDetailView or StatusView)
2. **Verify:**
   - Text wraps appropriately (not crammed onto one line)
   - Controls (buttons, text fields) are accessible
   - Vertical scrolling is smooth if content overflows
   - No content is clipped or hidden beyond recovery

**Expected Result:** Detail view is compact but usable. All controls are reachable.

---

### Test 6: Resizing Window — Continuous Feedback

**Procedure:**
1. Start at 560pt (minimum)
2. Slowly drag the window edge to make it wider (to 820pt and beyond)
3. **Verify:**
   - Sidebar remains visible at all widths
   - Panes grow smoothly without jumping
   - No flickering or layout thrashing
   - Ideal widths are reached at 820pt

**Expected Result:** Smooth resize behavior. Sidebar never collapses as window grows.

---

### Test 7: Programmatic Verification (Automated) — REQUIRED

**Purpose:** Ensure the fix is pixel-accurate and regression-protected for future changes.

**Procedure:**
1. Write or enhance a UITest in `Tests/UITests/generated/` that:
   - Launches the app
   - Navigates to **History** tab
   - Resizes the window to `580pt` width (the new minimum)
   - Uses accessibility API or `XCTest.XCUIApplication` to query frame sizes
   - Programmatically asserts:
     - `transcriptListPane.width >= 120.0` (at minimum constraint)
     - `detailPane.width >= 260.0` (at minimum constraint)
     - `transcriptListPane.width + detailPane.width + ~20 (chrome) <= 580`
   - Takes screenshots for visual confirmation

2. Execute: `python3 Tests/UITests/uat_runner.py run --files Tests/UITests/generated/<test>.py --verbose`

**Expected Result:** All programmatic assertions pass. Sidebar remains visible. Actual pane widths match the frame constraints.

---

## 5. Risk Assessment

### Eliminated Risk: Sidebar Still Collapses

**Status**: MITIGATED by implementing both Fix 1 AND Fix 2 (window minWidth increase)

By raising the window `minWidth` from 560 to 580, we provide a 20pt buffer that:
- Accounts for divider hit-testing areas and chrome variations
- Protects against future macOS system UI changes
- Makes the layout robust, not mathematically brittle
- Prevents AppKit's column-collapse heuristic from triggering

Per Gemini review: zero-margin layouts are fragile; the 20pt buffer is engineering best practice.

---

### Risk: Transcript List Too Narrow at 120pt Minimum

**Severity**: Low (now reduced by window minWidth increase)
**Likelihood**: Very Low — window minimum is now 580pt, so users cannot resize below this

**Analysis**:
- 120pt is still 8–10 characters of horizontal space (readable for short transcript titles)
- Transcript titles in the app are typically short ("Interview with Jane", "Product demo")
- If items are longer, the List naturally supports truncation + hover tooltips
- Users can grab the divider and manually expand the transcript pane toward its 280pt max

**Action if visual testing reveals poor legibility**:
- Raise `minWidth` of transcript list from 120 to 130pt
- Compensate by lowering detail pane `minWidth` from 260 to 250pt
- This trades 10pt from detail to list — negligible impact on 260pt detail view
- Retest with programmatic verification (Test 7)

---

### Risk: Detail Pane Too Narrow at 260pt Minimum

**Severity**: Low
**Likelihood**: Low — most detail pane content uses vertical layout and scales well

**Analysis**:
- TranscriptDetailView is primarily vertical (transcript text, buttons, controls)
- StatusView is a centered message ("No transcript selected")
- Both use `ScrollView` or `VStack` that wrap gracefully
- At 260pt, a typical form field or text editor has room for ~40–50 characters per line

**Action if visual testing reveals poor usability**:
- Increase detail pane `minWidth` from 260 to 280pt
- Reduce transcript list `minWidth` from 120 to 100pt
- Retest with programmatic verification (Test 7)
- As last resort, raise window `minWidth` to 600pt

---

### Risk: Reducing Ideal Widths Breaks Existing User Windows

**Severity**: Very Low
**Likelihood**: Very Low — ideal widths only affect initial open; user-resized panes persist in saved window state

**Mitigation**:
- SwiftUI remembers user-performed resize operations via NSWindowState (or equivalent on macOS)
- Users who have already resized the History panes will not see a change (saved state takes priority)
- Only new users opening History for the first time will see the new ideals (200 + 420)
- The new ideals are still well-balanced and comfortable at the 820pt default width

---

## 6. Post-Implementation Validation Steps

### Compilation & Build
1. **Edit Files**: Apply Fix 1 (HistoryContentView.swift lines 15 & 24) and Fix 2 (EnviousWisprApp.swift window frame)
2. **Compile**: `swift build`
3. **Bundle & Launch**: `/wispr-rebuild-and-relaunch` (automatically builds, bundles, launches, and runs smart UAT)

### Manual Visual Validation
4. **Manual UAT**: Execute Test Plan 1–6 above in sequence
   - Test 1: Minimum window width (580pt, not 560pt) — sidebar visible ✓
   - Test 2: Default width (820pt) — balanced spacing ✓
   - Test 3: Intermediate width (640pt) — all sections visible ✓
   - Test 4: Transcript list legibility at 120pt — readable titles ✓
   - Test 5: Detail pane legibility at 260pt — accessible controls ✓
   - Test 6: Continuous resize — smooth, no collapse ✓

### Automated Verification
5. **Programmatic UAT** (Test 7): Write and execute automated test to assert actual pane widths at minimum window size
   - Query frame sizes programmatically
   - Assert `transcriptList.width >= 120.0`
   - Assert `detailPane.width >= 260.0`
   - Report pass/fail with screenshots

### Regression Testing
6. **Smart UAT**: `wispr-run-smart-uat` (will generate tests for History view changes if they exist in scope)
7. **Tab Regression**: Switch to Settings, AudioSettings, SpeechEngine, other tabs — verify none are affected by window minWidth change
8. **Edge Case**: Test on secondary monitor at different resolutions — resize across multiple screens, verify consistent behavior

### Completion Criteria
- All visual tests pass (no sidebar collapse at any width >= 580pt)
- Programmatic tests assert correct frame sizes
- Smart UAT reports PASSED or SKIPPED (no failures)
- Zero regressions in other tabs
- Transcript list at 120pt and detail pane at 260pt are legible and functional

---

## 7. Revert/Recovery Plan (If Needed)

If visual testing reveals unacceptable legibility or usability problems:

### Recovery Option 1: Adjust Frame Minimums Only (Keep Window at 580pt)

If transcript list at 120pt or detail pane at 260pt is too narrow:

```swift
// ALTERNATIVE 1: Give more space to transcript list
TranscriptHistoryView()
    .frame(minWidth: 130, idealWidth: 210, maxWidth: 290)  // +10pt min

Group { ... }
    .frame(minWidth: 250, idealWidth: 410, maxWidth: .infinity)  // -10pt min

// ALTERNATIVE 2: Give more space to detail pane
TranscriptHistoryView()
    .frame(minWidth: 100, idealWidth: 190, maxWidth: 270)  // -20pt min

Group { ... }
    .frame(minWidth: 280, idealWidth: 430, maxWidth: .infinity)  // +20pt min
```

Then retest with the programmatic verification (Test 7).

### Recovery Option 2: Increase Window Minimum Further (As Last Resort)

If even the adjustments above don't provide enough space:

```swift
// In EnviousWisprApp.swift
.frame(minWidth: 600, minHeight: 400)  // Up from 580, adds another 20pt buffer
```

Then adjust inner pane minimums upward:

```swift
// In HistoryContentView.swift
TranscriptHistoryView()
    .frame(minWidth: 140, idealWidth: 210, maxWidth: 300)

Group { ... }
    .frame(minWidth: 300, idealWidth: 450, maxWidth: .infinity)
```

### Recovery Option 3: Complete Revert (Least Desirable)

```swift
// Revert HistoryContentView.swift to original
TranscriptHistoryView()
    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

Group { ... }
    .frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)

// Revert EnviousWisprApp.swift
.frame(minWidth: 560, minHeight: 400)
```

This will likely re-trigger the sidebar collapse at narrow widths, so it is the fallback of last resort. The intended fix (Option 1 or 2) is strongly preferred.

---

## 8. Success Criteria

All of the following must be satisfied before the fix is considered complete:

✓ **Sidebar remains visible at 580pt window width** (the new minimum)
✓ **Sidebar remains visible when resizing from 820pt down to 580pt** (continuous smoothness)
✓ **Transcript list is readable at 120pt minimum width** (visual test + legibility check)
✓ **Detail pane content is usable at 260pt minimum width** (all controls accessible)
✓ **No visual regressions in other tabs** (Settings, Audio, SpeechEngine, etc.)
✓ **Ideal widths at 820pt are balanced and spacious** (default view is comfortable)
✓ **Programmatic tests pass** (frame sizes verified by code, not just eyes)
✓ **Smart UAT passes or reports SKIPPED** (no behavioral failures)

---

## 9. Coordination Notes

**Exactly two files need to be modified** for this fix to work correctly:

**Required Changes:**
1. `HistoryContentView.swift` — Reduce HSplitView pane minimums (lines 15 & 24)
2. `EnviousWisprApp.swift` — Raise window minWidth from 560 to 580 (critical for robustness)

**No changes needed in:**
- `SettingsView.swift` — NavigationSplitView constraints remain appropriate as-is
- Other detail views (SpeechEngineSettingsView, AudioSettingsView, etc.) — Unaffected (no HSplitView)
- Audio pipeline, permissions, ASR modules — Unaffected
- Any other source file

**Estimated Time to Complete (including UAT):**
- Code edits: 2 minutes
- Compilation: 30 seconds
- Bundle & relaunch: 1 minute
- Manual UAT (Tests 1–6): 5–10 minutes
- Programmatic UAT (Test 7): 3–5 minutes (if a test needs to be written)
- **Total: ~15–20 minutes**

**After completing the implementation:**
Run `/wispr-rebuild-and-relaunch` to trigger automatic smart UAT, which will validate the fix against any existing History view tests.

