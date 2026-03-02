# Onboarding Design Spec — HTML Mockup to SwiftUI Translation

> This spec provides every CSS value from the HTML mockup translated to SwiftUI code.
> A Swift developer can implement this without seeing the mockup.

---

## Global Color Palette

```swift
// MARK: - Onboarding Color Palette
extension Color {
    // Backgrounds
    static let obBg           = Color(red: 0.973, green: 0.961, blue: 1.0)         // #f8f5ff
    static let obSurface      = Color(red: 0.941, green: 0.925, blue: 0.976)       // #f0ecf9
    static let obCardBg       = Color.white                                         // #ffffff

    // Text
    static let obTextPrimary  = Color(red: 0.059, green: 0.039, blue: 0.102)       // #0f0a1a
    static let obTextSecondary = Color(red: 0.290, green: 0.239, blue: 0.376)      // #4a3d60
    static let obTextTertiary = Color(red: 0.490, green: 0.435, blue: 0.588)       // #7d6f96

    // Brand
    static let obAccent       = Color(red: 0.486, green: 0.227, blue: 0.929)       // #7c3aed
    static let obAccentHover  = Color(red: 0.427, green: 0.157, blue: 0.851)       // #6d28d9
    static let obAccentSoft   = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.1)

    // Semantic
    static let obSuccess      = Color(red: 0.0, green: 0.784, blue: 0.502)         // #00c880
    static let obSuccessSoft  = Color(red: 0.0, green: 0.784, blue: 0.502).opacity(0.1)
    static let obSuccessText  = Color(red: 0.0, green: 0.541, blue: 0.337)         // #008a56
    static let obWarning      = Color(red: 0.902, green: 0.761, blue: 0.0)         // #e6c200
    static let obError        = Color(red: 0.902, green: 0.145, blue: 0.227)       // #e6253a
    static let obErrorSoft    = Color(red: 0.902, green: 0.145, blue: 0.227).opacity(0.1)

    // Borders
    static let obBorder       = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.06)  // rgba(138,43,226,0.06)
    static let obBorderHover  = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.12)  // rgba(138,43,226,0.12)

    // Buttons
    static let obBtnDark      = Color(red: 0.059, green: 0.039, blue: 0.102)       // #0f0a1a
    static let obBtnDarkHover = Color(red: 0.102, green: 0.071, blue: 0.188)       // #1a1230
}
```

### Rainbow Gradient (used in progress connectors, download bar, result accent)

```swift
static let obRainbow = LinearGradient(
    colors: [
        Color(red: 1.0, green: 0.165, blue: 0.251),    // #ff2a40
        Color(red: 1.0, green: 0.549, blue: 0.0),       // #ff8c00
        Color(red: 1.0, green: 0.843, blue: 0.0),       // #ffd700
        Color(red: 0.678, green: 1.0, blue: 0.184),     // #adff2f
        Color(red: 0.0, green: 0.98, blue: 0.604),      // #00fa9a
        Color(red: 0.0, green: 1.0, blue: 1.0),         // #00ffff
        Color(red: 0.118, green: 0.565, blue: 1.0),     // #1e90ff
        Color(red: 0.255, green: 0.412, blue: 0.882),   // #4169e1
        Color(red: 0.541, green: 0.169, blue: 0.886),   // #8a2be2
    ],
    startPoint: .leading,
    endPoint: .trailing
)
```

---

## Global Typography

The mockup uses **Plus Jakarta Sans** and **JetBrains Mono**. On macOS/SwiftUI these translate to:

```swift
// Display / body — use system font with custom sizing (Plus Jakarta Sans is not available natively)
// Alternatively, bundle Plus Jakarta Sans and use Font.custom("Plus Jakarta Sans", size:)
// For now, use system with matching weights:

// Step title: 22px, weight 800 (extraBold), letterSpacing -0.4px, lineHeight 1.2
.font(.system(size: 22, weight: .heavy))
.kerning(-0.4)

// Step body: 14px, weight 400, lineHeight 1.55
.font(.system(size: 14, weight: .regular))
.lineSpacing(14 * 0.55)  // ~7.7pt extra leading

// Caption: 12px, weight 400
.font(.system(size: 12, weight: .regular))

// Monospaced (keycaps, API key): JetBrains Mono or SF Mono
.font(.system(size: 12, weight: .semibold, design: .monospaced))
```

---

## Window Frame

```swift
// Current SwiftUI
.frame(width: 500, height: 550)

// Target SwiftUI — matches mockup
.frame(width: 460, height: 480)  // 460px wide, min-height 440 + 42px titlebar ≈ 482
// Note: macOS window chrome is automatic. The 460x440 is CONTENT area.
// SwiftUI window: width 460, minHeight ~480 (content min-height 396 + titlebar 42 + padding 24+28)
```

The window background should be `.obCardBg` (white). The mockup has `border-radius: 12px` and a shadow — these are provided by the macOS window system in SwiftUI.

Content padding: `padding: 24px 28px 28px` translates to:

```swift
.padding(.top, 24)
.padding(.horizontal, 28)
.padding(.bottom, 28)
```

---

## 1. Step Indicator Bar (Progress Dots)

### Current SwiftUI
- HStack with circles (22x22) showing numbers/checkmarks
- Text labels beside each dot
- Rectangles as connectors (height 1, with horizontal padding 6)
- Uses `Color.accentColor`, `Color.secondary`

### Target SwiftUI

The mockup uses **dots only** (no text labels) with larger circles and wider connectors.

```swift
private var stepIndicator: some View {
    HStack(spacing: 0) {
        ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
            let isCurrent = step == viewModel.currentStep
            let isCompleted = step.rawValue < viewModel.currentStep.rawValue

            // Dot
            ZStack {
                Circle()
                    .fill(dotFill(isCompleted: isCompleted, isCurrent: isCurrent))
                    .frame(width: 30, height: 30)
                    .shadow(
                        color: isCurrent ? Color.obAccent.opacity(0.3) : .clear,
                        radius: isCurrent ? 6 : 0,
                        y: isCurrent ? 2 : 0
                    )

                if isCompleted {
                    // Checkmark
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isCurrent ? .white : Color.obTextTertiary)
                }
            }

            // Connector (NOT after the last dot)
            if step != OnboardingViewModel.Step.allCases.last {
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isCompleted
                            ? AnyShapeStyle(Color.obRainbow)   // rainbow gradient for completed
                            : AnyShapeStyle(Color.obSurface)   // plain for upcoming
                    )
                    .frame(width: 28, height: 2)
            }
        }
    }
    .padding(.bottom, 22)  // margin-bottom: 22px
}

func dotFill(isCompleted: Bool, isCurrent: Bool) -> Color {
    if isCompleted { return .obSuccess }       // #00c880
    if isCurrent  { return .obAccent }         // #7c3aed
    return .obSurface                          // #f0ecf9
}
```

