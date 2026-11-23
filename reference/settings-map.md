# Settings Map

Generated from the compiled Settings Map and the validated search vocabulary. Do not edit by hand.

- Regenerate: `scripts/settings-map/export.sh`
- Check: `scripts/settings-map/export.sh --check` (CI runs the same comparison)
- Map: [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift); runtime titles: [Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift)
- Interface text: [Sources/EnviousWispr/Resources/Localizable.xcstrings](../Sources/EnviousWispr/Resources/Localizable.xcstrings) (English, German, Spanish and French)
- Search vocabulary: [Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json](../Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json)
- Machine-readable export with every field and all vocabulary: [settings-map.json](settings-map.json)
- Authoring and review: [scripts/settings-map/README.md](../scripts/settings-map/README.md)

The interface ships in English, German, Spanish and French. The other 28 languages (ar, bg, cs, da, el, et, fi, hi, hr, hu, it, ja, ko, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, tr, uk, vi, zh) are search metadata only: words and titles people may type, matched against the same places. Titles below read English / German / Spanish / French.

336 nodes, 307 searchable, 9824 vocabulary blocks.

Fingerprints: mapSHA256 `63f6ecabfce1ce90fea97a979e94b9a257196f62c689ceb5d49a21ba40d3e504`, uiCatalogSHA256 `c867df4403089f1beafa13342b4ef1d69ed37d45cb226418964e8b2aa7cd8392`, vocabularyCanonicalization `length-prefixed-v1`, vocabularySHA256 `be8c74f8bb8765c6c8625fa7f9c2ff2e84ebe08aae4fd1ca66ee38af808ee608`

## Structure

