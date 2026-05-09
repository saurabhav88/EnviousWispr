import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("Observability redaction")
struct ObservabilityRedactionTests {
  @Test("redactDict recurses through nested dictionaries and arrays")
  func recursiveRedaction() {
    let redacted = ObservabilityBootstrap.redactDict([
      "audio_environment": [
        "safe": "built_in_mic",
        "nested": [
          "email": "user@example.com",
          "array": ["ok", "sk-abcdefghijklmnopqrstuvwxyz123456"],
        ],
      ],
      "outer": "phc_abcdefghijklmnopqrstuvwxyz123456",
    ])

    let environment = redacted["audio_environment"] as? [String: Any]
    let nested = environment?["nested"] as? [String: Any]
    let array = nested?["array"] as? [Any]

    #expect(environment?["safe"] as? String == "built_in_mic")
    #expect(nested?["email"] as? String == "[REDACTED]")
    #expect(array?[0] as? String == "ok")
    #expect(array?[1] as? String == "[REDACTED]")
    #expect(redacted["outer"] as? String == "[REDACTED]")
  }
}