**Key differences from current:**
- Dots are 30x30 (was 22x22)
- No text labels beside dots
- Connectors are 28x2 (was flexible width, height 1)
- Completed connectors get rainbow gradient
- Current dot has purple shadow glow
- Completed dots are green (not accent)
- Font in dots: 12px bold (was 11px)

---

## 2. Step 1: Welcome

### Lips Icon (replaces the icon row)

The mockup has a custom **animated rainbow lips SVG** (70x70) instead of the icon row. This is the app's brand mascot — a set of 9 rainbow bars arranged in a lips/mouth shape.

```swift
// The lips icon is a 70x70 SVG with animated bars
// SwiftUI implementation would need a custom view:
struct LipsIconView: View {
    // 70x70 container
    var body: some View {
        // ... custom drawn bars with animation ...
    }
}
// Frame: width 70, height 70
// marginBottom: 18
.frame(width: 70, height: 70)
.padding(.bottom, 18)
```

The SVG consists of 9 upper bars and 9 lower bars with rainbow colors:
- Upper bars (left to right): #ff2a40, #ff8c00, #ffd700, #adff2f, #00fa9a, #00ffff, #1e90ff, #4169e1, #8a2be2
- Lower bars (mirrored): #4169e1, #1e90ff, #00ffff, #00fa9a, #adff2f, #ffd700, #ff8c00, #ff2a40, #8a2be2
- Each bar: width 14, rounded (rx 5)
- Bars have a glow filter (Gaussian blur stdDeviation 4)
- Animation states: idle (gentle breathing), denied (sad/shrunken), happy (bounce), equalizer, recording, etc.

**NOTE:** This is complex. For the SwiftUI implementation, either:
1. Bundle the SVG and display via a WebView/Image
2. Use SFSymbol "waveform" as a simpler placeholder
3. Create a full custom SwiftUI view with bars + animations

### Title
```swift
// Current: .font(.title2.bold())
// Target:
Text("Welcome to EnviousWispr")
    .font(.system(size: 22, weight: .heavy))
    .foregroundStyle(Color.obTextPrimary)
    .kerning(-0.4)
    .padding(.bottom, 6)
```

### Subtitle
```swift
// Current: .multilineTextAlignment(.center).foregroundStyle(.secondary)
// Target:
Text("Press a hotkey to transcribe your voice. First, we need microphone access.")
    .font(.system(size: 14, weight: .regular))
    .lineSpacing(7.7)  // 14 * 1.55 - 14 ≈ 7.7
    .foregroundStyle(Color.obTextSecondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: 360)
    .padding(.bottom, 18)
```

### Icon Flow (mic -> app -> text)

```swift
// Three 36x36 rounded boxes with small SVG icons, connected by arrows
HStack(spacing: 8) {
    // Each icon box:
    iconFlowItem(systemName: "mic.fill")
    Text("→")
        .font(.system(size: 11))
        .foregroundStyle(Color.obTextTertiary)
    iconFlowItem(systemName: "app.fill")
    Text("→")
        .font(.system(size: 11))
        .foregroundStyle(Color.obTextTertiary)
    iconFlowItem(systemName: "text.alignleft")
}
.padding(.bottom, 18)

func iconFlowItem(systemName: String) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 16))
        .foregroundStyle(Color.obTextTertiary)  // #7d6f96
        .frame(width: 36, height: 36)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.obBorder, lineWidth: 1)
        )
}
```

### Inline Alert (granted / denied)

```swift
// Green alert (granted):
HStack(spacing: 8) {
    Text("Microphone access granted ✓")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.obSuccessText)  // #008a56
}
.padding(.horizontal, 14)
.padding(.vertical, 10)
.frame(maxWidth: 360)
.background(Color.obSuccessSoft, in: RoundedRectangle(cornerRadius: 12))
.overlay(
    RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.obSuccess.opacity(0.2), lineWidth: 1)
)

// Red alert (denied):
HStack(spacing: 8) {
    Text("Microphone access was denied.")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.obError)  // #e6253a
}
.padding(.horizontal, 14)
.padding(.vertical, 10)
.frame(maxWidth: 360)
.background(Color.obErrorSoft, in: RoundedRectangle(cornerRadius: 12))
.overlay(
    RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.obError.opacity(0.2), lineWidth: 1)
)
```

### Primary Button ("Grant Microphone Access")

```swift
// Current: .buttonStyle(.borderedProminent).controlSize(.large)
// Target (custom):
Button("Grant Microphone Access") { ... }
    .font(.system(size: 14, weight: .semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 28)
    .padding(.vertical, 11)
    .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
    .kerning(-0.1)
// Hover: background -> #1a1230, shadow 0 4px 16px rgba(15,10,26,0.2), translateY(-1px)
```

### Error Button ("Open System Settings" — after denial)

```swift
Button("Open System Settings") { ... }
    .font(.system(size: 14, weight: .semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 28)
    .padding(.vertical, 11)
    .background(Color.obError, in: RoundedRectangle(cornerRadius: 12))
// Hover: background -> #cc1f32
```

---

## 3. Step 2: Model Download

### Spinner

```swift
// Current: ProgressView().scaleEffect(1.4)
// Target: 40x40 spinning ring
ZStack {
    Circle()
        .stroke(Color.obSurface, lineWidth: 3)
        .frame(width: 40, height: 40)
    Circle()
        .trim(from: 0, to: 0.25)
        .stroke(Color.obAccent, lineWidth: 3)
        .frame(width: 40, height: 40)
        .rotationEffect(.degrees(spinAngle))
        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinAngle)
}
.padding(.bottom, 16)
```

### Download Progress Bar (Rainbow)

```swift
// 4px height, max-width 360, rainbow gradient fill with shimmer animation
ZStack(alignment: .leading) {
    RoundedRectangle(cornerRadius: 2)
        .fill(Color.obSurface)
        .frame(height: 4)

    RoundedRectangle(cornerRadius: 2)
        .fill(Color.obRainbow)
        .frame(width: progressWidth, height: 4)  // width = maxWidth * progress
}
.frame(maxWidth: 360)
.padding(.bottom, 12)
```

### Hotkey Callout Card

```swift
// Current: HStack with KeyCapView in a rounded background
// Target: Proper card with title, body, hero keycap

VStack(spacing: 10) {
    Text("Your hotkey is Right Command")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.1)

    Text("Press and hold it anytime to start dictating.")
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Color.obTextSecondary)
        .lineSpacing(5.85)  // 13 * 1.45 - 13

    // Hero keycap
    VStack(spacing: 4) {
        Text("⌘")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Color.obAccent)
            .frame(minWidth: 80, minHeight: 56)
            .background(
                LinearGradient(
                    colors: [.white, Color.obSurface],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.obAccent.opacity(0.15), lineWidth: 1.5)
            )
            .shadow(color: Color.obAccent.opacity(0.1), radius: 4, y: 2)

        Text("RIGHT COMMAND")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.obTextTertiary)
            .kerning(0.3)
    }
}
.padding(18)
.frame(maxWidth: 360)
.background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.obBorder, lineWidth: 1)
)
.shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1.5, y: 1)
.shadow(color: Color.obAccent.opacity(0.04), radius: 0, y: 0)  // border shadow
```

