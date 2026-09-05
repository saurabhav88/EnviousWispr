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
/// All five fields are read together in HAL's single all-succeeded commit block
/// and cleared together in its single teardown, so they are ONE fact with one
/// lifetime, not five accessors that could drift apart.
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

  /// WHY this device was chosen, frozen at resolution time (#1714):
  /// `pinned_uid`, `system_default` or `list_fallback`.
  ///
  /// **Non-optional and undefaulted, deliberately.** Cold resolution normally
  /// happens during `preWarm()`, which discards the bind it gets back, and the
  /// recording that follows takes the WARM path — so by the time a take
  /// completes, nothing else on the session still knows why this microphone was
  /// picked. Riding on the bind is what carries the fact across that gap. An
  /// optional or defaulted field would let a conformer commit a bind without
  /// saying why and still compile, and the attribution would silently read
  /// `system_default` for every fallback take — which is precisely the metric
  /// #1714 ships to prove the fix works.
  ///
  /// A low-cardinality `String`, not the resolver enum: `AudioCaptureInterface`
  /// is `public`, and a public requirement cannot expose a package type.
  public let resolutionSource: String

  /// #2664: the device input channel (0-based) the mono capture ACTUALLY took.
  /// 0 is the default (no channel map set). Set only in HAL's committed block,
  /// from the channel-map property set's own result, so a map the unit refused
  /// reads 0 here — never the channel the user asked for. The warm-reuse
  /// predicate compares this to the CURRENT preference; a mismatch rebuilds.
  ///
  /// **Undefaulted, deliberately** — the `resolutionSource` reasoning above
  /// applies unchanged: a defaulted field would let a conformer commit a bind
  /// without saying which channel it recorded, and a reuse decision built on
  /// that silence would keep a stale channel warm across a settings change.
  public let inputChannel: Int

  public init(
    deviceID: AudioDeviceID, deviceUID: String?, transportLabel: String?, resolutionSource: String,
    inputChannel: Int
  ) {
    self.deviceID = deviceID
    self.deviceUID = deviceUID
    self.transportLabel = transportLabel
    self.resolutionSource = resolutionSource
    self.inputChannel = inputChannel
  }
}
