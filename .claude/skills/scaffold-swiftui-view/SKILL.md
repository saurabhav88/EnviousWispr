---
name: scaffold-swiftui-view
description: >
  Use when creating any new SwiftUI view in EnviousWispr — a detail panel,
  onboarding screen, transcript row, modal sheet, or any standalone visual
  component that needs AppState injection and macOS-correct patterns.
---

# Scaffold a New SwiftUI View

## Step 1 — Choose the right location

| View type             | Directory                              |
|-----------------------|----------------------------------------|
| Main window panel     | `Sources/EnviousWispr/Views/Main/`      |
| Settings tab          | use `scaffold-settings-tab` skill      |
| Menu bar popover      | `Sources/EnviousWispr/Views/MenuBar/`   |
| Onboarding screen     | `Sources/EnviousWispr/Views/Onboarding/`|
| Reusable component    | `Sources/EnviousWispr/Views/` (root)    |

## Step 2 — Create the view file

Create `Sources/EnviousWispr/Views/<Subdirectory>/<Name>View.swift`.

```swift
import SwiftUI

struct <Name>View: View {
    // Inject root state via environment — never pass AppState as a parameter.
    @Environment(AppState.self) private var appState

    // Local UI state only — transient, not persisted.
    @State private var <localVar>: <Type> = <defaultValue>

    var body: some View {
        // Declare @Bindable inside body to get two-way bindings on AppState.
        @Bindable var state = appState

        // --- macOS layout primitives ---
        // Main content window:  NavigationSplitView (sidebar + detail)
        // Settings:             Form { }.formStyle(.grouped)  — use scaffold-settings-tab
        // Tabbed views:         TabView { }
        // Dialogs / sheets:     .sheet(isPresented:) or .confirmationDialog(...)
        // Standard container:   VStack / HStack / ZStack / ScrollView

        VStack(spacing: 16) {
            // Read-only access via appState.<property>
            Text(appState.<property>)

            // Two-way binding via $state.<property>
            TextField("<Label>", text: $state.<stringProperty>)
                .textFieldStyle(.roundedBorder)

            Toggle("<Label>", isOn: $state.<boolProperty>)

            Button("<Action>") {
                Task { await appState.<asyncMethod>() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        // Lifecycle hooks
        .onAppear { /* load data */ }
        .onDisappear { /* cleanup */ }
    }
}
```

## Step 3 — AppState injection rules

- Views receive `AppState` from the environment — set at the app root via
  `.environment(appState)` on the top-level view.
- `@Bindable var state = appState` enables `$state.<property>` two-way bindings.
  Declare it as a local `var` inside `body`, not as a stored property.
- Never store a reference to `AppState` in `@State` or pass it as a constructor arg.
- Child views that need bindings accept `Binding<T>` parameters, not `AppState` directly.

## Step 4 — macOS-specific rules

- No `#Preview` macros — CLI tools only (no full Xcode).
- Use `.controlSize(.small)` for toolbar-area buttons.
- Use `.font(.caption).foregroundStyle(.secondary)` for helper text.
- Use `.monospacedDigit()` for numeric readouts (timer, RTF, latency).
- Use `Label("...", systemImage: "...")` for icon+text combos.
- Prefer `NavigationSplitView` over `NavigationStack` for main-window two-panel layouts.
- Sheet presentation: `.sheet(isPresented: $state.<flag>) { ChildView().environment(appState) }`

## Step 5 — Async actions

Wrap `async` calls in `Task { }` inside button closures or `.task { }` view modifiers:

```swift
Button("Transcribe") {
    Task { await appState.toggleRecording() }
}

.task {
    appState.loadTranscripts()
}
```

Do not call `async` methods directly from synchronous closures.

## Step 6 — Verify

```bash
swift build
```

Check for missing `.environment(appState)` propagation if the view is presented
modally or opened in a new window.
