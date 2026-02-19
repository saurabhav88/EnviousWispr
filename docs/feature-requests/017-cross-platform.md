# Feature: Cross-Platform Support (Windows, Linux)

**ID:** 017
**Category:** Platform & Distribution
**Priority:** Low
**Inspired by:** Handy — full support for macOS, Windows (x64 + ARM64), Linux (x64 + ARM64)
**Status:** Ready for Implementation

## Problem

EnviousWispr only runs on macOS with Apple Silicon. Users on Windows or Linux cannot use the app.

## Proposed Solution

This is a fundamental architectural decision. Options:

**Option A: Stay macOS-only (recommended for now)**
- Focus on being the best macOS dictation app
- Leverage CoreML, Neural Engine, native SwiftUI
- Much less maintenance burden

**Option B: Tauri-based rewrite (like Handy)**
- Rewrite in Rust + React/TypeScript
- Use whisper.cpp for cross-platform ASR
- Lose CoreML/Neural Engine performance advantage
- Massive effort — essentially a new app

**Option C: Companion apps**
- Keep macOS app as-is
- Build separate Windows/Linux apps sharing design philosophy
- Could share LLM connector logic via a shared library

## Implementation Plan

This is an analysis document. No code will be written for cross-platform support at this time. The recommendation is **Option A: Stay macOS-only** for the foreseeable future.

---

### Architecture Analysis

#### What Makes EnviousWispr macOS-Specific

Every significant component in the current architecture is tied to an Apple framework:

**Audio capture — `AudioCaptureManager.swift`**
Uses `AVAudioEngine` and `AVAudioConverter` from `AVFoundation`. These are Apple-only APIs. On Windows, the equivalent is WASAPI (Windows Audio Session API), exposed via C or COM interfaces. On Linux, the equivalent is PulseAudio or ALSA. Neither has a Swift wrapper. Both require a complete rewrite of `AudioCaptureManager`.

**ASR — `ASRManager.swift` + FluidAudio + WhisperKit**
FluidAudio uses CoreML and Apple's Neural Engine. It is Apple Silicon exclusive — the `Float16` type used internally is unavailable on x86_64. WhisperKit also targets CoreML. Cross-platform ASR would require replacing both backends with `whisper.cpp` (C/C++) or ONNX Runtime, losing the Neural Engine speed advantage that is EnviousWispr's primary differentiator.

**VAD — `SilenceDetector.swift` via FluidAudio's `VadManager`**
FluidAudio's Silero VAD implementation is CoreML-backed. Cross-platform would need the raw ONNX Silero model run via a different runtime.

**UI — SwiftUI**
SwiftUI is Apple-platform only. A cross-platform UI would require a complete rewrite in another framework (Tauri/React, Electron, Qt, or native per-platform).

**Menu bar — `AppDelegate.swift` using `NSStatusItem`**
`NSStatusBar`, `NSStatusItem`, `NSMenu`, `NSMenuItem` are all AppKit-only. Windows uses the System Tray (`Shell_NotifyIcon`); Linux uses `libappindicator` or `StatusNotifierItem`.

**Global hotkeys — `HotkeyService.swift` using `NSEvent`**
`NSEvent.addGlobalMonitorForEvents(matching:)` requires macOS Accessibility permission. Windows uses `RegisterHotKey`. Linux uses `XGrabKey` (X11) or `inhibit_shortcuts` (Wayland).

**Paste — `PasteService.swift` using `NSPasteboard`**
`NSPasteboard` is AppKit-only. Windows uses `OpenClipboard`/`SetClipboardData`. Linux uses `xclip`/`wl-copy`.

**Keychain — `KeychainManager.swift`**
macOS Keychain Services are Apple-only. Windows uses DPAPI (`CryptProtectData`). Linux uses `libsecret`/`gnome-keyring`.

**Sparkle updates**
Sparkle is macOS-only. Cross-platform would need per-platform update mechanisms.

**Permissions — `PermissionsService.swift`**
`AVCaptureDevice.requestAccess(for:)` and `AXIsProcessTrustedWithOptions` are macOS-only. Windows and Linux have different permission models.

**Total macOS-specific API surface: 100% of the codebase.** There is no shared layer that could be extracted for reuse across platforms.

---

### Option A: Stay macOS-Only (Recommended)

**Recommendation: Do not pursue cross-platform support.**

EnviousWispr's core value proposition is speed: local transcription on Apple Silicon using the Neural Engine via CoreML. The M-series Neural Engine delivers transcription at 20-100x real-time — performance that cannot be replicated on x86 Windows/Linux hardware using whisper.cpp on CPU, or even whisper.cpp with CUDA on an Nvidia GPU for the same power envelope.

The target user is a macOS power user who wants system-level dictation without sending audio to the cloud. This user profile is inherently macOS-centric. Cross-platform dilutes focus without addressing the core audience.

**Effort to stay macOS-only:** Zero additional effort. Continue improving the macOS experience.

**Key actions for Option A:**
- Add Apple Silicon to the marketing copy explicitly ("Optimized for Apple Silicon Neural Engine")
- Focus future development on macOS-specific features: Shortcuts integration, Services menu, Spotlight search over transcripts
- Invest in quality over breadth

