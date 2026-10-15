import EnviousWisprCore
import Foundation

/// Moves an existing user from the retired WhisperKit (CoreML) models to the transcribe.cpp
/// GGUF models (#3735 plan §3.6). Runs on every launch; after the first, it is a few file
/// existence checks.
///
/// One durable record per artifact (dictation turbo, Universal preview) is the owner of the
/// upgrade decision:
/// - `owed`: this user is owed the replacement. Written on the first launch of the new build
///   for a user who had the old model or has the engine selected, BEFORE any old file is
///   deleted, so a crash between the two still leaves the debt recorded.
/// - `notOwed`: neither condition held at that first launch. Later choices go through the
///   ordinary Settings Download.
/// - `admitted`: the replacement is installed.
/// - `declined`: the user cancelled or removed it. Nothing fetches automatically again; an
///   explicit Download clears it.
///
/// Automatic fetch runs only while an artifact is owed AND currently selected, so a user who
/// had the old folders but never selected the engine has them deleted and downloads nothing.
/// A finished download only installs the model: it never starts a recording or changes the
/// selected engine.
///
/// Deletion is limited to identified app-owned leftovers: the two old install folders, the
/// retired family's admission markers and staging folders (all named `whisper_kit-…`), and
/// the two markers the old coordinator wrote. It never touches `~/Documents/huggingface`
/// (`.claude/knowledge/whisperkit-research.md` FACT:
/// documents-huggingface-is-a-shared-cache-not-ours), the shared metadata directory itself,
/// or an admitted replacement. A failed deletion is logged and retried next launch; it never
/// blocks the download.
@MainActor
final class WhisperModelMigration {

  enum Artifact: String, CaseIterable, Codable, Sendable {
    case dictation
    case preview
  }

  enum ReplacementState: String, Codable, Sendable, Equatable {
    case owed
    case notOwed
    case admitted
    case declined
  }

  /// What the migration may do to one artifact's replacement. Closures, so tests drive it
  /// without a delivery controller.
  struct ArtifactPort {
    /// The engine this artifact serves is the one currently selected.
    let isSelected: @MainActor () -> Bool
    /// Admitted, or adoptable WITHOUT fetching (a complete cache with no marker).
    let isAdmittedOrAdoptable: @MainActor () async -> Bool
    /// The download door; true when the replacement ended admitted.
    let ensureAvailable: @MainActor () async -> Bool
    /// The retired CoreML install folder this artifact replaces.
    let legacyInstallDirectory: URL
  }

  /// Content-free and path-free: these cross the telemetry boundary.
  enum Event: Sendable, Equatable {
    /// Every identified leftover present at this launch was deleted (never sent when there
    /// were none).
    case legacyRetired
    /// At least one leftover could not be deleted; retried next launch.
    case legacyRetirementFailed
    /// An owed replacement became admitted.
    case replacementCompleted(Artifact)
  }

  var onEvent: (@MainActor (Event) -> Void)?

  enum CommandOutcome: Sendable, Equatable {
    case done
    /// The record could not be read or written, so nothing else ran.
    case refusedRecord
  }

  private let metadataDirectory: URL
  private let ports: [Artifact: ArtifactPort]
  private let isDeliveryEnabled: @MainActor () -> Bool
  private let removeItem: (URL) throws -> Void
  private let log: @MainActor (String) -> Void

  /// Bumped per artifact by every user command on that artifact, so a launch run overtaken on
  /// one artifact (a Cancel during its automatic fetch) does not write a stale state for it,
  /// and the other artifact's work goes on.
  private var generations: [Artifact: Int] = [:]

  init(
    metadataDirectory: URL,
    ports: [Artifact: ArtifactPort],
    isDeliveryEnabled: @escaping @MainActor () -> Bool,
    removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
    log: @escaping @MainActor (String) -> Void = { message in
      Task { await AppLogger.shared.log(message, level: .info, category: "WhisperMigration") }
    }
  ) {
    self.metadataDirectory = metadataDirectory
    self.ports = ports
    self.isDeliveryEnabled = isDeliveryEnabled
    self.removeItem = removeItem
    self.log = log
  }

  // MARK: - Record

  /// Keyed by `Artifact.rawValue`, so the file reads as a plain JSON object.
  private struct Record: Codable, Equatable {
    var version = 1
    var artifacts: [String: ReplacementState] = [:]

    subscript(artifact: Artifact) -> ReplacementState? {
      get { artifacts[artifact.rawValue] }
      set { artifacts[artifact.rawValue] = newValue }
    }
  }

  private enum RecordRead {
    case absent
    case present(Record)
    /// The file exists but could not be read, decoded, or has a version this build does not
    /// know. It may hold a decision (a decline) this build cannot see, so nothing proceeds
    /// and nothing overwrites it.
    case unusable
  }

  private var recordURL: URL {
    metadataDirectory.appendingPathComponent("whisper-replacement.json")
  }

  private func readRecord() -> RecordRead {
    guard FileManager.default.fileExists(atPath: recordURL.path) else { return .absent }
    guard let data = try? Data(contentsOf: recordURL),
      let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1
    else {
      log("Whisper migration: the replacement record is unreadable; nothing changes")
      return .unusable
    }
    return .present(record)
  }

