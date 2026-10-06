import EnviousWisprCore
import Foundation

/// Settings item names that had no named owner before the Settings Map (#3482): each was an
/// inline literal at its control. The control and the map now read the same resource, with the
/// key, default value and comment unchanged.
enum SettingsItemCopy {
  enum AIPolish {
    static let aboutAppleIntelligence = LocalizedStringResource("About Apple Intelligence", comment: "AI Polish: link to Apple's Apple Intelligence support page.")
    static let appleRecheck = LocalizedStringResource("Check Apple Intelligence availability", comment: "AI Polish, Apple Intelligence: re-checks availability.")
    static let claudeKey = LocalizedStringResource("Claude API Key", comment: "AI Polish: label and VoiceOver name of the API key field.")
    static let claudeRateLimits = LocalizedStringResource("Claude API rate limits", comment: "AI Polish: link to Anthropic's rate limits page.")
    static let downloadOllama = LocalizedStringResource("Download Ollama", comment: "AI Polish, Ollama setup: opens the Ollama download page.")
    static let enable = LocalizedStringResource("settings.aiPolish.enable.title", defaultValue: "Enable AI Polish")
    static let geminiKey = LocalizedStringResource("Google Gemini API Key", comment: "AI Polish: label and VoiceOver name of the API key field.")
    static let geminiRateLimits = LocalizedStringResource("Gemini API rate limits by tier", comment: "AI Polish: link to Google's Gemini rate limits page.")
    static let keyClear = LocalizedStringResource("Clear", comment: "AI Polish: button that deletes the saved API key.")
    static let keySave = LocalizedStringResource("Save", comment: "AI Polish: button that saves the API key.")
    static let model = LocalizedStringResource("Model", comment: "AI Polish: the model row's title.")
    static let modelSection = LocalizedStringResource("Model", comment: "AI Polish: heading above the provider card.")
    static let ollamaBrowseModels = LocalizedStringResource("Download more models", comment: "AI Polish, Ollama: title of the card that opens the model list.")
    static let ollamaCancel = LocalizedStringResource("Cancel")
    static let ollamaLibrary = LocalizedStringResource("Ollama model library", comment: "AI Polish: link to Ollama's model library.")
    static let ollamaPrepareModel = LocalizedStringResource("Prepare model", comment: "AI Polish, Ollama: loads the model now.")
    static let ollamaRecheck = LocalizedStringResource("Re-check Ollama status", comment: "AI Polish, Ollama: checks Ollama again.")
    static let ollamaServer = LocalizedStringResource("Server", comment: "AI Polish, Ollama: the server row's title.")
    static let ollamaTryAgain = LocalizedStringResource("Try Again", comment: "AI Polish, Ollama: checks the Ollama setup again.")
    static let openAIKey = LocalizedStringResource("OpenAI API Key", comment: "AI Polish: label and VoiceOver name of the API key field.")
    static let openAIRateLimits = LocalizedStringResource("OpenAI rate limits by tier", comment: "AI Polish: link to OpenAI's rate limits page.")
    static let refreshModels = LocalizedStringResource("Refresh available models", comment: "AI Polish: re-checks the key and reloads the model list.")
    static let startOllama = LocalizedStringResource("Start Ollama", comment: "AI Polish, Ollama setup: the current step.")
    static let whyAppleIntelligence = LocalizedStringResource("Why use Apple Intelligence", comment: "AI Polish: card title explaining a provider.")
    static let whyClaude = LocalizedStringResource("Why use Claude", comment: "AI Polish: card title explaining a provider.")
    static let whyEGOne = LocalizedStringResource("Why use EG-1", comment: "AI Polish: card title explaining a provider.")
    static let whyGemini = LocalizedStringResource("Why use Gemini", comment: "AI Polish: card title explaining a provider.")
    static let whyOllama = LocalizedStringResource("Why use Ollama", comment: "AI Polish: card title explaining a provider.")
    static let whyOpenAI = LocalizedStringResource("Why use OpenAI", comment: "AI Polish: card title explaining a provider.")
    static let whyS1Mini = LocalizedStringResource("Why use \(LLMProvider.s1Mini.displayName)", comment: "AI Polish: card title explaining a provider. %@ is the model name, S1-mini.")
  }

