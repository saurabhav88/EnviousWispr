# Settings Map

Generated from the compiled Settings Map and the validated search vocabulary. Do not edit by hand.

- Regenerate: `scripts/settings-map/export.sh`
- Check: `scripts/settings-map/export.sh --check` (CI runs the same comparison)
- Map: [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift); runtime titles: [Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift)
- Interface text: [Sources/EnviousWispr/Resources/Localizable.xcstrings](../Sources/EnviousWispr/Resources/Localizable.xcstrings) (English and German)
- Search vocabulary: [Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json](../Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json)
- Machine-readable export with every field and all vocabulary: [settings-map.json](settings-map.json)
- Authoring and review: [scripts/settings-map/README.md](../scripts/settings-map/README.md)

The interface ships in English and German. The other 30 languages (ar, bg, cs, da, el, es, et, fi, fr, hi, hr, hu, it, ja, ko, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, tr, uk, vi, zh) are search metadata only: words and titles people may type, matched against the same places. Titles below read English / German.

272 nodes, 246 searchable, 7872 vocabulary blocks.

Fingerprints: mapSHA256 `3ec2032ed9a46f013dffdceacf0933126b939d65047a33e9ecf9c7c0df38b6b6`, uiCatalogSHA256 `0273deade377a667b19e5c5a1ec167133b68800ece717c9adc9472e2768988a0`, vocabularyCanonicalization `length-prefixed-v1`, vocabularySHA256 `1d9af94e6eb6a759ef03b3c5a1222fbe4533818ae790fea63f11639519cc732d`

## Structure

