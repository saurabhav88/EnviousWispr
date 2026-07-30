import CoreAudio

/// #1844: the input device a capture source ACTUALLY OPENED.
///
/// This is the RETURN VALUE of `AudioInputSource.prepare()`, deliberately, not a
/// property to be read afterwards. The bug this type exists to kill was an
/// ORDERING bug: the manager froze a device for the zero-signal health check one
/// synchronous turn BEFORE `prepare()` committed the bind, so the health verdict
/// could describe a microphone the session never recorded from. Returning the
/// bind makes "read it before it exists" unexpressible rather than merely tested.
///
/// All three fields are read together in HAL's single all-succeeded commit block
/// and cleared together in its single teardown, so they are ONE fact with one
/// lifetime — not three accessors that could drift apart.
///
/// **Visibility.** `public` is the NARROWEST WORKING visibility, not a default.
/// `AudioCaptureInterface` is already `public` (`AudioCaptureInterface.swift:7`)
/// and carries this type as a requirement, and a public protocol requirement
/// cannot expose a `package` type. Verified by compile probe, not asserted:
/// `property cannot be declared public because its type uses a package type`.
/// Narrowing the whole protocol to `package` is a separate refactor.
public struct BoundInputDevice: Equatable, Sendable {
  /// The CoreAudio device the AudioUnit was pointed at.
  public let deviceID: AudioDeviceID

  /// The device's persistent UID AT BIND TIME. `AudioDeviceID` is a runtime
  /// handle that CoreAudio may reuse for a different device after a replug, so
  /// a numeric match alone is not identity: the health check re-reads the UID
  /// and refuses if it no longer matches this one. nil when the UID could not
  /// be read at bind, which also fails closed.
  public let deviceUID: String?

  /// Low-cardinality transport label at bind time, for route telemetry. A
  /// SNAPSHOT of `HALDeviceInputSource.boundTransport`, which remains the
  /// authority; this is not a second home for the fact.
  public let transportLabel: String?

  public init(deviceID: AudioDeviceID, deviceUID: String?, transportLabel: String?) {
    self.deviceID = deviceID
    self.deviceUID = deviceUID
    self.transportLabel = transportLabel
  }
}
