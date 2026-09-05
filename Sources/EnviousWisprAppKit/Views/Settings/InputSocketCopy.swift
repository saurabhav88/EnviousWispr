/// #2664. Every string the "Microphone socket" row shows, in one place, frozen
/// by `InputSocketCopyTests`. Shown only for a device reporting more than one
/// input. Stored values are 0-based; the labels count from 1 the way the
/// sockets on the box do. No dashes anywhere (content rule).
enum InputSocketCopy {
  static let header = "Microphone socket"

  static func optionLabel(index: Int) -> String {
    "Input \(index + 1)"
  }

  static func helper(inputCount: Int, deviceName: String) -> String {
    "This device has \(inputCount) inputs. Pick the one your microphone is plugged into. "
      + "EnviousWispr remembers this for \(deviceName)."
  }
}
