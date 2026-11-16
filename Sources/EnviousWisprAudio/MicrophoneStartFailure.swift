import CoreAudio

/// #4601 §3.7: the ONE decision "this microphone start failed because the audio system did not
/// answer". Dictation's start paths and the meeting start all ask it, each keeping its own
/// precedence (permission first) in front of it.
///
/// It means one of: the start did not finish within its five-second budget, a start was refused
/// because an earlier audio call is still past its deadline, or macOS returned OSStatus 60 from
/// starting the unit. The app does not know the cause; customer copy says another app's driver
/// "may" be stuck.
public enum MicrophoneStartFailure {
  /// The step whose OSStatus 60 counts as not responding. Only the unit start: the same status
  /// from any other step keeps its generic treatment.
  static let startStep = "HALDeviceInputSource.prepare.start"
  static let notRespondingStatus: OSStatus = 60

  public static func isNotResponding(_ error: any Error) -> Bool {
    guard let audioError = error as? AudioError else { return false }
    switch audioError {
    case .microphoneNotResponding:
      return true
    case .formatCreationFailed(let source, let osStatus):
      return source == startStep && osStatus == notRespondingStatus
    default:
      return false
    }
  }
}
