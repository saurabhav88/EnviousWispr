### Parakeet v3

* The Parakeet model downloads automatically during the onboarding flow.
* Download progress is shown in the UI.
* Each download is verified with a **SHA-256 checksum** to guarantee file integrity.

### WhisperKit

* WhisperKit models download when you select the WhisperKit engine for the first time.
* The default model is **large-v3-turbo**.

### Model unloading

To manage memory usage, EnviousWispr can automatically unload speech models after a period of inactivity. This is configurable in the **Performance** tab of settings.

Available unload policies:

* Never (keep model loaded)
* After 2, 5, 10, 15, or 60 minutes of inactivity
* Immediately after each recording

If the model is unloaded, the next recording triggers a reload. With Parakeet, this adds minimal delay. With WhisperKit, model loading is visible in the overlay status.