- [EnviousWispr](#node-window-settings) `window.settings` (window)
  - [Search settings / Einstellungen suchen / Buscar en Ajustes / Rechercher](#node-window-search) `window.search` (section)
  - [AI Polish / KI-Nachbearbeitung / Pulido con IA / Retouche IA](#node-page-aiPolish) `page.aiPolish` (page)
    - [Model / Modell / Modelo / Modèle](#node-section-aiPolishModel) `section.aiPolishModel` (section)
      - [(named at runtime by `providerName`)](#node-aiPolishProvider) `aiPolishProvider` (setting)
        - [(named at runtime by `providerSection`)](#node-aiPolish-providerSection) `aiPolish.providerSection` (feature)
          - [Download / Laden / Descargar / Télécharger](#node-localModel-download) `localModel.download` (action)
          - [Cancel / Abbrechen / Cancelar / Annuler](#node-localModel-cancel) `localModel.cancel` (action)
          - [Resume / Fortsetzen / Reanudar / Reprendre](#node-localModel-resume) `localModel.resume` (action)
          - [Resume upgrade / Upgrade fortsetzen / Reanudar la actualización / Reprendre la mise à niveau](#node-localModel-resumeUpgrade) `localModel.resumeUpgrade` (action)
          - [Finish upgrade / Upgrade abschließen / Terminar la actualización / Terminer la mise à niveau](#node-localModel-finishUpgrade) `localModel.finishUpgrade` (action)
          - [Try Again / Erneut versuchen / Intentar de nuevo / Réessayer](#node-localModel-tryAgain) `localModel.tryAgain` (action)
          - [(named at runtime by `localModelTest`)](#node-localModel-testLive) `localModel.testLive` (action)
          - [Tone / Ton / Tono / Ton](#node-s1Tone) `s1Tone` (setting)
            - [Casual / Locker / Informal / Décontracté](#node-s1Tone-casual) `s1Tone.casual` (choice)
            - [Semi-casual / Eher locker / Algo informal / Plutôt décontracté](#node-s1Tone-semiCasual) `s1Tone.semiCasual` (choice)
            - [Semi-formal / Eher förmlich / Semiformal / Plutôt formel](#node-s1Tone-semiFormal) `s1Tone.semiFormal` (choice)
            - [Formal / Förmlich / Formal / Formel](#node-s1Tone-formal) `s1Tone.formal` (choice)
          - [Structure / Struktur / Estructura / Structure](#node-s1Structure) `s1Structure` (setting)
            - [Prose / Fließtext / Prosa / Prose](#node-s1Structure-prose) `s1Structure.prose` (choice)
            - [Lists / Listen / Listas / Listes](#node-s1Structure-lists) `s1Structure.lists` (choice)
          - [Context / Kontext / Contexto / Contexte](#node-s1Context) `s1Context` (setting)
            - [General / Allgemein / General / Général](#node-s1Context-general) `s1Context.general` (choice)
            - [Email / E-Mail / Correo electrónico / E-mail](#node-s1Context-email) `s1Context.email` (choice)
          - [Unload polish model after / Polish-Modell entladen nach / Quitar modelo de Pulido de la RAM tras / Décharger le modèle de retouche après](#node-unloadPolishModel) `unloadPolishModel` (setting)
            - [Never / Nie / Nunca / Jamais](#node-unloadPolishModel-never) `unloadPolishModel.never` (choice)
            - [Immediately / Sofort / Inmediatamente / Immédiatement](#node-unloadPolishModel-immediately) `unloadPolishModel.immediately` (choice)
            - [After 2 minutes / Nach 2 Minuten / Después de 2 minutos / Après 2 minutes](#node-unloadPolishModel-twoMinutes) `unloadPolishModel.twoMinutes` (choice)
            - [After 5 minutes / Nach 5 Minuten / Después de 5 minutos / Après 5 minutes](#node-unloadPolishModel-fiveMinutes) `unloadPolishModel.fiveMinutes` (choice)
            - [After 10 minutes / Nach 10 Minuten / Después de 10 minutos / Après 10 minutes](#node-unloadPolishModel-tenMinutes) `unloadPolishModel.tenMinutes` (choice)
            - [After 15 minutes / Nach 15 Minuten / Después de 15 minutos / Après 15 minutes](#node-unloadPolishModel-fifteenMinutes) `unloadPolishModel.fifteenMinutes` (choice)
            - [After 1 hour / Nach 1 Stunde / Después de 1 hora / Après 1 heure](#node-unloadPolishModel-oneHour) `unloadPolishModel.oneHour` (choice)
          - [OpenAI API Key / OpenAI-API-Schlüssel / Clave de API de OpenAI / Clé d’API OpenAI](#node-apiKey-openAI) `apiKey.openAI` (setting)
          - [Google Gemini API Key / Google Gemini-API-Schlüssel / Clave de API de Google Gemini / Clé API Google Gemini](#node-apiKey-gemini) `apiKey.gemini` (setting)
          - [Claude API Key / Claude-API-Schlüssel / Clave de API de Claude / Clé API Claude](#node-apiKey-claude) `apiKey.claude` (setting)
          - [Save / Sichern / Guardar / Enregistrer](#node-apiKey-save) `apiKey.save` (action)
          - [Clear / Löschen / Borrar / Effacer](#node-apiKey-clear) `apiKey.clear` (action)
          - [(named at runtime by `apiKeyReveal`)](#node-apiKey-reveal) `apiKey.reveal` (action)
          - [(named at runtime by `apiKeyLink`)](#node-apiKey-getKeyLink) `apiKey.getKeyLink` (action)
          - [Model / Modell / Modelo / Modèle](#node-polishModel) `polishModel` (setting)
            - [Prepare model / Modell vorbereiten / Preparar modelo / Préparer le modèle](#node-ollama-prepareModel) `ollama.prepareModel` (action)
            - [Refresh available models / Verfügbare Modelle aktualisieren / Actualizar modelos disponibles / Actualiser les modèles disponibles](#node-polishModel-refresh) `polishModel.refresh` (action)
        - [EG-1](#node-aiPolishProvider-egOne) `aiPolishProvider.egOne` (choice)
          - [Why use EG-1 / Warum EG-1 verwenden? / Por qué usar EG-1 / Pourquoi utiliser EG-1](#node-aiPolish-whyUse-egOne) `aiPolish.whyUse.egOne` (feature)
        - [S1-mini](#node-aiPolishProvider-s1Mini) `aiPolishProvider.s1Mini` (choice)
          - [Why use S1-mini / Warum S1-mini verwenden? / Por qué usar S1-mini / Pourquoi utiliser S1-mini](#node-aiPolish-whyUse-s1Mini) `aiPolish.whyUse.s1Mini` (feature)
        - [Apple Intelligence](#node-aiPolishProvider-appleIntelligence) `aiPolishProvider.appleIntelligence` (choice)
          - [Why use Apple Intelligence / Warum Apple Intelligence verwenden? / Por qué usar Apple Intelligence / Pourquoi utiliser Apple Intelligence](#node-aiPolish-whyUse-appleIntelligence) `aiPolish.whyUse.appleIntelligence` (feature)
            - [About Apple Intelligence / Über Apple Intelligence / Más información sobre Apple Intelligence / À propos d’Apple Intelligence](#node-aiPolish-link-aboutAppleIntelligence) `aiPolish.link.aboutAppleIntelligence` (action)
          - [(named at runtime by `appleIntelligenceStatus`)](#node-appleIntelligence-status) `appleIntelligence.status` (feature)
            - [Check Apple Intelligence availability / Verfügbarkeit von Apple Intelligence prüfen / Comprobar la disponibilidad de Apple Intelligence / Vérifier la disponibilité d’Apple Intelligence](#node-appleIntelligence-recheck) `appleIntelligence.recheck` (action)
        - [Ollama](#node-aiPolishProvider-ollama) `aiPolishProvider.ollama` (choice)
          - [Why use Ollama / Warum Ollama verwenden? / Por qué usar Ollama / Pourquoi utiliser Ollama](#node-aiPolish-whyUse-ollama) `aiPolish.whyUse.ollama` (feature)
            - [Ollama model library / Ollama-Modellbibliothek / Biblioteca de modelos de Ollama / Bibliothèque de modèles Ollama](#node-aiPolish-link-ollamaLibrary) `aiPolish.link.ollamaLibrary` (action)
          - [Download Ollama / Ollama herunterladen / Descargar Ollama / Télécharger Ollama](#node-ollama-downloadOllama) `ollama.downloadOllama` (action)
          - [Start Ollama / Ollama starten / Iniciar Ollama / Démarrer Ollama](#node-ollama-start) `ollama.start` (action)
          - [(named at runtime by `ollamaModelDownload`)](#node-ollama-downloadModel) `ollama.downloadModel` (action)
          - [Cancel / Abbrechen / Cancelar / Annuler](#node-ollama-cancelPull) `ollama.cancelPull` (action)
          - [Server / Server / Servidor / Serveur](#node-ollama-server) `ollama.server` (feature)
          - [Re-check Ollama status / Ollama-Status erneut prüfen / Comprobar de nuevo el estado de Ollama / Vérifier à nouveau l’état d’Ollama](#node-ollama-recheck) `ollama.recheck` (action)
          - [Try Again / Erneut versuchen / Intentar de nuevo / Réessayer](#node-ollama-tryAgain) `ollama.tryAgain` (action)
          - [Download more models / Weitere Modelle laden / Descargar más modelos / Télécharger d’autres modèles](#node-ollama-browseModels) `ollama.browseModels` (action)
        - [OpenAI](#node-aiPolishProvider-openAI) `aiPolishProvider.openAI` (choice)
          - [Why use OpenAI / Warum OpenAI verwenden? / Por qué usar OpenAI / Pourquoi utiliser OpenAI](#node-aiPolish-whyUse-openAI) `aiPolish.whyUse.openAI` (feature)
            - [OpenAI rate limits by tier / OpenAI-Ratenlimits nach Stufe / Límites de uso de OpenAI por nivel / Limites de débit d’OpenAI par niveau](#node-aiPolish-link-openAIRateLimits) `aiPolish.link.openAIRateLimits` (action)
        - [Google Gemini](#node-aiPolishProvider-gemini) `aiPolishProvider.gemini` (choice)
          - [Why use Gemini / Warum Gemini verwenden? / Por qué usar Gemini / Pourquoi utiliser Gemini](#node-aiPolish-whyUse-gemini) `aiPolish.whyUse.gemini` (feature)
            - [Gemini API rate limits by tier / Ratenlimits der Gemini-API nach Nutzungsstufe / Límites de la API de Gemini por nivel / Limites de débit de l’API Gemini par niveau](#node-aiPolish-link-geminiRateLimits) `aiPolish.link.geminiRateLimits` (action)
        - [Claude](#node-aiPolishProvider-claude) `aiPolishProvider.claude` (choice)
          - [Why use Claude / Warum Claude verwenden? / Por qué usar Claude / Pourquoi utiliser Claude](#node-aiPolish-whyUse-claude) `aiPolish.whyUse.claude` (feature)
            - [Claude API rate limits / Claude-API-Ratenlimits / Límites de uso de la API de Claude / Limites de débit de l’API Claude](#node-aiPolish-link-claudeRateLimits) `aiPolish.link.claudeRateLimits` (action)
    - [Enable AI Polish / KI-Nachbearbeitung aktivieren / Activar Pulido con IA / Activer la retouche IA](#node-enableAIPolish) `enableAIPolish` (setting)
    - [Dictation output language / Ausgabesprache für Diktate / Idioma de salida del dictado / Langue du texte dicté](#node-dictationOutputLanguage) `dictationOutputLanguage` (setting)
  - [App Settings / App-Einstellungen / Ajustes de la app / Réglages de l’app](#node-page-appSettings) `page.appSettings` (page)
    - [Appearance / Erscheinungsbild / Aspecto / Apparence](#node-appSettings-tab-appearance) `appSettings.tab.appearance` (feature)
      - [APPEARANCE / ERSCHEINUNGSBILD / ASPECTO / APPARENCE](#node-section-appearance) `section.appearance` (section)
        - [Theme / Design / Tema / Thème](#node-theme) `theme` (setting)
          - [System / System / Sistema / Système](#node-theme-system) `theme.system` (choice)
          - [Light / Hell / Claro / Clair](#node-theme-light) `theme.light` (choice)
          - [Dark / Dunkel / Oscuro / Sombre](#node-theme-dark) `theme.dark` (choice)
        - [Language / Sprache / Idioma / Langue](#node-appLanguage) `appLanguage` (setting)
          - [System default / Systemstandard / Predeterminado del sistema / Par défaut du système](#node-appLanguage-systemDefault) `appLanguage.systemDefault` (choice)
          - [(named at runtime by `appLanguageName`)](#node-appLanguage-shipped) `appLanguage.shipped` (choice)
          - [Relaunch to apply / Zum Übernehmen neu starten / Reiniciar para aplicar / Relancer pour appliquer](#node-appLanguage-relaunch) `appLanguage.relaunch` (action)
        - [Show app in Dock / App im Dock anzeigen / Mostrar la app en el Dock / Afficher l’app dans le Dock](#node-showInDock) `showInDock` (setting)
        - [Update alert in menu bar / Update-Hinweis in der Menüleiste / Aviso de actualización en la barra de menús / Alerte de mise à jour dans la barre des menus](#node-updateAlertInMenuBar) `updateAlertInMenuBar` (setting)
    - [Permissions / Berechtigungen / Permisos / Autorisations](#node-appSettings-tab-permissions) `appSettings.tab.permissions` (feature)
      - [PERMISSIONS / BERECHTIGUNGEN / PERMISOS / AUTORISATIONS](#node-section-permissions) `section.permissions` (section)
        - [Microphone / Mikrofon / Micrófono / Micro](#node-permission-microphone) `permission.microphone` (feature)
          - [Request Access / Zugriff anfordern / Solicitar acceso / Demander l’accès](#node-permission-microphone-request) `permission.microphone.request` (action)
        - [Accessibility / Bedienungshilfen / Accesibilidad / Accessibilité](#node-permission-accessibility) `permission.accessibility` (feature)
          - [Open System Settings / Systemeinstellungen öffnen / Abrir Ajustes del Sistema / Ouvrir Réglages Système](#node-permission-accessibility-openSettings) `permission.accessibility.openSettings` (action)
    - [Privacy / Datenschutz / Privacidad / Confidentialité](#node-appSettings-tab-privacy) `appSettings.tab.privacy` (feature)
      - [PRIVACY / DATENSCHUTZ / PRIVACIDAD / CONFIDENTIALITÉ](#node-section-privacy) `section.privacy` (section)
        - [Share usage metrics / Nutzungsstatistiken teilen / Compartir métricas de uso / Partager les données d’utilisation](#node-shareUsageMetrics) `shareUsageMetrics` (setting)
        - [Send crash reports / Absturzberichte senden / Enviar informes de fallos / Envoyer les rapports de plantage](#node-sendCrashReports) `sendCrashReports` (setting)
          - [Restart now / Jetzt neu starten / Reiniciar ahora / Redémarrer maintenant](#node-sendCrashReports-restart) `sendCrashReports.restart` (action)
        - [What we collect / Was wir erfassen / Qué recopilamos / Ce que nous recueillons](#node-whatWeCollect) `whatWeCollect` (feature)
          - [See details / Details ansehen / Ver detalles / Afficher les détails](#node-whatWeCollect-seeDetails) `whatWeCollect.seeDetails` (action)
    - [Recordings / Aufnahmen / Grabaciones / Enregistrements](#node-appSettings-tab-recordings) `appSettings.tab.recordings` (feature)
      - [Recordings / Aufnahmen / Grabaciones / Enregistrements](#node-section-recordings) `section.recordings` (section)
        - [Save dictation recordings / Diktataufnahmen speichern / Guardar grabaciones de dictado / Enregistrer l’audio des dictées](#node-saveDictationRecordings) `saveDictationRecordings` (setting)
        - [Keep dictation recordings / Diktataufnahmen behalten / Conservar las grabaciones de dictados / Conserver les enregistrements de dictée](#node-dictationRecordingRetention) `dictationRecordingRetention` (setting)
        - [Keep meeting audio / Meeting-Audio behalten / Conservar el audio de las reuniones / Conserver l’audio des réunions](#node-meetingRecordingRetention) `meetingRecordingRetention` (setting)
      - [Storage / Speicher / Almacenamiento / Stockage](#node-section-recordingStorage) `section.recordingStorage` (section)
        - [Storage used / Belegter Speicher / Espacio utilizado / Stockage utilisé](#node-recordingStorageUsage) `recordingStorageUsage` (feature)
        - [Storage warning threshold / Speicherwarnschwelle / Umbral de aviso de almacenamiento / Seuil d’avertissement du stockage](#node-recordingStorageWarningThreshold) `recordingStorageWarningThreshold` (setting)
        - [Past the threshold / Über der Schwelle / Al superar el umbral / Au-delà du seuil](#node-recordingThresholdBehavior) `recordingThresholdBehavior` (setting)
        - [Delete recordings / Aufnahmen löschen / Eliminar grabaciones / Supprimer les enregistrements](#node-deleteRecordings) `deleteRecordings` (feature)
          - [Delete all dictation recordings / Alle Diktataufnahmen löschen / Eliminar todas las grabaciones de dictado / Supprimer tous les enregistrements de dictée](#node-deleteRecordings-dictations) `deleteRecordings.dictations` (action)
          - [Delete all meeting audio / Gesamtes Meeting-Audio löschen / Eliminar todo el audio de las reuniones / Supprimer tout l’audio des réunions](#node-deleteRecordings-meetings) `deleteRecordings.meetings` (action)
    - [Licenses / Lizenzen / Licencias / Licences](#node-appSettings-tab-licenses) `appSettings.tab.licenses` (feature)
      - [ABOUT / INFO / ACERCA DE / À PROPOS](#node-section-about) `section.about` (section)
        - [EnviousWispr · GPLv3 / EnviousWispr · GPLv3 / EnviousWispr · GPLv3 / EnviousWispr · GPLv3](#node-license-gpl) `license.gpl` (feature)
          - [View license / Lizenz ansehen / Ver licencia / Afficher la licence](#node-license-gpl-view) `license.gpl.view` (action)
        - [Third-Party Notices / Hinweise zu Drittanbietern / Avisos de terceros / Mentions légales de tiers](#node-license-notices) `license.notices` (feature)
          - [View notices / Hinweise ansehen / Ver avisos / Afficher les avis](#node-license-notices-view) `license.notices.view` (action)
  - [Dictation Settings / Diktateinstellungen / Ajustes del dictado / Réglages de dictée](#node-page-dictation) `page.dictation` (page)
    - [Engine / Engine / Motor / Moteur](#node-dictation-tab-engine) `dictation.tab.engine` (feature)
      - [TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE / MOTOR DE TRANSCRIPCIÓN / MOTEUR DE TRANSCRIPTION](#node-section-transcriptionEngine) `section.transcriptionEngine` (section)
        - [TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE / MOTOR DE TRANSCRIPCIÓN / MOTEUR DE TRANSCRIPTION](#node-transcriptionEngine) `transcriptionEngine` (setting)
          - [Change / Ändern / Cambiar / Modifier](#node-transcriptionEngine-change) `transcriptionEngine.change` (action)
          - [Keep current engine / Aktuelle Engine beibehalten / Mantener el motor actual / Conserver le moteur actuel](#node-transcriptionEngine-keepCurrent) `transcriptionEngine.keepCurrent` (action)
          - [Re-check Fast model status / Modellstatus von „Schnell“ erneut prüfen / Comprobar de nuevo el estado del modelo Rápido / Vérifier à nouveau l’état du modèle « Rapide »](#node-transcriptionEngine-recheckFast) `transcriptionEngine.recheckFast` (action)
          - [Cancel / Abbrechen / Cancelar / Annuler](#node-fastModel-cancelDownload) `fastModel.cancelDownload` (action)
          - [Resume / Fortsetzen / Reanudar / Reprendre](#node-fastModel-resume) `fastModel.resume` (action)
          - [Try Again / Erneut versuchen / Intentar de nuevo / Réessayer](#node-fastModel-tryAgain) `fastModel.tryAgain` (action)
          - [Set up model / Modell einrichten / Configurar modelo / Configurer le modèle](#node-whisperModel-setUp) `whisperModel.setUp` (action)
          - [Cancel / Abbrechen / Cancelar / Annuler](#node-whisperModel-cancelDownload) `whisperModel.cancelDownload` (action)
          - [Resume / Fortsetzen / Reanudar / Reprendre](#node-whisperModel-resume) `whisperModel.resume` (action)
          - [Remove Model / Modell entfernen / Eliminar modelo / Supprimer le modèle](#node-whisperModel-remove) `whisperModel.remove` (action)
          - [Re-check model status / Modellstatus erneut prüfen / Comprobar de nuevo el estado del modelo / Vérifier à nouveau l’état du modèle](#node-whisperModel-recheck) `whisperModel.recheck` (action)
          - [Try Again / Erneut versuchen / Intentar de nuevo / Réessayer](#node-whisperModel-tryAgain) `whisperModel.tryAgain` (action)
          - [Fast / Schnell / Rápido / Rapide](#node-transcriptionEngine-fast) `transcriptionEngine.fast` (choice)
          - [All Languages / Alle Sprachen / Todos los idiomas / Toutes les langues](#node-transcriptionEngine-allLanguages) `transcriptionEngine.allLanguages` (choice)
      - [APPLIES TO BOTH ENGINES / GILT FÜR BEIDE ENGINES / SE APLICA A AMBOS MOTORES / S’APPLIQUE AUX DEUX MOTEURS](#node-section-engineShared) `section.engineShared` (section)
        - [Stop recording on silence / Aufnahme bei Stille stoppen / Detener la grabación al detectar silencio / Arrêter l’enregistrement en cas de silence](#node-stopOnSilence) `stopOnSilence` (setting)
          - [Pause duration / Pausendauer / Duración de la pausa / Durée de la pause](#node-pauseDuration) `pauseDuration` (setting)
        - [Remove filler words (um, uh, hmm...) / Füllwörter entfernen (ähm, äh, hm...) / Eliminar muletillas (um, uh, mmm...) / Supprimer les mots de remplissage (euh, hum, hmm…)](#node-fillerRemoval) `fillerRemoval` (setting)
        - [Convert spoken emoji (e.g. "thumbs up emoji" → 👍) / Gesprochene Emojis umwandeln (z. B. „thumbs up emoji“ → 👍) / Convertir los emojis dictados (p. ej., “thumbs up emoji” → 👍) / Convertir les émojis dictés (p. ex. « thumbs up emoji » → 👍)](#node-spokenEmoji) `spokenEmoji` (setting)
        - [Spoken punctuation / Gesprochene Satzzeichen / Puntuación por voz / Ponctuation dictée](#node-spokenPunctuation) `spokenPunctuation` (setting)
          - [Start word / Startwort / Palabra de inicio / Mot de début](#node-startWordLanguage) `startWordLanguage` (setting)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-en) `startWordLanguage.en` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-de) `startWordLanguage.de` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-fr) `startWordLanguage.fr` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-es) `startWordLanguage.es` (choice)
            - [(named at runtime by `startWordLanguage`)](#node-startWordLanguage-it) `startWordLanguage.it` (choice)
          - [Start word for / Startwort für / Palabra de inicio para / Mot de début pour](#node-startWordField) `startWordField` (setting)
            - [Save word / Wort sichern / Guardar palabra / Enregistrer le mot](#node-startWord-save) `startWord.save` (action)
            - [Reset / Zurücksetzen / Restablecer / Réinitialiser](#node-startWord-reset) `startWord.reset` (action)
        - [Casual mode / Lockerer Modus / Modo informal / Mode décontracté](#node-casualMode) `casualMode` (setting)
        - [Unload model after / Modell entladen nach / Quitar modelo de RAM tras / Décharger le modèle après](#node-unloadModel) `unloadModel` (setting)
          - [Never / Nie / Nunca / Jamais](#node-unloadModel-never) `unloadModel.never` (choice)
          - [Immediately / Sofort / Inmediatamente / Immédiatement](#node-unloadModel-immediately) `unloadModel.immediately` (choice)
          - [After 2 minutes / Nach 2 Minuten / Después de 2 minutos / Après 2 minutes](#node-unloadModel-twoMinutes) `unloadModel.twoMinutes` (choice)
          - [After 5 minutes / Nach 5 Minuten / Después de 5 minutos / Après 5 minutes](#node-unloadModel-fiveMinutes) `unloadModel.fiveMinutes` (choice)
          - [After 10 minutes / Nach 10 Minuten / Después de 10 minutos / Après 10 minutes](#node-unloadModel-tenMinutes) `unloadModel.tenMinutes` (choice)
          - [After 15 minutes / Nach 15 Minuten / Después de 15 minutos / Après 15 minutes](#node-unloadModel-fifteenMinutes) `unloadModel.fifteenMinutes` (choice)
          - [After 1 hour / Nach 1 Stunde / Después de 1 hora / Après 1 heure](#node-unloadModel-oneHour) `unloadModel.oneHour` (choice)
      - [(named at runtime by `currentEngineHeading`)](#node-currentEngineSection) `currentEngineSection` (feature)
        - [Auto-detect language / Sprache automatisch erkennen / Detectar idioma automáticamente / Détecter automatiquement la langue](#node-autoDetectLanguage) `autoDetectLanguage` (setting)
          - [Reset suggestions / Vorschläge zurücksetzen / Restablecer las sugerencias / Réinitialiser les suggestions](#node-autoDetectLanguage-resetSuggestions) `autoDetectLanguage.resetSuggestions` (action)
        - [(named at runtime by `lockedLanguage`)](#node-lockedLanguage) `lockedLanguage` (setting)
          - [Change / Ändern / Cambiar / Modifier](#node-lockedLanguage-change) `lockedLanguage.change` (action)
        - [Faster Transcription / Schnellere Transkription / Transcripción más rápida / Transcription plus rapide](#node-fasterTranscription) `fasterTranscription` (setting)
    - [Microphone / Mikrofon / Micrófono / Micro](#node-dictation-tab-microphone) `dictation.tab.microphone` (feature)
      - [INPUT &amp; BEHAVIOR / EINGABE &amp; VERHALTEN / ENTRADA Y COMPORTAMIENTO / ENTRÉE ET COMPORTEMENT](#node-section-microphone) `section.microphone` (section)
        - [Input device / Eingabegerät / Dispositivo de entrada / Périphérique d’entrée](#node-inputDevice) `inputDevice` (setting)
          - [Auto / Auto / Automático / Auto](#node-inputDevice-auto) `inputDevice.auto` (choice)
          - [(named at runtime by `inputDeviceName`)](#node-inputDevice-device) `inputDevice.device` (choice)
          - [Mic is on / Mikrofon ist an / Entrada del micrófono / Micro sur](#node-inputSocket) `inputSocket` (setting)
            - [(named at runtime by `inputSocketOption`)](#node-inputSocket-input) `inputSocket.input` (choice)
        - [Media during dictation / Medien beim Diktieren / Contenido multimedia durante el dictado / Audio pendant la dictée](#node-mediaDuringDictation) `mediaDuringDictation` (setting)
          - [Continue / Weiterlaufen lassen / No pausar / Continuer la lecture](#node-mediaDuringDictation-continue) `mediaDuringDictation.continue` (choice)
          - [Lower / Leiser / Bajar / Baisser](#node-mediaDuringDictation-lower) `mediaDuringDictation.lower` (choice)
          - [Mute / Stummschalten / Silenciar / Couper le son](#node-mediaDuringDictation-mute) `mediaDuringDictation.mute` (choice)
          - [Pause / Pausieren / Pausar / Mettre en pause](#node-mediaDuringDictation-pause) `mediaDuringDictation.pause` (choice)
        - [Microphone readiness / Mikrofonbereitschaft / Disponibilidad del micrófono / Disponibilité du micro](#node-micReadiness) `micReadiness` (setting)
          - [Off / Aus / Desactivado / Désactivé](#node-micReadiness-off) `micReadiness.off` (choice)
          - [10 sec / 10 Sek. / 10 s / 10 s](#node-micReadiness-10s) `micReadiness.10s` (choice)
          - [30 sec / 30 Sek. / 30 s / 30 s](#node-micReadiness-30s) `micReadiness.30s` (choice)
          - [60 sec / 60 Sek. / 60 s / 60 s](#node-micReadiness-60s) `micReadiness.60s` (choice)
          - [Always / Immer / Siempre / Toujours](#node-micReadiness-always) `micReadiness.always` (choice)
        - [Warn when the microphone is silent / Bei Mikrofonstille warnen / Avisar si el micrófono está en silencio / Avertir en cas de silence du micro](#node-silentMicWarning) `silentMicWarning` (setting)
        - [Using a Bluetooth microphone? / Verwendest du ein Bluetooth-Mikrofon? / ¿Usas un micrófono Bluetooth? / Vous utilisez un micro Bluetooth ?](#node-bluetoothGuide) `bluetoothGuide` (feature)
          - [Learn more / Mehr erfahren / Más información / En savoir plus](#node-bluetoothGuide-learnMore) `bluetoothGuide.learnMore` (action)
    - [Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct](#node-dictation-tab-livePreview) `dictation.tab.livePreview` (feature)
      - [Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct](#node-section-livePreview) `section.livePreview` (section)
        - [Show words while you speak / Wörter beim Sprechen anzeigen / Mostrar las palabras mientras hablas / Afficher les mots pendant que vous parlez](#node-livePreview) `livePreview` (setting)
          - [(named at runtime by `previewLanguage`)](#node-livePreview-language) `livePreview.language` (action)
          - [Browse downloads / Downloads ansehen / Explorar descargas / Parcourir les téléchargements](#node-livePreview-browseDownloads) `livePreview.browseDownloads` (action)
      - [Preview engine / Vorschau-Engine / Motor de vista previa / Moteur d’aperçu](#node-section-previewEngine) `section.previewEngine` (section)
        - [Preview engine / Vorschau-Engine / Motor de vista previa / Moteur d’aperçu](#node-previewEngine) `previewEngine` (setting)
          - [Change / Ändern / Cambiar / Modifier](#node-previewEngine-change) `previewEngine.change` (action)
          - [Compare engines / Engines vergleichen / Comparar motores / Comparer les moteurs](#node-previewEngine-compare) `previewEngine.compare` (action)
          - [Keep current preview engine / Aktuelle Vorschau-Engine beibehalten / Mantener el motor de vista previa actual / Conserver le moteur d’aperçu actuel](#node-previewEngine-keepCurrent) `previewEngine.keepCurrent` (action)
          - [Apple](#node-previewEngine-apple) `previewEngine.apple` (choice)
          - [Universal / Universal / Universal / Universal](#node-previewEngine-universal) `previewEngine.universal` (choice)
            - [Download / Laden / Descargar / Télécharger](#node-previewEngine-universal-download) `previewEngine.universal.download` (action)
            - [Cancel / Abbrechen / Cancelar / Annuler](#node-previewEngine-universal-cancel) `previewEngine.universal.cancel` (action)
            - [Resume / Fortsetzen / Reanudar / Reprendre](#node-previewEngine-universal-resume) `previewEngine.universal.resume` (action)
            - [Try Again / Erneut versuchen / Intentar de nuevo / Réessayer](#node-previewEngine-universal-retry) `previewEngine.universal.retry` (action)
            - [Remove / Entfernen / Eliminar / Supprimer](#node-previewEngine-universal-remove) `previewEngine.universal.remove` (action)
        - [Languages / Sprachen / Idiomas / Langues](#node-previewLanguages) `previewLanguages` (feature)
          - [(named at runtime by `previewLanguagesInstall`)](#node-previewLanguages-install) `previewLanguages.install` (action)
    - [Recording Pill / Aufnahmeanzeige / Píldora de grabación / Pastille d’enregistrement](#node-dictation-tab-pill) `dictation.tab.pill` (feature)
      - [Recording Pill / Aufnahmeanzeige / Píldora de grabación / Pastille d’enregistrement](#node-section-pill) `section.pill` (section)
        - [Position on screen / Position auf dem Bildschirm / Posición en pantalla / Position à l’écran](#node-pillPosition) `pillPosition` (setting)
          - [Top / Oben / Arriba / En haut](#node-pillPosition-top) `pillPosition.top` (choice)
          - [Bottom / Unten / Abajo / En bas](#node-pillPosition-bottom) `pillPosition.bottom` (choice)
        - [Style / Stil / Estilo / Style](#node-pillStyle) `pillStyle` (setting)
          - [Configure Live Preview / Live-Vorschau einrichten / Configurar la Vista previa en tiempo real / Configurer l’Aperçu en direct](#node-pillStyle-configureLivePreview) `pillStyle.configureLivePreview` (action)
          - [Capsule / Kapsel / Cápsula / Capsule](#node-pillStyle-capsule) `pillStyle.capsule` (choice)
          - [Level Rail / Pegelanzeige / Barra de nivel / Barre de niveau](#node-pillStyle-levelRail) `pillStyle.levelRail` (choice)
          - [Reading Well / Lesefeld / Panel de lectura / Zone de lecture](#node-pillStyle-readingWell) `pillStyle.readingWell` (choice)
    - [Chimes / Signaltöne / Tonos / Sons](#node-dictation-tab-chimes) `dictation.tab.chimes` (feature)
      - [RECORDING CHIMES / AUFNAHMESIGNALTÖNE / SONIDOS DE GRABACIÓN / SONS D’ENREGISTREMENT](#node-section-chimes) `section.chimes` (section)
        - [Play recording chimes / Aufnahmesignaltöne abspielen / Reproducir tonos de grabación / Lire les sons de début et de fin d’enregistrement](#node-recordingChimes) `recordingChimes` (setting)
        - [RECORDING CHIMES / AUFNAHMESIGNALTÖNE / SONIDOS DE GRABACIÓN / SONS D’ENREGISTREMENT](#node-recordingChime) `recordingChime` (setting)
          - [(named at runtime by `chimePreview`)](#node-recordingChime-preview) `recordingChime.preview` (action)
          - [Dust Mote / Staubflöckchen / Mota de polvo / Grain de poussière](#node-recordingChime-dustMote) `recordingChime.dustMote` (choice)
          - [Velvet Hush / Samtflüstern / Susurro aterciopelado / Murmure velouté](#node-recordingChime-velvetHush) `recordingChime.velvetHush` (choice)
          - [Muted Confirm / Leises Okay / Confirmación suave / Confirmation discrète](#node-recordingChime-mutedConfirm) `recordingChime.mutedConfirm` (choice)
          - [Whisper Tick / Flüstertick / Tic de Whisper / Tic Whisper](#node-recordingChime-whisperTick) `recordingChime.whisperTick` (choice)
          - [Round Pebble / Runder Kiesel / Piedra redonda / Galet rond](#node-recordingChime-roundPebble) `recordingChime.roundPebble` (choice)
          - [Paper Tap / Papierklopfen / Golpecito de papel / Tapotement de papier](#node-recordingChime-paperTap) `recordingChime.paperTap` (choice)
          - [Soft Hush / Sanftes Säuseln / Susurro suave / Doux murmure](#node-recordingChime-softHush) `recordingChime.softHush` (choice)
          - [Low Nod / Tiefes Nicken / Asentimiento grave / Hochement grave](#node-recordingChime-lowNod) `recordingChime.lowNod` (choice)
          - [Cloud Pop / Wolkenplopp / Plof de nube / Ploc nuageux](#node-recordingChime-cloudPop) `recordingChime.cloudPop` (choice)
          - [Velvet Tap / Samttipp / Toque aterciopelado / Tapotement velouté](#node-recordingChime-velvetTap) `recordingChime.velvetTap` (choice)
          - [Satin Shift / Satin-Schimmer / Brillo satinado / Éclat satiné](#node-recordingChime-satinShift) `recordingChime.satinShift` (choice)
          - [Air Glint / Luftfunkeln / Destello de aire / Éclat d’air](#node-recordingChime-airGlint) `recordingChime.airGlint` (choice)
    - [Clipboard / Zwischenablage / Portapapeles / Presse-papiers](#node-dictation-tab-clipboard) `dictation.tab.clipboard` (feature)
      - [Clipboard / Zwischenablage / Portapapeles / Presse-papiers](#node-section-clipboard) `section.clipboard` (section)
        - [Paste dictations automatically / Diktate automatisch einfügen / Pegar dictados automáticamente / Coller automatiquement les dictées](#node-automaticDictationPaste) `automaticDictationPaste` (setting)
        - [Auto-copy to clipboard / Automatisch in die Zwischenablage kopieren / Copiar automáticamente al portapapeles / Copier automatiquement dans le presse-papiers](#node-autoCopyToClipboard) `autoCopyToClipboard` (setting)
        - [Restore clipboard after paste / Zwischenablage nach dem Einfügen wiederherstellen / Restaurar el portapapeles después de pegar / Restaurer le presse-papiers après le collage](#node-restoreClipboard) `restoreClipboard` (setting)
        - [Hide dictations from clipboard manager apps / Diktate vor Zwischenablage-Managern verbergen / Ocultar los dictados a las apps de gestión del portapapeles / Masquer les dictées aux gestionnaires de presse-papiers](#node-keepOutOfClipboardHistory) `keepOutOfClipboardHistory` (setting)
        - [Smart insertion / Intelligentes Einfügen / Inserción inteligente / Insertion intelligente](#node-smartInsertion) `smartInsertion` (setting)
      - [Quick Add / Schnell hinzufügen / Añadir rápidamente / Ajout rapide](#node-section-quickAddClipboard) `section.quickAddClipboard` (section)
        - [Read selections through the clipboard / Auswahl über die Zwischenablage lesen / Leer las selecciones mediante el portapapeles / Lire les sélections via le presse-papiers](#node-quickAddClipboardFallback) `quickAddClipboardFallback` (setting)
  - [Dictionary / Wörterbuch / Diccionario / Dictionnaire](#node-page-dictionary) `page.dictionary` (page)
    - [Dictionary / Wörterbuch / Diccionario / Dictionnaire](#node-section-dictionary) `section.dictionary` (section)
    - [Enable Dictionary / Wörterbuch aktivieren / Activar el Diccionario / Activer le Dictionnaire](#node-enableDictionary) `enableDictionary` (setting)
    - [Your Words / Deine Wörter / Tus palabras / Vos mots](#node-dictionary-tab-yourWords) `dictionary.tab.yourWords` (feature)
      - [Add word / Wort hinzufügen / Añadir palabra / Ajouter un mot](#node-yourWords-add) `yourWords.add` (action)
      - [Import / Importieren / Importar / Importer](#node-yourWords-import) `yourWords.import` (action)
      - [Export your words / Deine Wörter exportieren / Exportar tus palabras / Exporter vos mots](#node-yourWords-export) `yourWords.export` (action)
      - [Search by word, mishearing, or category / Nach Wort, Fehlerkennung oder Kategorie suchen / Buscar por palabra, error de reconocimiento o categoría / Rechercher par mot, erreur de reconnaissance ou catégorie](#node-yourWords-search) `yourWords.search` (setting)
        - [Clear search / Suche löschen / Borrar búsqueda / Effacer la recherche](#node-yourWords-clearSearch) `yourWords.clearSearch` (action)
      - [All categories / Alle Kategorien / Todas las categorías / Toutes les catégories](#node-yourWords-categoryFilter) `yourWords.categoryFilter` (setting)
        - [All categories / Alle Kategorien / Todas las categorías / Toutes les catégories](#node-yourWords-category-all) `yourWords.category.all` (choice)
        - [General / Allgemein / General / Général](#node-yourWords-category-general) `yourWords.category.general` (choice)
        - [Person / Person / Persona / Personne](#node-yourWords-category-person) `yourWords.category.person` (choice)
        - [Brand / Marke / Marca / Marque](#node-yourWords-category-brand) `yourWords.category.brand` (choice)
        - [Acronym / Akronym / Acrónimo / Acronyme](#node-yourWords-category-acronym) `yourWords.category.acronym` (choice)
        - [Domain / Fachgebiet / Ámbito / Domaine](#node-yourWords-category-domain) `yourWords.category.domain` (choice)
        - [Auto-learned / Automatisch gelernt / Aprendidas automáticamente / Appris automatiquement](#node-yourWords-category-autoLearned) `yourWords.category.autoLearned` (choice)
      - [Mass edit / Mehrere auswählen / Editar en lote / Modification groupée](#node-yourWords-massEdit) `yourWords.massEdit` (action)
    - [Vocabulary Packs / Wortschatzpakete / Vocabularios / Lexiques](#node-dictionary-tab-vocabularyPacks) `dictionary.tab.vocabularyPacks` (feature)
    - [Learn from... / Lernen aus... / Aprender de… / Apprendre de…](#node-dictionary-tab-learnFrom) `dictionary.tab.learnFrom` (feature)
      - [Learn from... / Lernen aus... / Aprender de… / Apprendre de…](#node-learnFrom) `learnFrom` (feature)
      - [Learn new words / Neue Wörter lernen / Aprender palabras nuevas / Apprendre de nouveaux mots](#node-selfLearningDictionary) `selfLearningDictionary` (setting)
        - [Learn more / Mehr erfahren / Más información / En savoir plus](#node-selfLearningDictionary-learnMore) `selfLearningDictionary.learnMore` (action)
        - [Forget learning memory / Lerngedächtnis löschen / Borrar la memoria de aprendizaje / Oublier la mémoire d’apprentissage](#node-selfLearningDictionary-forgetMemory) `selfLearningDictionary.forgetMemory` (action)
      - [Fix words it learned / Gelernte Korrekturen anwenden / Corregir palabras aprendidas / Corriger les mots appris](#node-fixLearnedWords) `fixLearnedWords` (setting)
      - [Import from Contacts / Aus Kontakten importieren / Importar desde Contactos / Importer depuis Contacts](#node-importContacts) `importContacts` (feature)
        - [Keep in sync on launch / Beim Start synchron halten / Mantener sincronizado al iniciar / Maintenir la synchronisation au lancement](#node-contactsSyncOnLaunch) `contactsSyncOnLaunch` (setting)
    - [Quick Add / Schnell hinzufügen / Añadir rápidamente / Ajout rapide](#node-dictionary-tab-quickAdd) `dictionary.tab.quickAdd` (feature)
      - [Highlight a word / Wort markieren / Selecciona una palabra / Sélectionner un mot](#node-quickAdd-step1) `quickAdd.step1` (feature)
      - [Trigger Quick Add / „Schnell hinzufügen“ aufrufen / Activar “Añadir rápidamente” / Déclencher l’ajout rapide](#node-quickAdd-step2) `quickAdd.step2` (feature)
      - [Choose and save / Auswählen und sichern / Elegir y guardar / Choisir et enregistrer](#node-quickAdd-step3) `quickAdd.step3` (feature)
      - [Keyboard shortcut / Tastenkürzel / Atajo de teclado / Raccourci clavier](#node-quickAdd-shortcut) `quickAdd.shortcut` (action)
      - [Menu bar / Menüleiste / Barra de menús / Barre des menus](#node-quickAdd-menuBar) `quickAdd.menuBar` (feature)
  - [Keybinds / Tastenkürzel / Atajos de teclado / Raccourcis clavier](#node-page-keybinds) `page.keybinds` (page)
    - [Recording / Aufnahme / GRABACIÓN / ENREGISTREMENT](#node-section-keybindsRecording) `section.keybindsRecording` (section)
      - [Recording mode / Aufnahmemodus / Modo de grabación / Mode d’enregistrement](#node-recordingMode) `recordingMode` (setting)
        - [Push to Talk / Zum Sprechen drücken / Pulsar para hablar / Appuyer pour parler](#node-recordingMode-pushToTalk) `recordingMode.pushToTalk` (choice)
        - [Toggle / Umschalten / Interruptor / Activer ou désactiver](#node-recordingMode-toggle) `recordingMode.toggle` (choice)
      - [Start / stop recording / Aufnahme starten / stoppen / Iniciar o detener la grabación / Démarrer/arrêter l’enregistrement](#node-recordKeybind) `recordKeybind` (setting)
      - [Cancel recording / Aufnahme abbrechen / Cancelar grabación / Annuler l’enregistrement](#node-cancelKeybind) `cancelKeybind` (setting)
      - [Escape Recovery / Wiederherstellung bei Escape / Recuperación con Escape / Récupération avec Échap](#node-escapeRecovery) `escapeRecovery` (setting)
      - [Reset to default / Auf Standard zurücksetzen / Restablecer valor inicial / Rétablir par défaut](#node-keybind-resetToDefault) `keybind.resetToDefault` (action)
    - [Shortcuts / Kurzbefehle / ATAJOS / RACCOURCIS](#node-section-keybindsShortcuts) `section.keybindsShortcuts` (section)
      - [Add selected word to Dictionary / Markiertes Wort zum Wörterbuch hinzufügen / Añadir la palabra seleccionada al Diccionario / Ajouter le mot sélectionné au Dictionnaire](#node-quickAddKeybind) `quickAddKeybind` (setting)
      - [Paste last dictation / Letztes Diktat einfügen / Pegar el último dictado / Coller la dernière dictée](#node-pasteLastKeybind) `pasteLastKeybind` (setting)
      - [Copy last dictation / Letztes Diktat kopieren / Copiar el último dictado / Copier la dernière dictée](#node-copyLastKeybind) `copyLastKeybind` (setting)
  - [EnviousMeet / EnviousMeet / EnviousMeet / EnviousMeet](#node-page-meetings) `page.meetings` (page)
    - [General / Allgemein / General / Général](#node-meetings-tab-general) `meetings.tab.general` (feature)
      - [Record only my voice / Nur meine Stimme aufnehmen / Grabar solo mi voz / Enregistrer uniquement ma voix](#node-meetingCaptureCallSound) `meetingCaptureCallSound` (setting)
      - [Turn off dictation during meetings / Diktieren während Meetings ausschalten / Desactivar el dictado durante las reuniones / Désactiver la dictée pendant les réunions](#node-meetingTurnsOffDictation) `meetingTurnsOffDictation` (setting)
      - [Leave my voice out when I'm muted / Meine Stimme weglassen, wenn ich stummgeschaltet bin / No grabar mi voz si mi micrófono está silenciado / Ne pas enregistrer ma voix quand mon micro est coupé](#node-meetingFollowsCallMute) `meetingFollowsCallMute` (setting)
      - [Name meetings from my calendar / Meetings nach meinem Kalender benennen / Nombrar reuniones según mi calendario / Nommer les réunions d’après mon calendrier](#node-meetingUseCalendarForNames) `meetingUseCalendarForNames` (setting)
      - [When a call starts / Wenn ein Anruf beginnt / Cuando comienza una llamada / Au début d’un appel](#node-meetingCallDetection) `meetingCallDetection` (setting)
    - [Models / Modelle / Modelos / Modèles](#node-meetings-tab-models) `meetings.tab.models` (feature)
      - [Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct](#node-meetingLiveWords) `meetingLiveWords` (setting)
        - [Change / Ändern / Cambiar / Modifier](#node-meetingLiveWords-change) `meetingLiveWords.change` (action)
        - [Keep current Live Preview engine / Aktuelle Live-Vorschau-Engine beibehalten / Mantener el motor actual de Vista previa en tiempo real / Conserver le moteur actuel d’Aperçu en direct](#node-meetingLiveWords-keepCurrent) `meetingLiveWords.keepCurrent` (action)
        - [Apple](#node-meetingLiveWords-apple) `meetingLiveWords.apple` (choice)
        - [Universal / Universal / Universal / Universal](#node-meetingLiveWords-universal) `meetingLiveWords.universal` (choice)
      - [Live Preview language / Sprache der Live-Vorschau / Idioma de la Vista previa en tiempo real / Langue de l’Aperçu en direct](#node-meetingLiveWordsLanguage) `meetingLiveWordsLanguage` (setting)
      - [Transcript engine / Transkript-Engine / Motor de transcripción / Moteur de transcription](#node-meetingTranscriptEngine) `meetingTranscriptEngine` (setting)
        - [Change / Ändern / Cambiar / Modifier](#node-meetingTranscriptEngine-change) `meetingTranscriptEngine.change` (action)
        - [Keep current transcript engine / Aktuelle Transkript-Engine beibehalten / Mantener el motor actual de transcripción / Conserver le moteur de transcription actuel](#node-meetingTranscriptEngine-keepCurrent) `meetingTranscriptEngine.keepCurrent` (action)
        - [Parakeet / Parakeet / Parakeet / Parakeet](#node-meetingTranscriptEngine-parakeet) `meetingTranscriptEngine.parakeet` (choice)
        - [Whisper Large v3 Turbo / Whisper Large v3 Turbo / Whisper Large v3 Turbo / Whisper Large v3 Turbo](#node-meetingTranscriptEngine-whisper) `meetingTranscriptEngine.whisper` (choice)
        - [Apple](#node-meetingTranscriptEngine-apple) `meetingTranscriptEngine.apple` (choice)
      - [Auto-detect language / Sprache automatisch erkennen / Detectar idioma automáticamente / Détecter automatiquement la langue](#node-meetingTranscriptAutoDetect) `meetingTranscriptAutoDetect` (setting)
      - [Transcript language / Transkriptsprache / Idioma de la transcripción / Langue de transcription](#node-meetingTranscriptLanguage) `meetingTranscriptLanguage` (setting)
      - [Speaker labels / Sprecherkennzeichnung / Etiquetas de participantes / Libellés des intervenants](#node-meetingSpeakerLabels) `meetingSpeakerLabels` (feature)
    - [Summaries / Zusammenfassungen / Resúmenes / Résumés](#node-meetings-tab-summaries) `meetings.tab.summaries` (feature)
      - [Write a summary when a meeting ends / Zusammenfassung erstellen, wenn ein Meeting endet / Escribir un resumen al terminar una reunión / Rédiger un résumé à la fin d’une réunion](#node-meetingWriteSummary) `meetingWriteSummary` (setting)
      - [Summary engine / Zusammenfassungs-Engine / Motor de resúmenes / Moteur de résumé](#node-meetingSummaryEngine) `meetingSummaryEngine` (setting)
        - [Change / Ändern / Cambiar / Modifier](#node-meetingSummaryEngine-change) `meetingSummaryEngine.change` (action)
        - [Keep current summary engine / Aktuelle Zusammenfassungs-Engine beibehalten / Mantener el motor actual de resúmenes / Conserver le moteur de résumé actuel](#node-meetingSummaryEngine-keepCurrent) `meetingSummaryEngine.keepCurrent` (action)
        - [EG-1](#node-meetingSummaryEngine-egOne) `meetingSummaryEngine.egOne` (choice)
        - [Apple Intelligence](#node-meetingSummaryEngine-appleIntelligence) `meetingSummaryEngine.appleIntelligence` (choice)
        - [Ollama](#node-meetingSummaryEngine-ollama) `meetingSummaryEngine.ollama` (choice)
        - [OpenAI](#node-meetingSummaryEngine-openAI) `meetingSummaryEngine.openAI` (choice)
        - [Google Gemini](#node-meetingSummaryEngine-gemini) `meetingSummaryEngine.gemini` (choice)
        - [Claude](#node-meetingSummaryEngine-claude) `meetingSummaryEngine.claude` (choice)
    - [Call Apps / Anruf-Apps / Apps de llamadas / Apps d’appel](#node-meetings-tab-callApps) `meetings.tab.callApps` (feature)
      - [Notice calls in / Anrufe erkennen in / Detectar llamadas en / Détecter les appels dans](#node-meetingCallApps) `meetingCallApps` (setting)
    - [Permissions / Berechtigungen / Permisos / Autorisations](#node-meetings-tab-permissions) `meetings.tab.permissions` (feature)
  - [Snippets / Textbausteine / Fragmentos de texto / Extraits de texte](#node-page-snippets) `page.snippets` (page)
    - [Paste the text you type over and over, by voice / Füge Text, den du oft tippst, per Stimme ein / Pega con la voz el texto que escribes una y otra vez / Coller à la voix les textes que vous saisissez souvent](#node-snippets) `snippets` (feature)
    - [Keyword / Schlüsselwort / Palabra clave / Mot-clé](#node-snippetKeyword) `snippetKeyword` (setting)
    - [Your snippets / Deine Textbausteine / Tus fragmentos de texto / Vos extraits de texte](#node-yourSnippets) `yourSnippets` (feature)
      - [Search snippets / Textbausteine durchsuchen / Buscar fragmentos de texto / Rechercher des extraits](#node-snippets-search) `snippets.search` (setting)
        - [Clear search / Suche löschen / Borrar búsqueda / Effacer la recherche](#node-snippets-clearSearch) `snippets.clearSearch` (action)
      - [Import / Importieren / Importar / Importer](#node-snippets-import) `snippets.import` (action)
      - [Export / Exportieren / Exportar / Exporter](#node-snippets-export) `snippets.export` (action)
      - [Add snippet / Textbaustein hinzufügen / Añadir fragmento de texto / Ajouter un extrait](#node-snippets-add) `snippets.add` (action)
      - [Add your first snippet / Ersten Textbaustein hinzufügen / Añadir tu primer fragmento de texto / Ajouter votre premier extrait](#node-snippets-addFirst) `snippets.addFirst` (action)
  - [Transcribe a File / Datei transkribieren / Transcribir un archivo / Transcrire un fichier](#node-page-transcribeFile) `page.transcribeFile` (page)
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

### Search settings / Einstellungen suchen / Buscar en Ajustes / Rechercher (`window.search`)

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

### AI Polish / KI-Nachbearbeitung / Pulido con IA / Retouche IA (`page.aiPolish`)

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

### App Settings / App-Einstellungen / Ajustes de la app / Réglages de l’app (`page.appSettings`)

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

### Dictation Settings / Diktateinstellungen / Ajustes del dictado / Réglages de dictée (`page.dictation`)

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

### Dictionary / Wörterbuch / Diccionario / Dictionnaire (`page.dictionary`)

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

### Keybinds / Tastenkürzel / Atajos de teclado / Raccourcis clavier (`page.keybinds`)

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

<a id="node-page-meetings"></a>

### EnviousMeet / EnviousMeet / EnviousMeet / EnviousMeet (`page.meetings`)

| Field | Value |
|---|---|
| Structure | page |
| Kind | structure only, not searchable |
| Parent | [`window.settings`](#node-window-settings) |
| Title source | catalog key `EnviousMeet` |
| Description | none |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-page-snippets"></a>

### Snippets / Textbausteine / Fragmentos de texto / Extraits de texte (`page.snippets`)

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

### Transcribe a File / Datei transkribieren / Transcribir un archivo / Transcrire un fichier (`page.transcribeFile`)

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

### TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE / MOTOR DE TRANSCRIPCIÓN / MOTEUR DE TRANSCRIPTION (`section.transcriptionEngine`)

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

### APPLIES TO BOTH ENGINES / GILT FÜR BEIDE ENGINES / SE APLICA A AMBOS MOTORES / S’APPLIQUE AUX DEUX MOTEURS (`section.engineShared`)

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

### INPUT &amp; BEHAVIOR / EINGABE &amp; VERHALTEN / ENTRADA Y COMPORTAMIENTO / ENTRÉE ET COMPORTEMENT (`section.microphone`)

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

### Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct (`section.livePreview`)

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

### Preview engine / Vorschau-Engine / Motor de vista previa / Moteur d’aperçu (`section.previewEngine`)

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

### Recording Pill / Aufnahmeanzeige / Píldora de grabación / Pastille d’enregistrement (`section.pill`)

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

### RECORDING CHIMES / AUFNAHMESIGNALTÖNE / SONIDOS DE GRABACIÓN / SONS D’ENREGISTREMENT (`section.chimes`)

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

### Clipboard / Zwischenablage / Portapapeles / Presse-papiers (`section.clipboard`)

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

### Quick Add / Schnell hinzufügen / Añadir rápidamente / Ajout rapide (`section.quickAddClipboard`)

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

### Recording / Aufnahme / GRABACIÓN / ENREGISTREMENT (`section.keybindsRecording`)

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

### Shortcuts / Kurzbefehle / ATAJOS / RACCOURCIS (`section.keybindsShortcuts`)

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

### Model / Modell / Modelo / Modèle (`section.aiPolishModel`)

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

### Dictionary / Wörterbuch / Diccionario / Dictionnaire (`section.dictionary`)

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

### APPEARANCE / ERSCHEINUNGSBILD / ASPECTO / APPARENCE (`section.appearance`)

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

### PERMISSIONS / BERECHTIGUNGEN / PERMISOS / AUTORISATIONS (`section.permissions`)

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

### PRIVACY / DATENSCHUTZ / PRIVACIDAD / CONFIDENTIALITÉ (`section.privacy`)

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

<a id="node-section-recordings"></a>

### Recordings / Aufnahmen / Grabaciones / Enregistrements (`section.recordings`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.recordings`](#node-appSettings-tab-recordings) |
| Title source | catalog key `Recordings` |
| Description | none |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-recordingStorage"></a>

### Storage / Speicher / Almacenamiento / Stockage (`section.recordingStorage`)

| Field | Value |
|---|---|
| Structure | section |
| Kind | structure only, not searchable |
| Parent | [`appSettings.tab.recordings`](#node-appSettings-tab-recordings) |
| Title source | catalog key `Storage` |
| Description | none |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | none |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |

<a id="node-section-about"></a>

### ABOUT / INFO / ACERCA DE / À PROPOS (`section.about`)

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

### Engine / Engine / Motor / Moteur (`dictation.tab.engine`)

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
| Search (es) | words: pestaña Engine, ajustes del motor<br>phrases: abrir la pestaña del motor de dictado |
| Search (fr) | words: onglet moteur, réglages moteur<br>phrases: ouvrir l’onglet du moteur de dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-microphone"></a>

### Microphone / Mikrofon / Micrófono / Micro (`dictation.tab.microphone`)

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
| Search (es) | words: ajustes del micro, pestaña Microphone<br>phrases: abrir la pestaña de ajustes del micrófono |
| Search (fr) | words: onglet micro, réglages micro<br>phrases: ouvrir l’onglet des réglages du microphone |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-livePreview"></a>

### Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct (`dictation.tab.livePreview`)

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
| Search (es) | words: pestaña Live Preview, ajustes de vista previa<br>phrases: abrir la pestaña de vista previa en vivo |
| Search (fr) | words: onglet aperçu, réglages aperçu<br>phrases: ouvrir l’onglet de l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-pill"></a>

### Recording Pill / Aufnahmeanzeige / Píldora de grabación / Pastille d’enregistrement (`dictation.tab.pill`)

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
| Search (es) | words: widget, overlay, indicador flotante<br>phrases: abrir los ajustes del indicador flotante de grabación |
| Search (fr) | words: widget, indicateur flottant, overlay<br>phrases: ouvrir les réglages de l’indicateur flottant d’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-chimes"></a>

### Chimes / Signaltöne / Tonos / Sons (`dictation.tab.chimes`)

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
| Search (es) | words: ajustes de sonidos, pestaña Chimes<br>phrases: abrir la pestaña de sonidos de grabación |
| Search (fr) | words: onglet sons, réglages sonores<br>phrases: ouvrir l’onglet des sons d’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictation-tab-clipboard"></a>

### Clipboard / Zwischenablage / Portapapeles / Presse-papiers (`dictation.tab.clipboard`)

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
| Search (es) | words: clipboard<br>phrases: ver los ajustes del portapapeles |
| Search (fr) | words: clipboard, copier-coller<br>phrases: ouvrir les réglages du presse-papiers |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine"></a>

### TRANSCRIPTION ENGINE / TRANSKRIPTIONS-ENGINE / MOTOR DE TRANSCRIPCIÓN / MOTEUR DE TRANSCRIPTION (`transcriptionEngine`)

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
| Search (es) | words: modelo de dictado, transcriptor del dictado<br>phrases: qué modelo convierte mi dictado en texto |
| Search (fr) | words: modèle de dictée, transcription finale<br>phrases: où choisir le modèle qui transforme ma dictée en texte |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-change"></a>

### Change / Ändern / Cambiar / Modifier (`transcriptionEngine.change`)

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
| Search (es) | words: cambiar modelo de dictado, Cambiar motor de dictado<br>phrases: cambiar el modelo que transcribe mi dictado |
| Search (fr) | words: changer de moteur<br>phrases: passer à un autre modèle pour mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-keepCurrent"></a>

### Keep current engine / Aktuelle Engine beibehalten / Mantener el motor actual / Conserver le moteur actuel (`transcriptionEngine.keepCurrent`)

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
| Search (es) | words: mantener motor de dictado, conservar modelo de dictado<br>phrases: dejar el motor de dictado como está |
| Search (fr) | words: garder le moteur<br>phrases: conserver mon modèle de dictée actuel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-recheckFast"></a>

### Re-check Fast model status / Modellstatus von „Schnell“ erneut prüfen / Comprobar de nuevo el estado del modelo Rápido / Vérifier à nouveau l’état du modèle « Rapide » (`transcriptionEngine.recheckFast`)

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
| Search (es) | words: comprobar Parakeet, revisar Parakeet, Volver a comprobar Parakeet<br>phrases: comprobar otra vez si Parakeet está listo |
| Search (fr) | words: revérifier Parakeet<br>phrases: vérifier à nouveau si le modèle Parakeet est prêt |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-cancelDownload"></a>

### Cancel / Abbrechen / Cancelar / Annuler (`fastModel.cancelDownload`)

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
| Search (es) | words: cancelar Parakeet, detener descarga Parakeet<br>phrases: cancelar la descarga de Parakeet |
| Search (fr) | words: annuler Parakeet<br>phrases: arrêter le téléchargement de Parakeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-resume"></a>

### Resume / Fortsetzen / Reanudar / Reprendre (`fastModel.resume`)

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
| Search (es) | words: reanudar Parakeet, continuar descarga Parakeet<br>phrases: seguir descargando Parakeet donde se quedó |
| Search (fr) | words: reprendre Parakeet<br>phrases: reprendre le téléchargement de Parakeet mis en pause |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fastModel-tryAgain"></a>

### Try Again / Erneut versuchen / Intentar de nuevo / Réessayer (`fastModel.tryAgain`)

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
| Search (es) | words: reintentar Parakeet, descarga Parakeet fallida<br>phrases: volver a intentar descargar Parakeet después del fallo |
| Search (fr) | words: réessayer Parakeet<br>phrases: relancer le téléchargement de Parakeet après son échec |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-setUp"></a>

### Set up model / Modell einrichten / Configurar modelo / Configurer le modèle (`whisperModel.setUp`)

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
| Search (es) | words: configurar Whisper<br>phrases: instalar Whisper en mi Mac |
| Search (fr) | words: installer Whisper<br>phrases: installer Whisper sur mon Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-cancelDownload"></a>

### Cancel / Abbrechen / Cancelar / Annuler (`whisperModel.cancelDownload`)

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
| Search (es) | words: cancelar Whisper, detener descarga Whisper<br>phrases: cancelar la descarga de Whisper |
| Search (fr) | words: annuler Whisper<br>phrases: arrêter le téléchargement de Whisper |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-resume"></a>

### Resume / Fortsetzen / Reanudar / Reprendre (`whisperModel.resume`)

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
| Search (es) | words: reanudar Whisper, continuar descarga Whisper<br>phrases: seguir descargando Whisper donde se quedó |
| Search (fr) | words: reprendre Whisper<br>phrases: reprendre le téléchargement de Whisper mis en pause |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-remove"></a>

### Remove Model / Modell entfernen / Eliminar modelo / Supprimer le modèle (`whisperModel.remove`)

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
| Search (es) | words: borrar Whisper, desinstalar Whisper<br>phrases: borrar el modelo Whisper de mi Mac |
| Search (fr) | words: désinstaller Whisper<br>phrases: supprimer le modèle Whisper de mon Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-recheck"></a>

### Re-check model status / Modellstatus erneut prüfen / Comprobar de nuevo el estado del modelo / Vérifier à nouveau l’état du modèle (`whisperModel.recheck`)

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
| Search (es) | words: comprobar Whisper, revisar Whisper, Volver a comprobar Whisper<br>phrases: comprobar otra vez si Whisper está listo |
| Search (fr) | words: revérifier Whisper<br>phrases: vérifier à nouveau si Whisper est prêt |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whisperModel-tryAgain"></a>

### Try Again / Erneut versuchen / Intentar de nuevo / Réessayer (`whisperModel.tryAgain`)

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
| Search (es) | words: reintentar Whisper, instalación Whisper fallida<br>phrases: volver a intentar instalar Whisper después del fallo |
| Search (fr) | words: réessayer Whisper<br>phrases: relancer l’installation de Whisper après son échec |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: motor activo, modelo actual, Rápido · Parakeet<br>phrases: ver las opciones del motor de dictado que estoy usando |
| Search (fr) | words: moteur actif, options actuelles<br>phrases: voir les options du moteur de dictée que j’utilise actuellement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoDetectLanguage"></a>

### Auto-detect language / Sprache automatisch erkennen / Detectar idioma automáticamente / Détecter automatiquement la langue (`autoDetectLanguage`)

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
| Search (es) | words: autodetección, detectar idioma, idioma automático<br>phrases: detectar automáticamente en qué idioma hablo; no quiero elegir a mano el idioma del dictado |
| Search (fr) | words: détection automatique, autodétection<br>phrases: reconnaître automatiquement la langue que je parle |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoDetectLanguage-resetSuggestions"></a>

### Reset suggestions / Vorschläge zurücksetzen / Restablecer las sugerencias / Réinitialiser les suggestions (`autoDetectLanguage.resetSuggestions`)

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
| Search (es) | words: restablecer sugerencias, reiniciar sugerencias<br>phrases: volver a sugerirme que fije el idioma detectado |
| Search (fr) | words: réinitialiser les suggestions<br>phrases: me proposer à nouveau de garder la langue détectée pour mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-lockedLanguage"></a>

### (named at runtime by `lockedLanguage`) (`lockedLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`currentEngineSection`](#node-currentEngineSection) |
| Title source | resolver `lockedLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | Choose the language for dictation and preview. / Wähle die Sprache für Diktat und Vorschau. / Elige el idioma del dictado y de la vista previa. / Choisissez la langue de la dictée et de l’aperçu. |
| Description source | catalog key `Choose the language for dictation and preview.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `languageLocked` |
| Arrival target | [`lockedLanguage`](#node-lockedLanguage) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: lock, fixed<br>phrases: always use the same language for dictation; set a fixed language for dictation and preview; stop guessing which language I am speaking |
| Search (de) | words: Diktiersprache, festlegen, fest<br>phrases: verwende fürs Diktieren immer dieselbe Sprache; lege die Sprache für Diktat und Vorschau fest; erkenne meine Diktiersprache nicht automatisch |
| Search (es) | words: idioma fijo, fijar idioma, bloquear idioma, idioma del dictado<br>phrases: usar siempre el mismo idioma para el dictado y la vista previa |
| Search (fr) | words: langue fixe, langue verrouillée<br>phrases: toujours utiliser la même langue pour la dictée et l’aperçu |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-lockedLanguage-change"></a>

### Change / Ändern / Cambiar / Modifier (`lockedLanguage.change`)

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
| Search (es) | words: cambiar idioma desde Engine, cambiar idioma desde motor<br>phrases: cambiar el idioma del dictado desde la pestaña del motor |
| Search (fr) | words: changer la langue fixe<br>phrases: changer la langue de dictée depuis l’onglet Moteur |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fasterTranscription"></a>

### Faster Transcription / Schnellere Transkription / Transcripción más rápida / Transcription plus rapide (`fasterTranscription`)

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
| Search (es) | words: latencia, transcripción anticipada, menos espera<br>phrases: empezar a transcribir antes de terminar de grabar; reducir la espera del texto final del dictado |
| Search (fr) | words: latence, transcription anticipée, traitement anticipé<br>phrases: commencer à transcrire pendant l’enregistrement pour réduire l’attente à la fin |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-stopOnSilence"></a>

### Stop recording on silence / Aufnahme bei Stille stoppen / Detener la grabación al detectar silencio / Arrêter l’enregistrement en cas de silence (`stopOnSilence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Stop recording on silence` |
| Description | Ends recording after you stop speaking. / Beendet die Aufnahme, wenn du aufhörst zu sprechen. / La grabación termina cuando dejas de hablar. / Arrête l’enregistrement après que vous avez cessé de parler. |
| Description source | catalog key `Ends recording after you stop speaking.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`stopOnSilence`](#node-stopOnSilence) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: silence, autostop<br>phrases: stop recording when I stop talking; end my dictation automatically when I go quiet; I want recording to stop without pressing a key |
| Search (de) | words: Stille, Autostopp, Sprechpause<br>phrases: stoppe die Aufnahme, wenn ich nicht mehr spreche; beende mein Diktat automatisch bei Stille; beende die Aufnahme, ohne dass ich eine Taste drücken muss |
| Search (es) | words: parada automática, autostop, parar por silencio, Parar la grabación al dejar de hablar<br>phrases: parar la grabación cuando deje de hablar |
| Search (fr) | words: arrêt automatique, autostop, arrêt au silence<br>phrases: arrêter l’enregistrement automatiquement quand je ne parle plus |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pauseDuration"></a>

### Pause duration / Pausendauer / Duración de la pausa / Durée de la pause (`pauseDuration`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`stopOnSilence`](#node-stopOnSilence) |
| Title source | catalog key `Pause duration` |
| Description | How long a pause ends the recording. / Wie lange eine Pause dauern muss, um die Aufnahme zu beenden. / Cuánto debe durar una pausa para terminar la grabación. / Durée de pause nécessaire pour arrêter l’enregistrement. |
| Description source | catalog key `How long a pause ends the recording.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `stopOnSilenceOn` |
| Arrival target | [`pauseDuration`](#node-pauseDuration) |
| Fallbacks, in order | [`stopOnSilence`](#node-stopOnSilence) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: timeout, delay<br>phrases: how long can I stay quiet before recording stops; wait longer before stopping on silence; change the length of the pause that ends recording |
| Search (de) | words: Zeitlimit, Verzögerung, Pausenlänge<br>phrases: wie lange darf ich still sein, bevor die Aufnahme endet; warte bei Stille länger, bevor du die Aufnahme stoppst; ändere, wie lang die Pause zum Beenden der Aufnahme sein muss |
| Search (es) | words: duración del silencio, tiempo de pausa, timeout<br>phrases: cuánto puedo estar en silencio antes de que pare la grabación; esperar más antes de parar por silencio |
| Search (fr) | words: délai de silence, durée du silence, timeout<br>phrases: régler combien de temps je peux me taire avant que l’enregistrement s’arrête |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fillerRemoval"></a>

### Remove filler words (um, uh, hmm...) / Füllwörter entfernen (ähm, äh, hm...) / Eliminar muletillas (um, uh, mmm...) / Supprimer les mots de remplissage (euh, hum, hmm…) (`fillerRemoval`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Remove filler words (um, uh, hmm...)` |
| Description | Strips common filler words from transcriptions. / Entfernt häufige Füllwörter aus Transkripten. / Elimina palabras de relleno habituales de las transcripciones. / Supprime les mots de remplissage courants des transcriptions. |
| Description source | catalog key `Strips common filler words from transcriptions.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`fillerRemoval`](#node-fillerRemoval) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: um, uh, hmm, ums, hesitations, fillers<br>phrases: remove ums and uhs from my text; leave out my hesitation sounds; remove filler words from my dictation |
| Search (de) | words: ähm, äh, hm, Ähms, Fülllaute<br>phrases: lass die Ähms aus meinem Text weg; entferne meine Füllwörter beim Diktieren; schreib meine Ähs und Ähms nicht mit |
| Search (es) | words: muletillas, vacilaciones, um, uh, hmm, fillers<br>phrases: quitar las muletillas y los sonidos de duda de mi dictado |
| Search (fr) | words: euh, hum, hmm, hésitations, fillers<br>phrases: enlever les euh et les sons d’hésitation de ma dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-spokenEmoji"></a>

### Convert spoken emoji (e.g. "thumbs up emoji" → 👍) / Gesprochene Emojis umwandeln (z. B. „thumbs up emoji“ → 👍) / Convertir los emojis dictados (p. ej., “thumbs up emoji” → 👍) / Convertir les émojis dictés (p. ex. « thumbs up emoji » → 👍) (`spokenEmoji`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Convert spoken emoji (e.g. "thumbs up emoji" → 👍)` |
| Description | Say a phrase followed by emoji to get its symbol. / Sag einen Ausdruck und danach „Emoji“, um das Symbol einzufügen. / Di una frase seguida de “emoji” para obtener su símbolo. / Dites une expression suivie de « emoji » pour obtenir son symbole. |
| Description source | catalog key `Say a phrase followed by emoji to get its symbol.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`spokenEmoji`](#node-spokenEmoji) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: smiley, smileys, 👍<br>phrases: turn spoken emoji names into symbols; insert a thumbs up when I say thumbs up emoji; let me dictate smileys by saying their name and emoji |
| Search (de) | words: Smiley, Smileys, 👍<br>phrases: mach aus gesprochenen Emoji-Namen die passenden Symbole; füge einen Daumen hoch ein, wenn ich Daumen hoch Emoji sage; ich möchte Smileys mit ihrem Namen und dem Wort Emoji diktieren |
| Search (es) | words: emojis, emoticonos, caritas, smileys<br>phrases: insertar un emoji diciendo su nombre y la palabra emoji |
| Search (fr) | words: emoji, émojis, smileys, émoticônes<br>phrases: insérer un émoji en disant son nom suivi du mot emoji |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-spokenPunctuation"></a>

### Spoken punctuation / Gesprochene Satzzeichen / Puntuación por voz / Ponctuation dictée (`spokenPunctuation`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Spoken punctuation` |
| Description | Say comma or new paragraph to insert it. / Sag „comma“ oder „new paragraph“, um es einzufügen. / Dicta los signos de puntuación para insertarlos. / Dites « comma » ou « new paragraph » pour l’insérer. |
| Description source | catalog key `Say comma or new paragraph to insert it.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: comma, period, paragraph, colon, semicolon<br>phrases: insert punctuation by speaking a command; start a new paragraph with a spoken command; let me dictate commas and periods |
| Search (de) | words: Komma, Punkt, Absatz, Doppelpunkt, Semikolon<br>phrases: füge Satzzeichen mit einem gesprochenen Befehl ein; beginne mit einem Sprachbefehl einen neuen Absatz; ich möchte Kommas und Punkte diktieren |
| Search (es) | words: comas, puntos, nuevo párrafo, dos puntos, punto y coma<br>phrases: poner comas y puntos con comandos de voz; empezar un párrafo nuevo con un comando de voz |
| Search (fr) | words: virgule, point-virgule, deux-points, nouveau paragraphe<br>phrases: insérer des virgules et des points avec des commandes vocales |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordLanguage"></a>

### Start word / Startwort / Palabra de inicio / Mot de début (`startWordLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`spokenPunctuation`](#node-spokenPunctuation) |
| Title source | catalog key `Start word` |
| Description | The word you say before a mark. / Das Wort, das du vor einem Zeichen sagst. / La palabra que dices antes de un signo. / Le mot que vous dites avant un signe. |
| Description source | catalog key `The word you say before a mark.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `spokenPunctuationOn` |
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose which language I am editing the punctuation start word for; select the language for the punctuation trigger settings |
| Search (de) | phrases: wähle, für welche Sprache ich das Startwort für Satzzeichen bearbeite; für welche Sprache stelle ich den Satzzeichenauslöser ein |
| Search (es) | words: idioma del activador, idioma del prefijo<br>phrases: elegir para qué idioma quiero editar la palabra de activación de puntuación |
| Search (fr) | words: langue du déclencheur, langue de ponctuation<br>phrases: choisir pour quelle langue je règle le mot déclencheur de ponctuation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWordField"></a>

### Start word for / Startwort für / Palabra de inicio para / Mot de début pour (`startWordField`)

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: prefix, trigger<br>phrases: set the word I say before a punctuation mark; enter my own punctuation trigger word; change the spoken prefix for punctuation |
| Search (de) | words: Auslösewort, Befehlswort, Signalwort<br>phrases: lege fest, welches Wort ich vor einem Satzzeichen sagen muss; gib mein eigenes Auslösewort für Satzzeichen ein; ändere das Wort vor dem Satzzeichenbefehl |
| Search (es) | words: prefijo de puntuación, activador de puntuación, Palabra de activación para puntuación<br>phrases: cambiar la palabra que digo antes de un signo de puntuación |
| Search (fr) | words: préfixe de ponctuation, déclencheur de ponctuation<br>phrases: saisir le mot à dire avant un signe de ponctuation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWord-save"></a>

### Save word / Wort sichern / Guardar palabra / Enregistrer le mot (`startWord.save`)

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: save the punctuation start word I entered; apply my new punctuation trigger |
| Search (de) | phrases: speichere mein eingegebenes Startwort für Satzzeichen; übernimm mein neues Auslösewort für Satzzeichen |
| Search (es) | words: guardar activador, guardar prefijo<br>phrases: guardar mi nueva palabra de activación de puntuación |
| Search (fr) | words: enregistrer le déclencheur<br>phrases: enregistrer mon nouveau mot déclencheur de ponctuation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-startWord-reset"></a>

### Reset / Zurücksetzen / Restablecer / Réinitialiser (`startWord.reset`)

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: restore the default punctuation start word; reset my custom punctuation trigger |
| Search (de) | phrases: stell das voreingestellte Startwort für Satzzeichen wieder her; setze mein eigenes Auslösewort für Satzzeichen zurück |
| Search (es) | words: restablecer activador, prefijo predeterminado<br>phrases: volver a la palabra de activación de puntuación predeterminada |
| Search (fr) | words: réinitialiser le déclencheur<br>phrases: remettre le mot déclencheur de ponctuation par défaut |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-casualMode"></a>

### Casual mode / Lockerer Modus / Modo informal / Mode décontracté (`casualMode`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Casual mode` |
| Description | Leave off the full stop at the end of each dictation. / Lässt den Punkt am Ende jedes Diktats weg. / No añadir el punto al final de cada dictado. / Omet le point final de chaque dictée. |
| Description source | catalog key `Leave off the full stop at the end of each dictation.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`casualMode`](#node-casualMode) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: full stop, period, trailing dot<br>phrases: no period at the end of dictation; leave off the final full stop |
| Search (de) | words: Schlusspunkt, Satzende<br>phrases: lass den Punkt am Ende des Diktats weg; kein Punkt am Ende |
| Search (es) | words: punto final, omitir el punto final<br>phrases: sin punto al final del dictado; quitar el punto al final del dictado |
| Search (fr) | words: point final<br>phrases: sans point à la fin de la dictée; enlever le point final de la dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel"></a>

### Unload model after / Modell entladen nach / Quitar modelo de RAM tras / Décharger le modèle après (`unloadModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.engineShared`](#node-section-engineShared) |
| Title source | catalog key `Unload model after` |
| Description | Frees memory when you are not dictating. / Gibt Speicher frei, wenn du nicht diktierst. / Libera memoria cuando no estás dictando. / Libère de la mémoire quand vous ne dictez pas. |
| Description source | catalog key `Frees memory when you are not dictating.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`unloadModel`](#node-unloadModel) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: RAM, memory, unloading<br>phrases: free the dictation model memory when I am not using it; choose how long the speech model stays in memory; change when the dictation model is unloaded |
| Search (de) | words: RAM, Arbeitsspeicher, Speicher, entladen<br>phrases: gib den Arbeitsspeicher frei, wenn ich nicht diktiere; wie lange soll das Diktiermodell im Speicher bleiben; ändere, wann das Diktiermodell aus dem Speicher entfernt wird |
| Search (es) | words: RAM, memoria del dictado, descarga de memoria, Liberar el modelo de la memoria después de<br>phrases: elegir cuánto tiempo se queda el modelo de dictado en memoria |
| Search (fr) | words: RAM, mémoire, déchargement<br>phrases: régler combien de temps le modèle de dictée reste en mémoire sans être utilisé |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputDevice"></a>

### Input device / Eingabegerät / Dispositivo de entrada / Périphérique d’entrée (`inputDevice`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Input device` |
| Description | Choose the microphone used for recording. / Wähle das Mikrofon für die Aufnahme. / Elige el micrófono que se usará para grabar. / Choisissez le micro utilisé pour l’enregistrement. |
| Description source | catalog key `Choose the microphone used for recording.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`inputDevice`](#node-inputDevice) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: mic, source<br>phrases: choose which microphone records my voice; select the microphone I dictate into; where do I choose my recording device |
| Search (de) | words: Mikro, Mikroauswahl, Aufnahmegerät<br>phrases: wähle das Mikrofon, das meine Stimme aufnimmt; welches Mikro soll ich fürs Diktieren benutzen; wo wähle ich mein Aufnahmegerät aus |
| Search (es) | words: elegir micrófono, fuente de audio, micro de entrada<br>phrases: elegir con qué micrófono grabo mi voz |
| Search (fr) | words: source audio, micro d’entrée<br>phrases: où choisir le microphone qui enregistre ma voix |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputDevice-auto"></a>

### Auto / Auto / Automático / Auto (`inputDevice.auto`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`inputDevice`](#node-inputDevice) |
| Title source | catalog key `Auto` |
| Description | Follows macOS / Folgt macOS / Igual que macOS / Suit macOS |
| Description source | catalog key `Follows macOS` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`inputDevice`](#node-inputDevice) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: default, system<br>phrases: use the microphone selected in macOS; follow the Mac sound input setting |
| Search (de) | words: Standardmikrofon, Systemmikrofon<br>phrases: nimm das Mikrofon, das in macOS ausgewählt ist; verwende die Toneingabe aus den Mac-Einstellungen |
| Search (es) | words: micro del sistema, micrófono predeterminado<br>phrases: usar el micrófono elegido en los ajustes de sonido de macOS |
| Search (fr) | words: micro système, micro par défaut<br>phrases: utiliser le microphone sélectionné dans macOS |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: micro USB, micro integrado, micro externo, micro de auriculares, micro Bluetooth, Micrófono seleccionado<br>phrases: elegir un micrófono concreto de la lista |
| Search (fr) | words: micro USB, micro intégré, micro externe, micro-casque<br>phrases: sélectionner un microphone précis dans la liste des appareils |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-inputSocket"></a>

### Mic is on / Mikrofon ist an / Entrada del micrófono / Micro sur (`inputSocket`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`inputDevice`](#node-inputDevice) |
| Title source | catalog key `Mic is on` |
| Description | Choose the socket your microphone is plugged into. / Wähle den Anschluss, an dem dein Mikrofon steckt. / Elige el conector al que está conectado tu micrófono. / Choisissez la prise à laquelle votre micro est branché. |
| Description source | catalog key `Choose the socket your microphone is plugged into.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `multiInputDevice` |
| Arrival target | [`inputSocket`](#node-inputSocket) |
| Fallbacks, in order | [`inputDevice`](#node-inputDevice) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: socket, port, channel, interface<br>phrases: choose the socket my microphone is plugged into; select the microphone channel on my audio interface |
| Search (de) | words: Buchse, Anschluss, Kanal, Audiointerface<br>phrases: wähle die Buchse, an der mein Mikrofon steckt; stelle den Mikrofonkanal an meinem Audiointerface ein |
| Search (es) | words: toma, puerto, canal, interfaz de audio<br>phrases: elegir la toma a la que está conectado el micro en mi interfaz de audio |
| Search (fr) | words: prise micro, canal micro, port micro, interface audio<br>phrases: choisir la prise de mon interface audio sur laquelle le micro est branché |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: entrada 1, entrada 2, entrada numerada<br>phrases: seleccionar el número de entrada al que está conectado este micrófono |
| Search (fr) | words: entrée 1, entrée 2, entrée numérotée<br>phrases: sélectionner le numéro de l’entrée où mon micro est branché |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation"></a>

### Media during dictation / Medien beim Diktieren / Contenido multimedia durante el dictado / Audio pendant la dictée (`mediaDuringDictation`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Media during dictation` |
| Description | What music and video do while you dictate. / Was beim Diktieren mit Musik und Videos passiert. / Qué ocurre con la música y el vídeo mientras dictas. / Ce qui arrive à la musique et aux vidéos pendant que vous dictez. |
| Description source | catalog key `What music and video do while you dictate.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`mediaDuringDictation`](#node-mediaDuringDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: music, video, podcast, playback, media<br>phrases: what should happen to my music while I dictate; choose how videos behave during recording; change what happens to background audio during dictation |
| Search (de) | words: Musik, Video, Podcast, Wiedergabe, Hintergrundton<br>phrases: was soll mit meiner Musik beim Diktieren passieren; stelle ein, was Videos während der Aufnahme machen; ändere, was beim Diktieren mit dem Hintergrundton passiert |
| Search (es) | words: música, vídeo, podcast, reproducción, multimedia, Audio y vídeo durante el dictado<br>phrases: elegir qué pasa con la música y los vídeos mientras dicto |
| Search (fr) | words: musique, vidéo, podcast, lecture audio<br>phrases: choisir ce qui arrive à la musique et aux vidéos pendant que je dicte |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness"></a>

### Microphone readiness / Mikrofonbereitschaft / Disponibilidad del micrófono / Disponibilité du micro (`micReadiness`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Microphone readiness` |
| Description | How long the mic stays ready after recording. / Wie lange das Mikrofon nach der Aufnahme bereit bleibt. / Cuánto tiempo permanece listo el micrófono después de grabar. / Durée pendant laquelle le micro reste prêt après l’enregistrement. |
| Description source | catalog key `How long the mic stays ready after recording.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`micReadiness`](#node-micReadiness) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: standby, warmup, readiness<br>phrases: choose how long the microphone stays ready after recording; keep the mic ready between recordings; change the microphone standby time |
| Search (de) | words: Standby, Bereitschaft, warmhalten<br>phrases: wie lange soll das Mikro nach der Aufnahme bereit bleiben; halte das Mikrofon zwischen Aufnahmen bereit; ändere die Bereitschaftszeit des Mikrofons |
| Search (es) | words: micro en espera, standby del micro, tiempo del micro, Mantener el micrófono listo<br>phrases: elegir cuánto tiempo queda listo el micro entre grabaciones |
| Search (fr) | words: micro prêt, disponibilité du micro, standby micro<br>phrases: choisir combien de temps le micro reste prêt après un enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-silentMicWarning"></a>

### Warn when the microphone is silent / Bei Mikrofonstille warnen / Avisar si el micrófono está en silencio / Avertir en cas de silence du micro (`silentMicWarning`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Warn when the microphone is silent` |
| Description | Shows a notice on the pill when no sound arrives. / Zeigt einen Hinweis an der Aufnahmeanzeige, wenn kein Ton ankommt. / Muestra un aviso en la píldora de grabación cuando no llega sonido. / Affiche un avis sur la pastille d’enregistrement quand aucun son n’arrive. |
| Description source | catalog key `Shows a notice on the pill when no sound arrives.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`silentMicWarning`](#node-silentMicWarning) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: silence warning, silent input alert<br>phrases: warn me if nothing comes through while I dictate; turn off the silence warning on the recording pill |
| Search (de) | words: Stillewarnung, Stillehinweis<br>phrases: warne mich, wenn beim Diktieren kein Ton ankommt; schalte den Hinweis bei fehlendem Ton auf der Aufnahmeanzeige aus |
| Search (es) | words: aviso de micrófono sin sonido, alerta de micrófono en silencio<br>phrases: cómo activar el aviso si el micro no capta sonido al dictar; cómo quitar el aviso de micrófono en silencio |
| Search (fr) | words: alerte micro, avertissement micro, alerte micro muet<br>phrases: me prévenir si mon micro ne capte rien pendant la dictée; désactiver l’alerte quand aucun son ne vient du micro |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-bluetoothGuide"></a>

### Using a Bluetooth microphone? / Verwendest du ein Bluetooth-Mikrofon? / ¿Usas un micrófono Bluetooth? / Vous utilisez un micro Bluetooth ? (`bluetoothGuide`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.microphone`](#node-section-microphone) |
| Title source | catalog key `Using a Bluetooth microphone?` |
| Description | Keeping your mic ready reduces Bluetooth startup delay. / Ein bereites Mikrofon verkürzt die Startverzögerung bei Bluetooth. / Mantener listo el micrófono reduce la demora al empezar a grabar por Bluetooth. / Maintenir votre micro prêt réduit le délai de démarrage du Bluetooth. |
| Description source | catalog key `Keeping your mic ready reduces Bluetooth startup delay.` |
| Destination | `dictation` › `microphone` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`bluetoothGuide`](#node-bluetoothGuide) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Bluetooth, startup<br>phrases: why does my Bluetooth mic take so long to start; how can I reduce Bluetooth microphone startup delay; explain how keeping my Bluetooth mic ready helps |
| Search (de) | words: Bluetooth, Startverzögerung, Anlaufzeit<br>phrases: warum braucht mein Bluetooth-Mikro so lange zum Starten; wie startet mein Bluetooth-Mikro schneller; erkläre mir, warum ein bereites Mikro bei Bluetooth hilft |
| Search (es) | words: retraso Bluetooth, arranque Bluetooth<br>phrases: por qué tarda tanto en arrancar mi micro Bluetooth; cómo ayuda mantener listo el micro Bluetooth |
| Search (fr) | words: démarrage Bluetooth, retard Bluetooth, latence Bluetooth<br>phrases: pourquoi mon micro Bluetooth met du temps à démarrer |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-bluetoothGuide-learnMore"></a>

### Learn more / Mehr erfahren / Más información / En savoir plus (`bluetoothGuide.learnMore`)

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
| Search (es) | words: guía Bluetooth, ayuda Bluetooth, Más información sobre micrófonos Bluetooth<br>phrases: abrir la guía para reducir el retraso del micro Bluetooth |
| Search (fr) | words: aide Bluetooth<br>phrases: ouvrir le guide sur le délai de démarrage des micros Bluetooth |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview"></a>

### Show words while you speak / Wörter beim Sprechen anzeigen / Mostrar las palabras mientras hablas / Afficher les mots pendant que vous parlez (`livePreview`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.livePreview`](#node-section-livePreview) |
| Title source | catalog key `Show words while you speak` |
| Description | See words before you finish your dictation. / Sieh den Text schon während des Diktierens. / Ve el texto antes de terminar tu dictado. / Voir les mots avant la fin de votre dictée. |
| Description source | catalog key `See words before you finish your dictation.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`livePreview`](#node-livePreview) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: realtime, interim, live<br>phrases: show my words before I finish dictating; let me see my text while I speak; turn the live text preview on or off |
| Search (de) | words: Echtzeit, mitlesen, Zwischentext<br>phrases: zeig mir meinen Text, bevor ich fertig diktiert habe; ich möchte meine Wörter beim Sprechen mitlesen; schalte die Live-Vorschau ein oder aus |
| Search (es) | words: texto en vivo, tiempo real, texto provisional<br>phrases: activar o desactivar el texto que aparece mientras hablo |
| Search (fr) | words: texte en direct, temps réel, affichage en direct<br>phrases: activer ou désactiver l’affichage du texte pendant que je parle |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview-language"></a>

### (named at runtime by `previewLanguage`) (`livePreview.language`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`livePreview`](#node-livePreview) |
| Title source | resolver `previewLanguage` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | This changes dictation too, not just the preview. / Das ändert auch das Diktat, nicht nur die Vorschau. / Esto también cambia el dictado, no solo la vista previa. / Cela modifie aussi la dictée, pas seulement l’aperçu. |
| Description source | catalog key `This changes dictation too, not just the preview.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewLanguageKnown` |
| Arrival target | [`livePreview.language`](#node-livePreview-language) |
| Fallbacks, in order | [`livePreview`](#node-livePreview) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change the dictation language from Live Preview settings; change the preview language and dictation language together here |
| Search (de) | phrases: ändere die Diktiersprache in den Einstellungen der Live-Vorschau; ändere hier die Sprache für Vorschau und Diktat zusammen |
| Search (es) | words: idioma desde Live Preview, idioma desde vista previa<br>phrases: cambiar el idioma del dictado y la vista previa desde la pestaña de vista previa |
| Search (fr) | words: changer la langue d’aperçu, langue de dictée, modifier la langue de dictée<br>phrases: changer la langue de dictée et d’aperçu depuis l’onglet Aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-livePreview-browseDownloads"></a>

### Browse downloads / Downloads ansehen / Explorar descargas / Parcourir les téléchargements (`livePreview.browseDownloads`)

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
| Search (es) | words: descargas de vista previa<br>phrases: ver la lista de descargas desde los ajustes de vista previa |
| Search (fr) | words: téléchargements de l’aperçu<br>phrases: ouvrir la liste des téléchargements depuis les réglages de l’aperçu |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine"></a>

### Preview engine / Vorschau-Engine / Motor de vista previa / Moteur d’aperçu (`previewEngine`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.previewEngine`](#node-section-previewEngine) |
| Title source | catalog key `Preview engine` |
| Description | Choose which engine shows words while you speak. / Wähle die Engine, die Wörter beim Sprechen anzeigt. / Elige el motor que muestra las palabras mientras hablas. / Choisissez le moteur qui affiche les mots pendant que vous parlez. |
| Description source | catalog key `Choose which engine shows words while you speak.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose which engine recognizes the live preview text; which model powers the words shown while I speak; where do I choose the preview engine |
| Search (de) | words: Vorschaumodell<br>phrases: wähle die Engine für die Wörter in der Live-Vorschau; welches Modell erkennt den Text, den ich beim Sprechen sehe; wo wähle ich die Vorschau-Engine aus |
| Search (es) | words: modelo de vista previa, motor del texto en vivo<br>phrases: qué motor reconoce las palabras de la vista previa |
| Search (fr) | words: moteur d’aperçu, modèle d’aperçu<br>phrases: où choisir le moteur qui reconnaît le texte de l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-change"></a>

### Change / Ändern / Cambiar / Modifier (`previewEngine.change`)

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
| Search (es) | words: cambiar modelo de vista previa<br>phrases: cambiar el motor que muestra las palabras mientras hablo |
| Search (fr) | words: changer de moteur d’aperçu<br>phrases: passer à un autre moteur pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-compare"></a>

### Compare engines / Engines vergleichen / Comparar motores / Comparer les moteurs (`previewEngine.compare`)

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
| Search (es) | words: comparar Apple y Universal, diferencias Apple Universal<br>phrases: ver las diferencias entre Apple y Universal para la vista previa |
| Search (fr) | words: comparatif aperçu, Apple contre Universal<br>phrases: comparer Apple et Universal pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-keepCurrent"></a>

### Keep current preview engine / Aktuelle Vorschau-Engine beibehalten / Mantener el motor de vista previa actual / Conserver le moteur d’aperçu actuel (`previewEngine.keepCurrent`)

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
| Search (es) | words: mantener motor de vista previa, conservar modelo de vista previa<br>phrases: dejar el motor de vista previa como está |
| Search (fr) | words: garder le moteur d’aperçu<br>phrases: conserver mon moteur d’aperçu actuel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-download"></a>

### Download / Laden / Descargar / Télécharger (`previewEngine.universal.download`)

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
| Search (es) | words: instalar Universal<br>phrases: descargar Universal para la vista previa |
| Search (fr) | words: installer Universal<br>phrases: télécharger le modèle Universal pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-cancel"></a>

### Cancel / Abbrechen / Cancelar / Annuler (`previewEngine.universal.cancel`)

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
| Search (es) | words: cancelar Universal, detener descarga Universal<br>phrases: cancelar la descarga del modelo Universal |
| Search (fr) | words: annuler Universal<br>phrases: arrêter le téléchargement du modèle Universal |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-resume"></a>

### Resume / Fortsetzen / Reanudar / Reprendre (`previewEngine.universal.resume`)

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
| Search (es) | words: reanudar Universal, continuar descarga Universal<br>phrases: seguir descargando Universal donde se quedó |
| Search (fr) | words: reprendre Universal<br>phrases: reprendre le téléchargement d’Universal là où il s’est arrêté |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-retry"></a>

### Try Again / Erneut versuchen / Intentar de nuevo / Réessayer (`previewEngine.universal.retry`)

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
| Search (es) | words: reintentar Universal, descarga Universal fallida<br>phrases: volver a intentar descargar Universal después del fallo |
| Search (fr) | words: réessayer Universal<br>phrases: relancer le téléchargement d’Universal après son échec |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal-remove"></a>

### Remove / Entfernen / Eliminar / Supprimer (`previewEngine.universal.remove`)

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
| Search (es) | words: borrar Universal, desinstalar Universal<br>phrases: borrar el modelo Universal de mi Mac |
| Search (fr) | words: désinstaller Universal<br>phrases: supprimer le modèle d’aperçu Universal de mon Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewLanguages"></a>

### Languages / Sprachen / Idiomas / Langues (`previewLanguages`)

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
| Search (es) | words: paquetes instalados<br>phrases: ver qué idiomas de vista previa tengo instalados |
| Search (fr) | words: langues installées, packs installés<br>phrases: quelles langues sont déjà installées pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewLanguages-install"></a>

### (named at runtime by `previewLanguagesInstall`) (`previewLanguages.install`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`previewLanguages`](#node-previewLanguages) |
| Title source | resolver `previewLanguagesInstall` in [SettingsMap.title(of:)](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift) |
| Description | Download a language from macOS to preview it. / Lade für die Vorschau ein Sprachpaket von macOS herunter. / Descarga el paquete de idioma en macOS para usarlo en la vista previa. / Téléchargez une langue depuis macOS pour en afficher un aperçu. |
| Description source | catalog key `Download a language from macOS to preview it.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `appleLanguagePacks` |
| Arrival target | [`previewLanguages`](#node-previewLanguages) |
| Fallbacks, in order | [`previewEngine`](#node-previewEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: download another macOS language for live preview; install a new Apple language pack for the text preview |
| Search (de) | phrases: lade eine weitere macOS-Sprache für die Live-Vorschau herunter; installiere ein neues Apple-Sprachpaket für die Textvorschau |
| Search (es) | words: instalar idioma Apple, descargar idioma de vista previa, Instalar nuevos idiomas<br>phrases: instalar otro idioma de macOS para la vista previa |
| Search (fr) | words: installer une langue Apple<br>phrases: télécharger une nouvelle langue macOS pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition"></a>

### Position on screen / Position auf dem Bildschirm / Posición en pantalla / Position à l’écran (`pillPosition`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.pill`](#node-section-pill) |
| Title source | catalog key `Position on screen` |
| Description | Where the pill floats while you dictate. / Wo die Aufnahmeanzeige beim Diktieren schwebt. / Dónde flota la píldora mientras dictas. / Où flotte la pastille pendant que vous dictez. |
| Description source | catalog key `Where the pill floats while you dictate.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillPosition`](#node-pillPosition) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: placement, location, move<br>phrases: change where the recording pill appears on screen; move the floating recording indicator; choose the recording widget's screen position |
| Search (de) | words: verschieben, Anzeigeort, Platzierung<br>phrases: ändere, wo die Aufnahmeanzeige auf dem Bildschirm erscheint; verschiebe die schwebende Aufnahmeanzeige; stelle die Position des Aufnahmefensters ein |
| Search (es) | words: posición del indicador, mover widget, ubicación del indicador<br>phrases: cambiar dónde aparece el indicador de grabación |
| Search (fr) | words: position du widget, emplacement de l’indicateur<br>phrases: régler où l’indicateur d’enregistrement apparaît à l’écran |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle"></a>

### Style / Stil / Estilo / Style (`pillStyle`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.pill`](#node-section-pill) |
| Title source | catalog key `Style` |
| Description | What the floating pill shows while you record. / Was die Aufnahmeanzeige während der Aufnahme zeigt. / Qué muestra la píldora flotante mientras grabas. / Ce qu’affiche la pastille flottante pendant l’enregistrement. |
| Description source | catalog key `What the floating pill shows while you record.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: appearance, design, layout<br>phrases: change what the recording pill looks like; choose what the floating recording indicator displays; change the recording widget design |
| Search (de) | words: Aussehen, Design, Layout<br>phrases: ändere das Aussehen der Aufnahmeanzeige; wähle, was die schwebende Aufnahmeanzeige zeigt; stelle das Design des Aufnahmefensters ein |
| Search (es) | words: diseño del indicador, aspecto del widget<br>phrases: cambiar el aspecto y lo que muestra el indicador de grabación |
| Search (fr) | words: style du widget, design de l’indicateur<br>phrases: choisir l’apparence de l’indicateur flottant d’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-configureLivePreview"></a>

### Configure Live Preview / Live-Vorschau einrichten / Configurar la Vista previa en tiempo real / Configurer l’Aperçu en direct (`pillStyle.configureLivePreview`)

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
| Search (es) | words: vista previa desde indicador, Configurar vista previa en vivo<br>phrases: abrir los ajustes de vista previa desde los estilos del indicador de grabación |
| Search (fr) | words: aperçu depuis l’indicateur<br>phrases: ouvrir les réglages de l’aperçu depuis les styles de l’indicateur |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChimes"></a>

### Play recording chimes / Aufnahmesignaltöne abspielen / Reproducir tonos de grabación / Lire les sons de début et de fin d’enregistrement (`recordingChimes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.chimes`](#node-section-chimes) |
| Title source | catalog key `Play recording chimes` |
| Description | Plays a short chime when recording starts and stops. / Spielt beim Start und Ende der Aufnahme einen kurzen Signalton. / Reproduce un tono breve al iniciar y detener la grabación. / Émet un bref signal sonore au début et à la fin de l’enregistrement. |
| Description source | catalog key `Plays a short chime when recording starts and stops.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChimes`](#node-recordingChimes) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: beep, beeps, cues, chiming<br>phrases: turn recording start and stop sounds on or off; play a sound when recording begins and ends; disable the beeps at the start and end of recording |
| Search (de) | words: piepen, Piepton, Pieptöne, Aufnahmetöne<br>phrases: schalte die Töne für Aufnahmestart und Aufnahmeende ein oder aus; spiel einen Ton, wenn die Aufnahme beginnt und endet; schalte das Piepen beim Starten und Stoppen der Aufnahme aus |
| Search (es) | words: pitidos, beeps, sonido de inicio, sonido de fin<br>phrases: activar o desactivar los sonidos al empezar y terminar de grabar |
| Search (fr) | words: bips, signaux sonores, sons début-fin<br>phrases: activer ou désactiver les sons au début et à la fin de l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime"></a>

### RECORDING CHIMES / AUFNAHMESIGNALTÖNE / SONIDOS DE GRABACIÓN / SONS D’ENREGISTREMENT (`recordingChime`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.chimes`](#node-section-chimes) |
| Title source | catalog key `RECORDING CHIMES` |
| Description | Hear this chime without changing your choice. / Hör dir diesen Signalton an, ohne deine Auswahl zu ändern. / Escucha esta señal sin cambiar tu elección. / Écoutez cette sonnerie sans modifier votre choix. |
| Description source | catalog key `Hear this chime without changing your choice.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: audition, sample, listen<br>phrases: let me hear this recording sound before choosing it; play a chime sample without changing my selection; test this recording sound |
| Search (de) | words: probehören, Klangprobe, anhören, Tonprobe<br>phrases: spiel mir diesen Aufnahmeton zur Probe vor; lass mich den Ton hören, ohne meine Auswahl zu ändern; ich möchte diesen Ton erst einmal anhören |
| Search (es) | words: muestra de sonido, prueba sin selección<br>phrases: se puede probar un sonido sin cambiar el que tengo elegido |
| Search (fr) | words: échantillon sonore, essai sans sélection<br>phrases: où tester un son d’enregistrement sans modifier mon choix |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: reproducir muestra, probar sonido, Escuchar sonido<br>phrases: reproducir este sonido para escucharlo sin cambiar mi selección |
| Search (fr) | words: écouter, écouter le son<br>phrases: faire entendre ce son d’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-automaticDictationPaste"></a>

### Paste dictations automatically / Diktate automatisch einfügen / Pegar dictados automáticamente / Coller automatiquement les dictées (`automaticDictationPaste`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Paste dictations automatically` |
| Description | Turn this off to keep your latest dictation on the clipboard for manual paste. / Wenn du das ausschaltest, bleibt dein letztes Diktat zum manuellen Einfügen in der Zwischenablage. / Desactiva esto para conservar tu último dictado en el portapapeles y pegarlo manualmente. / Désactivez cette option pour conserver votre dernière dictée dans le presse-papiers et la coller manuellement. |
| Description source | catalog key `Turn this off to keep your latest dictation on the clipboard for manual paste.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`automaticDictationPaste`](#node-automaticDictationPaste) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: auto-paste, automatic pasting, manual paste, clipboard only<br>phrases: paste my dictation automatically; stop pasting my dictation automatically; copy every dictation to the clipboard so I can paste it myself |
| Search (de) | words: Diktat manuell einfügen<br>phrases: automatisches Einfügen nach dem Diktieren ausschalten; letztes Diktat in der Zwischenablage behalten und selbst einfügen |
| Search (es) | words: pegado automático, pegado manual, autopegado<br>phrases: pegar automáticamente el texto al terminar de dictar; desactivar el pegado automático de los dictados; dejar cada dictado en el portapapeles para pegarlo a mano |
| Search (fr) | words: collage automatique, collage manuel, collage auto<br>phrases: coller automatiquement le texte à la fin de chaque dictée; désactiver le collage automatique des dictées; garder chaque dictée dans le presse-papiers pour la coller moi-même |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-autoCopyToClipboard"></a>

### Auto-copy to clipboard / Automatisch in die Zwischenablage kopieren / Copiar automáticamente al portapapeles / Copier automatiquement dans le presse-papiers (`autoCopyToClipboard`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Auto-copy to clipboard` |
| Description | Copies dictation when automatic pasting is skipped. / Kopiert dein Diktat, wenn das automatische Einfügen übersprungen wird. / Copia tu dictado cuando se omite el pegado automático. / Copie votre dictée lorsque le collage automatique est ignoré. |
| Description source | catalog key `Copies dictation when automatic pasting is skipped.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`autoCopyToClipboard`](#node-autoCopyToClipboard) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: copy my dictation when automatic pasting is skipped; keep my dictation on the clipboard if it is not pasted |
| Search (de) | phrases: kopiere mein Diktat, wenn es nicht automatisch eingefügt wird; leg mein Diktat in die Zwischenablage, wenn das Einfügen übersprungen wird |
| Search (es) | words: copia automática, copiar sin pegar<br>phrases: copiar el dictado al portapapeles si se omite el pegado automático |
| Search (fr) | words: copie automatique, dictée non collée<br>phrases: copier ma dictée dans le presse-papiers quand le collage automatique est ignoré |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-restoreClipboard"></a>

### Restore clipboard after paste / Zwischenablage nach dem Einfügen wiederherstellen / Restaurar el portapapeles después de pegar / Restaurer le presse-papiers après le collage (`restoreClipboard`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Restore clipboard after paste` |
| Description | Puts back what was on your clipboard before pasting. / Stellt den vorherigen Inhalt der Zwischenablage nach dem Einfügen wieder her. / Recupera lo que había en el portapapeles antes de pegar. / Restaure le contenu précédent du presse-papiers après le collage. |
| Description source | catalog key `Puts back what was on your clipboard before pasting.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`restoreClipboard`](#node-restoreClipboard) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: put my previous clipboard contents back after pasting; keep what I copied before dictating |
| Search (de) | phrases: stell nach dem Einfügen meinen alten Zwischenablageinhalt wieder her; behalte das, was ich vor dem Diktieren kopiert habe |
| Search (es) | words: restaurar portapapeles, copia anterior<br>phrases: recuperar lo que tenía copiado antes de pegar el dictado |
| Search (fr) | words: contenu précédent, restauration du presse-papiers<br>phrases: remettre ce que j’avais copié avant le collage de ma dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-keepOutOfClipboardHistory"></a>

### Hide dictations from clipboard manager apps / Diktate vor Zwischenablage-Managern verbergen / Ocultar los dictados a las apps de gestión del portapapeles / Masquer les dictées aux gestionnaires de presse-papiers (`keepOutOfClipboardHistory`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Hide dictations from clipboard manager apps` |
| Description | For apps like Raycast and Maccy. / Für Apps wie Raycast und Maccy. / Para apps como Raycast y Maccy. / Pour les apps comme Raycast et Maccy. |
| Description source | catalog key `For apps like Raycast and Maccy.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`keepOutOfClipboardHistory`](#node-keepOutOfClipboardHistory) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Raycast, Maccy, clipboard history<br>phrases: keep dictations out of clipboard history; don't save dictated text in Maccy |
| Search (de) | words: Raycast, Maccy, Zwischenablageverlauf, Clipboard-Manager, Clipboard-Historie<br>phrases: Diktate nicht im Zwischenablageverlauf speichern; Maccy soll Diktate nicht speichern |
| Search (es) | words: Raycast, Maccy, historial del portapapeles, ocultar los dictados a los gestores del portapapeles<br>phrases: no guardar dictados en el historial del portapapeles; ocultar mis dictados a Maccy |
| Search (fr) | words: Raycast, Maccy, historique du presse-papiers<br>phrases: ne pas enregistrer mes dictées dans l’historique de Raycast; masquer mes dictées à Maccy |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-smartInsertion"></a>

### Smart insertion / Intelligentes Einfügen / Inserción inteligente / Insertion intelligente (`smartInsertion`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.clipboard`](#node-section-clipboard) |
| Title source | catalog key `Smart insertion` |
| Description | Fits text to the spacing and capitals around your cursor. / Passt Abstände und Großschreibung an den Text um den Cursor an. / Ajusta los espacios y las mayúsculas del texto que insertas según lo que rodea al cursor. / Adapte les espaces et les majuscules au texte autour du curseur. |
| Description source | catalog key `Fits text to the spacing and capitals around your cursor.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`smartInsertion`](#node-smartInsertion) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: spacing, capitalization, spaces, cursor<br>phrases: fit the spaces around my cursor; match capital letters to the surrounding text |
| Search (de) | words: Leerzeichen, Großschreibung, Abstände, Cursor<br>phrases: pass die Leerzeichen an den Text um den Cursor an; pass die Großschreibung an den umgebenden Text an |
| Search (es) | words: espacios, mayúsculas, cursor, Smart Insertion<br>phrases: ajustar los espacios y las mayúsculas al texto que rodea el cursor |
| Search (fr) | words: espaces, majuscules, curseur, espacement<br>phrases: adapter les espaces et les majuscules au texte autour du curseur |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAddClipboardFallback"></a>

### Read selections through the clipboard / Auswahl über die Zwischenablage lesen / Leer las selecciones mediante el portapapeles / Lire les sélections via le presse-papiers (`quickAddClipboardFallback`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.quickAddClipboard`](#node-section-quickAddClipboard) |
| Title source | catalog key `Read selections through the clipboard` |
| Description | Reads hidden selections and restores your clipboard. / Liest verborgene Auswahlen und stellt die Zwischenablage wieder her. / Lee el texto seleccionado que otras apps no comparten y restaura el portapapeles. / Lit les sélections masquées et restaure votre presse-papiers. |
| Description source | catalog key `Reads hidden selections and restores your clipboard.` |
| Destination | `dictation` › `clipboard` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`quickAddClipboardFallback`](#node-quickAddClipboardFallback) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use the clipboard to read a selected dictionary word; read my selected word when the app hides the selection |
| Search (de) | phrases: lies das markierte Wort fürs Wörterbuch über die Zwischenablage; erkenne mein markiertes Wort auch dann, wenn die App die Auswahl nicht freigibt |
| Search (es) | words: selección oculta, lectura por portapapeles<br>phrases: usar el portapapeles para leer la palabra seleccionada cuando la otra app oculta la selección |
| Search (fr) | words: sélection masquée, lecture du presse-papiers<br>phrases: utiliser le presse-papiers pour lire le mot sélectionné quand l’application masque la sélection |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode"></a>

### Recording mode / Aufnahmemodus / Modo de grabación / Mode d’enregistrement (`recordingMode`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Recording mode` |
| Description | Hold to talk, or press once to start and again to stop. / Zum Sprechen gedrückt halten oder einmal zum Starten und noch einmal zum Stoppen drücken. / Mantén pulsado para hablar o pulsa una vez para empezar a grabar y otra para detener la grabación. / Maintenez la touche enfoncée pour parler, ou appuyez une fois pour démarrer et une autre fois pour arrêter. |
| Description source | catalog key `Hold to talk, or press once to start and again to stop.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingMode`](#node-recordingMode) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: behavior, activation<br>phrases: change how the dictation key works; choose between holding the key and pressing it twice |
| Search (de) | words: Tastenverhalten, Bedienung<br>phrases: stell ein, wie die Diktattaste funktioniert; lass mich zwischen Gedrückthalten und zweimaligem Drücken wählen |
| Search (es) | words: activación por tecla<br>phrases: elegir cómo funciona la tecla de dictado |
| Search (fr) | words: mode d’activation, comportement de la touche<br>phrases: régler le fonctionnement de la touche de dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordKeybind"></a>

### Start / stop recording / Aufnahme starten / stoppen / Iniciar o detener la grabación / Démarrer/arrêter l’enregistrement (`recordKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Start / stop recording` |
| Description | Click Change to choose the keys you use. / Klicke auf „Ändern“, um deine Tasten festzulegen. / Haz clic en Cambiar para elegir las teclas que usas. / Cliquez sur « Modifier » pour choisir les touches que vous utilisez. |
| Description source | catalog key `Click Change to choose the keys you use.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordKeybind`](#node-recordKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change my dictation shortcut; choose the keys that start and stop recording |
| Search (de) | words: Diktattaste, Diktierkürzel<br>phrases: ändere mein Tastenkürzel fürs Diktieren; leg die Tasten zum Starten und Stoppen der Aufnahme fest |
| Search (es) | words: atajo de dictado, tecla de grabación<br>phrases: cambiar las teclas para empezar y terminar de grabar |
| Search (fr) | words: raccourci dictée, touche d’enregistrement<br>phrases: choisir les touches qui démarrent et arrêtent la dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-cancelKeybind"></a>

### Cancel recording / Aufnahme abbrechen / Cancelar grabación / Annuler l’enregistrement (`cancelKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Cancel recording` |
| Description | Cancels the current recording. / Bricht die laufende Aufnahme ab. / Cancela la grabación actual. / Annule l’enregistrement en cours. |
| Description source | catalog key `Cancels the current recording.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`cancelKeybind`](#node-cancelKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: abort<br>phrases: change the shortcut that cancels recording; choose a key to discard the current recording |
| Search (de) | words: Abbruchtaste, Abbruchkürzel<br>phrases: ändere mein Tastenkürzel zum Abbrechen der Aufnahme; leg eine Taste zum Verwerfen der laufenden Aufnahme fest |
| Search (es) | words: atajo para cancelar, tecla de cancelación<br>phrases: elegir la tecla que cancela la grabación actual |
| Search (fr) | words: raccourci annulation, touche d’annulation<br>phrases: choisir la touche qui annule l’enregistrement en cours |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-escapeRecovery"></a>

### Escape Recovery / Wiederherstellung bei Escape / Recuperación con Escape / Récupération avec Échap (`escapeRecovery`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsRecording`](#node-section-keybindsRecording) |
| Title source | catalog key `Escape Recovery` |
| Description | Keeps cancelled dictations in History for 24 hours. / Behält abgebrochene Diktate 24 Stunden lang im Verlauf. / Conserva los dictados cancelados en el Historial durante 24 horas. / Conserve les dictées annulées dans l’Historique pendant 24 heures. |
| Description source | catalog key `Keeps cancelled dictations in History for 24 hours.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`escapeRecovery`](#node-escapeRecovery) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recover, recovery, history<br>phrases: keep cancelled dictations for 24 hours; recover my dictation after I accidentally press escape |
| Search (de) | words: retten, Verlauf, Wiederherstellung<br>phrases: bewahre abgebrochene Diktate 24 Stunden lang auf; rette mein Diktat, wenn ich versehentlich Escape drücke |
| Search (es) | words: recuperación, Escape, dictados cancelados, 24 horas<br>phrases: guardar los dictados cancelados en el historial durante 24 horas; recuperar mi dictado si pulso Escape por accidente |
| Search (fr) | words: dictée annulée, récupération, Échap, historique 24 h<br>phrases: garder les dictées annulées dans l’historique pendant 24 heures; récupérer ma dictée après un appui accidentel sur Échap |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAddKeybind"></a>

### Add selected word to Dictionary / Markiertes Wort zum Wörterbuch hinzufügen / Añadir la palabra seleccionada al Diccionario / Ajouter le mot sélectionné au Dictionnaire (`quickAddKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Add selected word to Dictionary` |
| Description | Select a misheard word, then press these keys. / Markiere ein falsch erkanntes Wort und drücke dann diese Tasten. / Selecciona una palabra mal reconocida y pulsa estas teclas. / Sélectionnez un mot mal reconnu, puis appuyez sur ces touches. |
| Description source | catalog key `Select a misheard word, then press these keys.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`quickAddKeybind`](#node-quickAddKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: misheard, vocabulary<br>phrases: set a shortcut to add a selected word to the dictionary; add a misheard word with a key press |
| Search (de) | words: Wortschatz, Wörterbuchkürzel<br>phrases: leg ein Tastenkürzel zum Hinzufügen markierter Wörter fest; füge ein falsch erkanntes Wort per Tastendruck zum Wörterbuch hinzu |
| Search (es) | words: configurar atajo Quick Add, teclas para añadir palabras<br>phrases: configurar un atajo para añadir la palabra seleccionada al diccionario |
| Search (fr) | words: raccourci dictionnaire, touches ajout rapide<br>phrases: définir les touches pour ajouter un mot sélectionné au dictionnaire |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pasteLastKeybind"></a>

### Paste last dictation / Letztes Diktat einfügen / Pegar el último dictado / Coller la dernière dictée (`pasteLastKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Paste last dictation` |
| Description | Pastes your last dictation. / Fügt dein letztes Diktat ein. / Pega tu último dictado. / Colle votre dernière dictée. |
| Description source | catalog key `Pastes your last dictation.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pasteLastKeybind`](#node-pasteLastKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: reinsert<br>phrases: set a shortcut to paste my last dictation; insert what I just dictated again |
| Search (de) | phrases: leg ein Tastenkürzel zum Einfügen meines letzten Diktats fest; füge meinen zuletzt diktierten Text nochmal ein |
| Search (es) | words: atajo para pegar dictado, reinsertar dictado<br>phrases: configurar un atajo para pegar otra vez lo que acabo de dictar |
| Search (fr) | words: recoller, raccourci collage<br>phrases: définir un raccourci pour coller à nouveau ma dernière dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-copyLastKeybind"></a>

### Copy last dictation / Letztes Diktat kopieren / Copiar el último dictado / Copier la dernière dictée (`copyLastKeybind`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.keybindsShortcuts`](#node-section-keybindsShortcuts) |
| Title source | catalog key `Copy last dictation` |
| Description | Copies your last dictation. / Kopiert dein letztes Diktat. / Copia tu último dictado. / Copie votre dernière dictée. |
| Description source | catalog key `Copies your last dictation.` |
| Destination | `keybinds` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`copyLastKeybind`](#node-copyLastKeybind) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: set a shortcut to copy my last dictation; copy what I just dictated to the clipboard |
| Search (de) | phrases: leg ein Tastenkürzel zum Kopieren meines letzten Diktats fest; kopiere meinen zuletzt diktierten Text in die Zwischenablage |
| Search (es) | words: atajo para copiar dictado, copiar último dictado<br>phrases: configurar un atajo para copiar mi último dictado |
| Search (fr) | words: raccourci copie, copie dernière dictée<br>phrases: définir un raccourci pour copier ma dernière dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-keybind-resetToDefault"></a>

### Reset to default / Auf Standard zurücksetzen / Restablecer valor inicial / Rétablir par défaut (`keybind.resetToDefault`)

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
| Search (es) | words: teclas originales<br>phrases: volver a las teclas originales de este atajo |
| Search (fr) | words: réinitialiser le raccourci<br>phrases: remettre les touches d’origine de ce raccourci |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: pasos, etapas, progreso del archivo, pasos para transcribir un archivo<br>phrases: ver en qué paso está la transcripción de mi archivo |
| Search (fr) | words: étapes, avancement, progression<br>phrases: voir à quelle étape en est la transcription de mon fichier |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingCaptureCallSound"></a>

### Record only my voice / Nur meine Stimme aufnehmen / Grabar solo mi voz / Enregistrer uniquement ma voix (`meetingCaptureCallSound`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.general`](#node-meetings-tab-general) |
| Title source | catalog key `Record only my voice` |
| Description | Leaves out the sound your Mac plays, like the other people on a call. / Lässt den Ton weg, den dein Mac abspielt, zum Beispiel die Stimmen anderer Personen bei einem Anruf. / No graba el audio que reproduce tu Mac, como las voces de las otras personas en una llamada. / Omet les sons diffusés par votre Mac, comme les voix des autres participants à un appel. |
| Description source | catalog key `Leaves out the sound your Mac plays, like the other people on a call.` |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingCaptureCallSound`](#node-meetingCaptureCallSound) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: don't record computer audio; leave out other people's voices on calls |
| Search (de) | phrases: lass den Ton vom Mac bei Aufnahmen weg; nimm die anderen im Anruf nicht auf |
| Search (es) | phrases: no grabar el sonido del ordenador; excluir las voces de los demás en la llamada |
| Search (fr) | phrases: ne pas enregistrer le son de l'ordinateur; ne pas enregistrer les autres pendant un appel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingWriteSummary"></a>

### Write a summary when a meeting ends / Zusammenfassung erstellen, wenn ein Meeting endet / Escribir un resumen al terminar una reunión / Rédiger un résumé à la fin d’une réunion (`meetingWriteSummary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.summaries`](#node-meetings-tab-summaries) |
| Title source | catalog key `Write a summary when a meeting ends` |
| Description | The summary engine on this tab writes a summary of each meeting. / Die Zusammenfassungs-Engine in diesem Tab erstellt eine Zusammenfassung für jedes Meeting. / El motor de resúmenes de esta pestaña crea un resumen de cada reunión. / Le moteur de résumé de cet onglet crée un résumé pour chaque réunion. |
| Description source | catalog key `The summary engine on this tab writes a summary of each meeting.` |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingWriteSummary`](#node-meetingWriteSummary) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: automatically summarize meetings; write a summary when a meeting ends |
| Search (de) | phrases: nach jedem Meeting automatisch eine Zusammenfassung erstellen; automatische Meetingzusammenfassung nach Meetingende einschalten |
| Search (es) | words: crear un resumen al terminar la reunión<br>phrases: resumir la reunión al acabar; resumen automático de reuniones |
| Search (fr) | phrases: résumer la réunion une fois terminée; résumé automatique des réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine"></a>

### Summary engine / Zusammenfassungs-Engine / Motor de resúmenes / Moteur de résumé (`meetingSummaryEngine`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.summaries`](#node-meetings-tab-summaries) |
| Title source | catalog key `Summary engine` |
| Description | The AI that writes your meeting summaries. Separate from AI Polish for dictation. / Die KI, die deine Meeting-Zusammenfassungen erstellt. Getrennt von der KI-Nachbearbeitung für Diktate. / La IA que escribe los resúmenes de tus reuniones. Es independiente del Pulido con IA para el dictado. / L’IA qui rédige les résumés de vos réunions. Indépendante de la Retouche IA pour les dictées. |
| Description source | catalog key `The AI that writes your meeting summaries. Separate from AI Polish for dictation.` |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: which AI writes my meeting summaries; meeting summary engine setup |
| Search (de) | words: Zusammenfassungsmodell<br>phrases: welche KI erstellt deine Meetingzusammenfassungen; Engine für Meetingzusammenfassungen einstellen |
| Search (es) | words: modelo de resumen<br>phrases: qué IA escribe los resúmenes de mis reuniones; configurar el motor de resúmenes de reuniones |
| Search (fr) | words: moteur de résumé des réunions<br>phrases: quelle ia rédige mes résumés de réunion; configurer le moteur de résumé des réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-change"></a>

### Change / Ändern / Cambiar / Modifier (`meetingSummaryEngine.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine.change`](#node-meetingSummaryEngine-change) |
| Fallbacks, in order | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change AI for meeting summaries |
| Search (de) | phrases: andere KI für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: cambiar la IA para resumir reuniones |
| Search (fr) | phrases: changer l’ia pour les résumés de réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-keepCurrent"></a>

### Keep current summary engine / Aktuelle Zusammenfassungs-Engine beibehalten / Mantener el motor actual de resúmenes / Conserver le moteur de résumé actuel (`meetingSummaryEngine.keepCurrent`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | catalog key `Keep current summary engine` |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep using the same AI for meeting summaries |
| Search (de) | phrases: bisherige KI für Meetingzusammenfassungen behalten |
| Search (es) | phrases: seguir usando la misma IA para resumir reuniones; cerrar la selección sin cambiar el motor de resúmenes |
| Search (fr) | phrases: garder la même ia pour les résumés de réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTurnsOffDictation"></a>

### Turn off dictation during meetings / Diktieren während Meetings ausschalten / Desactivar el dictado durante las reuniones / Désactiver la dictée pendant les réunions (`meetingTurnsOffDictation`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.general`](#node-meetings-tab-general) |
| Title source | catalog key `Turn off dictation during meetings` |
| Description | The dictation key records nothing while a meeting is recording. / Solange ein Meeting aufgenommen wird, startet die Diktiertaste kein Diktat. / La tecla de dictado no graba nada mientras se graba una reunión. / La touche de dictée ne lance aucune dictée pendant l’enregistrement d’une réunion. |
| Description source | catalog key `The dictation key records nothing while a meeting is recording.` |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTurnsOffDictation`](#node-meetingTurnsOffDictation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: disable dictation while recording a meeting; dictation key does nothing during meeting recording |
| Search (de) | words: Meetingaufnahme, Besprechung<br>phrases: während einer Meetingaufnahme kein Diktat starten; schalte Diktieren im Meeting aus |
| Search (es) | phrases: desactivar dictado mientras se graba una reunión; la tecla de dictado no funciona al grabar una reunión |
| Search (fr) | phrases: bloquer la dictée pendant l’enregistrement d’une réunion; la touche de dictée ne fonctionne pas pendant l’enregistrement d’une réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingFollowsCallMute"></a>

### Leave my voice out when I'm muted / Meine Stimme weglassen, wenn ich stummgeschaltet bin / No grabar mi voz si mi micrófono está silenciado / Ne pas enregistrer ma voix quand mon micro est coupé (`meetingFollowsCallMute`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.general`](#node-meetings-tab-general) |
| Title source | catalog key `Leave my voice out when I'm muted` |
| Description | Follows the mute button in supported Zoom, Teams and Google Meet calls. / Richtet sich nach deiner Stummschaltung in unterstützten Anrufen mit Zoom, Teams und Google Meet. / Se guía por el botón de silencio en las llamadas compatibles de Zoom, Teams y Google Meet. / Suit le bouton de désactivation du son lors des appels pris en charge sur Zoom, Teams et Google Meet. |
| Description source | catalog key `Follows the mute button in supported Zoom, Teams and Google Meet calls.` |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingFollowsCallMute`](#node-meetingFollowsCallMute) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: leave my voice out of the meeting recording when I'm muted; record my mic even when I'm muted in a meeting |
| Search (de) | words: Stummschaltung, stummgeschaltet, Mikrofon, Stimme<br>phrases: meine Stimme nicht aufnehmen, wenn ich stumm bin; Stimme bei Stummschaltung weglassen; Stummschaltung in Google Meet |
| Search (es) | phrases: no grabar mi voz cuando estoy silenciado en Zoom; excluir mi voz de la grabación cuando silencio el micrófono en Teams; no incluir mi voz en la grabación cuando estoy silenciado en Google Meet |
| Search (fr) | words: sourdine, mute<br>phrases: ne pas enregistrer ma voix quand je suis en sourdine dans l’appel; exclure mon micro de l’enregistrement quand il est coupé dans Teams |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWords"></a>

### Live Preview / Live-Vorschau / Vista previa en tiempo real / Aperçu en direct (`meetingLiveWords`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Live Preview` |
| Description | The engine and language for words shown while a meeting records. / Engine und Sprache für die Live-Vorschau während einer Meeting-Aufnahme. / El motor y el idioma de las palabras que se muestran mientras se graba una reunión. / Le moteur et la langue des mots affichés pendant l’enregistrement d’une réunion. |
| Description source | catalog key `The engine and language for words shown while a meeting records.` |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingLiveWords`](#node-meetingLiveWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: live meeting transcript, real-time meeting text<br>phrases: change meeting live transcript language; choose engine for live meeting transcription |
| Search (de) | words: Live-Vorschau, Live-Transkript, Engine<br>phrases: Engine für die Live-Vorschau im Meeting wählen; Live-Vorschau für Meetings einrichten |
| Search (es) | words: texto en directo de reuniones, mostrar palabras mientras hablas en EnviousMeet<br>phrases: elegir el motor de la vista previa de EnviousMeet; usar Apple o Universal para mostrar texto provisional durante una reunión |
| Search (fr) | phrases: choisir le moteur de l’aperçu en direct des réunions dans EnviousMeet; régler le moteur et la langue du texte affiché pendant une réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWords-change"></a>

### Change / Ändern / Cambiar / Modifier (`meetingLiveWords.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingLiveWords`](#node-meetingLiveWords) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingLiveWords`](#node-meetingLiveWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the Live Preview engine choices in EnviousMeet |
| Search (de) | phrases: Engine für die Live-Vorschau im Meeting ändern |
| Search (es) | phrases: abrir las opciones del motor de transcripción en directo de reuniones en EnviousMeet |
| Search (fr) | phrases: afficher les moteurs disponibles pour la transcription en direct des réunions dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWords-keepCurrent"></a>

### Keep current Live Preview engine / Aktuelle Live-Vorschau-Engine beibehalten / Mantener el motor actual de Vista previa en tiempo real / Conserver le moteur actuel d’Aperçu en direct (`meetingLiveWords.keepCurrent`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingLiveWords`](#node-meetingLiveWords) |
| Title source | catalog key `Keep current Live Preview engine` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`meetingLiveWords`](#node-meetingLiveWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep using the same engine for live meeting transcription |
| Search (de) | phrases: bisherige Engine für die Live-Vorschau im Meeting behalten |
| Search (es) | words: mantener el motor actual de “Mostrar palabras mientras hablas” en EnviousMeet<br>phrases: cerrar las opciones sin cambiar el motor de la vista previa de EnviousMeet |
| Search (fr) | phrases: fermer le choix des moteurs sans changer le moteur de l’aperçu en direct des réunions dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWordsLanguage"></a>

### Live Preview language / Sprache der Live-Vorschau / Idioma de la Vista previa en tiempo real / Langue de l’Aperçu en direct (`meetingLiveWordsLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Live Preview language` |
| Description | The language Live Preview listens for during a meeting. / Die Sprache, die die Live-Vorschau während eines Meetings erkennt. / El idioma que reconoce la Vista previa en tiempo real durante una reunión. / La langue que l’Aperçu en direct écoute pendant une réunion. |
| Description source | catalog key `The language Live Preview listens for during a meeting.` |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingLiveWordsLanguage`](#node-meetingLiveWordsLanguage) |
| Fallbacks, in order | [`meetingLiveWords`](#node-meetingLiveWords) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change the live preview language for meetings; change the language of text shown while recording a meeting |
| Search (de) | words: Sprache, Live-Vorschau, Live-Text, Meeting<br>phrases: Sprache der Live-Vorschau ändern; Sprache für Live-Text im Meeting |
| Search (es) | phrases: cambiar el idioma de la vista previa en directo de la reunión |
| Search (fr) | phrases: changer la langue de l’aperçu en direct d’une réunion dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine"></a>

### Transcript engine / Transkript-Engine / Motor de transcripción / Moteur de transcription (`meetingTranscriptEngine`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Transcript engine` |
| Description | Chooses the engine that writes the full transcript after a meeting. / Wählt die Engine, die nach einem Meeting das vollständige Transkript erstellt. / Determina qué motor genera la transcripción completa después de una reunión. / Choisit le moteur qui rédige la transcription complète après une réunion. |
| Description source | catalog key `Chooses the engine that writes the full transcript after a meeting.` |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: meeting transcript engine<br>phrases: choose model for the full meeting transcript; change the engine for full meeting transcripts |
| Search (de) | phrases: Modell für das vollständige Meetingtranskript auswählen; Engine für die Transkription nach dem Meeting ändern |
| Search (es) | words: motor de transcripción de reuniones<br>phrases: elegir motor para la transcripción completa de la reunión; cambiar el motor que transcribe después de la reunión |
| Search (fr) | phrases: choisir le moteur qui transcrit toute la réunion une fois terminée; changer le moteur de transcription complète des réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine-change"></a>

### Change / Ändern / Cambiar / Modifier (`meetingTranscriptEngine.change`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Title source | catalog key `Change` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: open the full meeting transcript engine choices in EnviousMeet |
| Search (de) | phrases: Engine für das Transkript nach dem Meeting ändern |
| Search (es) | phrases: abrir las opciones del motor de transcripción completa de reuniones en EnviousMeet |
| Search (fr) | phrases: afficher les moteurs disponibles pour transcrire toute la réunion après l’enregistrement dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine-keepCurrent"></a>

### Keep current transcript engine / Aktuelle Transkript-Engine beibehalten / Mantener el motor actual de transcripción / Conserver le moteur de transcription actuel (`meetingTranscriptEngine.keepCurrent`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Title source | catalog key `Keep current transcript engine` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep using the same engine for meeting transcripts |
| Search (de) | phrases: bisherige Engine für das Transkript nach dem Meeting behalten |
| Search (es) | phrases: cerrar las opciones sin cambiar el motor de transcripción completa de reuniones en EnviousMeet |
| Search (fr) | phrases: fermer le choix des moteurs sans changer celui qui transcrit toute la réunion après l’enregistrement dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptAutoDetect"></a>

### Auto-detect language / Sprache automatisch erkennen / Detectar idioma automáticamente / Détecter automatiquement la langue (`meetingTranscriptAutoDetect`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Auto-detect language` |
| Description | composed at display time from live state (not exported) |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptAutoDetect`](#node-meetingTranscriptAutoDetect) |
| Fallbacks, in order | [`meetingTranscriptLanguage`](#node-meetingTranscriptLanguage) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: automatically detect the language for the full meeting transcript; turn off automatic language detection for meeting transcripts |
| Search (de) | words: Transkript, Spracherkennung, automatisch<br>phrases: Sprache des Transkripts automatisch erkennen; automatische Spracherkennung im Meeting |
| Search (es) | phrases: activar la detección automática del idioma en la transcripción final de la reunión; desactivar la detección automática del idioma al transcribir de nuevo una reunión |
| Search (fr) | phrases: détecter automatiquement la langue pour transcrire la réunion une fois terminée; désactiver la détection automatique de la langue pour la transcription des réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptLanguage"></a>

### Transcript language / Transkriptsprache / Idioma de la transcripción / Langue de transcription (`meetingTranscriptLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Transcript language` |
| Description | The language of the full transcript written after a meeting. / Die Sprache des vollständigen Transkripts, das nach einem Meeting erstellt wird. / El idioma de la transcripción completa que se crea después de una reunión. / La langue de la transcription complète créée après une réunion. |
| Description source | catalog key `The language of the full transcript written after a meeting.` |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptLanguage`](#node-meetingTranscriptLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: change meeting transcript language; language of the full transcript after a meeting |
| Search (de) | phrases: ändere die Sprache für das vollständige Transkript nach dem Meeting; in welcher Sprache wird das vollständige Transkript nach dem Meeting erstellt |
| Search (es) | phrases: cambiar el idioma de la transcripción completa de la reunión; detectar automáticamente el idioma de la transcripción final de la reunión; idioma de la transcripción que se genera al terminar la reunión |
| Search (fr) | phrases: choisir la langue de la transcription complète des prochaines réunions; langue du texte intégral après la réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSpeakerLabels"></a>

### Speaker labels / Sprecherkennzeichnung / Etiquetas de participantes / Libellés des intervenants (`meetingSpeakerLabels`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`meetings.tab.models`](#node-meetings-tab-models) |
| Title source | catalog key `Speaker labels` |
| Description | Shows who is talking in Live Preview while a meeting records. / Zeigt in der Live-Vorschau, wer gerade spricht, während ein Meeting aufgenommen wird. / Muestra quién está hablando en la Vista previa en tiempo real mientras se graba una reunión. / Affiche l’intervenant dans l’Aperçu en direct pendant l’enregistrement d’une réunion. |
| Description source | catalog key `Shows who is talking in Live Preview while a meeting records.` |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSpeakerLabels`](#node-meetingSpeakerLabels) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: diarization, speaker identification, speaker labels<br>phrases: who is talking in the meeting; show who is speaking in live preview |
| Search (de) | words: Sprecherzuordnung, Sprechererkennung, Sprechermodell<br>phrases: wer spricht gerade im Meeting; unterscheide Stimmen im Meeting |
| Search (es) | words: diferenciar voces, etiquetas de hablantes<br>phrases: quién está hablando en la reunión; mostrar quién habla en la vista previa en directo |
| Search (fr) | words: locuteurs, distinction des voix<br>phrases: qui parle en ce moment dans la réunion; afficher qui parle dans l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingUseCalendarForNames"></a>

### Name meetings from my calendar / Meetings nach meinem Kalender benennen / Nombrar reuniones según mi calendario / Nommer les réunions d’après mon calendrier (`meetingUseCalendarForNames`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.general`](#node-meetings-tab-general) |
| Title source | catalog key `Name meetings from my calendar` |
| Description | Uses the title of the calendar event at the time the meeting starts. / Nutzt den Titel des Kalendertermins zum Zeitpunkt, an dem das Meeting beginnt. / Usa el título del evento del calendario cuando comienza la reunión. / Utilise le titre de l’événement du calendrier au moment où la réunion commence. |
| Description source | catalog key `Uses the title of the calendar event at the time the meeting starts.` |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingUseCalendarForNames`](#node-meetingUseCalendarForNames) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: automatic naming, event title<br>phrases: use the calendar event title as the meeting name; automatically name meetings from calendar events |
| Search (de) | words: Terminname<br>phrases: nimm den Termintitel als Meetingnamen; benenne meine Meetings automatisch nach dem Kalender |
| Search (es) | words: calendario<br>phrases: usar el título del evento como nombre de la reunión; usar el calendario para nombrar las reuniones |
| Search (fr) | words: calendrier, titre de l’événement<br>phrases: utiliser le titre de l’événement du calendrier comme nom de réunion; nommer automatiquement les réunions d’après mon calendrier |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingCallDetection"></a>

### When a call starts / Wenn ein Anruf beginnt / Cuando comienza una llamada / Au début d’un appel (`meetingCallDetection`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.general`](#node-meetings-tab-general) |
| Title source | catalog key `When a call starts` |
| Description | EnviousMeet can ask to record when a call app starts using your microphone. / EnviousMeet kann dich fragen, ob du einen Anruf aufnehmen möchtest, sobald eine Anruf-App dein Mikrofon nutzt. / EnviousMeet puede preguntarte si quieres grabar cuando una app de llamadas empiece a usar tu micrófono. / EnviousMeet peut vous proposer d’enregistrer lorsqu’une app d’appel commence à utiliser votre micro. |
| Description source | catalog key `EnviousMeet can ask to record when a call app starts using your microphone.` |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingCallDetection`](#node-meetingCallDetection) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: call detection, recording prompt<br>phrases: ask me if I want to record a call; detect calls when an app uses my microphone |
| Search (de) | words: Anruferkennung, Aufnahmeabfrage<br>phrases: frag mich, ob ich den Anruf aufnehmen möchte; starte die Meetingaufnahme automatisch, wenn ein Anruf beginnt; schalte die automatische Anruferkennung aus |
| Search (es) | words: detección de llamadas, aviso de grabación, cuando empieza una llamada<br>phrases: preguntarme si quiero grabar la llamada; detectar llamadas cuando una app usa el micrófono |
| Search (fr) | words: détection des appels, enregistrement automatique<br>phrases: me demander si je veux enregistrer l’appel; enregistrer automatiquement quand un appel commence; désactiver la détection des appels |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingCallApps"></a>

### Notice calls in / Anrufe erkennen in / Detectar llamadas en / Détecter les appels dans (`meetingCallApps`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`meetings.tab.callApps`](#node-meetings-tab-callApps) |
| Title source | catalog key `Notice calls in` |
| Description | Turn off an app to never be asked about its calls. / Wenn du eine App ausschaltest, fragt EnviousMeet bei Anrufen über diese App nicht mehr nach. / Desactiva una app para que nunca se te vuelva a preguntar por sus llamadas. / Désactivez une app pour ne plus recevoir de demande concernant ses appels. |
| Description source | catalog key `Turn off an app to never be asked about its calls.` |
| Destination | `meetings` › `callApps` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingCallApps`](#node-meetingCallApps) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: call apps<br>phrases: choose which apps to detect calls in; stop asking about calls in this app |
| Search (de) | words: Anruferkennung<br>phrases: wähle aus, in welchen Apps Anrufe erkannt werden; frag mich bei Anrufen in dieser App nicht mehr nach einer Aufnahme; schalte die Anruferkennung für einzelne Apps aus |
| Search (es) | words: detectar llamadas en aplicaciones<br>phrases: elegir en qué apps detectar llamadas; dejar de preguntar por las llamadas de esta app |
| Search (fr) | phrases: choisir les applis où détecter les appels; ne plus me proposer d’enregistrer les appels de cette appli |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-enableAIPolish"></a>

### Enable AI Polish / KI-Nachbearbeitung aktivieren / Activar Pulido con IA / Activer la retouche IA (`enableAIPolish`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.aiPolish`](#node-page-aiPolish) |
| Title source | catalog key `settings.aiPolish.enable.title` |
| Description | Fixes grammar, punctuation and formatting / Korrigiert Grammatik, Zeichensetzung und Formatierung / Corrige la gramática, la puntuación y el formato / Corrige la grammaire, la ponctuation et la mise en forme |
| Description source | catalog key `Fixes grammar, punctuation and formatting` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`enableAIPolish`](#node-enableAIPolish) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: grammar, punctuation, formatting, proofread<br>phrases: turn on automatic grammar correction for dictation; fix punctuation and formatting after I dictate |
| Search (de) | words: Grammatik, Satzzeichen, Zeichensetzung, Formatierung<br>phrases: verbessere nach dem Diktieren automatisch die Grammatik; korrigiere Satzzeichen und Formatierung meiner Diktate |
| Search (es) | words: gramática, formato, corrección automática, AI Polish<br>phrases: activar la corrección de gramática, puntuación y formato después de dictar |
| Search (fr) | words: grammaire, correction automatique, mise en forme, relecture<br>phrases: activer la correction automatique de la grammaire et de la ponctuation après ma dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: proveedor de corrección, elegir proveedor de IA, Proveedor de AI Polish<br>phrases: elegir el proveedor que mejora el texto que dicto |
| Search (fr) | words: fournisseur IA, correcteur de dictée<br>phrases: choisir le fournisseur qui corrige mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictationOutputLanguage"></a>

### Dictation output language / Ausgabesprache für Diktate / Idioma de salida del dictado / Langue du texte dicté (`dictationOutputLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.aiPolish`](#node-page-aiPolish) |
| Title source | catalog key `Dictation output language` |
| Description | composed at display time from live state (not exported) |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictationOutputLanguage`](#node-dictationOutputLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: target language, final text language<br>phrases: change the language of my dictated text; get my dictation in another language |
| Search (de) | words: Zielsprache<br>phrases: Ausgabesprache für Diktate; Diktate in die gewählte Zielsprache übersetzen |
| Search (es) | words: idioma de salida, lengua de destino<br>phrases: cambiar el idioma del texto después de dictar; quiero que el dictado salga en otro idioma |
| Search (fr) | words: langue de sortie, langue cible<br>phrases: changer la langue du texte après la dictée; je veux le texte de ma dictée dans une autre langue |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: ajustes del corrector de dictado, opciones exclusivas del proveedor, Ajustes exclusivos de este modelo<br>phrases: ver los ajustes que solo se aplican al modelo que corrige mi dictado |
| Search (fr) | words: réglages du fournisseur, options AI Polish<br>phrases: voir les réglages propres au modèle choisi pour corriger mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-egOne"></a>

### Why use EG-1 / Warum EG-1 verwenden? / Por qué usar EG-1 / Pourquoi utiliser EG-1 (`aiPolish.whyUse.egOne`)

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
| Search (es) | words: tiempo de EG-1, alternativas a EG-1<br>phrases: cuánto tarda EG-1 en corregir el texto; cuándo conviene elegir otro modelo en lugar de EG-1 |
| Search (fr) | words: durée EG-1, alternatives EG-1<br>phrases: combien de temps prend la correction avec EG-1; quand choisir un autre modèle qu’EG-1 |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-s1Mini"></a>

### Why use S1-mini / Warum S1-mini verwenden? / Por qué usar S1-mini / Pourquoi utiliser S1-mini (`aiPolish.whyUse.s1Mini`)

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
| Search (es) | words: idiomas de S1-mini, ventajas de S1-mini<br>phrases: sirve S1-mini para mi idioma; cuándo conviene usar S1-mini |
| Search (fr) | words: langues S1-mini, conseils S1-mini<br>phrases: est-ce que S1-mini convient à ma langue |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-appleIntelligence"></a>

### Why use Apple Intelligence / Warum Apple Intelligence verwenden? / Por qué usar Apple Intelligence / Pourquoi utiliser Apple Intelligence (`aiPolish.whyUse.appleIntelligence`)

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
| Search (es) | words: ventajas de Apple Intelligence, Apple Intelligence no disponible<br>phrases: por qué no está disponible Apple Intelligence; cuándo conviene usar Apple Intelligence para corregir texto |
| Search (fr) | words: conseils Apple Intelligence, aide Apple Intelligence<br>phrases: quand choisir Apple Intelligence pour corriger mes dictées; pourquoi Apple Intelligence peut être indisponible |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-ollama"></a>

### Why use Ollama / Warum Ollama verwenden? / Por qué usar Ollama / Pourquoi utiliser Ollama (`aiPolish.whyUse.ollama`)

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
| Search (es) | words: recomendaciones Ollama, modelo Ollama ausente<br>phrases: qué modelo de Ollama conviene para corregir texto; por qué no aparece mi modelo de Ollama |
| Search (fr) | words: conseils Ollama, modèle Ollama absent<br>phrases: quel modèle Ollama est adapté à la correction; pourquoi mon modèle Ollama n’apparaît pas |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-openAI"></a>

### Why use OpenAI / Warum OpenAI verwenden? / Por qué usar OpenAI / Pourquoi utiliser OpenAI (`aiPolish.whyUse.openAI`)

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
| Search (es) | words: recomendaciones OpenAI, modelos OpenAI ausentes<br>phrases: qué modelo de OpenAI conviene para corregir dictados; por qué faltan algunos modelos de OpenAI |
| Search (fr) | words: conseils OpenAI, modèles OpenAI absents<br>phrases: quel modèle OpenAI est adapté à la correction de dictée; pourquoi certains modèles OpenAI n’apparaissent pas |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-gemini"></a>

### Why use Gemini / Warum Gemini verwenden? / Por qué usar Gemini / Pourquoi utiliser Gemini (`aiPolish.whyUse.gemini`)

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
| Search (es) | words: recomendaciones Gemini, modelos Gemini bloqueados<br>phrases: qué modelo de Gemini conviene para corregir texto; por qué están bloqueados algunos modelos de Gemini |
| Search (fr) | words: conseils Gemini, modèles Gemini verrouillés<br>phrases: quel modèle Gemini est adapté à la correction; pourquoi certains modèles Gemini sont verrouillés |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-whyUse-claude"></a>

### Why use Claude / Warum Claude verwenden? / Por qué usar Claude / Pourquoi utiliser Claude (`aiPolish.whyUse.claude`)

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
| Search (es) | words: recomendaciones Claude, modelos Claude ausentes, acceso API Claude<br>phrases: qué modelo de Claude conviene y por qué faltan algunos; qué acceso a la API necesito para usar Claude |
| Search (fr) | words: conseils Claude, modèles Claude absents, accès API Claude<br>phrases: quel modèle Claude est adapté à la correction; pourquoi certains modèles Claude manquent et quel accès API faut-il |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-aboutAppleIntelligence"></a>

### About Apple Intelligence / Über Apple Intelligence / Más información sobre Apple Intelligence / À propos d’Apple Intelligence (`aiPolish.link.aboutAppleIntelligence`)

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
| Search (es) | words: web Apple Intelligence, Acerca de Apple Intelligence<br>phrases: abrir la página de información de Apple Intelligence |
| Search (fr) | words: page Apple Intelligence<br>phrases: ouvrir la page d’information sur Apple Intelligence |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-ollamaLibrary"></a>

### Ollama model library / Ollama-Modellbibliothek / Biblioteca de modelos de Ollama / Bibliothèque de modèles Ollama (`aiPolish.link.ollamaLibrary`)

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
| Search (es) | words: biblioteca Ollama, web de modelos Ollama<br>phrases: abrir la web de la biblioteca de modelos de Ollama |
| Search (fr) | words: catalogue web Ollama<br>phrases: ouvrir le site de la bibliothèque de modèles Ollama |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-openAIRateLimits"></a>

### OpenAI rate limits by tier / OpenAI-Ratenlimits nach Stufe / Límites de uso de OpenAI por nivel / Limites de débit d’OpenAI par niveau (`aiPolish.link.openAIRateLimits`)

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
| Search (es) | words: límites OpenAI, cuota OpenAI, rate limits OpenAI<br>phrases: ver los límites de solicitudes de OpenAI para mi nivel de uso |
| Search (fr) | words: quotas OpenAI, limites OpenAI<br>phrases: ouvrir les limites de requêtes OpenAI pour mon niveau d’utilisation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-geminiRateLimits"></a>

### Gemini API rate limits by tier / Ratenlimits der Gemini-API nach Nutzungsstufe / Límites de la API de Gemini por nivel / Limites de débit de l’API Gemini par niveau (`aiPolish.link.geminiRateLimits`)

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
| Search (es) | words: límites Gemini, cuota Gemini, rate limits Gemini<br>phrases: ver los límites de solicitudes de Gemini para mi nivel de uso |
| Search (fr) | words: quotas Gemini, limites Gemini<br>phrases: ouvrir les limites de requêtes Gemini pour mon niveau d’utilisation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolish-link-claudeRateLimits"></a>

### Claude API rate limits / Claude-API-Ratenlimits / Límites de uso de la API de Claude / Limites de débit de l’API Claude (`aiPolish.link.claudeRateLimits`)

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
| Search (es) | words: límites Claude, cuota Claude, rate limits Claude<br>phrases: ver los límites de solicitudes de la API de Claude |
| Search (fr) | words: quotas Claude, limites Claude<br>phrases: ouvrir les limites de requêtes de l’API Claude |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-download"></a>

### Download / Laden / Descargar / Télécharger (`localModel.download`)

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
| Search (es) | words: descargar EG-1, descargar S1-mini<br>phrases: descargar EG-1 o S1-mini en mi Mac |
| Search (fr) | words: télécharger EG-1, télécharger S1-mini<br>phrases: télécharger EG-1 ou S1-mini sur mon Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-cancel"></a>

### Cancel / Abbrechen / Cancelar / Annuler (`localModel.cancel`)

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
| Search (es) | words: cancelar descarga EG-1, cancelar descarga S1-mini<br>phrases: cancelar la descarga de EG-1 o S1-mini |
| Search (fr) | words: annuler EG-1, annuler S1-mini<br>phrases: annuler le téléchargement d’EG-1 ou de S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-resume"></a>

### Resume / Fortsetzen / Reanudar / Reprendre (`localModel.resume`)

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
| Search (es) | words: reanudar descarga EG-1, reanudar descarga S1-mini<br>phrases: continuar la descarga pausada de EG-1 o S1-mini |
| Search (fr) | words: reprendre EG-1, reprendre S1-mini<br>phrases: reprendre le téléchargement mis en pause d’EG-1 ou de S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-resumeUpgrade"></a>

### Resume upgrade / Upgrade fortsetzen / Reanudar la actualización / Reprendre la mise à niveau (`localModel.resumeUpgrade`)

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
| Search (es) | words: reanudar actualización EG-1, reanudar actualización S1-mini, Reanudar actualización del modelo<br>phrases: continuar la actualización de EG-1 o S1-mini que quedó a medias |
| Search (fr) | phrases: reprendre la mise à niveau interrompue d’EG-1 ou de S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-finishUpgrade"></a>

### Finish upgrade / Upgrade abschließen / Terminar la actualización / Terminer la mise à niveau (`localModel.finishUpgrade`)

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
| Search (es) | words: terminar actualización EG-1, terminar actualización S1-mini, Terminar actualización del modelo<br>phrases: terminar de instalar la nueva versión de EG-1 o S1-mini para que vuelva a funcionar la corrección |
| Search (fr) | words: finir la mise à niveau<br>phrases: terminer l’installation de la nouvelle version d’EG-1 ou de S1-mini pour réactiver la correction |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-localModel-tryAgain"></a>

### Try Again / Erneut versuchen / Intentar de nuevo / Réessayer (`localModel.tryAgain`)

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
| Search (es) | words: reintentar EG-1, reintentar S1-mini<br>phrases: volver a intentarlo tras el error de EG-1 o S1-mini |
| Search (fr) | words: réessayer EG-1, réessayer S1-mini<br>phrases: réessayer après l’erreur d’EG-1 ou de S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: probar corrector local, comprobar modelo descargado<br>phrases: probar si funciona el modelo de corrección descargado |
| Search (fr) | words: tester EG-1, tester S1-mini, tester le modèle, vérifier que le modèle est actif<br>phrases: tester si le modèle de correction téléchargé fonctionne |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone"></a>

### Tone / Ton / Tono / Ton (`s1Tone`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Tone` |
| Description | Choose how formal your text sounds. / Wähle, wie förmlich dein Text klingt. / Elige el nivel de formalidad de tu texto. / Choisissez le niveau de formalité de votre texte. |
| Description source | catalog key `Choose how formal your text sounds.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Tone`](#node-s1Tone) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: formality, style, register<br>phrases: choose how formal S1-mini makes my text; adjust the writing style in S1-mini |
| Search (de) | words: Formalität, Sprachstil, Schreibstil<br>phrases: stell ein, wie förmlich S1-mini meinen Text schreibt; pass den Schreibstil von S1-mini an |
| Search (es) | words: formalidad, registro, tono S1-mini<br>phrases: elegir lo formal que suena mi texto con S1-mini |
| Search (fr) | words: ton S1-mini, registre, formalité<br>phrases: régler le degré de formalité du texte avec S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure"></a>

### Structure / Struktur / Estructura / Structure (`s1Structure`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Structure` |
| Description | Keep sentences or turn spoken items into lists. / Sätze behalten oder gesprochene Punkte in Listen umwandeln. / Conservar las frases o convertir los elementos dictados en listas. / Conserver les phrases ou transformer les éléments dictés en listes. |
| Description source | catalog key `Keep sentences or turn spoken items into lists.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Structure`](#node-s1Structure) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: organization, arrangement<br>phrases: choose whether S1-mini keeps sentences or makes lists; change how S1-mini organizes my dictated text |
| Search (de) | words: Textaufbau, Anordnung<br>phrases: stell ein, ob S1-mini Sätze beibehält oder Listen erstellt; ändere, wie S1-mini meinen diktierten Text aufbaut |
| Search (es) | words: organización del texto<br>phrases: elegir cómo organiza S1-mini el texto que dicto |
| Search (fr) | words: organisation S1-mini, structure du texte<br>phrases: choisir si S1-mini garde les phrases ou fait des listes |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context"></a>

### Context / Kontext / Contexto / Contexte (`s1Context`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Context` |
| Description | Format dictated greetings and sign-offs as email. / Diktierte Anreden und Grußformeln als E-Mail formatieren. / Da formato de correo electrónico a los saludos y las despedidas dictados. / Mettre en forme les salutations et formules de politesse dictées comme un e-mail. |
| Description source | catalog key `Format dictated greetings and sign-offs as email.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`s1Context`](#node-s1Context) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose whether S1-mini uses general or email formatting; change the context used to format my S1-mini dictation |
| Search (de) | phrases: stell ein, ob S1-mini normalen Text oder eine E-Mail formatiert; wähle den Kontext für die Formatierung meiner S1-mini-Diktate |
| Search (es) | words: contexto S1-mini, tipo de texto<br>phrases: elegir el contexto que usa S1-mini para dar formato al dictado |
| Search (fr) | words: contexte S1-mini, format S1-mini<br>phrases: choisir entre une mise en forme générale et une mise en forme de mail avec S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel"></a>

### Unload polish model after / Polish-Modell entladen nach / Quitar modelo de Pulido de la RAM tras / Décharger le modèle de retouche après (`unloadPolishModel`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Unload polish model after` |
| Description | Frees the polish model's memory when you are not dictating. / Gibt den Speicher des Polish-Modells frei, wenn du nicht diktierst. / Libera la memoria del modelo de Pulido cuando no estás dictando. / Libère la mémoire du modèle de retouche quand vous ne dictez pas. |
| Description source | catalog key `Frees the polish model's memory when you are not dictating.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: polish model timeout, unload polish model<br>phrases: free up ram used by ai polish when i stop dictating; how long does the local polish model stay in memory |
| Search (de) | words: Nachbearbeitungsmodell entladen, Leerlaufzeit für das Nachbearbeitungsmodell<br>phrases: wie lange bleibt das Modell für die KI-Nachbearbeitung nach dem Diktieren im Arbeitsspeicher; stell ein, wann EG-1 oder S1-mini bei Nichtbenutzung den Arbeitsspeicher freigibt |
| Search (es) | words: memoria del modelo de corrección, inactividad del modelo de corrección<br>phrases: cuándo se libera la memoria del modelo que corrige el texto si no dicto; cuánto tiempo sigue cargado el modelo de corrección después de dejar de dictar |
| Search (fr) | words: mémoire du modèle de correction, inactivité du modèle de correction<br>phrases: combien de temps le modèle de correction reste en mémoire quand je ne dicte plus; libérer la mémoire utilisée par la correction de texte sur mon Mac quand je ne dicte pas |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: estado Apple Intelligence, disponibilidad Apple Intelligence<br>phrases: ver si Apple Intelligence está listo en este Mac |
| Search (fr) | words: état Apple Intelligence, disponibilité Apple Intelligence<br>phrases: voir l’état actuel d’Apple Intelligence sur ce Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appleIntelligence-recheck"></a>

### Check Apple Intelligence availability / Verfügbarkeit von Apple Intelligence prüfen / Comprobar la disponibilidad de Apple Intelligence / Vérifier la disponibilité d’Apple Intelligence (`appleIntelligence.recheck`)

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
| Search (es) | words: recomprobar Apple Intelligence<br>phrases: volver a comprobar si está disponible Apple Intelligence |
| Search (fr) | words: revérifier Apple Intelligence<br>phrases: vérifier à nouveau la disponibilité d’Apple Intelligence |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-downloadOllama"></a>

### Download Ollama / Ollama herunterladen / Descargar Ollama / Télécharger Ollama (`ollama.downloadOllama`)

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
| Search (es) | words: instalar Ollama, descargar programa Ollama<br>phrases: instalar el programa Ollama en mi Mac |
| Search (fr) | words: installer Ollama<br>phrases: installer Ollama lui-même sur mon Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-start"></a>

### Start Ollama / Ollama starten / Iniciar Ollama / Démarrer Ollama (`ollama.start`)

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
| Search (es) | words: arrancar Ollama, ollama serve<br>phrases: poner Ollama en marcha después de instalarlo |
| Search (fr) | words: lancer Ollama, ollama serve<br>phrases: démarrer Ollama après son installation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: primer modelo Ollama, descargar modelo inicial Ollama<br>phrases: descargar un modelo para que Ollama pueda corregir texto |
| Search (fr) | words: premier modèle Ollama<br>phrases: télécharger le modèle nécessaire pour qu’Ollama puisse corriger le texte |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-cancelPull"></a>

### Cancel / Abbrechen / Cancelar / Annuler (`ollama.cancelPull`)

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
| Search (es) | words: cancelar descarga Ollama, detener descarga Ollama<br>phrases: cancelar la descarga del modelo en Ollama |
| Search (fr) | words: annuler le téléchargement Ollama<br>phrases: arrêter le téléchargement du modèle dans Ollama |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-server"></a>

### Server / Server / Servidor / Serveur (`ollama.server`)

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
| Search (es) | words: servidor Ollama, dirección Ollama, endpoint Ollama<br>phrases: ver la dirección del servidor de Ollama que está funcionando |
| Search (fr) | words: adresse Ollama, endpoint Ollama<br>phrases: voir l’adresse de mon serveur Ollama en cours d’exécution |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-recheck"></a>

### Re-check Ollama status / Ollama-Status erneut prüfen / Comprobar de nuevo el estado de Ollama / Vérifier à nouveau l’état d’Ollama (`ollama.recheck`)

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
| Search (es) | words: recomprobar Ollama, Volver a comprobar Ollama<br>phrases: comprobar otra vez si Ollama está en marcha |
| Search (fr) | words: revérifier Ollama<br>phrases: vérifier à nouveau si Ollama est en cours d’exécution |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-tryAgain"></a>

### Try Again / Erneut versuchen / Intentar de nuevo / Réessayer (`ollama.tryAgain`)

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
| Search (es) | words: Reintentar Ollama<br>phrases: volver a intentarlo después del error de Ollama |
| Search (fr) | words: réessayer Ollama<br>phrases: réessayer après l’erreur Ollama |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-browseModels"></a>

### Download more models / Weitere Modelle laden / Descargar más modelos / Télécharger d’autres modèles (`ollama.browseModels`)

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
| Search (es) | words: más modelos Ollama, explorar descargas Ollama<br>phrases: ver más modelos para descargar desde Ollama |
| Search (fr) | words: autres modèles Ollama<br>phrases: parcourir d’autres modèles à télécharger avec Ollama |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-ollama-prepareModel"></a>

### Prepare model / Modell vorbereiten / Preparar modelo / Préparer le modèle (`ollama.prepareModel`)

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
| Search (es) | words: preparar modelo Ollama, inicializar modelo Ollama<br>phrases: preparar el modelo elegido de Ollama para corregir texto |
| Search (fr) | words: initialiser le modèle Ollama<br>phrases: préparer le modèle Ollama sélectionné pour la correction |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-openAI"></a>

### OpenAI API Key / OpenAI-API-Schlüssel / Clave de API de OpenAI / Clé d’API OpenAI (`apiKey.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `OpenAI API Key` |
| Description | Sends text and dictation context to OpenAI. / Sendet Text und Diktatkontext an OpenAI. / Envía texto y contexto del dictado a OpenAI. / Envoie le texte et le contexte de dictée à OpenAI. |
| Description source | catalog key `Sends text and dictation context to OpenAI.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.openAI`](#node-apiKey-openAI) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enter my OpenAI API key for dictation cleanup; change the OpenAI API key used to send dictation text and context |
| Search (de) | phrases: trag meinen OpenAI-API-Schlüssel für die Diktatkorrektur ein; ändere den OpenAI-API-Schlüssel zum Senden von Diktattext und Kontext |
| Search (es) | words: clave OpenAI, API key OpenAI<br>phrases: introducir mi clave de OpenAI para corregir el dictado |
| Search (fr) | words: clé OpenAI, API key OpenAI<br>phrases: saisir ma clé API OpenAI pour corriger mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-gemini"></a>

### Google Gemini API Key / Google Gemini-API-Schlüssel / Clave de API de Google Gemini / Clé API Google Gemini (`apiKey.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Google Gemini API Key` |
| Description | Sends text and dictation context to Google. / Sendet Text und Diktatkontext an Google. / Envía texto y contexto del dictado a Google. / Envoie le texte et le contexte de dictée à Google. |
| Description source | catalog key `Sends text and dictation context to Google.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.gemini`](#node-apiKey-gemini) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enter my Google API key for Gemini dictation cleanup; change the Gemini API key used to send dictation text and context |
| Search (de) | phrases: trag meinen Google-API-Schlüssel für die Diktatkorrektur mit Gemini ein; ändere den Gemini-API-Schlüssel zum Senden von Diktattext und Kontext |
| Search (es) | words: clave Gemini, API key Google<br>phrases: introducir mi clave de Google para corregir el dictado con Gemini |
| Search (fr) | words: clé Gemini, clé Google, API key Gemini<br>phrases: saisir ma clé API Google pour la correction avec Gemini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-claude"></a>

### Claude API Key / Claude-API-Schlüssel / Clave de API de Claude / Clé API Claude (`apiKey.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`aiPolish.providerSection`](#node-aiPolish-providerSection) |
| Title source | catalog key `Claude API Key` |
| Description | Sends text and dictation context to Anthropic. / Sendet Text und Diktatkontext an Anthropic. / Envía texto y contexto del dictado a Anthropic. / Envoie le texte et le contexte de dictée à Anthropic. |
| Description source | catalog key `Sends text and dictation context to Anthropic.` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `apiKeyProvider` |
| Arrival target | [`apiKey.claude`](#node-apiKey-claude) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Anthropic, credential, token<br>phrases: enter my Anthropic API key; use my Anthropic key for AI Polish |
| Search (de) | words: Anthropic, Zugangsdaten, Token<br>phrases: meinen API-Schlüssel von Anthropic eintragen; Claude mit meinem Anthropic-Schlüssel nutzen |
| Search (es) | words: clave Anthropic, clave Claude, API key Claude<br>phrases: introducir mi clave de Anthropic para AI Polish |
| Search (fr) | words: clé Claude, clé Anthropic, API key Anthropic<br>phrases: saisir ma clé API Anthropic pour AI Polish |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-save"></a>

### Save / Sichern / Guardar / Enregistrer (`apiKey.save`)

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
| Search (es) | words: guardar clave API<br>phrases: guardar la clave de API que he introducido |
| Search (fr) | words: enregistrer la clé<br>phrases: enregistrer la clé API que je viens de saisir |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-apiKey-clear"></a>

### Clear / Löschen / Borrar / Effacer (`apiKey.clear`)

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
| Search (es) | words: borrar clave API, eliminar clave guardada<br>phrases: quitar mi clave de API guardada |
| Search (fr) | words: supprimer la clé<br>phrases: effacer ma clé API enregistrée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: mostrar clave API, ocultar clave API<br>phrases: mostrar u ocultar mi clave de API |
| Search (fr) | words: afficher la clé, masquer la clé<br>phrases: afficher ou masquer ma clé API |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (es) | words: conseguir API key, obtener clave API<br>phrases: abrir la web del proveedor para conseguir una clave de API |
| Search (fr) | words: obtenir une clé<br>phrases: ouvrir le site du fournisseur pour obtenir une clé API |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-polishModel"></a>

### Model / Modell / Modelo / Modèle (`polishModel`)

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
| Search (es) | words: LLM, modelo del proveedor, Modelo de corrección<br>phrases: elegir qué modelo usa el proveedor seleccionado para corregir mi texto |
| Search (fr) | words: LLM, modèle du fournisseur<br>phrases: choisir le modèle utilisé au sein de mon fournisseur AI Polish ou d’Ollama |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-polishModel-refresh"></a>

### Refresh available models / Verfügbare Modelle aktualisieren / Actualizar modelos disponibles / Actualiser les modèles disponibles (`polishModel.refresh`)

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
| Search (es) | words: recargar lista de modelos, actualizar modelos disponibles<br>phrases: volver a cargar la lista de modelos de corrección disponibles |
| Search (fr) | words: actualiser les modèles<br>phrases: recharger la liste des modèles disponibles pour AI Polish |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-enableDictionary"></a>

### Enable Dictionary / Wörterbuch aktivieren / Activar el Diccionario / Activer le Dictionnaire (`enableDictionary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Enable Dictionary` |
| Description | Use your words and vocabulary to improve recognition. / Nutze deine Wörter und dein Vokabular für eine bessere Erkennung. / Usa tus palabras y vocabulario para mejorar el reconocimiento. / Utilisez vos mots et votre vocabulaire pour améliorer la reconnaissance. |
| Description source | catalog key `Use your words and vocabulary to improve recognition.` |
| Destination | `dictionary` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`enableDictionary`](#node-enableDictionary) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recognition<br>phrases: use my dictionary to improve dictation recognition; stop using my dictionary when I dictate |
| Search (de) | words: Worterkennung, Erkennung<br>phrases: mein Wörterbuch beim Diktieren berücksichtigen; die Wörterbuchhilfe für die Erkennung ausschalten |
| Search (es) | words: desactivar diccionario<br>phrases: usar mi diccionario para reconocer mejor lo que dicto |
| Search (fr) | words: dictionnaire activé, reconnaissance personnalisée<br>phrases: activer ou désactiver l’utilisation de mon dictionnaire pour reconnaître mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-yourWords"></a>

### Your Words / Deine Wörter / Tus palabras / Vos mots (`dictionary.tab.yourWords`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Your Words` |
| Description | Words you added / Eigene Wörter / Palabras añadidas / Mots ajoutés |
| Description source | catalog key `Words you added` |
| Destination | `dictionary` |
| Dictionary tab | `yourWords` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.yourWords`](#node-dictionary-tab-yourWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: entries, spellings, lexicon<br>phrases: show the words I added myself; where is my personal word list |
| Search (de) | words: Wörterbucheinträge, Schreibweisen<br>phrases: wo sind meine selbst hinzugefügten Wörter; meine persönliche Wortliste ansehen |
| Search (es) | words: mis palabras, diccionario personal, entradas propias<br>phrases: ver las palabras que he añadido al diccionario |
| Search (fr) | words: mots personnels, lexique personnel, orthographes enregistrées<br>phrases: voir les mots que j’ai ajoutés moi-même |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-vocabularyPacks"></a>

### Vocabulary Packs / Wortschatzpakete / Vocabularios / Lexiques (`dictionary.tab.vocabularyPacks`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Vocabulary Packs` |
| Description | Ready-made lists / Fertige Listen / Listas prehechas / Listes types |
| Description source | catalog key `Ready-made lists` |
| Destination | `dictionary` |
| Dictionary tab | `vocabularyPacks` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.vocabularyPacks`](#node-dictionary-tab-vocabularyPacks) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: enable lists of specialist terms; recognise medical terms; enable lists of brand names |
| Search (de) | phrases: Listen mit Fachbegriffen einschalten; medizinische Begriffe erkennen; Listen mit Markennamen einschalten |
| Search (es) | words: pestaña Vocabulary Packs, pestaña de paquetes<br>phrases: abrir la pestaña de paquetes de vocabulario |
| Search (fr) | words: onglet packs, onglet vocabulaire<br>phrases: ouvrir l’onglet des packs de vocabulaire |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-learnFrom"></a>

### Learn from... / Lernen aus... / Aprender de… / Apprendre de… (`dictionary.tab.learnFrom`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Learn from...` |
| Description | Learn as you go / Nebenbei lernen / Aprende con el uso / Au fil de l’usage |
| Description source | catalog key `Learn as you go` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: learn new words from my corrections; learn words I correct after dictating; learn names from my contacts |
| Search (de) | phrases: lerne neue Wörter aus meinen Korrekturen; merk dir Wörter, die ich nach dem Diktieren korrigiere; lerne Namen aus meinen Kontakten |
| Search (es) | words: pestaña Learn from, pestaña de aprendizaje<br>phrases: abrir la pestaña Aprender de del diccionario |
| Search (fr) | words: onglet apprentissage, onglet sources<br>phrases: ouvrir l’onglet Apprendre à partir de |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictionary-tab-quickAdd"></a>

### Quick Add / Schnell hinzufügen / Añadir rápidamente / Ajout rapide (`dictionary.tab.quickAdd`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.dictionary`](#node-page-dictionary) |
| Title source | catalog key `Quick Add` |
| Description | Add from any app / Aus jeder App / Desde cualquier app / Depuis toute app |
| Description source | catalog key `Add from any app` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: guide, instructions<br>phrases: how do I add words from another app; show me how Quick Add works |
| Search (de) | words: Anleitung<br>phrases: wie füge ich Wörter aus anderen Apps hinzu; wie funktioniert Schnell hinzufügen |
| Search (es) | words: guía Quick Add, instrucciones Quick Add<br>phrases: cómo añadir palabras al diccionario desde otra app |
| Search (fr) | words: guide Quick Add, aide ajout rapide<br>phrases: ouvrir le guide de l’ajout de mots depuis une autre application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-add"></a>

### Add word / Wort hinzufügen / Añadir palabra / Ajouter un mot (`yourWords.add`)

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
| Search (es) | words: añadir palabra manualmente, nueva entrada<br>phrases: añadir una palabra directamente a mi diccionario personal |
| Search (fr) | phrases: ajouter directement un mot à mon dictionnaire personnel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-import"></a>

### Import / Importieren / Importar / Importer (`yourWords.import`)

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
| Search (es) | words: importar diccionario, cargar lista de palabras<br>phrases: importar una lista de palabras a mi diccionario |
| Search (fr) | phrases: importer une liste de mots dans mon dictionnaire |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-export"></a>

### Export your words / Deine Wörter exportieren / Exportar tus palabras / Exporter vos mots (`yourWords.export`)

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
| Search (es) | words: exportar diccionario, exportar palabras<br>phrases: exportar las palabras de mi diccionario personal |
| Search (fr) | words: exporter des mots<br>phrases: exporter les mots de mon dictionnaire personnel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-search"></a>

### Search by word, mishearing, or category / Nach Wort, Fehlerkennung oder Kategorie suchen / Buscar por palabra, error de reconocimiento o categoría / Rechercher par mot, erreur de reconnaissance ou catégorie (`yourWords.search`)

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
| Search (es) | words: buscar mis palabras, buscador del diccionario<br>phrases: buscar una entrada de mi diccionario por palabra, error de reconocimiento o categoría |
| Search (fr) | words: recherche dictionnaire, recherche mots personnels<br>phrases: chercher dans mes mots personnels par mot, erreur de reconnaissance ou catégorie |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-clearSearch"></a>

### Clear search / Suche löschen / Borrar búsqueda / Effacer la recherche (`yourWords.clearSearch`)

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
| Search (es) | words: limpiar búsqueda del diccionario<br>phrases: borrar la búsqueda de mi lista de palabras |
| Search (fr) | words: vider la recherche dictionnaire<br>phrases: vider le champ de recherche de ma liste de mots personnels |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-categoryFilter"></a>

### All categories / Alle Kategorien / Todas las categorías / Toutes les catégories (`yourWords.categoryFilter`)

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
| Search (es) | words: categorías, filtro de palabras, grupos de palabras<br>phrases: filtrar mis palabras por categoría |
| Search (fr) | words: filtre dictionnaire, catégories de mots<br>phrases: filtrer mes mots personnels par catégorie |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-massEdit"></a>

### Mass edit / Mehrere auswählen / Editar en lote / Modification groupée (`yourWords.massEdit`)

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
| Search (es) | words: selección múltiple, edición en bloque<br>phrases: seleccionar varias entradas del diccionario a la vez |
| Search (fr) | words: sélection multiple, sélection en lot<br>phrases: sélectionner plusieurs entrées du dictionnaire à la fois |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-learnFrom"></a>

### Learn from... / Lernen aus... / Aprender de… / Apprendre de… (`learnFrom`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Learn from...` |
| Description | Let EnviousWispr pick up new words on its own, from things you already have. / Lass EnviousWispr neue Wörter aus deinen vorhandenen Inhalten selbst lernen. / Deja que EnviousWispr detecte por sí solo palabras nuevas a partir de lo que ya tienes. / Laissez EnviousWispr apprendre de lui-même de nouveaux mots à partir de ce que vous avez déjà. |
| Description source | catalog key `Let EnviousWispr pick up new words on its own, from things you already have.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`learnFrom`](#node-learnFrom) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: sources, discovery<br>phrases: find ways for the app to learn new words; let the app pick up vocabulary from things I already have |
| Search (de) | words: Lernquellen, Wortquellen<br>phrases: welche Quellen kann die App zum Wörterlernen nutzen; neue Wörter aus vorhandenen Quellen übernehmen lassen |
| Search (es) | words: fuentes de vocabulario, descubrir palabras<br>phrases: ver de dónde puede aprender palabras nuevas la app |
| Search (fr) | words: sources de vocabulaire, découverte de mots<br>phrases: voir les façons d’apprendre de nouveaux mots à partir de ce que j’ai déjà |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-selfLearningDictionary"></a>

### Learn new words / Neue Wörter lernen / Aprender palabras nuevas / Apprendre de nouveaux mots (`selfLearningDictionary`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Learn new words` |
| Description | Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words. / Erkennt automatisch, wenn du ein Diktat korrigierst, und fügt das korrigierte Wort deinem Wörterbuch hinzu. Du kannst das über die Mitteilung rückgängig machen oder das Wort später unter „Deine Wörter“ entfernen. / Detecta automáticamente cuándo corriges un dictado y añade la palabra corregida a tu Diccionario. Puedes deshacer esa incorporación desde la notificación o eliminar la palabra más tarde en Tus palabras. / Détecte automatiquement les corrections apportées à une dictée et ajoute le mot corrigé à votre dictionnaire. Annulez cette action depuis la notification ou supprimez le mot plus tard dans Vos mots. |
| Description source | catalog key `Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: selflearning<br>phrases: learn new words from edits I make after dictating; stop learning from my dictation corrections |
| Search (de) | words: selbstlernend<br>phrases: Wörter lernen, wenn ich mein Diktat korrigiere; nicht mehr aus meinen Diktatkorrekturen lernen |
| Search (es) | words: aprender de mis correcciones<br>phrases: añadir automáticamente al diccionario las palabras que corrijo después de dictar |
| Search (fr) | words: apprentissage de nouveaux mots<br>phrases: ajouter automatiquement au dictionnaire les mots que je corrige à la main après une dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-fixLearnedWords"></a>

### Fix words it learned / Gelernte Korrekturen anwenden / Corregir palabras aprendidas / Corriger les mots appris (`fixLearnedWords`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Fix words it learned` |
| Description | Use learned words in new recordings and imports. Turn this off to keep using words you added yourself without applying learned corrections. / Wende gelernte Korrekturen bei neuen Aufnahmen und Importen an. Wenn du diese Option ausschaltest, werden selbst hinzugefügte Wörter weiterhin berücksichtigt, solange das Wörterbuch aktiviert ist. / Usa las palabras aprendidas en las grabaciones e importaciones nuevas. Desactiva esta opción para seguir usando las palabras que añadiste sin aplicar las correcciones aprendidas. / Utilisez les mots appris dans les nouveaux enregistrements et les importations. Désactivez cette option pour continuer à utiliser les mots que vous avez ajoutés vous-même sans appliquer les corrections apprises. |
| Description source | catalog key `Use learned words in new recordings and imports. Turn this off to keep using words you added yourself without applying learned corrections.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`fixLearnedWords`](#node-fixLearnedWords) |
| Fallbacks, in order | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: learned corrections<br>phrases: use my past corrections in new recordings; apply learned corrections to imported audio; stop applying learned corrections |
| Search (de) | phrases: gelernte Korrekturen bei neuen Aufnahmen und Importen anwenden; nur noch selbst hinzugefügte Wörter für Korrekturen nutzen |
| Search (es) | phrases: usar mis correcciones anteriores en nuevas grabaciones y archivos importados; dejar de aplicar las correcciones aprendidas y seguir usando las palabras que añadí a mano |
| Search (fr) | words: réutiliser les corrections<br>phrases: appliquer les corrections apprises aux prochains enregistrements et aux fichiers importés; désactiver les corrections apprises tout en continuant à utiliser les mots ajoutés à la main |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-selfLearningDictionary-learnMore"></a>

### Learn more / Mehr erfahren / Más información / En savoir plus (`selfLearningDictionary.learnMore`)

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
| Search (es) | words: guía de autoaprendizaje, ayuda de autoaprendizaje<br>phrases: leer cómo aprende el diccionario de mis correcciones |
| Search (fr) | words: aide apprentissage dictionnaire<br>phrases: ouvrir l’explication de l’apprentissage à partir de mes corrections de dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-selfLearningDictionary-forgetMemory"></a>

### Forget learning memory / Lerngedächtnis löschen / Borrar la memoria de aprendizaje / Oublier la mémoire d’apprentissage (`selfLearningDictionary.forgetMemory`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Title source | catalog key `Forget learning memory` |
| Description | none |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `learnMemoryStored` |
| Arrival target | [`selfLearningDictionary.forgetMemory`](#node-selfLearningDictionary-forgetMemory) |
| Fallbacks, in order | [`selfLearningDictionary`](#node-selfLearningDictionary) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: forget, reset, blocked, unblock, memory<br>phrases: clear the memory of rejected corrections; let blocked words be learned again |
| Search (de) | words: Lerngedächtnis, blockiert, entsperren, vergessen<br>phrases: Lerngedächtnis löschen; abgelehnte Korrekturen vergessen; blockierte Wörter wieder lernen lassen |
| Search (es) | words: memoria, bloqueos, desbloquear<br>phrases: permitir que se vuelvan a aprender palabras bloqueadas; borrar la memoria de correcciones rechazadas |
| Search (fr) | words: oublier, mémoire, corrections refusées, mots bloqués, débloquer<br>phrases: effacer la mémoire des corrections refusées; permettre au dictionnaire d’apprendre les mots bloqués |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-importContacts"></a>

### Import from Contacts / Aus Kontakten importieren / Importar desde Contactos / Importer depuis Contacts (`importContacts`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.learnFrom`](#node-dictionary-tab-learnFrom) |
| Title source | catalog key `Import from Contacts` |
| Description | Add the names of people you know to your word list, so dictation spells them right. / Füge Namen von Personen zu deiner Wortliste hinzu, damit sie beim Diktieren richtig geschrieben werden. / Añade los nombres de las personas que conoces a tu lista de palabras para que el dictado los escriba correctamente. / Ajoutez les noms des personnes que vous connaissez à votre liste de mots pour que la dictée les orthographie correctement. |
| Description source | catalog key `Add the names of people you know to your word list, so dictation spells them right.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`importContacts`](#node-importContacts) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: addressbook<br>phrases: teach dictation the names in my address book; use names from my contacts to improve spelling |
| Search (de) | words: Adressbuch<br>phrases: die Namen aus meinem Adressbuch fürs Diktieren nutzen; Namen aus meinen Kontakten richtig erkennen lassen |
| Search (es) | words: agenda, nombres de contactos<br>phrases: cómo usar los nombres de mi agenda para que el dictado los escriba bien |
| Search (fr) | words: carnet d’adresses, vocabulaire des contacts<br>phrases: utiliser les noms de mon carnet d’adresses pour améliorer leur reconnaissance |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-contactsSyncOnLaunch"></a>

### Keep in sync on launch / Beim Start synchron halten / Mantener sincronizado al iniciar / Maintenir la synchronisation au lancement (`contactsSyncOnLaunch`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`importContacts`](#node-importContacts) |
| Title source | catalog key `Keep in sync on launch` |
| Description | Check for new contacts each time EnviousWispr starts. Off by default. / Bei jedem Start von EnviousWispr nach neuen Kontakten suchen. Standardmäßig deaktiviert. / Buscar nuevos contactos cada vez que se inicie EnviousWispr. Está desactivado por defecto. / Rechercher de nouveaux contacts à chaque démarrage d’EnviousWispr. Désactivé par défaut. |
| Description source | catalog key `Check for new contacts each time EnviousWispr starts. Off by default.` |
| Destination | `dictionary` |
| Dictionary tab | `learnFrom` |
| Shown when | `always` |
| Arrival target | [`contactsSyncOnLaunch`](#node-contactsSyncOnLaunch) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: sync, synchronization<br>phrases: check for new contact names when the app starts; keep my contact vocabulary updated on launch |
| Search (de) | words: Kontaktabgleich, Synchronisierung<br>phrases: bei jedem Appstart nach neuen Kontaktnamen suchen; meine Kontaktwörter beim Start aktuell halten |
| Search (es) | words: sincronizar contactos, actualizar contactos<br>phrases: buscar nuevos nombres de contactos cada vez que se abre la app |
| Search (fr) | words: synchronisation contacts, nouveaux contacts, sync au démarrage<br>phrases: chercher de nouveaux noms de contacts à chaque démarrage de l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step1"></a>

### Highlight a word / Wort markieren / Selecciona una palabra / Sélectionner un mot (`quickAdd.step1`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Highlight a word` |
| Description | Select the word you want to fix in an email, chat, or document. / Markiere das Wort, das du in einer E-Mail, einem Chat oder Dokument korrigieren möchtest. / Selecciona la palabra que quieres corregir en un correo electrónico, chat o documento. / Sélectionnez le mot que vous voulez corriger dans un e-mail, une conversation ou un document. |
| Description source | catalog key `Select the word you want to fix in an email, chat, or document.` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.step1`](#node-quickAdd-step1) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: highlight, highlighting<br>phrases: highlight the word I want to fix in another app; select a word before using Quick Add |
| Search (de) | words: Textauswahl, Textmarkierung<br>phrases: das Wort zum Korrigieren in einer anderen App markieren; vor Schnell hinzufügen ein Wort auswählen |
| Search (es) | words: resaltar palabra, seleccionar palabra<br>phrases: seleccionar en otra app la palabra que quiero corregir antes de usar Quick Add |
| Search (fr) | words: mot à sélectionner, surligner un mot<br>phrases: sélectionner le mot à corriger dans une autre application avant l’ajout rapide |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step2"></a>

### Trigger Quick Add / „Schnell hinzufügen“ aufrufen / Activar “Añadir rápidamente” / Déclencher l’ajout rapide (`quickAdd.step2`)

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
| Search (es) | words: abrir Quick Add, activar Quick Add<br>phrases: abrir Quick Add después de seleccionar una palabra |
| Search (fr) | words: déclenchement Quick Add, ouverture après sélection<br>phrases: comment déclencher l’ajout rapide une fois le mot sélectionné |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-step3"></a>

### Choose and save / Auswählen und sichern / Elegir y guardar / Choisir et enregistrer (`quickAdd.step3`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Choose and save` |
| Description | Choose the word you meant, or create a new one. Quick Add saves the highlighted spelling to your dictionary. / Wähle das gemeinte Wort oder erstelle ein neues. „Schnell hinzufügen“ speichert die markierte Schreibweise in deinem Wörterbuch. / Elige la palabra que querías escribir o crea una nueva. “Añadir rápidamente” guarda en tu Diccionario la palabra tal como aparece resaltada. / Choisissez le mot voulu ou créez-en un nouveau. L’ajout rapide enregistre l’orthographe sélectionnée dans votre dictionnaire. |
| Description source | catalog key `Choose the word you meant, or create a new one. Quick Add saves the highlighted spelling to your dictionary.` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.step3`](#node-quickAdd-step3) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose the intended word in Quick Add; save the highlighted spelling with the right dictionary word |
| Search (de) | phrases: bei Schnell hinzufügen das gemeinte Wort auswählen; die markierte Schreibweise beim richtigen Wörterbucheintrag speichern |
| Search (es) | words: palabra correcta, guardar variante seleccionada<br>phrases: elegir la palabra que quería decir y guardar la forma seleccionada en Quick Add |
| Search (fr) | words: mot voulu, association des orthographes<br>phrases: choisir le bon mot et enregistrer l’orthographe sélectionnée dans l’ajout rapide |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-shortcut"></a>

### Keyboard shortcut / Tastenkürzel / Atajo de teclado / Raccourci clavier (`quickAdd.shortcut`)

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
| Search (es) | words: ver atajo Quick Add, consultar teclas Quick Add<br>phrases: ver qué teclas abren Quick Add y dónde se cambian |
| Search (fr) | words: voir les touches Quick Add<br>phrases: voir quelles touches ouvrent l’ajout rapide et où modifier ce raccourci |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-quickAdd-menuBar"></a>

### Menu bar / Menüleiste / Barra de menús / Barre des menus (`quickAdd.menuBar`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`dictionary.tab.quickAdd`](#node-dictionary-tab-quickAdd) |
| Title source | catalog key `Menu bar` |
| Description | Click the EnviousWispr icon, then choose the item that starts with “Add” / Klicke auf das EnviousWispr-Symbol und wähle dann den Eintrag, der mit „hinzufügen“ endet / Haz clic en el icono de EnviousWispr y, después, elige el elemento que empieza por “Añadir” / Cliquez sur l’icône EnviousWispr, puis choisissez l’élément qui commence par « Ajouter » |
| Description source | catalog key `Click the EnviousWispr icon, then choose the item that starts with “Add”` |
| Destination | `dictionary` |
| Dictionary tab | `quickAdd` |
| Shown when | `always` |
| Arrival target | [`quickAdd.menuBar`](#node-quickAdd-menuBar) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: add a selected word through the EnviousWispr menu; find the Add item under the EnviousWispr icon |
| Search (de) | phrases: ein markiertes Wort über das EnviousWispr-Menü hinzufügen; den Eintrag zum Hinzufügen unter dem EnviousWispr-Symbol finden |
| Search (es) | words: Add del menú, añadir desde icono<br>phrases: añadir una palabra seleccionada desde el menú del icono de EnviousWispr |
| Search (fr) | words: menu EnviousWispr, commande Ajouter<br>phrases: trouver la commande Ajouter sous l’icône EnviousWispr dans la barre des menus |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets"></a>

### Paste the text you type over and over, by voice / Füge Text, den du oft tippst, per Stimme ein / Pega con la voz el texto que escribes una y otra vez / Coller à la voix les textes que vous saisissez souvent (`snippets`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`page.snippets`](#node-page-snippets) |
| Title source | catalog key `Paste the text you type over and over, by voice` |
| Description | Save an email address, a signature, a link. Say your keyword, then the trigger, and the saved text lands where your cursor is. Say the trigger on its own and your dictation is left alone. / Speichere eine E-Mail-Adresse, eine Signatur oder einen Link. Sprich dein Schlüsselwort und danach den Auslöser, und der gespeicherte Text erscheint an der Cursorposition. Sprichst du nur den Auslöser, bleibt dein Diktat unverändert. / Guarda una dirección de correo electrónico, una firma o un enlace. Di tu palabra clave y después el activador para que el texto guardado aparezca donde esté el cursor. Di solo el activador y tu dictado no cambiará. / Enregistrez une adresse e-mail, une signature ou un lien. Dites votre mot-clé, puis le déclencheur, et le texte enregistré s’insère à l’emplacement du curseur. Dites uniquement le déclencheur et votre dictée reste inchangée. |
| Description source | catalog key `Save an email address, a signature, a link. Say your keyword, then the trigger, and the saved text lands where your cursor is. Say the trigger on its own and your dictation is left alone.` |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippets`](#node-snippets) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: expander, expansion<br>phrases: insert saved text by voice; say a command instead of typing repeated text; paste a saved signature with my voice |
| Search (de) | words: Texterweiterung, Textersetzung<br>phrases: gespeicherten Text per Stimme einfügen; wiederkehrenden Text mit einem Sprachbefehl einsetzen; eine gespeicherte Signatur per Stimme einfügen |
| Search (es) | words: expansión de texto, expansor, firma por voz, texto repetido, Insertar textos guardados por voz<br>phrases: insertar texto guardado diciendo un comando |
| Search (fr) | words: expansion de texte, raccourcis vocaux, signature vocale<br>phrases: insérer un texte enregistré en disant le mot-clé puis son déclencheur |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippetKeyword"></a>

### Keyword / Schlüsselwort / Palabra clave / Mot-clé (`snippetKeyword`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`page.snippets`](#node-page-snippets) |
| Title source | catalog key `Keyword` |
| Description | Say this first, then your trigger. One word. / Sag zuerst dieses Wort, dann deinen Auslöser. Ein Wort. / Di esto primero y luego tu activador. Una palabra. / Dites d’abord ceci, puis votre déclencheur. Un seul mot. |
| Description source | catalog key `Say this first, then your trigger. One word.` |
| Destination | `snippets` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`snippetKeyword`](#node-snippetKeyword) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: prefix, opener<br>phrases: change the word I say before a snippet trigger; choose the opening word for snippet commands |
| Search (de) | words: Startwort, Einleitungswort<br>phrases: das Wort vor dem Textbausteinauslöser ändern; festlegen, mit welchem Wort meine Textbausteinbefehle anfangen |
| Search (es) | words: prefijo de snippets, palabra inicial de snippets<br>phrases: cambiar la palabra que digo antes del activador de un texto guardado |
| Search (fr) | words: préfixe des extraits, mot-clé snippets<br>phrases: choisir le mot à dire avant le déclencheur d’un extrait |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourSnippets"></a>

### Your snippets / Deine Textbausteine / Tus fragmentos de texto / Vos extraits de texte (`yourSnippets`)

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
| Search (es) | words: mis snippets, textos guardados, textos reutilizables<br>phrases: ver los textos que ya tengo guardados para insertar por voz |
| Search (fr) | words: extraits enregistrés, textes réutilisables, snippets sauvegardés<br>phrases: voir les textes réutilisables que j’ai déjà enregistrés |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-search"></a>

### Search snippets / Textbausteine durchsuchen / Buscar fragmentos de texto / Rechercher des extraits (`snippets.search`)

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
| Search (es) | words: buscar snippet, buscador de snippets, Buscar textos guardados<br>phrases: buscar un texto en mi colección de snippets |
| Search (fr) | words: recherche extraits, recherche snippets<br>phrases: chercher un extrait dans ma collection enregistrée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-import"></a>

### Import / Importieren / Importar / Importer (`snippets.import`)

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
| Search (es) | words: importar snippets, Importar textos guardados<br>phrases: importar una colección de textos reutilizables |
| Search (fr) | phrases: importer une collection de textes réutilisables |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-export"></a>

### Export / Exportieren / Exportar / Exporter (`snippets.export`)

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
| Search (es) | words: exportar snippets<br>phrases: exportar mi colección de textos guardados |
| Search (fr) | phrases: exporter ma collection de textes réutilisables |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-add"></a>

### Add snippet / Textbaustein hinzufügen / Añadir fragmento de texto / Ajouter un extrait (`snippets.add`)

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
| Search (es) | words: añadir otro snippet<br>phrases: añadir otro texto a mi colección de snippets |
| Search (fr) | words: ajouter un autre extrait<br>phrases: ajouter un autre extrait à ma collection existante |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-addFirst"></a>

### Add your first snippet / Ersten Textbaustein hinzufügen / Añadir tu primer fragmento de texto / Ajouter votre premier extrait (`snippets.addFirst`)

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
| Search (es) | words: primer snippet<br>phrases: crear mi primer texto para insertar por voz cuando la lista está vacía |
| Search (fr) | words: premier extrait<br>phrases: créer mon premier extrait quand la liste est vide |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-snippets-clearSearch"></a>

### Clear search / Suche löschen / Borrar búsqueda / Effacer la recherche (`snippets.clearSearch`)

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
| Search (es) | words: limpiar búsqueda de snippets, Borrar búsqueda de textos guardados<br>phrases: borrar la búsqueda de mi lista de snippets |
| Search (fr) | words: vider la recherche snippets<br>phrases: vider le champ de recherche de mes extraits |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetings-tab-general"></a>

### General / Allgemein / General / Général (`meetings.tab.general`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.meetings`](#node-page-meetings) |
| Title source | catalog key `General` |
| Description | none |
| Destination | `meetings` › `general` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetings.tab.general`](#node-meetings-tab-general) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: general EnviousMeet settings |
| Search (de) | phrases: allgemeine Einstellungen für EnviousMeet |
| Search (es) | phrases: ajustes generales de EnviousMeet |
| Search (fr) | phrases: ouvrir l’onglet général d’EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetings-tab-models"></a>

### Models / Modelle / Modelos / Modèles (`meetings.tab.models`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.meetings`](#node-page-meetings) |
| Title source | catalog key `Models` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetings.tab.models`](#node-meetings-tab-models) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: meeting models; EnviousMeet models |
| Search (de) | phrases: Modelle für Meetings; Modelle in EnviousMeet |
| Search (es) | phrases: modelos para reuniones |
| Search (fr) | phrases: modèles pour les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetings-tab-summaries"></a>

### Summaries / Zusammenfassungen / Resúmenes / Résumés (`meetings.tab.summaries`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.meetings`](#node-page-meetings) |
| Title source | catalog key `Summaries` |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetings.tab.summaries`](#node-meetings-tab-summaries) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: meeting summary settings; EnviousMeet summaries tab |
| Search (de) | phrases: Tab Zusammenfassungen in EnviousMeet öffnen; zu den Einstellungen für Meetingzusammenfassungen wechseln |
| Search (es) | phrases: pestaña de resúmenes de EnviousMeet; dónde están los ajustes de resúmenes de reuniones |
| Search (fr) | phrases: ouvrir l’onglet résumés d’EnviousMeet; où sont les réglages des résumés de réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetings-tab-callApps"></a>

### Call Apps / Anruf-Apps / Apps de llamadas / Apps d’appel (`meetings.tab.callApps`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.meetings`](#node-page-meetings) |
| Title source | catalog key `Call Apps` |
| Description | none |
| Destination | `meetings` › `callApps` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetings.tab.callApps`](#node-meetings-tab-callApps) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Zoom, Microsoft Teams, FaceTime, Slack, Webex, Google Meet<br>phrases: choose which apps to watch for calls; turn off call detection for Zoom |
| Search (de) | words: Zoom, Microsoft Teams, FaceTime, Slack, Webex, Google Meet<br>phrases: lege fest, bei welchen Apps EnviousMeet Anrufe erkennt; schalte die Anruferkennung für Zoom aus; schalte die Anruferkennung für Meetings im Browser aus |
| Search (es) | phrases: pestaña de apps de llamadas; lista de aplicaciones de llamadas en EnviousMeet |
| Search (fr) | words: applis d’appel<br>phrases: paramètres des applications d’appel; liste des applications d’appel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetings-tab-permissions"></a>

### Permissions / Berechtigungen / Permisos / Autorisations (`meetings.tab.permissions`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.meetings`](#node-page-meetings) |
| Title source | catalog key `Permissions` |
| Description | none |
| Destination | `meetings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetings.tab.permissions`](#node-meetings-tab-permissions) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: meeting permissions, call sound<br>phrases: EnviousMeet permissions; check permissions for meeting recording; allow microphone access for meeting recording |
| Search (de) | phrases: Berechtigungen für EnviousMeet; welche Berechtigungen braucht EnviousMeet |
| Search (es) | phrases: permisos de EnviousMeet; permisos para grabar reuniones |
| Search (fr) | words: permissions EnviousMeet<br>phrases: autorisations pour EnviousMeet; vérifier les autorisations pour enregistrer une réunion; autoriser le micro et le son du Mac pour EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-appearance"></a>

### Appearance / Erscheinungsbild / Aspecto / Apparence (`appSettings.tab.appearance`)

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
| Search (es) | words: pestaña Appearance, ajustes de apariencia<br>phrases: abrir la pestaña de apariencia de la app |
| Search (fr) | words: onglet apparence, réglages visuels<br>phrases: ouvrir l’onglet Apparence des réglages de l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-permissions"></a>

### Permissions / Berechtigungen / Permisos / Autorisations (`appSettings.tab.permissions`)

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
| Search (es) | words: autorizaciones<br>phrases: ver todos los permisos del Mac que necesita la app |
| Search (fr) | words: permissions macOS, autorisations de l’app<br>phrases: voir toutes les autorisations du Mac nécessaires à l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-privacy"></a>

### Privacy / Datenschutz / Privacidad / Confidentialité (`appSettings.tab.privacy`)

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
| Search (es) | words: privacidad de la app, ajustes de privacidad<br>phrases: abrir la pestaña de privacidad de la app |
| Search (fr) | words: onglet confidentialité, partage de données<br>phrases: ouvrir l’onglet Confidentialité des réglages de l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-recordings"></a>

### Recordings / Aufnahmen / Grabaciones / Enregistrements (`appSettings.tab.recordings`)

| Field | Value |
|---|---|
| Structure | tab |
| Kind | feature |
| Parent | [`page.appSettings`](#node-page-appSettings) |
| Title source | catalog key `Recordings` |
| Description | none |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appSettings.tab.recordings`](#node-appSettings-tab-recordings) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: audio recordings, voice recordings<br>phrases: save dictation recordings; how long to keep meeting audio; delete saved audio to free up space |
| Search (de) | words: Audioaufnahmen, Diktataufnahmen, Aufbewahrungsdauer, Speicherplatz<br>phrases: speichere meine Diktataufnahmen; wie lange werden Diktataufnahmen und Meeting-Audio aufbewahrt; lösche gespeicherte Audioaufnahmen |
| Search (es) | words: grabaciones de dictado, audio de reuniones, almacenamiento de audio<br>phrases: guardar las grabaciones de mis dictados; cuánto tiempo se conservan las grabaciones; borrar el audio sin borrar el texto |
| Search (fr) | words: enregistrements audio, audio des réunions, durée de conservation, stockage audio<br>phrases: conserver les enregistrements de dictée; supprimer les enregistrements sans effacer le texte; régler le seuil d’alerte du stockage audio |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appSettings-tab-licenses"></a>

### Licenses / Lizenzen / Licencias / Licences (`appSettings.tab.licenses`)

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
| Search (es) | words: copyright, derechos de autor<br>phrases: ver el resumen de licencias de la app y de sus componentes |
| Search (fr) | words: onglet licences, droits d’auteur<br>phrases: ouvrir la vue d’ensemble des licences de l’application et des logiciels tiers |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme"></a>

### Theme / Design / Tema / Thème (`theme`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Theme` |
| Description | Choose how EnviousWispr looks. / Lege fest, wie EnviousWispr aussieht. / Elige el aspecto de EnviousWispr. / Choisissez l’apparence d’EnviousWispr. |
| Description source | catalog key `Choose how EnviousWispr looks.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`theme`](#node-theme) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: colors, colours, palette<br>phrases: change the app's color scheme; choose the app's appearance mode |
| Search (de) | words: Farbschema, Farben, Farbmodus<br>phrases: das Farbschema der App ändern; den Darstellungsmodus der App auswählen |
| Search (es) | words: colores, paleta<br>phrases: cambiar el esquema de colores de la app |
| Search (fr) | words: couleurs, palette<br>phrases: où choisir le thème de l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage"></a>

### Language / Sprache / Idioma / Langue (`appLanguage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Language` |
| Description | The language of the app interface. / Die Sprache der App-Oberfläche. / El idioma de la interfaz de la app. / La langue de l’interface de l’app. |
| Description source | catalog key `The language of the app interface.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`appLanguage`](#node-appLanguage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: locale, localization, translation<br>phrases: change the language of the app menus; change the language used in Settings |
| Search (de) | words: Oberflächensprache, Menüsprache, Übersetzung<br>phrases: die Sprache der Appmenüs ändern; die Sprache der Einstellungen ändern |
| Search (es) | words: idioma de menús, traducción, idioma de interfaz<br>phrases: cambiar el idioma de los menús de la app |
| Search (fr) | words: langue des menus, traduction, localisation<br>phrases: où changer la langue des menus et des réglages de l’application |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage-systemDefault"></a>

### System default / Systemstandard / Predeterminado del sistema / Par défaut du système (`appLanguage.systemDefault`)

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
| Search (es) | words: idioma según macOS, idioma de interfaz automático<br>phrases: usar en la app el mismo idioma que tiene mi Mac |
| Search (fr) | words: langue système, langue automatique des menus<br>phrases: utiliser la même langue que mon Mac pour l’interface |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Search (en) | words: English, German, Deutsch, French, interface languages, Spanish<br>phrases: show the app menus in English; show the app menus in German; show the app menus in French; show the app menus in Spanish |
| Search (de) | words: Deutsch, Englisch, English, Französisch, Oberflächensprachen, Spanisch<br>phrases: die Appmenüs auf Deutsch anzeigen; die Appmenüs auf Englisch anzeigen; die Appmenüs auf Französisch anzeigen; die Appmenüs auf Spanisch anzeigen |
| Search (es) | words: menús en inglés, menús en alemán, English interfaz, Deutsch interfaz, menús en francés, menús en español, idiomas de interfaz, Idiomas disponibles para la interfaz<br>phrases: poner los menús de la app en inglés; poner los menús de la app en alemán; poner los menús de la app en francés; poner los menús de la app en español |
| Search (fr) | words: menus anglais, menus allemands, English, Deutsch, menus français, langues d’interface, menus espagnols<br>phrases: afficher les menus de l’application en anglais; afficher les menus de l’application en allemand; afficher les menus de l’application en français; afficher les menus de l’application en espagnol |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-appLanguage-relaunch"></a>

### Relaunch to apply / Zum Übernehmen neu starten / Reiniciar para aplicar / Relancer pour appliquer (`appLanguage.relaunch`)

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
| Search (es) | words: reiniciar por idioma<br>phrases: reiniciar la app para aplicar el nuevo idioma de los menús |
| Search (fr) | words: relancer pour la langue<br>phrases: redémarrer l’application pour appliquer la nouvelle langue des menus |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-showInDock"></a>

### Show app in Dock / App im Dock anzeigen / Mostrar la app en el Dock / Afficher l’app dans le Dock (`showInDock`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Show app in Dock` |
| Description | Keep EnviousWispr in your Dock. / EnviousWispr im Dock behalten. / Mantener EnviousWispr en el Dock. / Conserver EnviousWispr dans le Dock. |
| Description source | catalog key `Keep EnviousWispr in your Dock.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`showInDock`](#node-showInDock) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: keep the EnviousWispr icon in my Dock; hide EnviousWispr from the Dock |
| Search (de) | phrases: das EnviousWispr-Symbol im Dock behalten; EnviousWispr aus dem Dock ausblenden |
| Search (es) | words: Dock, icono del Dock<br>phrases: mostrar u ocultar EnviousWispr en el Dock |
| Search (fr) | words: Dock, icône Dock<br>phrases: afficher ou masquer EnviousWispr dans le Dock |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-updateAlertInMenuBar"></a>

### Update alert in menu bar / Update-Hinweis in der Menüleiste / Aviso de actualización en la barra de menús / Alerte de mise à jour dans la barre des menus (`updateAlertInMenuBar`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.appearance`](#node-section-appearance) |
| Title source | catalog key `Update alert in menu bar` |
| Description | Show gold lips when an update is ready. / Goldene Lippen anzeigen, wenn ein Update bereitsteht. / Mostrar los labios dorados cuando haya una actualización disponible. / Afficher les lèvres dorées lorsqu’une mise à jour est disponible. |
| Description source | catalog key `Show gold lips when an update is ready.` |
| Destination | `appSettings` › `appearance` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`updateAlertInMenuBar`](#node-updateAlertInMenuBar) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: gold, golden, lips, badge<br>phrases: show gold lips when an update is ready; hide the update indicator in the menu bar |
| Search (de) | words: gold, golden, Lippen, Updatesymbol<br>phrases: goldene Lippen anzeigen, wenn ein Update bereitsteht; den Update-Hinweis in der Menüleiste ausblenden |
| Search (es) | words: labios dorados, aviso de actualización, badge de actualización<br>phrases: mostrar u ocultar los labios dorados cuando haya una actualización lista |
| Search (fr) | words: lèvres dorées, badge de mise à jour<br>phrases: afficher ou masquer les lèvres dorées quand une mise à jour est prête |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-microphone"></a>

### Microphone / Mikrofon / Micrófono / Micro (`permission.microphone`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.permissions`](#node-section-permissions) |
| Title source | catalog key `Microphone` |
| Description | Needed to record your voice. / Nötig, um deine Stimme aufzunehmen. / Se necesita para grabar tu voz. / Nécessaire pour enregistrer votre voix. |
| Description source | catalog key `Needed to record your voice.` |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`permission.microphone`](#node-permission-microphone) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: mic, recording, audio<br>phrases: check whether the app can record my voice; why is microphone access denied |
| Search (de) | words: Mikro, Aufnahme, Sprachaufnahme<br>phrases: prüfen, ob die App meine Stimme aufnehmen darf; warum ist der Mikrofonzugriff gesperrt |
| Search (es) | words: acceso al micro, micrófono denegado<br>phrases: comprobar si la app tiene permiso para grabar mi voz; por qué está denegado el acceso al micrófono |
| Search (fr) | words: accès micro, micro refusé, permission micro<br>phrases: vérifier si l’application a l’autorisation d’enregistrer ma voix |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-microphone-request"></a>

### Request Access / Zugriff anfordern / Solicitar acceso / Demander l’accès (`permission.microphone.request`)

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
| Search (es) | words: pedir permiso del micro, solicitar acceso al micro<br>phrases: pedir permiso para usar el micrófono |
| Search (fr) | words: demander l’accès micro<br>phrases: demander l’autorisation d’utiliser le microphone |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-accessibility"></a>

### Accessibility / Bedienungshilfen / Accesibilidad / Accessibilité (`permission.accessibility`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.permissions`](#node-section-permissions) |
| Title source | catalog key `Accessibility` |
| Description | Needed to paste text into other apps. / Nötig, um Text in andere Apps einzufügen. / Se necesita para pegar texto en otras apps. / Nécessaire pour coller du texte dans d’autres apps. |
| Description source | catalog key `Needed to paste text into other apps.` |
| Destination | `appSettings` › `permissions` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`permission.accessibility`](#node-permission-accessibility) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: paste, pasting, insertion<br>phrases: check the permission needed to paste dictation into other apps; why does text insertion need Accessibility access |
| Search (de) | words: Einfügeberechtigung, Einfügen, Texteingabe<br>phrases: die Berechtigung zum Einfügen von Diktaten prüfen; warum braucht die Texteingabe Zugriff auf Bedienungshilfen |
| Search (es) | words: accesibilidad, permiso para pegar<br>phrases: comprobar el permiso de Accesibilidad necesario para pegar el dictado en otras apps |
| Search (fr) | words: accessibilité, permission collage<br>phrases: vérifier l’autorisation nécessaire pour coller ma dictée dans d’autres applications |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-permission-accessibility-openSettings"></a>

### Open System Settings / Systemeinstellungen öffnen / Abrir Ajustes del Sistema / Ouvrir Réglages Système (`permission.accessibility.openSettings`)

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
| Search (es) | words: conceder accesibilidad<br>phrases: abrir los ajustes del Mac para dar o volver a dar permiso de Accesibilidad |
| Search (fr) | words: ouvrir les autorisations d’accessibilité<br>phrases: ouvrir les réglages du Mac pour accorder l’accès à l’accessibilité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-shareUsageMetrics"></a>

### Share usage metrics / Nutzungsstatistiken teilen / Compartir métricas de uso / Partager les données d’utilisation (`shareUsageMetrics`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `Share usage metrics` |
| Description | Help us catch broken updates. / Hilf uns, fehlerhafte Updates zu erkennen. / Ayúdanos a detectar actualizaciones defectuosas. / Aidez-nous à détecter les mises à jour défectueuses. |
| Description source | catalog key `Help us catch broken updates.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`shareUsageMetrics`](#node-shareUsageMetrics) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: analytics, statistics<br>phrases: share usage data to help spot broken updates; turn off usage analytics |
| Search (de) | words: Nutzungsdaten, Nutzungsanalyse<br>phrases: Nutzungsdaten teilen, um fehlerhafte Updates zu erkennen; die Nutzungsanalyse ausschalten |
| Search (es) | words: estadísticas, analítica, métricas de uso, analytics<br>phrases: activar o desactivar el envío de estadísticas de uso para detectar actualizaciones con fallos |
| Search (fr) | words: statistiques, données d’usage, analytics, télémétrie<br>phrases: activer ou désactiver le partage des statistiques d’utilisation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-sendCrashReports"></a>

### Send crash reports / Absturzberichte senden / Enviar informes de fallos / Envoyer les rapports de plantage (`sendCrashReports`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `Send crash reports` |
| Description | Help us fix crashes and errors. / Hilf uns, Abstürze und Fehler zu beheben. / Ayúdanos a corregir cierres inesperados y errores. / Aidez-nous à corriger les plantages et les erreurs. |
| Description source | catalog key `Help us fix crashes and errors.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`sendCrashReports`](#node-sendCrashReports) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: crashes, errors, diagnostics<br>phrases: send information about app crashes and errors; stop sending crash reports |
| Search (de) | words: Abstürze, Fehler, Fehlerdiagnose<br>phrases: Informationen zu Abstürzen und Fehlern senden; keine Absturzberichte mehr senden |
| Search (es) | words: crashes, cierres inesperados, diagnósticos, reportes de fallos<br>phrases: activar o desactivar el envío de informes de errores y cierres inesperados |
| Search (fr) | words: plantages, crashs, diagnostics, rapports d’erreurs<br>phrases: activer ou désactiver l’envoi des rapports de plantage et d’erreur |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-sendCrashReports-restart"></a>

### Restart now / Jetzt neu starten / Reiniciar ahora / Redémarrer maintenant (`sendCrashReports.restart`)

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
| Search (es) | words: reiniciar por informes de fallos<br>phrases: reiniciar la app para aplicar el ajuste de informes de fallos |
| Search (fr) | words: redémarrer pour les rapports<br>phrases: redémarrer l’application pour appliquer le réglage des rapports de plantage |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whatWeCollect"></a>

### What we collect / Was wir erfassen / Qué recopilamos / Ce que nous recueillons (`whatWeCollect`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.privacy`](#node-section-privacy) |
| Title source | catalog key `What we collect` |
| Description | Never your audio, text, history, snippets, dictionary or API keys. Only what you type into the feedback form. / Niemals deine Audiodaten, Texte, deinen Verlauf, deine Textbausteine, dein Wörterbuch oder API-Schlüssel. Nur was du in das Feedback-Formular eingibst. / Nunca recopilamos tu audio, texto, historial, fragmentos, diccionario ni claves de API. Solo lo que escribas en el formulario de comentarios. / Jamais votre audio, vos textes, votre historique, vos extraits, votre dictionnaire ou vos clés API. Uniquement ce que vous saisissez dans le formulaire de commentaires. |
| Description source | catalog key `Never your audio, text, history, snippets, dictionary or API keys. Only what you type into the feedback form.` |
| Destination | `appSettings` › `privacy` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`whatWeCollect`](#node-whatWeCollect) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: collection, feedback<br>phrases: what information does the app collect; are my recordings or dictations collected; does the app collect my dictionary or API keys |
| Search (de) | words: Datenerfassung, Feedbackdaten<br>phrases: welche Daten erfasst die App; werden meine Aufnahmen oder Diktate gesammelt; werden mein Wörterbuch oder meine API-Schlüssel erfasst |
| Search (es) | words: datos recopilados, datos del formulario<br>phrases: qué información recopila la app; se recopilan mis grabaciones, dictados o claves de API |
| Search (fr) | words: données collectées, collecte, formulaire de retour<br>phrases: quelles informations l’application collecte-t-elle; est-ce que mes dictées ou mes clés API sont collectées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-whatWeCollect-seeDetails"></a>

### See details / Details ansehen / Ver detalles / Afficher les détails (`whatWeCollect.seeDetails`)

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
| Search (es) | words: detalles de recopilación, Ver detalles de los datos recopilados<br>phrases: abrir la explicación detallada de los datos que se recopilan |
| Search (fr) | words: détails de la collecte<br>phrases: ouvrir l’explication détaillée des données collectées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-saveDictationRecordings"></a>

### Save dictation recordings / Diktataufnahmen speichern / Guardar grabaciones de dictado / Enregistrer l’audio des dictées (`saveDictationRecordings`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.recordings`](#node-section-recordings) |
| Title source | catalog key `Save dictation recordings` |
| Description | Keep the audio of each new dictation on this Mac, so you can play it back. / Speichert das Audio jedes neuen Diktats auf diesem Mac, damit du es abspielen kannst. / Conservar el audio de cada nuevo dictado en este Mac para poder reproducirlo. / Conserver l’audio de chaque nouvelle dictée sur ce Mac pour pouvoir le réécouter. |
| Description source | catalog key `Keep the audio of each new dictation on this Mac, so you can play it back.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`saveDictationRecordings`](#node-saveDictationRecordings) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: keep audio<br>phrases: save each dictation's audio on my Mac; keep recordings so I can listen later |
| Search (de) | words: Audioaufnahmen, Diktataudio<br>phrases: speichere den Ton neuer Diktate auf diesem Mac zum späteren Anhören; speichere keine Audioaufnahmen neuer Diktate mehr |
| Search (es) | phrases: conservar el audio de cada dictado; guardar mis dictados para escucharlos después |
| Search (fr) | phrases: garder l’audio de chaque dictée; enregistrer mes dictées pour les réécouter |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-dictationRecordingRetention"></a>

### Keep dictation recordings / Diktataufnahmen behalten / Conservar las grabaciones de dictados / Conserver les enregistrements de dictée (`dictationRecordingRetention`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.recordings`](#node-section-recordings) |
| Title source | catalog key `Keep dictation recordings` |
| Description | Choose how long to keep recordings. The text always stays. / Wähle, wie lange Aufnahmen behalten werden. Der Text bleibt immer erhalten. / Elige cuánto tiempo quieres conservar las grabaciones. El texto siempre se conserva. / Choisissez combien de temps conserver les enregistrements. Le texte reste toujours disponible. |
| Description source | catalog key `Choose how long to keep recordings. The text always stays.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`dictationRecordingRetention`](#node-dictationRecordingRetention) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dictation recording retention<br>phrases: how long are dictation recordings kept; automatically delete old dictation recordings but keep the text; keep dictation recordings until I delete them |
| Search (de) | words: Aufbewahrungsdauer, Diktataufnahmen<br>phrases: wie lange bleiben meine Diktataufnahmen gespeichert; alte Diktataufnahmen automatisch löschen und den Text behalten |
| Search (es) | phrases: cuánto tiempo se guardan las grabaciones de dictado; borrar automáticamente las grabaciones antiguas de dictado sin borrar el texto; guardar las grabaciones de dictado hasta que las borre |
| Search (fr) | words: durée de conservation<br>phrases: choisir combien de temps garder l’audio des dictées; supprimer automatiquement les anciens enregistrements de dictée sans supprimer le texte |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingRecordingRetention"></a>

### Keep meeting audio / Meeting-Audio behalten / Conservar el audio de las reuniones / Conserver l’audio des réunions (`meetingRecordingRetention`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.recordings`](#node-section-recordings) |
| Title source | catalog key `Keep meeting audio` |
| Description | Meeting text, notes and summaries always stay. / Meeting-Text, Notizen und Zusammenfassungen bleiben immer erhalten. / El texto, las notas y los resúmenes de las reuniones siempre se conservan. / Le texte, les notes et les résumés des réunions sont toujours conservés. |
| Description source | catalog key `Meeting text, notes and summaries always stay.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingRecordingRetention`](#node-meetingRecordingRetention) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: meeting recordings, meeting audio retention<br>phrases: choose how long to keep meeting audio; automatically delete old meeting audio; keep meeting audio until I delete it |
| Search (de) | words: Meeting-Audio, Meetingaudio, Aufbewahrungsdauer<br>phrases: stell ein, wie lange Meeting-Audio gespeichert bleibt; bewahre Meeting-Audio 30 oder 90 Tage auf; behalte Meeting-Audio, bis ich es lösche |
| Search (es) | words: retención del audio, caducidad del audio<br>phrases: cuánto tiempo guardar el audio de las reuniones; borrar automáticamente el audio antiguo de las reuniones; conservar el audio de las reuniones hasta que lo borre |
| Search (fr) | words: enregistrements de réunions<br>phrases: choisir combien de temps garder l’audio des réunions; supprimer automatiquement l’audio des anciennes réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingStorageUsage"></a>

### Storage used / Belegter Speicher / Espacio utilizado / Stockage utilisé (`recordingStorageUsage`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.recordingStorage`](#node-section-recordingStorage) |
| Title source | catalog key `Storage used` |
| Description | composed at display time from live state (not exported) |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingStorageUsage`](#node-recordingStorageUsage) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recording size, disk usage<br>phrases: how much space do my recordings take; space taken up by recordings |
| Search (de) | words: Speicherbelegung, Speicherverbrauch<br>phrases: wie viel Platz brauchen meine Aufnahmen; zeig mir die Größe meiner Aufnahmen |
| Search (es) | words: tamaño de las grabaciones<br>phrases: cuánto ocupan las grabaciones; espacio que usan mis grabaciones |
| Search (fr) | words: taille des enregistrements<br>phrases: combien de place prennent mes enregistrements; espace occupé par les enregistrements |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingStorageWarningThreshold"></a>

### Storage warning threshold / Speicherwarnschwelle / Umbral de aviso de almacenamiento / Seuil d’avertissement du stockage (`recordingStorageWarningThreshold`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.recordingStorage`](#node-section-recordingStorage) |
| Title source | catalog key `Storage warning threshold` |
| Description | Get a warning when recordings use more than this. / Erhalte eine Warnung, wenn Aufnahmen mehr Speicher als diesen Wert belegen. / Recibe un aviso cuando las grabaciones superen este límite. / Recevoir un avertissement lorsque les enregistrements utilisent plus que cette valeur. |
| Description source | catalog key `Get a warning when recordings use more than this.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingStorageWarningThreshold`](#node-recordingStorageWarningThreshold) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: recording size alert, disk usage warning<br>phrases: warn me when recordings take up too much space; set when the recording storage warning appears |
| Search (de) | words: Warnschwelle, Speicherplatzwarnung<br>phrases: warne mich, wenn Aufnahmen mehr als 2 GB belegen; schalte die Speicherplatzwarnung für Aufnahmen aus |
| Search (es) | words: aviso de almacenamiento, alerta de espacio<br>phrases: avísame cuando las grabaciones ocupen demasiado espacio; elegir a partir de cuántos GB de grabaciones mostrar un aviso; desactivar el aviso de espacio de las grabaciones |
| Search (fr) | words: alerte de stockage, seuil d’avertissement<br>phrases: me prévenir quand les enregistrements prennent trop de place; régler le seuil d’alerte pour l’espace occupé par les enregistrements; désactiver l’alerte de stockage des enregistrements |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingThresholdBehavior"></a>

### Past the threshold / Über der Schwelle / Al superar el umbral / Au-delà du seuil (`recordingThresholdBehavior`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | setting |
| Parent | [`section.recordingStorage`](#node-section-recordingStorage) |
| Title source | catalog key `Past the threshold` |
| Description | Ask you, or remove the oldest dictation recordings. / Dich fragen oder die ältesten Diktataufnahmen entfernen. / Preguntarte o eliminar las grabaciones de dictados más antiguas. / Vous demander quoi faire ou supprimer les enregistrements les plus anciens. |
| Description source | catalog key `Ask you, or remove the oldest dictation recordings.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingThresholdBehavior`](#node-recordingThresholdBehavior) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: automatic deletion<br>phrases: ask me to free space when storage is over the limit; automatically delete the oldest dictation recordings when over the storage limit |
| Search (de) | words: Löschverhalten, automatisches Löschen<br>phrases: frag mich, ob ich Platz schaffen möchte, wenn Aufnahmen die Warnschwelle überschreiten; lösche die ältesten Diktataufnahmen automatisch, wenn Aufnahmen die Warnschwelle überschreiten |
| Search (es) | words: borrado automático, al superar el límite de almacenamiento<br>phrases: preguntarme antes de liberar espacio al superar el límite; borrar las grabaciones de dictado más antiguas al superar el límite |
| Search (fr) | words: suppression automatique<br>phrases: me demander de libérer de l’espace quand le seuil est dépassé; supprimer automatiquement les plus anciens enregistrements de dictée au-delà du seuil |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-deleteRecordings"></a>

### Delete recordings / Aufnahmen löschen / Eliminar grabaciones / Supprimer les enregistrements (`deleteRecordings`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.recordingStorage`](#node-section-recordingStorage) |
| Title source | catalog key `Delete recordings` |
| Description | Text, meeting notes and summaries stay. / Text, Meeting-Notizen und Zusammenfassungen bleiben erhalten. / El texto, las notas de reuniones y los resúmenes se conservan. / Le texte, les notes de réunion et les résumés sont conservés. |
| Description source | catalog key `Text, meeting notes and summaries stay.` |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`deleteRecordings`](#node-deleteRecordings) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: audio files, remove<br>phrases: delete audio and keep the text |
| Search (de) | words: Audiodateien, Aufnahmen<br>phrases: lösche Audio von Diktaten oder Meetings; lösche Aufnahmen und behalte Text, Notizen und Zusammenfassungen |
| Search (es) | words: archivos de audio<br>phrases: borrar el audio y conservar el texto |
| Search (fr) | words: fichiers audio, effacer<br>phrases: supprimer l’audio et garder le texte |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-deleteRecordings-dictations"></a>

### Delete all dictation recordings / Alle Diktataufnahmen löschen / Eliminar todas las grabaciones de dictado / Supprimer tous les enregistrements de dictée (`deleteRecordings.dictations`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`deleteRecordings`](#node-deleteRecordings) |
| Title source | catalog key `Delete all dictation recordings` |
| Description | none |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`deleteRecordings.dictations`](#node-deleteRecordings-dictations) |
| Fallbacks, in order | [`deleteRecordings`](#node-deleteRecordings) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dictation audio<br>phrases: remove all my dictation audio recordings |
| Search (de) | words: Diktataudio<br>phrases: lösch alle Audioaufnahmen meiner Diktate |
| Search (es) | phrases: borrar todos los audios de dictado |
| Search (fr) | phrases: effacer tous les audios de mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-deleteRecordings-meetings"></a>

### Delete all meeting audio / Gesamtes Meeting-Audio löschen / Eliminar todo el audio de las reuniones / Supprimer tout l’audio des réunions (`deleteRecordings.meetings`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | action |
| Parent | [`deleteRecordings`](#node-deleteRecordings) |
| Title source | catalog key `Delete all meeting audio` |
| Description | none |
| Destination | `appSettings` › `recordings` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`deleteRecordings.meetings`](#node-deleteRecordings-meetings) |
| Fallbacks, in order | [`deleteRecordings`](#node-deleteRecordings) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: meeting recordings<br>phrases: delete audio recordings of all meetings |
| Search (de) | words: Besprechungsaufnahmen<br>phrases: lösch die Audioaufnahmen aller Meetings |
| Search (es) | phrases: borrar las grabaciones de audio de todas las reuniones |
| Search (fr) | phrases: effacer les enregistrements audio de toutes les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-gpl"></a>

### EnviousWispr · GPLv3 / EnviousWispr · GPLv3 / EnviousWispr · GPLv3 / EnviousWispr · GPLv3 (`license.gpl`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.about`](#node-section-about) |
| Title source | catalog key `EnviousWispr · GPLv3` |
| Description | Open source under the GNU GPL version 3. / Open Source unter der GNU GPL Version 3. / Código abierto con licencia GNU GPL versión 3. / Open source sous licence GNU GPL version 3. |
| Description source | catalog key `Open source under the GNU GPL version 3.` |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.gpl`](#node-license-gpl) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: opensource, copyleft, GNU, GPL<br>phrases: is EnviousWispr open source; which open-source license covers EnviousWispr |
| Search (de) | words: quelloffen, Copyleft, GNU, GPL<br>phrases: ist EnviousWispr Open Source; unter welcher freien Lizenz steht EnviousWispr |
| Search (es) | words: código abierto, open source, copyleft, GNU, GPLv3<br>phrases: qué licencia de código abierto tiene EnviousWispr |
| Search (fr) | words: open source, logiciel libre, copyleft, GNU GPL<br>phrases: sous quelle licence libre est publié EnviousWispr |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-gpl-view"></a>

### View license / Lizenz ansehen / Ver licencia / Afficher la licence (`license.gpl.view`)

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
| Search (es) | words: leer GPLv3, abrir licencia GPL<br>phrases: abrir el texto completo de la licencia GPLv3 |
| Search (fr) | words: texte intégral GPLv3<br>phrases: ouvrir le texte complet de la licence GPLv3 |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-notices"></a>

### Third-Party Notices / Hinweise zu Drittanbietern / Avisos de terceros / Mentions légales de tiers (`license.notices`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | feature |
| Parent | [`section.about`](#node-section-about) |
| Title source | catalog key `Third-Party Notices` |
| Description | Licenses for the tools EnviousWispr uses. / Lizenzen der Werkzeuge, die EnviousWispr nutzt. / Licencias de las herramientas que usa EnviousWispr. / Licences des outils utilisés par EnviousWispr. |
| Description source | catalog key `Licenses for the tools EnviousWispr uses.` |
| Destination | `appSettings` › `licenses` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`license.notices`](#node-license-notices) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dependencies, libraries, components<br>phrases: which licenses cover the tools used by EnviousWispr; find licensing information for the app's dependencies |
| Search (de) | words: Bibliothekslizenzen, Komponentenlizenzen, Fremdsoftware<br>phrases: welche Lizenzen gelten für die verwendeten Werkzeuge; Lizenzinformationen zu den eingebauten Bibliotheken finden |
| Search (es) | words: dependencias, bibliotecas, componentes de terceros<br>phrases: qué licencias tienen las herramientas que usa EnviousWispr |
| Search (fr) | words: dépendances, bibliothèques tierces, composants tiers<br>phrases: quelles licences couvrent les outils utilisés par EnviousWispr |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-license-notices-view"></a>

### View notices / Hinweise ansehen / Ver avisos / Afficher les avis (`license.notices.view`)

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
| Search (es) | words: abrir avisos de terceros<br>phrases: abrir los avisos de licencias de terceros |
| Search (fr) | words: ouvrir les mentions tierces<br>phrases: ouvrir les mentions de licence des logiciels tiers |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-fast"></a>

### Fast / Schnell / Rápido / Rapide (`transcriptionEngine.fast`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `Fast` |
| Description | Pick this for everyday English and European dictation. / Wähle dies für alltägliche Diktate auf Englisch und in europäischen Sprachen. / Elige este para dictados cotidianos en inglés y en idiomas europeos. / Choisissez cette option pour les dictées quotidiennes en anglais et dans les langues européennes. |
| Description source | catalog key `Pick this for everyday English and European dictation.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Parakeet, European, ANE<br>phrases: use Parakeet for dictation; choose the dictation model that uses the Apple Neural Engine |
| Search (de) | words: Parakeet, europäisch, ANE<br>phrases: nimm Parakeet fürs Diktieren; wähle das Diktiermodell für europäische Sprachen |
| Search (es) | words: Parakeet dictado, ANE dictado, Fast dictado<br>phrases: usar Parakeet para dictar; elegir el modelo de dictado que usa el Neural Engine |
| Search (fr) | words: Parakeet dictée, ANE dictée, dictée européenne<br>phrases: utiliser Parakeet pour mes dictées; choisir le modèle de dictée qui utilise le Neural Engine |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-transcriptionEngine-allLanguages"></a>

### All Languages / Alle Sprachen / Todos los idiomas / Toutes les langues (`transcriptionEngine.allLanguages`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`transcriptionEngine`](#node-transcriptionEngine) |
| Title source | catalog key `All Languages` |
| Description | Pick this for other languages or the toughest audio. / Wähle dies für andere Sprachen oder besonders schwierige Aufnahmen. / Elige este para otros idiomas o para los casos de audio más difíciles. / Choisissez celui-ci pour les autres langues ou les enregistrements les plus difficiles. |
| Description source | catalog key `Pick this for other languages or the toughest audio.` |
| Destination | `dictation` › `engine` |
| Dictionary tab | none |
| Shown when | `engineChoicesExpanded` |
| Arrival target | [`transcriptionEngine`](#node-transcriptionEngine) |
| Fallbacks, in order | [`transcriptionEngine`](#node-transcriptionEngine) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Whisper, Turbo, GPU, WhisperKit<br>phrases: use Whisper for dictation; choose the dictation model for difficult audio; I need to dictate in a language outside Europe |
| Search (de) | words: Whisper, Turbo, GPU, WhisperKit<br>phrases: nimm Whisper fürs Diktieren; wähle das Diktiermodell für schwierige Aufnahmen; ich möchte in einer außereuropäischen Sprache diktieren |
| Search (es) | words: Whisper dictado, Turbo dictado, GPU dictado, WhisperKit<br>phrases: usar Whisper para dictar; elegir el modelo de dictado para audio difícil o idiomas de fuera de Europa |
| Search (fr) | words: Whisper dictée, Turbo dictée, GPU dictée, WhisperKit<br>phrases: utiliser Whisper pour mes dictées; choisir le modèle de dictée pour un son difficile à comprendre |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select English for the punctuation start word; show the English punctuation trigger |
| Search (de) | phrases: wähle Englisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für englische Satzzeichen |
| Search (es) | words: activador inglés, prefijo inglés<br>phrases: ver la palabra de activación de puntuación en inglés |
| Search (fr) | words: déclencheur anglais, préfixe anglais<br>phrases: afficher le mot déclencheur de ponctuation pour l’anglais |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select German for the punctuation start word; show the German punctuation trigger |
| Search (de) | phrases: wähle Deutsch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für deutsche Satzzeichen |
| Search (es) | words: activador alemán, prefijo alemán<br>phrases: ver la palabra de activación de puntuación en alemán |
| Search (fr) | words: déclencheur allemand, préfixe allemand<br>phrases: afficher le mot déclencheur de ponctuation pour l’allemand |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select French for the punctuation start word; show the French punctuation trigger |
| Search (de) | phrases: wähle Französisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für französische Satzzeichen |
| Search (es) | words: activador francés, prefijo francés<br>phrases: ver la palabra de activación de puntuación en francés |
| Search (fr) | words: déclencheur français, préfixe français<br>phrases: afficher le mot déclencheur de ponctuation pour le français |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select Spanish for the punctuation start word; show the Spanish punctuation trigger |
| Search (de) | phrases: wähle Spanisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für spanische Satzzeichen |
| Search (es) | words: activador español, prefijo español<br>phrases: ver la palabra de activación de puntuación en español |
| Search (fr) | words: déclencheur espagnol, préfixe espagnol<br>phrases: afficher le mot déclencheur de ponctuation pour l’espagnol |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
| Arrival target | [`spokenPunctuation`](#node-spokenPunctuation) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: select Italian for the punctuation start word; show the Italian punctuation trigger |
| Search (de) | phrases: wähle Italienisch für das Startwort vor Satzzeichen; zeig mir das Auslösewort für italienische Satzzeichen |
| Search (es) | words: activador italiano, prefijo italiano<br>phrases: ver la palabra de activación de puntuación en italiano |
| Search (fr) | words: déclencheur italien, préfixe italien<br>phrases: afficher le mot déclencheur de ponctuation pour l’italien |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWords-apple"></a>

### Apple (`meetingLiveWords.apple`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingLiveWords`](#node-meetingLiveWords) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingLiveWords`](#node-meetingLiveWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple for live meeting transcription |
| Search (de) | words: Apple<br>phrases: verwende Apple für die Live-Vorschau im Meeting |
| Search (es) | phrases: usar Apple para transcribir la reunión en directo |
| Search (fr) | phrases: utiliser Apple pour transcrire la réunion en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingLiveWords-universal"></a>

### Universal / Universal / Universal / Universal (`meetingLiveWords.universal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingLiveWords`](#node-meetingLiveWords) |
| Title source | catalog key `Universal` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingLiveWords`](#node-meetingLiveWords) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Universal for live meeting transcription |
| Search (de) | words: Universal<br>phrases: nutze Universal für die Live-Vorschau im Meeting |
| Search (es) | phrases: usar Universal para la transcripción en directo de la reunión |
| Search (fr) | phrases: choisir Universal pour la transcription en direct de la réunion |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine-parakeet"></a>

### Parakeet / Parakeet / Parakeet / Parakeet (`meetingTranscriptEngine.parakeet`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Title source | catalog key `Parakeet` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Parakeet for meeting transcripts |
| Search (de) | phrases: Parakeet für das Transkript nach dem Meeting nutzen |
| Search (es) | phrases: usar Parakeet para transcribir reuniones |
| Search (fr) | phrases: utiliser Parakeet pour transcrire les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine-whisper"></a>

### Whisper Large v3 Turbo / Whisper Large v3 Turbo / Whisper Large v3 Turbo / Whisper Large v3 Turbo (`meetingTranscriptEngine.whisper`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Title source | catalog key `Whisper Large v3 Turbo` |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Whisper for meeting transcripts |
| Search (de) | phrases: Whisper für das Transkript nach dem Meeting nutzen |
| Search (es) | phrases: usar Whisper para transcribir reuniones |
| Search (fr) | phrases: utiliser Whisper pour transcrire les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingTranscriptEngine-apple"></a>

### Apple (`meetingTranscriptEngine.apple`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `models` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingTranscriptEngine`](#node-meetingTranscriptEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: Apple engine for full meeting transcripts coming soon |
| Search (de) | phrases: wann kann ich Apple für das Transkript nutzen; Apple Spracherkennung für Meeting-Transkripte |
| Search (es) | phrases: Apple para la transcripción completa de reuniones en EnviousMeet (próximamente) |
| Search (fr) | phrases: moteur Apple bientôt disponible pour la transcription complète des réunions dans EnviousMeet |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-egOne"></a>

### EG-1 (`meetingSummaryEngine.egOne`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use EG-1 for meeting summaries |
| Search (de) | phrases: EG-1 für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar EG-1 para resumir reuniones |
| Search (fr) | phrases: utiliser EG-1 pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-appleIntelligence"></a>

### Apple Intelligence (`meetingSummaryEngine.appleIntelligence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple Intelligence for meeting summaries |
| Search (de) | phrases: Apple Intelligence für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar Apple Intelligence para resumir reuniones |
| Search (fr) | phrases: utiliser Apple Intelligence pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-ollama"></a>

### Ollama (`meetingSummaryEngine.ollama`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Ollama for meeting summaries |
| Search (de) | phrases: Ollama für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar Ollama para resumir reuniones |
| Search (fr) | phrases: utiliser Ollama pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-openAI"></a>

### OpenAI (`meetingSummaryEngine.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use OpenAI for meeting summaries |
| Search (de) | phrases: OpenAI für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar OpenAI para resumir reuniones |
| Search (fr) | phrases: utiliser OpenAI pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-gemini"></a>

### Google Gemini (`meetingSummaryEngine.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Google Gemini for meeting summaries |
| Search (de) | phrases: Google Gemini für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar Google Gemini para resumir reuniones |
| Search (fr) | phrases: utiliser Google Gemini pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-meetingSummaryEngine-claude"></a>

### Claude (`meetingSummaryEngine.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Title source | product name |
| Description | none |
| Destination | `meetings` › `summaries` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`meetingSummaryEngine`](#node-meetingSummaryEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Claude for meeting summaries |
| Search (de) | phrases: Claude für Meetingzusammenfassungen auswählen |
| Search (es) | phrases: usar Claude para resumir reuniones |
| Search (fr) | phrases: utiliser Claude pour résumer les réunions |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-never"></a>

### Never / Nie / Nunca / Jamais (`unloadModel.never`)

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
| Search (es) | words: modelo siempre cargado, no liberar modelo<br>phrases: mantener el modelo de dictado siempre en memoria |
| Search (fr) | words: modèle toujours chargé, mémoire permanente<br>phrases: garder le modèle de dictée en mémoire tout le temps |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-immediately"></a>

### Immediately / Sofort / Inmediatamente / Immédiatement (`unloadModel.immediately`)

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
| Search (es) | words: liberación inmediata, modelo fuera al terminar<br>phrases: liberar la memoria del modelo después de cada dictado |
| Search (fr) | words: déchargement immédiat, mémoire après dictée<br>phrases: libérer la mémoire du modèle après chaque transcription |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-twoMinutes"></a>

### After 2 minutes / Nach 2 Minuten / Después de 2 minutos / Après 2 minutes (`unloadModel.twoMinutes`)

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
| Search (es) | words: 2 minutos, dos minutos<br>phrases: liberar el modelo tras dos minutos sin dictar |
| Search (fr) | words: mémoire 2 minutes, modèle deux minutes<br>phrases: libérer le modèle après deux minutes sans dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-fiveMinutes"></a>

### After 5 minutes / Nach 5 Minuten / Después de 5 minutos / Après 5 minutes (`unloadModel.fiveMinutes`)

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
| Search (es) | words: 5 minutos, cinco minutos<br>phrases: liberar el modelo tras cinco minutos sin dictar |
| Search (fr) | words: mémoire 5 minutes, modèle cinq minutes<br>phrases: libérer le modèle après cinq minutes sans dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-tenMinutes"></a>

### After 10 minutes / Nach 10 Minuten / Después de 10 minutos / Après 10 minutes (`unloadModel.tenMinutes`)

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
| Search (es) | words: 10 minutos, diez minutos<br>phrases: liberar el modelo tras diez minutos sin dictar |
| Search (fr) | words: mémoire 10 minutes, modèle dix minutes<br>phrases: libérer le modèle après dix minutes sans dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-fifteenMinutes"></a>

### After 15 minutes / Nach 15 Minuten / Después de 15 minutos / Après 15 minutes (`unloadModel.fifteenMinutes`)

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
| Search (es) | words: 15 minutos, quince minutos, cuarto de hora<br>phrases: liberar el modelo tras un cuarto de hora sin dictar |
| Search (fr) | words: mémoire 15 minutes, modèle quart d’heure<br>phrases: libérer le modèle après un quart d’heure sans dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadModel-oneHour"></a>

### After 1 hour / Nach 1 Stunde / Después de 1 hora / Après 1 heure (`unloadModel.oneHour`)

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
| Search (es) | words: 1 hora, una hora, 60 minutos<br>phrases: liberar el modelo tras una hora sin dictar |
| Search (fr) | words: mémoire 1 heure, modèle 60 minutes<br>phrases: libérer le modèle après une heure sans dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-never"></a>

### Never / Nie / Nunca / Jamais (`unloadPolishModel.never`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `Never` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: always loaded, keep in memory, stay in ram<br>phrases: keep the polish model loaded when i'm not dictating; don't unload the polish model after dictation |
| Search (de) | words: Nachbearbeitungsmodell nie entladen, AI Polish dauerhaft geladen<br>phrases: das Nachbearbeitungsmodell auch in Diktierpausen im Arbeitsspeicher behalten; das Modell für die KI-Nachbearbeitung dauerhaft geladen lassen |
| Search (es) | words: modelo de corrección siempre cargado<br>phrases: mantener el modelo de corrección en memoria aunque no esté dictando |
| Search (fr) | words: jamais, modèle de correction toujours en mémoire, ne jamais décharger le modèle de correction<br>phrases: garder le modèle de correction de texte en mémoire même quand je ne dicte pas |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-immediately"></a>

### Immediately / Sofort / Inmediatamente / Immédiatement (`unloadPolishModel.immediately`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `Immediately` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 10 seconds, 10 sec<br>phrases: unload the polish model after about 10 seconds of inactivity; free up memory used by AI Polish about 10 seconds after i stop dictating |
| Search (de) | words: AI Polish ca. 10 Sek., Nachbearbeitungsmodell kurz nach Gebrauch entladen<br>phrases: das Nachbearbeitungsmodell etwa 10 Sekunden nach der letzten Nutzung entladen; den Arbeitsspeicher des Modells für die KI-Nachbearbeitung nach rund zehn Sekunden Leerlauf freigeben |
| Search (es) | words: enseguida, unos 10 segundos, modelo de corrección tras 10 segundos<br>phrases: liberar la memoria del modelo de corrección unos 10 segundos después de dejar de dictar |
| Search (fr) | words: 10 secondes, correction de texte 10 s, déchargement rapide du modèle de correction<br>phrases: libérer la mémoire du modèle de correction de texte environ 10 secondes après sa dernière utilisation |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-twoMinutes"></a>

### After 2 minutes / Nach 2 Minuten / Después de 2 minutos / Après 2 minutes (`unloadPolishModel.twoMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `After 2 minutes` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 2 min, two minutes, 120 seconds<br>phrases: unload the polish model after 2 minutes without dictating; free up memory used by AI Polish after 2 minutes of inactivity |
| Search (de) | words: AI Polish 2 Min., KI-Nachbearbeitung zwei Minuten<br>phrases: das Nachbearbeitungsmodell nach 2 Minuten Leerlauf entladen |
| Search (es) | words: 2 min, modelo de corrección tras dos minutos<br>phrases: liberar la memoria del modelo de corrección tras 2 minutos sin dictar |
| Search (fr) | words: 2 min, correction de texte 2 minutes, modèle de correction deux minutes<br>phrases: libérer la mémoire du modèle de correction de texte après 2 minutes d’inactivité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-fiveMinutes"></a>

### After 5 minutes / Nach 5 Minuten / Después de 5 minutos / Après 5 minutes (`unloadPolishModel.fiveMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `After 5 minutes` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 5 min, five minutes<br>phrases: unload the polish model after 5 minutes of inactivity; free up the polish model’s memory after 5 minutes without dictating |
| Search (de) | words: AI Polish 5 Min., KI-Nachbearbeitung fünf Minuten<br>phrases: das Nachbearbeitungsmodell nach 5 Minuten Leerlauf entladen; den Arbeitsspeicher des Modells für die KI-Nachbearbeitung fünf Minuten nach der letzten Nutzung freigeben |
| Search (es) | words: 5 min, modelo de corrección tras cinco minutos<br>phrases: liberar la memoria del modelo de corrección tras 5 minutos sin dictar |
| Search (fr) | words: 5 min, correction de texte 5 minutes, modèle de correction cinq minutes<br>phrases: libérer la mémoire du modèle de correction de texte après 5 minutes d’inactivité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-tenMinutes"></a>

### After 10 minutes / Nach 10 Minuten / Después de 10 minutos / Après 10 minutes (`unloadPolishModel.tenMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `After 10 minutes` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 10 min, ten minutes<br>phrases: unload the polish model after 10 minutes of inactivity; free up polish model memory after 10 minutes without dictating |
| Search (de) | words: AI Polish 10 Min., KI-Nachbearbeitung zehn Minuten<br>phrases: das Nachbearbeitungsmodell nach 10 Minuten Leerlauf entladen |
| Search (es) | words: 10 min, modelo de corrección tras diez minutos<br>phrases: liberar la memoria del modelo de corrección tras 10 minutos sin dictar |
| Search (fr) | words: 10 min, correction de texte 10 minutes, modèle de correction dix minutes<br>phrases: libérer la mémoire du modèle de correction de texte après 10 minutes d’inactivité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-fifteenMinutes"></a>

### After 15 minutes / Nach 15 Minuten / Después de 15 minutos / Après 15 minutes (`unloadPolishModel.fifteenMinutes`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `After 15 minutes` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 15 min<br>phrases: unload the polish model after 15 min without dictating; keep the polish model loaded for a quarter of an hour after dictation |
| Search (de) | words: AI Polish 15 Min., Nachbearbeitungsmodell Viertelstunde<br>phrases: das Nachbearbeitungsmodell nach 15 Minuten Leerlauf entladen; das Modell für die KI-Nachbearbeitung nach einer Viertelstunde ohne Nutzung entladen |
| Search (es) | words: 15 min, corrección de texto tras un cuarto de hora<br>phrases: liberar la memoria del modelo de corrección tras 15 minutos sin dictar |
| Search (fr) | words: 15 min, correction de texte 15 minutes, modèle de correction quart d’heure<br>phrases: libérer la mémoire du modèle de correction de texte après un quart d’heure d’inactivité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-unloadPolishModel-oneHour"></a>

### After 1 hour / Nach 1 Stunde / Después de 1 hora / Après 1 heure (`unloadPolishModel.oneHour`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`unloadPolishModel`](#node-unloadPolishModel) |
| Title source | catalog key `After 1 hour` |
| Description | none |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `providerSelected` |
| Arrival target | [`unloadPolishModel`](#node-unloadPolishModel) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 60 minutes, 1 hr<br>phrases: free up polish model memory after an hour without dictating; keep the polish model in memory for an hour after dictation |
| Search (de) | words: AI Polish 1 Std., KI-Nachbearbeitung 60 Minuten<br>phrases: das Nachbearbeitungsmodell nach einer Stunde Leerlauf entladen; den Arbeitsspeicher des Modells für die KI-Nachbearbeitung nach 60 Minuten ohne Nutzung freigeben |
| Search (es) | words: 1 h, modelo de corrección tras 60 minutos<br>phrases: liberar la memoria del modelo de corrección tras una hora sin dictar |
| Search (fr) | words: 1 h, correction de texte 1 heure, modèle de correction 60 minutes<br>phrases: libérer la mémoire du modèle de correction de texte après une heure d’inactivité |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-continue"></a>

### Continue / Weiterlaufen lassen / No pausar / Continuer la lecture (`mediaDuringDictation.continue`)

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
| Search (es) | words: sin interrupciones, volumen sin cambios, Seguir reproduciendo<br>phrases: dejar la música sonando al mismo volumen mientras dicto |
| Search (fr) | words: lecture continue, musique inchangée<br>phrases: laisser ma musique jouer au même volume pendant la dictée |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-lower"></a>

### Lower / Leiser / Bajar / Baisser (`mediaDuringDictation.lower`)

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
| Search (es) | words: bajar volumen, media potencia, ducking<br>phrases: bajar el volumen a la mitad mientras grabo y restaurarlo al terminar |
| Search (fr) | words: volume réduit, demi-volume, ducking<br>phrases: baisser le volume pendant la dictée puis le rétablir |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-mute"></a>

### Mute / Stummschalten / Silenciar / Couper le son (`mediaDuringDictation.mute`)

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
| Search (es) | words: mute, sin sonido<br>phrases: silenciar los altavoces o auriculares mientras dicto y recuperar el volumen al terminar |
| Search (fr) | words: son coupé, muet, mute<br>phrases: couper le son des haut-parleurs ou du casque pendant la dictée puis le rétablir |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-mediaDuringDictation-pause"></a>

### Pause / Pausieren / Pausar / Mettre en pause (`mediaDuringDictation.pause`)

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
| Search (es) | words: pausar música, pausar vídeo, pausar podcast<br>phrases: pausar lo que se está reproduciendo mientras dicto y reanudarlo al terminar |
| Search (fr) | words: musique en pause, podcast en pause, vidéo en pause<br>phrases: mettre la lecture en pause pendant la dictée puis la reprendre |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-off"></a>

### Off / Aus / Desactivado / Désactivé (`micReadiness.off`)

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
| Search (es) | words: sin espera del micro, liberar micro<br>phrases: liberar el micrófono en cuanto termine la grabación |
| Search (fr) | words: micro libéré, maintien désactivé<br>phrases: libérer le microphone dès la fin de l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-10s"></a>

### 10 sec / 10 Sek. / 10 s / 10 s (`micReadiness.10s`)

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
| Search (es) | words: diez segundos, 10s<br>phrases: mantener el micrófono listo durante diez segundos después de grabar |
| Search (fr) | words: micro 10 secondes, micro dix secondes<br>phrases: garder le micro prêt dix secondes après l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-30s"></a>

### 30 sec / 30 Sek. / 30 s / 30 s (`micReadiness.30s`)

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
| Search (es) | words: medio minuto, 30s, 30 segundos<br>phrases: mantener el micrófono listo durante medio minuto después de grabar |
| Search (fr) | words: micro 30 secondes, micro demi-minute<br>phrases: garder le micro prêt trente secondes après l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-60s"></a>

### 60 sec / 60 Sek. / 60 s / 60 s (`micReadiness.60s`)

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
| Search (es) | words: un minuto, 60s, 60 segundos<br>phrases: mantener el micrófono listo durante un minuto después de grabar |
| Search (fr) | words: micro 60 secondes, micro une minute<br>phrases: garder le micro prêt une minute après l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-micReadiness-always"></a>

### Always / Immer / Siempre / Toujours (`micReadiness.always`)

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
| Search (es) | words: micro siempre listo, micro siempre activo<br>phrases: mantener el micrófono listo todo el tiempo; por qué puede quedarse encendido el indicador del micro con Siempre seleccionado |
| Search (fr) | words: micro toujours actif, micro permanent, voyant micro permanent<br>phrases: garder le micro prêt en permanence entre les enregistrements; pourquoi le voyant du micro peut rester allumé avec l’option Toujours |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-apple"></a>

### Apple (`previewEngine.apple`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | product name |
| Description | Uses Apple's speech recognition. No separate preview-model download; some languages may need an Apple language download. Needs macOS 26. / Verwendet Apples Spracherkennung. Für die Vorschau ist kein eigenes Modell nötig. Manche Sprachen müssen möglicherweise von Apple heruntergeladen werden. Benötigt macOS 26. / Usa el reconocimiento de voz de Apple. No tienes que descargar un modelo de vista previa aparte, aunque algunos idiomas pueden requerir un paquete de idioma de Apple. Requiere macOS 26. / Utilise la reconnaissance vocale d’Apple. Aucun téléchargement distinct de modèle pour l’aperçu en direct n’est nécessaire. Certaines langues peuvent nécessiter le téléchargement d’une langue Apple. Nécessite macOS 26. |
| Description source | catalog key `Uses Apple's speech recognition. No separate preview-model download; some languages may need an Apple language download. Needs macOS 26.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewChoicesExpanded` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple's speech recognition for live preview; choose the preview engine that needs macOS 26; use the preview engine without a separate preview model download |
| Search (de) | phrases: nimm Apples Spracherkennung für die Live-Vorschau; wähle die Vorschau-Engine, die macOS 26 braucht; nimm die Vorschau ohne separaten Download eines Vorschaumodells |
| Search (es) | words: Apple vista previa, reconocimiento de Apple<br>phrases: usar el reconocimiento de Apple para la vista previa; elegir el motor de vista previa que requiere macOS 26 y no necesita un modelo aparte |
| Search (fr) | words: aperçu Apple, reconnaissance Apple, aperçu macOS 26<br>phrases: utiliser la reconnaissance vocale Apple pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-previewEngine-universal"></a>

### Universal / Universal / Universal / Universal (`previewEngine.universal`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`previewEngine`](#node-previewEngine) |
| Title source | catalog key `Universal` |
| Description | Works on macOS 14 and later, in more languages. Needs one optional 270 MB download. / Funktioniert ab macOS 14 und unterstützt mehr Sprachen. Ein optionaler Download von 270 MB ist nötig. / Funciona en macOS 14 y versiones posteriores, con más idiomas. Necesita una descarga opcional de 270 MB. / Fonctionne sous macOS 14 et versions ultérieures, dans davantage de langues. Un téléchargement facultatif de 270 Mo est nécessaire. |
| Description source | catalog key `Works on macOS 14 and later, in more languages. Needs one optional 270 MB download.` |
| Destination | `dictation` › `livePreview` |
| Dictionary tab | none |
| Shown when | `previewChoicesExpanded` |
| Arrival target | [`previewEngine`](#node-previewEngine) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: 270MB<br>phrases: choose Universal for the live preview; use the preview engine that works on macOS 14; choose the preview engine with more languages |
| Search (de) | words: 270MB<br>phrases: nimm Universal für die Live-Vorschau; wähle die Vorschau-Engine, die auf macOS 14 läuft; nimm die Vorschau-Engine mit mehr Sprachen |
| Search (es) | words: Universal vista previa, 270 MB, vista previa macOS 14<br>phrases: usar Universal para ver las palabras mientras hablo; elegir el motor de vista previa compatible con macOS 14 y con más idiomas |
| Search (fr) | words: aperçu Universal, 270 Mo, aperçu macOS 14<br>phrases: utiliser Universal pour l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition-top"></a>

### Top / Oben / Arriba / En haut (`pillPosition.top`)

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
| Search (es) | words: borde superior<br>phrases: poner el indicador de grabación arriba de la pantalla |
| Search (fr) | words: bord supérieur<br>phrases: mettre l’indicateur d’enregistrement en haut de l’écran |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillPosition-bottom"></a>

### Bottom / Unten / Abajo / En bas (`pillPosition.bottom`)

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
| Search (es) | words: borde inferior<br>phrases: poner el indicador de grabación abajo de la pantalla |
| Search (fr) | words: bord inférieur<br>phrases: mettre l’indicateur d’enregistrement en bas de l’écran |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-capsule"></a>

### Capsule / Kapsel / Cápsula / Capsule (`pillStyle.capsule`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Capsule` |
| Description | A compact pill with a dot and level meter. / Eine kompakte Kapsel mit Punkt und Pegelbalken. / Una píldora compacta con un punto y un medidor de nivel. / Une pastille compacte avec un point et un indicateur de niveau. |
| Description source | catalog key `A compact pill with a dot and level meter.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: dot, compact<br>phrases: use the small recording pill with a dot and level meter; choose the compact dot and meter recording indicator |
| Search (de) | words: Aufnahmepunkt, kompakt<br>phrases: nimm die kleine Aufnahmeanzeige mit Punkt und Pegel; wähle die kompakte Anzeige mit Punkt und Lautstärkemesser |
| Search (es) | words: punto y medidor, indicador compacto, Cápsula<br>phrases: usar el indicador pequeño con un punto y un medidor de nivel |
| Search (fr) | words: point et jauge, indicateur compact<br>phrases: utiliser le petit indicateur avec un point et une jauge de volume |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-levelRail"></a>

### Level Rail / Pegelanzeige / Barra de nivel / Barre de niveau (`pillStyle.levelRail`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Level Rail` |
| Description | A slim rail that follows your volume. / Eine schmale Leiste, die sich deiner Lautstärke anpasst. / Una barra fina que responde al volumen de tu voz. / Une barre fine qui suit votre volume. |
| Description source | catalog key `A slim rail that follows your volume.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: bar, strip, rail, slim<br>phrases: use a thin recording bar that follows my voice volume; choose the slim level rail as the recording indicator |
| Search (de) | words: Balken, Leiste, Streifen, schmal<br>phrases: nimm einen schmalen Aufnahmebalken, der meiner Lautstärke folgt; wähle die dünne Pegelleiste als Aufnahmeanzeige |
| Search (es) | words: barra fina, barra de volumen<br>phrases: usar una barra fina que siga el volumen de mi voz |
| Search (fr) | words: barre fine, barre de volume<br>phrases: utiliser une barre fine qui suit le volume de ma voix |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-pillStyle-readingWell"></a>

### Reading Well / Lesefeld / Panel de lectura / Zone de lecture (`pillStyle.readingWell`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`pillStyle`](#node-pillStyle) |
| Title source | catalog key `Reading Well` |
| Description | Shows words as you speak. Turns Live Preview on. / Zeigt Wörter beim Sprechen. Schaltet die Live-Vorschau ein. / Muestra las palabras mientras hablas. Activa la Vista previa en tiempo real. / Affiche les mots pendant que vous parlez. Active l’Aperçu en direct. |
| Description source | catalog key `Shows words as you speak. Turns Live Preview on.` |
| Destination | `dictation` › `pill` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`pillStyle`](#node-pillStyle) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: panel<br>phrases: choose the recording pill style that displays my words; use a floating text panel as the recording indicator; choose the Reading Well style and turn on Live Preview |
| Search (de) | words: Textfeld<br>phrases: wähle den Stil der Aufnahmeanzeige, der meine Wörter zeigt; nimm ein schwebendes Textfeld als Aufnahmeanzeige; wähle das Lesefeld und schalte damit die Live-Vorschau ein |
| Search (es) | words: panel flotante, Reading Well, Panel de texto<br>phrases: usar el indicador con un panel de palabras y activar la vista previa |
| Search (fr) | words: texte flottant<br>phrases: choisir le style d’indicateur qui affiche mes mots et active l’aperçu en direct |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-dustMote"></a>

### Dust Mote / Staubflöckchen / Mota de polvo / Grain de poussière (`recordingChime.dustMote`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Dust Mote` |
| Description | Soft filtered air, no tone. / Leises, gefiltertes Rauschen ohne Tonhöhe. / Aire filtrado suave, sin tono. / Un souffle doux filtré, sans tonalité. |
| Description source | catalog key `Soft filtered air, no tone.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: toneless, pitchless, air<br>phrases: choose the filtered air sound with no tone; use the soft recording sound without a musical pitch |
| Search (de) | words: Luftrauschen, Luftgeräusch<br>phrases: nimm das sanfte Luftrauschen ohne Tonhöhe; wähle das gefilterte Luftgeräusch ohne erkennbare Tonhöhe |
| Search (es) | words: Dust Mote, sin tono, sin nota<br>phrases: elegir el sonido de aire suave sin tono musical |
| Search (fr) | words: sans note, sans tonalité<br>phrases: choisir le léger bruit d’air filtré sans note musicale |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-velvetHush"></a>

### Velvet Hush / Samtflüstern / Susurro aterciopelado / Murmure velouté (`recordingChime.velvetHush`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Velvet Hush` |
| Description | Two close tones, gentle warmth. / Zwei eng beieinanderliegende Töne, sanft und warm. / Dos tonos cercanos, cálidos y suaves. / Deux tonalités proches, une douce chaleur. |
| Description source | catalog key `Two close tones, gentle warmth.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose the warm chime with two closely pitched tones; use the gentle pair of tones with similar pitches |
| Search (de) | phrases: nimm den warmen Klang mit zwei ähnlichen Tonhöhen; wähle das sanfte Tonpaar mit dicht beieinanderliegenden Tönen |
| Search (es) | words: Velvet Hush, tonos cercanos, Susurro de terciopelo<br>phrases: elegir el sonido cálido con dos tonos muy parecidos |
| Search (fr) | words: notes proches, duo chaleureux<br>phrases: choisir le son chaleureux avec deux notes proches |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-mutedConfirm"></a>

### Muted Confirm / Leises Okay / Confirmación suave / Confirmation discrète (`recordingChime.mutedConfirm`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Muted Confirm` |
| Description | Same pitch both ways, plain. / Gleiche Tonhöhe beim Starten und Stoppen, ganz schlicht. / Mismo tono al iniciar y detener, sin adornos. / Même note au début et à la fin, sans fioritures. |
| Description source | catalog key `Same pitch both ways, plain.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: plain, matching<br>phrases: use the same chime pitch for recording start and stop; choose the plain sound with matching pitches both ways |
| Search (de) | words: schlicht, gleich<br>phrases: nimm beim Aufnahmestart und Aufnahmeende dieselbe Tonhöhe; wähle den schlichten Ton, der beim Starten und Stoppen gleich klingt |
| Search (es) | words: Muted Confirm, tonos iguales, Confirmación discreta<br>phrases: usar el mismo tono al empezar y terminar de grabar |
| Search (fr) | words: notes identiques, tonalité identique<br>phrases: utiliser la même note au début et à la fin de l’enregistrement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-whisperTick"></a>

### Whisper Tick / Flüstertick / Tic de Whisper / Tic Whisper (`recordingChime.whisperTick`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Whisper Tick` |
| Description | Barely-there tick. / Ein kaum hörbares Ticken. / Un tic apenas perceptible. / Un tic à peine audible. |
| Description source | catalog key `Barely-there tick.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: tick, ticking, faint<br>phrases: choose the recording tick that is barely audible; use the very faint ticking sound |
| Search (de) | words: Ticken, Tick, Tickgeräusch<br>phrases: nimm das Ticken, das kaum zu hören ist; wähle das ganz leise Tickgeräusch |
| Search (es) | words: Whisper Tick, tic, casi inaudible, Tic tenue<br>phrases: elegir el tic que apenas se oye |
| Search (fr) | words: tic, presque inaudible<br>phrases: choisir le petit tic à peine audible |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-roundPebble"></a>

### Round Pebble / Runder Kiesel / Piedra redonda / Galet rond (`recordingChime.roundPebble`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Round Pebble` |
| Description | Rounded, no edge. / Rund und weich. / Redondo y suave. / Un son rond, sans aspérité. |
| Description source | catalog key `Rounded, no edge.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: rounded, round, edgeless<br>phrases: choose the rounded recording sound without a sharp edge; use the chime described as rounded with no edge |
| Search (de) | words: rund, abgerundet<br>phrases: nimm den rund klingenden Aufnahmeton ohne scharfe Kante; wähle den Klang, der als abgerundet beschrieben wird |
| Search (es) | words: Round Pebble, redondeado, sin aristas<br>phrases: elegir el sonido redondeado sin bordes bruscos |
| Search (fr) | words: son rond, son arrondi<br>phrases: choisir le son rond sans côté tranchant |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-paperTap"></a>

### Paper Tap / Papierklopfen / Golpecito de papel / Tapotement de papier (`recordingChime.paperTap`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Paper Tap` |
| Description | Soft paper-like tap. / Ein leises Klopfen wie auf Papier. / Golpecito suave, como un toque sobre papel. / Un léger tapotement évoquant le papier. |
| Description source | catalog key `Soft paper-like tap.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: papery, paper<br>phrases: choose the recording sound like a soft tap on paper; use the gentle paper-like tapping sound |
| Search (de) | words: Papier, Papiergeräusch<br>phrases: nimm den Aufnahmeton, der wie sanftes Tippen auf Papier klingt; wähle das leise papierartige Klopfgeräusch |
| Search (es) | words: Paper Tap, papel<br>phrases: elegir el sonido de un golpecito suave sobre papel |
| Search (fr) | words: papier, tapotement papier<br>phrases: choisir le son d’un léger tapotement sur du papier |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-softHush"></a>

### Soft Hush / Sanftes Säuseln / Susurro suave / Doux murmure (`recordingChime.softHush`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Soft Hush` |
| Description | Slow fade, like a breath. / Ein langsames Verklingen wie ein Atemzug. / Desvanecimiento lento, como una respiración. / Fondu lent, comme un souffle. |
| Description source | catalog key `Slow fade, like a breath.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: breath, breathy, fade, exhale<br>phrases: choose the breath-like recording sound that fades slowly; use the chime that sounds like a slowly fading breath |
| Search (de) | words: Atem, Atemzug, Ausatmen, ausklingen<br>phrases: nimm den Klang, der wie ein Atemzug langsam ausklingt; wähle das langsam verklingende Atemgeräusch |
| Search (es) | words: Soft Hush, respiración, suspiro, desvanecimiento lento<br>phrases: usar el sonido como una respiración que se desvanece despacio |
| Search (fr) | words: expiration, fondu lent<br>phrases: choisir le son qui ressemble à un souffle et disparaît lentement |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-lowNod"></a>

### Low Nod / Tiefes Nicken / Asentimiento grave / Hochement grave (`recordingChime.lowNod`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Low Nod` |
| Description | Low, warm, unhurried. / Tief, warm und gemächlich. / Grave, cálido y pausado. / Grave, chaleureux et posé. |
| Description source | catalog key `Low, warm, unhurried.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: deep, low, unhurried<br>phrases: choose the low warm recording sound; use the deep chime with an unhurried feel |
| Search (de) | words: tief, dunkel, gemächlich<br>phrases: nimm den tiefen warmen Aufnahmeton; wähle den dunklen Klang, der ruhig und gemächlich klingt |
| Search (es) | words: Low Nod, grave, pausado<br>phrases: elegir el sonido grave y cálido que suena pausado |
| Search (fr) | words: son grave, note basse<br>phrases: choisir le son grave et chaleureux qui prend son temps |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-cloudPop"></a>

### Cloud Pop / Wolkenplopp / Plof de nube / Ploc nuageux (`recordingChime.cloudPop`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Cloud Pop` |
| Description | Tiny filtered-air pop. / Ein leises Ploppen wie ein Luftstoß durch einen Filter. / Pequeño estallido de aire filtrado. / Petit claquement d’air filtré. |
| Description source | catalog key `Tiny filtered-air pop.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: pop, popping<br>phrases: choose the tiny filtered air pop; use the little airy popping recording sound |
| Search (de) | words: Plopp, ploppen, Luftplopp<br>phrases: nimm den kleinen gefilterten Luftplopp; wähle das kurze luftige Ploppgeräusch |
| Search (es) | words: Cloud Pop, pop, estallido<br>phrases: elegir el pequeño pop de aire filtrado |
| Search (fr) | words: pop, petit pop<br>phrases: choisir le petit pop d’air filtré |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-velvetTap"></a>

### Velvet Tap / Samttipp / Toque aterciopelado / Tapotement velouté (`recordingChime.velvetTap`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Velvet Tap` |
| Description | Muted, compact tap. / Ein leises, kurzes Klopfen. / Un toque suave y breve. / Un tapotement discret et bref. |
| Description source | catalog key `Muted, compact tap.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: muted, damped<br>phrases: choose the compact muted tapping sound; use the short damped tap as my recording chime |
| Search (de) | words: gedämpft<br>phrases: nimm das kurze gedämpfte Tippgeräusch; wähle den kompakten gedämpften Klopfton |
| Search (es) | words: Velvet Tap, golpe amortiguado, Golpecito de terciopelo<br>phrases: usar el golpecito corto y amortiguado |
| Search (fr) | words: coup étouffé<br>phrases: choisir le tapotement court et étouffé |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-satinShift"></a>

### Satin Shift / Satin-Schimmer / Brillo satinado / Éclat satiné (`recordingChime.satinShift`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Satin Shift` |
| Description | Smooth two-tone shift. / Ein sanfter Wechsel zwischen zwei Tönen. / Transición suave entre dos tonos. / Transition douce entre deux tons. |
| Description source | catalog key `Smooth two-tone shift.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: transition, shift<br>phrases: choose the recording sound with a smooth two-tone shift; use the chime with a smooth change between two tones |
| Search (de) | words: Tonwechsel, Tonübergang<br>phrases: nimm den sanften Wechsel zwischen zwei Tönen; wähle den Aufnahmeton mit dem fließenden Tonübergang |
| Search (es) | words: Satin Shift, cambio de tonos, transición suave, Transición de satén<br>phrases: elegir el sonido que cambia suavemente entre dos tonos |
| Search (fr) | words: glissement sonore, transition de notes<br>phrases: choisir le son qui passe doucement d’une note à l’autre |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingChime-airGlint"></a>

### Air Glint / Luftfunkeln / Destello de aire / Éclat d’air (`recordingChime.airGlint`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`recordingChime`](#node-recordingChime) |
| Title source | catalog key `Air Glint` |
| Description | Clean, airy glint. / Ein klarer, luftiger Klang. / Un tintineo nítido y ligero. / Son clair et aérien. |
| Description source | catalog key `Clean, airy glint.` |
| Destination | `dictation` › `chimes` |
| Dictionary tab | none |
| Shown when | `always` |
| Arrival target | [`recordingChime`](#node-recordingChime) |
| Fallbacks, in order | none |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: airy, shimmer, sparkle<br>phrases: pick the airy chime; use the shimmering sound |
| Search (de) | words: luftig, schimmernd, funkelnd<br>phrases: nimm den luftig klingenden Ton; wähle den schimmernden Klang |
| Search (es) | words: Air Glint, destello, brillo<br>phrases: elegir el sonido limpio de aire con un destello brillante |
| Search (fr) | words: scintillement, son scintillant<br>phrases: choisir le son aérien qui scintille |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode-pushToTalk"></a>

### Push to Talk / Zum Sprechen drücken / Pulsar para hablar / Appuyer pour parler (`recordingMode.pushToTalk`)

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
| Search (es) | words: mantener pulsado, soltar para parar, Push to Talk, doble pulsación, triple pulsación<br>phrases: grabar mientras mantengo la tecla pulsada y parar al soltarla; pulsar dos veces para seguir grabando o tres para cancelar en Push to Talk |
| Search (fr) | words: push to talk, touche maintenue, relâcher, double appui, triple appui<br>phrases: enregistrer tant que je maintiens la touche et arrêter quand je la relâche; en mode maintien appuyer deux fois pour verrouiller ou trois fois pour annuler |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-recordingMode-toggle"></a>

### Toggle / Umschalten / Interruptor / Activer ou désactiver (`recordingMode.toggle`)

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
| Search (es) | words: toggle, pulsaciones separadas, Pulsar para iniciar y detener<br>phrases: pulsar una vez para grabar y otra para parar |
| Search (fr) | words: bascule, toggle, appuis séparés<br>phrases: appuyer une fois pour enregistrer puis une autre fois pour arrêter |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-egOne"></a>

### EG-1 (`aiPolishProvider.egOne`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Our tuned model / Unser angepasstes Modell / Nuestro modelo ajustado / Notre modèle optimisé |
| Description source | catalog key `Our tuned model` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: model size, EG-1 size<br>phrases: use the app's own model to clean up my dictation; choose EG-1 for dictation cleanup on this Mac; EG-1 Micro; EG-1 Mini |
| Search (de) | words: Modellgröße, EG-1-Größe<br>phrases: verbessere meine Diktate mit dem eigenen Modell der App; wähle EG-1 für die Diktatkorrektur auf diesem Mac; EG-1 Micro, am kleinsten und schnellsten; EG-1 Mini, schneller Allrounder |
| Search (es) | words: EG-1 dictado, corrector propio, tamaño del modelo, tamaños de EG-1<br>phrases: usar EG-1 para corregir mi dictado en el Mac; cambiar a EG-1 Micro; cambiar a EG-1 Mini |
| Search (fr) | words: EG-1 dictée, correcteur EnviousWispr, taille du modèle, taille du modèle EG-1<br>phrases: utiliser EG-1 sur mon Mac pour corriger mes dictées; choisir EG-1 Micro; choisir EG-1 Mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-s1Mini"></a>

### S1-mini (`aiPolishProvider.s1Mini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | by Superwhisper / von Superwhisper / de Superwhisper / par Superwhisper |
| Description source | catalog key `by Superwhisper` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | words: Superwhisper, small, compact<br>phrases: use Superwhisper's model to clean up my dictation; pick the small local model suited to English dictation |
| Search (de) | words: Superwhisper, klein, kompakt<br>phrases: verbessere meine Diktate mit dem Modell von Superwhisper; nimm das kleine lokale Modell für englische Diktate |
| Search (es) | words: S1-mini dictado, Superwhisper, corrector pequeño<br>phrases: usar el modelo pequeño de Superwhisper para corregir mi dictado, sobre todo en inglés |
| Search (fr) | words: Superwhisper, petit correcteur, correcteur anglais<br>phrases: utiliser le petit modèle de Superwhisper pour corriger mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-appleIntelligence"></a>

### Apple Intelligence (`aiPolishProvider.appleIntelligence`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Built into macOS / In macOS integriert / Integrado en macOS / Intégrée à macOS |
| Description source | catalog key `Built into macOS` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use Apple's built-in model to clean up my dictation; choose Apple Intelligence for dictation polish |
| Search (de) | phrases: verbessere meine Diktate mit Apples eingebautem Modell; wähle Apple Intelligence für die Diktatkorrektur |
| Search (es) | words: Apple Intelligence dictado, corrección integrada<br>phrases: usar Apple Intelligence para corregir mi dictado |
| Search (fr) | words: Apple Intelligence dictée, correcteur intégré<br>phrases: utiliser Apple Intelligence pour corriger mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-ollama"></a>

### Ollama (`aiPolishProvider.ollama`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your models, local or hosted / Deine Modelle, lokal oder gehostet / Tus modelos, en tu Mac o en un servidor / Vos modèles, locaux ou hébergés |
| Description source | catalog key `Your models, local or hosted` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: use my Ollama models to clean up dictation; choose my own local or hosted Ollama setup for dictation |
| Search (de) | phrases: verbessere meine Diktate mit meinen Ollama-Modellen; nutze für die Diktatkorrektur meine eigene lokale oder gehostete Ollama-Umgebung |
| Search (es) | words: Ollama dictado, Ollama local o alojado<br>phrases: usar mis modelos locales o alojados de Ollama para corregir lo que dicto |
| Search (fr) | words: Ollama dictée, correction Ollama dictée<br>phrases: utiliser mes modèles Ollama locaux ou hébergés pour corriger mes dictées |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-openAI"></a>

### OpenAI (`aiPolishProvider.openAI`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel / Tu clave de API / Votre clé API |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose OpenAI to clean up my dictation; use OpenAI cloud polish for dictated text |
| Search (de) | phrases: wähle OpenAI für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit OpenAI in der Cloud |
| Search (es) | words: OpenAI dictado, OpenAI corrección en nube<br>phrases: elegir OpenAI para corregir mi dictado en la nube |
| Search (fr) | words: OpenAI dictée, correction OpenAI dictée<br>phrases: choisir OpenAI pour corriger mes dictées dans le cloud |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-gemini"></a>

### Google Gemini (`aiPolishProvider.gemini`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel / Tu clave de API / Votre clé API |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose Google's model to clean up my dictation; use Gemini cloud polish for dictated text |
| Search (de) | phrases: wähle Googles Modell für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit Gemini in der Cloud |
| Search (es) | words: Gemini dictado, Google corrección en nube<br>phrases: elegir Gemini para corregir mi dictado en la nube |
| Search (fr) | words: Gemini dictée, correction Google dictée<br>phrases: choisir Gemini pour corriger mes dictées dans le cloud |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-aiPolishProvider-claude"></a>

### Claude (`aiPolishProvider.claude`)

| Field | Value |
|---|---|
| Structure | item |
| Kind | choice |
| Parent | [`aiPolishProvider`](#node-aiPolishProvider) |
| Title source | product name |
| Description | Your API key / Dein API-Schlüssel / Tu clave de API / Votre clé API |
| Description source | catalog key `Your API key` |
| Destination | `aiPolish` |
| Dictionary tab | none |
| Shown when | `aiPolishEnabled` |
| Arrival target | [`aiPolishProvider`](#node-aiPolishProvider) |
| Fallbacks, in order | [`aiPolishProvider`](#node-aiPolishProvider), [`enableAIPolish`](#node-enableAIPolish) |
| Declared in | [Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift](../Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift) |
| Search (en) | phrases: choose Anthropic's model to clean up my dictation; use Claude cloud polish for dictated text |
| Search (de) | phrases: wähle Anthropics Modell für die Nachbearbeitung meiner Diktate; verbessere meinen diktierten Text mit Claude in der Cloud |
| Search (es) | words: Claude dictado, Anthropic corrección en nube<br>phrases: elegir Claude para corregir mi dictado en la nube |
| Search (fr) | words: Claude dictée, correction Anthropic dictée<br>phrases: choisir Claude pour corriger mes dictées dans le cloud |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-casual"></a>

### Casual / Locker / Informal / Décontracté (`s1Tone.casual`)

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
| Search (es) | words: coloquial, estilo de chat<br>phrases: hacer que S1-mini escriba como en una conversación cotidiana |
| Search (fr) | words: familier, informel, conversationnel<br>phrases: faire écrire S1-mini comme dans une conversation de tous les jours |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-semiCasual"></a>

### Semi-casual / Eher locker / Algo informal / Plutôt décontracté (`s1Tone.semiCasual`)

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
| Search (es) | words: semiinformal<br>phrases: usar un tono un poco informal con S1-mini |
| Search (fr) | words: semi-casual, légèrement informel<br>phrases: utiliser avec S1-mini un ton un peu décontracté sans être trop familier |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-semiFormal"></a>

### Semi-formal / Eher förmlich / Semiformal / Plutôt formel (`s1Tone.semiFormal`)

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
| Search (es) | words: semiformal<br>phrases: hacer que S1-mini suene profesional sin ser demasiado formal |
| Search (fr) | words: semi-formel, professionnel souple<br>phrases: utiliser avec S1-mini un style professionnel sans être trop rigide |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Tone-formal"></a>

### Formal / Förmlich / Formal / Formel (`s1Tone.formal`)

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
| Search (es) | words: tono oficial<br>phrases: hacer que S1-mini escriba con un tono totalmente formal |
| Search (fr) | words: soutenu, officiel<br>phrases: faire écrire S1-mini dans un style formel |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure-prose"></a>

### Prose / Fließtext / Prosa / Prose (`s1Structure.prose`)

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
| Search (es) | words: frases completas, párrafos<br>phrases: hacer que S1-mini escriba párrafos en lugar de listas |
| Search (fr) | words: prose, phrases complètes, paragraphes<br>phrases: garder des phrases complètes plutôt que des puces avec S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Structure-lists"></a>

### Lists / Listen / Listas / Listes (`s1Structure.lists`)

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
| Search (es) | words: viñetas, enumeración, bullets<br>phrases: hacer que S1-mini convierta lo que enumero al dictar en una lista con viñetas |
| Search (fr) | words: puces, énumérations<br>phrases: transformer les éléments dictés en liste à puces avec S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context-general"></a>

### General / Allgemein / General / Général (`s1Context.general`)

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
| Search (es) | words: texto normal, formato general<br>phrases: usar formato de texto normal en S1-mini sin convertirlo en un correo |
| Search (fr) | words: texte ordinaire, format général<br>phrases: utiliser une mise en forme ordinaire avec S1-mini sans format de mail |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-s1Context-email"></a>

### Email / E-Mail / Correo electrónico / E-mail (`s1Context.email`)

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
| Search (es) | words: email, correo, saludos, despedidas<br>phrases: hacer que S1-mini dé formato de correo a los saludos y despedidas que dicto |
| Search (fr) | words: mail, salutations, formule de fin<br>phrases: mettre les salutations et la formule de fin de ma dictée au format e-mail avec S1-mini |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-all"></a>

### All categories / Alle Kategorien / Todas las categorías / Toutes les catégories (`yourWords.category.all`)

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
| Search (es) | words: palabras sin filtro<br>phrases: mostrar mis palabras de todas las categorías |
| Search (fr) | words: toutes catégories, sans filtre<br>phrases: afficher mes mots personnels de toutes les catégories |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-general"></a>

### General / Allgemein / General / Général (`yourWords.category.general`)

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
| Search (es) | words: categoría general, palabras cotidianas<br>phrases: ver mis palabras de la categoría general |
| Search (fr) | words: catégorie générale, mots courants personnels<br>phrases: afficher mes mots personnels dans la catégorie générale |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-person"></a>

### Person / Person / Persona / Personne (`yourWords.category.person`)

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
| Search (es) | words: mis nombres, mis apellidos, categoría persona<br>phrases: ver los nombres y apellidos que he añadido al diccionario |
| Search (fr) | words: prénoms ajoutés, noms personnels<br>phrases: afficher les noms et prénoms que j’ai ajoutés moi-même |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-brand"></a>

### Brand / Marke / Marca / Marque (`yourWords.category.brand`)

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
| Search (es) | words: mis marcas, categoría marca<br>phrases: ver los nombres de empresas y productos que he añadido |
| Search (fr) | words: marques ajoutées, produits ajoutés<br>phrases: afficher les noms de marques et de produits que j’ai ajoutés moi-même |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-acronym"></a>

### Acronym / Akronym / Acrónimo / Acronyme (`yourWords.category.acronym`)

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
| Search (es) | words: siglas, acrónimos, abreviaturas<br>phrases: ver las siglas y abreviaturas que he guardado |
| Search (fr) | words: sigles, abréviations, acronymes<br>phrases: afficher les abréviations que j’ai enregistrées dans mes mots personnels |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-domain"></a>

### Domain / Fachgebiet / Ámbito / Domaine (`yourWords.category.domain`)

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
| Search (es) | words: mis tecnicismos, categoría especialidad<br>phrases: ver los términos de mi sector que he añadido al diccionario |
| Search (fr) | words: termes spécialisés ajoutés, vocabulaire métier personnel<br>phrases: afficher les termes spécialisés que j’ai ajoutés moi-même |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-yourWords-category-autoLearned"></a>

### Auto-learned / Automatisch gelernt / Aprendidas automáticamente / Appris automatiquement (`yourWords.category.autoLearned`)

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
| Search (es) | words: palabras aprendidas, entradas automáticas<br>phrases: mostrar solo las palabras aprendidas de mis correcciones |
| Search (fr) | words: mots appris, entrées auto-apprises<br>phrases: afficher seulement les mots déjà appris à partir de mes corrections |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-system"></a>

### System / System / Sistema / Système (`theme.system`)

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
| Search (es) | words: tema del sistema, apariencia automática<br>phrases: hacer que la app siga el modo claro u oscuro del Mac |
| Search (fr) | words: thème système, apparence automatique<br>phrases: faire suivre à l’application le mode clair ou sombre du Mac |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-light"></a>

### Light / Hell / Claro / Clair (`theme.light`)

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
| Search (es) | words: modo claro, tema claro, light mode<br>phrases: dejar la app en modo claro |
| Search (fr) | words: mode clair, mode jour, light mode<br>phrases: garder l’interface de l’application en mode clair |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

<a id="node-theme-dark"></a>

### Dark / Dunkel / Oscuro / Sombre (`theme.dark`)

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
| Search (es) | words: modo oscuro, tema oscuro, dark mode<br>phrases: dejar la app en modo oscuro |
| Search (fr) | words: mode sombre, mode nuit, dark mode<br>phrases: garder l’interface de l’application en mode sombre |
| Search (other 28 languages) | titles, words and phrases in [settings-map.json](settings-map.json) under this id |

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
