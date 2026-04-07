EnviousWispr uses opt-in telemetry via PostHog to improve the product. No data is collected without your explicit consent.

### Opt-In Only

Telemetry is only active if you explicitly opt in. No analytics are collected by default.

### What Is Collected (When Opted In)

If you choose to enable telemetry, the following anonymized events are collected:

* **App launched**: App version, OS version, and hardware model (for retention metrics).
* **Recording started**: Trigger method (hotkey or button) and which ASR backend was used.
* **Transcription completed**: Duration in milliseconds, word count, and whether AI polish was used.
* **Polish used**: Which LLM provider was used and latency in milliseconds.
* **Settings changed**: Which setting key was changed (the value is never recorded).

### Anonymized Identifiers

A random UUID is generated at install time for analytics. This is not tied to any hardware identifier, account, or personal information.

### What Is Never Collected

* Transcript text content
* API keys or tokens
* Microphone audio or samples
* File paths or usernames
* Email, name, or any personally identifying information