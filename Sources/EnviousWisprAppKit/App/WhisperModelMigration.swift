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
    /// The record could not be written, so nothing else ran.
    case refusedRecordWrite
  }

  private let metadataDirectory: URL
  private let ports: [Artifact: ArtifactPort]
  private let isDeliveryEnabled: @MainActor () -> Bool
  private let removeItem: (URL) throws -> Void
  private let log: @MainActor (String) -> Void

  /// Bumped by every user command, so a launch run that was overtaken (a Cancel during its
  /// automatic fetch) does not write a stale state afterwards.
  private var generation = 0

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

  private struct Record: Codable, Equatable {
    var version = 1
    var artifacts: [Artifact: ReplacementState] = [:]
  }

  private var recordURL: URL {
    metadataDirectory.appendingPathComponent("whisper-replacement.json")
  }

  /// A record that exists but cannot be read is treated as absent for every artifact, which
  /// recomputes `owed` from the disk and the selection: the same answer a first launch gives.
  private func readRecord() -> Record {
    guard let data = try? Data(contentsOf: recordURL),
      let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1
    else { return Record() }
    return record
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
    readRecord().artifacts[artifact]
  }

  private func setState(_ state: ReplacementState, for artifact: Artifact) -> Bool {
    var record = readRecord()
    record.artifacts[artifact] = state
    return writeRecord(record)
  }

  // MARK: - Launch

  /// Every launch. The delivery kill switch refuses the whole run before any write or
  /// deletion: a rollback must not lose the old model and then refuse the new one.
  func runLaunch() async {
    guard isDeliveryEnabled() else { return }
    let started = generation

    // 1. The first launch of this build records each artifact's debt, before any deletion.
    var record = readRecord()
    var changed = false
    for artifact in Artifact.allCases where record.artifacts[artifact] == nil {
      guard let port = ports[artifact] else { continue }
      let hadOld =
        Self.directoryExists(port.legacyInstallDirectory)
        || (artifact == .dictation && legacyOwedMarkerExists)
      record.artifacts[artifact] = (hadOld || port.isSelected()) ? .owed : .notOwed
      changed = true
    }
    if changed, !writeRecord(record) { return }

    // 2. Retire the old leftovers. Best effort; failures are retried next launch.
    retireLegacyAssets()

    // 3. Settle or fetch what is owed.
    for artifact in Artifact.allCases {
      guard generation == started, let port = ports[artifact],
        readRecord().artifacts[artifact] == .owed
      else { continue }
      if await port.isAdmittedOrAdoptable() {
        if generation == started { markAdmitted(artifact) }
        continue
      }
      guard port.isSelected(), isDeliveryEnabled() else { continue }
      let admitted = await port.ensureAvailable()
      if admitted, generation == started { markAdmitted(artifact) }
    }
  }

  // MARK: - User commands

  /// Settings Download: clears a decline and fetches. The record is written first, so a quit
  /// mid-download resumes on the next launch.
  func download(_ artifact: Artifact) async -> CommandOutcome {
    generation += 1
    guard setState(.owed, for: artifact) else { return .refusedRecordWrite }
    guard let port = ports[artifact] else { return .done }
    let mine = generation
    if await port.ensureAvailable(), mine == generation {
      markAdmitted(artifact)
    }
    return .done
  }

  private func markAdmitted(_ artifact: Artifact) {
    if setState(.admitted, for: artifact) { onEvent?(.replacementCompleted(artifact)) }
  }

  /// Settings Cancel or Remove: recorded BEFORE the caller stops the fetch or deletes the
  /// files, so the next launch never restarts what the user stopped. Refused (and nothing
  /// else should run) when the record cannot be written.
  func decline(_ artifact: Artifact) -> CommandOutcome {
    generation += 1
    return setState(.declined, for: artifact) ? .done : .refusedRecordWrite
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
