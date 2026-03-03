# Configurable Keybindings Implementation Plan

**Date**: 2026-02-20
**Feature**: Make all hotkeys user-configurable via Settings → Shortcuts

## Overview

Currently, only the cancel hotkey is configurable. This plan extends configurability to:
1. **Toggle hotkey** (currently hardcoded: Option+Space)
2. **Push-to-talk modifier** (currently hardcoded: Option key)

## Current State

| Hotkey | Current Binding | Configurable? | Persisted? |
|--------|----------------|---------------|------------|
| Cancel | Escape | ✅ Yes | ✅ Yes |
| Toggle | Option+Space | ❌ No | ❌ No |
| Push-to-talk | Option (hold) | ❌ No | ❌ No |

## Implementation Steps

### Step 1: Add Persistence to AppState
**File**: `Sources/EnviousWispr/App/AppState.swift`

Add new persisted properties:
```swift
// Toggle hotkey (default: Option+Space)
var toggleKeyCode: UInt16 = 49  // Space
var toggleModifiers: UInt = NSEvent.ModifierFlags.option.rawValue

// Push-to-talk modifier (default: Option)
var pushToTalkModifier: UInt = NSEvent.ModifierFlags.option.rawValue
```

With UserDefaults persistence in `didSet` and `init()` loading.

### Step 2: Create Reusable HotkeyRecorderView
**File**: `Sources/EnviousWispr/Views/Components/HotkeyRecorderView.swift`

A SwiftUI component that:
- Shows current keybinding as text (e.g., "⌥ Space")
- Enters "recording" mode on click
- Captures next keypress + modifiers
- Calls binding callback with new values
- Has "Reset to Default" option

### Step 3: Update ShortcutsSettingsView
**File**: `Sources/EnviousWispr/Views/Settings/ShortcutsSettingsView.swift`

Convert from read-only display to editable:
- Replace static Text with HotkeyRecorderView for each hotkey
- Add section headers for clarity
- Add "Reset All to Defaults" button

### Step 4: Wire HotkeyService to AppState
**File**: `Sources/EnviousWispr/Services/HotkeyService.swift`

- Remove hardcoded key codes
- Read initial values from AppState
- Subscribe to AppState changes (via observation or callback)
- Re-register monitors when hotkeys change

### Step 5: Add Key Symbol Formatting
**File**: `Sources/EnviousWispr/Utilities/KeySymbols.swift`

Helper to convert key codes to readable symbols:
- 49 → "Space"
- 53 → "Escape"
- Modifiers: ⌘ ⌥ ⌃ ⇧

## Files to Modify

| File | Change |
|------|--------|
| `AppState.swift` | Add 3 new persisted properties |
| `ShortcutsSettingsView.swift` | Make hotkeys editable |
| `HotkeyService.swift` | Use configurable values |

## Files to Create

| File | Purpose |
|------|---------|
| `HotkeyRecorderView.swift` | Reusable key capture component |
| `KeySymbols.swift` | Key code → symbol formatting |

## Testing Plan

1. Build succeeds with `swift build`
2. Launch app, go to Settings → Shortcuts
3. Change toggle hotkey to Cmd+Shift+R
4. Verify new hotkey works
5. Restart app, verify hotkey persisted
6. Reset to defaults, verify Option+Space restored

## Estimated Effort

- AppState changes: ~30 lines
- HotkeyRecorderView: ~100 lines
- ShortcutsSettingsView updates: ~50 lines
- HotkeyService wiring: ~40 lines
- KeySymbols helper: ~60 lines

**Total**: ~280 lines of code

## Agent Assignment

| Task | Agent |
|------|-------|
| AppState persistence | macos-platform |
| HotkeyRecorderView | feature-scaffolding |
| ShortcutsSettingsView | macos-platform |
| HotkeyService wiring | macos-platform |
| Build validation | build-compile |
| Smoke test | testing |
