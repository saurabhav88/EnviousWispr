import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

@Suite("AudioError identity — #1378")
struct AudioErrorIdentityTests {

  @Test("no-microphone error has stable NSError identity")
  func noMicrophoneNSErrorIdentity() {
    let error = AudioError.noBuiltInMicrophoneFound as NSError
    #expect(error.domain == AudioError.errorDomain)
    #expect(error.code == AudioError.noBuiltInMicrophoneFound.errorCode)
    #expect(error.localizedDescription == "No usable microphone device was found.")
  }

  @Test("XPC sanitizer preserves no-microphone domain and code")
  func xpcSanitizerPreservesNoMicrophoneIdentity() {
    let sanitized = XPCErrorSanitizer.sanitizeForXPC(AudioError.noBuiltInMicrophoneFound)
    #expect(sanitized.domain == AudioError.errorDomain)
    #expect(sanitized.code == AudioError.noBuiltInMicrophoneFound.errorCode)
    #expect(sanitized.localizedDescription == "No usable microphone device was found.")
  }
}