### Hotkey Config Row (Change Hotkey)

```swift
HStack(spacing: 12) {
    // Key icon
    Text("⌘")
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(Color.obAccent)
        .frame(width: 36, height: 36)
        .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.obBorderHover, lineWidth: 1)
        )
        .shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1, y: 1)

    // Labels
    VStack(alignment: .leading, spacing: 0) {
        Text("Right ⌘ (Command)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.obTextPrimary)
            .kerning(-0.1)
        Text("Current binding")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.obTextTertiary)
    }

    Spacer()

    // Customize button
    Button("Customize...") { }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.obAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.obAccent.opacity(0.15), lineWidth: 1)
        )
}
.padding(.horizontal, 16)
.padding(.vertical, 14)
.frame(maxWidth: 360)
.background(Color.obSurface, in: RoundedRectangle(cornerRadius: 14))
.overlay(
    RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.obBorder, lineWidth: 1)
)
```

### Caption

```swift
Text("Usually takes less than a minute on a standard connection.")
    .font(.system(size: 12, weight: .regular))
    .foregroundStyle(Color.obTextTertiary)
    .multilineTextAlignment(.center)
```

---

## 4. Step 3: AI Polish

### Title & Body

```swift
// Lips icon: shimmer expression (see Lips Icon section)

Text("Enhance Your Transcriptions")
    .font(.system(size: 22, weight: .heavy))
    .foregroundStyle(Color.obTextPrimary)
    .kerning(-0.4)
    .padding(.bottom, 6)

Text("AI Polish cleans up grammar, punctuation, and filler words after transcription. Choose how you'd like it to work:")
    .font(.system(size: 14, weight: .regular))
    .lineSpacing(7.7)
    .foregroundStyle(Color.obTextSecondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: 360)
    .padding(.bottom, 18)
```

### Polish Option Cards

Two cards side by side in an HStack with 10px gap:

```swift
HStack(spacing: 10) {
    polishCard(
        icon: "desktopcomputer",
        title: "On-Device (Free)",
        body: "Runs locally on your Mac. No API key needed. Good for basic cleanup.",
        badge: ("PRIVATE", Color.obSuccessText, Color.obSuccessSoft),
        isSelected: selectedOption == .onDevice
    ) { selectedOption = .onDevice }

    polishCard(
        icon: "key.fill",
        title: "Bring Your Own Key",
        body: "Use OpenAI or Gemini for advanced polishing. Requires an API key.",
        badge: ("BETTER QUALITY", Color.obAccent, Color.obAccentSoft),
        isSelected: selectedOption == .byok
    ) { selectedOption = .byok }
}
.frame(maxWidth: 380)
.padding(.bottom, 14)
```

**Individual card spec:**

```swift
func polishCard(icon: String, title: String, body: String,
                badge: (String, Color, Color),
                isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.obTextSecondary)

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.1)

            Text(body)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.obTextSecondary)
                .lineSpacing(11 * 0.4)  // lineHeight 1.4

            // Badge
            Text(badge.0)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(badge.1)
                .kerning(0.5)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.2, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.obAccent.opacity(0.03)
                : Color.obCardBg,
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isSelected ? Color.obAccent : Color.obBorder,
                    lineWidth: 1.5
                )
        )
        .shadow(
            color: isSelected ? Color.obAccent.opacity(0.08) : .clear,
            radius: isSelected ? 0 : 0  // box-shadow: 0 0 0 3px — simulated by stroke
        )
    }
    .buttonStyle(.plain)
}
```

**Selected state:**
- border: 1.5px solid `#7c3aed` (obAccent)
- background: `rgba(124,58,237,0.03)`
- outer glow: `0 0 0 3px rgba(124,58,237,0.08)` — use `.shadow(color: .obAccent.opacity(0.08), radius: 1.5)`

**Hover state (macOS):**
- border-color -> obBorderHover
- translateY(-2px) + shadow `0 8px 24px rgba(15,10,26,0.06)`

### BYOK Card Back (Provider Selection)

When BYOK is selected, the card flips (3D) to show provider selection. In SwiftUI, use `.rotation3DEffect` with `backface hidden`:

```swift
// Provider mini-card
HStack(spacing: 8) {
    // Icon
    Text("⚡")  // or ✦ for Gemini
        .font(.system(size: 16))
        .frame(width: 22)

    // Text
    VStack(alignment: .leading, spacing: 2) {
        Text("OpenAI")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.obTextPrimary)
            .kerning(-0.1)
        Text("GPT-4o for polishing")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Color.obTextSecondary)
    }

    Spacer()

    // Check circle (visible only when selected)
    if isSelectedProvider {
        Circle()
            .fill(Color.obAccent)
            .frame(width: 16, height: 16)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
.padding(10)
.background(
    isSelectedProvider
        ? Color.obAccent.opacity(0.06)
        : Color.obCardBg,
    in: RoundedRectangle(cornerRadius: 10)
)
.overlay(
    RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
            isSelectedProvider ? Color.obAccent : Color.obBorder,
            lineWidth: 1.5
        )
)
```

### API Key Field (below cards when BYOK provider selected)

```swift
VStack(alignment: .leading, spacing: 6) {
    TextField("sk-...", text: $apiKey)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.obBorderHover, lineWidth: 1)
        )

    // Focus state: border -> obAccent, shadow 0 0 0 3px rgba(124,58,237,0.08)

    Button("Get your API key at platform.openai.com/api-keys") { }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.obAccent)
        .buttonStyle(.plain)
}
.frame(maxWidth: 360)
```

### Settings Hint

```swift
Text("You can change this anytime in Settings")
    .font(.system(size: 12, weight: .regular))
    .foregroundStyle(Color.obTextTertiary)
    .multilineTextAlignment(.center)
```

### Skip Link

```swift
Button("Skip for now →") { viewModel.advanceToNextStep() }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.obTextTertiary)
    // Hover: color -> obAccent
```

---

## 5. Step 4: Try It Now

### Hero Keycap (large, pulsing)

```swift
VStack(spacing: 4) {
    Text("⌘")
        .font(.system(size: 28, weight: .bold))
        .foregroundStyle(Color.obAccent)
        .frame(minWidth: 80, minHeight: 56)
        .padding(.horizontal, 20)
        .background(
            LinearGradient(
                colors: [.white, Color.obSurface],
                startPoint: .top, endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.obAccent.opacity(0.15), lineWidth: 1.5)
        )
        .shadow(color: Color.obAccent.opacity(0.1), radius: 4, y: 2)
        // Pulse animation: alternating shadow glow
        // @keyframes keycapPulse: 0%/100% shadow normal, 50% shadow 0 0 0 6px rgba(124,58,237,0.08)

    Text("RIGHT COMMAND")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.obTextTertiary)
        .kerning(0.3)
        .textCase(.uppercase)
}
.padding(.bottom, 16)
```

