import CryptoKit
import EnviousWisprModelDelivery
import Foundation

/// Retires exactly one unsupported, app-owned EG-1 artifact.
///
/// It does not understand current shards, download them, verify them, or admit
/// them. Those responsibilities stay in EGOneDeliveryAdapter and
/// ModelDeliveryController.
@MainActor
public final class EGOneLegacyUpgradeCoordinator {
  public struct TrustedArtifact: Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, sizeBytes: Int64, sha256: String) {
      self.name = name
      self.sizeBytes = sizeBytes
      self.sha256 = sha256
    }
  }

  public enum FailureReason: String, Sendable, Equatable {
    case markerWrite = "marker_write"
    case delete
    case unreadable
    case containment
  }

  public enum Event: Sendable, Equatable {
    case legacyDetected
    case legacyRetired
    case legacyRetirementFailed(reason: FailureReason)
    case replacementCompleted
    case replacementDeclined
  }

  public static let shippedLegacyArtifact = TrustedArtifact(
    name: "eg-1-v1.gguf",
    sizeBytes: 2_889_511_680,
    sha256: "3343fc1a30a3e82df7499a4775ef73dd6e28dea1cc39bb58197ec0b66ec874f6"
  )

  public var onEvent: (@MainActor @Sendable (Event) -> Void)?

  private enum Fingerprint {
    case absent
    case match
    case mismatch
    case unreadable
  }

  private let appSupportDirectory: URL
  private let defaults: UserDefaults
  private let trustedArtifact: TrustedArtifact

  private let ensureCurrentModel:
    @MainActor @Sendable () async -> ModelDeliveryController.DeliveryOutcome
  private let currentModelIsAdmitted: @MainActor @Sendable () async -> Bool

  private let hashFile: @Sendable (URL) async throws -> String
  private let writeMarker: @MainActor @Sendable (URL) -> Bool
  private let removeItem: @MainActor @Sendable (URL) throws -> Void

  private var preparationTask: Task<Bool, Never>?
  private var containmentRefused = false

  public convenience init(
    adapter: EGOneDeliveryAdapter,
    appSupportDirectory: URL,
    defaults: UserDefaults? = nil,
    trustedArtifact: TrustedArtifact = shippedLegacyArtifact
  ) {
    self.init(
      appSupportDirectory: appSupportDirectory,
      defaults: defaults
        ?? UserDefaults(suiteName: DeliveryFlags.suiteName)
        ?? .standard,
      trustedArtifact: trustedArtifact,
      ensureCurrentModel: { [weak adapter] in
        guard let adapter else {
          return .failed(DeliveryFailure(reason: .unknown, detail: "adapter_released"))
        }
        return await adapter.ensureAvailable()
      },
      currentModelIsAdmitted: { [weak adapter] in
        guard let adapter else { return false }
        return await adapter.isAdmitted()
      }
    )

    // The adapter retains these closures, and therefore this coordinator.
    // The coordinator's adapter closures above are weak: no cycle.
    adapter.installLegacyUpgradeHooks(
      beforeEnsure: { [self] in await prepareForDownload() },
      beforeDecline: { [self] in recordUserDecline() },
      onAdmitted: { [self] in handleAdmission() }
    )
  }

  /// Internal test seam. It changes no production abstraction.
  init(
    appSupportDirectory: URL,
    defaults: UserDefaults,
    trustedArtifact: TrustedArtifact,
    ensureCurrentModel:
      @escaping @MainActor @Sendable () async -> ModelDeliveryController.DeliveryOutcome,
    currentModelIsAdmitted: @escaping @MainActor @Sendable () async -> Bool,
    hashFile: (@Sendable (URL) async throws -> String)? = nil,
    writeMarker: (@MainActor @Sendable (URL) -> Bool)? = nil,
    removeItem: (@MainActor @Sendable (URL) throws -> Void)? = nil
  ) {
    self.appSupportDirectory = appSupportDirectory
    self.defaults = defaults
    self.trustedArtifact = trustedArtifact
    self.ensureCurrentModel = ensureCurrentModel
    self.currentModelIsAdmitted = currentModelIsAdmitted
    self.hashFile = hashFile ?? Self.streamingSHA256
    self.writeMarker = writeMarker ?? Self.atomicWriteMarker
    self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }
  }

  private var oldStoreDirectory: URL {
    appSupportDirectory.appendingPathComponent(
      "EnviousWispr/PolishModels", isDirectory: true)
  }

  private var legacyArtifactURL: URL {
    oldStoreDirectory.appendingPathComponent(trustedArtifact.name)
  }

  private var metadataDirectory: URL {
    appSupportDirectory.appendingPathComponent(
      "EnviousWispr/ModelDelivery", isDirectory: true)
  }

  private var owedMarkerURL: URL {
    metadataDirectory.appendingPathComponent("eg1-v1-replacement-owed")
  }

  private var isReplacementOwed: Bool {
    FileManager.default.fileExists(atPath: owedMarkerURL.path)
  }

  // C1 - One real switch for adapter and coordinator.
  private var isEnabled: Bool {
    EGOneDeliveryAdapter.isDeliveryEnabled(defaults: defaults)
  }

  // C2 - Prepare before the admitted return so an exact reintroduced monolith
  // is still retired.
  public func runLaunch() async {
    guard isEnabled else { return }

    let admitted = await currentModelIsAdmitted()

    guard await prepareForDownload(), !containmentRefused else { return }

    if admitted {
      handleAdmission()
      return
    }

    guard isReplacementOwed else { return }

    // C7 - The existing adapter/controller is the only download door.
    let outcome = await ensureCurrentModel()
    if case .admitted = outcome {
      handleAdmission()
    }
  }

  // C3 - Launch and a simultaneous Download click share one fingerprint/delete.
  func prepareForDownload() async -> Bool {
    guard isEnabled else { return false }

    if let preparationTask {
      return await preparationTask.value
    }

    let task = Task { @MainActor [self] in
      await prepareOnce()
    }
    preparationTask = task
    let result = await task.value
    preparationTask = nil
    return result
  }

  private func prepareOnce() async -> Bool {
    guard isEnabled else { return false }

    containmentRefused = false

    // C4 - Compare resolved candidate to a tree built from the resolved root.
    let resolvedRoot =
      appSupportDirectory.resolvingSymlinksInPath().standardizedFileURL
    let canonicalTree = resolvedRoot.appendingPathComponent(
      "EnviousWispr", isDirectory: true
    ).standardizedFileURL
    let resolvedOldStore =
      oldStoreDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedOldStore.path.hasPrefix(canonicalTree.path + "/") else {
      containmentRefused = true
      emit(.legacyRetirementFailed(reason: .containment))
      return true
    }

    sweepExactRetiredSidecars()

    if isReplacementOwed {
      return await retireMarkerBackedArtifactIfNeeded()
    }

    // C4 - Exact path + regular file + size + digest.
    switch await fingerprintLegacyArtifact() {
    case .absent, .mismatch:
      return true

    case .unreadable:
      emit(.legacyRetirementFailed(reason: .unreadable))
      return true

    case .match:
      emit(.legacyDetected)

      // C5 - Marker is the linearization point and precedes unlink.
      guard writeMarker(owedMarkerURL) else {
        emit(.legacyRetirementFailed(reason: .markerWrite))
        return false
      }

      do {
        // No suspension occurs between successful marker persistence and unlink.
        try removeItem(legacyArtifactURL)
      } catch {
        // C6 - Keep the marker and block the replacement.
        emit(.legacyRetirementFailed(reason: .delete))
        return false
      }

      emit(.legacyRetired)
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true
    }
  }

  private func retireMarkerBackedArtifactIfNeeded() async -> Bool {
    switch await fingerprintLegacyArtifact() {
    case .absent:
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true

    case .match:
      emit(.legacyDetected)
      do {
        try removeItem(legacyArtifactURL)
      } catch {
        emit(.legacyRetirementFailed(reason: .delete))
        return false
      }
      emit(.legacyRetired)
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true

    case .mismatch:
      // The marker proves a replacement is owed, but no longer proves these
      // changed bytes are ours. Preserve them and continue the replacement.
      return true

    case .unreadable:
      // It may still be the trusted artifact. Refuse to delete or duplicate it
      // until it can be classified.
      emit(.legacyRetirementFailed(reason: .unreadable))
      return false
    }
  }

  private func fingerprintLegacyArtifact() async -> Fingerprint {
    let url = legacyArtifactURL
    let fm = FileManager.default

    guard fm.fileExists(atPath: url.path) else { return .absent }

    let values: URLResourceValues
    do {
      values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    } catch {
      return .unreadable
    }

    guard values.isSymbolicLink != true,
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      Int64(fileSize) == trustedArtifact.sizeBytes
    else {
      return .mismatch
    }

    do {
      return try await hashFile(url) == trustedArtifact.sha256 ? .match : .mismatch
    } catch {
      return .unreadable
    }
  }

  private func sweepExactRetiredSidecars() {
    for name in [
      "\(trustedArtifact.name).partial",
      "\(trustedArtifact.name).resume.json",
    ] {
      let url = oldStoreDirectory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        try? removeItem(url)
      }
    }
    removeOldStoreIfEmpty()
  }

  private func cleanRetiredStoreMetadataAfterProvenOwnership() {
    for name in [
      "installed-manifest.json",
      "\(trustedArtifact.name).partial",
      "\(trustedArtifact.name).resume.json",
    ] {
      let url = oldStoreDirectory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        try? removeItem(url)
      }
    }
    removeOldStoreIfEmpty()
  }

  private func removeOldStoreIfEmpty() {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: oldStoreDirectory,
        includingPropertiesForKeys: nil
      ),
      entries.isEmpty
    else {
      return
    }
    try? removeItem(oldStoreDirectory)
  }

  // C8 - Admission clears the marker only while model delivery is enabled and
  // preparation did not refuse the old-store topology.
  private func handleAdmission() {
    guard isEnabled, !containmentRefused else { return }
    let wasOwed = isReplacementOwed
    guard clearOwedMarker() else { return }
    if wasOwed {
      emit(.replacementCompleted)
    }
  }

  // C9 - Explicit Cancel/Remove records decline even while delivery is off.
  func recordUserDecline() -> Bool {
    let wasOwed = isReplacementOwed
    guard clearOwedMarker() else { return false }
    if wasOwed {
      emit(.replacementDeclined)
    }
    return true
  }

  @discardableResult
  private func clearOwedMarker() -> Bool {
    guard isReplacementOwed else { return true }
    do {
      try removeItem(owedMarkerURL)
      return true
    } catch {
      return false
    }
  }

  // C10 - Typed, bounded, content-free events.
  private func emit(_ event: Event) {
    onEvent?(event)
  }

  private static func atomicWriteMarker(_ url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private nonisolated static func streamingSHA256(of url: URL) async throws -> String {
    try await Task.detached(priority: .utility) {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      var hasher = SHA256()
      while true {
        try Task.checkCancellation()
        let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }.value
  }
}