---

### Option B: Tauri-Based Rewrite

**Effort estimate: 6-12 months of full-time engineering for a single developer.**

Tauri is a Rust framework that wraps a system WebView (WKWebView on macOS, WebView2 on Windows, WebKitGTK on Linux) with a Rust backend. The frontend is React/TypeScript or similar. Handy uses this architecture.

**What would be required:**

1. Rewrite all audio capture in Rust using `cpal` (cross-platform audio library)
2. Replace FluidAudio + WhisperKit with `whisper-rs` (Rust bindings to whisper.cpp)
3. Replace Silero VAD with a cross-platform ONNX Runtime binding
4. Rewrite the full UI in React/TypeScript (~8 SwiftUI views)
5. Replace AppKit menu bar with Tauri's system tray API
6. Replace NSEvent hotkeys with `global-hotkey` Rust crate
7. Replace NSPasteboard with `arboard` Rust crate
8. Replace macOS Keychain with `keyring` Rust crate (cross-platform secret storage)
9. Replace Sparkle with Tauri's built-in updater
10. Set up GitHub Actions CI for macOS/Windows/Linux builds (3 separate build matrices)

**Performance impact:** whisper.cpp on CPU is approximately 3-5x real-time on a modern x86 machine — 20x slower than the Neural Engine path. The performance differentiator is eliminated.

**Binary size:** Tauri apps are typically 5-15MB due to the system WebView. The current EnviousWispr binary is <50MB including models.

**Conclusion:** The Tauri rewrite is essentially building a new app that happens to share design intent. The current app's competitive advantage (Neural Engine speed, native SwiftUI UX, zero web runtime overhead) is entirely lost. This option is only viable if there is demonstrated demand from Windows/Linux users who are willing to trade performance for access.

---

### Option C: Companion Apps

**Effort estimate: 3-6 months per platform, ongoing maintenance forever.**

Build separate native apps for Windows and Linux that share the design philosophy but use platform-native technologies:

- **Windows:** WinUI 3 (C#) or Rust + Win32, using Windows Speech Recognition API or whisper.cpp
- **Linux:** GTK4 (Rust or Python), using whisper.cpp via `whisper-rs`

**Shared components possible:**
- LLM polishing HTTP calls (pure REST, implementable in any language)
- Appcast/update feed format (XML, readable by any HTTP client)
- The design language and UX patterns (documented, not code)

**Not shareable:**
- All audio/ASR/VAD code (framework-specific)
- All UI code (framework-specific)
- All system integration code (framework-specific)

**Conclusion:** Three separate apps to maintain, each requiring platform-specific expertise. The Windows and Linux apps would be weaker products (no Neural Engine, no CoreML) with a much larger combined maintenance burden. Only viable with dedicated platform engineering resources.

---

### Decision Matrix

| Criterion | Option A (macOS-only) | Option B (Tauri rewrite) | Option C (Companion apps) |
|-----------|----------------------|--------------------------|--------------------------|
| Engineering effort | 0 months | 6-12 months | 3-6 months/platform |
| Preserves Neural Engine advantage | Yes | No | No (macOS companion only) |
| Preserves native UX | Yes | Partial (WebView) | Yes (per platform) |
| Maintenance burden | Low | Medium (one codebase, 3 platforms) | High (3 codebases) |
| Time to first Windows/Linux release | Never (by design) | 9-15 months | 6-12 months |
| Code reuse from current codebase | 100% (no rewrite) | ~0% | ~0% |
| Recommended | **Yes** | No | No |

---

### Future Reconsideration Triggers

Revisit this decision if any of the following occur:

1. **Sustained user demand:** 50+ GitHub issues or discussions requesting Windows/Linux support from non-macOS users willing to beta test.
2. **Apple exits the Neural Engine:** Unlikely, but if CoreML/ANE APIs are deprecated or restricted, the macOS-only moat weakens.
3. **whisper.cpp reaches Neural Engine parity:** If a cross-platform inference runtime achieves comparable speed on affordable hardware, the performance argument weakens.
4. **A contributor volunteers:** If a Windows or Linux developer proposes to build and maintain a companion app using their own time, Option C becomes viable without engineering cost to the macOS project.

## Testing Strategy

This document requires no code and therefore no automated tests. The analysis should be reviewed:

1. Benchmark current Parakeet/WhisperKit throughput on an M-series Mac and compare published whisper.cpp benchmarks on equivalent-wattage x86 hardware.
2. Survey the GitHub issues and discussions for cross-platform requests. If fewer than 10 unique users have requested it, demand is insufficient to justify Option B or C.
3. Review Handy's architecture (Tauri + whisper.cpp) as a reference implementation and assess user reception of its performance on Windows vs Mac.

## Risks & Considerations

- Massive scope — could take months to years
- Would need to replace every macOS-specific API (AVAudioEngine, NSEvent, NSPasteboard, Keychain, etc.)
- SwiftUI only works on Apple platforms
- Likely not worth pursuing unless there is strong user demand
- The Neural Engine performance advantage is the app's primary differentiator — cross-platform eliminates it
