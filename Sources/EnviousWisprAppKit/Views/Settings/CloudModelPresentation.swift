import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// #4353 D6: what the cloud model list adds to a cloud model menu, label and note. The one
/// policy the three menus (dictation, Transcribe a File, summaries), the closed-menu label, the
/// sidebar label and DevControl's admission read, each from ONE captured holder snapshot.
///
/// Derived presentation only: it never edits the discovered or cached rows (availability and
/// probe times stay as discovery left them), never writes a setting and never changes a choice.
///
/// Every fact (recommended, hidden, display name, release date) resolves the exact id first,
/// then its dated base (`LLMProvider.listedRow`): a dated copy is the same model. An exact
/// dated row wins over its base. The request id is never changed.
enum CloudModelPresentation {
  /// Whether the list hides `id` from the menu. Compiled model-kind exclusions are applied
  /// earlier, at discovery (`LLMModelDiscovery.filterModels`); endpoint eligibility under the
  /// current list is checked beside this in `OllamaModelPickerPresentation.cloudGroups`.
  static func isHidden(_ id: String, provider: LLMProvider, list: CloudModelList?) -> Bool {
    provider.listedRow(model: id, list: list)?.hidden == true
  }

  /// "Recommended for cleanup": a listed row's `recommended` decides; the compiled tier words
  /// and disqualifiers (`AIPolishModelClassifier`) answer only for an id the list does not name.
  static func isRecommended(_ id: String, provider: LLMProvider, list: CloudModelList?) -> Bool {
    if let row = provider.listedRow(model: id, list: list) { return row.recommended }
    return AIPolishModelClassifier.isRecommendedForCleanup(id)
  }

  /// The list's `released` as the UTC midnight it names.
  static func releaseDate(_ released: String) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = released.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// One discovered row as the menu shows it: name list → provider → id, date list → provider
  /// → undated. A copy; the input row is untouched.
  static func presented(_ model: LLMModelInfo, list: CloudModelList?) -> LLMModelInfo {
    guard let row = model.provider.listedRow(model: model.id, list: list),
      row.displayName != nil || row.released != nil
    else { return model }
    return LLMModelInfo(
      id: model.id, displayName: row.displayName ?? model.displayName, provider: model.provider,
      availability: model.availability, isRemote: model.isRemote,
      appleIntelligenceStatus: model.appleIntelligenceStatus,
      availabilityObservedAt: model.availabilityObservedAt,
      releaseDate: row.released.flatMap(releaseDate) ?? model.releaseDate)
  }

  /// The label for a stored choice: its discovered row as presented, else the list's name for
  /// it, else the stored id. Never a replacement model; the choice itself is not touched.
  static func label(
    for id: String, provider: LLMProvider, models: [LLMModelInfo], list: CloudModelList?
  ) -> String {
    if let info = models.first(where: { $0.provider == provider && $0.id == id }) {
      return presented(info, list: list).localizedDisplayName
    }
    return provider.listedRow(model: id, list: list)?.displayName ?? id
  }
}
