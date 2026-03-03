# Phase 2 Brainstorm — UI Polish (Gemini)

## Issue 1: API Key Placeholder Text

### Recommendation
- Change prompt from provider prefix ("sk-...", "AIza...") to "Enter API key here"
- Move provider hint to caption below field: "Your key should start with 'sk-...'"
- Caption fades when user starts typing

### Implementation
```swift
TextField("", text: $apiKey,
    prompt: Text("Enter API key here")
        .foregroundColor(.secondary)
)
// Below the field:
Text("Your key should start with \"\(selectedProvider.keyPlaceholder)\"")
    .font(.system(size: 11))
    .foregroundColor(.secondary)
    .opacity(apiKey.isEmpty ? 1.0 : 0.0)
```

---

## Issue 2: Font & Color Alignment

### Decision: Use optimized system fonts (NOT bundled web fonts)
- SF Pro + SF Mono are high quality, zero maintenance burden
- Use `.rounded` design variant for headings to match Plus Jakarta Sans feel
- Bundling web fonts adds complexity, licensing, and binary size

### Typographic Scale
| Category | SwiftUI Font |
|----------|-------------|
| Display Heading | `.system(size: 24, weight: .heavy, design: .rounded)` |
| Heading | `.system(size: 20, weight: .bold, design: .rounded)` |
| Subheading | `.system(size: 14, weight: .semibold)` |
| Body | `.system(size: 14, weight: .regular)` |
| Caption | `.system(size: 12, weight: .regular)` |
| Monospaced | `.system(size: 13, weight: .regular, design: .monospaced)` |

### Action: Create Font extension
```swift
extension Font {
    static let obDisplayHeading = Font.system(size: 24, weight: .heavy, design: .rounded)
    static let obHeading = Font.system(size: 20, weight: .bold, design: .rounded)
    static let obSubheading = Font.system(size: 14, weight: .semibold)
    static let obBody = Font.system(size: 14, weight: .regular)
    static let obCaption = Font.system(size: 12, weight: .regular)
    static let obMonospaced = Font.system(size: 13, weight: .regular, design: .monospaced)
}
```

### Color Adjustments
- Replace hardcoded placeholder color with `.secondary` (system semantic)
- Ensure accent purple passes contrast checks for text
- Use `.primary` / `.secondary` for standard text instead of custom obTextPrimary where possible

### Effort Estimates
1. API key placeholder: 2-4 hours (small)
2. Font system + 22 call sites: 1-2 days (medium)
3. Color refinement: 3-5 hours (small)
