# Apple Intelligence Availability Hardening Plan

Bead: ew-5gzo | Depends on: ew-eel4 (CI/SDK fix)

## Goal

Upgrade the current Apple Intelligence availability checker from a simple UI status into a full diagnostic subsystem that:

- performs layered gate checks
- returns explicit failure reasons
- logs every decision point
- emits telemetry/debug breadcrumbs for later investigation
- supports fast support triage on fresh installs

This should help us answer:
- Why is Apple Intelligence unavailable on this machine?
- Was it compiled in correctly?
- Is the runtime environment eligible?
- Did the model/session initialization fail later?
- What exact state did the user/device have when the issue happened?

---

## Desired Architecture

Create a dedicated diagnostic component, not ad hoc checks in the settings view.

Suggested types:

- `AppleIntelligenceDiagnosticsService`
- `AppleIntelligenceAvailabilityReport`
- `AppleIntelligenceFailureReason`
- `AppleIntelligenceTelemetrySnapshot`

The settings UI should consume a structured report, not compute availability inline.

---

## Layered Gate Checks

Implement availability as a multi-stage pipeline.

### Stage 1: Build / Binary Gate
Purpose: verify this app binary was actually built with Apple Intelligence support.

Checks:
- compile-time path for `FoundationModels` present
- runtime marker confirming AI-capable binary path exists
- optional build metadata flag embedded at build time:
  - `appleIntelligenceCompiled = true`
  - build SDK version
  - app version / build number

Why:
This distinguishes:
- "feature absent from binary"
from
- "feature present but unavailable on device"

### Stage 2: OS / Runtime Environment Gate
Checks:
- macOS version meets minimum required floor for the API path you use
- process is running on supported hardware class
- any required framework/class/symbol can be loaded at runtime
- sandbox / entitlement assumptions if relevant

### Stage 3: Device Eligibility Gate
Checks:
- device is eligible for Apple Intelligence
- Apple Intelligence support is actually active/usable for this user/device
- language/locale/region prerequisites if your runtime path exposes this indirectly
- model availability state if exposed by the runtime API

Important:
Do not reduce this to one boolean. Capture:
- eligible
- not eligible
- unknown
- temporarily unavailable
- disabled / not configured

### Stage 4: Model Access Gate
Checks:
- can create or access the system language model
- can create a session / request object
- lightweight probe call succeeds
- timeout handling for slow first-load conditions

This distinguishes:
- "framework exists"
from
- "actual model usage is working"

### Stage 5: Functional Probe Gate
Run a tiny safe probe in debug / controlled contexts:
- instantiate model/session
- perform minimal no-op or tiny generation path if safe and cheap
- record latency and result category

Do not run expensive generation every time the settings page opens.
Use caching and throttling.

---

## Report Object Design

Create a structured report:

```swift
struct AppleIntelligenceAvailabilityReport {
    let overallStatus: OverallStatus
    let buildCompiledIn: Bool
    let osVersion: String
    let hardwareClass: String
    let runtimeFrameworkPresent: Bool
    let deviceEligibility: TriState
    let modelAccessible: TriState
    let probeSucceeded: TriState
    let failureReasons: [AppleIntelligenceFailureReason]
    let userVisibleMessage: String
    let debugSummary: String
    let generatedAt: Date
}
```

Use enums, not strings:

```swift
enum OverallStatus {
    case available
    case unavailable
    case degraded
    case unknown
    case checking
}

enum TriState {
    case yes
    case no
    case unknown
}
```

Failure reasons should be explicit and stable:

```swift
enum AppleIntelligenceFailureReason: String {
    case notCompiledIn
    case unsupportedOS
    case unsupportedHardware
    case frameworkMissingAtRuntime
    case deviceNotEligible
    case appleIntelligenceDisabledOrUnavailable
    case localeOrRegionUnsupported
    case modelAccessFailed
    case probeTimedOut
    case probeFailed
    case unknownError
}
```

---

## UI Improvements

Replace the single Available badge with richer status states.

### Recommended UI states
- Available
- Checking...
- Unavailable
- Partially available
- Error initializing
- Unsupported on this Mac

### Add "Why?" detail text

Show a concise explanation under status:
- "This build includes Apple Intelligence support and this Mac can use it."
- "This build includes Apple Intelligence support, but this Mac does not meet runtime requirements."
- "Apple Intelligence appears supported, but model initialization failed."
- "Apple Intelligence support is missing from this app build."

### Add a developer disclosure / debug section

