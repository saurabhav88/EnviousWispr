import Darwin
import Foundation

/// The Share extension and the containing app compile this same transfer contract.
/// An offered file can be claimed once. The importer holds the claim until it finishes reading.
package struct SharedMediaTransfer: Sendable {
  private static let directoryName = "Shared Media"
  private static let groupKey = "EWSharedMediaGroup"
  private static let offeredName = "offered"
  private static let claimedName = "claimed"
  private static let metadataName = "offer.json"
  private static let lockName = "lease"
  // An orphan is only eligible on a later Share. Twenty-four hours is a retention rule,
  // not a handoff deadline. A live writer or reader keeps its lease regardless of age.
  static let retention: TimeInterval = 86_400

  enum TransferError: Error {
    case invalid
    case unavailable
  }

  package final class Claim: Sendable {
    package let url: URL
    package let displayName: String

    private let directory: URL
    private let descriptor: Int32

    fileprivate init(url: URL, displayName: String, directory: URL, descriptor: Int32) {
      self.url = url
      self.displayName = displayName
      self.directory = directory
      self.descriptor = descriptor
    }

    deinit {
      try? FileManager.default.removeItem(at: directory)
      close(descriptor)
    }
  }

  private struct Offer: Codable {
    let name: String
    let receiver: String
  }

  let root: URL

  package static func live() -> Self? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: groupKey) as? String,
      !group.isEmpty,
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return Self(root: container.resolvingSymlinksInPath().appendingPathComponent(directoryName))
  }

  func offer(_ source: URL, suffix: String, suggestedName: String?, receiver: URL) throws -> URL {
    let files = FileManager.default
    guard Self.isRegular(source), !suffix.isEmpty,
      suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    else { throw TransferError.invalid }

    try files.createDirectory(at: root, withIntermediateDirectories: true)
    guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
      throw TransferError.invalid
    }
    retireExpired()
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: false)

    guard let descriptor = Self.lock(directory, create: true) else {
      try? files.removeItem(at: directory)
      throw TransferError.unavailable
    }
    var published = false
    defer {
      if !published { try? files.removeItem(at: directory) }
      close(descriptor)
    }
    let partial = directory.appendingPathComponent("partial")
    let destination = directory.appendingPathComponent(Self.offeredName)
      .appendingPathExtension(suffix)
    try files.copyItem(at: source, to: partial)
    var name = (suggestedName ?? source.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { name = source.lastPathComponent }
    let offer = Offer(name: String(name.prefix(255)), receiver: receiver.resolvingSymlinksInPath().path)
    try JSONEncoder().encode(offer).write(to: directory.appendingPathComponent(Self.metadataName))
    try files.moveItem(at: partial, to: destination)
    published = true
    return destination
  }

  package func recognizes(_ url: URL) -> Bool {
    offeredDirectory(for: url) != nil
  }

  package func claim(_ url: URL, receiver: URL = Bundle.main.bundleURL) -> Claim? {
    guard let directory = offeredDirectory(for: url),
      let descriptor = Self.lock(directory)
    else { return nil }
    guard !isExpired(directory), Self.isRegular(url) else {
      close(descriptor)
      return nil
    }

    let destination = directory.appendingPathComponent(Self.claimedName)
      .appendingPathExtension(url.pathExtension)
    do {
      let metaURL = directory.appendingPathComponent(Self.metadataName)
      guard Self.isRegular(metaURL) else { throw TransferError.invalid }
      let offer = try JSONDecoder().decode(Offer.self, from: Data(contentsOf: metaURL))
      guard offer.receiver == receiver.resolvingSymlinksInPath().path else {
        throw TransferError.invalid
      }
      try FileManager.default.moveItem(at: url, to: destination)
      return Claim(
        url: destination, displayName: offer.name, directory: directory, descriptor: descriptor)
    } catch {
      close(descriptor)
      return nil
    }
  }

  /// Called if Launch Services rejects the notification. A claimed file is someone else's work.
  @discardableResult
  func discardOffer(_ url: URL) -> Bool {
    guard let directory = offeredDirectory(for: url), let descriptor = Self.lock(directory)
    else { return false }
    defer { close(descriptor) }
    guard Self.isRegular(url) else { return false }
    do {
      try FileManager.default.removeItem(at: directory)
      return true
    } catch {
      return false
    }
  }

  private func offeredDirectory(for url: URL) -> URL? {
    guard url.isFileURL, url.deletingPathExtension().lastPathComponent == Self.offeredName,
      !url.pathExtension.isEmpty
    else { return nil }
    let directory = url.deletingLastPathComponent()
    guard directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
      UUID(uuidString: directory.lastPathComponent) != nil,
      directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path
    else { return nil }
    return directory
  }

  package func retireExpired() {
    let files = FileManager.default
    guard let children = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    else { return }
    for directory in children {
      guard UUID(uuidString: directory.lastPathComponent) != nil, isExpired(directory),
        directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
        let descriptor = Self.lock(directory, create: true)
      else { continue }

      if isExpired(directory) { try? files.removeItem(at: directory) }
      close(descriptor)
    }
  }

  private func isExpired(_ directory: URL) -> Bool {
    guard let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate
    else { return true }
    return Date().timeIntervalSince(created) >= Self.retention
  }

  private static func isRegular(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink == false
  }

  private static func lock(_ directory: URL, create: Bool = false) -> Int32? {
    var flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
    if create { flags |= O_CREAT }
    let descriptor = open(directory.appendingPathComponent(lockName).path, flags, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    return descriptor
  }
}
