/// #2664. Every string the microphone socket control shows, in one place,
/// frozen by `InputSocketCopyTests`. Shown only for a device reporting more than
/// one input. Stored values are 0-based; the labels count from 1 the way the
/// sockets on the box do. No dashes anywhere (content rule).
enum InputSocketCopy {
  /// The short label in front of the control, on the device picker's own line.
  static let label = "Mic is on"

  static func optionLabel(index: Int) -> String {
    "Input \(index + 1)"
  }

  /// The one quiet line under the row: the choice is per device.
  static func helper(deviceName: String) -> String {
    "Remembered for \(deviceName)."
  }
}
