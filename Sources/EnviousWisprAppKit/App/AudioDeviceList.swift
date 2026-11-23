import CoreAudio
import EnviousWisprAudio
import Observation

/// Manages the list of available audio input devices, refreshing automatically on hardware changes.
///
/// #4021: the list is read on `CoreAudioQueryLane`, never on the main actor. A third-party audio
/// driver that stops answering used to freeze the whole app here (main thread stuck in
/// `allInputDevices()` -> `AudioObjectGetPropertyData` -> `mach_msg`). Now a read that cannot
/// answer leaves the last accepted snapshot in place, and the list refreshes again once the lane
/// is free. The last accepted facts may stay stale for as long as a read is stuck.
@MainActor @Observable
final class AudioDeviceList {
  var availableInputDevices: [AudioInputDevice] = []
  /// The last accepted snapshot: a successful list read, possibly partial. Nil until the first.
  private(set) var snapshot: AudioDeviceSnapshot?
  var hasSnapshot: Bool { snapshot != nil }

  /// The list plus the snapshot's Auto device and transport tokens, for the picker and menu.
  /// The device list itself comes from `availableInputDevices` (fixtures assign it directly);
  /// facts the snapshot does not hold stay unavailable rather than triggering a live read.
  var microphoneFacts: MicrophoneFacts {
    var tokens: [AudioDeviceID: String] = [:]
    for device in snapshot?.devices ?? [] {
      if let label = device.transportLabel { tokens[device.id] = label }
    }
    return MicrophoneFacts(
      devices: availableInputDevices, resolvedAutoDeviceID: snapshot?.resolvedAutoDeviceID,
      transportTokens: tokens)
  }

  /// Called with the list ONLY when the accepted inventory proves absence
  /// (`AudioDeviceSnapshot.provesAbsence`), so a partial or failed read can never make a
  /// pinned microphone look disconnected.
  var onDevicesChanged: (([AudioInputDevice]) -> Void)?
  /// Called after every accepted snapshot is applied, complete or partial.
  var onSnapshotApplied: (() -> Void)?
  /// Called when each read finishes, with its outcome, after any snapshot was applied.
  var onReadFinished: ((ReadResult) -> Void)?

  /// How one read ended, for `onReadFinished`.
  enum ReadResult: Equatable {
    case applied
    case listReadFailed
    case timedOut
    case busy
  }

  /// The shared Core Audio lane. Other idle-time reads (microphone-choice validation) use the
  /// same one so only one read can ever be stuck.
  let lane: CoreAudioQueryLane
  /// The shared microphone-choice owner, built and kept by `WisprBootstrapper` on this same lane
  /// and only exposed here so the pickers reach it without another environment object.
  let choices: MicrophoneChoiceOwner

  @ObservationIgnored private let read: @Sendable () -> AudioDeviceSnapshot
  @ObservationIgnored private var deviceMonitor: AudioDeviceMonitor?
  /// One read in flight at a time; requests during it coalesce into one pending refresh.
  @ObservationIgnored private var inFlight = false
  @ObservationIgnored private var pendingRefresh = false
  /// At most one outstanding availability wake-up, so events during a stuck read never pile up
  /// callbacks. The wake-up is a chance to retry, not a reservation of the lane.
  @ObservationIgnored private var awaitingLane = false

  /// - Parameter startReading: false builds a fixture that never reads Core Audio or listens
  ///   for device changes (tests assign `availableInputDevices` directly).
  init(
    lane: CoreAudioQueryLane = CoreAudioQueryLane(),
    choices: MicrophoneChoiceOwner,
    read: @escaping @Sendable () -> AudioDeviceSnapshot = { AudioDeviceSnapshotReader.read() },
    startReading: Bool = true
  ) {
    self.lane = lane
    self.choices = choices
    self.read = read
    guard startReading else { return }
    deviceMonitor = AudioDeviceMonitor { [weak self] in
      Task { @MainActor in self?.requestRefresh() }
    }
    requestRefresh()
  }

  /// Ask for a fresh snapshot. Coalesces with a read already in flight.
  func requestRefresh() {
    if inFlight {
      pendingRefresh = true
      return
    }
    inFlight = true
    pendingRefresh = false
    let lane = lane
    let read = read
    Task { [weak self] in
      let outcome = await lane.bounded("device_snapshot", read)
      self?.finish(outcome)
    }
  }

  private func finish(_ outcome: CoreAudioQueryLane.Outcome<AudioDeviceSnapshot>) {
    inFlight = false
    let result: ReadResult
    switch outcome {
    case .value(let snapshot):
      // A list-read failure proves nothing: keep the previous facts and notify no one.
      if snapshot.listReadSucceeded {
        apply(snapshot)
        result = .applied
      } else {
        result = .listReadFailed
      }
    case .timedOut:
      // No answer. The abandoned read still holds the lane; its value is never published (the
      // lane resumed this caller with `.timedOut` exactly once). Retry once the lane is free,
      // with no further device event needed.
      pendingRefresh = true
      result = .timedOut
    case .busy:
      // Another lane user (a stuck read or a choice validation) holds the lane. Same retry.
      pendingRefresh = true
      result = .busy
    }
    onReadFinished?(result)
    guard pendingRefresh, !awaitingLane else { return }
    awaitingLane = true
    lane.whenAvailable { [weak self] in
      Task { @MainActor in self?.laneBecameAvailable() }
    }
  }

  private func laneBecameAvailable() {
    awaitingLane = false
    // Re-check main-actor state: a request may already have started a read meanwhile.
    guard pendingRefresh, !inFlight else { return }
    requestRefresh()
  }

  private func apply(_ snapshot: AudioDeviceSnapshot) {
    self.snapshot = snapshot
    availableInputDevices = snapshot.displayDevices
    onSnapshotApplied?()
    if snapshot.provesAbsence {
      onDevicesChanged?(availableInputDevices)
    }
  }
}
