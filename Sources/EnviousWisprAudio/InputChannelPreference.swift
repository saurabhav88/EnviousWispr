/// #2664. Which device input channel (0-based) the mono capture should take.
///
/// The one authority for the channel INDEX: HAL prepare applies it, the
/// warm-reuse predicate compares against it, and the settings row displays it.
/// Pure: (requested, available) -> effective. Never throws; a stale, absent or
/// out-of-range preference is channel 0, which is exactly today's behaviour
/// (AUHAL's mono client format takes device channel 0 when no map is set).
///
/// `public` because AppKit's settings row calls it too, so a saved index the
/// device no longer has is SHOWN as Input 1 rather than as a socket that does
/// not exist.
public enum InputChannelPreference {
  public static func effectiveChannel(requested: Int?, availableChannels: Int?) -> Int {
    guard let requested, requested > 0,
      let availableChannels, requested < availableChannels
    else { return 0 }
    return requested
  }

  /// The ONE way a device's saved choice is looked up. A device whose UID could
  /// not be read (nil, or the empty string `AudioDeviceEnumerator` substitutes)
  /// has NO saved choice: an empty key would otherwise be shared by every such
  /// device, and a choice made on one would be applied to another. Every reader
  /// (cold prepare, warm reuse, the settings row) goes through here.
  public static func requested(for deviceUID: String?, in preference: [String: Int]) -> Int? {
    guard let deviceUID, !deviceUID.isEmpty else { return nil }
    return preference[deviceUID]
  }
}
