import Foundation
import os

/// Off-main cache for `volumeAvailableCapacityForImportantUsageKey` (#4893).
public final class VolumeSpaceCache: Sendable {
  public static let shared = VolumeSpaceCache()

  private struct Entry: Sendable {
    let bytes: Int64?
    let generation: UInt64
  }
  private struct State: Sendable {
    var nextGeneration: UInt64 = 0
    var inFlightPaths: Set<String> = []
    var latestRequestedGeneration: [String: UInt64] = [:]
    var entries: [String: Entry] = [:]
  }

  private let readPlain: @Sendable (String) -> Int64?
  private let readImportant: @Sendable (String) -> Int64?
  private let queue = DispatchQueue(label: "com.enviouswispr.volume-space-cache", qos: .utility)
  private let state = OSAllocatedUnfairLock(initialState: State())
  #if DEBUG
    private let publishHook = OSAllocatedUnfairLock<(@Sendable (String, UInt64) -> Void)?>(initialState: nil)
    public func installPublishHookForTesting(_ hook: (@Sendable (String, UInt64) -> Void)?) { publishHook.withLock { $0 = hook } }
  #endif

  public convenience init() {
    self.init(
      readPlain: { Self.resourceValues(at: $0, key: .volumeAvailableCapacityKey)?.volumeAvailableCapacity.map(Int64.init) },
      readImportant: { Self.resourceValues(at: $0, key: .volumeAvailableCapacityForImportantUsageKey)?.volumeAvailableCapacityForImportantUsage })
  }

  public init(readPlain: @escaping @Sendable (String) -> Int64?, readImportant: @escaping @Sendable (String) -> Int64?) {
    self.readPlain = readPlain
    self.readImportant = readImportant
  }

  public func plainBytes(at path: String) -> Int64? { readPlain(path) }

  @discardableResult
  public func requestRefresh(at path: String) -> UInt64 {
    let (shouldEnqueue, gen) = state.withLock { s in
      s.nextGeneration &+= 1
      let reqGen = s.nextGeneration
      s.latestRequestedGeneration[path] = reqGen
      guard !s.inFlightPaths.contains(path) else { return (false, reqGen) }
      s.inFlightPaths.insert(path)
      return (true, reqGen)
    }
    if shouldEnqueue { enqueueWorker(for: path) }
    return gen
  }

  private func enqueueWorker(for path: String) {
    queue.async { [self] in
      guard let snapGen = self.state.withLock({ $0.latestRequestedGeneration[path] }) else {
        _ = self.state.withLock { $0.inFlightPaths.remove(path) }
        return
      }
      let bytes = self.readImportant(path)
      let requeue = self.state.withLock { s -> Bool in
        s.entries[path] = Entry(bytes: bytes, generation: snapGen)
        if let latest = s.latestRequestedGeneration[path], latest > snapGen { return true }
        s.inFlightPaths.remove(path)
        return false
      }
      #if DEBUG
        self.publishHook.withLock { $0 }?(path, snapGen)
      #endif
      if requeue { self.enqueueWorker(for: path) }
    }
  }

  public func importantBytes(at path: String, minGeneration: UInt64 = 0) -> Int64? {
    state.withLock { s in
      guard let entry = s.entries[path], entry.generation >= minGeneration else { return nil }
      return entry.bytes
    }
  }

  public func availableBytes(at path: String, neededBytes: Int64, minGeneration: UInt64 = 0) -> Int64? {
    if let plain = readPlain(path), plain >= neededBytes { return plain }
    return importantBytes(at: path, minGeneration: minGeneration)
  }

  private static func resourceValues(at path: String, key: URLResourceKey) -> URLResourceValues? {
    var url = URL(filePath: path, directoryHint: .isDirectory)
    url.removeAllCachedResourceValues()
    return try? url.resourceValues(forKeys: [key])
  }
}
