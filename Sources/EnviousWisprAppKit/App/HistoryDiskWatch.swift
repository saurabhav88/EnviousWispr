import CoreServices
import EnviousWisprStorage
import Foundation

/// Other-process changes (restores, edits by an older app) enter the same reconciliation
/// path as a dropped source notification. Local store writes have their own numbered feed.
///
/// #4598: one watcher per session. It reports what each notice proves, so the session can
/// re-check one source instead of all of them, and it reports a replaced or late-created root
/// itself (`kFSEventStreamCreateFlagWatchRoot`), so nothing re-creates it per notice. Building it
/// registers with `fseventsd` and can block for seconds when that daemon is busy, so callers
/// construct it off the main actor. The stream is immutable after `init` and touched again only
/// in `deinit`; that is what makes the type safe to hand from the building task to its owner.
final class HistoryDiskWatch: @unchecked Sendable {
  enum Event: Hashable, Sendable {
    /// A notice for a path: the narrowest scope it proves.
    case scope(HistorySourceChanges.Scope)
    /// The kernel or daemon dropped events below a root: every source must be re-checked.
    case rescan
    /// A watched root was created, moved, deleted or replaced: re-register, then re-check all.
    case rootChanged
  }

  private let stream: FSEventStreamRef

  init?(
    directories: [URL], scope: @escaping @Sendable (String) -> HistorySourceChanges.Scope?,
    changed: @escaping @Sendable (Set<Event>) -> Void
  ) {
    let token = Unmanaged.passRetained(Callback(scope: scope, changed: changed))
    var context = FSEventStreamContext(
      version: 0, info: token.toOpaque(), retain: nil,
      release: { value in
        if let value { Unmanaged<Callback>.fromOpaque(value).release() }
      }, copyDescription: nil)
    let origins = directories.map(\.path) as CFArray
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagIgnoreSelf)
    guard
      let stream = FSEventStreamCreate(
        nil,
        { _, info, count, paths, flags, _ in
          guard let info else { return }
          let sink = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
          let urls = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
          var events = Set<Event>()
          for index in 0..<count {
            let flag = flags[index]
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
              events.insert(.rootChanged)
              continue
            }
            if flag
              & FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                  | kFSEventStreamEventFlagKernelDropped) != 0
            {
              events.insert(.rescan)
              continue
            }
            guard let bytes = urls[index] else {
              events.insert(.rescan)
              continue
            }
            if let scope = sink.scope(String(cString: bytes)) {
              events.insert(.scope(scope))
            }
          }
          if !events.isEmpty { sink.changed(events) }
        }, &context, origins, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
    else {
      token.release()
      return nil
    }
    FSEventStreamSetDispatchQueue(
      stream, DispatchQueue(label: "com.enviouswispr.history.files", qos: .utility))
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
    let scope: @Sendable (String) -> HistorySourceChanges.Scope?
    let changed: @Sendable (Set<Event>) -> Void

    init(
      scope: @escaping @Sendable (String) -> HistorySourceChanges.Scope?,
      changed: @escaping @Sendable (Set<Event>) -> Void
    ) {
      self.scope = scope
      self.changed = changed
    }
  }
}
