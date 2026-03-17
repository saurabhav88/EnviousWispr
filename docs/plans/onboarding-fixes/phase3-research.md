# Phase 3 Research: Issue #10 — History View Cuts Off Settings Sidebar

## Date: 2026-03-02

---

## 1. Current Layout Structure

### Window Scene (`EnviousWisprApp.swift`)
- `Window("EnviousWispr", id: "main")` contains `UnifiedWindowView`
- Minimum size: `minWidth: 560, minHeight: 400`
- Default size: `width: 820, height: 600`

### Root View (`SettingsView.swift` — struct `UnifiedWindowView`)
```swift
NavigationSplitView {
    List(selection: $selectedSection) {
        // sidebar nav items
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
} detail: {
    detailContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

The `NavigationSplitView` has:
- **Sidebar**: `navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)` — constrained to 160–200pt
- **Detail**: `frame(maxWidth: .infinity, maxHeight: .infinity)` — expands to fill all remaining space

### Detail for `.history` case:
```swift
case .history:
    HistoryContentView()
```

### `HistoryContentView.swift`
```swift
VStack(spacing: 0) {
    if appState.permissions.shouldShowAccessibilityWarning {
        AccessibilityWarningBanner()
    }

    HSplitView {
        TranscriptHistoryView()
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

        Group { ... }
            .frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

`HistoryContentView` contains **its own `HSplitView`** (an AppKit `NSSplitView` wrapper) that creates:
- **Transcript list panel**: `minWidth: 200, idealWidth: 250, maxWidth: 300`
- **Content/detail panel**: `minWidth: 350, idealWidth: 500, maxWidth: .infinity`

---

## 2. Root Cause Analysis

### The Core Problem: Minimum Width Conflict

The window has `minWidth: 560`. The `NavigationSplitView` plus `HSplitView` impose a combined minimum:

```
NavigationSplitView sidebar min: 160pt
  + HSplitView transcript list min: 200pt
  + HSplitView detail pane min: 350pt
  + divider chrome (~2pt each × 2 = ~4pt)
= ~714pt minimum content width
```

**714pt > 560pt window minimum** — there's a 154pt gap between what the layout needs and what the window allows.

When the window is at or near its minimum width (560–714pt), the three-pane layout (NavigationSplitView sidebar + 2× HSplitView panes) cannot satisfy all three minimum widths simultaneously. macOS resolves this conflict by **collapsing the NavigationSplitView sidebar** — the leftmost column disappears entirely.

### Why Only History Is Affected

All other detail views (SpeechEngineSettingsView, AudioSettingsView, etc.) are standard `ScrollView`/`Form`/`VStack` content without their own `minWidth` constraints. Their natural minimum width is minimal (whatever text wraps to). The detail pane's `frame(maxWidth: .infinity)` gives them all available space without competing with the sidebar.

**History is uniquely broken** because `HistoryContentView` introduces a second horizontal split (`HSplitView`) with hard `minWidth` constraints inside the detail pane. This is a nested split view within a split view — the inner `HSplitView` enforces its own minimum of `200 + 350 = 550pt` inside a pane that can be as small as the remaining space after the NavigationSplitView sidebar takes its 160–200pt share.

**At a 700pt window width:**
- Sidebar takes ~180pt (ideal)
- Remaining for detail: ~520pt
- HSplitView needs min 200 + 350 = 550pt
- Deficit: 30pt → AppKit resolves by collapsing the NavigationSplitView sidebar (since it's the outermost, lowest-priority column)

**At the 820pt default width:**
- Sidebar: 180pt
- Remaining: 640pt — meets 550pt minimum, so layout works
- But if user resizes the window narrower than ~714pt, the sidebar collapses

### Why the Sidebar Specifically "Cuts Off"

`NavigationSplitView` in macOS has automatic column collapse behavior. When available width is insufficient to satisfy all column minimums, it hides the sidebar column entirely rather than partially showing it. The user sees only the History content, with the nav sidebar gone.

The `.navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)` modifier guides the sidebar width but does NOT prevent AppKit from collapsing the column when constraints cannot be met.

---

## 3. Proposed Fix

### Option A: Reduce HSplitView Minimum Widths (Minimal Change, Recommended)

Lower the inner `HSplitView` pane minimums so the combined three-pane minimum fits within the window's minimum width:

**Target**: NavigationSplitView sidebar (160) + HSplitView list (160) + HSplitView detail (240) + chrome (~10) = 570pt ≤ 560pt... still tight. Better:

Window minimum is 560pt. Sidebar takes min 160pt. That leaves 400pt for the HSplitView:
- Transcript list min: `120pt` (was 200)
- Detail pane min: `260pt` (was 350)
- Total inner: 380pt + chrome ≈ 400pt ✓

**File: `Sources/EnviousWispr/Views/Main/HistoryContentView.swift`**

```swift
// BEFORE
TranscriptHistoryView()
    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

Group { ... }
    .frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)

// AFTER
TranscriptHistoryView()
    .frame(minWidth: 120, idealWidth: 220, maxWidth: 280)

Group { ... }
    .frame(minWidth: 260, idealWidth: 460, maxWidth: .infinity)
```

### Option B: Raise Window Minimum Width (Simple, But Limits Users)

In `EnviousWisprApp.swift`:
```swift
// BEFORE
.frame(minWidth: 560, minHeight: 400)

// AFTER
.frame(minWidth: 740, minHeight: 400)
```

This guarantees the three-pane layout always fits but prevents users from making the window narrower than 740pt. Not ideal for usability.

### Option C: Replace HSplitView with NavigationSplitView (Best UX, More Work)

Replace the inner `HSplitView` in `HistoryContentView` with a proper two-column `NavigationSplitView`. This uses macOS's native column management which handles collapse gracefully and cooperates better with the outer NavigationSplitView. However, nested `NavigationSplitView` within another's detail pane has its own caveats on macOS.

### Option D: Add `.navigationSplitViewStyle(.balanced)` or `.prominentDetail` (Quick Experiment)

SwiftUI's `NavigationSplitViewStyle` can affect how space is distributed:
- `.balanced`: Both columns share available space proportionally
- `.prominentDetail`: Detail gets priority

Adding `.navigationSplitViewStyle(.balanced)` to the outer NavigationSplitView might help AppKit negotiate space better, but does not actually solve the minimum-width conflict.

### Recommended Fix: Option A

Lower the inner HSplitView minWidth values so the three-pane minimum sum fits comfortably within the window's existing 560pt minimum. This is a one-file, three-line change that fixes the root cause without side effects.

**Additionally**: Consider raising the window `minWidth` from 560 to 600 to give a small buffer, and set `defaultSize` to something that ensures History always renders correctly on first open.

---

## 4. Other Sections — Same Issue?

No. All other detail view sections render `ScrollView`/`Form`/`VStack` content. None of them embed an `HSplitView` with `minWidth` constraints. The sidebar only collapses when the History section introduces its additional minimum-width demand via the nested `HSplitView`.

The other sections that use complex content (e.g., `AIPolishSettingsView` at 612 lines) use `ScrollView { Form { ... } }` patterns that wrap gracefully to any width.

---

## 5. Files Involved

| File | Change Required |
|------|----------------|
| `Sources/EnviousWispr/Views/Main/HistoryContentView.swift` | Reduce minWidth values on HSplitView children (primary fix) |
| `Sources/EnviousWispr/App/EnviousWisprApp.swift` | Optional: raise minWidth from 560 to 600 as defensive floor |

---

## 6. Buddies Feedback (Gemini Review — 2026-03-02)

### Verdict: Root cause confirmed. Option A is correct.

**On root cause accuracy:**
Gemini confirmed the analysis is spot-on. The layout system sees all horizontal constraints as: `Sidebar.minWidth + Divider1 + HSplitPane1.minWidth + Divider2 + HSplitPane2.minWidth <= Window.width`. When the window is below ~720pt, AppKit resolves the conflict by collapsing the NavigationSplitView sidebar (its own column), prioritizing the content inside its panes over its own structural integrity.

**On Option A (reduce inner minWidths):**
Confirmed as the best and most idiomatic approach. Direct, correct, respects user flexibility. Key concern raised: **visually test content legibility at 120pt transcript list width and 260pt detail pane width**. The design trade-off is spaciousness at larger sizes for functionality at smaller sizes.

**On replacing HSplitView with nested NavigationSplitView:**
Gemini explicitly confirmed: do NOT use nested NavigationSplitView. It is not recommended — leads to unpredictable behavior with state, focus, toolbar commands, and animations. Current `NavigationSplitView` (navigation) + `HSplitView` (content splitting) is the correct architecture.

**On `.navigationSplitViewStyle(.balanced)`:**
Will NOT fix the bug. Controls resize behavior proportions, not minimum constraint resolution. Leave at default.

**Additional gotcha raised — `layoutPriority`:**
Could be used to give the sidebar column higher priority: `.layoutPriority(1)` on the sidebar List. However Gemini explicitly advises against this as a "bigger hammer" — can cause inner HSplitView panes to be compressed below their minWidth, which could look worse. Option A remains cleaner.

**Final Gemini Recommendations:**
1. Implement Option A — reduce HSplitView minWidth values
2. Test visually at the 560pt minimum window width
3. Do NOT raise the window minimum width unless visual testing proves absolutely necessary
4. Do NOT use nested NavigationSplitView
5. Do NOT add `.navigationSplitViewStyle` modifiers

---

## 7. Final Fix Plan (Post-Buddies Validation)

### Primary fix (one file change):

**File: `Sources/EnviousWispr/Views/Main/HistoryContentView.swift`**

```swift
// BEFORE
TranscriptHistoryView()
    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

Group { /* detail or StatusView */ }
    .frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)

// AFTER
TranscriptHistoryView()
    .frame(minWidth: 120, idealWidth: 220, maxWidth: 280)

Group { /* detail or StatusView */ }
    .frame(minWidth: 260, idealWidth: 460, maxWidth: .infinity)
```

**Why these numbers:**
- Window min: 560pt
- NavigationSplitView sidebar min: 160pt
- Remaining for HSplitView: 560 - 160 = 400pt
- Chrome/dividers: ~10pt
- Available for two panes: ~390pt
- Split as 120 + 260 = 380pt (fits within 390pt buffer)
- Ideal widths: 220 + 460 = 680pt (comfortable at 820pt default + 180pt sidebar = 1000pt... adjust)
  - More realistic: at 820pt window, sidebar = 180pt, remaining = 640pt, split 220+460 = 680pt → slightly tight, use 200+420 for ideals
  - Revised ideals: `idealWidth: 200` and `idealWidth: 420` to fit comfortably at 820pt default

### Revised final numbers:
```swift
TranscriptHistoryView()
    .frame(minWidth: 120, idealWidth: 200, maxWidth: 280)

Group { /* detail or StatusView */ }
    .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
```

At 820pt default: sidebar 180pt + list 200pt + detail 420pt + chrome ~20pt = 820pt ✓
At 560pt minimum: sidebar 160pt + list 120pt + detail 260pt + chrome ~20pt = 560pt ✓

### Optional defensive change:

**File: `Sources/EnviousWispr/App/EnviousWisprApp.swift`**

Consider raising `minWidth` from 560 to 570 to provide a small buffer against rounding/chrome variance. Not strictly necessary but gives headroom.

### No changes needed to:
- `SettingsView.swift` — NavigationSplitView constraints are fine
- Any other detail view — only History has the HSplitView issue
- `SettingsSection.swift` — pure data, no layout