- [EnviousWispr](#node-window-settings) `window.settings` (window)
  - [Search settings / Einstellungen suchen](#node-window-search) `window.search` (section)
  - [AI Polish / KI-Nachbearbeitung](#node-page-aiPolish) `page.aiPolish` (page)
    - [Model / Modell](#node-section-aiPolishModel) `section.aiPolishModel` (section)
      - [(named at runtime by `providerName`)](#node-aiPolishProvider) `aiPolishProvider` (setting)
        - [(named at runtime by `providerSection`)](#node-aiPolish-providerSection) `aiPolish.providerSection` (feature)
          - [Download / Laden](#node-localModel-download) `localModel.download` (action)
          - [Cancel / Abbrechen](#node-localModel-cancel) `localModel.cancel` (action)
          - [Resume / Fortsetzen](#node-localModel-resume) `localModel.resume` (action)
          - [Resume upgrade / Upgrade fortsetzen](#node-localModel-resumeUpgrade) `localModel.resumeUpgrade` (action)
          - [Finish upgrade / Upgrade abschließen](#node-localModel-finishUpgrade) `localModel.finishUpgrade` (action)
          - [Try Again / Erneut versuchen](#node-localModel-tryAgain) `localModel.tryAgain` (action)
          - [(named at runtime by `localModelTest`)](#node-localModel-testLive) `localModel.testLive` (action)
          - [Tone / Ton](#node-s1Tone) `s1Tone` (setting)
            - [Casual / Locker](#node-s1Tone-casual) `s1Tone.casual` (choice)
            - [Semi-casual / Eher locker](#node-s1Tone-semiCasual) `s1Tone.semiCasual` (choice)
            - [Semi-formal / Eher förmlich](#node-s1Tone-semiFormal) `s1Tone.semiFormal` (choice)
            - [Formal / Förmlich](#node-s1Tone-formal) `s1Tone.formal` (choice)
          - [Structure / Struktur](#node-s1Structure) `s1Structure` (setting)
            - [Prose / Fließtext](#node-s1Structure-prose) `s1Structure.prose` (choice)
            - [Lists / Listen](#node-s1Structure-lists) `s1Structure.lists` (choice)
          - [Context / Kontext](#node-s1Context) `s1Context` (setting)
            - [General / Allgemein](#node-s1Context-general) `s1Context.general` (choice)
            - [Email / E-Mail](#node-s1Context-email) `s1Context.email` (choice)
          - [OpenAI API Key / OpenAI-API-Schlüssel](#node-apiKey-openAI) `apiKey.openAI` (setting)
          - [Google Gemini API Key / Google Gemini-API-Schlüssel](#node-apiKey-gemini) `apiKey.gemini` (setting)
          - [Claude API Key / Claude-API-Schlüssel](#node-apiKey-claude) `apiKey.claude` (setting)
          - [Save / Sichern](#node-apiKey-save) `apiKey.save` (action)
          - [Clear / Löschen](#node-apiKey-clear) `apiKey.clear` (action)
          - [(named at runtime by `apiKeyReveal`)](#node-apiKey-reveal) `apiKey.reveal` (action)
          - [(named at runtime by `apiKeyLink`)](#node-apiKey-getKeyLink) `apiKey.getKeyLink` (action)
          - [Model / Modell](#node-polishModel) `polishModel` (setting)
            - [Prepare model / Modell vorbereiten](#node-ollama-prepareModel) `ollama.prepareModel` (action)
            - [Refresh available models / Verfügbare Modelle aktualisieren](#node-polishModel-refresh) `polishModel.refresh` (action)
        - [EG-1](#node-aiPolishProvider-egOne) `aiPolishProvider.egOne` (choice)
          - [Why use EG-1 / Warum EG-1 verwenden?](#node-aiPolish-whyUse-egOne) `aiPolish.whyUse.egOne` (feature)
        - [S1-mini](#node-aiPolishProvider-s1Mini) `aiPolishProvider.s1Mini` (choice)
          - [Why use S1-mini / Warum S1-mini verwenden?](#node-aiPolish-whyUse-s1Mini) `aiPolish.whyUse.s1Mini` (feature)
        - [Apple Intelligence](#node-aiPolishProvider-appleIntelligence) `aiPolishProvider.appleIntelligence` (choice)
          - [Why use Apple Intelligence / Warum Apple Intelligence verwenden?](#node-aiPolish-whyUse-appleIntelligence) `aiPolish.whyUse.appleIntelligence` (feature)
            - [About Apple Intelligence / Über Apple Intelligence](#node-aiPolish-link-aboutAppleIntelligence) `aiPolish.link.aboutAppleIntelligence` (action)
          - [(named at runtime by `appleIntelligenceStatus`)](#node-appleIntelligence-status) `appleIntelligence.status` (feature)
            - [Check Apple Intelligence availability / Verfügbarkeit von Apple Intelligence prüfen](#node-appleIntelligence-recheck) `appleIntelligence.recheck` (action)
        - [Ollama](#node-aiPolishProvider-ollama) `aiPolishProvider.ollama` (choice)
          - [Why use Ollama / Warum Ollama verwenden?](#node-aiPolish-whyUse-ollama) `aiPolish.whyUse.ollama` (feature)
            - [Ollama model library / Ollama-Modellbibliothek](#node-aiPolish-link-ollamaLibrary) `aiPolish.link.ollamaLibrary` (action)
          - [Download Ollama / Ollama herunterladen](#node-ollama-downloadOllama) `ollama.downloadOllama` (action)
          - [Start Ollama / Ollama starten](#node-ollama-start) `ollama.start` (action)
          - [(named at runtime by `ollamaModelDownload`)](#node-ollama-downloadModel) `ollama.downloadModel` (action)
          - [Cancel / Abbrechen](#node-ollama-cancelPull) `ollama.cancelPull` (action)
          - [Server / Server](#node-ollama-server) `ollama.server` (feature)
          - [Re-check Ollama status / Ollama-Status erneut prüfen](#node-ollama-recheck) `ollama.recheck` (action)
          - [Try Again / Erneut versuchen](#node-ollama-tryAgain) `ollama.tryAgain` (action)
          - [Download more models / Weitere Modelle laden](#node-ollama-browseModels) `ollama.browseModels` (action)
        - [OpenAI](#node-aiPolishProvider-openAI) `aiPolishProvider.openAI` (choice)
          - [Why use OpenAI / Warum OpenAI verwenden?](#node-aiPolish-whyUse-openAI) `aiPolish.whyUse.openAI` (feature)
            - [OpenAI rate limits by tier / OpenAI-Ratenlimits nach Stufe](#node-aiPolish-link-openAIRateLimits) `aiPolish.link.openAIRateLimits` (action)
        - [Google Gemini](#node-aiPolishProvider-gemini) `aiPolishProvider.gemini` (choice)
          - [Why use Gemini / Warum Gemini verwenden?](#node-aiPolish-whyUse-gemini) `aiPolish.whyUse.gemini` (feature)
            - [Gemini API rate limits by tier / Ratenlimits der Gemini-API nach Nutzungsstufe](#node-aiPolish-link-geminiRateLimits) `aiPolish.link.geminiRateLimits` (action)
        - [Claude](#node-aiPolishProvider-claude) `aiPolishProvider.claude` (choice)
          - [Why use Claude / Warum Claude verwenden?](#node-aiPolish-whyUse-claude) `aiPolish.whyUse.claude` (feature)
            - [Claude API rate limits / Claude-API-Ratenlimits](#node-aiPolish-link-claudeRateLimits) `aiPolish.link.claudeRateLimits` (action)
    - [Enable AI Polish / KI-Nachbearbeitung aktivieren](#node-enableAIPolish) `enableAIPolish` (setting)
  - [App Settings / App-Einstellungen](#node-page-appSettings) `page.appSettings` (page)
    - [Appearance / Erscheinungsbild](#node-appSettings-tab-appearance) `appSettings.tab.appearance` (feature)
      - [APPEARANCE / ERSCHEINUNGSBILD](#node-section-appearance) `section.appearance` (section)
        - [Theme / Design](#node-theme) `theme` (setting)
          - [System / System](#node-theme-system) `theme.system` (choice)
          - [Light / Hell](#node-theme-light) `theme.light` (choice)
          - [Dark / Dunkel](#node-theme-dark) `theme.dark` (choice)
        - [Language / Sprache](#node-appLanguage) `appLanguage` (setting)
          - [System default / Systemstandard](#node-appLanguage-systemDefault) `appLanguage.systemDefault` (choice)
          - [(named at runtime by `appLanguageName`)](#node-appLanguage-shipped) `appLanguage.shipped` (choice)
          - [Relaunch to apply / Zum Übernehmen neu starten](#node-appLanguage-relaunch) `appLanguage.relaunch` (action)
        - [Show app in Dock / App im Dock anzeigen](#node-showInDock) `showInDock` (setting)
        - [Update alert in menu bar / Update-Hinweis in der Menüleiste](#node-updateAlertInMenuBar) `updateAlertInMenuBar` (setting)
    - [Permissions / Berechtigungen](#node-appSettings-tab-permissions) `appSettings.tab.permissions` (feature)
      - [PERMISSIONS / BERECHTIGUNGEN](#node-section-permissions) `section.permissions` (section)
        - [Microphone / Mikrofon](#node-permission-microphone) `permission.microphone` (feature)
          - [Request Access / Zugriff anfordern](#node-permission-microphone-request) `permission.microphone.request` (action)
        - [Accessibility / Bedienungshilfen](#node-permission-accessibility) `permission.accessibility` (feature)
          - [Open System Settings / Systemeinstellungen öffnen](#node-permission-accessibility-openSettings) `permission.accessibility.openSettings` (action)
    - [Privacy / Datenschutz](#node-appSettings-tab-privacy) `appSettings.tab.privacy` (feature)
      - [PRIVACY / DATENSCHUTZ](#node-section-privacy) `section.privacy` (section)
        - [Share usage metrics / Nutzungsstatistiken teilen](#node-shareUsageMetrics) `shareUsageMetrics` (setting)
        - [Send crash reports / Absturzberichte senden](#node-sendCrashReports) `sendCrashReports` (setting)
          - [Restart now / Jetzt neu starten](#node-sendCrashReports-restart) `sendCrashReports.restart` (action)
        - [What we collect / Was wir erfassen](#node-whatWeCollect) `whatWeCollect` (feature)
          - [See details / Details ansehen](#node-whatWeCollect-seeDetails) `whatWeCollect.seeDetails` (action)
    - [Licenses / Lizenzen](#node-appSettings-tab-licenses) `appSettings.tab.licenses` (feature)
      - [ABOUT / INFO](#node-section-about) `section.about` (section)
        - [EnviousWispr · GPLv3 / EnviousWispr · GPLv3](#node-license-gpl) `license.gpl` (feature)
          - [View license / Lizenz ansehen](#node-license-gpl-view) `license.gpl.view` (action)
        - [Third-Party Notices / Hinweise zu Drittanbietern](#node-license-notices) `license.notices` (feature)
          - [View notices / Hinweise ansehen](#node-license-notices-view) `license.notices.view` (action)
  - [Dictation Settings / Diktateinstellungen](#node-page-dictation) `page.dictation` (page)
    - [Engine / Engine](#node-dictation-tab-engine) `dictation.tab.engine` (feature)
      - [TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE](#node-section-transcriptionEngine) `section.transcriptionEngine` (section)
        - [TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE](#node-transcriptionEngine) `transcriptionEngine` (setting)
          - [Change / Ändern](#node-transcriptionEngine-change) `transcriptionEngine.change` (action)
          - [Keep current engine / Aktuelle Engine beibehalten](#node-transcriptionEngine-keepCurrent) `transcriptionEngine.keepCurrent` (action)
          - [Re-check Fast model status / Modellstatus von „Schnell“ erneut prüfen](#node-transcriptionEngine-recheckFast) `transcriptionEngine.recheckFast` (action)
          - [Cancel / Abbrechen](#node-fastModel-cancelDownload) `fastModel.cancelDownload` (action)
          - [Resume / Fortsetzen](#node-fastModel-resume) `fastModel.resume` (action)
          - [Try Again / Erneut versuchen](#node-fastModel-tryAgain) `fastModel.tryAgain` (action)
          - [Set up model / Modell einrichten](#node-whisperModel-setUp) `whisperModel.setUp` (action)
          - [Cancel / Abbrechen](#node-whisperModel-cancelDownload) `whisperModel.cancelDownload` (action)
          - [Resume / Fortsetzen](#node-whisperModel-resume) `whisperModel.resume` (action)
          - [Remove Model / Modell entfernen](#node-whisperModel-remove) `whisperModel.remove` (action)
          - [Re-check model status / Modellstatus erneut prüfen](#node-whisperModel-recheck) `whisperModel.recheck` (action)
          - [Try Again / Erneut versuchen](#node-whisperModel-tryAgain) `whisperModel.tryAgain` (action)
          - [Fast / Schnell](#node-transcriptionEngine-fast) `transcriptionEngine.fast` (choice)
          - [All Languages / Alle Sprachen](#node-transcriptionEngine-allLanguages) `transcriptionEngine.allLanguages` (choice)
      - [APPLIES TO BOTH ENGINES / GILT FÜR BEIDE ENGINES](#node-section-engineShared) `section.engineShared` (section)
        - [Stop recording on silence / Aufnahme bei Stille stoppen](#node-stopOnSilence) `stopOnSilence` (setting)
          - [Pause duration / Pausendauer](#node-pauseDuration) `pauseDuration` (setting)
        - [Remove filler words (um, uh, hmm...) / Füllwörter entfernen (ähm, äh, hm...)](#node-fillerRemoval) `fillerRemoval` (setting)
        - [Convert spoken emoji (e.g. "thumbs up emoji" → 👍) / Gesprochene Emojis umwandeln (z. B. „Daumen hoch Emoji“ → 👍)](#node-spokenEmoji) `spokenEmoji` (setting)
        - [Spoken punctuation / Gesprochene Satzzeichen](#node-spokenPunctuation) `spokenPunctuation` (setting)
          - [Start word / Startwort](#node-startWordLanguage) `startWordLanguage` (setting)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-en) `startWordLanguage.en` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-de) `startWordLanguage.de` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-fr) `startWordLanguage.fr` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-es) `startWordLanguage.es` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-it) `startWordLanguage.it` (choice)
          - [Start word for / Startwort für](#node-startWordField) `startWordField` (setting)
            - [Save word / Wort sichern](#node-startWord-save) `startWord.save` (action)
            - [Reset / Zurücksetzen](#node-startWord-reset) `startWord.reset` (action)
        - [Unload model after / Modell entladen nach](#node-unloadModel) `unloadModel` (setting)
          - [Never / Nie](#node-unloadModel-never) `unloadModel.never` (choice)
          - [Immediately / Sofort](#node-unloadModel-immediately) `unloadModel.immediately` (choice)
          - [After 2 minutes / Nach 2 Minuten](#node-unloadModel-twoMinutes) `unloadModel.twoMinutes` (choice)
          - [After 5 minutes / Nach 5 Minuten](#node-unloadModel-fiveMinutes) `unloadModel.fiveMinutes` (choice)
          - [After 10 minutes / Nach 10 Minuten](#node-unloadModel-tenMinutes) `unloadModel.tenMinutes` (choice)
          - [After 15 minutes / Nach 15 Minuten](#node-unloadModel-fifteenMinutes) `unloadModel.fifteenMinutes` (choice)
          - [After 1 hour / Nach 1 Stunde](#node-unloadModel-oneHour) `unloadModel.oneHour` (choice)
      - [(named at runtime by `currentEngineHeading`)](#node-currentEngineSection) `currentEngineSection` (feature)
        - [Auto-detect language / Sprache automatisch erkennen](#node-autoDetectLanguage) `autoDetectLanguage` (setting)
          - [Reset suggestions / Vorschläge zurücksetzen](#node-autoDetectLanguage-resetSuggestions) `autoDetectLanguage.resetSuggestions` (action)
        - [(named at runtime by `lockedLanguage`)](#node-lockedLanguage) `lockedLanguage` (setting)
          - [Change / Ändern](#node-lockedLanguage-change) `lockedLanguage.change` (action)
        - [Faster Transcription / Schnellere Transkription](#node-fasterTranscription) `fasterTranscription` (setting)
    - [Microphone / Mikrofon](#node-dictation-tab-microphone) `dictation.tab.microphone` (feature)
      - [INPUT &amp; BEHAVIOR / EINGABE &amp; VERHALTEN](#node-section-microphone) `section.microphone` (section)
        - [Input device / Eingabegerät](#node-inputDevice) `inputDevice` (setting)
          - [Auto / Auto](#node-inputDevice-auto) `inputDevice.auto` (choice)
          - [(named at runtime by `inputDeviceName`)](#node-inputDevice-device) `inputDevice.device` (choice)
          - [Mic is on / Mikrofon ist an](#node-inputSocket) `inputSocket` (setting)
            - [(named at runtime by `inputSocketOption`)](#node-inputSocket-input) `inputSocket.input` (choice)
        - [Media during dictation / Medien beim Diktieren](#node-mediaDuringDictation) `mediaDuringDictation` (setting)
          - [Continue / Weiterlaufen lassen](#node-mediaDuringDictation-continue) `mediaDuringDictation.continue` (choice)
          - [Lower / Leiser](#node-mediaDuringDictation-lower) `mediaDuringDictation.lower` (choice)
          - [Mute / Stummschalten](#node-mediaDuringDictation-mute) `mediaDuringDictation.mute` (choice)
          - [Pause / Pausieren](#node-mediaDuringDictation-pause) `mediaDuringDictation.pause` (choice)
        - [Microphone readiness / Mikrofonbereitschaft](#node-micReadiness) `micReadiness` (setting)
          - [Off / Aus](#node-micReadiness-off) `micReadiness.off` (choice)
          - [10 sec / 10 Sek.](#node-micReadiness-10s) `micReadiness.10s` (choice)
          - [30 sec / 30 Sek.](#node-micReadiness-30s) `micReadiness.30s` (choice)
          - [60 sec / 60 Sek.](#node-micReadiness-60s) `micReadiness.60s` (choice)
          - [Always / Immer](#node-micReadiness-always) `micReadiness.always` (choice)
        - [Using a Bluetooth microphone? / Verwendest du ein Bluetooth-Mikrofon?](#node-bluetoothGuide) `bluetoothGuide` (feature)
          - [Learn more / Mehr erfahren](#node-bluetoothGuide-learnMore) `bluetoothGuide.learnMore` (action)
    - [Live Preview / Live-Vorschau](#node-dictation-tab-livePreview) `dictation.tab.livePreview` (feature)
      - [Live Preview / Live-Vorschau](#node-section-livePreview) `section.livePreview` (section)
        - [Show words while you speak / Wörter beim Sprechen anzeigen](#node-livePreview) `livePreview` (setting)
          - [(named at runtime by `previewLanguage`)](#node-livePreview-language) `livePreview.language` (action)
          - [Browse downloads / Downloads ansehen](#node-livePreview-browseDownloads) `livePreview.browseDownloads` (action)
      - [Preview engine / Vorschau-Engine](#node-section-previewEngine) `section.previewEngine` (section)
        - [Preview engine / Vorschau-Engine](#node-previewEngine) `previewEngine` (setting)
          - [Change / Ändern](#node-previewEngine-change) `previewEngine.change` (action)
          - [Compare engines / Engines vergleichen](#node-previewEngine-compare) `previewEngine.compare` (action)
          - [Keep current preview engine / Aktuelle Vorschau-Engine beibehalten](#node-previewEngine-keepCurrent) `previewEngine.keepCurrent` (action)
          - [Apple](#node-previewEngine-apple) `previewEngine.apple` (choice)
          - [Universal / Universal](#node-previewEngine-universal) `previewEngine.universal` (choice)
            - [Download / Laden](#node-previewEngine-universal-download) `previewEngine.universal.download` (action)
            - [Cancel / Abbrechen](#node-previewEngine-universal-cancel) `previewEngine.universal.cancel` (action)
            - [Resume / Fortsetzen](#node-previewEngine-universal-resume) `previewEngine.universal.resume` (action)
            - [Try Again / Erneut versuchen](#node-previewEngine-universal-retry) `previewEngine.universal.retry` (action)
            - [Remove / Entfernen](#node-previewEngine-universal-remove) `previewEngine.universal.remove` (action)
        - [Languages / Sprachen](#node-previewLanguages) `previewLanguages` (feature)
          - [(named at runtime by `previewLanguagesInstall`)](#node-previewLanguages-install) `previewLanguages.install` (action)
    - [Recording Pill / Aufnahmeanzeige](#node-dictation-tab-pill) `dictation.tab.pill` (feature)
      - [Recording Pill / Aufnahmeanzeige](#node-section-pill) `section.pill` (section)
        - [Position on screen / Position auf dem Bildschirm](#node-pillPosition) `pillPosition` (setting)
          - [Top / Oben](#node-pillPosition-top) `pillPosition.top` (choice)
          - [Bottom / Unten](#node-pillPosition-bottom) `pillPosition.bottom` (choice)
        - [Style / Stil](#node-pillStyle) `pillStyle` (setting)
          - [Configure Live Preview / Live-Vorschau einrichten](#node-pillStyle-configureLivePreview) `pillStyle.configureLivePreview` (action)
          - [Capsule / Kapsel](#node-pillStyle-capsule) `pillStyle.capsule` (choice)
          - [Level Rail / Pegelanzeige](#node-pillStyle-levelRail) `pillStyle.levelRail` (choice)
          - [Reading Well / Lesefeld](#node-pillStyle-readingWell) `pillStyle.readingWell` (choice)
    - [Chimes / Signaltöne](#node-dictation-tab-chimes) `dictation.tab.chimes` (feature)
      - [RECORDING CHIMES / AUFNAHMESIGNALTÖNE](#node-section-chimes) `section.chimes` (section)
        - [Play recording chimes / Aufnahmesignaltöne abspielen](#node-recordingChimes) `recordingChimes` (setting)
        - [RECORDING CHIMES / AUFNAHMESIGNALTÖNE](#node-recordingChime) `recordingChime` (setting)
          - [(named at runtime by `chimePreview`)](#node-recordingChime-preview) `recordingChime.preview` (action)
          - [Dust Mote / Staubflöckchen](#node-recordingChime-dustMote) `recordingChime.dustMote` (choice)
          - [Velvet Hush / Samtflüstern](#node-recordingChime-velvetHush) `recordingChime.velvetHush` (choice)
          - [Muted Confirm / Leises Okay](#node-recordingChime-mutedConfirm) `recordingChime.mutedConfirm` (choice)
          - [Whisper Tick / Flüstertick](#node-recordingChime-whisperTick) `recordingChime.whisperTick` (choice)
          - [Round Pebble / Runder Kiesel](#node-recordingChime-roundPebble) `recordingChime.roundPebble` (choice)
          - [Paper Tap / Papierklopfen](#node-recordingChime-paperTap) `recordingChime.paperTap` (choice)
          - [Soft Hush / Sanftes Säuseln](#node-recordingChime-softHush) `recordingChime.softHush` (choice)
          - [Low Nod / Tiefes Nicken](#node-recordingChime-lowNod) `recordingChime.lowNod` (choice)
          - [Cloud Pop / Wolkenplopp](#node-recordingChime-cloudPop) `recordingChime.cloudPop` (choice)
          - [Velvet Tap / Samttipp](#node-recordingChime-velvetTap) `recordingChime.velvetTap` (choice)
          - [Satin Shift / Satin-Schimmer](#node-recordingChime-satinShift) `recordingChime.satinShift` (choice)
          - [Air Glint / Luftfunkeln](#node-recordingChime-airGlint) `recordingChime.airGlint` (choice)
    - [Clipboard / Zwischenablage](#node-dictation-tab-clipboard) `dictation.tab.clipboard` (feature)
      - [Clipboard / Zwischenablage](#node-section-clipboard) `section.clipboard` (section)
        - [Auto-copy to clipboard / Automatisch in die Zwischenablage kopieren](#node-autoCopyToClipboard) `autoCopyToClipboard` (setting)
        - [Restore clipboard after paste / Zwischenablage nach dem Einfügen wiederherstellen](#node-restoreClipboard) `restoreClipboard` (setting)
        - [Smart insertion / Intelligentes Einfügen](#node-smartInsertion) `smartInsertion` (setting)
      - [Quick Add / Schnell hinzufügen](#node-section-quickAddClipboard) `section.quickAddClipboard` (section)
        - [Read selections through the clipboard / Auswahl über die Zwischenablage lesen](#node-quickAddClipboardFallback) `quickAddClipboardFallback` (setting)
  - [Dictionary / Wörterbuch](#node-page-dictionary) `page.dictionary` (page)
    - [Dictionary / Wörterbuch](#node-section-dictionary) `section.dictionary` (section)
    - [Enable Dictionary / Wörterbuch aktivieren](#node-enableDictionary) `enableDictionary` (setting)
    - [Your Words / Deine Wörter](#node-dictionary-tab-yourWords) `dictionary.tab.yourWords` (feature)
      - [Add word / Wort hinzufügen](#node-yourWords-add) `yourWords.add` (action)
      - [Import / Importieren](#node-yourWords-import) `yourWords.import` (action)
      - [Export your words / Deine Wörter exportieren](#node-yourWords-export) `yourWords.export` (action)
      - [Search by word, mishearing, or category / Nach Wort, Fehlerkennung oder Kategorie suchen](#node-yourWords-search) `yourWords.search` (setting)
        - [Clear search / Suche löschen](#node-yourWords-clearSearch) `yourWords.clearSearch` (action)
      - [All categories / Alle Kategorien](#node-yourWords-categoryFilter) `yourWords.categoryFilter` (setting)
        - [All categories / Alle Kategorien](#node-yourWords-category-all) `yourWords.category.all` (choice)
        - [General / Allgemein](#node-yourWords-category-general) `yourWords.category.general` (choice)
        - [Person / Person](#node-yourWords-category-person) `yourWords.category.person` (choice)
        - [Brand / Marke](#node-yourWords-category-brand) `yourWords.category.brand` (choice)
        - [Acronym / Akronym](#node-yourWords-category-acronym) `yourWords.category.acronym` (choice)
        - [Domain / Fachgebiet](#node-yourWords-category-domain) `yourWords.category.domain` (choice)
        - [Auto-learned / Automatisch gelernt](#node-yourWords-category-autoLearned) `yourWords.category.autoLearned` (choice)
      - [Mass edit / Mehrere auswählen](#node-yourWords-massEdit) `yourWords.massEdit` (action)
    - [Vocabulary Packs / Wortschatzpakete](#node-dictionary-tab-vocabularyPacks) `dictionary.tab.vocabularyPacks` (feature)
    - [Learn from... / Lernen aus...](#node-dictionary-tab-learnFrom) `dictionary.tab.learnFrom` (feature)
      - [Learn from... / Lernen aus...](#node-learnFrom) `learnFrom` (feature)
      - [Self-Learning Dictionary / Selbstlernendes Wörterbuch](#node-selfLearningDictionary) `selfLearningDictionary` (setting)
        - [Learn more / Mehr erfahren](#node-selfLearningDictionary-learnMore) `selfLearningDictionary.learnMore` (action)
      - [Import from Contacts / Aus Kontakten importieren](#node-importContacts) `importContacts` (feature)
        - [Keep in sync on launch / Beim Start synchron halten](#node-contactsSyncOnLaunch) `contactsSyncOnLaunch` (setting)
    - [Quick Add / Schnell hinzufügen](#node-dictionary-tab-quickAdd) `dictionary.tab.quickAdd` (feature)
      - [Highlight a word / Wort markieren](#node-quickAdd-step1) `quickAdd.step1` (feature)
      - [Trigger Quick Add / „Schnell hinzufügen“ aufrufen](#node-quickAdd-step2) `quickAdd.step2` (feature)
      - [Choose and save / Auswählen und sichern](#node-quickAdd-step3) `quickAdd.step3` (feature)
      - [Keyboard shortcut / Tastenkürzel](#node-quickAdd-shortcut) `quickAdd.shortcut` (action)
      - [Menu bar / Menüleiste](#node-quickAdd-menuBar) `quickAdd.menuBar` (feature)
  - [Keybinds / Tastenkürzel](#node-page-keybinds) `page.keybinds` (page)
    - [Recording / Aufnahme](#node-section-keybindsRecording) `section.keybindsRecording` (section)
      - [Recording mode / Aufnahmemodus](#node-recordingMode) `recordingMode` (setting)
        - [Push to Talk / Zum Sprechen drücken](#node-recordingMode-pushToTalk) `recordingMode.pushToTalk` (choice)
        - [Toggle / Umschalten](#node-recordingMode-toggle) `recordingMode.toggle` (choice)
      - [Start / stop recording / Aufnahme starten / stoppen](#node-recordKeybind) `recordKeybind` (setting)
      - [Cancel recording / Aufnahme abbrechen](#node-cancelKeybind) `cancelKeybind` (setting)
      - [Escape Recovery / Wiederherstellung bei Escape](#node-escapeRecovery) `escapeRecovery` (setting)
      - [Reset to default / Auf Standard zurücksetzen](#node-keybind-resetToDefault) `keybind.resetToDefault` (action)
    - [Shortcuts / Kurzbefehle](#node-section-keybindsShortcuts) `section.keybindsShortcuts` (section)
      - [Add selected word to Dictionary / Markiertes Wort zum Wörterbuch hinzufügen](#node-quickAddKeybind) `quickAddKeybind` (setting)
      - [Paste last dictation / Letztes Diktat einfügen](#node-pasteLastKeybind) `pasteLastKeybind` (setting)
      - [Copy last dictation / Letztes Diktat kopieren](#node-copyLastKeybind) `copyLastKeybind` (setting)
  - [Snippets / Textbausteine](#node-page-snippets) `page.snippets` (page)
    - [Paste the text you type over and over, by voice / Füge Text, den du oft tippst, per Stimme ein](#node-snippets) `snippets` (feature)
    - [Keyword / Schlüsselwort](#node-snippetKeyword) `snippetKeyword` (setting)
    - [Your snippets / Deine Textbausteine](#node-yourSnippets) `yourSnippets` (feature)
      - [Search snippets / Textbausteine durchsuchen](#node-snippets-search) `snippets.search` (setting)
        - [Clear search / Suche löschen](#node-snippets-clearSearch) `snippets.clearSearch` (action)
      - [Import / Importieren](#node-snippets-import) `snippets.import` (action)
      - [Export / Exportieren](#node-snippets-export) `snippets.export` (action)
      - [Add snippet / Textbaustein hinzufügen](#node-snippets-add) `snippets.add` (action)
      - [Add your first snippet / Ersten Textbaustein hinzufügen](#node-snippets-addFirst) `snippets.addFirst` (action)
  - [Transcribe a File / Datei transkribieren](#node-page-transcribeFile) `page.transcribeFile` (page)
    - [(named at runtime by `transcribeFileStep`)](#node-transcribeFile-steps) `transcribeFile.steps` (feature)

## Places

<a id="node-window-settings"></a>

### EnviousWispr (`window.settings`)

| Field | Value |
|---|---|
| Structure | window |
| Kind | structure only, not searchable |
| Parent | none |
| Title source | product name |
| Description | none |
| Destination | none |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-window-search"></a>

### Search settings / Einstellungen suchen (`window.search`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Search settings` |
| Description | none |
| Destination | none |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-aiPolish"></a>

### AI Polish / KI-Nachbearbeitung (`page.aiPolish`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `AI Polish` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-appSettings"></a>

### App Settings / App-Einstellungen (`page.appSettings`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `App Settings` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-dictation"></a>

### Dictation Settings / Diktateinstellungen (`page.dictation`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Dictation Settings` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-dictionary"></a>

### Dictionary / Wörterbuch (`page.dictionary`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Dictionary` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-keybinds"></a>

### Keybinds / Tastenkürzel (`page.keybinds`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Keybinds` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-snippets"></a>

### Snippets / Textbausteine (`page.snippets`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Snippets` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-transcribeFile"></a>

### Transcribe a File / Datei transkribieren (`page.transcribeFile`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `Transcribe a File` |
| Description | none |
| Destination | `transcribeFile` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-transcriptionEngine"></a>

### TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE (`section.transcriptionEngine`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.engine`](#node-dictation-tab-engine) |
| Title source | catalog key `TRANSCRIPTION ENGINE` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-engineShared"></a>

### APPLIES TO BOTH ENGINES / GILT FÜR BEIDE ENGINES (`section.engineShared`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.engine`](#node-dictation-tab-engine) |
| Title source | catalog key `APPLIES TO BOTH ENGINES` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-microphone"></a>

### INPUT &amp; BEHAVIOR / EINGABE &amp; VERHALTEN (`section.microphone`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.microphone`](#node-dictation-tab-microphone) |
| Title source | catalog key `INPUT & BEHAVIOR` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-livePreview"></a>

### Live Preview / Live-Vorschau (`section.livePreview`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.livePreview`](#node-dictation-tab-livePreview) |
| Title source | catalog key `Live Preview` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-previewEngine"></a>

### Preview engine / Vorschau-Engine (`section.previewEngine`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.livePreview`](#node-dictation-tab-livePreview) |
| Title source | catalog key `Preview engine` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-pill"></a>

### Recording Pill / Aufnahmeanzeige (`section.pill`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.pill`](#node-dictation-tab-pill) |
| Title source | catalog key `Recording Pill` |
| Description | none |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-chimes"></a>

### RECORDING CHIMES / AUFNAHMESIGNALTÖNE (`section.chimes`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.chimes`](#node-dictation-tab-chimes) |
| Title source | catalog key `RECORDING CHIMES` |
| Description | none |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-clipboard"></a>

### Clipboard / Zwischenablage (`section.clipboard`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.clipboard`](#node-dictation-tab-clipboard) |
| Title source | catalog key `Clipboard` |
| Description | none |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-quickAddClipboard"></a>

### Quick Add / Schnell hinzufügen (`section.quickAddClipboard`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`dictation.tab.clipboard`](#node-dictation-tab-clipboard) |
| Title source | catalog key `Quick Add` |
| Description | none |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-keybindsRecording"></a>

### Recording / Aufnahme (`section.keybindsRecording`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`page.keybinds`](#node-page-keybinds) |
| Title source | catalog key `keybinds.section.recording` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-keybindsShortcuts"></a>

### Shortcuts / Kurzbefehle (`section.keybindsShortcuts`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`page.keybinds`](#node-page-keybinds) |
| Title source | catalog key `keybinds.section.shortcuts` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-aiPolishModel"></a>

### Model / Modell (`section.aiPolishModel`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`page.aiPolish`](#node-page-aiPolish) |
| Title source | catalog key `Model` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-dictionary"></a>

### Dictionary / Wörterbuch (`section.dictionary`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Dictionary` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-appearance"></a>

### APPEARANCE / ERSCHEINUNGSBILD (`section.appearance`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.appearance`](#node-appSettings-tab-appearance) |
| Title source | catalog key `APPEARANCE` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-permissions"></a>

### PERMISSIONS / BERECHTIGUNGEN (`section.permissions`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.permissions`](#node-appSettings-tab-permissions) |
| Title source | catalog key `PERMISSIONS` |
| Description | none |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-privacy"></a>

### PRIVACY / DATENSCHUTZ (`section.privacy`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.privacy`](#node-appSettings-tab-privacy) |
| Title source | catalog key `PRIVACY` |
| Description | none |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-about"></a>

### ABOUT / INFO (`section.about`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.licenses`](#node-appSettings-tab-licenses) |
| Title source | catalog key `ABOUT` |
| Description | none |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-dictation-tab-engine"></a>

### Engine / Engine (`dictation.tab.engine`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Engine` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.engine`](#node-dictation-tab-engine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show me the engine settings tab; open the dictation engine page |
| Search (de) | phrases: zeig mir den Tab mit den Engine-Einstellungen; öffne die Engine-Seite in den Diktiereinstellungen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-microphone"></a>

### Microphone / Mikrofon (`dictation.tab.microphone`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Microphone` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.microphone`](#node-dictation-tab-microphone) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the microphone settings tab; show me the microphone settings page |
| Search (de) | phrases: öffne den Tab mit den Mikrofoneinstellungen; zeig mir die Einstellungsseite fürs Mikrofon |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-livePreview"></a>

### Live Preview / Live-Vorschau (`dictation.tab.livePreview`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Live Preview` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.livePreview`](#node-dictation-tab-livePreview) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Live Preview tab; show me the Live Preview settings page |
| Search (de) | phrases: öffne den Tab für die Live-Vorschau; zeig mir die Einstellungsseite für die Live-Vorschau |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-pill"></a>

### Recording Pill / Aufnahmeanzeige (`dictation.tab.pill`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Recording Pill` |
| Description | none |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.pill`](#node-dictation-tab-pill) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: overlay, widget<br>phrases: open the Recording Pill settings tab; show me the floating recording indicator settings page |
| Search (de) | words: Overlay, Widget, Aufnahmefenster<br>phrases: öffne den Tab für die Aufnahmeanzeige; zeig mir die Einstellungsseite für die schwebende Aufnahmeanzeige |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-chimes"></a>

### Chimes / Signaltöne (`dictation.tab.chimes`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Chimes` |
| Description | none |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.chimes`](#node-dictation-tab-chimes) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Chimes settings tab; show me the recording sounds settings page |
| Search (de) | phrases: öffne den Tab für die Signaltöne; zeig mir die Einstellungsseite für die Aufnahmetöne |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-clipboard"></a>

### Clipboard / Zwischenablage (`dictation.tab.clipboard`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictation`](#node-page-dictation) |
| Title source | catalog key `Clipboard` |
| Description | none |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictation.tab.clipboard`](#node-dictation-tab-clipboard) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: pasteboard, copy, paste, copied<br>phrases: where are the settings for copied text; show me the clipboard settings |
| Search (de) | words: Clipboard, kopieren, einfügen, kopiert<br>phrases: wo sind die Einstellungen für kopierten Text; zeig mir die Einstellungen für die Zwischenablage |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine"></a>

### TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE (`transcriptionEngine`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.transcriptionEngine`](#node-section-transcriptionEngine) |
| Title source | catalog key `TRANSCRIPTION ENGINE` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: transcriber<br>phrases: which model turns my dictation into the finished text; where do I choose the dictation model |
| Search (de) | words: Diktiermodell<br>phrases: welches Modell macht aus meinem Diktat den fertigen Text; wo wähle ich das Modell fürs Diktieren aus |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-change"></a>

### Change / Ändern (`transcriptionEngine.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: switch to a different dictation model; change the speech engine for my finished dictation |
| Search (de) | phrases: wechsle das Modell fürs Diktieren; wähle eine andere Engine für mein fertiges Diktat |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-keepCurrent"></a>

### Keep current engine / Aktuelle Engine beibehalten (`transcriptionEngine.keepCurrent`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Keep current engine` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep my current dictation model; leave the speech engine unchanged |
| Search (de) | phrases: behalte mein bisheriges Diktiermodell; lass die Engine fürs Diktieren unverändert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-recheckFast"></a>

### Re-check Fast model status / Modellstatus von „Schnell“ erneut prüfen (`transcriptionEngine.recheckFast`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Re-check Fast model status` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `fastSelected` |
| Arrival target | [`transcriptionEngine.recheckFast`](#node-transcriptionEngine-recheckFast) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: check whether the Fast model is ready; check Parakeet model status again |
| Search (de) | phrases: prüfe erneut, ob das schnelle Modell bereit ist; prüfe den Status von Parakeet noch einmal |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-cancelDownload"></a>

### Cancel / Abbrechen (`fastModel.cancelDownload`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Cancel` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `fastDeliveryAction` |
| Arrival target | [`fastModel.cancelDownload`](#node-fastModel-cancelDownload) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: cancel the Parakeet download; stop downloading the Fast dictation model |
| Search (de) | phrases: brich den Download von Parakeet ab; stoppe den Download des schnellen Diktiermodells |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-resume"></a>

### Resume / Fortsetzen (`fastModel.resume`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Resume` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `fastDeliveryAction` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: resume the paused Parakeet download; continue downloading the Fast dictation model |
| Search (de) | phrases: setze den pausierten Parakeet-Download fort; lade das schnelle Diktiermodell weiter herunter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-tryAgain"></a>

### Try Again / Erneut versuchen (`fastModel.tryAgain`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Try Again` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `fastDeliveryAction` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: retry the failed Parakeet download; try downloading the Fast dictation model again |
| Search (de) | phrases: versuche den fehlgeschlagenen Parakeet-Download noch einmal; lade das schnelle Diktiermodell erneut herunter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-setUp"></a>

### Set up model / Modell einrichten (`whisperModel.setUp`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Set up model` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.setUp`](#node-whisperModel-setUp) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: set up Whisper on my Mac; install the All Languages dictation model |
| Search (de) | phrases: richte Whisper auf meinem Mac ein; installiere das Diktiermodell für alle Sprachen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-cancelDownload"></a>

### Cancel / Abbrechen (`whisperModel.cancelDownload`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Cancel` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.cancelDownload`](#node-whisperModel-cancelDownload) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: cancel the Whisper download; stop downloading the All Languages dictation model |
| Search (de) | phrases: brich den Whisper-Download ab; stoppe den Download des Diktiermodells für alle Sprachen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-resume"></a>

### Resume / Fortsetzen (`whisperModel.resume`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Resume` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.resume`](#node-whisperModel-resume) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: resume the paused Whisper download; continue downloading the All Languages dictation model |
| Search (de) | phrases: setze den pausierten Whisper-Download fort; lade das Diktiermodell für alle Sprachen weiter herunter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-remove"></a>

### Remove Model / Modell entfernen (`whisperModel.remove`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Remove Model` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.remove`](#node-whisperModel-remove) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: delete the installed Whisper model; remove the All Languages dictation model from my Mac |
| Search (de) | phrases: lösche das installierte Whisper-Modell; entferne das Diktiermodell für alle Sprachen von meinem Mac |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-recheck"></a>

### Re-check model status / Modellstatus erneut prüfen (`whisperModel.recheck`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Re-check model status` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.recheck`](#node-whisperModel-recheck) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: check whether Whisper is ready; check the All Languages model status again |
| Search (de) | phrases: prüfe, ob Whisper bereit ist; prüfe den Status des Modells für alle Sprachen erneut |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-tryAgain"></a>

### Try Again / Erneut versuchen (`whisperModel.tryAgain`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Try Again` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `whisperSetupState` |
| Arrival target | [`whisperModel.tryAgain`](#node-whisperModel-tryAgain) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: retry the failed Whisper setup; try setting up the All Languages dictation model again |
| Search (de) | phrases: versuche die Einrichtung von Whisper noch einmal; richte das Diktiermodell für alle Sprachen erneut ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-currentEngineSection"></a>

### (named at runtime by `currentEngineHeading`) (`currentEngineSection`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictation.tab.engine`](#node-dictation-tab-engine) |
| Title source | resolver `currentEngineHeading` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`currentEngineSection`](#node-currentEngineSection) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show the settings for my active dictation engine; where are the options for the dictation model I am using |
| Search (de) | phrases: zeig mir die Einstellungen für meine aktive Diktierengine; wo sind die Optionen für das Diktiermodell, das ich gerade nutze |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoDetectLanguage"></a>

### Auto-detect language / Sprache automatisch erkennen (`autoDetectLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`currentEngineSection`](#node-currentEngineSection) |
| Title source | catalog key `Auto-detect language` |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `languageSectionAvailable` |
| Arrival target | [`autoDetectLanguage`](#node-autoDetectLanguage) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: autodetect, detection<br>phrases: detect which language I am speaking; recognize my language automatically; I do not want to choose my dictation language manually |
| Search (de) | words: Spracherkennung, automatische Spracherkennung<br>phrases: erkenne automatisch, welche Sprache ich spreche; finde meine Diktiersprache selbst heraus; ich möchte die Diktiersprache nicht von Hand auswählen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoDetectLanguage-resetSuggestions"></a>

### Reset suggestions / Vorschläge zurücksetzen (`autoDetectLanguage.resetSuggestions`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`autoDetectLanguage`](#node-autoDetectLanguage) |
| Title source | catalog key `Reset suggestions` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `languageSectionAvailable` |
| Arrival target | [`autoDetectLanguage.resetSuggestions`](#node-autoDetectLanguage-resetSuggestions) |
| Fallbacks, in order | [`autoDetectLanguage`](#node-autoDetectLanguage), [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: suggest locking a detected language again; reset the suggestions to fix my dictation language |
| Search (de) | phrases: schlage mir wieder vor, die erkannte Sprache festzulegen; setze die Vorschläge zum Festlegen der Diktiersprache zurück |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-lockedLanguage"></a>

### (named at runtime by `lockedLanguage`) (`lockedLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`currentEngineSection`](#node-currentEngineSection) |
| Title source | resolver `lockedLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | Choose the language for dictation and preview. / Wähle die Sprache für Diktat und Vorschau. |
| Description source | catalog key `Choose the language for dictation and preview.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `languageLocked` |
| Arrival target | [`lockedLanguage`](#node-lockedLanguage) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: lock, fixed<br>phrases: always use the same language for dictation; set a fixed language for dictation and preview; stop guessing which language I am speaking |
| Search (de) | words: Diktiersprache, festlegen, fest<br>phrases: verwende fürs Diktieren immer dieselbe Sprache; lege die Sprache für Diktat und Vorschau fest; erkenne meine Diktiersprache nicht automatisch |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-lockedLanguage-change"></a>

### Change / Ändern (`lockedLanguage.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`lockedLanguage`](#node-lockedLanguage) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `languageLocked` |
| Arrival target | [`lockedLanguage.change`](#node-lockedLanguage-change) |
| Fallbacks, in order | [`lockedLanguage`](#node-lockedLanguage), [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change my fixed dictation language from the Engine tab |
| Search (de) | phrases: ändere meine festgelegte Diktiersprache im Engine-Tab |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fasterTranscription"></a>

### Faster Transcription / Schnellere Transkription (`fasterTranscription`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`currentEngineSection`](#node-currentEngineSection) |
| Title source | catalog key `Faster Transcription` |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`fasterTranscription`](#node-fasterTranscription) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: processing, latency<br>phrases: process my dictation while I am still recording; reduce the wait for the finished transcription; start transcribing before I stop recording |
| Search (de) | words: Verarbeitung, Wartezeit, Latenz<br>phrases: verarbeite mein Diktat schon während der Aufnahme; verkürze die Wartezeit auf den fertigen Text; beginne mit der Transkription, bevor ich die Aufnahme beende |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-stopOnSilence"></a>

### Stop recording on silence / Aufnahme bei Stille stoppen (`stopOnSilence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Stop recording on silence` |
| Description | Ends recording after you stop speaking. / Beendet die Aufnahme, wenn du aufhörst zu sprechen. |
| Description source | catalog key `Ends recording after you stop speaking.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`stopOnSilence`](#node-stopOnSilence) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: silence, autostop<br>phrases: stop recording when I stop talking; end my dictation automatically when I go quiet; I want recording to stop without pressing a key |
| Search (de) | words: Stille, Autostopp, Sprechpause<br>phrases: stoppe die Aufnahme, wenn ich nicht mehr spreche; beende mein Diktat automatisch bei Stille; beende die Aufnahme, ohne dass ich eine Taste drücken muss |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pauseDuration"></a>

### Pause duration / Pausendauer (`pauseDuration`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`stopOnSilence`](#node-stopOnSilence) |
| Title source | catalog key `Pause duration` |
| Description | How long a pause ends the recording. / Wie lange eine Pause dauern muss, um die Aufnahme zu beenden. |
| Description source | catalog key `How long a pause ends the recording.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `stopOnSilenceOn` |
| Arrival target | [`pauseDuration`](#node-pauseDuration) |
| Fallbacks, in order | [`stopOnSilence`](#node-stopOnSilence) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: timeout, delay<br>phrases: how long can I stay quiet before recording stops; wait longer before stopping on silence; change the length of the pause that ends recording |
| Search (de) | words: Zeitlimit, Verzögerung, Pausenlänge<br>phrases: wie lange darf ich still sein, bevor die Aufnahme endet; warte bei Stille länger, bevor du die Aufnahme stoppst; ändere, wie lang die Pause zum Beenden der Aufnahme sein muss |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fillerRemoval"></a>

### Remove filler words (um, uh, hmm...) / Füllwörter entfernen (ähm, äh, hm...) (`fillerRemoval`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Remove filler words (um, uh, hmm...)` |
| Description | Strips common filler words from transcriptions. / Entfernt häufige Füllwörter aus Transkripten. |
| Description source | catalog key `Strips common filler words from transcriptions.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`fillerRemoval`](#node-fillerRemoval) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: um, uh, hmm, ums, hesitations, fillers<br>phrases: remove ums and uhs from my text; leave out my hesitation sounds; remove filler words from my dictation |
| Search (de) | words: ähm, äh, hm, Ähms, Fülllaute<br>phrases: lass die Ähms aus meinem Text weg; entferne meine Füllwörter beim Diktieren; schreib meine Ähs und Ähms nicht mit |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-spokenEmoji"></a>

### Convert spoken emoji (e.g. "thumbs up emoji" → 👍) / Gesprochene Emojis umwandeln (z. B. „Daumen hoch Emoji“ → 👍) (`spokenEmoji`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Convert spoken emoji (e.g. "thumbs up emoji" → 👍)` |
| Description | Say a phrase followed by emoji to get its symbol. / Sag einen Ausdruck und danach „Emoji“, um das Symbol einzufügen. |
| Description source | catalog key `Say a phrase followed by emoji to get its symbol.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`spokenEmoji`](#node-spokenEmoji) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: smiley, smileys, 👍<br>phrases: turn spoken emoji names into symbols; insert a thumbs up when I say thumbs up emoji; let me dictate smileys by saying their name and emoji |
| Search (de) | words: Smiley, Smileys, 👍<br>phrases: mach aus gesprochenen Emoji-Namen die passenden Symbole; füge einen Daumen hoch ein, wenn ich Daumen hoch Emoji sage; ich möchte Smileys mit ihrem Namen und dem Wort Emoji diktieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-spokenPunctuation"></a>

### Spoken punctuation / Gesprochene Satzzeichen (`spokenPunctuation`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Spoken punctuation` |
| Description | Say comma or new paragraph to insert it. / Sag „comma“ oder „new paragraph“, um es einzufügen. |
| Description source | catalog key `Say comma or new paragraph to insert it.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: comma, period, paragraph, colon, semicolon<br>phrases: insert punctuation by speaking a command; start a new paragraph with a spoken command; let me dictate commas and periods |
| Search (de) | words: Komma, Punkt, Absatz, Doppelpunkt, Semikolon<br>phrases: füge Satzzeichen mit einem gesprochenen Befehl ein; beginne mit einem Sprachbefehl einen neuen Absatz; ich möchte Kommas und Punkte diktieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage"></a>

### Start word / Startwort (`startWordLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`spokenPunctuation`](#node-spokenPunctuation) |
| Title source | catalog key `Start word` |
| Description | The word you say before a mark. / Das Wort, das du vor einem Zeichen sagst. |
| Description source | catalog key `The word you say before a mark.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose which language I am editing the punctuation start word for; select the language for the punctuation trigger settings |
| Search (de) | phrases: wähle, für welche Sprache ich das Startwort für Satzzeichen bearbeite; für welche Sprache stelle ich den Satzzeichenauslöser ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordField"></a>

### Start word for / Startwort für (`startWordField`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`spokenPunctuation`](#node-spokenPunctuation) |
| Title source | catalog key `Start word for` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordField`](#node-startWordField) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: prefix, trigger<br>phrases: set the word I say before a punctuation mark; enter my own punctuation trigger word; change the spoken prefix for punctuation |
| Search (de) | words: Auslösewort, Befehlswort, Signalwort<br>phrases: lege fest, welches Wort ich vor einem Satzzeichen sagen muss; gib mein eigenes Auslösewort für Satzzeichen ein; ändere das Wort vor dem Satzzeichenbefehl |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWord-save"></a>

### Save word / Wort sichern (`startWord.save`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`startWordField`](#node-startWordField) |
| Title source | catalog key `Save word` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWord.save`](#node-startWord-save) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: save the punctuation start word I entered; apply my new punctuation trigger |
| Search (de) | phrases: speichere mein eingegebenes Startwort für Satzzeichen; übernimm mein neues Auslösewort für Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWord-reset"></a>

### Reset / Zurücksetzen (`startWord.reset`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`startWordField`](#node-startWordField) |
| Title source | catalog key `Reset` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWord.reset`](#node-startWord-reset) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: restore the default punctuation start word; reset my custom punctuation trigger |
| Search (de) | phrases: stell das voreingestellte Startwort für Satzzeichen wieder her; setze mein eigenes Auslösewort für Satzzeichen zurück |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel"></a>

### Unload model after / Modell entladen nach (`unloadModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Unload model after` |
| Description | Frees memory when you are not dictating. / Gibt Speicher frei, wenn du nicht diktierst. |
| Description source | catalog key `Frees memory when you are not dictating.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: RAM, memory, unloading<br>phrases: free the dictation model memory when I am not using it; choose how long the speech model stays in memory; change when the dictation model is unloaded |
| Search (de) | words: RAM, Arbeitsspeicher, Speicher, entladen<br>phrases: gib den Arbeitsspeicher frei, wenn ich nicht diktiere; wie lange soll das Diktiermodell im Speicher bleiben; ändere, wann das Diktiermodell aus dem Speicher entfernt wird |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputDevice"></a>

### Input device / Eingabegerät (`inputDevice`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Input device` |
| Description | Choose the microphone used for recording. / Wähle das Mikrofon für die Aufnahme. |
| Description source | catalog key `Choose the microphone used for recording.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`inputDevice`](#node-inputDevice) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: mic, source<br>phrases: choose which microphone records my voice; select the microphone I dictate into; where do I choose my recording device |
| Search (de) | words: Mikro, Mikroauswahl, Aufnahmegerät<br>phrases: wähle das Mikrofon, das meine Stimme aufnimmt; welches Mikro soll ich fürs Diktieren benutzen; wo wähle ich mein Aufnahmegerät aus |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputDevice-auto"></a>

### Auto / Auto (`inputDevice.auto`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`inputDevice`](#node-inputDevice) |
| Title source | catalog key `Auto` |
| Description | Follows macOS / Folgt macOS |
| Description source | catalog key `Follows macOS` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`inputDevice`](#node-inputDevice) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: default, system<br>phrases: use the microphone selected in macOS; follow the Mac sound input setting |
| Search (de) | words: Standardmikrofon, Systemmikrofon<br>phrases: nimm das Mikrofon, das in macOS ausgewählt ist; verwende die Toneingabe aus den Mac-Einstellungen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputDevice-device"></a>

### (named at runtime by `inputDeviceName`) (`inputDevice.device`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`inputDevice`](#node-inputDevice) |
| Title source | resolver `inputDeviceName` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`inputDevice`](#node-inputDevice) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: USB, headset, internal, external<br>phrases: select a specific microphone from the device list; use my USB microphone; use my headset microphone instead of the built-in mic |
| Search (de) | words: USB, Headset, intern, extern<br>phrases: wähle ein bestimmtes Mikrofon aus der Geräteliste; nimm mein USB-Mikrofon; nimm das Mikrofon meines Headsets statt des eingebauten Mikros |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputSocket"></a>

### Mic is on / Mikrofon ist an (`inputSocket`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`inputDevice`](#node-inputDevice) |
| Title source | catalog key `Mic is on` |
| Description | Choose the socket your microphone is plugged into. / Wähle den Anschluss, an dem dein Mikrofon steckt. |
| Description source | catalog key `Choose the socket your microphone is plugged into.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `multiInputDevice` |
| Arrival target | [`inputSocket`](#node-inputSocket) |
| Fallbacks, in order | [`inputDevice`](#node-inputDevice) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: socket, port, channel, interface<br>phrases: choose the socket my microphone is plugged into; select the microphone channel on my audio interface |
| Search (de) | words: Buchse, Anschluss, Kanal, Audiointerface<br>phrases: wähle die Buchse, an der mein Mikrofon steckt; stelle den Mikrofonkanal an meinem Audiointerface ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputSocket-input"></a>

### (named at runtime by `inputSocketOption`) (`inputSocket.input`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`inputSocket`](#node-inputSocket) |
| Title source | resolver `inputSocketOption` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `multiInputDevice` |
| Arrival target | [`inputSocket`](#node-inputSocket) |
| Fallbacks, in order | [`inputDevice`](#node-inputDevice) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use input 1 for this microphone; use input 2 for this microphone; select the numbered input my microphone is connected to |
| Search (de) | phrases: nimm Eingang 1 für dieses Mikrofon; nimm Eingang 2 für dieses Mikrofon; wähle den nummerierten Eingang, an dem mein Mikrofon steckt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation"></a>

### Media during dictation / Medien beim Diktieren (`mediaDuringDictation`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Media during dictation` |
| Description | What music and video do while you dictate. / Was beim Diktieren mit Musik und Videos passiert. |
| Description source | catalog key `What music and video do while you dictate.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: music, video, podcast, playback, media<br>phrases: what should happen to my music while I dictate; choose how videos behave during recording; change what happens to background audio during dictation |
| Search (de) | words: Musik, Video, Podcast, Wiedergabe, Hintergrundton<br>phrases: was soll mit meiner Musik beim Diktieren passieren; stelle ein, was Videos während der Aufnahme machen; ändere, was beim Diktieren mit dem Hintergrundton passiert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness"></a>

### Microphone readiness / Mikrofonbereitschaft (`micReadiness`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Microphone readiness` |
| Description | How long the mic stays ready after recording. / Wie lange das Mikrofon nach der Aufnahme bereit bleibt. |
| Description source | catalog key `How long the mic stays ready after recording.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: standby, warmup, readiness<br>phrases: choose how long the microphone stays ready after recording; keep the mic ready between recordings; change the microphone standby time |
| Search (de) | words: Standby, Bereitschaft, warmhalten<br>phrases: wie lange soll das Mikro nach der Aufnahme bereit bleiben; halte das Mikrofon zwischen Aufnahmen bereit; ändere die Bereitschaftszeit des Mikrofons |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-bluetoothGuide"></a>

### Using a Bluetooth microphone? / Verwendest du ein Bluetooth-Mikrofon? (`bluetoothGuide`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Using a Bluetooth microphone?` |
| Description | Keeping your mic ready reduces Bluetooth startup delay. / Ein bereites Mikrofon verkürzt die Startverzögerung bei Bluetooth. |
| Description source | catalog key `Keeping your mic ready reduces Bluetooth startup delay.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`bluetoothGuide`](#node-bluetoothGuide) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Bluetooth, startup<br>phrases: why does my Bluetooth mic take so long to start; how can I reduce Bluetooth microphone startup delay; explain how keeping my Bluetooth mic ready helps |
| Search (de) | words: Bluetooth, Startverzögerung, Anlaufzeit<br>phrases: warum braucht mein Bluetooth-Mikro so lange zum Starten; wie startet mein Bluetooth-Mikro schneller; erkläre mir, warum ein bereites Mikro bei Bluetooth hilft |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-bluetoothGuide-learnMore"></a>

### Learn more / Mehr erfahren (`bluetoothGuide.learnMore`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`bluetoothGuide`](#node-bluetoothGuide) |
| Title source | catalog key `Learn more` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`bluetoothGuide.learnMore`](#node-bluetoothGuide-learnMore) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Bluetooth microphone startup guide; read the help about keeping a Bluetooth mic ready |
| Search (de) | phrases: öffne die Hilfe zur Startverzögerung von Bluetooth-Mikros; zeig mir den Ratgeber zur Bereitschaft von Bluetooth-Mikrofonen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview"></a>

### Show words while you speak / Wörter beim Sprechen anzeigen (`livePreview`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.livePreview`](#node-section-livePreview) |
| Title source | catalog key `Show words while you speak` |
| Description | See words before you finish your dictation. / Sieh den Text schon während des Diktierens. |
| Description source | catalog key `See words before you finish your dictation.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`livePreview`](#node-livePreview) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: realtime, interim, live<br>phrases: show my words before I finish dictating; let me see my text while I speak; turn the live text preview on or off |
| Search (de) | words: Echtzeit, mitlesen, Zwischentext<br>phrases: zeig mir meinen Text, bevor ich fertig diktiert habe; ich möchte meine Wörter beim Sprechen mitlesen; schalte die Live-Vorschau ein oder aus |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview-language"></a>

### (named at runtime by `previewLanguage`) (`livePreview.language`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`livePreview`](#node-livePreview) |
| Title source | resolver `previewLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | This changes dictation too, not just the preview. / Das ändert auch das Diktat, nicht nur die Vorschau. |
| Description source | catalog key `This changes dictation too, not just the preview.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewLanguageKnown` |
| Arrival target | [`livePreview.language`](#node-livePreview-language) |
| Fallbacks, in order | [`livePreview`](#node-livePreview) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change the dictation language from Live Preview settings; change the preview language and dictation language together here |
| Search (de) | phrases: ändere die Diktiersprache in den Einstellungen der Live-Vorschau; ändere hier die Sprache für Vorschau und Diktat zusammen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview-browseDownloads"></a>

### Browse downloads / Downloads ansehen (`livePreview.browseDownloads`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`livePreview`](#node-livePreview) |
| Title source | catalog key `Browse downloads` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewLanguageMissing` |
| Arrival target | [`livePreview.browseDownloads`](#node-livePreview-browseDownloads) |
| Fallbacks, in order | [`livePreview`](#node-livePreview) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: browse the downloads from Live Preview settings; open the download list for the live text preview |
| Search (de) | phrases: öffne die Downloadliste in den Einstellungen der Live-Vorschau; zeig mir die Downloads für die laufende Textvorschau |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine"></a>

### Preview engine / Vorschau-Engine (`previewEngine`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.previewEngine`](#node-section-previewEngine) |
| Title source | catalog key `Preview engine` |
| Description | Choose which engine shows words while you speak. / Wähle die Engine, die Wörter beim Sprechen anzeigt. |
| Description source | catalog key `Choose which engine shows words while you speak.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose which engine recognizes the live preview text; which model powers the words shown while I speak; where do I choose the preview engine |
| Search (de) | words: Vorschaumodell<br>phrases: wähle die Engine für die Wörter in der Live-Vorschau; welches Modell erkennt den Text, den ich beim Sprechen sehe; wo wähle ich die Vorschau-Engine aus |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-change"></a>

### Change / Ändern (`previewEngine.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: switch to a different live preview engine; change the model that shows words while I speak |
| Search (de) | phrases: wechsle die Engine für die Live-Vorschau; wähle ein anderes Modell für den Text beim Sprechen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-compare"></a>

### Compare engines / Engines vergleichen (`previewEngine.compare`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | catalog key `Compare engines` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`previewEngine.compare`](#node-previewEngine-compare) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: comparison, differences<br>phrases: compare Apple and Universal preview engines; show me how the live preview engines differ |
| Search (de) | words: Vergleich, Unterschiede<br>phrases: vergleiche Apple und Universal für die Live-Vorschau; zeig mir die Unterschiede zwischen den Vorschau-Engines |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-keepCurrent"></a>

### Keep current preview engine / Aktuelle Vorschau-Engine beibehalten (`previewEngine.keepCurrent`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | catalog key `Keep current preview engine` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewChoicesExpanded` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep my current live preview engine; leave the preview model unchanged |
| Search (de) | phrases: behalte meine bisherige Vorschau-Engine; lass das Modell für die Live-Vorschau unverändert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-download"></a>

### Download / Laden (`previewEngine.universal.download`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine.universal`](#node-previewEngine-universal) |
| Title source | catalog key `Download` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `universalSetupState` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: download the Universal live preview model; install Universal for the text preview |
| Search (de) | phrases: lade das Universal-Modell für die Live-Vorschau herunter; installiere Universal für die Textvorschau |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-cancel"></a>

### Cancel / Abbrechen (`previewEngine.universal.cancel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine.universal`](#node-previewEngine-universal) |
| Title source | catalog key `Cancel` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `universalSetupState` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: cancel the Universal preview download; stop downloading the Universal live preview model |
| Search (de) | phrases: brich den Download des Universal-Vorschaumodells ab; stoppe den Universal-Download für die Live-Vorschau |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-resume"></a>

### Resume / Fortsetzen (`previewEngine.universal.resume`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine.universal`](#node-previewEngine-universal) |
| Title source | catalog key `Resume` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `universalSetupState` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: resume the paused Universal preview download; continue downloading Universal where it stopped |
| Search (de) | phrases: setze den pausierten Download des Universal-Vorschaumodells fort; lade Universal an der unterbrochenen Stelle weiter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-retry"></a>

### Try Again / Erneut versuchen (`previewEngine.universal.retry`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine.universal`](#node-previewEngine-universal) |
| Title source | catalog key `Try Again` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `universalSetupState` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: retry the failed Universal preview download; try downloading the Universal preview model again |
| Search (de) | phrases: versuche den fehlgeschlagenen Universal-Download erneut; lade das Universal-Vorschaumodell noch einmal herunter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-remove"></a>

### Remove / Entfernen (`previewEngine.universal.remove`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewEngine.universal`](#node-previewEngine-universal) |
| Title source | catalog key `Remove` |
| Description | none |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `universalSetupState` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: delete the installed Universal preview model; remove the Universal live preview download from my Mac |
| Search (de) | phrases: lösche das installierte Universal-Vorschaumodell; entferne das heruntergeladene Universal-Modell von meinem Mac |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewLanguages"></a>

### Languages / Sprachen (`previewLanguages`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.previewEngine`](#node-section-previewEngine) |
| Title source | catalog key `Languages` |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `appleLanguagePacks` |
| Arrival target | [`previewLanguages`](#node-previewLanguages) |
| Fallbacks, in order | [`previewEngine`](#node-previewEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: installed, inventory<br>phrases: which preview languages are installed on my Mac; show the installed language packs for live preview; how many preview languages are already installed |
| Search (de) | words: Sprachpakete, installiert<br>phrases: welche Vorschausprachen sind auf meinem Mac installiert; zeig mir die installierten Sprachpakete für die Live-Vorschau; wie viele Sprachen sind für die Vorschau schon installiert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewLanguages-install"></a>

### (named at runtime by `previewLanguagesInstall`) (`previewLanguages.install`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewLanguages`](#node-previewLanguages) |
| Title source | resolver `previewLanguagesInstall` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | Download a language from macOS to preview it. / Lade für die Vorschau ein Sprachpaket von macOS herunter. |
| Description source | catalog key `Download a language from macOS to preview it.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `appleLanguagePacks` |
| Arrival target | [`previewLanguages`](#node-previewLanguages) |
| Fallbacks, in order | [`previewEngine`](#node-previewEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: download another macOS language for live preview; install a new Apple language pack for the text preview |
| Search (de) | phrases: lade eine weitere macOS-Sprache für die Live-Vorschau herunter; installiere ein neues Apple-Sprachpaket für die Textvorschau |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition"></a>

### Position on screen / Position auf dem Bildschirm (`pillPosition`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.pill`](#node-section-pill) |
| Title source | catalog key `Position on screen` |
| Description | Where the pill floats while you dictate. / Wo die Aufnahmeanzeige beim Diktieren schwebt. |
| Description source | catalog key `Where the pill floats while you dictate.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillPosition`](#node-pillPosition) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: placement, location, move<br>phrases: change where the recording pill appears on screen; move the floating recording indicator; choose the recording widget's screen position |
| Search (de) | words: verschieben, Anzeigeort, Platzierung<br>phrases: ändere, wo die Aufnahmeanzeige auf dem Bildschirm erscheint; verschiebe die schwebende Aufnahmeanzeige; stelle die Position des Aufnahmefensters ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle"></a>

### Style / Stil (`pillStyle`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.pill`](#node-section-pill) |
| Title source | catalog key `Style` |
| Description | What the floating pill shows while you record. / Was die Aufnahmeanzeige während der Aufnahme zeigt. |
| Description source | catalog key `What the floating pill shows while you record.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: appearance, design, layout<br>phrases: change what the recording pill looks like; choose what the floating recording indicator displays; change the recording widget design |
| Search (de) | words: Aussehen, Design, Layout<br>phrases: ändere das Aussehen der Aufnahmeanzeige; wähle, was die schwebende Aufnahmeanzeige zeigt; stelle das Design des Aufnahmefensters ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-configureLivePreview"></a>

### Configure Live Preview / Live-Vorschau einrichten (`pillStyle.configureLivePreview`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Configure Live Preview` |
| Description | none |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `pillShowsWords` |
| Arrival target | [`pillStyle.configureLivePreview`](#node-pillStyle-configureLivePreview) |
| Fallbacks, in order | [`pillStyle`](#node-pillStyle) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open Live Preview settings from the recording pill style options |
| Search (de) | phrases: öffne die Live-Vorschau-Einstellungen bei den Stilen der Aufnahmeanzeige |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChimes"></a>

### Play recording chimes / Aufnahmesignaltöne abspielen (`recordingChimes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.chimes`](#node-section-chimes) |
| Title source | catalog key `Play recording chimes` |
| Description | Plays a short chime when recording starts and stops. / Spielt beim Start und Ende der Aufnahme einen kurzen Signalton. |
| Description source | catalog key `Plays a short chime when recording starts and stops.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChimes`](#node-recordingChimes) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: beep, beeps, cues, chiming<br>phrases: turn recording start and stop sounds on or off; play a sound when recording begins and ends; disable the beeps at the start and end of recording |
| Search (de) | words: piepen, Piepton, Pieptöne, Aufnahmetöne<br>phrases: schalte die Töne für Aufnahmestart und Aufnahmeende ein oder aus; spiel einen Ton, wenn die Aufnahme beginnt und endet; schalte das Piepen beim Starten und Stoppen der Aufnahme aus |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime"></a>

### RECORDING CHIMES / AUFNAHMESIGNALTÖNE (`recordingChime`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.chimes`](#node-section-chimes) |
| Title source | catalog key `RECORDING CHIMES` |
| Description | Hear this chime without changing your choice. / Hör dir diesen Signalton an, ohne deine Auswahl zu ändern. |
| Description source | catalog key `Hear this chime without changing your choice.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: audition, sample, listen<br>phrases: let me hear this recording sound before choosing it; play a chime sample without changing my selection; test this recording sound |
| Search (de) | words: probehören, Klangprobe, anhören, Tonprobe<br>phrases: spiel mir diesen Aufnahmeton zur Probe vor; lass mich den Ton hören, ohne meine Auswahl zu ändern; ich möchte diesen Ton erst einmal anhören |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-preview"></a>

### (named at runtime by `chimePreview`) (`recordingChime.preview`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | resolver `chimePreview` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: listen, hear<br>phrases: play this chime for me; let me hear this sound |
| Search (de) | words: anhören, probehören<br>phrases: spiel mir diesen Ton vor; lass mich den Klang anhören |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoCopyToClipboard"></a>

### Auto-copy to clipboard / Automatisch in die Zwischenablage kopieren (`autoCopyToClipboard`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Auto-copy to clipboard` |
| Description | Copies dictation when automatic pasting is skipped. / Kopiert dein Diktat, wenn das automatische Einfügen übersprungen wird. |
| Description source | catalog key `Copies dictation when automatic pasting is skipped.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`autoCopyToClipboard`](#node-autoCopyToClipboard) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: copy my dictation when automatic pasting is skipped; keep my dictation on the clipboard if it is not pasted |
| Search (de) | phrases: kopiere mein Diktat, wenn es nicht automatisch eingefügt wird; leg mein Diktat in die Zwischenablage, wenn das Einfügen übersprungen wird |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-restoreClipboard"></a>

### Restore clipboard after paste / Zwischenablage nach dem Einfügen wiederherstellen (`restoreClipboard`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Restore clipboard after paste` |
| Description | Puts back what was on your clipboard before pasting. / Stellt den vorherigen Inhalt der Zwischenablage nach dem Einfügen wieder her. |
| Description source | catalog key `Puts back what was on your clipboard before pasting.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`restoreClipboard`](#node-restoreClipboard) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: put my previous clipboard contents back after pasting; keep what I copied before dictating |
| Search (de) | phrases: stell nach dem Einfügen meinen alten Zwischenablageinhalt wieder her; behalte das, was ich vor dem Diktieren kopiert habe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-smartInsertion"></a>

### Smart insertion / Intelligentes Einfügen (`smartInsertion`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Smart insertion` |
| Description | Fits text to the spacing and capitals around your cursor. / Passt Abstände und Großschreibung an den Text um den Cursor an. |
| Description source | catalog key `Fits text to the spacing and capitals around your cursor.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`smartInsertion`](#node-smartInsertion) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: spacing, capitalization, spaces, cursor<br>phrases: fit the spaces around my cursor; match capital letters to the surrounding text |
| Search (de) | words: Leerzeichen, Großschreibung, Abstände, Cursor<br>phrases: pass die Leerzeichen an den Text um den Cursor an; pass die Großschreibung an den umgebenden Text an |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAddClipboardFallback"></a>

### Read selections through the clipboard / Auswahl über die Zwischenablage lesen (`quickAddClipboardFallback`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.quickAddClipboard`](#node-section-quickAddClipboard) |
| Title source | catalog key `Read selections through the clipboard` |
| Description | Reads hidden selections and restores your clipboard. / Liest verborgene Auswahlen und stellt die Zwischenablage wieder her. |
| Description source | catalog key `Reads hidden selections and restores your clipboard.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`quickAddClipboardFallback`](#node-quickAddClipboardFallback) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use the clipboard to read a selected dictionary word; read my selected word when the app hides the selection |
| Search (de) | phrases: lies das markierte Wort fürs Wörterbuch über die Zwischenablage; erkenne mein markiertes Wort auch dann, wenn die App die Auswahl nicht freigibt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode"></a>

### Recording mode / Aufnahmemodus (`recordingMode`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Recording mode` |
| Description | Hold to talk, or press once to start and again to stop. / Zum Sprechen gedrückt halten oder einmal zum Starten und noch einmal zum Stoppen drücken. |
| Description source | catalog key `Hold to talk, or press once to start and again to stop.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingMode`](#node-recordingMode) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: behavior, activation<br>phrases: change how the dictation key works; choose between holding the key and pressing it twice |
| Search (de) | words: Tastenverhalten, Bedienung<br>phrases: stell ein, wie die Diktattaste funktioniert; lass mich zwischen Gedrückthalten und zweimaligem Drücken wählen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordKeybind"></a>

### Start / stop recording / Aufnahme starten / stoppen (`recordKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Start / stop recording` |
| Description | Click Change to choose the keys you use. / Klicke auf „Ändern“, um deine Tasten festzulegen. |
| Description source | catalog key `Click Change to choose the keys you use.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordKeybind`](#node-recordKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change my dictation shortcut; choose the keys that start and stop recording |
| Search (de) | words: Diktattaste, Diktierkürzel<br>phrases: ändere mein Tastenkürzel fürs Diktieren; leg die Tasten zum Starten und Stoppen der Aufnahme fest |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-cancelKeybind"></a>

### Cancel recording / Aufnahme abbrechen (`cancelKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Cancel recording` |
| Description | Cancels the current recording. / Bricht die laufende Aufnahme ab. |
| Description source | catalog key `Cancels the current recording.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`cancelKeybind`](#node-cancelKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: abort<br>phrases: change the shortcut that cancels recording; choose a key to discard the current recording |
| Search (de) | words: Abbruchtaste, Abbruchkürzel<br>phrases: ändere mein Tastenkürzel zum Abbrechen der Aufnahme; leg eine Taste zum Verwerfen der laufenden Aufnahme fest |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-escapeRecovery"></a>

### Escape Recovery / Wiederherstellung bei Escape (`escapeRecovery`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Escape Recovery` |
| Description | Keeps cancelled dictations in History for 24 hours. / Behält abgebrochene Diktate 24 Stunden lang im Verlauf. |
| Description source | catalog key `Keeps cancelled dictations in History for 24 hours.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`escapeRecovery`](#node-escapeRecovery) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recover, recovery, history<br>phrases: keep cancelled dictations for 24 hours; recover my dictation after I accidentally press escape |
| Search (de) | words: retten, Verlauf, Wiederherstellung<br>phrases: bewahre abgebrochene Diktate 24 Stunden lang auf; rette mein Diktat, wenn ich versehentlich Escape drücke |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAddKeybind"></a>

### Add selected word to Dictionary / Markiertes Wort zum Wörterbuch hinzufügen (`quickAddKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Add selected word to Dictionary` |
| Description | Select a misheard word, then press these keys. / Markiere ein falsch erkanntes Wort und drücke dann diese Tasten. |
| Description source | catalog key `Select a misheard word, then press these keys.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`quickAddKeybind`](#node-quickAddKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: misheard, vocabulary<br>phrases: set a shortcut to add a selected word to the dictionary; add a misheard word with a key press |
| Search (de) | words: Wortschatz, Wörterbuchkürzel<br>phrases: leg ein Tastenkürzel zum Hinzufügen markierter Wörter fest; füge ein falsch erkanntes Wort per Tastendruck zum Wörterbuch hinzu |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pasteLastKeybind"></a>

### Paste last dictation / Letztes Diktat einfügen (`pasteLastKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Paste last dictation` |
| Description | Pastes your last dictation. / Fügt dein letztes Diktat ein. |
| Description source | catalog key `Pastes your last dictation.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pasteLastKeybind`](#node-pasteLastKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: reinsert<br>phrases: set a shortcut to paste my last dictation; insert what I just dictated again |
| Search (de) | phrases: leg ein Tastenkürzel zum Einfügen meines letzten Diktats fest; füge meinen zuletzt diktierten Text nochmal ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-copyLastKeybind"></a>

### Copy last dictation / Letztes Diktat kopieren (`copyLastKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Copy last dictation` |
| Description | Copies your last dictation. / Kopiert dein letztes Diktat. |
| Description source | catalog key `Copies your last dictation.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`copyLastKeybind`](#node-copyLastKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: set a shortcut to copy my last dictation; copy what I just dictated to the clipboard |
| Search (de) | phrases: leg ein Tastenkürzel zum Kopieren meines letzten Diktats fest; kopiere meinen zuletzt diktierten Text in die Zwischenablage |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-keybind-resetToDefault"></a>

### Reset to default / Auf Standard zurücksetzen (`keybind.resetToDefault`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Reset to default` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordKeybind`](#node-recordKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: reset, default<br>phrases: restore this shortcut's original keys |
| Search (de) | words: zurücksetzen, Standard<br>phrases: stell die ursprünglichen Tasten für dieses Kürzel wieder her |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcribeFile-steps"></a>

### (named at runtime by `transcribeFileStep`) (`transcribeFile.steps`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`page.transcribeFile`](#node-page-transcribeFile) |
| Title source | resolver `transcribeFileStep` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `transcribeFile` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`transcribeFile.steps`](#node-transcribeFile-steps) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: stages, steps, progress<br>phrases: show the steps from uploading a file to the finished transcript; show which stage my file transcription is at |
| Search (de) | words: Schritte, Ablauf, Fortschritt<br>phrases: zeig mir die Schritte von der Datei bis zum fertigen Text; zeig mir, bei welchem Schritt die Dateitranskription gerade ist |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-enableAIPolish"></a>

### Enable AI Polish / KI-Nachbearbeitung aktivieren (`enableAIPolish`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.aiPolish`](#node-page-aiPolish) |
| Title source | catalog key `settings.aiPolish.enable.title` |
| Description | Fixes grammar, punctuation and formatting / Korrigiert Grammatik, Zeichensetzung und Formatierung |
| Description source | catalog key `Fixes grammar, punctuation and formatting` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`enableAIPolish`](#node-enableAIPolish) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: grammar, punctuation, formatting, proofread<br>phrases: turn on automatic grammar correction for dictation; fix punctuation and formatting after I dictate |
| Search (de) | words: Grammatik, Satzzeichen, Zeichensetzung, Formatierung<br>phrases: verbessere nach dem Diktieren automatisch die Grammatik; korrigiere Satzzeichen und Formatierung meiner Diktate |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider"></a>

### (named at runtime by `providerName`) (`aiPolishProvider`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.aiPolishModel`](#node-section-aiPolishModel) |
| Title source | resolver `providerName` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose the model that cleans up my dictation; switch the AI provider for my dictated text |
| Search (de) | phrases: wähle das Modell für die Nachbearbeitung meiner Diktate; wechsle den KI-Anbieter für meinen diktierten Text |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-providerSection"></a>

### (named at runtime by `providerSection`) (`aiPolish.providerSection`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | resolver `providerSection` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show the settings specific to my selected dictation polish model; find the options that apply only to my chosen dictation provider |
| Search (de) | phrases: zeig mir die Einstellungen speziell für mein gewähltes Diktatkorrekturmodell; zeig mir die Optionen, die nur für meinen gewählten Anbieter zur KI-Nachbearbeitung gelten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-egOne"></a>

### Why use EG-1 / Warum EG-1 verwenden? (`aiPolish.whyUse.egOne`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.egOne`](#node-aiPolishProvider-egOne) |
| Title source | catalog key `Why use EG-1` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.egOne`](#node-aiPolish-whyUse-egOne) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: how long does EG-1 cleanup take; when should I choose something other than EG-1 |
| Search (de) | phrases: wie lange dauert die Nachbearbeitung mit EG-1; wann sollte ich statt EG-1 ein anderes Modell nehmen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-s1Mini"></a>

### Why use S1-mini / Warum S1-mini verwenden? (`aiPolish.whyUse.s1Mini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.s1Mini`](#node-aiPolishProvider-s1Mini) |
| Title source | catalog key `Why use %@` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.s1Mini`](#node-aiPolish-whyUse-s1Mini) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: is S1-mini a good fit for my language; when should I choose S1-mini |
| Search (de) | phrases: eignet sich S1-mini für meine Sprache; wann ist S1-mini die richtige Wahl |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-appleIntelligence"></a>

### Why use Apple Intelligence / Warum Apple Intelligence verwenden? (`aiPolish.whyUse.appleIntelligence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.appleIntelligence`](#node-aiPolishProvider-appleIntelligence) |
| Title source | catalog key `Why use Apple Intelligence` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.appleIntelligence`](#node-aiPolish-whyUse-appleIntelligence) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: why is Apple Intelligence unavailable; when is Apple's built-in cleanup model a good fit |
| Search (de) | phrases: warum ist Apple Intelligence nicht verfügbar; wann eignet sich Apples eingebautes Modell zur Nachbearbeitung |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-ollama"></a>

### Why use Ollama / Warum Ollama verwenden? (`aiPolish.whyUse.ollama`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Why use Ollama` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.ollama`](#node-aiPolish-whyUse-ollama) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: which Ollama model should I use for cleanup; why is my Ollama model missing |
| Search (de) | phrases: welches Ollama-Modell eignet sich zur Nachbearbeitung; warum fehlt mein Ollama-Modell |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-openAI"></a>

### Why use OpenAI / Warum OpenAI verwenden? (`aiPolish.whyUse.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.openAI`](#node-aiPolishProvider-openAI) |
| Title source | catalog key `Why use OpenAI` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.openAI`](#node-aiPolish-whyUse-openAI) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: which OpenAI model should I use for dictation cleanup; why are some OpenAI models missing |
| Search (de) | phrases: welches OpenAI-Modell eignet sich für die Diktatkorrektur; warum fehlen manche OpenAI-Modelle |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-gemini"></a>

### Why use Gemini / Warum Gemini verwenden? (`aiPolish.whyUse.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.gemini`](#node-aiPolishProvider-gemini) |
| Title source | catalog key `Why use Gemini` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.gemini`](#node-aiPolish-whyUse-gemini) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: which Gemini model should I use for cleanup; why are some Gemini models locked |
| Search (de) | phrases: welches Gemini-Modell eignet sich zur Nachbearbeitung; warum sind manche Gemini-Modelle gesperrt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-claude"></a>

### Why use Claude / Warum Claude verwenden? (`aiPolish.whyUse.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.claude`](#node-aiPolishProvider-claude) |
| Title source | catalog key `Why use Claude` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.claude`](#node-aiPolish-whyUse-claude) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: which Claude model should I use for cleanup; why are some Claude models missing; what API access do I need for Claude |
| Search (de) | phrases: welches Claude-Modell eignet sich zur Nachbearbeitung; warum fehlen manche Claude-Modelle; welchen API-Zugang brauche ich für Claude |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-aboutAppleIntelligence"></a>

### About Apple Intelligence / Über Apple Intelligence (`aiPolish.link.aboutAppleIntelligence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.whyUse.appleIntelligence`](#node-aiPolish-whyUse-appleIntelligence) |
| Title source | catalog key `About Apple Intelligence` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.appleIntelligence`](#node-aiPolish-whyUse-appleIntelligence) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the information page about Apple Intelligence |
| Search (de) | phrases: öffne die Infoseite zu Apple Intelligence |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-ollamaLibrary"></a>

### Ollama model library / Ollama-Modellbibliothek (`aiPolish.link.ollamaLibrary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.whyUse.ollama`](#node-aiPolish-whyUse-ollama) |
| Title source | catalog key `Ollama model library` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.ollama`](#node-aiPolish-whyUse-ollama) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Ollama model library website |
| Search (de) | phrases: öffne die Webseite mit der Ollama-Modellbibliothek |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-openAIRateLimits"></a>

### OpenAI rate limits by tier / OpenAI-Ratenlimits nach Stufe (`aiPolish.link.openAIRateLimits`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.whyUse.openAI`](#node-aiPolish-whyUse-openAI) |
| Title source | catalog key `OpenAI rate limits by tier` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.openAI`](#node-aiPolish-whyUse-openAI) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show the OpenAI request limits for my usage tier |
| Search (de) | phrases: zeig mir die OpenAI-Anfragelimits für meine Nutzungsstufe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-geminiRateLimits"></a>

### Gemini API rate limits by tier / Ratenlimits der Gemini-API nach Nutzungsstufe (`aiPolish.link.geminiRateLimits`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.whyUse.gemini`](#node-aiPolish-whyUse-gemini) |
| Title source | catalog key `Gemini API rate limits by tier` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.gemini`](#node-aiPolish-whyUse-gemini) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show the Gemini request limits for my usage tier |
| Search (de) | phrases: zeig mir die Gemini-Anfragelimits für meine Nutzungsstufe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-claudeRateLimits"></a>

### Claude API rate limits / Claude-API-Ratenlimits (`aiPolish.link.claudeRateLimits`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.whyUse.claude`](#node-aiPolish-whyUse-claude) |
| Title source | catalog key `Claude API rate limits` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`aiPolish.whyUse.claude`](#node-aiPolish-whyUse-claude) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show the Claude API request limits |
| Search (de) | phrases: zeig mir die Anfragelimits der Claude-API |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-download"></a>

### Download / Laden (`localModel.download`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Download` |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`localModel.download`](#node-localModel-download) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: download EG-1 or S1-mini onto my Mac |
| Search (de) | phrases: lade EG-1 oder S1-mini auf meinen Mac herunter |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-cancel"></a>

### Cancel / Abbrechen (`localModel.cancel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Cancel` |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`localModel.cancel`](#node-localModel-cancel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: cancel the EG-1 or S1-mini download |
| Search (de) | phrases: brich den Download von EG-1 oder S1-mini ab |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-resume"></a>

### Resume / Fortsetzen (`localModel.resume`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Resume` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`localModel.resume`](#node-localModel-resume) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: unpause<br>phrases: continue the paused EG-1 or S1-mini download |
| Search (de) | words: weiterladen<br>phrases: setz den pausierten Download von EG-1 oder S1-mini fort |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-resumeUpgrade"></a>

### Resume upgrade / Upgrade fortsetzen (`localModel.resumeUpgrade`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Resume upgrade` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: resume the EG-1 or S1-mini upgrade that stopped partway |
| Search (de) | phrases: setz das unterbrochene Upgrade von EG-1 oder S1-mini fort |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-finishUpgrade"></a>

### Finish upgrade / Upgrade abschließen (`localModel.finishUpgrade`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Finish upgrade` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: finish installing the new model version so cleanup works again |
| Search (de) | phrases: schließ die Installation der neuen Modellversion ab, damit die Nachbearbeitung wieder funktioniert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-tryAgain"></a>

### Try Again / Erneut versuchen (`localModel.tryAgain`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Try Again` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`localModel.tryAgain`](#node-localModel-tryAgain) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: retry after the EG-1 or S1-mini error |
| Search (de) | phrases: versuch es nach dem Fehler bei EG-1 oder S1-mini nochmal |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-testLive"></a>

### (named at runtime by `localModelTest`) (`localModel.testLive`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | resolver `localModelTest` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`localModel.testLive`](#node-localModel-testLive) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: test<br>phrases: test whether the downloaded cleanup model is working |
| Search (de) | words: Funktionstest, testen<br>phrases: teste, ob das heruntergeladene Nachbearbeitungsmodell funktioniert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone"></a>

### Tone / Ton (`s1Tone`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Tone` |
| Description | Choose how formal your text sounds. / Wähle, wie förmlich dein Text klingt. |
| Description source | catalog key `Choose how formal your text sounds.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: formality, style, register<br>phrases: choose how formal S1-mini makes my text; adjust the writing style in S1-mini |
| Search (de) | words: Formalität, Sprachstil, Schreibstil<br>phrases: stell ein, wie förmlich S1-mini meinen Text schreibt; pass den Schreibstil von S1-mini an |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure"></a>

### Structure / Struktur (`s1Structure`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Structure` |
| Description | Keep sentences or turn spoken items into lists. / Sätze behalten oder gesprochene Punkte in Listen umwandeln. |
| Description source | catalog key `Keep sentences or turn spoken items into lists.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Structure`](#node-s1Structure) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: organization, arrangement<br>phrases: choose whether S1-mini keeps sentences or makes lists; change how S1-mini organizes my dictated text |
| Search (de) | words: Textaufbau, Anordnung<br>phrases: stell ein, ob S1-mini Sätze beibehält oder Listen erstellt; ändere, wie S1-mini meinen diktierten Text aufbaut |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context"></a>

### Context / Kontext (`s1Context`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Context` |
| Description | Format dictated greetings and sign-offs as email. / Diktierte Anreden und Grußformeln als E-Mail formatieren. |
| Description source | catalog key `Format dictated greetings and sign-offs as email.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Context`](#node-s1Context) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose whether S1-mini uses general or email formatting; change the context used to format my S1-mini dictation |
| Search (de) | phrases: stell ein, ob S1-mini normalen Text oder eine E-Mail formatiert; wähle den Kontext für die Formatierung meiner S1-mini-Diktate |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appleIntelligence-status"></a>

### (named at runtime by `appleIntelligenceStatus`) (`appleIntelligence.status`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.appleIntelligence`](#node-aiPolishProvider-appleIntelligence) |
| Title source | resolver `appleIntelligenceStatus` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`appleIntelligence.status`](#node-appleIntelligence-status) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show whether Apple Intelligence is ready on this Mac; show the current availability of Apple's cleanup model |
| Search (de) | phrases: zeig mir, ob Apple Intelligence auf diesem Mac bereit ist; zeig mir die aktuelle Verfügbarkeit von Apples Nachbearbeitungsmodell |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appleIntelligence-recheck"></a>

### Check Apple Intelligence availability / Verfügbarkeit von Apple Intelligence prüfen (`appleIntelligence.recheck`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`appleIntelligence.status`](#node-appleIntelligence-status) |
| Title source | catalog key `Check Apple Intelligence availability` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`appleIntelligence.recheck`](#node-appleIntelligence-recheck) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: check Apple Intelligence availability again |
| Search (de) | phrases: prüf nochmal, ob Apple Intelligence verfügbar ist |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-downloadOllama"></a>

### Download Ollama / Ollama herunterladen (`ollama.downloadOllama`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Download Ollama` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.downloadOllama`](#node-ollama-downloadOllama) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: runtime<br>phrases: install Ollama itself on my Mac |
| Search (de) | words: Laufzeitumgebung<br>phrases: installiere Ollama selbst auf meinem Mac |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-start"></a>

### Start Ollama / Ollama starten (`ollama.start`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Start Ollama` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.start`](#node-ollama-start) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: serve<br>phrases: launch Ollama after installation |
| Search (de) | words: serve<br>phrases: starte Ollama nach der Installation |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-downloadModel"></a>

### (named at runtime by `ollamaModelDownload`) (`ollama.downloadModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | resolver `ollamaModelDownload` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.downloadModel`](#node-ollama-downloadModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: download a model so Ollama can polish text |
| Search (de) | phrases: lade ein Modell herunter, damit Ollama Text nachbearbeiten kann |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-cancelPull"></a>

### Cancel / Abbrechen (`ollama.cancelPull`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Cancel` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.cancelPull`](#node-ollama-cancelPull) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: cancel the model download in Ollama |
| Search (de) | phrases: brich den Modelldownload in Ollama ab |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-server"></a>

### Server / Server (`ollama.server`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Server` |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.server`](#node-ollama-server) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: address, endpoint, connection<br>phrases: show the address of my Ollama server; show the running Ollama server |
| Search (de) | words: Adresse, Serveradresse, Verbindung<br>phrases: zeig mir die Adresse meines Ollama-Servers; zeig mir den laufenden Ollama-Server |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-recheck"></a>

### Re-check Ollama status / Ollama-Status erneut prüfen (`ollama.recheck`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Re-check Ollama status` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.recheck`](#node-ollama-recheck) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: check again whether Ollama is running |
| Search (de) | phrases: prüf nochmal, ob Ollama läuft |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-tryAgain"></a>

### Try Again / Erneut versuchen (`ollama.tryAgain`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Try Again` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.tryAgain`](#node-ollama-tryAgain) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: retry after the Ollama error |
| Search (de) | phrases: versuch es nach dem Ollama-Fehler nochmal |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-browseModels"></a>

### Download more models / Weitere Modelle laden (`ollama.browseModels`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolishProvider.ollama`](#node-aiPolishProvider-ollama) |
| Title source | catalog key `Download more models` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.browseModels`](#node-ollama-browseModels) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: browse more models to download through Ollama |
| Search (de) | phrases: zeig mir weitere Modelle zum Herunterladen über Ollama |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-prepareModel"></a>

### Prepare model / Modell vorbereiten (`ollama.prepareModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`polishModel`](#node-polishModel) |
| Title source | catalog key `Prepare model` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSetupState` |
| Arrival target | [`ollama.prepareModel`](#node-ollama-prepareModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: prepare, initialize<br>phrases: prepare my selected Ollama model for cleanup |
| Search (de) | words: vorbereiten, startklar<br>phrases: mach mein gewähltes Ollama-Modell für die Nachbearbeitung bereit |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-openAI"></a>

### OpenAI API Key / OpenAI-API-Schlüssel (`apiKey.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `OpenAI API Key` |
| Description | Sends text and dictation context to OpenAI. / Sendet Text und Diktatkontext an OpenAI. |
| Description source | catalog key `Sends text and dictation context to OpenAI.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.openAI`](#node-apiKey-openAI) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enter my OpenAI API key for dictation cleanup; change the OpenAI API key used to send dictation text and context |
| Search (de) | phrases: trag meinen OpenAI-API-Schlüssel für die Diktatkorrektur ein; ändere den OpenAI-API-Schlüssel zum Senden von Diktattext und Kontext |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-gemini"></a>

### Google Gemini API Key / Google Gemini-API-Schlüssel (`apiKey.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Google Gemini API Key` |
| Description | Sends text and dictation context to Google. / Sendet Text und Diktatkontext an Google. |
| Description source | catalog key `Sends text and dictation context to Google.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.gemini`](#node-apiKey-gemini) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enter my Google API key for Gemini dictation cleanup; change the Gemini API key used to send dictation text and context |
| Search (de) | phrases: trag meinen Google-API-Schlüssel für die Diktatkorrektur mit Gemini ein; ändere den Gemini-API-Schlüssel zum Senden von Diktattext und Kontext |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-claude"></a>

### Claude API Key / Claude-API-Schlüssel (`apiKey.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Claude API Key` |
| Description | Sends text and dictation context to Anthropic. / Sendet Text und Diktatkontext an Anthropic. |
| Description source | catalog key `Sends text and dictation context to Anthropic.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.claude`](#node-apiKey-claude) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Anthropic, credential, token<br>phrases: enter my Anthropic API key; use my Anthropic key for AI Polish |
| Search (de) | words: Anthropic, Zugangsdaten, Token<br>phrases: meinen API-Schlüssel von Anthropic eintragen; Claude mit meinem Anthropic-Schlüssel nutzen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-save"></a>

### Save / Sichern (`apiKey.save`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Save` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.save`](#node-apiKey-save) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: save the API key I entered |
| Search (de) | phrases: meinen eingegebenen API-Schlüssel speichern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-clear"></a>

### Clear / Löschen (`apiKey.clear`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Clear` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeySaved` |
| Arrival target | [`apiKey.clear`](#node-apiKey-clear) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: remove my saved API key |
| Search (de) | phrases: meinen gespeicherten API-Schlüssel entfernen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-reveal"></a>

### (named at runtime by `apiKeyReveal`) (`apiKey.reveal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | resolver `apiKeyReveal` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyDraftNonempty` |
| Arrival target | [`apiKey.reveal`](#node-apiKey-reveal) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: unmask, conceal<br>phrases: show the hidden API key; hide my API key again |
| Search (de) | phrases: meinen API-Schlüssel sichtbar machen; meinen API-Schlüssel wieder verbergen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-getKeyLink"></a>

### (named at runtime by `apiKeyLink`) (`apiKey.getKeyLink`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | resolver `apiKeyLink` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.getKeyLink`](#node-apiKey-getKeyLink) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: where do I get an API key; open the provider website to get a key |
| Search (de) | phrases: wo bekomme ich einen API-Schlüssel; die Anbieterseite für einen API-Schlüssel öffnen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-polishModel"></a>

### Model / Modell (`polishModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Model` |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`polishModel`](#node-polishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: LLM, Ollama<br>phrases: choose which AI polishes my text; switch the model used for AI Polish |
| Search (de) | words: KI, LLM, Ollama<br>phrases: eine andere KI zum Überarbeiten wählen; ändern, welches Modell meinen Text verbessert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-polishModel-refresh"></a>

### Refresh available models / Verfügbare Modelle aktualisieren (`polishModel.refresh`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`polishModel`](#node-polishModel) |
| Title source | catalog key `Refresh available models` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`polishModel.refresh`](#node-polishModel-refresh) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: reload the list of available polish models; check for newly available polish models |
| Search (de) | phrases: die Liste der verfügbaren Modelle neu laden; noch mal nach Modellen zum Überarbeiten suchen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-enableDictionary"></a>

### Enable Dictionary / Wörterbuch aktivieren (`enableDictionary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Enable Dictionary` |
| Description | Use your words and vocabulary to improve recognition. / Nutze deine Wörter und dein Vokabular für eine bessere Erkennung. |
| Description source | catalog key `Use your words and vocabulary to improve recognition.` |
| Destination | `dictionary` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`enableDictionary`](#node-enableDictionary) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recognition<br>phrases: use my dictionary to improve dictation recognition; stop using my dictionary when I dictate |
| Search (de) | words: Worterkennung, Erkennung<br>phrases: mein Wörterbuch beim Diktieren berücksichtigen; die Wörterbuchhilfe für die Erkennung ausschalten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-yourWords"></a>

### Your Words / Deine Wörter (`dictionary.tab.yourWords`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Your Words` |
| Description | Words you added / Eigene Wörter |
| Description source | catalog key `Words you added` |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: entries, spellings, lexicon<br>phrases: show the words I added myself; where is my personal word list |
| Search (de) | words: Wörterbucheinträge, Schreibweisen<br>phrases: wo sind meine selbst hinzugefügten Wörter; meine persönliche Wortliste ansehen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-vocabularyPacks"></a>

### Vocabulary Packs / Wortschatzpakete (`dictionary.tab.vocabularyPacks`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Vocabulary Packs` |
| Description | Ready-made lists / Fertige Listen |
| Description source | catalog key `Ready-made lists` |
| Destination | `dictionary` |
| Dictionary tab | `vocabularyPacks` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.vocabularyPacks`](#node-dictionary-tab-vocabularyPacks) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enable lists of specialist terms; recognise medical terms; enable lists of brand names |
| Search (de) | phrases: Listen mit Fachbegriffen einschalten; medizinische Begriffe erkennen; Listen mit Markennamen einschalten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-learnFrom"></a>

### Learn from... / Lernen aus... (`dictionary.tab.learnFrom`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Learn from...` |
| Description | Learn as you go / Nebenbei lernen |
| Description source | catalog key `Learn as you go` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: learn new words from my corrections; learn words I correct after dictating; learn names from my contacts |
| Search (de) | phrases: lerne neue Wörter aus meinen Korrekturen; merk dir Wörter, die ich nach dem Diktieren korrigiere; lerne Namen aus meinen Kontakten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-quickAdd"></a>

### Quick Add / Schnell hinzufügen (`dictionary.tab.quickAdd`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Quick Add` |
| Description | Add from any app / Aus jeder App |
| Description source | catalog key `Add from any app` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: guide, instructions<br>phrases: how do I add words from another app; show me how Quick Add works |
| Search (de) | words: Anleitung<br>phrases: wie füge ich Wörter aus anderen Apps hinzu; wie funktioniert Schnell hinzufügen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-add"></a>

### Add word / Wort hinzufügen (`yourWords.add`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `Add word` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.add`](#node-yourWords-add) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: add a word directly to my personal word list |
| Search (de) | phrases: ein Wort direkt in meiner persönlichen Wortliste anlegen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-import"></a>

### Import / Importieren (`yourWords.import`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `Import` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.import`](#node-yourWords-import) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: bring an existing word list into my dictionary |
| Search (de) | phrases: eine vorhandene Wortliste in mein Wörterbuch einlesen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-export"></a>

### Export your words / Deine Wörter exportieren (`yourWords.export`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `Export your words` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.export`](#node-yourWords-export) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: export my personal dictionary entries |
| Search (de) | phrases: meine persönlichen Wörterbucheinträge exportieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-search"></a>

### Search by word, mishearing, or category / Nach Wort, Fehlerkennung oder Kategorie suchen (`yourWords.search`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `Search by word, mishearing, or category` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.search`](#node-yourWords-search) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: find a word in my personal dictionary; search my own entries by mishearing or category |
| Search (de) | words: Wörterbuchsuche<br>phrases: ein Wort in meinem persönlichen Wörterbuch suchen; meine eigenen Einträge nach falscher Erkennung oder Kategorie durchsuchen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-clearSearch"></a>

### Clear search / Suche löschen (`yourWords.clearSearch`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`yourWords.search`](#node-yourWords-search) |
| Title source | catalog key `Clear search` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `searchHasQuery` |
| Arrival target | [`yourWords.clearSearch`](#node-yourWords-clearSearch) |
| Fallbacks, in order | [`yourWords.search`](#node-yourWords-search) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: clear the search field in my personal word list |
| Search (de) | phrases: das Suchfeld bei meinen eigenen Wörtern leeren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-categoryFilter"></a>

### All categories / Alle Kategorien (`yourWords.categoryFilter`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `All categories` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: filter, groups, types<br>phrases: filter my own words by category; show only one type of dictionary entry |
| Search (de) | words: Kategoriefilter, Wortgruppen, Eintragstypen<br>phrases: meine eigenen Wörter nach Kategorie filtern; nur eine bestimmte Art von Wörterbucheinträgen anzeigen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-massEdit"></a>

### Mass edit / Mehrere auswählen (`yourWords.massEdit`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Title source | catalog key `Mass edit` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `wordsListed` |
| Arrival target | [`yourWords.massEdit`](#node-yourWords-massEdit) |
| Fallbacks, in order | [`yourWords.search`](#node-yourWords-search) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: bulk, batch, multiselect<br>phrases: select several dictionary entries at once |
| Search (de) | words: Mehrfachauswahl, Sammelauswahl<br>phrases: mehrere Wörterbucheinträge auf einmal auswählen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-learnFrom"></a>

### Learn from... / Lernen aus... (`learnFrom`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Learn from...` |
| Description | Let EnviousWispr pick up new words on its own, from things you already have. / Lass EnviousWispr neue Wörter aus deinen vorhandenen Inhalten selbst lernen. |
| Description source | catalog key `Let EnviousWispr pick up new words on its own, from things you already have.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`learnFrom`](#node-learnFrom) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: sources, discovery<br>phrases: find ways for the app to learn new words; let the app pick up vocabulary from things I already have |
| Search (de) | words: Lernquellen, Wortquellen<br>phrases: welche Quellen kann die App zum Wörterlernen nutzen; neue Wörter aus vorhandenen Quellen übernehmen lassen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-selfLearningDictionary"></a>

### Self-Learning Dictionary / Selbstlernendes Wörterbuch (`selfLearningDictionary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Self-Learning Dictionary` |
| Description | Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words. / Erkennt automatisch, wenn du ein Diktat korrigierst, und fügt das korrigierte Wort deinem Wörterbuch hinzu. Du kannst das über die Mitteilung rückgängig machen oder das Wort später unter „Deine Wörter“ entfernen. |
| Description source | catalog key `Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: selflearning<br>phrases: remember words when I correct a dictation; automatically add corrected words to my dictionary; stop learning from my dictation corrections |
| Search (de) | words: Korrekturlernen, Korrekturerkennung<br>phrases: Wörter merken, wenn ich ein Diktat korrigiere; korrigierte Wörter automatisch ins Wörterbuch aufnehmen; nicht mehr aus meinen Diktatkorrekturen lernen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-selfLearningDictionary-learnMore"></a>

### Learn more / Mehr erfahren (`selfLearningDictionary.learnMore`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Title source | catalog key `Learn more` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`selfLearningDictionary.learnMore`](#node-selfLearningDictionary-learnMore) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: read how learning from dictation corrections works |
| Search (de) | phrases: nachlesen, wie das Lernen aus Diktatkorrekturen funktioniert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-importContacts"></a>

### Import from Contacts / Aus Kontakten importieren (`importContacts`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Import from Contacts` |
| Description | Add the names of people you know to your word list, so dictation spells them right. / Füge Namen von Personen zu deiner Wortliste hinzu, damit sie beim Diktieren richtig geschrieben werden. |
| Description source | catalog key `Add the names of people you know to your word list, so dictation spells them right.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`importContacts`](#node-importContacts) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: addressbook<br>phrases: teach dictation the names in my address book; use names from my contacts to improve spelling |
| Search (de) | words: Adressbuch<br>phrases: die Namen aus meinem Adressbuch fürs Diktieren nutzen; Namen aus meinen Kontakten richtig erkennen lassen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-contactsSyncOnLaunch"></a>

### Keep in sync on launch / Beim Start synchron halten (`contactsSyncOnLaunch`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`importContacts`](#node-importContacts) |
| Title source | catalog key `Keep in sync on launch` |
| Description | Check for new contacts each time EnviousWispr starts. Off by default. / Bei jedem Start von EnviousWispr nach neuen Kontakten suchen. Standardmäßig deaktiviert. |
| Description source | catalog key `Check for new contacts each time EnviousWispr starts. Off by default.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`contactsSyncOnLaunch`](#node-contactsSyncOnLaunch) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: sync, synchronization<br>phrases: check for new contact names when the app starts; keep my contact vocabulary updated on launch |
| Search (de) | words: Kontaktabgleich, Synchronisierung<br>phrases: bei jedem Appstart nach neuen Kontaktnamen suchen; meine Kontaktwörter beim Start aktuell halten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step1"></a>

### Highlight a word / Wort markieren (`quickAdd.step1`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Highlight a word` |
| Description | Select the word you want to fix in an email, chat, or document. / Markiere das Wort, das du in einer E-Mail, einem Chat oder Dokument korrigieren möchtest. |
| Description source | catalog key `Select the word you want to fix in an email, chat, or document.` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.step1`](#node-quickAdd-step1) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: highlight, highlighting<br>phrases: highlight the word I want to fix in another app; select a word before using Quick Add |
| Search (de) | words: Textauswahl, Textmarkierung<br>phrases: das Wort zum Korrigieren in einer anderen App markieren; vor Schnell hinzufügen ein Wort auswählen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step2"></a>

### Trigger Quick Add / „Schnell hinzufügen“ aufrufen (`quickAdd.step2`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Trigger Quick Add` |
| Description | composed at display time from live state (not exported) |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.step2`](#node-quickAdd-step2) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: start Quick Add after selecting a word; open Quick Add for the highlighted word |
| Search (de) | phrases: Schnell hinzufügen für das markierte Wort aufrufen; nach dem Markieren die Wortübernahme starten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step3"></a>

### Choose and save / Auswählen und sichern (`quickAdd.step3`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Choose and save` |
| Description | Choose the word you meant, or create a new one. Quick Add saves the highlighted spelling to your dictionary. / Wähle das gemeinte Wort oder erstelle ein neues. „Schnell hinzufügen“ speichert die markierte Schreibweise in deinem Wörterbuch. |
| Description source | catalog key `Choose the word you meant, or create a new one. Quick Add saves the highlighted spelling to your dictionary.` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.step3`](#node-quickAdd-step3) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose the intended word in Quick Add; save the highlighted spelling with the right dictionary word |
| Search (de) | phrases: bei Schnell hinzufügen das gemeinte Wort auswählen; die markierte Schreibweise beim richtigen Wörterbucheintrag speichern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-shortcut"></a>

### Keyboard shortcut / Tastenkürzel (`quickAdd.shortcut`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Keyboard shortcut` |
| Description | composed at display time from live state (not exported) |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.shortcut`](#node-quickAdd-shortcut) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: hotkey, keybind<br>phrases: which keys open Quick Add; where can I change the Quick Add shortcut |
| Search (de) | words: Hotkey, Tastenkombination<br>phrases: welche Tasten öffnen Schnell hinzufügen; wo kann ich das Tastenkürzel für Schnell hinzufügen ändern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-menuBar"></a>

### Menu bar / Menüleiste (`quickAdd.menuBar`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Menu bar` |
| Description | Click the EnviousWispr icon, then choose the item that starts with “Add” / Klicke auf das EnviousWispr-Symbol und wähle dann den Eintrag, der mit „hinzufügen“ endet |
| Description source | catalog key `Click the EnviousWispr icon, then choose the item that starts with “Add”` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.menuBar`](#node-quickAdd-menuBar) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: add a selected word through the EnviousWispr menu; find the Add item under the EnviousWispr icon |
| Search (de) | phrases: ein markiertes Wort über das EnviousWispr-Menü hinzufügen; den Eintrag zum Hinzufügen unter dem EnviousWispr-Symbol finden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets"></a>

### Paste the text you type over and over, by voice / Füge Text, den du oft tippst, per Stimme ein (`snippets`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`page.snippets`](#node-page-snippets) |
| Title source | catalog key `Paste the text you type over and over, by voice` |
| Description | Save an email address, a signature, a link. Say your keyword, then the trigger, and the saved text lands where your cursor is. Say the trigger on its own and your dictation is left alone. / Speichere eine E-Mail-Adresse, eine Signatur oder einen Link. Sprich dein Schlüsselwort und danach den Auslöser, und der gespeicherte Text erscheint an der Cursorposition. Sprichst du nur den Auslöser, bleibt dein Diktat unverändert. |
| Description source | catalog key `Save an email address, a signature, a link. Say your keyword, then the trigger, and the saved text lands where your cursor is. Say the trigger on its own and your dictation is left alone.` |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippets`](#node-snippets) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: expander, expansion<br>phrases: insert saved text by voice; say a command instead of typing repeated text; paste a saved signature with my voice |
| Search (de) | words: Texterweiterung, Textersetzung<br>phrases: gespeicherten Text per Stimme einfügen; wiederkehrenden Text mit einem Sprachbefehl einsetzen; eine gespeicherte Signatur per Stimme einfügen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippetKeyword"></a>

### Keyword / Schlüsselwort (`snippetKeyword`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.snippets`](#node-page-snippets) |
| Title source | catalog key `Keyword` |
| Description | Say this first, then your trigger. One word. / Sag zuerst dieses Wort, dann deinen Auslöser. Ein Wort. |
| Description source | catalog key `Say this first, then your trigger. One word.` |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippetKeyword`](#node-snippetKeyword) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: prefix, opener<br>phrases: change the word I say before a snippet trigger; choose the opening word for snippet commands |
| Search (de) | words: Startwort, Einleitungswort<br>phrases: das Wort vor dem Textbausteinauslöser ändern; festlegen, mit welchem Wort meine Textbausteinbefehle anfangen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourSnippets"></a>

### Your snippets / Deine Textbausteine (`yourSnippets`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`page.snippets`](#node-page-snippets) |
| Title source | catalog key `Your snippets` |
| Description | composed at display time from live state (not exported) |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`yourSnippets`](#node-yourSnippets) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show my saved snippet collection; where are the reusable texts I already saved |
| Search (de) | words: Bausteinsammlung<br>phrases: meine gespeicherte Textbausteinsammlung ansehen; wo sind die Texte, die ich schon als Bausteine gespeichert habe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-search"></a>

### Search snippets / Textbausteine durchsuchen (`snippets.search`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`yourSnippets`](#node-yourSnippets) |
| Title source | catalog key `Search snippets` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `snippetsListed` |
| Arrival target | [`snippets.search`](#node-snippets-search) |
| Fallbacks, in order | [`yourSnippets`](#node-yourSnippets) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: find a snippet in my saved collection; search my existing text snippets |
| Search (de) | words: Bausteinsuche<br>phrases: einen Textbaustein in meiner Sammlung finden; meine vorhandenen Textbausteine durchsuchen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-import"></a>

### Import / Importieren (`snippets.import`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`yourSnippets`](#node-yourSnippets) |
| Title source | catalog key `Import` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippets.import`](#node-snippets-import) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: import an existing collection of text snippets |
| Search (de) | phrases: eine vorhandene Textbausteinsammlung einlesen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-export"></a>

### Export / Exportieren (`snippets.export`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`yourSnippets`](#node-yourSnippets) |
| Title source | catalog key `Export` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippets.export`](#node-snippets-export) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: export my saved text snippet collection |
| Search (de) | phrases: meine gespeicherte Textbausteinsammlung exportieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-add"></a>

### Add snippet / Textbaustein hinzufügen (`snippets.add`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`yourSnippets`](#node-yourSnippets) |
| Title source | catalog key `Add snippet` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippets.add`](#node-snippets-add) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: add another snippet to my existing collection |
| Search (de) | phrases: meiner vorhandenen Sammlung einen weiteren Textbaustein hinzufügen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-addFirst"></a>

### Add your first snippet / Ersten Textbaustein hinzufügen (`snippets.addFirst`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`yourSnippets`](#node-yourSnippets) |
| Title source | catalog key `Add your first snippet` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `snippetsEmpty` |
| Arrival target | [`snippets.addFirst`](#node-snippets-addFirst) |
| Fallbacks, in order | [`snippets.add`](#node-snippets-add) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: create my first snippet while the list is empty |
| Search (de) | phrases: meinen ersten Textbaustein in der noch leeren Liste anlegen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-clearSearch"></a>

### Clear search / Suche löschen (`snippets.clearSearch`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`snippets.search`](#node-snippets-search) |
| Title source | catalog key `Clear search` |
| Description | none |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `searchHasQuery` |
| Arrival target | [`snippets.clearSearch`](#node-snippets-clearSearch) |
| Fallbacks, in order | [`snippets.search`](#node-snippets-search), [`yourSnippets`](#node-yourSnippets) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: clear the search field in my snippet list |
| Search (de) | phrases: das Suchfeld in meiner Textbausteinliste leeren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-appearance"></a>

### Appearance / Erscheinungsbild (`appSettings.tab.appearance`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.appSettings`](#node-page-appSettings) |
| Title source | catalog key `Appearance` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appSettings.tab.appearance`](#node-appSettings-tab-appearance) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Appearance tab in App Settings; where is the Appearance section of App Settings |
| Search (de) | phrases: den Bereich Erscheinungsbild in den App-Einstellungen öffnen; wo ist der Reiter Erscheinungsbild |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-permissions"></a>

### Permissions / Berechtigungen (`appSettings.tab.permissions`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.appSettings`](#node-page-appSettings) |
| Title source | catalog key `Permissions` |
| Description | none |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appSettings.tab.permissions`](#node-appSettings-tab-permissions) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: authorizations, privileges<br>phrases: see all the Mac permissions the app needs; open the app permissions overview |
| Search (de) | words: Zugriffsrechte, Freigaben, Appzugriffe<br>phrases: alle benötigten Mac-Berechtigungen ansehen; die Übersicht der App-Berechtigungen öffnen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-privacy"></a>

### Privacy / Datenschutz (`appSettings.tab.privacy`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.appSettings`](#node-page-appSettings) |
| Title source | catalog key `Privacy` |
| Description | none |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appSettings.tab.privacy`](#node-appSettings-tab-privacy) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Privacy tab in App Settings; where are the app's data-sharing settings |
| Search (de) | words: Privatsphäre<br>phrases: den Datenschutzbereich der App-Einstellungen öffnen; wo sind die Einstellungen zur Datenweitergabe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-licenses"></a>

### Licenses / Lizenzen (`appSettings.tab.licenses`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.appSettings`](#node-page-appSettings) |
| Title source | catalog key `Licenses` |
| Description | none |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appSettings.tab.licenses`](#node-appSettings-tab-licenses) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: copyright<br>phrases: show the overview of app and third-party licenses; where are all the software licensing documents |
| Search (de) | words: Urheberrecht, Lizenzübersicht<br>phrases: die Übersicht der App- und Drittanbieterlizenzen öffnen; wo finde ich alle Lizenzdokumente |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme"></a>

### Theme / Design (`theme`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Theme` |
| Description | Choose how EnviousWispr looks. / Lege fest, wie EnviousWispr aussieht. |
| Description source | catalog key `Choose how EnviousWispr looks.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`theme`](#node-theme) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: colors, colours, palette<br>phrases: change the app's color scheme; choose the app's appearance mode |
| Search (de) | words: Farbschema, Farben, Farbmodus<br>phrases: das Farbschema der App ändern; den Darstellungsmodus der App auswählen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage"></a>

### Language / Sprache (`appLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Language` |
| Description | The language of the app interface. / Die Sprache der App-Oberfläche. |
| Description source | catalog key `The language of the app interface.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appLanguage`](#node-appLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: locale, localization, translation<br>phrases: change the language of the app menus; change the language used in Settings |
| Search (de) | words: Oberflächensprache, Menüsprache, Übersetzung<br>phrases: die Sprache der Appmenüs ändern; die Sprache der Einstellungen ändern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage-systemDefault"></a>

### System default / Systemstandard (`appLanguage.systemDefault`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`appLanguage`](#node-appLanguage) |
| Title source | catalog key `System default` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appLanguage`](#node-appLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use the same app language as my Mac; let my Mac choose the interface language |
| Search (de) | phrases: die Appsprache vom Mac übernehmen; die App in derselben Sprache wie meinen Mac anzeigen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage-shipped"></a>

### (named at runtime by `appLanguageName`) (`appLanguage.shipped`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`appLanguage`](#node-appLanguage) |
| Title source | resolver `appLanguageName` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appLanguage`](#node-appLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: English, German, Deutsch<br>phrases: show the app menus in English; show the app menus in German |
| Search (de) | words: Deutsch, Englisch, English<br>phrases: die Appmenüs auf Deutsch anzeigen; die Appmenüs auf Englisch anzeigen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage-relaunch"></a>

### Relaunch to apply / Zum Übernehmen neu starten (`appLanguage.relaunch`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`appLanguage`](#node-appLanguage) |
| Title source | catalog key `Relaunch to apply` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `relaunchNeeded` |
| Arrival target | [`appLanguage.relaunch`](#node-appLanguage-relaunch) |
| Fallbacks, in order | [`appLanguage`](#node-appLanguage) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: restart the app to apply the new menu language |
| Search (de) | phrases: die App neu starten, um die neue Menüsprache zu übernehmen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-showInDock"></a>

### Show app in Dock / App im Dock anzeigen (`showInDock`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Show app in Dock` |
| Description | Keep EnviousWispr in your Dock. / EnviousWispr im Dock behalten. |
| Description source | catalog key `Keep EnviousWispr in your Dock.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`showInDock`](#node-showInDock) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the EnviousWispr icon in my Dock; hide EnviousWispr from the Dock |
| Search (de) | phrases: das EnviousWispr-Symbol im Dock behalten; EnviousWispr aus dem Dock ausblenden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-updateAlertInMenuBar"></a>

### Update alert in menu bar / Update-Hinweis in der Menüleiste (`updateAlertInMenuBar`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Update alert in menu bar` |
| Description | Show gold lips when an update is ready. / Goldene Lippen anzeigen, wenn ein Update bereitsteht. |
| Description source | catalog key `Show gold lips when an update is ready.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`updateAlertInMenuBar`](#node-updateAlertInMenuBar) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: gold, golden, lips, badge<br>phrases: show gold lips when an update is ready; hide the update indicator in the menu bar |
| Search (de) | words: gold, golden, Lippen, Updatesymbol<br>phrases: goldene Lippen anzeigen, wenn ein Update bereitsteht; den Update-Hinweis in der Menüleiste ausblenden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-microphone"></a>

### Microphone / Mikrofon (`permission.microphone`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.permissions`](#node-section-permissions) |
| Title source | catalog key `Microphone` |
| Description | Needed to record your voice. / Nötig, um deine Stimme aufzunehmen. |
| Description source | catalog key `Needed to record your voice.` |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`permission.microphone`](#node-permission-microphone) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: mic, recording, audio<br>phrases: check whether the app can record my voice; why is microphone access denied |
| Search (de) | words: Mikro, Aufnahme, Sprachaufnahme<br>phrases: prüfen, ob die App meine Stimme aufnehmen darf; warum ist der Mikrofonzugriff gesperrt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-microphone-request"></a>

### Request Access / Zugriff anfordern (`permission.microphone.request`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`permission.microphone`](#node-permission-microphone) |
| Title source | catalog key `Request Access` |
| Description | none |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `permissionState` |
| Arrival target | [`permission.microphone`](#node-permission-microphone) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: request permission to use the microphone |
| Search (de) | phrases: die Erlaubnis für den Mikrofonzugriff anfordern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-accessibility"></a>

### Accessibility / Bedienungshilfen (`permission.accessibility`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.permissions`](#node-section-permissions) |
| Title source | catalog key `Accessibility` |
| Description | Needed to paste text into other apps. / Nötig, um Text in andere Apps einzufügen. |
| Description source | catalog key `Needed to paste text into other apps.` |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`permission.accessibility`](#node-permission-accessibility) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: paste, pasting, insertion<br>phrases: check the permission needed to paste dictation into other apps; why does text insertion need Accessibility access |
| Search (de) | words: Einfügeberechtigung, Einfügen, Texteingabe<br>phrases: die Berechtigung zum Einfügen von Diktaten prüfen; warum braucht die Texteingabe Zugriff auf Bedienungshilfen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-accessibility-openSettings"></a>

### Open System Settings / Systemeinstellungen öffnen (`permission.accessibility.openSettings`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`permission.accessibility`](#node-permission-accessibility) |
| Title source | catalog key `Open System Settings` |
| Description | none |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `permissionState` |
| Arrival target | [`permission.accessibility`](#node-permission-accessibility) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open Mac settings to grant Accessibility permission; open Mac settings to grant Accessibility access again after rebuilding |
| Search (de) | phrases: die Mac-Einstellungen für den Zugriff auf Bedienungshilfen öffnen; nach einem neuen App-Build die Bedienungshilfen erneut freigeben |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-shareUsageMetrics"></a>

### Share usage metrics / Nutzungsstatistiken teilen (`shareUsageMetrics`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `Share usage metrics` |
| Description | Help us catch broken updates. / Hilf uns, fehlerhafte Updates zu erkennen. |
| Description source | catalog key `Help us catch broken updates.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`shareUsageMetrics`](#node-shareUsageMetrics) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: analytics, statistics<br>phrases: share usage data to help spot broken updates; turn off usage analytics |
| Search (de) | words: Nutzungsdaten, Nutzungsanalyse<br>phrases: Nutzungsdaten teilen, um fehlerhafte Updates zu erkennen; die Nutzungsanalyse ausschalten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-sendCrashReports"></a>

### Send crash reports / Absturzberichte senden (`sendCrashReports`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `Send crash reports` |
| Description | Help us fix crashes and errors. / Hilf uns, Abstürze und Fehler zu beheben. |
| Description source | catalog key `Help us fix crashes and errors.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`sendCrashReports`](#node-sendCrashReports) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: crashes, errors, diagnostics<br>phrases: send information about app crashes and errors; stop sending crash reports |
| Search (de) | words: Abstürze, Fehler, Fehlerdiagnose<br>phrases: Informationen zu Abstürzen und Fehlern senden; keine Absturzberichte mehr senden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-sendCrashReports-restart"></a>

### Restart now / Jetzt neu starten (`sendCrashReports.restart`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`sendCrashReports`](#node-sendCrashReports) |
| Title source | catalog key `Restart now` |
| Description | none |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `crashReportsChanged` |
| Arrival target | [`sendCrashReports.restart`](#node-sendCrashReports-restart) |
| Fallbacks, in order | [`sendCrashReports`](#node-sendCrashReports) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: restart the app to apply my crash-reporting setting |
| Search (de) | phrases: die App neu starten, um meine Einstellung für Absturzberichte zu übernehmen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whatWeCollect"></a>

### What we collect / Was wir erfassen (`whatWeCollect`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `What we collect` |
| Description | Never your audio, text, history, snippets, dictionary or API keys. Only what you type into the feedback form. / Niemals deine Audiodaten, Texte, deinen Verlauf, deine Textbausteine, dein Wörterbuch oder API-Schlüssel. Nur was du in das Feedback-Formular eingibst. |
| Description source | catalog key `Never your audio, text, history, snippets, dictionary or API keys. Only what you type into the feedback form.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`whatWeCollect`](#node-whatWeCollect) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: collection, feedback<br>phrases: what information does the app collect; are my recordings or dictations collected; does the app collect my dictionary or API keys |
| Search (de) | words: Datenerfassung, Feedbackdaten<br>phrases: welche Daten erfasst die App; werden meine Aufnahmen oder Diktate gesammelt; werden mein Wörterbuch oder meine API-Schlüssel erfasst |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whatWeCollect-seeDetails"></a>

### See details / Details ansehen (`whatWeCollect.seeDetails`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`whatWeCollect`](#node-whatWeCollect) |
| Title source | catalog key `See details` |
| Description | none |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`whatWeCollect.seeDetails`](#node-whatWeCollect-seeDetails) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the detailed explanation of what data is collected |
| Search (de) | phrases: die ausführliche Erklärung zur Datenerfassung öffnen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-gpl"></a>

### EnviousWispr · GPLv3 / EnviousWispr · GPLv3 (`license.gpl`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.about`](#node-section-about) |
| Title source | catalog key `EnviousWispr · GPLv3` |
| Description | Open source under the GNU GPL version 3. / Open Source unter der GNU GPL Version 3. |
| Description source | catalog key `Open source under the GNU GPL version 3.` |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.gpl`](#node-license-gpl) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: opensource, copyleft, GNU, GPL<br>phrases: is EnviousWispr open source; which open-source license covers EnviousWispr |
| Search (de) | words: quelloffen, Copyleft, GNU, GPL<br>phrases: ist EnviousWispr Open Source; unter welcher freien Lizenz steht EnviousWispr |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-gpl-view"></a>

### View license / Lizenz ansehen (`license.gpl.view`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`license.gpl`](#node-license-gpl) |
| Title source | catalog key `View license` |
| Description | none |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.gpl.view`](#node-license-gpl-view) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the full GPLv3 license text |
| Search (de) | phrases: den vollständigen GPLv3-Lizenztext öffnen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-notices"></a>

### Third-Party Notices / Hinweise zu Drittanbietern (`license.notices`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.about`](#node-section-about) |
| Title source | catalog key `Third-Party Notices` |
| Description | Licenses for the tools EnviousWispr uses. / Lizenzen der Werkzeuge, die EnviousWispr nutzt. |
| Description source | catalog key `Licenses for the tools EnviousWispr uses.` |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.notices`](#node-license-notices) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dependencies, libraries, components<br>phrases: which licenses cover the tools used by EnviousWispr; find licensing information for the app's dependencies |
| Search (de) | words: Bibliothekslizenzen, Komponentenlizenzen, Fremdsoftware<br>phrases: welche Lizenzen gelten für die verwendeten Werkzeuge; Lizenzinformationen zu den eingebauten Bibliotheken finden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-notices-view"></a>

### View notices / Hinweise ansehen (`license.notices.view`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`license.notices`](#node-license-notices) |
| Title source | catalog key `View notices` |
| Description | none |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.notices.view`](#node-license-notices-view) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the third-party licensing notices |
| Search (de) | phrases: die Lizenzhinweise zu Drittanbietern öffnen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-fast"></a>

### Fast / Schnell (`transcriptionEngine.fast`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Fast` |
| Description | Pick this for everyday English and European dictation. / Wähle dies für alltägliche Diktate auf Englisch und in europäischen Sprachen. |
| Description source | catalog key `Pick this for everyday English and European dictation.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Parakeet, European, ANE<br>phrases: use Parakeet for dictation; choose the dictation model that uses the Apple Neural Engine |
| Search (de) | words: Parakeet, europäisch, ANE<br>phrases: nimm Parakeet fürs Diktieren; wähle das Diktiermodell für europäische Sprachen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-allLanguages"></a>

### All Languages / Alle Sprachen (`transcriptionEngine.allLanguages`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `All Languages` |
| Description | Pick this for other languages or the toughest audio. / Wähle dies für andere Sprachen oder besonders schwierige Aufnahmen. |
| Description source | catalog key `Pick this for other languages or the toughest audio.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Whisper, Turbo, GPU, WhisperKit<br>phrases: use Whisper for dictation; choose the dictation model for difficult audio; I need to dictate in a language outside Europe |
| Search (de) | words: Whisper, Turbo, GPU, WhisperKit<br>phrases: nimm Whisper fürs Diktieren; wähle das Diktiermodell für schwierige Aufnahmen; ich möchte in einer außereuropäischen Sprache diktieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage-en"></a>

### (named at runtime by `startWordLanguage`) (`startWordLanguage.en`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`startWordLanguage`](#node-startWordLanguage) |
| Title source | resolver `startWordLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select English for the punctuation start word; show the English punctuation trigger |
| Search (de) | phrases: wähle Englisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für englische Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage-de"></a>

### (named at runtime by `startWordLanguage`) (`startWordLanguage.de`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`startWordLanguage`](#node-startWordLanguage) |
| Title source | resolver `startWordLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select German for the punctuation start word; show the German punctuation trigger |
| Search (de) | phrases: wähle Deutsch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für deutsche Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage-fr"></a>

### (named at runtime by `startWordLanguage`) (`startWordLanguage.fr`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`startWordLanguage`](#node-startWordLanguage) |
| Title source | resolver `startWordLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select French for the punctuation start word; show the French punctuation trigger |
| Search (de) | phrases: wähle Französisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für französische Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage-es"></a>

### (named at runtime by `startWordLanguage`) (`startWordLanguage.es`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`startWordLanguage`](#node-startWordLanguage) |
| Title source | resolver `startWordLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select Spanish for the punctuation start word; show the Spanish punctuation trigger |
| Search (de) | phrases: wähle Spanisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für spanische Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage-it"></a>

### (named at runtime by `startWordLanguage`) (`startWordLanguage.it`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`startWordLanguage`](#node-startWordLanguage) |
| Title source | resolver `startWordLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | composed at display time from live state (not exported) |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`startWordLanguage`](#node-startWordLanguage) |
| Fallbacks, in order | [`spokenPunctuation`](#node-spokenPunctuation) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select Italian for the punctuation start word; show the Italian punctuation trigger |
| Search (de) | phrases: wähle Italienisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für italienische Satzzeichen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-never"></a>

### Never / Nie (`unloadModel.never`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `Never` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the dictation model loaded all the time; never unload the speech model |
| Search (de) | phrases: lass das Diktiermodell dauerhaft geladen; entferne das Diktiermodell nie aus dem Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-immediately"></a>

### Immediately / Sofort (`unloadModel.immediately`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `Immediately` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: unload the model after every transcription; free model memory as soon as the dictation is finished |
| Search (de) | phrases: entlade das Modell nach jedem Diktat; gib den Modellspeicher frei, sobald der Text fertig ist |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-twoMinutes"></a>

### After 2 minutes / Nach 2 Minuten (`unloadModel.twoMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `After 2 minutes` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: unload the dictation model after two idle minutes; keep the speech model loaded for 2 minutes |
| Search (de) | phrases: entlade das Diktiermodell nach zwei Minuten ohne Diktat; lass das Diktiermodell 2 Minuten im Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-fiveMinutes"></a>

### After 5 minutes / Nach 5 Minuten (`unloadModel.fiveMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `After 5 minutes` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: unload the dictation model after five idle minutes; keep the speech model loaded for 5 minutes |
| Search (de) | phrases: entlade das Diktiermodell nach fünf Minuten ohne Diktat; lass das Diktiermodell 5 Minuten im Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-tenMinutes"></a>

### After 10 minutes / Nach 10 Minuten (`unloadModel.tenMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `After 10 minutes` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: unload the dictation model after ten idle minutes; keep the speech model loaded for 10 minutes |
| Search (de) | phrases: entlade das Diktiermodell nach zehn Minuten ohne Diktat; lass das Diktiermodell 10 Minuten im Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-fifteenMinutes"></a>

### After 15 minutes / Nach 15 Minuten (`unloadModel.fifteenMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `After 15 minutes` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: quarter-hour<br>phrases: unload the dictation model after a quarter of an hour; keep the speech model loaded for 15 idle minutes |
| Search (de) | words: Viertelstunde<br>phrases: entlade das Diktiermodell nach einer Viertelstunde ohne Diktat; lass das Diktiermodell 15 Minuten im Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-oneHour"></a>

### After 1 hour / Nach 1 Stunde (`unloadModel.oneHour`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadModel`](#node-unloadModel) |
| Title source | catalog key `After 1 hour` |
| Description | none |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: hour<br>phrases: unload the dictation model after an hour without dictation; keep the speech model loaded for 60 idle minutes |
| Search (de) | words: Stunde<br>phrases: entlade das Diktiermodell nach einer Stunde ohne Diktat; lass das Diktiermodell 60 Minuten im Speicher |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-continue"></a>

### Continue / Weiterlaufen lassen (`mediaDuringDictation.continue`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Title source | catalog key `otherAudio.option.continue` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: uninterrupted, unchanged<br>phrases: keep my music playing at its normal volume while I dictate; leave background audio unchanged during recording |
| Search (de) | words: unverändert, weiterlaufen<br>phrases: lass meine Musik beim Diktieren mit normaler Lautstärke weiterlaufen; lass den Hintergrundton während der Aufnahme unverändert |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-lower"></a>

### Lower / Leiser (`mediaDuringDictation.lower`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Title source | catalog key `Lower` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: ducking, quieter, quieten, halve<br>phrases: turn playback volume down while I dictate; lower my speaker volume during recording and restore it afterward |
| Search (de) | words: absenken, runterdrehen, halbieren, Ducking<br>phrases: dreh die Wiedergabe beim Diktieren leiser; senke die Lautsprecherlautstärke während der Aufnahme ab und stell sie danach wieder her |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-mute"></a>

### Mute / Stummschalten (`mediaDuringDictation.mute`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Title source | catalog key `Mute` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: silent, silence, speakers, headphones<br>phrases: mute my speakers while I dictate; turn off headphone sound during recording; silence call audio while I am dictating |
| Search (de) | words: stumm, lautlos, Lautsprecher, Kopfhörer<br>phrases: schalte meine Lautsprecher beim Diktieren stumm; mach den Kopfhörerton während der Aufnahme aus; schalte den Ton von Anrufen beim Diktieren stumm |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-pause"></a>

### Pause / Pausieren (`mediaDuringDictation.pause`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Title source | catalog key `Pause` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: suspend, pausing<br>phrases: pause my podcast while I dictate and resume it afterward; pause the video until I finish recording; stop music playback temporarily during dictation |
| Search (de) | words: anhalten, unterbrechen<br>phrases: halte meinen Podcast beim Diktieren an und spiel danach weiter; pausiere das Video, bis die Aufnahme fertig ist; unterbrich die Musikwiedergabe während des Diktierens |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-off"></a>

### Off / Aus (`micReadiness.off`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`micReadiness`](#node-micReadiness) |
| Title source | catalog key `Off` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: disable microphone standby after recording; release the microphone as soon as recording ends |
| Search (de) | phrases: schalte die Mikrofonbereitschaft nach der Aufnahme aus; gib das Mikrofon direkt nach der Aufnahme frei |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-10s"></a>

### 10 sec / 10 Sek. (`micReadiness.10s`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`micReadiness`](#node-micReadiness) |
| Title source | catalog key `10 sec` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the microphone ready for ten seconds after recording; set microphone standby to 10 seconds |
| Search (de) | phrases: halte das Mikrofon nach der Aufnahme zehn Sekunden bereit; stelle die Mikrofonbereitschaft auf 10 Sekunden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-30s"></a>

### 30 sec / 30 Sek. (`micReadiness.30s`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`micReadiness`](#node-micReadiness) |
| Title source | catalog key `30 sec` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the microphone ready for half a minute after recording; set microphone standby to 30 seconds |
| Search (de) | phrases: halte das Mikrofon nach der Aufnahme eine halbe Minute bereit; stelle die Mikrofonbereitschaft auf 30 Sekunden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-60s"></a>

### 60 sec / 60 Sek. (`micReadiness.60s`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`micReadiness`](#node-micReadiness) |
| Title source | catalog key `60 sec` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the microphone ready for a minute after recording; set microphone standby to 60 seconds |
| Search (de) | phrases: halte das Mikrofon nach der Aufnahme eine Minute bereit; stelle die Mikrofonbereitschaft auf 60 Sekunden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-always"></a>

### Always / Immer (`micReadiness.always`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`micReadiness`](#node-micReadiness) |
| Title source | catalog key `Always` |
| Description | none |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the microphone engine active all the time; keep the microphone permanently ready between recordings; why might the microphone indicator stay visible with Always selected |
| Search (de) | phrases: halte das Mikrofon dauerhaft bereit; lass die Mikrofonengine zwischen allen Aufnahmen aktiv; warum kann bei Immer die Mikrofonanzeige anbleiben |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-apple"></a>

### Apple (`previewEngine.apple`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | product name |
| Description | Uses Apple's speech recognition. No separate preview-model download; some languages may need an Apple language download. Needs macOS 26. / Verwendet Apples Spracherkennung. Für die Vorschau ist kein eigenes Modell nötig. Manche Sprachen müssen möglicherweise von Apple heruntergeladen werden. Benötigt macOS 26. |
| Description source | catalog key `Uses Apple's speech recognition. No separate preview-model download; some languages may need an Apple language download. Needs macOS 26.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewChoicesExpanded` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple's speech recognition for live preview; choose the preview engine that needs macOS 26; use the preview engine without a separate preview model download |
| Search (de) | phrases: nimm Apples Spracherkennung für die Live-Vorschau; wähle die Vorschau-Engine, die macOS 26 braucht; nimm die Vorschau ohne separaten Download eines Vorschaumodells |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal"></a>

### Universal / Universal (`previewEngine.universal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | catalog key `Universal` |
| Description | Works on macOS 14 and later, in more languages. Needs one optional 217 MB download. / Funktioniert ab macOS 14 und unterstützt mehr Sprachen. Ein optionaler Download von 217 MB ist nötig. |
| Description source | catalog key `Works on macOS 14 and later, in more languages. Needs one optional 217 MB download.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewChoicesExpanded` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 217MB<br>phrases: choose Universal for the live preview; use the preview engine that works on macOS 14; choose the preview engine with more languages |
| Search (de) | words: 217MB<br>phrases: nimm Universal für die Live-Vorschau; wähle die Vorschau-Engine, die auf macOS 14 läuft; nimm die Vorschau-Engine mit mehr Sprachen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition-top"></a>

### Top / Oben (`pillPosition.top`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillPosition`](#node-pillPosition) |
| Title source | catalog key `Top` |
| Description | none |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillPosition`](#node-pillPosition) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: upper, above<br>phrases: put the recording pill at the top of the screen; show the recording indicator at the upper screen edge |
| Search (de) | words: oberhalb<br>phrases: setz die Aufnahmeanzeige oben auf den Bildschirm; zeig die Aufnahmeanzeige am oberen Bildschirmrand |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition-bottom"></a>

### Bottom / Unten (`pillPosition.bottom`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillPosition`](#node-pillPosition) |
| Title source | catalog key `Bottom` |
| Description | none |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillPosition`](#node-pillPosition) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: lower, below<br>phrases: put the recording pill at the bottom of the screen; show the recording indicator at the lower screen edge |
| Search (de) | words: unterhalb<br>phrases: setz die Aufnahmeanzeige unten auf den Bildschirm; zeig die Aufnahmeanzeige am unteren Bildschirmrand |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-capsule"></a>

### Capsule / Kapsel (`pillStyle.capsule`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Capsule` |
| Description | A compact pill with a dot and level meter. / Eine kompakte Kapsel mit Punkt und Pegelbalken. |
| Description source | catalog key `A compact pill with a dot and level meter.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dot, compact<br>phrases: use the small recording pill with a dot and level meter; choose the compact dot and meter recording indicator |
| Search (de) | words: Aufnahmepunkt, kompakt<br>phrases: nimm die kleine Aufnahmeanzeige mit Punkt und Pegel; wähle die kompakte Anzeige mit Punkt und Lautstärkemesser |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-levelRail"></a>

### Level Rail / Pegelanzeige (`pillStyle.levelRail`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Level Rail` |
| Description | A slim rail that follows your volume. / Eine schmale Leiste, die sich deiner Lautstärke anpasst. |
| Description source | catalog key `A slim rail that follows your volume.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: bar, strip, rail, slim<br>phrases: use a thin recording bar that follows my voice volume; choose the slim level rail as the recording indicator |
| Search (de) | words: Balken, Leiste, Streifen, schmal<br>phrases: nimm einen schmalen Aufnahmebalken, der meiner Lautstärke folgt; wähle die dünne Pegelleiste als Aufnahmeanzeige |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-readingWell"></a>

### Reading Well / Lesefeld (`pillStyle.readingWell`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Reading Well` |
| Description | Shows words as you speak. Turns Live Preview on. / Zeigt Wörter beim Sprechen. Schaltet die Live-Vorschau ein. |
| Description source | catalog key `Shows words as you speak. Turns Live Preview on.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: panel<br>phrases: choose the recording pill style that displays my words; use a floating text panel as the recording indicator; choose the Reading Well style and turn on Live Preview |
| Search (de) | words: Textfeld<br>phrases: wähle den Stil der Aufnahmeanzeige, der meine Wörter zeigt; nimm ein schwebendes Textfeld als Aufnahmeanzeige; wähle das Lesefeld und schalte damit die Live-Vorschau ein |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-dustMote"></a>

### Dust Mote / Staubflöckchen (`recordingChime.dustMote`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Dust Mote` |
| Description | Soft filtered air, no tone. / Leises, gefiltertes Rauschen ohne Tonhöhe. |
| Description source | catalog key `Soft filtered air, no tone.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: toneless, pitchless, air<br>phrases: choose the filtered air sound with no tone; use the soft recording sound without a musical pitch |
| Search (de) | words: Luftrauschen, Luftgeräusch<br>phrases: nimm das sanfte Luftrauschen ohne Tonhöhe; wähle das gefilterte Luftgeräusch ohne erkennbare Tonhöhe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-velvetHush"></a>

### Velvet Hush / Samtflüstern (`recordingChime.velvetHush`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Velvet Hush` |
| Description | Two close tones, gentle warmth. / Zwei eng beieinanderliegende Töne, sanft und warm. |
| Description source | catalog key `Two close tones, gentle warmth.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose the warm chime with two closely pitched tones; use the gentle pair of tones with similar pitches |
| Search (de) | phrases: nimm den warmen Klang mit zwei ähnlichen Tonhöhen; wähle das sanfte Tonpaar mit dicht beieinanderliegenden Tönen |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-mutedConfirm"></a>

### Muted Confirm / Leises Okay (`recordingChime.mutedConfirm`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Muted Confirm` |
| Description | Same pitch both ways, plain. / Gleiche Tonhöhe beim Starten und Stoppen, ganz schlicht. |
| Description source | catalog key `Same pitch both ways, plain.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: plain, matching<br>phrases: use the same chime pitch for recording start and stop; choose the plain sound with matching pitches both ways |
| Search (de) | words: schlicht, gleich<br>phrases: nimm beim Aufnahmestart und Aufnahmeende dieselbe Tonhöhe; wähle den schlichten Ton, der beim Starten und Stoppen gleich klingt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-whisperTick"></a>

### Whisper Tick / Flüstertick (`recordingChime.whisperTick`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Whisper Tick` |
| Description | Barely-there tick. / Ein kaum hörbares Ticken. |
| Description source | catalog key `Barely-there tick.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: tick, ticking, faint<br>phrases: choose the recording tick that is barely audible; use the very faint ticking sound |
| Search (de) | words: Ticken, Tick, Tickgeräusch<br>phrases: nimm das Ticken, das kaum zu hören ist; wähle das ganz leise Tickgeräusch |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-roundPebble"></a>

### Round Pebble / Runder Kiesel (`recordingChime.roundPebble`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Round Pebble` |
| Description | Rounded, no edge. / Rund und weich. |
| Description source | catalog key `Rounded, no edge.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: rounded, round, edgeless<br>phrases: choose the rounded recording sound without a sharp edge; use the chime described as rounded with no edge |
| Search (de) | words: rund, abgerundet<br>phrases: nimm den rund klingenden Aufnahmeton ohne scharfe Kante; wähle den Klang, der als abgerundet beschrieben wird |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-paperTap"></a>

### Paper Tap / Papierklopfen (`recordingChime.paperTap`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Paper Tap` |
| Description | Soft paper-like tap. / Ein leises Klopfen wie auf Papier. |
| Description source | catalog key `Soft paper-like tap.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: papery, paper<br>phrases: choose the recording sound like a soft tap on paper; use the gentle paper-like tapping sound |
| Search (de) | words: Papier, Papiergeräusch<br>phrases: nimm den Aufnahmeton, der wie sanftes Tippen auf Papier klingt; wähle das leise papierartige Klopfgeräusch |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-softHush"></a>

### Soft Hush / Sanftes Säuseln (`recordingChime.softHush`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Soft Hush` |
| Description | Slow fade, like a breath. / Ein langsames Verklingen wie ein Atemzug. |
| Description source | catalog key `Slow fade, like a breath.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: breath, breathy, fade, exhale<br>phrases: choose the breath-like recording sound that fades slowly; use the chime that sounds like a slowly fading breath |
| Search (de) | words: Atem, Atemzug, Ausatmen, ausklingen<br>phrases: nimm den Klang, der wie ein Atemzug langsam ausklingt; wähle das langsam verklingende Atemgeräusch |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-lowNod"></a>

### Low Nod / Tiefes Nicken (`recordingChime.lowNod`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Low Nod` |
| Description | Low, warm, unhurried. / Tief, warm und gemächlich. |
| Description source | catalog key `Low, warm, unhurried.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: deep, low, unhurried<br>phrases: choose the low warm recording sound; use the deep chime with an unhurried feel |
| Search (de) | words: tief, dunkel, gemächlich<br>phrases: nimm den tiefen warmen Aufnahmeton; wähle den dunklen Klang, der ruhig und gemächlich klingt |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-cloudPop"></a>

### Cloud Pop / Wolkenplopp (`recordingChime.cloudPop`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Cloud Pop` |
| Description | Tiny filtered-air pop. / Ein leises Ploppen wie ein Luftstoß durch einen Filter. |
| Description source | catalog key `Tiny filtered-air pop.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: pop, popping<br>phrases: choose the tiny filtered air pop; use the little airy popping recording sound |
| Search (de) | words: Plopp, ploppen, Luftplopp<br>phrases: nimm den kleinen gefilterten Luftplopp; wähle das kurze luftige Ploppgeräusch |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-velvetTap"></a>

### Velvet Tap / Samttipp (`recordingChime.velvetTap`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Velvet Tap` |
| Description | Muted, compact tap. / Ein leises, kurzes Klopfen. |
| Description source | catalog key `Muted, compact tap.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: muted, damped<br>phrases: choose the compact muted tapping sound; use the short damped tap as my recording chime |
| Search (de) | words: gedämpft<br>phrases: nimm das kurze gedämpfte Tippgeräusch; wähle den kompakten gedämpften Klopfton |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-satinShift"></a>

### Satin Shift / Satin-Schimmer (`recordingChime.satinShift`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Satin Shift` |
| Description | Smooth two-tone shift. / Ein sanfter Wechsel zwischen zwei Tönen. |
| Description source | catalog key `Smooth two-tone shift.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: transition, shift<br>phrases: choose the recording sound with a smooth two-tone shift; use the chime with a smooth change between two tones |
| Search (de) | words: Tonwechsel, Tonübergang<br>phrases: nimm den sanften Wechsel zwischen zwei Tönen; wähle den Aufnahmeton mit dem fließenden Tonübergang |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-airGlint"></a>

### Air Glint / Luftfunkeln (`recordingChime.airGlint`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Air Glint` |
| Description | Clean, airy glint. / Ein klarer, luftiger Klang. |
| Description source | catalog key `Clean, airy glint.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: airy, shimmer, sparkle<br>phrases: pick the airy chime; use the shimmering sound |
| Search (de) | words: luftig, schimmernd, funkelnd<br>phrases: nimm den luftig klingenden Ton; wähle den schimmernden Klang |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode-pushToTalk"></a>

### Push to Talk / Zum Sprechen drücken (`recordingMode.pushToTalk`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingMode`](#node-recordingMode) |
| Title source | catalog key `Push to Talk` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingMode`](#node-recordingMode) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: hold, release, lock<br>phrases: record while I hold the key; stop recording when I release the key; double press to keep recording; triple press to cancel in push to talk mode |
| Search (de) | words: gedrückthalten, loslassen, einrasten<br>phrases: nimm auf, solange ich die Taste gedrückt halte; beende die Aufnahme, wenn ich die Taste loslasse; lass die Aufnahme nach zweimaligem Drücken weiterlaufen; brich im Modus zum Gedrückthalten nach dreimaligem Drücken ab |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode-toggle"></a>

### Toggle / Umschalten (`recordingMode.toggle`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingMode`](#node-recordingMode) |
| Title source | catalog key `Toggle` |
| Description | none |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingMode`](#node-recordingMode) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: press once to record and again to stop; start and stop recording with separate key presses |
| Search (de) | words: antippen<br>phrases: starte die Aufnahme beim ersten Drücken und beende sie beim nächsten; lass mich zum Aufnehmen einmal drücken statt die Taste zu halten |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-egOne"></a>

### EG-1 (`aiPolishProvider.egOne`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Our tuned model / Unser angepasstes Modell |
| Description source | catalog key `Our tuned model` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use the app's own model to clean up my dictation; choose EG-1 for dictation cleanup on this Mac |
| Search (de) | phrases: verbessere meine Diktate mit dem eigenen Modell der App; wähle EG-1 für die Diktatkorrektur auf diesem Mac |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-s1Mini"></a>

### S1-mini (`aiPolishProvider.s1Mini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | by Superwhisper / von Superwhisper |
| Description source | catalog key `by Superwhisper` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Superwhisper, small, compact<br>phrases: use Superwhisper's model to clean up my dictation; pick the small local model suited to English dictation |
| Search (de) | words: Superwhisper, klein, kompakt<br>phrases: verbessere meine Diktate mit dem Modell von Superwhisper; nimm das kleine lokale Modell für englische Diktate |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-appleIntelligence"></a>

### Apple Intelligence (`aiPolishProvider.appleIntelligence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Built into macOS / In macOS integriert |
| Description source | catalog key `Built into macOS` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple's built-in model to clean up my dictation; choose Apple Intelligence for dictation polish |
| Search (de) | phrases: verbessere meine Diktate mit Apples eingebautem Modell; wähle Apple Intelligence für die Diktatkorrektur |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-ollama"></a>

### Ollama (`aiPolishProvider.ollama`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your models, local or hosted / Deine Modelle, lokal oder gehostet |
| Description source | catalog key `Your models, local or hosted` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use my Ollama models to clean up dictation; choose my own local or hosted Ollama setup for dictation |
| Search (de) | phrases: verbessere meine Diktate mit meinen Ollama-Modellen; nutze für die Diktatkorrektur meine eigene lokale oder gehostete Ollama-Umgebung |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-openAI"></a>

### OpenAI (`aiPolishProvider.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose OpenAI to clean up my dictation; use OpenAI cloud polish for dictated text |
| Search (de) | phrases: wähle OpenAI für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit OpenAI in der Cloud |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-gemini"></a>

### Google Gemini (`aiPolishProvider.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose Google's model to clean up my dictation; use Gemini cloud polish for dictated text |
| Search (de) | phrases: wähle Googles Modell für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit Gemini in der Cloud |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-claude"></a>

### Claude (`aiPolishProvider.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose Anthropic's model to clean up my dictation; use Claude cloud polish for dictated text |
| Search (de) | phrases: wähle Anthropics Modell für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit Claude in der Cloud |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-casual"></a>

### Casual / Locker (`s1Tone.casual`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Tone`](#node-s1Tone) |
| Title source | catalog key `Casual` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: informal, chatty, relaxed<br>phrases: make S1-mini write in an informal style; make my text sound like everyday chat |
| Search (de) | words: umgangssprachlich, salopp, ungezwungen<br>phrases: lass S1-mini ganz ungezwungen schreiben; formuliere meinen Text so locker wie in einem Chat |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-semiCasual"></a>

### Semi-casual / Eher locker (`s1Tone.semiCasual`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Tone`](#node-s1Tone) |
| Title source | catalog key `Semi-casual` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: make S1-mini slightly informal; use a relaxed style without being too chatty |
| Search (de) | phrases: lass S1-mini eher locker schreiben; formuliere entspannt, aber nicht zu salopp |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-semiFormal"></a>

### Semi-formal / Eher förmlich (`s1Tone.semiFormal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Tone`](#node-s1Tone) |
| Title source | catalog key `Semi-formal` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: make S1-mini somewhat formal; use a professional style without sounding stiff |
| Search (de) | phrases: lass S1-mini eher förmlich schreiben; formuliere professionell, aber nicht steif |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-formal"></a>

### Formal / Förmlich (`s1Tone.formal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Tone`](#node-s1Tone) |
| Title source | catalog key `Formal` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: businesslike, official<br>phrases: make S1-mini write in a fully formal style; use formal wording for my text |
| Search (de) | words: formell, geschäftlich, offiziell<br>phrases: lass S1-mini sehr förmlich schreiben; verwende einen formellen Stil für meinen Text |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure-prose"></a>

### Prose / Fließtext (`s1Structure.prose`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Structure`](#node-s1Structure) |
| Title source | catalog key `Prose` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Structure`](#node-s1Structure) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: sentences, paragraphs<br>phrases: keep S1-mini output in full sentences; write paragraphs instead of bullet points |
| Search (de) | words: Sätze, Absätze<br>phrases: lass S1-mini in ganzen Sätzen schreiben; schreib Absätze statt Stichpunkte |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure-lists"></a>

### Lists / Listen (`s1Structure.lists`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Structure`](#node-s1Structure) |
| Title source | catalog key `Lists` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Structure`](#node-s1Structure) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: bullets, itemization, enumeration<br>phrases: make S1-mini turn spoken items into bullet points; format my dictated items as a list |
| Search (de) | words: Stichpunkte, Aufzählung, Listenpunkte<br>phrases: mach mit S1-mini aus meinen gesprochenen Punkten eine Liste; formatiere meine diktierten Punkte als Aufzählung |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context-general"></a>

### General / Allgemein (`s1Context.general`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Context`](#node-s1Context) |
| Title source | catalog key `General` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Context`](#node-s1Context) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use ordinary text formatting in S1-mini; do not format my S1-mini dictation as an email |
| Search (de) | phrases: behandle mein S1-mini-Diktat als normalen Text; formatiere meinen S1-mini-Text nicht als E-Mail |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context-email"></a>

### Email / E-Mail (`s1Context.email`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`s1Context`](#node-s1Context) |
| Title source | catalog key `Email` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Context`](#node-s1Context) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: mail, greetings, signoffs<br>phrases: format my dictated greeting and signoff as an email; use email formatting in S1-mini |
| Search (de) | words: Mail, Anrede, Grußformel<br>phrases: formatiere meine diktierte Anrede und Grußformel wie in einer E-Mail; lass S1-mini meinen Text als E-Mail formatieren |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-all"></a>

### All categories / Alle Kategorien (`yourWords.category.all`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `All categories` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: unfiltered<br>phrases: show my words from every category; remove the category filter from my word list |
| Search (de) | words: ungefiltert<br>phrases: meine Wörter aus allen Kategorien anzeigen; den Kategoriefilter für meine Wörter aufheben |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-general"></a>

### General / Allgemein (`yourWords.category.general`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `wordCategory.general` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: everyday, ordinary<br>phrases: show my entries in the general category; filter my own words for everyday vocabulary |
| Search (de) | phrases: meine Einträge in der Kategorie Allgemein anzeigen; meine Wortliste nach der Kategorie Allgemein filtern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-person"></a>

### Person / Person (`yourWords.category.person`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `Person` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: filter my own word list for people's names; show the first and last names I added myself |
| Search (de) | phrases: meine eigene Wortliste nach Personennamen filtern; die Vor- und Nachnamen anzeigen, die ich selbst hinzugefügt habe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-brand"></a>

### Brand / Marke (`yourWords.category.brand`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `Brand` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: filter my own entries for brands; show the company and product names I added myself |
| Search (de) | phrases: meine eigenen Einträge nach Marken filtern; die Firmen- und Produktnamen anzeigen, die ich selbst hinzugefügt habe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-acronym"></a>

### Acronym / Akronym (`yourWords.category.acronym`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `Acronym` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: abbreviations, initialisms, shortenings<br>phrases: show the abbreviations I saved; filter my own word list for acronyms |
| Search (de) | words: Abkürzungen, Kürzel, Kurzformen<br>phrases: meine gespeicherten Abkürzungen anzeigen; meine eigene Wortliste nach Kürzeln filtern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-domain"></a>

### Domain / Fachgebiet (`yourWords.category.domain`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `Domain` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: filter my own entries for specialist terms; show the industry vocabulary I added myself |
| Search (de) | phrases: meine eigenen Einträge nach Fachbegriffen filtern; die Fachwörter anzeigen, die ich selbst hinzugefügt habe |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-autoLearned"></a>

### Auto-learned / Automatisch gelernt (`yourWords.category.autoLearned`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Title source | catalog key `Auto-learned` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`yourWords.categoryFilter`](#node-yourWords-categoryFilter) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: show only the words learned from my corrections; filter my word list for automatically learned entries |
| Search (de) | phrases: nur die aus meinen Korrekturen gelernten Wörter anzeigen; meine Wortliste nach automatisch gelernten Einträgen filtern |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-system"></a>

### System / System (`theme.system`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`theme`](#node-theme) |
| Title source | catalog key `System` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`theme`](#node-theme) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: make the app follow my Mac's appearance; switch between light and dark with my Mac |
| Search (de) | phrases: das Farbschema meines Macs übernehmen; mit meinem Mac zwischen hell und dunkel wechseln |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-light"></a>

### Light / Hell (`theme.light`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`theme`](#node-theme) |
| Title source | catalog key `Light` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`theme`](#node-theme) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: bright, day, daytime<br>phrases: use a light app interface; keep the app in light mode |
| Search (de) | words: Tagmodus, heller<br>phrases: die App im hellen Modus anzeigen; dauerhaft das helle Design verwenden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-dark"></a>

### Dark / Dunkel (`theme.dark`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`theme`](#node-theme) |
| Title source | catalog key `Dark` |
| Description | none |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`theme`](#node-theme) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: night, nighttime, darker<br>phrases: use a dark app interface; keep the app in dark mode |
| Search (de) | words: Nachtmodus, dunkler<br>phrases: die App im dunklen Modus anzeigen; dauerhaft das dunkle Design verwenden |
| Search (other 30 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

## Language lists

Stop words may be ignored by search; markers never are. Per declared language:

- `ar` stop (92): في, من, على, ان, الى, و, عن, هذا, مع, التي, هذه, او, هو, كان, الذي, ذلك, بين, كانت, قد, هي, كما, اي, حيث, انه, عليه, وهو, تم, اذا, فى, له, مثل, هناك, لك, لي, ثم, يمكن, به, انت, لكن, وفي, ومن, فيه, فيها, الذين, يكون, عندما, وقد, بها, لو, بشكل, تلك, هنا, هل, عند, انا, لها, بان, كيف, حول, وهي, ب, فان, انها, بما, بسبب, منها, عليها, مما, بل, عليك, هم, لنا, بك, حين, وكان, اما, نحن, ام, أن, إلى, أو, إنه, إذا, أنت, أنا, بأن, فإن, إنها, أما, أم, فضلا, رجاء
  markers (148): لا, ليس, ليست, لم, لن, بدون, دون, بلا, غير, ما, أبدا, أبدًا, أبداً, ابدا, ولا, ولم, ولن, وليس, وليست, وبدون, وبلا, ودون, لست, لسنا, لستم, لستن, لستما, ليسا, ليستا, ليسوا, لسن, مش, مو, تشغيل, إيقاف, ايقاف, شغل, شغّل, شغلي, شغّلي, شغلوا, شغّلوا, أوقف, أوقفي, أوقفوا, اوقف, اوقفي, اوقفوا, وقف, وقّف, وقفي, وقّفي, وقفوا, وقّفوا, توقف, توقّف, توقفي, توقّفي, توقفوا, توقّفوا, فعّل, فعّلي, فعّلوا, عطل, عطّل, عطلي, عطّلي, عطلوا, عطّلوا, ابدأ, ابدئي, ابدؤوا, أظهر, أظهري, أظهروا, اظهر, اظهري, اظهروا, أخف, أخفِ, أخفي, أخفوا, اخف, اخفي, اخفوا, كتم, اكتم, اكتمي, اكتموا, ألغ, ألغِ, ألغي, ألغوا, الغي, الغ, علّق, علّقي, علّقوا, استأنف, استأنفي, استأنفوا, تابع, تابعي, تابعوا, غيّر, غيري, غيّري, غيروا, غيّروا, عدّل, عدل, عدلي, عدّلي, عدلوا, عدّلوا, اضبط, اضبطي, اضبطوا, بدّل, بدل, بدلي, بدّلي, بدلوا, بدّلوا, أكثر, اكثر, أقل, اقل, أعلى, اعلى, أخفض, اخفض, أهدأ, أسرع, اسرع, أبطأ, ابطأ, ابطا, أكبر, اكبر, أصغر, اصغر, فوق, تحت, مجددا, مجددًا, مجدداً, مجدّدًا
- `bg` stop (87): на, и, в, да, е, от, за, се, с, си, че, ще, са, това, като, а, ми, но, го, има, му, ако, към, може, съм, ти, ли, аз, които, при, ви, или, как, какво, той, трябва, във, което, те, така, със, когато, този, я, тази, ги, която, нещо, ме, беше, защото, им, тези, тя, бъде, защо, както, между, тук, мен, него, там, сме, кои, сте, тях, чрез, би, ето, нас, дали, ние, според, то, бе, заради, имат, къде, където, нея, бил, вас, иска, могат, мога, у, моля
  markers (139): не, няма, нямам, нямаш, нямаме, нямате, нямат, без, никога, нищо, никой, никоя, никое, никои, никого, никакъв, никаква, никакво, никакви, никаквия, никаквият, никаквата, никаквото, никаквите, нито, включи, включете, включвам, включваш, включва, включваме, включвате, включват, включен, включена, включено, включени, изключи, изключете, изключвам, изключваш, изключва, изключваме, изключвате, изключват, изключен, изключена, изключено, изключени, активирай, активирайте, активирам, деактивирай, деактивирайте, деактивирам, започни, започнете, започвам, започва, стартирай, стартирайте, спри, спрете, спре, спрат, спирам, спираш, спира, спираме, спирате, спират, покажи, покажете, показвам, скрий, скрийте, скривам, заглуши, заглушете, заглушавам, отзаглуши, отзаглушете, паузирай, паузирайте, продължи, продължете, възобнови, възобновете, промени, променете, променя, променям, променяш, променяме, променяте, променят, смени, сменете, сменя, сменям, настрой, настройте, коригирай, коригирайте, превключи, превключете, повече, по-малко, по-силно, по-силен, по-силна, по-силни, по-тихо, по-тих, по-тиха, по-тихи, по-бързо, по-бърз, по-бърза, по-бързи, по-бавно, по-бавен, по-бавна, по-бавни, по-голямо, по-голям, по-голяма, по-големи, по-малък, по-малка, по-малки, нагоре, надолу, отново, пак, увеличи, увеличете, намали, намалете
- `cs` stop (144): se, v, na, je, ze, si, do, jsem, ale, o, i, tak, pro, ve, za, co, k, jako, jak, od, jsou, mi, kdyz, me, nebo, byl, bude, ja, u, ma, jsme, ktere, ty, jeho, ktery, bylo, aby, byla, byt, pri, tam, toho, ten, kde, mam, ktera, ho, protoze, tu, podle, pokud, tom, neco, tim, mezi, nas, vam, vas, jste, kdo, proc, sve, tomu, asi, jejich, muze, kdy, ji, ti, ci, mit, takze, nam, vsak, jestli, maji, ta, tady, ke, jeji, proto, musi, budou, jsi, nekdo, tohle, jde, kteri, kvuli, zde, jim, tedy, chci, byly, mozna, mame, tento, budu, proste, my, ni, teto, byli, kterou, moje, chce, coz, když, mě, já, má, které, který, být, při, mám, která, protože, něco, tím, nás, vám, vás, proč, své, může, či, mít, takže, nám, však, mají, její, musí, někdo, kteří, kvůli, možná, máme, prostě, ní, této, což, prosím
  markers (142): ne, není, neni, nejsou, nejsem, nejsi, nejsme, nejste, bez, nikdy, nic, ničeho, ničemu, ničem, ničím, žádný, žádná, žádné, žádnou, žádného, žádnému, žádném, žádným, žádní, žádných, žádnými, zadny, zadna, zadne, zadnou, zadneho, zadnemu, zadnem, zadnym, zadni, zadnych, zadnymi, ani, zapnout, zapni, zapněte, zapínat, zapínej, zapnuto, vypnout, vypni, vypněte, vypínat, vypínej, vypnuto, povolit, povol, povolte, zakázat, zakaž, zakažte, aktivovat, aktivuj, deaktivovat, deaktivuj, spustit, spusť, spusťte, začít, začni, začněte, zastavit, zastav, zastavte, zastaví, zastavovat, zobrazit, zobraz, zobrazte, ukázat, ukaž, ukažte, skrýt, skryj, skryjte, ztlumit, ztlum, ztlumte, odtlumit, odtlum, odtlumte, pozastavit, pozastav, pozastavte, pokračovat, pokračuj, pokračujte, obnovit, obnov, obnovte, změnit, změň, změňte, změním, změní, měnit, měň, měňte, zmenit, zmen, zmente, upravit, uprav, upravte, přepnout, přepni, přepněte, prepnout, prepni, více, víc, méně, míň, vice, vic, mene, min, hlasitěji, tišeji, rychleji, pomaleji, hlasitější, tišší, rychlejší, pomalejší, větší, menší, vetsi, mensi, nahoru, dolů, dolu, výš, níž, znovu, znova, opět
- `da` stop (82): i, og, er, af, det, en, pa, jeg, har, med, de, kan, som, sa, et, var, vi, om, han, men, skal, ved, vil, ogsa, være, hvor, man, hvis, sig, mig, eller, her, hvad, noget, da, dig, kunne, min, nar, blev, bliver, havde, hun, have, selv, din, vores, deres, jo, ma, denne, dette, hans, været, blive, os, ville, hvordan, nogle, skulle, ham, sin, sadan, fordi, nogen, dog, dit, hvorfor, mit, hos, dine, disse, hendes, mine, hvem, på, så, også, når, må, sådan, venligst
  markers (96): ikke, nej, uden, aldrig, intet, ingen, ingenting, intets, ingens, hverken, fra, til, tænd, tænde, tænder, tændes, sluk, slukke, slukker, slukkes, aktiver, aktivér, aktivere, aktiverer, deaktiver, deaktivér, deaktivere, deaktiverer, start, starte, starter, stop, stoppe, stopper, stoppes, stands, standse, standser, vis, vise, viser, skjul, skjule, skjuler, dæmp, dæmpe, dæmper, mute, unmute, pausér, pausere, pauserer, fortsæt, fortsætte, fortsætter, genoptag, genoptage, genoptager, ændr, ændre, ændrer, ændres, juster, justér, justere, justerer, tilpas, tilpasse, skift, skifte, skifter, skiftes, mere, mindre, højere, lavere, hurtigere, langsommere, større, stærkere, svagere, op, ned, opad, nedad, igen, øg, øge, øger, sænk, sænke, sænker, hæv, hæve, gentag, gentage
- `de` stop (46): ich, es, der, die, das, eine, wenn, wie, mein, meine, bitte, machen, wo, was, ist, kann, den, dem, zu, für, im, in, auf, und, oder, mit, du, mir, mich, möchte, will, können, soll, einen, einem, einer, eines, des, dass, mal, doch, auch, habe, haben, könnte, würde
  markers (130): nicht, nie, niemals, ohne, aus, an, nein, kein, keine, keinen, keinem, keiner, keines, keins, keinerlei, nichts, einschalten, einschalte, einschaltet, ausschalten, ausschalte, ausschaltet, anschalten, anschalte, abschalten, abschalte, anmachen, anmache, ausmachen, ausmache, aktivieren, aktiviere, aktivier, deaktivieren, deaktiviere, deaktivier, starten, starte, startet, beginnen, beginne, stoppen, stopp, stop, stoppe, stoppt, stoppst, beenden, beende, anhalten, anhalte, anhält, anzeigen, zeigen, zeige, zeig, ausblenden, ausblende, einblenden, einblende, verbergen, verbirg, verstecken, versteck, verstecke, stummschalten, stummschalte, stumm, pausieren, pausiere, pausier, fortsetzen, fortsetze, fortfahren, weiter, weitermachen, wiederaufnehmen, ändern, ändere, änder, ändert, änderst, aendern, aendere, aendert, anpassen, anpasse, wechseln, wechsle, wechsele, wechselt, umschalten, umschalte, umstellen, umstelle, mehr, weniger, lauter, leiser, schneller, langsamer, größer, groesser, kleiner, höher, hoeher, niedriger, hoch, runter, rauf, herunter, hinunter, aufwärts, abwärts, wieder, erneut, nochmal, nochmals, erhöhen, erhöhe, verringern, verringere, senken, senke, vergrößern, verkleinern, ein, entmuten, entmute, wechsel
- `el` stop (82): και, το, να, του, η, με, την, της, για, ο, που, τα, από, σε, θα, τον, είναι, στο, στην, οι, των, μου, τη, τους, μας, τις, ότι, μια, ένα, στη, ήταν, τι, σας, σου, στα, αν, στον, έχει, αλλά, αυτό, στις, κι, όταν, πως, όπως, αυτή, πρέπει, μπορεί, είχε, έχουν, έχω, σαν, εγώ, κάτι, ένας, έτσι, αυτά, όμως, ενώ, είμαι, είσαι, οποία, έναν, έχουμε, απ, καθώς, έχεις, ας, όπου, εκεί, οποίο, μεταξύ, αυτός, είμαστε, ενός, εσύ, έχετε, αυτές, εμείς, αφού, λόγω, παρακαλώ
  markers (129): δεν, δε, μη, μην, όχι, χωρίς, δίχως, ποτέ, τίποτα, τίποτε, κανένα, κανένας, κανείς, κανενός, κανέναν, καμία, καμιά, καμίας, καμιάς, ούτε, ενεργοποίησε, ενεργοποιήστε, ενεργοποιήσω, απενεργοποίησε, απενεργοποιήστε, απενεργοποιήσω, άνοιξε, ανοίξτε, ανοίγω, ανοίγει, ανοίξω, ανοίξεις, ανοίξει, ανοιχτό, ανοιχτή, ανοιχτός, κλείσε, κλείστε, κλείνω, κλείνει, κλείσω, κλείσεις, κλείσει, κλειστό, κλειστή, κλειστός, ξεκίνα, ξεκίνησε, ξεκινήστε, ξεκινήσω, σταμάτα, σταμάτησε, σταματήστε, σταματώ, σταματάω, σταματά, σταματάει, σταματήσω, σταματήσεις, σταματήσει, δείξε, δείξτε, δείξω, εμφάνισε, εμφανίστε, κρύψε, κρύψτε, κρύψω, σίγασε, σιγάστε, αποσίγασε, αποσιγάστε, παύσε, παύστε, συνέχισε, συνεχίστε, συνεχίσω, άλλαξε, αλλάξτε, αλλάζω, αλλάζεις, αλλάζει, αλλάζουμε, αλλάζετε, αλλάζουν, αλλάξω, αλλάξεις, αλλάξει, αλλάξουμε, αλλάξετε, αλλάξουν, ρύθμισε, ρυθμίστε, ρυθμίσω, προσάρμοσε, προσαρμόστε, εναλλάσσω, εναλλάξε, εναλλάξτε, εναλλάξω, περισσότερο, περισσότερα, λιγότερο, λιγότερα, πιο, δυνατότερα, δυνατότερο, δυνατότερος, δυνατότερη, σιγότερα, σιγότερο, χαμηλότερα, χαμηλότερο, γρηγορότερα, γρηγορότερο, αργότερα, αργότερο, μεγαλύτερο, μεγαλύτερη, μεγαλύτερος, μεγαλύτερα, μικρότερο, μικρότερη, μικρότερος, μικρότερα, πάνω, κάτω, ξανά, πάλι
- `en` stop (31): make, it, the, a, an, to, i, my, me, when, how, do, can, want, please, use, is, where, what, of, for, in, and, or, with, you, your, this, that, would, could
  markers (123): not, no, never, without, none, nothing, cannot, don't, doesn't, can't, won't, isn't, aren't, didn't, wasn't, weren't, haven't, hasn't, hadn't, wouldn't, couldn't, shouldn't, mustn't, needn't, don’t, doesn’t, can’t, won’t, isn’t, aren’t, didn’t, wasn’t, weren’t, haven’t, hasn’t, hadn’t, wouldn’t, couldn’t, shouldn’t, mustn’t, needn’t, dont, doesnt, cant, wont, isnt, arent, didnt, wasnt, werent, havent, hasnt, hadnt, wouldnt, couldnt, shouldnt, mustnt, neednt, off, on, stop, stops, stopping, change, changes, changing, enable, enables, enabling, disable, disables, disabling, activate, deactivate, start, starts, starting, begin, show, shows, showing, hide, hides, hiding, mute, mutes, muting, unmute, unmutes, unmuting, pause, pauses, pausing, resume, resumes, resuming, continue, adjust, adjusts, adjusting, switch, switches, switching, toggle, more, less, louder, quieter, faster, slower, bigger, smaller, up, down, again, increase, decrease, raise, lower, higher, larger, fewer, softer
- `es` stop (93): de, la, que, el, en, y, los, un, se, por, es, las, con, una, lo, su, al, como, me, si, pero, te, o, mi, le, este, esta, ha, cuando, yo, ser, son, hay, fue, tu, sobre, eso, tiene, nos, porque, asi, entre, puede, hacer, era, esto, hace, donde, algo, ese, han, tengo, estan, esa, estoy, les, sea, habia, tener, ellos, creo, aunque, soy, estos, he, sido, aqui, ella, estas, estaba, estar, tienen, quien, mis, nuestro, parece, nuestra, poder, pueden, pues, cual, debe, tal, fueron, así, están, había, aquí, quién, cuál, a, quiero, favor
  markers (143): no, sin, nunca, jamás, jamas, nada, ningún, ningun, ninguno, ninguna, ningunos, ningunas, ni, tampoco, activar, activa, active, activen, activad, desactivar, desactiva, desactive, desactiven, desactivad, encender, enciende, encienda, enciendan, encended, encendido, encendida, encendidos, encendidas, apagar, apaga, apague, apaguen, apagad, apagado, apagada, apagados, apagadas, iniciar, inicia, inicie, inicien, empezar, empieza, parar, para, paro, paras, paramos, paráis, paran, pare, pares, paremos, paréis, paren, parad, detener, detén, deten, detengo, detienes, detiene, detenemos, detenéis, detienen, detenga, detengas, detengan, detened, mostrar, muestra, muestre, muestren, ocultar, oculta, oculte, oculten, silenciar, silencia, silencie, silencien, desilenciar, desilencia, desilencie, desilencien, pausar, pausa, pause, pausen, reanudar, reanuda, reanude, reanuden, cambiar, cambia, cambias, cambiamos, cambiáis, cambian, cambie, cambies, cambiemos, cambiéis, cambien, cambiad, ajustar, ajusta, ajusten, alternar, alterna, alterne, alternen, más, mas, menos, fuerte, suave, alto, bajo, rápido, rápida, rápidos, rápidas, lento, lenta, lentos, lentas, mayor, mayores, menor, menores, arriba, abajo, subir, sube, bajar, baja, nuevamente
- `et` stop (26): aga, et, ja, kas, kui, ma, me, mida, mind, minu, mis, mu, mul, mulle, nad, oled, olen, oli, oma, sa, seda, selle, siis, ta, te, palun
  markers (128): ei, ära, ärge, ärgu, ärgem, ilma, mitte, kunagi, iial, iialgi, midagi, miski, millegi, milleski, millestki, ükski, ühegi, ühtki, ühtegi, ühelegi, ühelgi, üheltki, ühessegi, üheski, ühestki, ühekski, ühenigi, ühenagi, ühetagi, ühegagi, ühedki, ühtedegi, ühtesidki, ühtedelegi, ühtedelgi, ühtedeltki, ühtedessegi, ühtedeski, ühtedestki, ühtedekski, ühtedenigi, ühtedenagi, ühtedetagi, ühtedegagi, pole, poleks, välja, sisse, lülita, lülitada, lülitama, lülitage, aktiveeri, aktiveerida, deaktiveeri, deaktiveerida, keela, keelata, luba, lubada, alusta, alustada, käivita, käivitada, peata, peatada, peatama, peatage, peatan, peatab, peatu, peatuda, peatuma, peatuge, lõpeta, lõpetada, lõpetama, lõpetage, lõpetan, lõpetab, näita, näidata, peida, peita, vaigista, vaigistada, taasta, taastada, pausita, pausitada, jätka, jätkata, muuda, muuta, muutma, muutke, muudan, muudab, kohanda, kohandada, reguleeri, reguleerida, vaheta, vahetada, rohkem, vähem, enam, valjem, valjemaks, valjemalt, vaiksem, vaiksemaks, vaiksemalt, kiirem, kiiremaks, kiiremini, aeglasem, aeglasemaks, aeglasemalt, suurem, suuremaks, väiksem, väiksemaks, üles, alla, uuesti, taas, jälle
- `fi` stop (80): ja, että, se, oli, mutta, ole, kun, hän, ovat, voi, sen, kuin, tai, joka, olla, sitä, mitä, kanssa, tämä, sitten, olisi, ollut, siitä, ne, sekä, miten, mukaan, olen, hänen, vaan, koska, kuitenkin, vaikka, mikä, jotka, eli, jossa, siis, sillä, ehkä, itse, onko, tuo, jonka, kuten, miksi, joku, siihen, tästä, he, joten, kiitos, tätä, esimerkiksi, vai, kuinka, niitä, olivat, tällä, minä, missä, kautta, tähän, me, meillä, olevan, voisi, nämä, olet, heidän, voidaan, mistä, meidän, niiden, hänet, jota, takia, haluaa, muuten, haluan
  markers (175): ei, en, et, emme, ette, eivät, älä, älkää, älköön, älkäämme, älkööt, ilman, koskaan, ikinä, mikään, mitään, minkään, missään, mistään, mihinkään, millään, miltään, millekään, minään, miksikään, mittään, mitkään, mitkienkään, missäkään, mistäkään, milläkään, miltäkään, minäkään, yhtään, yksikään, yhdenkään, yhtäkään, yhdessäkään, yhdestäkään, yhteenkään, yhdelläkään, yhdeltäkään, yhdellekään, yhtenäkään, yhdeksikään, yhdettäkään, yhdetkään, yksienkään, yksiäkään, yksissäkään, yksistäkään, yksiinkään, yksilläkään, yksiltäkään, yksillekään, yksinäkään, yksiksikään, yksittäkään, pois, päällä, päälle, päältä, kytke, kytkeä, kytkekää, käyttöön, käytöstä, salli, sallia, estä, estää, käynnistä, käynnistää, aloita, aloittaa, lopeta, lopettaa, lopettakaa, lopetan, lopetetaan, pysäytä, pysäyttää, pysäyttäkää, pysäytän, pysäytetään, pysähdy, pysähtyä, pysähtykää, näytä, näyttää, piilota, piilottaa, mykistä, mykistää, palauta, palauttaa, keskeytä, keskeyttää, tauota, tauottaa, jatka, jatkaa, muuta, muuttaa, muuttakaa, muutan, muutetaan, muokkaa, muokata, vaihda, vaihtaa, vaihtakaa, vaihdan, vaihdetaan, säädä, säätää, enemmän, vähemmän, kovempaa, kovempi, hiljempaa, hiljaisempi, nopeammin, nopeampi, hitaammin, hitaampi, suurempi, suuremmaksi, isompi, isommaksi, pienempi, pienemmäksi, ylös, alas, uudelleen, uudestaan, taas, jälleen, eikä, enkä, etkä, emmekä, ettekä, eivätkä, ettei, etten, ettet, ettemme, ettette, etteivät, ellei, ellen, ellet, ellemme, ellette, elleivät, eikö, enkö, etkö, emmekö, ettekö, eivätkö, eihän, enhän, ethän, emmehän, ettehän, eiväthän, eipä, enpä, etpä, emmepä, ettepä, eivätpä, enää
- `fr` stop (93): de, la, le, et, l, les, est, en, des, d, un, que, une, il, pour, dans, je, qui, c, au, ce, qu, par, avec, j, mais, se, vous, ça, tu, elle, y, ou, si, sont, nous, comme, être, ils, cette, sa, aux, me, ont, t, m, était, été, mon, ses, lui, peut, leur, moi, ces, quand, suis, avoir, va, alors, avait, ma, dire, te, votre, donc, notre, dont, toi, quoi, soit, leurs, chez, ainsi, mes, comment, es, sera, nos, parce, cela, doit, car, eu, puis, cet, ceux, elles, pourquoi, ta, fais, merci, à
  markers (139): pas, sans, non, ne, n', n’, n, jamais, rien, aucun, aucune, aucuns, aucunes, nul, nulle, nuls, nulles, ni, plus, moins, activer, active, activez, désactiver, désactive, désactivez, allumer, allume, allumes, allumons, allumez, allument, allumé, allumée, allumés, allumées, éteindre, éteins, éteint, éteignons, éteignez, éteignent, éteinte, éteints, éteintes, démarrer, démarre, démarrez, commencer, commence, commencez, arrêter, arrête, arrêtes, arrêtons, arrêtez, arrêtent, stopper, stoppe, stoppes, stoppons, stoppez, stoppent, stop, interrompre, interromps, interrompt, interrompons, interrompez, interrompent, afficher, affiche, affichez, montrer, montre, montrez, masquer, masque, masquez, cacher, cache, cachez, couper, coupe, coupez, muet, muette, muets, muettes, mute, unmute, réactiver, réactive, réactivez, rétablir, rétablis, rétablissez, suspendre, suspends, suspendez, reprendre, reprends, reprenez, changer, change, changes, changeons, changez, changent, modifier, modifie, modifies, modifions, modifiez, modifient, ajuster, ajuste, ajustez, basculer, bascule, basculez, fort, faible, vite, lentement, grand, grande, grands, grandes, petit, petite, petits, petites, haut, bas, encore, recommencer, recommence, recommencez
- `hi` stop (53): की, और, को, का, पर, एक, तो, कर, हो, लिए, कि, इस, था, यह, गया, किया, जो, आप, साथ, रहा, दिया, थी, या, वह, जब, होता, अपनी, जा, सकता, करना, तरह, करता, इन, होती, उस, अपना, उनकी, तब, इसका, इसी, कौन, है, हैं, मैं, में, से, लेकिन, करें, करो, कृपया, मुझे, मेरी, मेरा
  markers (113): नहीं, नही, ना, न, मत, बिना, बगैर, बग़ैर, कभी, कुछ, कोई, किसी, किन्हीं, बंद, बन्द, चालू, शुरू, शुरु, सक्रिय, निष्क्रिय, सक्षम, अक्षम, रोक, रोको, रोकें, रोकना, रोकिए, रोकिये, रोके, रोकते, रोकता, रोकती, रुक, रुको, रुकें, रुकना, रुकिए, रुकिये, रुकते, रुकता, रुकती, दिखाओ, दिखाएं, दिखाएँ, दिखाना, दिखा, दिखाइए, दिखाइये, छिपाओ, छिपाएं, छिपाएँ, छिपाना, छिपा, छिपाइए, छिपाइये, छुपाओ, छुपाएं, छुपाएँ, छुपाना, छुपा, छुपाइए, छुपाइये, म्यूट, अनम्यूट, पॉज़, पॉज, जारी, फिर, दोबारा, दुबारा, पुनः, बहाल, बदल, बदलो, बदलें, बदलना, बदलिए, बदलिये, बदलता, बदलती, बदलते, बदले, समायोजित, एडजस्ट, स्विच, ज्यादा, ज़्यादा, अधिक, कम, तेज, तेज़, धीमा, धीमी, धीमे, धीरे, बड़ा, बड़ी, बड़े, छोटा, छोटी, छोटे, ऊँचा, ऊँची, ऊँचे, ऊंचा, ऊंची, ऊंचे, ऊपर, नीचे, बढ़ाओ, बढ़ाना, घटाओ, घटाना
- `hr` stop (136): ako, ali, bi, bih, bila, bili, bilo, bio, bismo, biste, biti, će, ćemo, ćeš, ćete, ću, da, ga, hoće, hoćemo, hoćeš, hoćete, hoću, i, iako, ih, ili, iz, ja, je, jer, jesam, jesi, jesmo, jest, jeste, jesu, joj, ju, kada, kako, kao, koja, koje, koji, kojima, koju, kroz, li, me, mene, meni, mi, moj, moja, moje, mu, na, nam, nama, nas, naša, naše, našeg, nego, neka, neki, nekog, neku, nešto, netko, njega, njegov, njegova, njegovo, njemu, njezin, njezina, njezino, njih, njihov, njihova, njihovo, njim, njima, njoj, nju, no, o, od, ona, oni, ono, ova, pa, pak, po, sa, sam, se, sebe, sebi, si, smo, ste, što, su, svog, svoj, svoja, svoje, svom, ta, taj, tako, te, tebe, tebi, ti, toj, tome, tvoj, tvoja, tvoje, u, uz, vam, vama, vas, vaša, vaše, vi, za, zar, molim, hvala
  markers (141): ne, nije, nisu, nisam, nisi, nismo, niste, nema, nemam, nemaš, nemamo, nemate, nemaju, neće, neću, nećeš, nećemo, nećete, nemoj, nemojte, nemojmo, bez, nikad, nikada, ništa, ničega, ničemu, ničim, ni, nijedan, nijedna, nijedno, nijedni, nijedne, nijednu, nijednog, nijednoga, nijednom, nijednome, nijednomu, nijednoj, nijednim, nijednima, nijednih, nikakav, nikakva, nikakvo, nikakvi, nikakve, nikakvu, nikakvog, nikakvoga, nikakvom, nikakvome, nikakvomu, nikakvoj, nikakvim, nikakvima, nikakvih, uključi, uključite, uključiti, uključuje, uključivati, uključuj, uključujte, isključi, isključite, isključiti, isključuje, isključivati, isključuj, isključujte, omogući, omogućiti, onemogući, onemogućiti, pokreni, pokrenuti, počni, početi, zaustavi, zaustavite, zaustaviti, zaustavim, stani, stanite, stati, prestani, prestanite, prestati, prekini, prekinite, prekinuti, prikaži, prikazati, pokaži, pokazati, sakrij, sakriti, utišaj, utišati, odmutiraj, odmutirati, pauziraj, pauzirati, nastavi, nastaviti, promijeni, promijenite, promijeniti, promijenim, mijenjaj, mijenjajte, mijenjati, mijenja, izmijeni, izmijenite, izmijeniti, prilagodi, prilagoditi, podesi, podesiti, prebaci, prebaciti, više, manje, glasnije, tiše, brže, sporije, veće, veći, veća, manji, manja, gore, dolje, opet, ponovo, ponovno
- `hu` stop (89): az, és, hogy, egy, de, ha, van, volt, ez, vagy, én, kell, azt, akkor, mint, ezt, mert, így, olyan, mi, lesz, lehet, vagyok, majd, úgy, aki, amikor, ami, te, pedig, nekem, amit, szerint, mit, ilyen, miért, volna, azért, milyen, lett, miatt, lenne, által, hát, ő, mikor, valami, arra, ezért, vannak, ahol, ezek, legyen, neki, aztán, valaki, amely, tényleg, erre, neked, na, ahogy, akik, szerintem, hogyan, valamint, ezzel, mivel, őket, ennek, hanem, ezen, persze, azonban, illetve, köszönöm, vele, talán, ebben, kellett, voltak, annak, hozzá, való, vagyunk, hol, a, kérem, szeretném
  markers (238): nem, ne, nincs, nincsen, nincsenek, sincs, sincsen, sincsenek, nélkül, soha, sohasem, sohase, semmi, semmit, semminek, semmivel, semmiben, semmiből, semmibe, semmin, semmiről, semmire, se, sem, semmilyen, semmilyet, semmilyenek, semmilyeneket, semmilyennek, semmilyennel, semmilyenné, semmilyenben, semmilyenből, semmilyenbe, semmilyenen, semmilyenről, semmilyenre, semmilyenhez, semmilyennél, semmilyentől, semmilyenért, semmilyenig, semmilyenként, semmilyeneknek, semmilyenekkel, semmilyenekben, semmilyenekből, semmilyenekbe, semmilyeneken, semmilyenekről, semmilyenekre, semmilyenekhez, semmilyeneknél, semmilyenektől, semmilyenekért, semmilyenekig, semmilyeneké, semennyi, semennyit, semennyinek, semennyivel, semennyivé, semennyiben, semennyiből, semennyibe, semennyin, semennyiről, semennyire, semennyihez, semennyinél, semennyitől, semennyiért, semennyiig, semennyiként, semmiféle, semmifélét, semmifélék, semmiféléket, semmifélének, semmifélével, semmifélévé, semmifélében, semmiféléből, semmifélébe, semmifélén, semmiféléről, semmifélére, semmiféléhez, semmifélénél, semmifélétől, semmiféléért, semmiféléig, semmiféleként, semmiféléknek, semmifélékkel, semmifélékben, semmifélékből, semmifélékbe, semmiféléken, semmifélékről, semmifélékre, semmifélékhez, semmiféléknél, semmiféléktől, semmifélékért, semmifélékig, semekkora, semekkorát, semekkorák, semekkorákat, semekkorának, semekkorával, semekkorává, semekkorában, semekkorából, semekkorába, semekkorán, semekkoráról, semekkorára, semekkorához, semekkoránál, semekkorától, semekkoráért, semekkoráig, semekkoraként, ki, be, bekapcsolni, kikapcsolni, bekapcsol, kikapcsol, bekapcsolva, kikapcsolva, kapcsolj, kapcsold, kapcsolja, kapcsoljon, kapcsoljátok, kapcsolják, engedélyezd, engedélyezz, engedélyezni, tiltsd, tilts, tiltani, letilt, letiltani, indítsd, indíts, indítani, leállít, leállítani, leállítsd, leállíts, leállítsa, leállítson, leállítsatok, leállítsátok, leállítsák, leállítsanak, állj, álljon, álljatok, álljanak, megállni, megállít, megállítani, megállítsd, megállíts, mutasd, mutass, mutatni, rejtsd, rejts, elrejteni, némítsd, némíts, némítani, visszakapcsol, visszakapcsolni, szüneteltess, szüneteltesd, szüneteltetni, folytasd, folytass, folytatni, változtass, változtasd, változtassa, változtasson, változtassatok, változtassátok, változtassák, változtassanak, változtat, változtatni, módosíts, módosítsd, módosítsa, módosítson, módosítsatok, módosítsátok, módosítsák, módosítsanak, módosít, módosítani, igazíts, igazítsd, igazítani, válts, váltsd, váltani, több, többet, kevesebb, kevesebbet, hangosabb, hangosabban, hangosabbra, halkabb, halkabban, halkabbra, gyorsabb, gyorsabban, lassabb, lassabban, nagyobb, nagyobbra, kisebb, kisebbre, fel, föl, le, feljebb, lejjebb, újra, megint, ismét
- `it` stop (114): di, che, il, la, un, l, i, una, le, si, con, della, da, sono, ma, al, ha, come, dei, se, nel, mi, alla, anche, lo, gli, delle, o, questo, ho, ci, ad, dal, essere, io, nella, ti, cui, d, era, stato, quando, ed, questa, c, cosa, hanno, suo, loro, perché, sia, sua, fare, così, dalla, degli, sul, poi, quello, fa, me, chi, mio, può, mia, sulla, dove, nei, sei, quella, quindi, hai, bene, grazie, dai, noi, nelle, vi, sta, te, dire, tu, questi, stata, lui, siamo, quel, qualche, quale, suoi, aveva, dalle, sarà, stati, tuo, va, avere, dello, erano, queste, ciò, però, sarebbe, aver, deve, forse, nostro, agli, qualcosa, sembra, fosse, per, in, vorrei
  markers (133): non, no, senza, mai, niente, nulla, nessun, nessuno, nessuna, nessun', nessun’, nessuni, nessune, né, neanche, nemmeno, neppure, attiva, attivare, attivate, disattiva, disattivare, disattivate, abilita, abilitare, disabilita, disabilitare, accendi, accendere, accendo, accende, accendiamo, accendete, accendono, accenda, acceso, accesa, accesi, accese, spegni, spegnere, spengo, spegne, spegniamo, spegnete, spengono, spenga, spento, spenta, spenti, spente, avvia, avviare, inizia, iniziare, ferma, fermare, fermo, fermi, fermiamo, fermate, fermano, fermati, fermatevi, arresta, arrestare, arresti, arrestate, interrompi, interrompere, interrompo, interrompe, interrompiamo, interrompete, interrompono, interrompa, stop, mostra, mostrare, mostrate, nascondi, nascondere, nascondete, silenzia, silenziare, silenziate, riattiva, riattivare, sospendi, sospendere, sospendete, riprendi, riprendere, riprendete, cambia, cambiare, cambi, cambiamo, cambiate, cambiano, modificare, modifico, modifichi, modifichiamo, modificate, modificano, regolare, regolate, adegua, adeguare, passa, passare, più, meno, veloce, veloci, lento, lenta, lenti, lente, grande, grandi, piccolo, piccola, piccoli, piccole, forte, forti, piano, su, giù, ancora, nuovamente
- `ja` stop (48): の, に, て, は, か, た, を, し, と, も, から, です, する, ます, こと, いる, ある, や, この, これ, よう, その, なる, なら, という, それ, ても, 何, れる, 私, ため, あり, もの, へ, ので, として, など, られ, できる, なり, たり, たち, られる, について, とき, そして, ください, お願いします
  markers (118): ない, なく, なし, なかっ, なけれ, 無い, 無く, 無し, ず, ぬ, ん, まい, な, 不要, 決して, オン, オフ, 有効, 無効, 開始, 起動, 始める, 始め, 始めろ, 停止, 止める, 止め, 止めろ, 止まる, 止まり, 止まれ, やめる, やめ, やめろ, 中止, 中断, 見せる, 見せ, 見せろ, 隠す, 隠し, 隠せ, 消す, 消し, 消せ, ミュート, 解除, 消音, 入れる, 入れ, 入れろ, 切る, 切り, 切れ, 休止, 再開, 続ける, 続け, 続けろ, 変更, 変える, 変え, 変えろ, 変わる, 変わり, 調整, 調節, 切り替える, 切り替え, 切り替えろ, 切替, 切替え, もっと, 多く, 多い, 少なく, 少ない, 大きく, 大きい, 小さく, 小さい, 速く, 速い, 早く, 早い, 遅く, 遅い, 高く, 高い, 低く, 低い, 静か, 大きめ, 小さめ, 多め, 少なめ, 上, 下, 上げる, 上げ, 上げろ, 下げる, 下げ, 下げろ, 増やす, 増やし, 増やせ, 減らす, 減らし, 減らせ, もう, 再び, 再度, 繰り返す, 繰り返し, 繰り返せ, やり直す, やり直し
- `ko` stop (32): 이, 을, 에, 의, 가, 를, 들, 에서, 으로, 나, 로, 과, 것, 그, 와, 제, 우리, 에게, 네, 저, 등, 그리고, 및, 너, 이런, 해요, 자신, 제가, 저는, 나는, 좀요, 부탁해요
  markers (133): 안, 못, 아니, 아니다, 아닌, 아니야, 아니요, 아니에요, 아닙니다, 않다, 않게, 않아, 않아요, 않는, 않고, 않도록, 않습니다, 없다, 없이, 없는, 없어, 없어요, 없습니다, 아무, 아무런, 아무것도, 절대, 절대로, 전혀, 말고, 말아, 말아요, 말아줘, 말아주세요, 마, 마세요, 켜다, 켜, 켜줘, 켜주세요, 켜기, 켜고, 켜면, 켜져, 켜지다, 끄다, 꺼, 꺼줘, 꺼주세요, 끄기, 끄는, 끄고, 끄면, 끄지, 꺼져, 꺼지다, 활성화하다, 활성화해, 활성화해주세요, 비활성화하다, 비활성화해, 비활성화해주세요, 시작하다, 시작해, 시작해주세요, 중지하다, 중지해, 중지해주세요, 멈추다, 멈춰, 멈춰줘, 멈춰주세요, 멈추기, 멈추는, 멈추면, 멈추게, 그만, 그만해, 보여주다, 보여줘, 보여주세요, 보이게, 숨기다, 숨겨, 숨겨줘, 숨겨주세요, 음소거하다, 음소거해, 음소거해주세요, 해제하다, 해제해, 해제해주세요, 일시정지하다, 일시정지해, 재개하다, 재개해, 바꾸다, 바꿔, 바꿔줘, 바꿔주세요, 바꾸기, 바꾸는, 변경하다, 변경해, 변경해줘, 변경해주세요, 조정하다, 조정해, 전환하다, 전환해, 더, 덜, 크게, 작게, 큰, 작은, 빠르게, 느리게, 빨리, 천천히, 조용히, 조용하게, 위로, 아래로, 다시, 또, 높여, 낮춰, 늘려, 줄여, 올려, 내려, 키워
- `lt` stop (42): ir, kad, su, tai, kaip, ar, o, savo, bet, apie, jis, pat, kas, prie, nes, arba, ji, kur, pagal, mes, mano, kuris, man, jums, tarp, jus, kuri, gal, tiesiog, pats, ta, tas, toks, mums, taigi, kodel, kodėl, juk, pas, tokia, prašau, norėčiau
  markers (139): ne, nė, nėra, nebėra, be, niekada, niekad, niekas, nieko, niekam, nieką, nieku, niekame, joks, jokia, jokio, jokios, jokiam, jokiai, jokį, jokią, jokiu, jokioje, jokiame, jokie, jokių, jokiems, jokioms, jokius, jokias, jokiais, jokiomis, jokiuose, jokiose, įjungti, įjunk, įjunkite, įjungiu, įjungi, įjungia, įjungtas, įjungta, neįjungti, neįjunk, neįjunkite, išjungti, išjunk, išjunkite, išjungiu, išjungi, išjungia, išjungtas, išjungta, neišjungti, neišjunk, neišjunkite, įgalinti, įgalink, įgalinkite, deaktyvuoti, deaktyvuok, deaktyvuokite, pradėti, pradėk, pradėkite, sustabdyti, sustabdyk, sustabdykite, sustabdo, nesustabdyti, nesustabdyk, nesustabdykite, stabdyti, stabdyk, stabdykite, sustoti, sustok, sustokite, rodyti, rodyk, rodykite, nerodyti, nerodyk, nerodykite, slėpti, slėpk, slėpkite, nutildyti, nutildyk, nutildykite, atildyti, atildyk, atildykite, pristabdyti, pristabdyk, pristabdykite, tęsti, tęsk, tęskite, keisti, keisk, keiskite, keičiu, keiti, keičia, pakeisti, pakeisk, pakeiskite, nekeisti, nekeisk, nekeiskite, nepakeisti, nepakeisk, nepakeiskite, reguliuoti, reguliuok, reguliuokite, perjungti, perjunk, perjunkite, daugiau, mažiau, garsiau, tyliau, greičiau, lėčiau, didesnis, didesnė, didesnį, didesnę, mažesnis, mažesnė, mažesnį, mažesnę, aukštyn, žemyn, aukščiau, žemiau, vėl
- `lv` stop (40): un, ir, ar, par, ka, ari, arī, vai, bet, ta, tā, lai, bija, var, bus, būs, jo, gan, nu, esmu, kaut, pa, tiek, pat, but, būt, tacu, taču, tika, tapec, tāpēc, esi, tomer, tomēr, te, starp, esam, es, man, lūdzu
  markers (133): ne, nē, nav, bez, nekad, nekas, nekā, nekam, neko, neviena, neviens, nevienam, nevienai, nevienu, nevienā, nevieni, nevienas, nevieniem, nevienām, nevienus, nevienos, nevienās, nekāds, nekāda, nekādam, nekādai, nekādu, nekādā, nekādi, nekādas, nekādiem, nekādām, nekādus, nekādos, nekādās, ieslēgt, ieslēdz, ieslēdziet, ieslēdzu, ieslēgts, ieslēgta, neieslēgt, neieslēdz, neieslēdziet, izslēgt, izslēdz, izslēdziet, izslēdzu, izslēgts, izslēgta, neizslēgt, neizslēdz, neizslēdziet, iespējot, iespējo, iespējojiet, atspējot, atspējo, atspējojiet, sākt, sāc, sāciet, apturēt, apturi, apturiet, aptur, neapturēt, neapturi, neapturiet, apstāties, apstājies, apstājieties, apstājas, pārtraukt, pārtrauc, pārtrauciet, rādīt, rādi, rādiet, nerādīt, nerādi, nerādiet, paslēpt, paslēp, paslēpiet, apklusināt, apklusini, apklusiniet, atklusināt, atklusini, atklusiniet, pauzēt, pauzē, pauzējiet, atsākt, atsāc, atsāciet, mainīt, maini, mainiet, maina, nemainīt, nemaini, nemainiet, nomainīt, nomaini, nomainiet, pielāgot, pielāgo, pielāgojiet, pārslēgt, pārslēdz, pārslēdziet, vairāk, mazāk, skaļāk, klusāk, ātrāk, lēnāk, lielāks, lielāka, lielāku, mazāks, mazāka, mazāku, augšup, lejup, augšā, lejā, augšu, leju, atkal, vēlreiz
- `mt` stop (23): il, l, u, ta, tal, tat, li, għal, lil, jien, inti, hu, hija, aħna, intom, huma, dan, din, dak, dik, jekk, jogħġbok, nixtieq
  markers (113): le, mhux, mhix, mhumiex, mhuwiex, m'huwiex, m'hijiex, m'iniex, m'intix, m'aħniex, m'intomx, m'għandix, m'għandekx, m'għandux, m'għandhiex, m'għandniex, m'għandkomx, m'għandhomx, mingħajr, bla, qatt, xejn, ebda, ħadd, la, ixgħel, ixegħlu, ixgħelha, ixgħelhom, tixgħel, jixgħel, mixgħul, mixgħula, itfi, itfu, itfiha, itfih, itfihom, titfi, jitfi, mitfi, mitfija, attiva, attivaw, iddiżattiva, iddiżattivaw, ibda, ibdew, tibda, waqqaf, waqqfu, waqqafha, waqqfuha, waqqafhom, twaqqaf, jwaqqaf, ieqaf, ieqfu, tieqaf, jieqaf, uri, uru, aħbi, aħbu, sikket, sikktu, ippawża, ippawżaw, kompli, komplu, biddel, biddlu, biddilha, biddluha, biddilhom, tbiddel, jibdel, aġġusta, aġġustaw, aqleb, aqilbu, aktar, iktar, iżjed, inqas, ogħla, baxx, baxxa, akbar, iżgħar, fuq, isfel, erġa', erġgħu, jerġa', terġa', nerġa', nerġgħu, terġgħu, jerġgħu, mill-ġdid, malajr, bil-mod, għaġġel, għaġġlu, għolli, għollu, niżżel, niżżlu, kabbar, kabbru, ċekken, ċekknu
- `nl` stop (91): de, van, het, een, en, ik, dat, voor, je, te, met, zijn, er, maar, om, hij, ook, ze, door, naar, bij, dit, wat, heeft, of, deze, hebben, kan, zo, mijn, wel, u, wordt, heb, worden, haar, ben, kunnen, me, moet, hoe, ons, waar, werd, onze, wil, zich, zou, doen, dus, maken, mij, had, hun, zal, jij, moeten, wij, daar, toch, zij, zoals, iets, omdat, waren, hem, jullie, ja, wie, waarom, via, gewoon, bent, maakt, willen, iedereen, iemand, uw, werden, zelf, hebt, kunt, mag, doet, want, zeker, zullen, misschien, alstublieft, alsjeblieft, graag
  markers (110): niet, nee, geen, zonder, nooit, niks, niets, aan, uit, inschakelen, uitschakelen, schakel, schakelt, schakelen, aanzetten, uitzetten, activeren, activeer, deactiveren, deactiveer, start, starten, begin, begint, beginnen, stop, stoppen, stopt, beëindigen, beëindig, onderbreken, onderbreek, toon, tonen, toont, weergeven, verberg, verbergen, verbergt, dempen, demp, ontdempen, ontdemp, mute, muten, unmute, unmuten, pauzeren, pauzeer, hervatten, hervat, doorgaan, verdergaan, wijzigen, wijzig, wijzigt, veranderen, verander, verandert, aanpassen, bijstellen, wisselen, wissel, omschakelen, overschakelen, meer, minder, luider, luidere, harder, hardere, zachter, zachtere, stiller, stillere, sneller, snellere, langzamer, langzamere, trager, tragere, groter, grotere, kleiner, kleinere, hoger, hogere, lager, lagere, omhoog, omlaag, neer, beneden, opnieuw, weer, nogmaals, verhogen, verhoog, verlagen, verlaag, vergroten, vergroot, verkleinen, verklein, verminderen, verminder, versnellen, versnel, vertragen, vertraag
- `pl` stop (131): w, i, na, sie, się, do, jest, ze, że, o, jak, ale, co, tak, dla, tym, czy, przez, tego, sa, są, ma, mi, mnie, moze, może, bo, ja, ten, oraz, bedzie, będzie, byc, być, jego, sobie, ich, mam, tez, też, był, ktore, które, jako, jestem, było, jej, ktory, który, nawet, go, no, cos, coś, ci, tam, te, wiec, więc, gdzie, tej, zeby, żeby, jednak, lub, mozna, można, przy, nas, takze, także, tu, była, u, tych, rowniez, również, ta, takie, ktos, ktoś, kto, ktora, która, aby, albo, ty, maja, mają, ktorzy, którzy, dlaczego, nich, mu, mamy, chce, chcę, je, temu, tutaj, został, beda, będą, były, nam, ktorych, których, taki, swoje, dlatego, ktorym, którym, miał, moje, moj, mój, ok, trzeba, nim, ciebie, moga, mogą, oni, cie, cię, ktorej, której, moja, ona, jakie, proszę
  markers (132): nie, bez, nigdy, nic, niczego, niczemu, niczym, żaden, żadna, żadne, żadnego, żadnej, żadnemu, żadną, żadnym, żadni, żadnych, żadnymi, włącz, włączcie, włączyć, włączać, włączaj, włączajcie, włącza, włączam, włączasz, włączony, włączona, włączone, wyłącz, wyłączcie, wyłączyć, wyłączać, wyłączaj, wyłączajcie, wyłącza, wyłączam, wyłączasz, wyłączony, wyłączona, wyłączone, aktywuj, aktywować, dezaktywuj, dezaktywować, uruchom, uruchomić, zacznij, zacząć, stop, zatrzymaj, zatrzymajcie, zatrzymać, zatrzymywać, zatrzymuj, zatrzymujcie, zatrzymuje, zatrzyma, przerwij, przerwijcie, przerwać, przerywać, przerywaj, przerywajcie, pokaż, pokazać, ukryj, ukryć, wycisz, wyciszyć, odcisz, odciszyć, wstrzymaj, wstrzymać, pauzuj, pauzować, wznów, wznowić, zmień, zmieńcie, zmienić, zmieniać, zmieniaj, zmieniajcie, zmienia, zmieniam, zmieniasz, dostosuj, dostosować, reguluj, regulować, przełącz, przełączyć, przełączać, więcej, mniej, głośniej, ciszej, szybciej, wolniej, większy, większa, większe, większego, większej, większą, większym, mniejszy, mniejsza, mniejsze, mniejszego, mniejszej, mniejszą, mniejszym, górę, dół, wyżej, niżej, ponownie, znów, znowu, zwiększ, zwiększyć, zmniejsz, zmniejszyć, ścisz, ściszyć, przyspiesz, przyspieszyć, zwolnij, zwolnić
- `pt` stop (106): a, e, um, de, o, que, do, em, da, uma, no, na, por, os, eu, como, dos, mas, foi, ao, me, voce, você, ser, seu, sua, tem, sao, são, das, ou, ele, isso, nos, tambem, também, esta, está, meu, pelo, ela, vai, pela, sobre, bem, mesmo, pode, te, ter, aqui, fazer, minha, quem, entre, era, seus, nas, assim, este, onde, estao, estão, esse, essa, eles, ha, há, porque, tenho, foram, aos, coisa, sou, suas, quero, sei, entao, então, nossa, faz, qual, quer, estou, seja, sera, será, la, lá, qualquer, sim, sendo, diz, sabe, tinha, dar, ir, boa, estava, nosso, deve, podem, estar, dizer, favor, poderia, gostaria
  markers (136): não, nao, sem, nunca, jamais, nada, nenhum, nenhuma, nenhuns, nenhumas, nem, ativar, ativa, ative, ativem, desativar, desativa, desative, desativem, activar, activa, active, desactivar, desactiva, desactive, habilitar, habilita, habilite, desabilitar, desabilita, desabilite, ligar, liga, ligue, ligo, ligas, ligam, liguem, ligado, ligada, ligados, ligadas, desligar, desliga, desligue, desligo, desligas, desligam, desliguem, desligado, desligada, desligados, desligadas, iniciar, inicia, inicie, começar, começa, comece, parar, para, pare, paro, paras, param, parem, interromper, interrompe, interrompa, mostrar, mostra, mostre, ocultar, oculta, oculte, silenciar, silencia, silencie, mutar, muta, mute, desmutar, desmuta, desmute, pausar, pausa, pause, retomar, retoma, retome, mudar, muda, mude, mudo, mudas, mudam, mudem, alterar, altera, altere, alteram, alterem, ajustar, ajusta, ajuste, trocar, troca, troque, alternar, alterna, alterne, mais, menos, maior, maiores, menor, menores, alto, alta, baixo, baixa, rápido, rápida, devagar, lento, lenta, cima, acima, abaixo, novamente, aumentar, aumenta, aumente, diminuir, diminui, diminua
- `ro` stop (110): de, si, și, la, sa, să, din, o, pe, cu, un, este, ca, care, pentru, se, au, ce, fost, al, am, sunt, fi, va, lui, dar, sau, i, ne, ar, le, poate, prin, cum, ale, despre, era, are, l, cel, cele, noi, el, ei, dintre, te, face, pot, chiar, vor, asa, așa, acest, bine, mi, catre, către, unui, avea, ma, mă, unde, cea, eu, unei, intre, între, în, aceasta, ii, îi, asta, ceea, avut, lor, il, îl, d, aici, m, astfel, ea, orice, ceva, acesta, dat, unor, avem, sale, isi, își, mea, ori, voi, insa, însă, ti, ți, aceste, acolo, mine, imi, îmi, da, acestea, nostru, rog, vreau, aș, vă
  markers (124): nu, fără, fara, nici, niciodată, niciodata, nimic, niciun, nicio, niciunui, niciunei, niciunor, niciunul, niciuna, niciunii, niciunele, niciunuia, niciuneia, niciunora, activează, activeaza, activa, activați, activati, dezactivează, dezactiveaza, dezactiva, dezactivați, dezactivati, pornește, porneste, porni, pornesc, pornești, pornesti, porniți, porniti, pornit, pornită, pornita, oprește, opreste, opri, opresc, oprești, opresti, opriți, opriti, oprit, oprită, oprita, începe, incepe, începeți, incepeti, stop, încetează, inceteaza, înceta, inceta, încetați, incetati, arată, arata, arătați, aratati, ascunde, ascundeți, ascundeti, silențiază, silentiaza, silențiați, silentiati, suspendă, suspenda, suspendați, suspendati, reia, relua, reluați, reluati, schimbă, schimba, schimb, schimbi, schimbăm, schimbam, schimbați, schimbati, modifică, modifica, modifici, modificați, modificati, ajustează, ajusteaza, ajusta, ajustați, ajustati, comută, comuta, comutați, comutati, mai, mult, puțin, putin, tare, încet, incet, repede, rapid, lent, mare, mic, sus, jos, iar, iarăși, iarasi, mărește, mareste, micșorează, micsoreaza
- `ru` stop (102): в, и, на, с, что, я, по, а, как, из, это, за, для, о, к, но, то, у, его, он, от, так, же, мы, ты, был, было, мне, меня, бы, или, их, они, будет, кто, чтобы, есть, она, во, вы, может, были, со, была, также, вот, её, быть, где, этом, вас, можно, того, этого, том, ну, нас, об, которые, себя, этот, который, ли, тебя, надо, ему, них, тоже, почему, тем, эти, им, этой, потому, нужно, себе, такой, тебе, него, однако, свою, нам, своей, вам, мой, которых, свои, какой, тот, сделать, конечно, которая, которой, такое, хотя, чего, ведь, будут, спасибо, эта, могут, пожалуйста
  markers (131): не, нет, нету, без, никогда, ни, никакой, никакая, никакое, никакие, никакого, никакому, никаким, никаком, никакую, никакою, никаких, никакими, ничто, ничего, ничему, ничем, ничём, включить, включи, включите, включать, включай, включайте, включен, включён, включена, включено, включены, выключить, выключи, выключите, выключать, выключай, выключайте, выключен, выключён, выключена, выключено, выключены, отключить, отключи, отключите, отключать, отключай, отключайте, отключено, запустить, запусти, запустите, начать, начни, начните, остановить, останови, остановите, останавливать, останавливай, останавливайте, остановиться, остановись, остановитесь, прекратить, прекрати, прекратите, перестать, перестань, перестаньте, стоп, показать, покажи, покажите, скрыть, скрой, скройте, заглушить, заглуши, заглушите, приостановить, приостанови, приостановите, продолжить, продолжи, продолжите, возобновить, возобнови, возобновите, изменить, измени, измените, изменять, изменяй, изменяйте, менять, меняй, меняйте, поменять, поменяй, поменяйте, отрегулировать, отрегулируй, отрегулируйте, переключить, переключи, переключите, больше, меньше, громче, тише, быстрее, медленнее, крупнее, мельче, вверх, вниз, выше, ниже, снова, опять, заново, побольше, поменьше, погромче, потише, побыстрее, помедленнее
- `sk` stop (105): v, sa, na, je, že, ako, aj, o, si, som, ale, za, tak, od, čo, bol, pre, sú, k, alebo, sme, ich, vo, aby, ktorý, ktoré, ma, jeho, bola, bude, ktorá, bolo, byť, vám, jej, so, ho, i, zo, mi, však, ste, kde, boli, môže, nás, vás, no, tiež, tým, toho, tom, či, ju, ja, tento, nám, niečo, preto, možno, pretože, tomu, mať, mu, mali, teda, ten, toto, u, svoje, asi, ktorú, tejto, takže, ktorej, lebo, mám, tie, svoju, nich, ktorých, máte, môžete, kto, majú, mala, ktorí, budú, musí, tieto, mňa, svoj, vaše, prečo, máme, túto, ku, tohto, tomto, budete, naše, svojho, táto, prosím, ďakujem
  markers (132): nie, ani, bez, nikdy, nič, ničoho, ničomu, ničom, ničím, žiadny, žiadna, žiadne, žiadneho, žiadnemu, žiadnom, žiadnym, žiadnej, žiadnu, žiadnou, žiadni, žiadnych, žiadnymi, nijaký, nijaká, nijaké, nijakého, nijakému, nijakom, nijakým, nijakej, nijakú, nijakou, nijakí, nijakých, nijakými, zapnúť, zapni, zapnite, zapínať, zapínaj, zapínajte, zapnutý, zapnutá, zapnuté, vypnúť, vypni, vypnite, vypínať, vypínaj, vypínajte, vypnutý, vypnutá, vypnuté, povoliť, povoľ, povoľte, zakázať, zakáž, zakážte, spustiť, spusti, spustite, začať, začni, začnite, zastaviť, zastav, zastavte, zastavovať, zastavuj, zastavujte, prestať, prestaň, prestaňte, stop, zobraziť, zobraz, zobrazte, ukázať, ukáž, ukážte, skryť, skry, skryte, stlmiť, stlm, stlmte, odtlmiť, odtlm, odtlmte, pozastaviť, pozastav, pozastavte, pokračovať, pokračuj, pokračujte, obnoviť, obnov, obnovte, zmeniť, zmeň, zmeňte, meniť, meň, meňte, upraviť, uprav, upravte, prepnúť, prepni, prepnite, viac, menej, hlasnejšie, tichšie, rýchlejšie, pomalšie, väčší, väčšia, väčšie, menší, menšia, menšie, hore, dole, nahor, nadol, vyššie, nižšie, znova, znovu, opäť
- `sl` stop (61): je, v, na, se, da, so, za, pa, tudi, lahko, kot, iz, bi, bo, od, tako, ali, o, bil, jih, kar, ga, si, smo, bila, sem, saj, ta, tega, jo, bilo, bodo, ker, kjer, sta, kaj, naj, vam, kako, nas, mi, te, k, boste, nam, vendar, bomo, vas, mu, bili, seveda, ti, ste, jim, mora, biti, me, sicer, tam, prosim, hvala
  markers (142): ne, ni, nisem, nisi, nisva, nista, nismo, niste, niso, brez, nikoli, nikdar, nič, ničesar, ničemur, ničemer, ničimer, noben, nobeden, nobena, nobeno, nobenega, nobenemu, nobenem, nobenim, nobene, nobeni, nobenih, nobenimi, nobenima, nikakršen, nikakršna, nikakršno, nikakršnega, nikakršnemu, nikakršnem, nikakršnim, nikakršne, nikakršni, nikakršnih, nikakršnimi, nikakršnima, vklopiti, vklopi, vklopite, vklapljati, vklapljaj, vklapljajte, vklopljen, vklopljena, vklopljeno, izklopiti, izklopi, izklopite, izklapljati, izklapljaj, izklapljajte, izklopljen, izklopljena, izklopljeno, omogočiti, omogoči, omogočite, onemogočiti, onemogoči, onemogočite, začeti, začni, začnite, zagnati, zaženi, zaženite, ustaviti, ustavi, ustavite, ustavljati, ustavljaj, ustavljajte, prenehati, prenehaj, prenehajte, stop, pokazati, pokaži, pokažite, prikazati, prikaži, prikažite, skriti, skrij, skrijte, utišati, utišaj, utišajte, odtišati, odtišaj, odtišajte, zaustaviti, zaustavi, zaustavite, nadaljevati, nadaljuj, nadaljujte, spremeniti, spremeni, spremenite, spreminjati, spreminjaj, spreminjajte, zamenjati, zamenjaj, zamenjajte, menjati, menjaj, menjajte, prilagoditi, prilagodi, prilagodite, preklopiti, preklopi, preklopite, več, manj, glasneje, tišje, hitreje, počasneje, večji, večja, večje, manjši, manjša, manjše, gor, dol, navzgor, navzdol, višje, nižje, znova, spet, ponovno
- `sv` stop (85): är, det, att, och, i, jag, en, som, med, har, så, till, de, ett, kan, vi, men, man, var, ska, vad, från, mig, eller, han, hur, kommer, vill, sig, vara, där, får, finns, ha, skulle, min, dig, hade, ju, gör, få, blir, göra, detta, ni, också, hon, måste, även, någon, något, bli, kanske, vid, varför, din, sin, väl, fick, oss, varit, mitt, blev, dom, själv, några, denna, tack, mina, vilket, genom, hans, dessa, er, sina, sitt, gjort, kunna, kunde, ditt, fått, gjorde, honom, vem, snälla
  markers (90): inte, nej, utan, aldrig, ingen, inget, inga, ingens, ingets, ingas, ingenting, ej, på, av, aktivera, aktiverar, inaktivera, inaktiverar, avaktivera, avaktiverar, starta, startar, stoppa, stoppar, stopp, sluta, slutar, stäng, stänga, stänger, visa, visar, dölj, dölja, döljer, göm, gömma, gömmer, tysta, tystar, avmuta, avmutar, pausa, pausar, fortsätt, fortsätta, fortsätter, återuppta, återupptar, ändra, ändrar, justera, justerar, anpassa, anpassar, byt, byta, byter, växla, växlar, mer, mera, mindre, fler, färre, högre, lägre, högljuddare, tystare, snabbare, långsammare, större, upp, ner, ned, uppåt, neråt, nedåt, igen, återigen, öka, ökar, minska, minskar, höj, höja, höjer, sänk, sänka, sänker
- `tr` stop (74): ve, bir, bu, için, de, da, ile, ne, gibi, olarak, o, olan, ben, ama, ya, sen, ise, oldu, bile, nasıl, şey, benim, böyle, mı, seni, beni, bana, tarafından, veya, biz, olduğunu, diye, kendi, olduğu, olur, şu, sana, neden, olmak, çünkü, ancak, biri, bunu, işte, olsun, öyle, senin, siz, bizim, bunun, eden, onu, hem, yani, ayrıca, etti, ilgili, yapılan, bize, fakat, kim, mu, sizin, ediyor, lütfen, burada, onun, üzere, bizi, gerek, sizi, mi, mü, teşekkürler
  markers (142): hayır, değil, değilim, değilsin, değiliz, değilsiniz, değiller, değildir, yok, yoktur, olmadan, asla, hiç, hiçbir, hiçbiri, hiçbirini, hiçbirine, hiçbirinin, hiçbirinde, hiçbirinden, hiçbiriyle, hiçbirisi, hiçbirisini, hiçbirisine, hiçbirisinin, hiçbirisinde, hiçbirisinden, olmasın, olmaz, aç, açmak, açın, açınız, açık, açma, açmamak, açmayın, açmayınız, açmasın, açılmasın, kapat, kapatmak, kapatın, kapatınız, kapalı, kapatma, kapatmamak, kapatmayın, kapatmayınız, kapatmasın, kapatılmasın, etkinleştir, etkinleştirmek, etkinleştirin, etkinleştirme, etkinleştirmeyin, etkisizleştir, etkisizleştirmek, etkisizleştirin, etkisizleştirme, etkisizleştirmeyin, başlat, başlatmak, başlatın, başlatma, başlatmayın, başla, başlamak, başlayın, başlama, başlamayın, durdur, durdurmak, durdurun, durdurunuz, durdurma, durdurmayın, durdurmasın, durdurulmasın, dur, durmak, durun, durunuz, durma, durmayın, dursun, durmasın, durunca, göster, göstermek, gösterin, gösterme, göstermeyin, gizle, gizlemek, gizleyin, gizleme, gizlemeyin, sustur, susturmak, susturun, susturma, susturmayın, duraklat, duraklatmak, duraklatın, duraklatma, duraklatmayın, devam, sürdür, sürdürmek, sürdürün, sürdürme, sürdürmeyin, değiştir, değiştirmek, değiştirin, değiştiriniz, değiştirme, değiştirmeyin, değiştirilmesin, değişsin, değişmesin, ayarla, ayarlamak, ayarlayın, geç, geçmek, geçin, daha, fazla, az, yüksek, düşük, hızlı, yavaş, büyük, küçük, yukarı, aşağı, tekrar, yeniden
- `uk` stop (49): з, що, та, це, як, про, для, від, так, але, він, є, ви, ми, і, було, вони, із, чи, який, ти, був, її, також, їх, де, б, вона, те, бути, цей, була, були, вас, вам, навіть, от, нам, чого, такий, в, у, на, й, я, мені, будь, ласка, дякую
  markers (142): не, ні, ані, немає, нема, без, ніколи, ніщо, нічого, нічому, нічим, жоден, жодний, жодна, жодне, жодні, жодного, жодному, жодним, жоднім, жодній, жодну, жодною, жодних, жодними, ніякий, ніяка, ніяке, ніякі, ніякого, ніякому, ніяким, ніякім, ніякій, ніяку, ніякою, ніяких, ніякими, увімкнути, увімкни, увімкніть, увімкнено, вмикати, вмикай, вмикайте, вимкнути, вимкни, вимкніть, вимкнено, вимикати, вимикай, вимикайте, відключити, відключи, відключіть, запустити, запусти, запустіть, почати, почни, почніть, зупинити, зупини, зупиніть, зупиняти, зупиняй, зупиняйте, зупинитися, зупинись, зупинися, зупиніться, зупинятися, припинити, припини, припиніть, припиняти, припиняй, припиняйте, перестати, перестань, перестаньте, стоп, показати, покажи, покажіть, приховати, приховай, приховайте, заглушити, заглуши, заглушіть, призупинити, призупини, призупиніть, продовжити, продовж, продовжте, продовжувати, продовжуй, продовжуйте, відновити, віднови, відновіть, змінити, зміни, змініть, змінювати, змінюй, змінюйте, поміняти, поміняй, поміняйте, міняти, міняй, міняйте, відрегулювати, відрегулюй, відрегулюйте, перемкнути, перемкни, перемкніть, більше, менше, гучніше, тихіше, швидше, повільніше, більший, більша, більші, менший, менша, менші, вгору, угору, вниз, вище, нижче, знову, знов, наново, повторно
- `vi` stop (47): là, và, của, được, này, với, ở, để, như, nhưng, làm, sẽ, họ, tại, đó, cũng, sự, tôi, bị, phải, ông, mà, thì, việc, mình, bạn, theo, anh, đây, nên, vì, nó, cần, đang, biết, do, nào, vậy, hoặc, rằng, gì, muốn, cái, em, xin, vui, lòng
  markers (47): không, ko, k, chẳng, chả, chưa, đừng, bật, tắt, mở, đóng, dừng, ngừng, ngưng, chạy, bắt, đầu, hiện, ẩn, giấu, tạm, tiếp, tục, đổi, thay, sửa, chỉnh, chuyển, thêm, bớt, nhiều, ít, hơn, to, nhỏ, lớn, nhanh, chậm, tăng, giảm, lên, xuống, lại, nữa, cao, thấp, bé
- `zh` stop (77): 的, 是, 在, 了, 我, 和, 也, 你, 为, 他, 这, 与, 对, 就, 个, 说, 吗, 我们, 会, 要, 来, 被, 他们, 而, 可以, 但, 于, 什么, 这个, 将, 并, 能, 让, 从, 以, 她, 着, 自己, 给, 把, 去, 或, 因为, 之, 做, 及, 地, 由, 怎么, 用, 就是, 这些, 得, 所, 这样, 它, 那, 可, 吧, 其, 该, 啊, 们, 却, 但是, 谁, 以及, 你们, 为了, 所以, 跟, 请, 为什么, 呢, 如何, 其中, 谢谢
  markers (123): 不, 没, 沒, 没有, 沒有, 别, 別, 不是, 无, 無, 不要, 不用, 从不, 從不, 从未, 從未, 从来不, 從來不, 从来没有, 從來沒有, 从来没, 從來沒, 并不, 並不, 并非, 並非, 无需, 無需, 不必, 毫无, 毫無, 都不, 都没, 都沒, 关, 關, 开, 開, 关闭, 關閉, 关掉, 關掉, 开启, 開啟, 打开, 打開, 启用, 啟用, 禁用, 停用, 启动, 啟動, 开始, 開始, 停止, 停, 停下, 显示, 顯示, 隐藏, 隱藏, 静音, 靜音, 取消, 解除, 暂停, 暫停, 继续, 繼續, 恢复, 恢復, 改变, 改變, 更改, 修改, 改, 调整, 調整, 调节, 調節, 调, 調, 切换, 切換, 换, 換, 多, 少, 更多, 更少, 更, 大, 小, 更大, 更小, 快, 慢, 更快, 更慢, 响, 響, 响亮, 響亮, 轻, 輕, 高, 低, 上, 下, 向上, 向下, 提高, 降低, 调高, 調高, 调低, 調低, 再, 又, 再次, 重新, 重来, 重來
