/// One Secure Input state the keyboard listener observed (#3544 P3, plan amendment A2).
///
/// `enabled` is the OS's answer (`IsSecureEventInputEnabled`). `ownerPID` is best effort: the
/// process the current session names as holding Secure Input, or nil when that could not be read.
/// An unknown owner never means Secure Input is off.
package struct SecureInputObservation: Sendable, Equatable {
  package let enabled: Bool
  package let ownerPID: Int32?

  package init(enabled: Bool, ownerPID: Int32?) {
    self.enabled = enabled
    // An owner only exists while Secure Input is on.
    self.ownerPID = enabled ? ownerPID : nil
  }
}

/// Turns repeated samples into changes: the first sample of an installation is always a change
/// (so a state already on at launch is reported), and after that only a different enabled state
/// or, while enabled, a different owner is. The listener's worker owns one per installation.
package struct SecureInputChangeDetector: Sendable {
  private var last: SecureInputObservation?

  package init() {}

  /// The observation to report for this sample, or nil when nothing changed.
  package mutating func sample(enabled: Bool, ownerPID: Int32?) -> SecureInputObservation? {
    let observation = SecureInputObservation(enabled: enabled, ownerPID: ownerPID)
    guard observation != last else { return nil }
    last = observation
    return observation
  }
}
