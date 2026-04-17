import Foundation
import Testing

@testable import EnviousWisprCore

@Suite("XPCErrorSanitizer")
struct XPCErrorSanitizerTests {

  private enum SampleError: LocalizedError {
    case formatCreationFailed

    var errorDescription: String? {
      switch self {
      case .formatCreationFailed: return "Failed to create audio format."
      }
    }
  }

  @Test(
    "Swift enum error: domain, code, description preserved; userInfo has only NSLocalizedDescriptionKey"
  )
  func swiftEnumSanitized() {
    let ns = SampleError.formatCreationFailed as NSError
    let sanitized = XPCErrorSanitizer.sanitizeForXPC(SampleError.formatCreationFailed)

    #expect(sanitized.domain == ns.domain)
    #expect(sanitized.code == ns.code)
    #expect(sanitized.localizedDescription == "Failed to create audio format.")
    #expect(Array(sanitized.userInfo.keys) == [NSLocalizedDescriptionKey])
  }

  @Test("One-level NSUnderlyingError chain flattens into localizedDescription")
  func oneLevelChain() {
    let underlying = NSError(
      domain: "NSOSStatusErrorDomain", code: -50,
      userInfo: [NSLocalizedDescriptionKey: "OSStatus -50: invalid parameter"])
    let top = NSError(
      domain: "com.enviouswispr.audio", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Engine start failed",
        NSUnderlyingErrorKey: underlying,
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(top)

    #expect(sanitized.domain == "com.enviouswispr.audio")
    #expect(sanitized.code == 1)
    #expect(
      sanitized.localizedDescription == "Engine start failed <- OSStatus -50: invalid parameter")
    #expect(Array(sanitized.userInfo.keys) == [NSLocalizedDescriptionKey])
  }