### Transcription Box

Four states: waiting, recording, processing, result, success.

```swift
// WAITING state:
VStack(spacing: 8) {
    Text("Your transcription will appear here...")
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(Color.obTextTertiary)
        .italic()
}
.frame(maxWidth: 360, minHeight: 100)
.background(Color.obSurface, in: RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.obAccent.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
)

// RECORDING state:
// background: rgba(230,37,58,0.04)
// border: 1.5px solid rgba(230,37,58,0.2)
// Shows recording indicator with waveform bars + "Recording..." text
HStack(spacing: 10) {
    // Red pulsing dot (10x10)
    Circle()
        .fill(Color.obError)
        .frame(width: 10, height: 10)
        .opacity(pulsing ? 1 : 0.4)  // animate

    // Waveform: 7 bars, 3px wide, obError color
    // Heights: 8, 16, 12, 20, 14, 10, 18 px with staggered animation

    Text("Recording...")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.obError)
}
.frame(maxWidth: 360, minHeight: 100)
.background(Color.obError.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.obError.opacity(0.2), lineWidth: 1.5)
)

// RESULT state:
// background: white, border: 1.5px solid rgba(0,200,128,0.25)
// shadow: 0 4px 20px rgba(0,200,128,0.08)
// Text: 16px, aligned left, with rainbow accent bar on left
VStack(alignment: .leading) {
    HStack(spacing: 0) {
        // Rainbow accent bar
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.obRainbow)
            .frame(width: 3)
            .padding(.vertical, 2)

        Text(transcription)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color.obTextPrimary)
            .lineSpacing(16 * 0.6)  // lineHeight 1.6
            .padding(.leading, 14)
    }
}
.padding(20)
.frame(maxWidth: 360, minHeight: 100, alignment: .topLeading)
.background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.obSuccess.opacity(0.25), lineWidth: 1.5)
)
.shadow(color: Color.obSuccess.opacity(0.08), radius: 10, y: 4)

// SUCCESS state:
// background: obSuccessSoft, border: 1.5px solid rgba(0,200,128,0.3)
// Shows green check circle (36x36) + "Pasted to clipboard" text
VStack(spacing: 6) {
    Circle()
        .fill(Color.obSuccess)
        .frame(width: 36, height: 36)
        .overlay(
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        )
    Text("Pasted to clipboard")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.obSuccessText)  // #008a56
}
```

### Skip Link

```swift
Button("Skip this step →") { viewModel.advanceToNextStep() }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.obTextTertiary)
    // Aligns to trailing: alignSelf flex-end, marginTop auto, paddingTop 8
```

---

## 6. Step 5: Ready (You're All Set)

### Lips Icon: triumph expression

(Same lips SVG with `lips-triumph` class — vigorous bounce + glow animation)

### Title & Body

```swift
Text("You're All Set!")
    .font(.system(size: 22, weight: .heavy))
    .foregroundStyle(Color.obTextPrimary)
    .kerning(-0.4)
    .padding(.bottom, 6)

Text("EnviousWispr is running in your menu bar. Press **Right ⌘ (Command)** anytime to dictate.")
    .font(.system(size: 14, weight: .regular))
    .lineSpacing(7.7)
    .foregroundStyle(Color.obTextSecondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: 360)
    .padding(.bottom, 18)
```

### Enhancement Card (Toggle + Settings Link)

```swift
VStack(spacing: 0) {
    // Toggle Row
    HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
            Text("Enable Auto-Paste")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.obTextPrimary)
            Text("Automatically paste transcriptions into the active app.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.obTextSecondary)
                .lineSpacing(12 * 0.35)  // lineHeight 1.35
        }

        Spacer()

        // Toggle: 44x26, knob 22x22, green when on
        Toggle("", isOn: $autoPasteEnabled)
            .toggleStyle(.switch)
            .tint(Color.obSuccess)
    }
    .padding(.vertical, 6)

    // Divider
    Rectangle()
        .fill(Color.obSurface)
        .frame(height: 1)
        .padding(.vertical, 12)

    // Settings Link
    Button {
        // open settings
    } label: {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
            Text("Open Settings for more options")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.obAccent)
        .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
}
.padding(.horizontal, 18)
.padding(.vertical, 16)
.frame(maxWidth: 360)
.background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.obBorder, lineWidth: 1)
)
.shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1.5, y: 1)
.padding(.bottom, 18)
```

### Done Button (Full Width)

```swift
Button("Done") { onComplete() }
    .font(.system(size: 15, weight: .bold))
    .foregroundStyle(.white)
    .frame(maxWidth: 360)
    .padding(.vertical, 13)
    .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
// Hover: background -> #1a1230, shadow 0 4px 16px rgba(15,10,26,0.2), translateY(-1px)
```

---

## 7. Global: Button Styles

### btn-primary (dark)

```swift
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .kerning(-0.1)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
```

### btn-secondary (outline)

```swift
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.obTextSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.obBorderHover, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
```

### btn-accent (purple)

```swift
struct OnboardingAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obAccent, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
```

### btn-error (red)

```swift
struct OnboardingErrorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obError, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
```

---

## 8. Animations & Transitions

### Step Transition

```swift
// Current: .move(edge: .trailing).combined(with: .opacity), duration 0.25
// Mockup: @keyframes stepFadeIn: from opacity 0, translateY(12px) to opacity 1, translateY(0)
// duration: 0.35s, easing: cubic-bezier(0.16,1,0.3,1)

// Target SwiftUI:
.transition(.asymmetric(
    insertion: .move(edge: .bottom).combined(with: .opacity),
    removal: .opacity
))
.animation(.interpolatingSpring(stiffness: 300, damping: 30), value: viewModel.currentStep)
// Or approximate cubic-bezier(0.16,1,0.3,1) with .spring(response: 0.35, dampingFraction: 0.8)
```

### Progress Dot Transition

```swift
// transition: all 0.4s cubic-bezier(0.16,1,0.3,1)
.animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.currentStep)
```

---

## 9. Layout Summary — Spacing Rhythm

| Element | Padding/Margin | Notes |
|---------|---------------|-------|
| Window content | top 24, sides 28, bottom 28 | `.padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 28)` |
| Progress bar bottom | 22 | `margin-bottom: 22px` |
| Lips icon bottom | 18 | `.padding(.bottom, 18)` |
| Step title bottom | 6 | `.padding(.bottom, 6)` |
| Step body bottom | 18 | `.padding(.bottom, 18)` |
| Icon flow bottom | 18 | `.padding(.bottom, 18)` |
| Callout card bottom | 14 | `.padding(.bottom, 14)` |
| Polish cards bottom | 14 | `.padding(.bottom, 14)` |
| Enhancement card bottom | 18 | `.padding(.bottom, 18)` |
| Button row top | 10 | `.padding(.top, 10)` |
| Card internal padding | 16-18 | Varies by card type |

