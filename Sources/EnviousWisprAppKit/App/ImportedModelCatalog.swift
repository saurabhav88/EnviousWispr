import EnviousWisprCore
import Foundation
import Observation

/// #3147 PR3: the installed speech models Transcribe again with may offer, read from model
/// delivery's admitted installs. The menu reads `choices` synchronously in a view body, so the
/// async admission reads happen in `refresh()` (when History comes to the front and when a
/// menu opens), never in a body. Never downloads.
@MainActor
@Observable
final class ImportedModelCatalog {
  private(set) var choices: [ImportedASRChoice] = []

  @ObservationIgnored private let parakeetSelections:
    @MainActor () async -> [ParakeetModelSelection]
  @ObservationIgnored private let whisperModelPath: @MainActor () async -> String?
  @ObservationIgnored private let whisperIdentity: @MainActor () -> ASRModelIdentity?
  @ObservationIgnored private let whisperTitle: String
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  init(
    parakeetSelections: @escaping @MainActor () async -> [ParakeetModelSelection],
    whisperModelPath: @escaping @MainActor () async -> String?,
    whisperIdentity: @escaping @MainActor () -> ASRModelIdentity?,
    whisperTitle: String
  ) {
    self.parakeetSelections = parakeetSelections
    self.whisperModelPath = whisperModelPath
    self.whisperIdentity = whisperIdentity
    self.whisperTitle = whisperTitle
  }

  /// Rereads the admitted installs. Concurrent calls share one read.
  func refresh() async {
    if let refreshTask { return await refreshTask.value }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      self.choices = await self.read()
    }
    refreshTask = task
    await task.value
    refreshTask = nil
  }

  private func read() async -> [ImportedASRChoice] {
    var result: [ImportedASRChoice] = []
    for selection in await parakeetSelections() {
      result.append(
        ImportedASRChoice(
          id: "parakeet.\(selection.model.rawValue)", title: selection.model.displayName,
          selection: .parakeet(selection, identity: selection.modelIdentity), isCurrent: false))
    }
    if let path = await whisperModelPath(), let identity = whisperIdentity() {
      result.append(
        ImportedASRChoice(
          id: "whisper", title: whisperTitle,
          selection: .whisper(modelFile: URL(fileURLWithPath: path), identity: identity),
          isCurrent: false))
    }
    return result
  }
}