  enum AppSettings {
    static let aboutSection = LocalizedStringResource("ABOUT")
    static let accessibilityPermission = LocalizedStringResource("Accessibility")
    static let appearanceSection = LocalizedStringResource("APPEARANCE")
    static let gplLicense = LocalizedStringResource("EnviousWispr · GPLv3")
    static let language = LocalizedStringResource("Language")
    static let microphonePermission = LocalizedStringResource("Microphone")
    static let openSystemSettings = LocalizedStringResource("Open System Settings")
    static let permissionsSection = LocalizedStringResource("PERMISSIONS")
    static let privacySection = LocalizedStringResource("PRIVACY")
    static let relaunch = LocalizedStringResource("Relaunch to apply")
    static let requestAccess = LocalizedStringResource("Request Access")
    static let showInDock = LocalizedStringResource("Show app in Dock")
    static let systemDefault = LocalizedStringResource("System default")
    static let theme = LocalizedStringResource("Theme")
    static let thirdPartyNotices = LocalizedStringResource("Third-Party Notices")
    static let updateAlert = LocalizedStringResource("Update alert in menu bar")
    static let viewLicense = LocalizedStringResource("View license")
    static let viewNotices = LocalizedStringResource("View notices")
  }

  enum Dictionary {
    static let addWord = LocalizedStringResource("Add word")
    static let allCategories = LocalizedStringResource("All categories", comment: "Your Words: filter showing every category.")
    static let clearSearch = LocalizedStringResource("Clear search")
    static let exportWords = LocalizedStringResource("Export your words")
    static let importContacts = LocalizedStringResource("Import from Contacts")
    static let importWords = LocalizedStringResource("Import")
    static let learnFromPanel = LocalizedStringResource("Learn from...")
    static let massEdit = LocalizedStringResource("Mass edit")
    static let quickAddMenuBar = LocalizedStringResource("Menu bar", comment: "Dictionary settings, Quick Add teaching card: label of the menu bar callout.")
    static let quickAddShortcut = LocalizedStringResource("Keyboard shortcut", comment: "Dictionary settings, Quick Add teaching card: label of the shortcut callout.")
    static let quickAddStep1 = LocalizedStringResource("Highlight a word", comment: "Dictionary settings, Quick Add teaching card: step 1 title.")
    static let quickAddStep2 = LocalizedStringResource("Trigger Quick Add", comment: "Dictionary settings, Quick Add teaching card: step 2 title.")
    static let quickAddStep3 = LocalizedStringResource("Choose and save", comment: "Dictionary settings, Quick Add teaching card: step 3 title.")
    static let searchWords = LocalizedStringResource("Search by word, mishearing, or category")
    static let syncOnLaunch = LocalizedStringResource("Keep in sync on launch")
  }

  enum Engine {
    static let fastCancel = LocalizedStringResource("Cancel")
    static let fastResume = LocalizedStringResource("Resume", comment: "Speech engine settings, speech model download: button that resumes it.")
    static let fastTryAgain = LocalizedStringResource("Try Again", comment: "Speech engine settings, speech model download: button after a failure.")
    static let lockedLanguageChange = LocalizedStringResource("Change")
    static let pauseDuration = LocalizedStringResource("Pause duration", comment: "Speech engine settings, Auto-Stop: slider for how long a silence ends the recording.")
    static let resetSuggestions = LocalizedStringResource("Reset suggestions")
    static let whisperCancel = LocalizedStringResource("Cancel")
    static let whisperRecheck = LocalizedStringResource("Re-check model status")
    static let whisperRemove = LocalizedStringResource("Remove Model")
    static let whisperResume = LocalizedStringResource("Resume")
    static let whisperTryAgain = LocalizedStringResource("Try Again")
  }

