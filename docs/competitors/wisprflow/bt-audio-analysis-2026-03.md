# WisprFlow Bluetooth Audio Analysis

**Date:** 2026-03-13
**Status:** COMPLETE
**Version analyzed:** v1.4.517

---

## User-Confirmed Testing (2026-03-13)

### Test Setup
- macOS with Bluetooth headphones connected
- WisprFlow v1.4.517
- Music playing during testing

### Test 1: Default configuration (BT headphones connected)
- WisprFlow defaults to MacBook built-in mic, NOT the BT microphone
- Music plays perfectly through BT headphones (A2DP stays active)
- Recording works fine — voice captured via built-in laptop mic
- Zero music quality degradation
- Zero "call ended" notification
- This is their default behavior — most users never realize they're not using the BT mic

### Test 2: Manually switched to BT microphone
- Instant music quality degradation when recording starts (HFP codec switch confirmed)
- "Call ended" notification fires in BT headset (same as our app)
- BUT: after recording stops, music quality recovers to normal (A2DP re-established)
- Our app: music quality stays degraded after recording stops

### Key Insight
WisprFlow's BT "superiority" is primarily a smart default: use the built-in mic and avoid the HFP switch entirely. When forced to use the BT mic, they experience the same codec switch — but recover faster.

### Three-Part Strategy (Confirmed)
1. **Default to built-in mic** — avoids HFP entirely. Most users get perfect experience.
2. **Accept HFP when BT mic forced** — same degradation as everyone else
3. **Fast A2DP recovery** — VolumeManager restores state + Chromium audio service re-establishes A2DP cleanly after recording stops

### Our Gaps
1. We don't default to built-in mic when BT headphones are connected
2. We don't recover cleanly after recording stops — degraded audio state lingers
3. shouldMuteBeforeRecordingStart could mask the transition for users who do use BT mic

---

## Table of Contents