---

## 10. Key Differences: Current vs Mockup

| Aspect | Current | Mockup |
|--------|---------|--------|
| Step indicator | Circles (22px) + text labels + thin connector | Circles (30px) + no labels + thick rainbow connectors |
| Main icon | SF Symbols in colored pills | Animated rainbow lips SVG |
| Color scheme | System accent + secondary | Custom brand palette (violet/green/dark) |
| Window size | 500x550 | 460x~480 |
| Buttons | System `.borderedProminent` | Custom dark (#0f0a1a) or accent (#7c3aed) |
| Cards | Simple selection cards | Rich cards with badges, flip animation for BYOK |
| Font weights | System defaults | Heavy (800) titles, distinct hierarchy |
| Shadows | None | Subtle card/window shadows |
| Transitions | Slide left/right | Fade up from bottom |
| Step 2 download | ProgressView spinner | Custom spinner + rainbow progress bar + hero keycap |
| Step 4 transcription | Simple rounded box | State-aware box (dashed waiting, red recording, rainbow result) |
| Step 5 done button | System `.borderedProminent` | Full-width custom dark button |
| Navigation footer | Standard system buttons | Removed — buttons are inline in each step |

---

## 11. Rainbow Lips Icon — CENTRAL BRAND ELEMENT

The animated rainbow lips SVG is the **single most distinctive** visual in the onboarding flow. It replaces ALL generic SF Symbol icons (`mic.fill`, `sparkles`, `checkmark.seal.fill`, etc.) in the current SwiftUI code. Every step shows the SAME lips shape but with a different animation expression.

### 11.1 SVG Geometry (Static Shape)

**ViewBox**: `0 0 256 256` with content group translated `translate(8, 13)`
**Container**: 70x70pt in the mockup (`lips-wrap`)
**Glow filter**: Gaussian blur stdDeviation=4, merged with source (soft outer glow)

**18 rounded rectangles** — 9 upper bars + 9 lower bars, each `width: 14, rx: 5`:

```swift
// Bar data: (index, x, y, height, color, opacity)
// Upper bars (grow downward from top, origin = bottom center)
struct LipsBar {
    let index: Int
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat
    let color: Color
    let opacity: Double
    let isUpper: Bool
}

static let upperBars: [LipsBar] = [
    LipsBar(index: 0, x: 16,  y: 84.2,  height: 20, color: Color(hex: "#ff2a40"), opacity: 0.92, isUpper: true),
    LipsBar(index: 1, x: 40,  y: 65.75, height: 32, color: Color(hex: "#ff8c00"), opacity: 0.92, isUpper: true),
    LipsBar(index: 2, x: 64,  y: 43.36, height: 48, color: Color(hex: "#ffd700"), opacity: 0.92, isUpper: true),
    LipsBar(index: 3, x: 88,  y: 63.04, height: 36, color: Color(hex: "#adff2f"), opacity: 0.92, isUpper: true),
    LipsBar(index: 4, x: 112, y: 81.43, height: 24, color: Color(hex: "#00fa9a"), opacity: 0.92, isUpper: true),
    LipsBar(index: 5, x: 136, y: 63.04, height: 36, color: Color(hex: "#00ffff"), opacity: 0.92, isUpper: true),
    LipsBar(index: 6, x: 160, y: 43.36, height: 48, color: Color(hex: "#1e90ff"), opacity: 0.92, isUpper: true),
    LipsBar(index: 7, x: 184, y: 65.75, height: 32, color: Color(hex: "#4169e1"), opacity: 0.92, isUpper: true),
    LipsBar(index: 8, x: 208, y: 84.2,  height: 20, color: Color(hex: "#8a2be2"), opacity: 0.92, isUpper: true),
]

static let lowerBars: [LipsBar] = [
    LipsBar(index: 0, x: 16,  y: 125.8,  height: 20, color: Color(hex: "#4169e1"), opacity: 0.88, isUpper: false),
    LipsBar(index: 1, x: 40,  y: 119.35, height: 36, color: Color(hex: "#1e90ff"), opacity: 0.88, isUpper: false),
    LipsBar(index: 2, x: 64,  y: 112.96, height: 48, color: Color(hex: "#00ffff"), opacity: 0.88, isUpper: false),
    LipsBar(index: 3, x: 88,  y: 120.64, height: 60, color: Color(hex: "#00fa9a"), opacity: 0.88, isUpper: false),
    LipsBar(index: 4, x: 112, y: 127.03, height: 68, color: Color(hex: "#adff2f"), opacity: 0.88, isUpper: false),
    LipsBar(index: 5, x: 136, y: 120.64, height: 60, color: Color(hex: "#ffd700"), opacity: 0.88, isUpper: false),
    LipsBar(index: 6, x: 160, y: 112.96, height: 48, color: Color(hex: "#ff8c00"), opacity: 0.88, isUpper: false),
    LipsBar(index: 7, x: 184, y: 119.35, height: 36, color: Color(hex: "#ff2a40"), opacity: 0.88, isUpper: false),
    LipsBar(index: 8, x: 208, y: 125.8,  height: 20, color: Color(hex: "#8a2be2"), opacity: 0.88, isUpper: false),
]
```

**Color pattern**: Upper bars are a left-to-right rainbow (red -> violet). Lower bars are a reversed/complementary rainbow (blue -> red -> violet). The symmetry creates a "lips" or "mouth" shape with the tallest bars in the middle forming the widest opening.

**Shape note**: The bars form an arch — tallest (48pt) at indices 2 and 6, shortest (20pt) at the edges 0 and 8. The gap between upper bar bottoms and lower bar tops (~20-40pt depending on index) forms the "mouth opening."

### 11.2 Animation States — Complete Reference

Each animation works by applying `scaleY()` transforms to individual bars. Upper bars scale from `transform-origin: bottom center` (they grow upward). Lower bars scale from `transform-origin: top center` (they grow downward). Together they create the illusion of a mouth opening/closing.

#### Expression Enum

```swift
enum LipsExpression {
    case idle       // gentle breathing
    case denied     // sad, shrunk, desaturated
    case happy      // celebratory bounce
    case equalizer  // audio equalizer (moderate)
    case wave       // wave propagation outward
    case drooping   // failed, droopy
    case shimmer    // brightness/sparkle pulse
    case recording  // vigorous fast equalizer
    case pulse      // synchronized gentle wave
    case smile      // curved upward (smile shape)
    case triumph    // explosive bounce + glow
}
```

#### A) IDLE — Gentle Breathing (Step 1 default, Step 4 waiting)

```
Animation: lipsBreath
  0%, 100%  → scaleY(1.0)
  50%       → scaleY(0.88)
Duration: 2.8s, easing: ease-in-out, repeat: infinite
Upper bars: transform-origin bottom center
Lower bars: transform-origin top center

Per-bar delay:
  index 0: 0.0s    index 1: 0.1s    index 2: 0.2s
  index 3: 0.15s   index 4: 0.05s   index 5: 0.25s
  index 6: 0.3s    index 7: 0.1s    index 8: 0.2s
```

SwiftUI implementation:
```swift
// Each bar has a @State scaleY driven by a repeating timer or TimelineView
// Use TimelineView(.animation) for continuous animation:
TimelineView(.animation) { timeline in
    let t = timeline.date.timeIntervalSinceReferenceDate
    ForEach(allBars) { bar in
        let phase = (t - bar.delay).truncatingRemainder(dividingBy: 2.8) / 2.8
        let scale = 1.0 - 0.12 * sin(phase * .pi * 2)  // oscillate 1.0 ↔ 0.88
        RoundedRectangle(cornerRadius: 5)
            .fill(bar.color.opacity(bar.opacity))
            .frame(width: 14, height: bar.height)
            .scaleEffect(y: scale, anchor: bar.isUpper ? .bottom : .top)
            .position(x: bar.x + 7, y: bar.y + bar.height / 2)
    }
}
```

Delays array: `[0.0, 0.1, 0.2, 0.15, 0.05, 0.25, 0.3, 0.1, 0.2]`

---

#### B) DENIED — Sad, Desaturated (Step 1 mic denied)

```
Upper bars animation: lipsShrinkUpper
  0%, 100%  → scaleY(0.45)
  50%       → scaleY(0.38)
Duration: 3.0s, easing: ease-in-out, repeat: infinite
transform-origin: bottom center
filter: saturate(0.25) brightness(0.85)

Lower bars animation: lipsShrinkLower
  0%, 100%  → scaleY(0.35)
  50%       → scaleY(0.28)
Duration: 3.0s, easing: ease-in-out, repeat: infinite
transform-origin: top center
filter: saturate(0.25) brightness(0.85)

No per-bar delay — all bars animate together.
```

SwiftUI:
```swift
// All bars are permanently shrunken (scaleY ~0.3-0.45) with slight oscillation
// Desaturation: .saturation(0.25).brightness(-0.15)
RoundedRectangle(cornerRadius: 5)
    .fill(bar.color.opacity(bar.opacity))
    .frame(width: 14, height: bar.height)
    .scaleEffect(y: bar.isUpper ? upperScale : lowerScale, anchor: bar.isUpper ? .bottom : .top)
    .saturation(0.25)
    .brightness(-0.15)
```

---

#### C) HAPPY — Celebratory Bounce (Step 1 mic granted)

```
Upper bars animation: lipsBounceUpper
  0%    → scaleY(1.0)
  30%   → scaleY(1.25)   // overshoot up
  55%   → scaleY(0.95)   // undershoot
  75%   → scaleY(1.1)    // settle high
  100%  → scaleY(1.0)    // rest
Duration: 0.6s, easing: cubic-bezier(0.34,1.56,0.64,1), fill: forwards (plays ONCE)

Lower bars animation: lipsBounce
  0%    → scaleY(1.0)
  30%   → scaleY(1.2)
  55%   → scaleY(0.9)
  75%   → scaleY(1.05)
  100%  → scaleY(1.0)
Duration: 0.6s, easing: cubic-bezier(0.34,1.56,0.64,1), fill: forwards (plays ONCE)

Per-bar delay (symmetric from edges):
  index 0: 0.0s    index 1: 0.04s   index 2: 0.08s
  index 3: 0.06s   index 4: 0.02s   index 5: 0.06s
  index 6: 0.08s   index 7: 0.04s   index 8: 0.0s
```

SwiftUI:
```swift
// One-shot spring animation triggered on state change
// Use .spring(response: 0.3, dampingFraction: 0.4, blendDuration: 0) for overshoot bounce
// Stagger using DispatchQueue.main.asyncAfter for each bar's delay
withAnimation(.interpolatingSpring(stiffness: 200, damping: 8).delay(bar.delay)) {
    barScales[bar.index] = 1.0 // animate FROM current TO 1.0 through overshoot
}
```

---

#### D) EQUALIZER — Audio Bars (Step 2 downloading)

```
Each bar has its OWN unique keyframe + duration + delay:

Bar 0: scaleY 0.5 ↔ 1.1,  duration 0.45s, delay 0s
Bar 1: scaleY 1.0 ↔ 0.4,  duration 0.52s, delay 0.07s
Bar 2: scaleY 0.7 ↔ 1.2,  duration 0.38s, delay 0.14s
Bar 3: scaleY 1.1 ↔ 0.5,  duration 0.61s, delay 0.05s
Bar 4: scaleY 0.6 ↔ 1.15, duration 0.44s, delay 0.11s
Bar 5: scaleY 1.0 ↔ 0.55, duration 0.57s, delay 0.03s
Bar 6: scaleY 0.75 ↔ 1.05, duration 0.41s, delay 0.18s
Bar 7: scaleY 1.1 ↔ 0.45, duration 0.49s, delay 0.08s
Bar 8: scaleY 0.55 ↔ 1.1, duration 0.55s, delay 0.13s

All: ease-in-out, repeat infinite
Upper: transform-origin bottom center
Lower: transform-origin top center
Same animation applied to BOTH upper and lower bar of same index
```

SwiftUI:
```swift
struct EqBarConfig {
    let minScale: CGFloat
    let maxScale: CGFloat
    let duration: Double
    let delay: Double
}

static let eqConfigs: [EqBarConfig] = [
    EqBarConfig(minScale: 0.5,  maxScale: 1.1,  duration: 0.45, delay: 0.0),
    EqBarConfig(minScale: 0.4,  maxScale: 1.0,  duration: 0.52, delay: 0.07),
    EqBarConfig(minScale: 0.7,  maxScale: 1.2,  duration: 0.38, delay: 0.14),
    EqBarConfig(minScale: 0.5,  maxScale: 1.1,  duration: 0.61, delay: 0.05),
    EqBarConfig(minScale: 0.6,  maxScale: 1.15, duration: 0.44, delay: 0.11),
    EqBarConfig(minScale: 0.55, maxScale: 1.0,  duration: 0.57, delay: 0.03),
    EqBarConfig(minScale: 0.75, maxScale: 1.05, duration: 0.41, delay: 0.18),
    EqBarConfig(minScale: 0.45, maxScale: 1.1,  duration: 0.49, delay: 0.08),
    EqBarConfig(minScale: 0.55, maxScale: 1.1,  duration: 0.55, delay: 0.13),
]

// TimelineView-based:
let phase = ((t - config.delay).truncatingRemainder(dividingBy: config.duration)) / config.duration
let scale = config.minScale + (config.maxScale - config.minScale) * (0.5 + 0.5 * sin(phase * .pi * 2))
```

---

#### E) WAVE — Propagation Outward (Step 2 download complete)

```
Animation: lipsWave
  0%    → scaleY(0.4)
  40%   → scaleY(1.2)    // overshoot
  70%   → scaleY(0.9)    // undershoot
  100%  → scaleY(1.0)    // rest
Duration: 0.8s, easing: cubic-bezier(0.34,1.56,0.64,1), fill: forwards (plays ONCE)

Per-bar delay (propagates outward from center, symmetric):
  index 0: 0.0s    index 1: 0.06s   index 2: 0.12s
  index 3: 0.18s   index 4: 0.24s   index 5: 0.18s
  index 6: 0.12s   index 7: 0.06s   index 8: 0.0s

NOTE: Delay is SYMMETRIC — edges fire first (0s), center fires last (0.24s).
This creates a wave that starts at both edges and meets in the middle.
```

---

#### F) DROOPING — Failed Download (Step 2 download failed)

```
Animation: lipsDroop
  0%, 100%  → scaleY(0.3) rotate(0deg)
  50%       → scaleY(0.25) rotate(2deg)
Duration: 2.5s, easing: ease-in-out, repeat: infinite
transform-origin: center center (BOTH upper and lower)
filter: saturate(0.2) brightness(0.75)

No per-bar delay — all bars animate together.
```

SwiftUI:
```swift
// Bars are very shrunken (~0.25-0.3) with slight rotation wobble
// .saturation(0.2).brightness(-0.25) for washed-out sad look
// .rotationEffect(.degrees(rotAngle)) with small oscillation
```

---

#### G) SHIMMER — Brightness Pulse (Step 3 AI Polish)

```
Animation: lipsShimmer
  0%    → opacity 0.92, brightness(1.0)
  50%   → opacity 1.0,  brightness(1.4) saturate(1.2)
  100%  → opacity 0.92, brightness(1.0)
Duration: 1.8s, easing: ease-in-out, repeat: infinite

Per-bar delay (symmetric, propagates from edges to center):
  index 0: 0.0s    index 1: 0.2s    index 2: 0.4s
  index 3: 0.6s    index 4: 0.8s    index 5: 0.6s
  index 6: 0.4s    index 7: 0.2s    index 8: 0.0s

NOTE: No scaleY change — bars keep their static shape.
Only opacity + brightness + saturation change = "sparkle" sweep from edges to center.
```

SwiftUI:
```swift
// TimelineView-based brightness/opacity oscillation
let phase = ((t - bar.shimmerDelay).truncatingRemainder(dividingBy: 1.8)) / 1.8
let sinVal = sin(phase * .pi * 2)
let brightness = sinVal > 0 ? sinVal * 0.4 : 0  // 1.0 → 1.4 peak
let opacity = 0.92 + sinVal * 0.08               // 0.92 → 1.0 peak
let saturation = 1.0 + (sinVal > 0 ? sinVal * 0.2 : 0)

RoundedRectangle(...)
    .opacity(opacity)
    .brightness(brightness)
    .saturation(saturation)
```

---

#### H) RECORDING — Vigorous Fast Equalizer (Step 4 recording)

Same structure as EQUALIZER but with **faster durations** and **wider scaleY range**:

```
Bar 0: scaleY 0.4 ↔ 1.3,   duration 0.22s, delay 0s
Bar 1: scaleY 0.3 ↔ 1.2,   duration 0.27s, delay 0.03s
Bar 2: scaleY 0.6 ↔ 1.4,   duration 0.19s, delay 0.07s
Bar 3: scaleY 0.4 ↔ 1.3,   duration 0.31s, delay 0.02s
Bar 4: scaleY 0.5 ↔ 1.35,  duration 0.24s, delay 0.05s
Bar 5: scaleY 0.35 ↔ 1.25, duration 0.28s, delay 0.01s
Bar 6: scaleY 0.65 ↔ 1.3,  duration 0.21s, delay 0.09s
Bar 7: scaleY 0.4 ↔ 1.2,   duration 0.25s, delay 0.04s
Bar 8: scaleY 0.45 ↔ 1.25, duration 0.29s, delay 0.06s
```

```swift
static let recConfigs: [EqBarConfig] = [
    EqBarConfig(minScale: 0.4,  maxScale: 1.3,  duration: 0.22, delay: 0.0),
    EqBarConfig(minScale: 0.3,  maxScale: 1.2,  duration: 0.27, delay: 0.03),
    EqBarConfig(minScale: 0.6,  maxScale: 1.4,  duration: 0.19, delay: 0.07),
    EqBarConfig(minScale: 0.4,  maxScale: 1.3,  duration: 0.31, delay: 0.02),
    EqBarConfig(minScale: 0.5,  maxScale: 1.35, duration: 0.24, delay: 0.05),
    EqBarConfig(minScale: 0.35, maxScale: 1.25, duration: 0.28, delay: 0.01),
    EqBarConfig(minScale: 0.65, maxScale: 1.3,  duration: 0.21, delay: 0.09),
    EqBarConfig(minScale: 0.4,  maxScale: 1.2,  duration: 0.25, delay: 0.04),
    EqBarConfig(minScale: 0.45, maxScale: 1.25, duration: 0.29, delay: 0.06),
]
```

Key difference from equalizer: durations are ~0.19-0.31s (vs 0.38-0.61s) and scale ranges are wider. This makes the bars move 2x faster with more dramatic amplitude = more energetic.

---

#### I) PULSE — Synchronized Gentle Wave (Step 4 processing)

```
Animation: lipsPulse
  0%, 100%  → scaleY(0.7)
  50%       → scaleY(1.1)
Duration: 1.1s, easing: ease-in-out, repeat: infinite

Per-bar delay (symmetric, propagates from edges to center):
  index 0: 0.0s    index 1: 0.06s   index 2: 0.12s
  index 3: 0.18s   index 4: 0.22s   index 5: 0.18s
  index 6: 0.12s   index 7: 0.06s   index 8: 0.0s
```

All bars share the SAME keyframe/duration, only differing in delay. Creates a "breathing wave" that ripples from edges to center.

---

#### J) SMILE — Curved Upward (Step 4 result success)

```
Base animation (all bars): lipsSmileUpper/Lower
  0%, 100%  → scaleY(0.9)
  50%       → scaleY(1.05)
Duration: 2.2s, ease-in-out, infinite

PLUS static scaleY overrides to CREATE THE SMILE CURVE:
  Upper bars:
    u0, u8: scaleY(1.3)   — tall at edges
    u1, u7: scaleY(1.1)   — medium
    u2-u6: scaleY(1.0) default (u4 specifically: scaleY(0.6) — shortest in center)
    → Creates a FROWN shape for upper lip (tall edges, short center)

  Lower bars:
    l0, l8: scaleY(0.5)   — short at edges
    l3, l4, l5: scaleY(1.3) — tall in center
    l1, l2, l6, l7: default
    → Creates a SMILE shape for lower lip (short edges, tall center)

Combined: upper lip curves down + lower lip curves up = OPEN SMILE
```

SwiftUI:
```swift
static let smileUpperScales: [CGFloat] = [1.3, 1.1, 1.0, 1.0, 0.6, 1.0, 1.0, 1.1, 1.3]
static let smileLowerScales: [CGFloat] = [0.5, 1.0, 1.0, 1.3, 1.3, 1.3, 1.0, 1.0, 0.5]

// Apply static scale * animated oscillation (0.9 ↔ 1.05)
let animatedScale = 0.9 + 0.15 * (0.5 + 0.5 * sin(phase * .pi * 2))
let finalScale = staticScale * animatedScale
```

---

#### K) TRIUMPH — Explosive Bounce + Glow (Step 5 all set)

```
Animation: lipsTriumph
  0%    → scaleY(0.5)
  40%   → scaleY(1.35)   // big overshoot
  65%   → scaleY(1.05)   // slight undershoot
  80%   → scaleY(1.2)    // secondary bounce
  100%  → scaleY(1.1)    // settle slightly enlarged
Duration: 0.9s, easing: cubic-bezier(0.34,1.56,0.64,1), fill: forwards (plays ONCE)

Per-bar delay (symmetric from edges):
  index 0: 0.0s    index 1: 0.05s   index 2: 0.1s
  index 3: 0.15s   index 4: 0.18s   index 5: 0.15s
  index 6: 0.1s    index 7: 0.05s   index 8: 0.0s

PLUS after the bounce completes (0.9s), a continuous glow animation starts:
  lipsTriumphGlow (applied to the parent <g>):
    0%, 100% → brightness(1.0), drop-shadow(0 0 4px rgba(124,58,237,0.2))
    50%      → brightness(1.2), drop-shadow(0 0 12px rgba(124,58,237,0.4))
  Duration: 1.6s, ease-in-out, infinite, startDelay: 0.9s
```

SwiftUI:
```swift
// Phase 1: One-shot staggered bounce (0-0.9s)
// Phase 2: Continuous glow pulse (after 0.9s)
// Use .shadow() + .brightness() oscillation on the parent container

// For the glow:
.shadow(color: Color.obAccent.opacity(glowOpacity), radius: glowRadius)
.brightness(glowBrightness)
// where glowOpacity oscillates 0.2 ↔ 0.4, radius 4 ↔ 12, brightness 0 ↔ 0.2
```

---

### 11.3 State Transition Map — Which Expression for Which Condition

```
Step 1 (Welcome):
  Default state       → lips-idle
  Mic permission denied → lips-denied
  Mic permission granted → lips-happy (one-shot bounce, then auto-advance)

Step 2 (Model Download):
  Downloading          → lips-equalizer
  Download failed      → lips-drooping
  Download complete    → lips-wave (one-shot, then auto-advance)

Step 3 (AI Polish):
  Always               → lips-shimmer (the sparkle/polish metaphor)

Step 4 (Try It Now):
  Waiting for input    → lips-idle
  Recording active     → lips-recording
  Processing/transcribing → lips-pulse
  Result displayed     → lips-smile
  Success (pasted)     → lips-smile (or transition to idle)

Step 5 (Ready):
  Always               → lips-triumph (explosive entrance, then continuous glow)
```

### 11.4 SwiftUI Architecture Recommendation

```swift
/// The rainbow lips brand icon with animated expressions.
struct RainbowLipsView: View {
    let expression: LipsExpression
    let size: CGFloat  // default 70

    // Internal animation state
    @State private var animationPhase: CGFloat = 0
    @State private var bounceCompleted = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, canvasSize in
                let scale = canvasSize.width / 256.0
                context.translateBy(x: 8 * scale, y: 13 * scale)

                // Draw each bar with expression-specific scaleY
                for bar in Self.allBars {
                    let scaleY = computeScale(for: bar, at: timeline.date)
                    let rect = CGRect(
                        x: bar.x * scale,
                        y: bar.y * scale,
                        width: 14 * scale,
                        height: bar.height * scale
                    )
                    let anchor = bar.isUpper ? UnitPoint.bottom : UnitPoint.top

                    context.drawLayer { ctx in
                        ctx.scaleBy(x: 1, y: scaleY, anchor: anchor)
                        let path = RoundedRectangle(cornerRadius: 5 * scale)
                            .path(in: rect)
                        ctx.fill(path, with: .color(bar.color.opacity(bar.opacity)))
                    }
                }
            }
            // Glow filter: soft shadow behind the whole canvas
            .shadow(color: .white.opacity(0.3), radius: 4)
        }
        .frame(width: size, height: size)
    }

    private func computeScale(for bar: LipsBar, at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        switch expression {
        case .idle:      return idleScale(bar: bar, t: t)
        case .denied:    return deniedScale(bar: bar, t: t)
        case .happy:     return happyScale(bar: bar, t: t)
        case .equalizer: return equalizerScale(bar: bar, t: t)
        case .recording: return recordingScale(bar: bar, t: t)
        // ... etc for each expression
        }
    }
}
```

**Key implementation notes:**
- Use `Canvas` for 60fps rendering of 18 bars (more efficient than 18 separate SwiftUI views)
- Use `TimelineView(.animation)` for continuous animation without timers
- Expression change is driven by the parent view setting `expression:` — no internal state machine needed
- One-shot animations (happy, wave, triumph) need a `startTime` reference captured when expression changes
- Glow filter: use `.shadow()` on the Canvas container, not per-bar
- Desaturation (denied, drooping): use `.saturation()` and `.brightness()` modifiers on the Canvas

### 11.5 Glow Filter

The SVG applies a Gaussian blur filter (stdDeviation=4) merged with the source graphic. This creates a soft colored glow behind each bar. In SwiftUI:

```swift
// Option A: .shadow() on the Canvas (simpler, less accurate)
.shadow(color: .clear, radius: 4)  // + per-bar colored shadows in Canvas

// Option B: Render bars twice — once blurred (background glow), once sharp (foreground)
// This is closer to the SVG feMerge(blur + source) pattern
ZStack {
    // Glow layer
    Canvas { ... }  // same bars
        .blur(radius: 4)
        .opacity(0.5)

    // Sharp layer
    Canvas { ... }  // same bars
}
```

---

## 12. Navigation Structure Change

The mockup does NOT have a separate navigation footer. All buttons are inline within each step's content area (in a `.button-row` at the bottom of each step panel). The `skip-link` is also inline.

**Current SwiftUI has:**
- `navigationFooter` — a separate footer bar with Back/Next buttons
- Dividers above and below content

**Target SwiftUI should:**
- Remove the separate `navigationFooter`
- Remove the Dividers around content
- Move all step-specific buttons into each step view
- Use the `button-row` pattern: VStack(spacing: 8) with max-width 360, margin-top auto (Spacer push)
