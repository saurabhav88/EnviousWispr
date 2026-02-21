---
name: wispr-validate-menu-bar-patterns
description: "Use when implementing or reviewing MenuBarExtra logic, window targeting, settings activation, or app termination in EnviousWispr — covers dynamic icon updates, NSApplication window focus, and the Selector string workaround for settings."
---

# Validate Menu Bar Patterns

## MenuBarExtra Declaration

```swift
// Correct — dynamic icon tied to pipeline state
MenuBarExtra {
    MenuBarView()
        .environment(appState)
} label: {
    Image(systemName: appState.pipelineState.menuBarIconName)
}
.menuBarExtraStyle(.window)

// Incorrect — hardcoded icon does not reflect recording/transcribing state
} label: {
    Image(systemName: "mic")   // WRONG: never reflects state changes
}
```

`pipelineState.menuBarIconName` must be a computed property on `PipelineState` that returns the correct SF Symbol for each case (`.idle`, `.recording`, `.transcribing`, `.polishing`, `.complete`).

## Targeting the Main Window by ID

```swift
// Correct — find window by identifier, avoid stale references
func showMainWindow() {
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// Incorrect — caching a window reference across deactivation cycles
var cachedWindow: NSWindow?     // WRONG: can become stale
```

Window ID "main" must match the `.id("main")` modifier on the `Window` scene in `EnviousWisprApp`.

## Activating the App and Window

```swift
// Bring app to front after showing window
NSApplication.shared.activate(ignoringOtherApps: true)
// Always call AFTER makeKeyAndOrderFront, not before
```

## Opening Settings

```swift
// Correct — string selector workaround (typed selector unavailable on CLI target)
NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
NSApplication.shared.activate(ignoringOtherApps: true)

// Incorrect — direct API not available without full AppKit linkage
NSApp.showSettingsWindow()      // WRONG: does not compile on CLI toolchain
```

## App Termination

```swift
Button("Quit EnviousWispr") {
    NSApplication.shared.terminate(nil)
}
```

Never call `exit(0)` — it skips graceful cleanup (audio engine teardown, model unload).

## Checklist

- [ ] `MenuBarExtra` label reads from `pipelineState.menuBarIconName`, not a literal
- [ ] `PipelineState` has `menuBarIconName: String` covering all enum cases
- [ ] Main window targeted by ID `"main"` via `NSApp.windows.first(where:)`
- [ ] No stale cached `NSWindow` references stored as properties
- [ ] `NSApplication.shared.activate(ignoringOtherApps: true)` called after `makeKeyAndOrderFront`
- [ ] Settings opened via `Selector(("showSettingsWindow:"))` string form
- [ ] Quit uses `NSApplication.shared.terminate(nil)`, not `exit(0)`
- [ ] `MenuBarExtra` scene injects `.environment(appState)` into `MenuBarView`