For dev builds or hidden advanced mode:
- build compiled in: yes/no
- OS version
- hardware identifier / Apple silicon class if available
- framework detected: yes/no
- model access: yes/no/unknown
- last probe time
- last failure reason
- last initialization error string

### Add manual re-check action

Keep the refresh button, but make it:
- debounced
- cancellable
- stateful
- logged

---

## Logging Requirements

Structured logs, not generic print statements.

### Log every stage

For each stage emit:
- stage name
- pass/fail/unknown
- reason code
- duration
- relevant environment metadata

Example event names:
- `ai_check_started`
- `ai_build_gate_passed`
- `ai_runtime_gate_failed`
- `ai_model_probe_started`
- `ai_model_probe_failed`
- `ai_check_completed`

### Include stable fields

Every log/telemetry event should include:
- app version
- build number
- macOS version
- machine architecture
- fresh install indicator if available
- first launch indicator
- selected provider = Apple Intelligence
- check trigger source: app launch / settings open / manual refresh / first use / dictation attempt

### Record durations

Capture timing for:
- full check duration
- model initialization duration
- probe duration

This matters because some failures are really slow-init / timeout issues.

---

## Crash / Telemetry Integration

### Before risky calls

Add breadcrumbs before:
- entering AI availability check
- creating model/session objects
- making first probe request
- switching to Apple Intelligence as active provider
- using Apple Intelligence during dictation cleanup

### After risky calls

Add breadcrumbs for:
- success
- error category
- timeout
- fallback triggered

### Attach latest snapshot to errors

Persist the most recent `AppleIntelligenceAvailabilityReport` in memory and optionally on disk.
When a crash or tracked error occurs, include:
- latest report summary
- latest failure reason
- provider selection
- whether fallback occurred
- recent timestamps

---

## Persistence / Debug History

Keep a rolling history of recent checks.

Suggested:
- last 20 reports in memory
- optionally last 5 persisted to disk for dev/support builds

Store:
- timestamp
- trigger
- status
- failure reasons
- durations

Why: Fresh install bugs are often intermittent. A single current-state view is not enough.

---

## Fallback Behavior

If Apple Intelligence fails:
- do not silently present it as healthy
- mark provider unavailable/degraded
- fall back to another provider if your UX permits
- log fallback reason
- surface a clear message in settings

Need explicit distinction between:
- unavailable at startup
- available at startup but failed at first use
- available at startup but degraded later

---

## Fresh Install Hardening

On first app launch:
- run a full diagnostic once
- log `fresh_install = true`
- persist first-run report
- run a second delayed re-check after a short interval if needed
- compare first-check vs second-check state

Reason: Some first-install bugs are timing/setup related, not true incompatibility.

---

## Testing Matrix

### Unit tests
- report building logic
- failure reason mapping
- UI message generation
- fallback decision logic

### Integration tests
- compiled-in / not-compiled-in scenarios if possible via mocks
- probe success / failure / timeout / unknown
- refresh path
- first-launch path

### Manual QA scenarios
- fresh install on supported Apple silicon machine
- unsupported / simulated unsupported machine state
- Apple Intelligence disabled/unavailable state
- first launch offline
- upgrade install vs fresh install
- provider switched repeatedly
- probe timeout / slow init simulation

---

## Implementation Notes

### Avoid
- a single boolean `isAvailable`
- one-shot checks with no reason codes
- unstructured console prints
- expensive probe on every UI render
- silently swallowing model init failures

### Prefer
- structured diagnostic reports
- stable enums for failure reasons
- cached availability state with manual refresh
- background-safe logging
- telemetry breadcrumbs before and after risky calls
- explicit support snapshots

---

## Nice-to-Have

Hidden "Copy diagnostics" button in dev builds that copies a compact support blob:
- app version, build number, macOS version
- provider selected, overall status
- failure reasons
- last probe duration, last error summary

---

## Suggested Priority Order

### Phase 1
- introduce report model
- split checks into stages
- add explicit reason codes
- improve UI messaging

### Phase 2
- add structured logging + telemetry breadcrumbs
- persist latest snapshot
- add first-launch instrumentation

### Phase 3
- add probe timing, history, and support export
- tighten tests and edge-case coverage

---

## Success Criteria

This is successful when:
- a fresh install issue can be classified from logs alone
- support can distinguish build issue vs device issue vs runtime failure
- crash tooling contains the last known AI availability state
- the settings page explains why availability is failing
- provider fallback behavior is deterministic and logged
- telemetry fields are stable and enum-based, not freeform strings
