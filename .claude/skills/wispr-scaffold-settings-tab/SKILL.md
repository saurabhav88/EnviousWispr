---
name: wispr-scaffold-settings-tab
description: >
  Use when adding a new top-level tab to the EnviousWispr Settings window —
  e.g., a new feature category requiring its own Form-based settings UI,
  UserDefaults persistence, and a tab item in SettingsView's TabView.
---

# Scaffold a New Settings Tab

## Step 1 — Create the view file

Create `Sources/EnviousWispr/Views/Settings/<Name>SettingsView.swift`.

```swift
import SwiftUI

struct <Name>SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("<Section Title>") {
                // Use $state.<property> for two-way bindings.
                // Toggle, Picker, TextField, Slider — standard SwiftUI controls.
                Toggle("<Label>", isOn: $state.<boolProperty>)

                Picker("<Label>", selection: $state.<enumProperty>) {
                    ForEach(<EnumType>.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
            }

            Section("<Another Section>") {
                TextField("<Label>", text: $state.<stringProperty>)
                    .textFieldStyle(.roundedBorder)

                Text("<Helper caption>")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

Key rules:
- `@Bindable var state = appState` must be declared INSIDE `body` (local binding).
- Never use `@State` for settings that must persist — wire through `AppState` instead.
- `Form { }.formStyle(.grouped)` is the standard macOS grouped settings style.
- No `#Preview` macros — CLI tools only.

## Step 2 — Add persisted properties to AppState

File: `Sources/EnviousWispr/App/AppState.swift`

For each new setting, add a stored property with `didSet` persistence:

```swift
var <propertyName>: <Type> {
    didSet {
        UserDefaults.standard.set(<propertyName><conversionIfNeeded>,
                                  forKey: "<userDefaultsKey>")
        // Propagate to pipeline or subsystem if needed:
        // pipeline.<property> = <propertyName>
    }
}
```

In `AppState.init()`, load the persisted value and assign before any other use:

```swift
// Bool
<propertyName> = defaults.object(forKey: "<userDefaultsKey>") as? <Type> ?? <defaultValue>
// String
<propertyName> = defaults.string(forKey: "<userDefaultsKey>") ?? "<default>"
// RawRepresentable enum
<propertyName> = <EnumType>(rawValue: defaults.string(forKey: "<key>") ?? "") ?? .<defaultCase>
```

## Step 3 — Register the tab in SettingsView

File: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

Inside `TabView { }`, add after the last existing tab:

```swift
<Name>SettingsView()
    .tabItem {
        Label("<Tab Label>", systemImage: "<sf-symbol-name>")
    }
```

SF Symbols reference: `gear`, `keyboard`, `sparkles`, `lock.shield`, `person`, `bell`, etc.

If adding the tab changes the preferred window size, update `.frame(width:height:)` on
the `TabView` in `SettingsView.body`.

## Step 4 — Verify

```bash
swift build
```

Confirm the new tab appears and bindings compile without actor isolation errors.
See `audit-actor-isolation` skill if the compiler flags `@Bindable` usage.
