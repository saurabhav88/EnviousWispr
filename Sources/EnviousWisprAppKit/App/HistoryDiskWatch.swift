import CoreServices
import Foundation

/// Other-process changes (restores, edits by an older app) enter the same reconciliation
/// path as a dropped source notification. Local store writes have their own numbered feed.
final class HistoryDiskWatch {
  private let stream: FSEventStreamRef

  init?(directories: [URL], changed: @escaping @Sendable () -> Void) {
    let token = Unmanaged.passRetained(Callback(roots: directories.map(\.path), changed))
    var context = FSEventStreamContext(
      version: 0, info: token.toOpaque(), retain: nil,
      release: { value in
        if let value { Unmanaged<Callback>.fromOpaque(value).release() }
      }, copyDescription: nil)
    let origins = directories.map(\.path) as CFArray
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
    guard let stream = FSEventStreamCreate(
      nil, { _, info, count, paths, flags, _ in
        guard let info else { return }
        let sink = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
        let urls = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let unknown = FSEventStreamEventFlags(
          kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        for index in 0..<count {
          if flags[index] & unknown != 0 {
            sink.changed()
            return
          }
          guard let bytes = urls[index] else { continue }
          let path = String(cString: bytes)
          if sink.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            sink.changed()
            return
          }
        }
      }, &context, origins, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
    else {
      token.release()
      return nil
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.enviouswispr.history.files", qos: .utility))
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    self.stream = stream
  }

  deinit {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  private final class Callback: Sendable {
    let roots: [String]
    let changed: @Sendable () -> Void

    init(roots: [String], _ changed: @escaping @Sendable () -> Void) {
      self.roots = Array(roots.prefix(2))
      self.changed = changed
    }
  }
}