  enum Keybinds {
    static let pushToTalk = LocalizedStringResource("Push to Talk")
    static let recordingSection = LocalizedStringResource("keybinds.section.recording", defaultValue: "Recording", comment: "Keybinds page: section heading for the recording keys. Shown in capitals.")
    static let resetToDefault = LocalizedStringResource("Reset to default", comment: "Keybind field: puts this keybind back to its original keys.")
    static let shortcutsSection = LocalizedStringResource("keybinds.section.shortcuts", defaultValue: "Shortcuts", comment: "Keybinds page: section heading for paste, copy and add-a-word keys. Shown in capitals.")
    static let toggle = LocalizedStringResource("Toggle")
  }

  enum LivePreview {
    static let universalCancel = LocalizedStringResource("Cancel", comment: "Live Preview settings, Universal engine card: button. It stops the download.")
    static let universalDownload = LocalizedStringResource("Download", comment: "Live Preview settings, Universal engine card: button. It starts the engine download.")
    static let universalRemove = LocalizedStringResource("Remove", comment: "Live Preview settings, Universal engine card: button. It deletes the downloaded engine.")
    static let universalResume = LocalizedStringResource("Resume", comment: "Live Preview settings, Universal engine card: button. It resumes the download.")
    static let universalRetry = LocalizedStringResource("Try Again", comment: "Live Preview settings, Universal engine card: button. It retries a failed download.")
  }

  enum Microphone {
    static let auto = LocalizedStringResource("Auto")
    static let bluetoothLearnMore = LocalizedStringResource("Learn more")
    static let mediaContinue = LocalizedStringResource("otherAudio.option.continue", defaultValue: "Continue", comment: "Microphone settings, media during dictation: option that leaves other audio playing (keeps playing, not 'go on').")
    static let mediaLower = LocalizedStringResource("Lower", comment: "Microphone settings, media during dictation: option that turns other audio down.")
    static let mediaMute = LocalizedStringResource("Mute", comment: "Microphone settings, media during dictation: option that silences other audio.")
    static let mediaPause = LocalizedStringResource("Pause", comment: "Microphone settings, media during dictation: option that pauses what is playing.")
    static let readiness10s = LocalizedStringResource("10 sec", comment: "Microphone settings: readiness option, 10 seconds.")
    static let readiness30s = LocalizedStringResource("30 sec", comment: "Microphone settings: readiness option, 30 seconds.")
    static let readiness60s = LocalizedStringResource("60 sec", comment: "Microphone settings: readiness option, 60 seconds.")
    static let readinessAlways = LocalizedStringResource("Always", comment: "Microphone settings: readiness option; the microphone stays ready.")
    static let readinessOff = LocalizedStringResource("Off", comment: "Microphone settings: readiness option; the microphone is released at once.")
  }

  enum Pill {
    static let bottom = LocalizedStringResource("Bottom", comment: "Recording Pill settings, position on screen: the bottom of the screen.")
    static let configureLivePreview = LocalizedStringResource("Configure Live Preview")
    static let top = LocalizedStringResource("Top", comment: "Recording Pill settings, position on screen: the top of the screen.")
  }

  enum Shared {
    static let change = LocalizedStringResource(
      "Change", comment: "Settings: button that opens the other choices for a setting.")
  }

  enum Snippets {
    static let add = LocalizedStringResource("Add snippet")
    static let addFirst = LocalizedStringResource("Add your first snippet")
    static let clearSearch = LocalizedStringResource("Clear search")
    static let exportSnippets = LocalizedStringResource("Export")
    static let importSnippets = LocalizedStringResource("Import")
    static let keyword = LocalizedStringResource("Keyword")
    static let search = LocalizedStringResource("Search snippets")
    static let yourSnippets = LocalizedStringResource("Your snippets")
  }
}
