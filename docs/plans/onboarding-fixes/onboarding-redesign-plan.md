# Onboarding Redesign Plan

## Status
- Task #1: Designer extracting specs from HTML mockup → /tmp/onboarding-design-spec.md
- Task #5: Phase A — RainbowLipsView component (NEW file, no conflicts)
- Task #6: Phase B — Step indicator + color palette + global layout (OnboardingView.swift)
- Task #7: Phase C — Restyle Steps 1-3 (OnboardingView.swift)
- Task #8: Phase D — Restyle Steps 4-5 + build verify (OnboardingView.swift)

## Parallelization Strategy
- Phase A (new file) can run IN PARALLEL with Phases B-D (different files)
- Phases B/C/D all touch OnboardingView.swift → must be sequential OR done by one agent
- Best approach: 2 agents after spec is ready:
  - Agent 1: Phase A (RainbowLipsView.swift)
  - Agent 2: Phases B+C+D (OnboardingView.swift full restyle)

## Key Files
- HTML mockup (source of truth): /Users/m4pro_sv/Desktop/EnviousWispr/docs/designs/onboarding-mockup.html
- Current SwiftUI: /Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift
- Design spec (being produced): /tmp/onboarding-design-spec.md
- New file to create: Sources/EnviousWispr/Views/Onboarding/RainbowLipsView.swift

## Rainbow Lips Animation States (from HTML CSS lines 1442-1685)
| State | CSS Class | Condition | Animation |
|-------|-----------|-----------|-----------|
| idle | lips-idle | Step 1 default, Step 4 waiting | Gentle breathing scaleY |
| denied | lips-denied | Step 1 mic denied | Shrunk, desaturated |
| happy | lips-happy | Step 1 mic granted | Bounce |
| equalizer | lips-equalizer | Step 2 downloading | Audio equalizer bars |
| wave | lips-wave | Step 2 download complete | Wave propagation |
| drooping | lips-drooping | Step 2 download failed | Droopy, desaturated |
| shimmer | lips-shimmer | Step 3 AI polish | Brightness pulse |
| recording | lips-recording | Step 4 recording | Fast vigorous equalizer |
| pulse | lips-pulse | Step 4 processing | Gentle synchronized wave |
| smile | lips-smile | Step 4 result success | Curved smile shape |
| triumph | lips-triumph | Step 5 all set | Explosive bounce + glow |

## Color Palette (from HTML CSS :root)
- --accent: #7c3aed (purple)
- --accent-hover: #6d28d9
- --accent-soft: rgba(124,58,237,0.1)
- --success: #00c880 (green)
- --success-soft: rgba(0,200,128,0.1)
- --error: #e6253a (red)
- --error-soft: rgba(230,37,58,0.1)
- --text-primary: #0f0a1a
- --text-secondary: #4a3d60
- --text-tertiary: #7d6f96
- --surface: #f0ecf9
- --card-bg: #ffffff
- --btn-dark: #0f0a1a
- --border: rgba(138,43,226,0.06)

## Rainbow Bar Colors (SVG rect fills)
Upper bars (left to right): #ff2a40, #ff8c00, #ffd700, #adff2f, #00fa9a, #00ffff, #1e90ff, #4169e1, #8a2be2
Lower bars (left to right): #4169e1, #1e90ff, #00ffff, #00fa9a, #adff2f, #ffd700, #ff8c00, #ff2a40, #8a2be2

## Progress Dots
- Size: 30x30px circles
- States: upcoming (surface bg, tertiary text), current (accent bg, white text, shadow), completed (success green, white checkmark)
- Connectors: 28px wide, 2px tall, rainbow gradient when done