- [User-Confirmed Testing (2026-03-13)](#user-confirmed-testing-2026-03-13)
- [What We Know](#what-we-know)
- [Core Finding: ROUTE AROUND, Then MANAGE](#core-finding-route-around-then-manage)
- [Why Their BT Is Better — Chromium Isolation](#why-their-bt-is-better--chromium-isolation)
- [Swift Helper BT Classes](#swift-helper-bt-classes)
- [ONNX Runtime Discovery](#onnx-runtime-discovery)
- [Implications for Phase 4 (XPC Audio)](#implications-for-phase-4-xpc-audio)

---

## What We Know

### Audio Capture Stack

WisprFlow captures audio via **Web Audio API (AudioWorklet)**, not native CoreAudio. This is a fundamental architectural difference from EnviousWispr.

```
getUserMedia(exact: deviceId)
  -> AudioWorklet (PCM processing)
  -> WebCodecs AudioEncoder (Opus)
  -> Opus chunks streamed to server
```

This means Chromium's media layer sits between WisprFlow and CoreAudio. WisprFlow never directly touches `AVAudioEngine`, `AVAudioSession`, or CoreAudio HAL.

### IPC Messages Related to BT/Audio

| Message | Direction | Purpose |
|---|---|---|
| `AudioCodecChanged` | Swift -> Electron | Swift helper monitors and reports codec switches (e.g., A2DP -> HFP) |
| `AudioInterruptionEvent` | Swift -> Electron | Swift helper monitors audio session interruptions |
| `IsMediaPlayingUpdate` | Swift -> Electron | Detects when media is playing (relevant to BT profile negotiation) |
| `shouldMuteAudio` | Electron -> Swift | Controls system audio muting |
| `deviceMuteStateChanged` | Swift -> Electron | Reports mute state changes back to Electron |

### Device Management

- `getUserMedia` with **exact `deviceId`** constraint -- they target a specific device, not the system default
- `navigator.mediaDevices.ondevicechange` listener detects hot-plug/unplug and device switches
- 8-second timeout on `getUserMedia` -- they know device acquisition can hang (especially BT)

### User-Facing BT Behavior (Confirmed 2026-03-13)

- Their docs acknowledge AirPods issues but recommend **workarounds**, not architectural fixes
- Default config (built-in mic): zero music degradation, zero "call ended" — because HFP is never triggered
- BT mic manually selected: same HFP degradation and "call ended" notification as our app — but they recover to A2DP cleanly after recording stops
- Most users experience the "no degradation" path because they never change the default input device

---

## Core Finding: ROUTE AROUND, Then MANAGE

**They DO NOT avoid the HFP codec switch — they route around it via smart input device defaults.** Their primary strategy is to **default to the built-in laptop mic** when BT headphones are connected, so HFP is never triggered for most users. When the BT mic IS selected (manually by the user), `getUserMedia` at 16kHz mono triggers the same HFP switch as everyone else. Their secondary strategy is **MANAGE** the transition:

1. **Default to built-in mic** — avoids HFP entirely for the majority of users (confirmed via user testing 2026-03-13)
2. **Detect** codec switch via CoreAudio property listeners (sample rate change on default output device = HFP engaged)
3. **Wait for stabilization** — 500ms polling with retry attempts ("Waiting for codec to stabilize (attempt...", "Codec did not stabilize after...", "Codec has returned to normal after...")
4. **Mute system audio** before recording starts to mask quality degradation ("Playing dictation start sound and muting", `shouldMuteBeforeRecordingStart`) — this is a secondary defense for when BT mic IS selected
5. **Track mute state** and restore after recording (`wasPreviouslyMuted`, "Returning user's mute state")
6. **Skip muting** when media isn't playing or user disabled it
7. **Optimistically unmute** when conditions are safe
8. **Fast A2DP recovery** — after recording stops, Chromium audio service + VolumeManager cleanly re-establishes A2DP profile

This answers the core question definitively: **they cannot prevent the HFP switch any more than we can.** The codec switch is an OS-level behavior triggered by any app opening a microphone input on a BT device. Their advantage is (a) smart defaults that avoid triggering HFP in the first place, (b) graceful management when it does trigger, and (c) clean recovery back to A2DP after recording stops.

---

## Why Their BT Is Better — Chromium Isolation

Three layers of Chromium isolation protect them from CoreAudio instability:

### 1. Out-of-process audio service (since Chrome 76)

CoreAudio crashes kill the audio service process, not the app. The audio service auto-restarts transparently.

### 2. getUserMedia abstraction

The renderer process never touches CoreAudio directly. The call path is:

```
Renderer (getUserMedia) → Mojo IPC → Browser process → Audio service → CoreAudio
```

The renderer gets clean PCM buffers or error callbacks. It never sees raw hardware buffer pointers.

### 3. AudioWorklet thread isolation

`RecorderProcessor` worklet runs on a dedicated real-time thread. It accumulates 640-sample chunks (40ms at 16kHz) and posts them via `MessagePort`. No shared memory with CoreAudio buffers.

### Contrast with Our Approach

We use `AVAudioEngine.installTap(onBus:)` which gives a callback with `AVAudioPCMBuffer` whose underlying memory is owned by CoreAudio. BT device disconnect mid-callback = invalid buffer pointer = `EXC_BAD_ACCESS` in the main process.

**Bottom line:** WisprFlow does NOT have a magic BT solution. Same HFP codec switch as everyone else when BT mic is used. Their primary advantage is **smart input device defaults** (built-in mic avoids HFP entirely), with secondary advantages in architectural isolation (Chromium crash isolation) + UX polish (mute/stabilization) + clean A2DP recovery. XPC Audio Service gives us the same crash isolation they get from Chromium's multiprocess model.

---

## Swift Helper BT Classes

### VolumeManager

- System mute control (mute before recording, restore after)
- Codec change detection via output device sample rate monitoring
- Tracks `wasPreviouslyMuted` to restore user's original mute state

### AudioInterruptionMonitor

CoreAudio property listeners for:
- Default input device changes
- Device list changes
- Device alive state (`kAudioDevicePropertyDeviceIsAlive`)
- Mute state changes

IPC events sent to Electron:
- `AudioCodecChanged`
- `AudioInterruptionEvent`
- `deviceMuteStateChanged`

### What the Swift Helper Does NOT Do

- Open audio input streams
- Create `AVAudioEngine` / `AudioUnit` for capture
- Touch `AVAudioPCMBuffer` or raw audio data

The Swift helper is purely a **monitoring and control** layer. All audio capture is handled by Chromium's Web Audio API in the renderer process.

---

## ONNX Runtime Discovery

Bundle contains:
- `ort-wasm-simd-threaded.jsep.mjs`
- `ort-wasm-simd-threaded.jsep.wasm`
- `ort-wasm-simd-threaded.mjs`
- `ort-wasm-simd-threaded.wasm`

This means WisprFlow has **ONNX Runtime compiled to WebAssembly for local inference**. Possible uses:
- Local VAD (Voice Activity Detection) for endpointing
- Local fallback ASR (explains the `usedFallbackAsr` / `fallbackAsrText` columns in their DB)
- Local keyword/command detection

This revises the "100% cloud ASR" assessment. They appear to have a local inference safety net, which may explain their fallback ASR architecture.

---

## Implications for Phase 4 (XPC Audio)

### 1. XPC gives us Chromium-grade isolation

XPC provides Mach-level process isolation — actually better than Chromium's audio service isolation. If our XPC audio service crashes during a BT transition, the main app continues running and can restart the service. This directly addresses our `EXC_BAD_ACCESS` vulnerability.

### 2. Separate capture from monitoring

They do this: Chromium captures audio, Swift monitors device state. Our XPC service should similarly separate the audio capture path from the device monitoring path. The monitoring code should never share memory with the capture buffers.

### 3. Implement codec stabilization detection

500ms polling with retries before starting capture on BT devices. When a codec switch is detected:
- Wait up to 500ms for stabilization
- Retry detection several times
- Only begin capture after codec has settled
- Log warnings if codec doesn't stabilize ("Codec did not stabilize after...")

### 4. Default to built-in mic when BT headphones connected

Their primary BT strategy: default to the built-in laptop mic, avoiding HFP entirely. Most users get zero degradation because HFP is never triggered. Only users who manually select the BT mic experience the codec switch.

### 5. Mute-before-record pattern (secondary defense for BT mic users)

When the BT mic IS selected, mute system audio output before starting recording. This prevents the user from hearing the degraded audio quality during the A2DP → HFP transition. Restore mute state after recording stops. Skip muting when no media is playing or when user has opted out.

### 6. Monitor kAudioDevicePropertyDeviceIsAlive

A device can go "not alive" without leaving the device list. This is distinct from device removal — the device is still enumerated but non-functional. Their `AudioInterruptionMonitor` watches this property explicitly.

### 7. Timeout on audio device acquisition

`getUserMedia` / `AudioUnit` open can hang during BT codec negotiation. They warn at 8 seconds. Our XPC service should implement a similar timeout and abort/retry if device acquisition takes too long.

### 8. Proactive notification > reactive error handling

Mirror their Swift helper → Electron notification pattern in our XPC service → app communication:

```
WisprFlow:  Swift Helper --[AudioCodecChanged]--> Electron (proactive)
Us (now):   AVAudioEngine crash --> catch error --> attempt recovery (reactive)
Us (Phase 4): XPC Service --[AudioCodecChanged]--> App (proactive)
```

### 9. Device tracking with exact IDs

Their `exact: deviceId` pattern plus `ondevicechange` listener is worth adopting. Rather than relying on the "default" device, we should:
- Track the specific device the user selected
- Monitor for device disconnection/reconnection
- Handle device switches explicitly rather than relying on CoreAudio defaults