  private func writeRecord(_ record: Record) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: metadataDirectory, withIntermediateDirectories: true)
      try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
      return true
    } catch {
      log("Whisper migration: record write failed: \(error)")
      return false
    }
  }

  func state(of artifact: Artifact) -> ReplacementState? {
    if case .present(let record) = readRecord() { return record[artifact] }
    return nil
  }

  /// Refuses (false) on an unusable record as well as on a failed write.
  private func setState(_ state: ReplacementState, for artifact: Artifact) -> Bool {
    var record: Record
    switch readRecord() {
    case .absent: record = Record()
    case .present(let existing): record = existing
    case .unusable: return false
    }
    record[artifact] = state
    return writeRecord(record)
  }

  // MARK: - Launch

  /// Every launch. The delivery kill switch refuses the whole run before any write or
  /// deletion: a rollback must not lose the old model and then refuse the new one.
  func runLaunch() async {
    guard isDeliveryEnabled() else { return }
    let started = generations

    // 1. The first launch of this build records each artifact's debt, before any deletion.
    var record: Record
    switch readRecord() {
    case .absent: record = Record()
    case .present(let existing): record = existing
    case .unusable: return
    }
    var changed = false
    for artifact in Artifact.allCases where record[artifact] == nil {
      guard let port = ports[artifact] else { continue }
      let hadOld =
        Self.directoryExists(port.legacyInstallDirectory)
        || (artifact == .dictation && legacyOwedMarkerExists)
      record[artifact] = (hadOld || port.isSelected()) ? .owed : .notOwed
      changed = true
    }
    if changed, !writeRecord(record) { return }

    // 2. Retire the old leftovers. Best effort; failures are retried next launch.
    retireLegacyAssets()

    // 3. Settle or fetch what is owed.
    for artifact in Artifact.allCases {
      let current = { [unowned self] in generations[artifact] == started[artifact] }
      guard current(), let port = ports[artifact], state(of: artifact) == .owed else { continue }
      if await port.isAdmittedOrAdoptable() {
        if current() { markAdmitted(artifact) }
        continue
      }
      guard current(), port.isSelected(), isDeliveryEnabled() else { continue }
      let admitted = await port.ensureAvailable()
      if admitted, current() { markAdmitted(artifact) }
    }
  }

  // MARK: - User commands

  /// Settings Download: clears a decline and fetches. The record is written first, so a quit
  /// mid-download resumes on the next launch.
  func download(_ artifact: Artifact) async -> CommandOutcome {
    generations[artifact, default: 0] += 1
    guard setState(.owed, for: artifact) else { return .refusedRecord }
    guard let port = ports[artifact] else { return .done }
    let mine = generations[artifact]
    if await port.ensureAvailable(), mine == generations[artifact] {
      markAdmitted(artifact)
    }
    return .done
  }

  private func markAdmitted(_ artifact: Artifact) {
    if setState(.admitted, for: artifact) { onEvent?(.replacementCompleted(artifact)) }
  }

  /// Settings Cancel or Remove: recorded BEFORE the caller stops the fetch or deletes the
  /// files, so the next launch never restarts what the user stopped. Refused (and nothing
  /// else should run) when the record cannot be read or written.
  func decline(_ artifact: Artifact) -> CommandOutcome {
    generations[artifact, default: 0] += 1
    return setState(.declined, for: artifact) ? .done : .refusedRecord
  }

  // MARK: - Retirement

  /// The retired family's raw value. Literal on purpose: this file must keep recognizing old
  /// leftovers after the `ModelFamily` case is deleted.
  static let legacyFamilyPrefix = "whisper_kit-"
  static let legacyMarkerNames = [
    "whisperkit-replacement-owed", "whisperkit-foreign-declined.json",
  ]

  private var legacyOwedMarkerExists: Bool {
    FileManager.default.fileExists(
      atPath: metadataDirectory.appendingPathComponent(Self.legacyMarkerNames[0]).path)
  }

  /// The identified leftovers present right now, in deletion order. Exposed for tests.
  func legacyLeftovers() -> [URL] {
    let fm = FileManager.default
    var found: [URL] = []
    for artifact in Artifact.allCases {
      if let dir = ports[artifact]?.legacyInstallDirectory, Self.directoryExists(dir) {
        found.append(dir)
      }
    }
    let staging = metadataDirectory.appendingPathComponent("staging", isDirectory: true)
    for entry in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
    where entry.hasPrefix(Self.legacyFamilyPrefix) {
      found.append(staging.appendingPathComponent(entry))
    }
    for entry in (try? fm.contentsOfDirectory(atPath: metadataDirectory.path)) ?? []
    where entry.hasPrefix(Self.legacyFamilyPrefix) && entry.hasSuffix(".admission.json") {
      found.append(metadataDirectory.appendingPathComponent(entry))
    }
    for name in Self.legacyMarkerNames {
      let url = metadataDirectory.appendingPathComponent(name)
      if fm.fileExists(atPath: url.path) { found.append(url) }
    }
    return found
  }

  /// A real directory, not a symlink to one: a link is never followed into someone else's
  /// files.
  private static func directoryExists(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private func retireLegacyAssets() {
    let leftovers = legacyLeftovers()
    guard !leftovers.isEmpty else { return }
    var failed = false
    for url in leftovers {
      do {
        try removeItem(url)
      } catch {
        failed = true
        log("Whisper migration: could not delete \(url.lastPathComponent): \(error)")
      }
    }
    onEvent?(failed ? .legacyRetirementFailed : .legacyRetired)
  }
}
