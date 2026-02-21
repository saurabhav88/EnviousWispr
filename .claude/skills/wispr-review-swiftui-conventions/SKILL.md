---
name: wispr-review-swiftui-conventions
description: "Use when writing new SwiftUI views, reviewing existing views for correctness, or debugging state/binding issues in EnviousWispr — covers @Observable, environment injection, settings scenes, MenuBarExtra, and macOS-specific layout patterns."
---

# Review SwiftUI Conventions

## State & Observation (macOS 14+ / Swift 5.9+)

### Correct

```swift
// Declaration
@Observable final class AppState { ... }

// Injection at root
ContentView().environment(appState)

// Consumption
struct MyView: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state          // create binding scope
        TextField("", text: $state.someText)
    }
}
```

### Incorrect — do not use

```swift
// ObservableObject / @EnvironmentObject (legacy, not used here)
@EnvironmentObject var state: AppState       // WRONG
@StateObject var state = AppState()          // WRONG
@ObservedObject var state: AppState          // WRONG
```

## Settings Window

```swift
// Scene declaration
Settings {
    SettingsView()
        .environment(appState)
}

// Open programmatically (no direct API on macOS CLI target)
NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
// Use string selector — the typed variant is unavailable without AppKit glue
```

## MenuBarExtra

```swift
MenuBarExtra {
    MenuBarView()
        .environment(appState)
} label: {
    Image(systemName: appState.pipelineState.menuBarIconName)
}
.menuBarExtraStyle(.window)
```

Dynamic icon must come from `pipelineState.menuBarIconName`, never hardcoded.

## Forms and Layout

```swift
Form {
    Section("Audio") { ... }
    Section("Shortcuts") { ... }
}
.formStyle(.grouped)        // required for macOS sidebar-style forms
```

Use `TabView` with labeled tabs for settings. Use `NavigationSplitView` for main-window two-panel layouts.

## Async On-Appear

```swift
.task {
    await viewModel.loadData()   // preferred over .onAppear + Task { }
}
```

## No #Preview Macros

```swift
// NEVER add:
#Preview { MyView() }           // breaks CLI-only builds

// Omit previews entirely — no Xcode, no PreviewProvider either
```

## Checklist

- [ ] `@Observable` not `ObservableObject`
- [ ] `@Environment(AppState.self)` not `@EnvironmentObject`
- [ ] Bindings created with `@Bindable var x = x` inside `body`
- [ ] Forms use `.formStyle(.grouped)`
- [ ] Settings opened via `Selector(("showSettingsWindow:"))`
- [ ] MenuBarExtra icon is dynamic from `pipelineState.menuBarIconName`
- [ ] Async work in `.task {}` not `.onAppear`
- [ ] No `#Preview` macros anywhere
