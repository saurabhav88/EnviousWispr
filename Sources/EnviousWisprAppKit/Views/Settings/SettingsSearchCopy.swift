import Foundation

/// Copy for Settings search (#3482 plan §3.3, §3.5): the field, the dropdown and the Find
/// Settings command, plus the result labels of places whose interface title is only known at run
/// time. German ships with the English in the same catalog.
enum SettingsSearchCopy {
  static let placeholder = LocalizedStringResource(
    "Search settings", comment: "Settings sidebar: placeholder in the search field.")
  /// The same "Clear search" the Snippets and Your Words searches use.
  static let clear = LocalizedStringResource("Clear search")
  static let findSettings = LocalizedStringResource(
    "Find Settings",
    comment: "Edit menu: moves the cursor into the Settings search field (Command-F).")
  static let returnHint = LocalizedStringResource(
    "Return", comment: "Settings search: key hint on the selected result; Return opens it.")

  /// "Matches “Parakeet”": why a result was found when its visible title does not say so. The
  /// word is shown exactly as it was written in the vocabulary or interface, never the query.
  static func matches(_ word: String) -> String {
    String(
      localized: "Matches “\(word)”",
      comment: "Settings search result: the word that found this setting. %@ is that word.")
  }

  /// "No settings match “mic”."
  static func noResults(_ query: String) -> String {
    String(
      localized: "No settings match “\(query)”.",
      comment: "Settings search: shown when nothing matches. %@ is what the person typed.")
  }

  /// Spoken after typing pauses.
  static func resultCount(_ count: Int) -> String {
    String(
      localized: "\(count) settings found",
      comment: "Settings search, VoiceOver: how many results the search shows.")
  }

  /// Spoken when a search result opens its place: "Showing Pause duration".
  static func arrived(_ title: String) -> String {
    String(
      localized: "Showing \(title)",
      comment: "Settings search, VoiceOver: the place the chosen result opened. %@ is its name.")
  }

  /// Spoken when the chosen place is hidden and its declared fallback opened instead:
  /// "Showing Stop recording on silence for Pause duration".
  static func arrivedAtFallback(landed: String, chosen: String) -> String {
    String(
      localized: "Showing \(landed) for \(chosen)",
      comment:
        "Settings search, VoiceOver: the chosen setting is hidden right now, so the setting that shows it opened. The first %@ is the place opened, the second the chosen result.")
  }

  /// Result labels for searchable places whose map title is dynamic and has no fixed context
  /// (orchestrator-approved table, docs/audits/2026-10-07-settings-search-chunk4-labels.md).
  /// `SettingsSearchPresentationTests` requires every such place to have one.
  enum Label {
    static let dictationLanguage = LocalizedStringResource(
      "Dictation language",
      comment: "The language dictation is locked to: the language sheet's title and a Settings search result.")
    static let currentEngine = LocalizedStringResource(
      "Current dictation engine",
      comment: "Settings search result: the heading that names the speech engine in use.")
    static let microphoneInList = LocalizedStringResource(
      "Microphone in the list",
      comment: "Settings search result: one microphone in the Input device list.")
    static let inputs = LocalizedStringResource(
      "Input 1, Input 2…",
      comment: "Settings search result: the inputs of a microphone with several inputs.")
    static let listenToSound = LocalizedStringResource(
      "Listen to the sound",
      comment: "Settings search result: plays a recording chime so you can hear it.")
    static let fileSteps = LocalizedStringResource(
      "File transcription steps",
      comment: "Settings search result: the steps of Transcribe a File.")
    static let provider = LocalizedStringResource(
      "AI Polish provider",
      comment: "Settings search result: the model card that chooses who polishes the text.")
    static let providerSettings = LocalizedStringResource(
      "Settings for the chosen provider",
      comment: "Settings search result: the setup section of the chosen AI Polish provider.")
    static let testModel = LocalizedStringResource(
      "Test that the model is live",
      comment: "Settings search result: re-checks that the local polish model answers.")
    static let appleIntelligenceStatus = LocalizedStringResource(
      "Apple Intelligence status",
      comment: "Settings search result: whether Apple Intelligence is available on this Mac.")
    static let ollamaModel = LocalizedStringResource(
      "Download a model for Ollama",
      comment: "Settings search result: downloads a model for the Ollama provider.")
    static let getAPIKey = LocalizedStringResource(
      "Get an API key",
      comment: "Settings search result: link to the chosen cloud provider's API key page.")
    static let appLanguages = LocalizedStringResource(
      "English or German",
      comment: "Settings search result: the languages the app itself can be shown in.")
  }
}
