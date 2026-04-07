EnviousWispr runs audio capture and speech recognition in separate background processes. This means:

* If the ASR engine crashes (out of memory, model error, etc.), the main app stays running.
* If the audio capture service crashes, the main app stays running.
* The next recording after a crash automatically re-launches the failed service.

## Automatic Recovery

When an background service crash is detected via the interruption handler, the pipeline transitions to an error state. No user action is needed. Simply start your next recording and the service restarts automatically.

## Crash Tracking

EnviousWispr uses Sentry for crash tracking with breadcrumbs that capture the pipeline state leading up to a crash. This data is used to diagnose and fix issues. No audio or transcript content is ever sent to crash reporting services.

## If the Main App Itself Crashes

Main app crashes are rare thanks to process isolation. If it does happen, relaunch from your Applications folder. Transcript history is persisted to disk (JSON), so your previous dictations are preserved.