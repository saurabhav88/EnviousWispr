import EnviousWisprCore
import Foundation

/// Phase 5a (#635) — manages the vocabulary pack catalogue + installed state.
/// Bible §11.
///
/// Phase 5a ships the type + persistence skeleton WITHOUT bundled JSON
/// content. Phase 5b adds the actual pack JSON files + SPM resource
/// bundling + UI wire. This skeleton enables Phase 5b to compile against a
/// stable API.
///
/// Catalogue is loaded once on init from `loadCatalogueAndPacks(...)` (Phase
/// 5b implementation will read from the bundled Resources/VocabularyPacks/).
/// In Phase 5a, an in-memory empty catalogue is used; tests can inject a
/// catalogue via the convenience init.
@MainActor
public final class VocabularyPacksManager {
  /// All known packs (loaded from catalogue at init).
  public private(set) var availablePacks: [VocabularyPack]
  /// Set of installed pack IDs. Persisted to `installed-packs.json`.
  public private(set) var installedPackIDs: Set<String>
  /// Called whenever installed state changes — `CustomWordsCoordinator`
  /// subscribes here so it can re-emit `onWordsChanged` with the merged
  /// (user + pack) list and trigger a propagator broadcast.
  public var onInstalledPacksChanged: (() -> Void)?

  private let installedStateURL: URL?

  /// Phase 5b entry point: loads catalogue from bundled resources +
  /// installed state from disk. NOT YET IMPLEMENTED — Phase 5a ships the
  /// skeleton; production wiring comes when SPM resource bundling lands.
  public init() {
    self.availablePacks = []
    self.installedPackIDs = []
    self.installedStateURL = Self.defaultInstalledStateURL()
    // Phase 5b: replace with real catalogue load + installed-state restore.
  }

  /// Test seam — construct with explicit catalogue and installed state.
  /// Tests do not touch disk.
  public init(
    availablePacks: [VocabularyPack],
    installedPackIDs: Set<String> = [],
    installedStateURL: URL? = nil
  ) {
    self.availablePacks = availablePacks
    self.installedPackIDs = installedPackIDs
    self.installedStateURL = installedStateURL
  }

  /// Pack with the given ID, or nil.
  public func pack(id: String) -> VocabularyPack? {
    availablePacks.first { $0.id == id }
  }

  /// Whether `id` is currently installed.
  public func isInstalled(_ id: String) -> Bool {
    installedPackIDs.contains(id)
  }

  /// Install a pack by ID. No-op if already installed or if the ID is not in
  /// `availablePacks` (catalogue-not-loaded protection). Persists installed
  /// state if `installedStateURL` is set.
  public func install(_ id: String) {
    guard pack(id: id) != nil, !installedPackIDs.contains(id) else { return }
    installedPackIDs.insert(id)
    persistInstalledState()
    onInstalledPacksChanged?()
  }

  /// Uninstall a pack by ID. No-op if not installed.
  public func uninstall(_ id: String) {
    guard installedPackIDs.remove(id) != nil else { return }
    persistInstalledState()
    onInstalledPacksChanged?()
  }

  /// Merged `[CustomWord]` from all installed packs. Each entry has
  /// `source: .pack` so the propagator's `LanePartitioner.split` filters
  /// it out of the polish lane. Bible §2.2.
  public func installedTerms() -> [CustomWord] {
    var out: [CustomWord] = []
    for id in installedPackIDs {
      guard let p = pack(id: id) else { continue }
      out.append(contentsOf: p.customWords())
    }
    return out
  }

  // MARK: - Persistence

  private func persistInstalledState() {
    guard let url = installedStateURL else { return }
    do {
      let state = InstalledPacksState(
        version: 1, installedPackIDs: Array(installedPackIDs).sorted())
      let data = try JSONEncoder().encode(state)
      try data.write(to: url, options: [.atomic])
    } catch {
      // Best-effort persistence — Phase 8 telemetry will catch repeated failures.
    }
  }

  private static func defaultInstalledStateURL() -> URL? {
    let fileManager = FileManager.default
    guard
      let appSupport = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    let dir = appSupport.appendingPathComponent("EnviousWispr", isDirectory: true)
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("installed-packs.json")
  }

  private struct InstalledPacksState: Codable {
    let version: Int
    let installedPackIDs: [String]
  }
}
