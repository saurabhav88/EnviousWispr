EnviousWispr runs a five-stage gate check to determine Apple Intelligence availability. Each stage must pass before the next runs:

1. **Stage 1: Build/Binary.** Was the FoundationModels framework compiled into this build? If the app was built on an older SDK, Apple Intelligence code may be absent entirely.
2. **Stage 2: OS/Runtime Preconditions.** Is your macOS version sufficient? Apple Intelligence requires macOS 26 or later.
3. **Stage 3: Device Eligibility.** Is your Mac eligible for Apple Intelligence? This checks hardware and locale requirements set by Apple.
4. **Stage 4: Model Access.** Can a language model session be created? This verifies the on-device AI model is available and accessible. Has a 2-second timeout.
5. **Stage 5: Functional Probe.** Can a minimal text generation succeed? This is a live test with a 3-second timeout to confirm the AI actually works.

## Common Reasons for Failure

* **macOS version too old.** Apple Intelligence requires macOS 26. Check your version in Apple menu > About This Mac.
* **Apple Intelligence not enabled.** You may need to enable Apple Intelligence in System Settings > Apple Intelligence & Siri.
* **Model not yet downloaded.** After enabling Apple Intelligence, macOS may need time to download the on-device model.

## Viewing Diagnostics

EnviousWispr shows the diagnostic results in **Settings > AI Polish** when Apple Intelligence is selected as the provider. Each gate shows its status so you can identify exactly where the chain breaks.