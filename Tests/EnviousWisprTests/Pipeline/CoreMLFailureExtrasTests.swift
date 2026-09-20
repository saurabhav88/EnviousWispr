import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3027: the `asr_failed` capture must carry CoreML's own description, failure
/// reason and underlying error, clipped, and nothing for a non-CoreML error.
@Suite("CoreMLFailureExtras (#3027)", .tags(.observabilityContract))
struct CoreMLFailureExtrasTests {

  private func coreMLError(
    code: Int = 0, description: String, reason: String? = nil, underlying: NSError? = nil
  ) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let reason { info[NSLocalizedFailureReasonErrorKey] = reason }
    if let underlying { info[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: "com.apple.CoreML", code: code, userInfo: info)
  }

  @Test("a CoreML error with reason and underlying error yields all five keys, values intact")
  func allFiveKeys() {
    let underlying = NSError(domain: "com.apple.appleneuralengine", code: 7, userInfo: nil)
    let extra = CoreMLFailureExtras.build(
      coreMLError(
        code: 0, description: "Error computing NN outputs.",
        reason: "E5RT: ANE compile failed", underlying: underlying))
    #expect(extra["coreml.code"] as? Int == 0)
    #expect(extra["coreml.description"] as? String == "Error computing NN outputs.")
    #expect(extra["coreml.description_chars"] as? Int == 27)
    #expect(extra["coreml.failure_reason"] as? String == "E5RT: ANE compile failed")
    #expect(extra["coreml.underlying"] as? String == "com.apple.appleneuralengine#7")
    #expect(extra.count == 5)
  }

  @Test("optional keys are absent when CoreML supplied no reason or underlying error")
  func optionalKeysAbsent() {
    let extra = CoreMLFailureExtras.build(coreMLError(code: 3, description: "generic"))
    #expect(extra["coreml.code"] as? Int == 3)
    #expect(extra["coreml.description"] as? String == "generic")
    #expect(extra["coreml.description_chars"] as? Int == 7)
    #expect(extra["coreml.failure_reason"] == nil)
    #expect(extra["coreml.underlying"] == nil)
    #expect(extra.count == 3)
  }

  @Test("strings are passed through unclipped: the beforeSend sanitizer decides, never the producer")
  func neverClipped() {
    let long = String(repeating: "x", count: 200)
    let extra = CoreMLFailureExtras.build(coreMLError(description: long, reason: long))
    #expect((extra["coreml.description"] as? String)?.count == 200)
    #expect((extra["coreml.failure_reason"] as? String)?.count == 200)
    #expect(extra["coreml.description_chars"] as? Int == 200)
  }

  @Test("a non-CoreML error yields nothing, so an unconditional merge changes no other capture")
  func nonCoreMLIsEmpty() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: 5, userInfo: nil)
    #expect(CoreMLFailureExtras.build(posix).isEmpty)
    struct Plain: Error {}
    #expect(CoreMLFailureExtras.build(Plain()).isEmpty)
  }
}
