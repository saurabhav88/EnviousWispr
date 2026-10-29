import CoreAudio
import Darwin
import EnviousWisprCore
import Foundation

/// Watches which call-app processes hold the microphone (#4012 §3.1, R7, R12).
///
/// Reads Core Audio process objects (macOS 14.2+): the process list, and per process its
/// bundle identifier, pid and `IsRunningInput`. Listeners on per-process input are unreliable
/// (Apple forum 770348; Home Assistant iOS #5635), so it listens to the process list and the
/// coordinator polls it every 2 seconds while a call may be on. Every poll reports a whole
/// `Reading`: when the list cannot be read it is incomplete, and a process that may be a call
/// app but cannot be named makes it ambiguous. Nothing is remembered between readings, so a
/// failed read is never turned into "off" or into an old answer. Which processes count is the
/// injected filter: this module owns no app list.
///
/// The Core Audio and process reads run on the watcher's own serial queue (#4013 13B), never on
/// the main actor; readings come back to the main queue in the order they were taken.
@MainActor
public final class CallMicrophoneWatcher {
  public enum Input: Sendable, Equatable { case active, inactive, unknown }

  public struct Holder: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let input: Input
    /// The Core Audio process object: a new one for every run of a process, so it tells a
    /// relaunched process from the one before even when the pid comes back.
    public let object: UInt32

    public init(pid: Int32, bundleID: String, input: Input, object: UInt32 = 0) {
      self.pid = pid
      self.bundleID = bundleID
      self.input = input
      self.object = object
    }
  }

  public struct Reading: Sendable, Equatable {
    /// The process list was read; when false, `holders` is empty and proves nothing.
    public let complete: Bool
    public let holders: [Holder]
    /// A process that may be a call app could not be named, and its microphone was on or
    /// unreadable.
    public let ambiguous: Bool

    public init(complete: Bool, holders: [Holder], ambiguous: Bool = false) {
      self.complete = complete
      self.holders = holders
      self.ambiguous = ambiguous
    }

    public static let failed = Reading(complete: false, holders: [])
  }

  /// `candidateBundleID(bundleID, executablePath)`: the bundle identifier to report for a
  /// process (its own, or its owning app's for a helper), or nil when it is not a call app.
  public typealias CandidateFilter = @Sendable (String, String?) -> String?
  /// `mayBeCandidate(bundleID)`: whether a process whose executable cannot be read may still
  /// be a call app.
  public typealias UnnamedFilter = @Sendable (String?) -> Bool

  /// macOS 14.2 added the process objects; below it the watcher never starts.
  public static var isSupported: Bool {
    if #available(macOS 14.2, *) { return true }
    return false
  }

  private let candidateBundleID: CandidateFilter
  private let mayBeCandidate: UnnamedFilter
  private let onReading: @MainActor (Reading) -> Void
  private var listener: AudioObjectPropertyListenerBlock?
  private let ownPID = getpid()
  private let queue = DispatchQueue(label: "com.enviouswispr.call-microphone-watcher", qos: .utility)

  public init(
    candidateBundleID: @escaping CandidateFilter,
    mayBeCandidate: @escaping UnnamedFilter,
    onReading: @escaping @MainActor (Reading) -> Void
  ) {
    self.candidateBundleID = candidateBundleID
    self.mayBeCandidate = mayBeCandidate
    self.onReading = onReading
  }

  /// Whether the process-list listener is registered; without it the caller polls all the time.
  public var isListening: Bool { listener != nil }

  public func start() {
    guard Self.isSupported, listener == nil else { return }
    var address = Self.processListAddress
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.poll() }
    }
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr
    {
      listener = block
    }
    poll()
  }

  public func stop() {
    if let listener {
      var address = Self.processListAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    }
    listener = nil
  }

  /// Reads now (a process-list change, a poll, a wake from sleep) off the main actor, then
  /// reports the reading on the main queue and calls `done` after it. Readings are reported in
  /// the order the polls were asked for.
  public func poll(done: (@MainActor () -> Void)? = nil) {
    let candidateBundleID = candidateBundleID
    let mayBeCandidate = mayBeCandidate
    let ownPID = ownPID
    queue.async { [weak self] in
      let reading = Self.read(
        candidateBundleID: candidateBundleID, mayBeCandidate: mayBeCandidate, ownPID: ownPID)
      // The main queue keeps the order the serial queue produced them in.
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.onReading(reading)
          done?()
        }
      }
    }
  }

  /// `poll`, awaited until its reading was reported.
  public func pollAndWait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      poll { continuation.resume() }
    }
  }

  private nonisolated static func read(
    candidateBundleID: CandidateFilter, mayBeCandidate: UnnamedFilter, ownPID: pid_t
  ) -> Reading {
    guard let objects = Self.processObjects() else { return .failed }
    var holders: [Holder] = []
    var ambiguous = false
    for object in objects {
      let ownBundle = Self.string(object, kAudioProcessPropertyBundleID)
      let pid = Self.pid(of: object)
      if let pid, pid == ownPID { continue }
      let path = pid.flatMap(Self.executablePath)
      if let bundle = candidateBundleID(ownBundle ?? "", path) {
        if let pid {
          holders.append(
            Holder(pid: pid, bundleID: bundle, input: Self.input(of: object), object: object))
        } else if Self.input(of: object) != .inactive {
          // A call app whose process cannot be read: it can never start a call, and while it
          // may hold the microphone no call is confirmed over (review r14 F1).
          ambiguous = true
        }
        continue
      }
      // Not a call app as far as could be read; only an unread executable leaves doubt.
      if path == nil, mayBeCandidate(ownBundle), Self.input(of: object) != .inactive {
        ambiguous = true
      }
    }
    return Reading(
      complete: true, holders: holders.sorted { $0.pid < $1.pid }, ambiguous: ambiguous)
  }

  // MARK: - Core Audio reads

  private nonisolated static var processListAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  private nonisolated static func processObjects() -> [AudioObjectID]? {
    var address = processListAddress
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      return nil
    }
    guard size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
      return nil
    }
    // The list can shrink between the two calls; only what Core Audio wrote counts (#1714).
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  private nonisolated static func input(of object: AudioObjectID) -> Input {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return .unknown
    }
    return value != 0 ? .active : .inactive
  }

  private nonisolated static func pid(of object: AudioObjectID) -> Int32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var pid: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0
    else { return nil }
    return pid
  }

  private nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    let text = value.takeRetainedValue() as String
    return text.isEmpty ? nil : text
  }

  private nonisolated static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
  }
}