  @Test("Three-level NSUnderlyingError chain: all four descriptions joined")
  func threeLevelChain() {
    let d = NSError(domain: "D", code: 4, userInfo: [NSLocalizedDescriptionKey: "d"])
    let c = NSError(
      domain: "C", code: 3,
      userInfo: [NSLocalizedDescriptionKey: "c", NSUnderlyingErrorKey: d])
    let b = NSError(
      domain: "B", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "b", NSUnderlyingErrorKey: c])
    let a = NSError(
      domain: "A", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "a", NSUnderlyingErrorKey: b])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(a)

    #expect(sanitized.localizedDescription == "a <- b <- c <- d")
    #expect(sanitized.domain == "A")
    #expect(sanitized.code == 1)
  }

  @Test("Deep chain caps at depth 8, does not hang or stack-overflow")
  func deepChainCapped() {
    // Build a 20-level chain; sanitizer should walk at most 8.
    var current = NSError(
      domain: "L", code: 20, userInfo: [NSLocalizedDescriptionKey: "level20"])
    for i in (1..<20).reversed() {
      current = NSError(
        domain: "L", code: i,
        userInfo: [
          NSLocalizedDescriptionKey: "level\(i)",
          NSUnderlyingErrorKey: current,
        ])
    }

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(current)

    // Expect top + 8 underlyings = 9 segments joined by 8 separators.
    let segments = sanitized.localizedDescription.components(separatedBy: " <- ")
    #expect(segments.count == 9)
    #expect(segments.first == "level1")
    #expect(segments.last == "level9")
  }

  @Test("URL in userInfo is dropped, only NSLocalizedDescriptionKey remains")
  func urlInUserInfoDropped() {
    let url = URL(string: "file:///var/tmp/foo")!
    let err = NSError(
      domain: "Cocoa", code: 260,
      userInfo: [
        NSLocalizedDescriptionKey: "File not found",
        NSURLErrorKey: url,
        "com.example.customClass": NSArray(array: [NSNumber(value: 1)]),
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(err)

    #expect(Array(sanitized.userInfo.keys) == [NSLocalizedDescriptionKey])
    #expect(sanitized.localizedDescription == "File not found")
  }

  @Test(
    "failureReason is appended when there's no underlying chain and it differs from description")
  func failureReasonAppendedWithoutChain() {
    let err = NSError(
      domain: "Cocoa", code: 4,
      userInfo: [
        NSLocalizedDescriptionKey: "The operation couldn't be completed.",
        NSLocalizedFailureReasonErrorKey: "No such file or directory.",
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(err)

    #expect(
      sanitized.localizedDescription
        == "The operation couldn't be completed. <- No such file or directory.")
    #expect(Array(sanitized.userInfo.keys) == [NSLocalizedDescriptionKey])
  }

  @Test("failureReason NOT appended when identical to localizedDescription")
  func failureReasonSkippedWhenIdentical() {
    let text = "Operation failed."
    let err = NSError(
      domain: "X", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: text,
        NSLocalizedFailureReasonErrorKey: text,
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(err)

    #expect(sanitized.localizedDescription == text)
  }

  @Test("failureReason is NOT used when there is an underlying chain")
  func failureReasonIgnoredWithChain() {
    let underlying = NSError(domain: "U", code: 2, userInfo: [NSLocalizedDescriptionKey: "under"])
    let err = NSError(
      domain: "X", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "top",
        NSLocalizedFailureReasonErrorKey: "reason-only",
        NSUnderlyingErrorKey: underlying,
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(err)

    #expect(sanitized.localizedDescription == "top <- under")
  }

  @Test("Sanitized NSError round-trips through NSKeyedArchiver with XPC-allowed classes")
  func xpcAllowedClassRoundTrip() throws {
    let underlying = NSError(
      domain: "NSOSStatusErrorDomain", code: -10877,
      userInfo: [NSLocalizedDescriptionKey: "audio hardware unspecified error"])
    let top = NSError(
      domain: "com.enviouswispr.audio", code: 42,
      userInfo: [
        NSLocalizedDescriptionKey: "engine.start() failed",
        NSUnderlyingErrorKey: underlying,
        NSURLErrorKey: URL(string: "https://example.com")!,
      ])

    let sanitized = XPCErrorSanitizer.sanitizeForXPC(top)

    // Apple-documented XPC-allowed class set (excluding NSError itself which is the outer object).
    let allowed: [AnyClass] = [
      NSError.self, NSString.self, NSNumber.self, NSDictionary.self,
      NSArray.self, NSData.self, NSDate.self, NSURL.self, NSUUID.self, NSNull.self,
    ]

    let data = try NSKeyedArchiver.archivedData(
      withRootObject: sanitized, requiringSecureCoding: true)

    let unarchived =
      try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: allowed, from: data) as? NSError

    #expect(unarchived != nil)
    #expect(unarchived?.domain == sanitized.domain)
    #expect(unarchived?.code == sanitized.code)
    #expect(unarchived?.localizedDescription == sanitized.localizedDescription)
  }

  @Test("Property-based: representative errors all yield single-key userInfo")
  func representativeErrorsAllSafe() {
    let cases: [any Error] = [
      SampleError.formatCreationFailed,
      NSError(
        domain: "NSURLErrorDomain", code: -1001,
        userInfo: [NSLocalizedDescriptionKey: "request timed out"]),
      NSError(
        domain: "NSOSStatusErrorDomain", code: -10877,
        userInfo: [NSLocalizedDescriptionKey: "audio hardware error"]),
      NSError(
        domain: "NSCocoaErrorDomain", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "File not found",
          NSLocalizedFailureReasonErrorKey: "The file doesn't exist.",
        ]),
      URLError(.timedOut),
    ]

    for error in cases {
      let sanitized = XPCErrorSanitizer.sanitizeForXPC(error)
      let originalNS = error as NSError
      #expect(Array(sanitized.userInfo.keys) == [NSLocalizedDescriptionKey])
      #expect(sanitized.domain == originalNS.domain)
      #expect(sanitized.code == originalNS.code)
      #expect(sanitized.localizedDescription.hasPrefix(originalNS.localizedDescription))
    }
  }
}
