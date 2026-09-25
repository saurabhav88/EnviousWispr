/// #2664. Every string the microphone socket control shows, in one place,
/// frozen by `InputSocketCopyTests`. Shown only for a device reporting more than
/// one input. Stored values are 0-based; the labels count from 1 the way the
/// sockets on the box do. No dashes anywhere (content rule).
enum InputSocketCopy {
  /// The short label in front of the control, on the device picker's own line.
  static let label = String(
    localized: "Mic is on",
    comment:
      "Microphone settings, input socket (for a device with several inputs): label before the choice of input, as in Mic is on Input 2."
  )

  static func optionLabel(index: Int) -> String {
    String(
      localized: "Input \(index + 1)",
      comment:
        "Microphone settings, input socket (for a device with several inputs): one input of the device. %lld is its number."
    )
  }

  /// The one quiet line under the row: the choice is per device.
  static func helper(deviceName: String) -> String {
    String(
      localized: "Remembered for \(deviceName).",
      comment:
        "Microphone settings, input socket (for a device with several inputs): the choice is saved per device. %@ is the device's name."
    )
  }
}
