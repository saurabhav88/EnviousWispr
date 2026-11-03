import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 D4: discovery tells three things apart (works, confirmed locked for this key, not
/// sure), so a network blip or a busy server never takes a working model away from the user.
@Suite("Model availability evidence (#4353)", .tags(.productOutcome))
struct LLMModelAvailabilityTests {

  private func decode(_ json: String) throws -> LLMModelInfo {
    try JSONDecoder().decode(LLMModelInfo.self, from: Data(json.utf8))
  }

  // MARK: - Saved model lists

  @Test("a cloud row saved before #4353 as unavailable is read as not sure, and stays selectable")
  func legacyCloudFalseIsInconclusive() throws {
    for provider in ["openAI", "gemini", "claude"] {
      let row = try decode(
        #"{"id":"m-1","displayName":"m-1","provider":"\#(provider)","isAvailable":false,"isRemote":false}"#
      )
      #expect(row.availability == .inconclusive)
      #expect(row.isSelectable)
      #expect(row.isAvailable == false)
    }
  }

  @Test("other saved rows keep their meaning")
  func legacyOtherRowsKeepMeaning() throws {
    let cloudTrue = try decode(
      #"{"id":"gpt-6-luna","displayName":"gpt-6-luna","provider":"openAI","isAvailable":true,"isRemote":false}"#
    )
    #expect(cloudTrue.availability == .available)
    let appleFalse = try decode(
      #"{"id":"apple-intelligence","displayName":"A","provider":"appleIntelligence","isAvailable":false,"isRemote":false}"#
    )
    #expect(appleFalse.availability == .confirmedUnavailable)
    #expect(appleFalse.isSelectable == false)
    let ollama = try decode(
      #"{"id":"llama3.2","displayName":"llama3.2","provider":"ollama","isAvailable":true,"isRemote":false}"#
    )
    #expect(ollama.availability == .available)
  }

  @Test("each value survives a save and load, and the old key is still written")
  func roundTripWritesBothKeys() throws {
    let cases: [(LLMModelAvailability, Bool)] = [
      (.available, true), (.confirmedUnavailable, false), (.inconclusive, false),
    ]
    for (availability, legacy) in cases {
      let row = LLMModelInfo(
        id: "claude-haiku-5-5", displayName: "H", provider: .claude, availability: availability,
        isRemote: false)
      let data = try JSONEncoder().encode(row)
      let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["availability"] as? String == availability.rawValue)
      #expect(object["isAvailable"] as? Bool == legacy)
      #expect(try JSONDecoder().decode(LLMModelInfo.self, from: data).availability == availability)
    }
  }

  // MARK: - What a probe answer means

  @Test("OpenAI answers")
  func openAIAnswers() {
    let cases: [(Int?, String, LLMModelAvailability)] = [
      (200, "", .available),
      (404, #"{"error":{"code":"model_not_found"}}"#, .confirmedUnavailable),
      (403, "", .confirmedUnavailable),
      (429, #"{"error":{"type":"rate_limit_exceeded"}}"#, .inconclusive),
      (429, #"{"error":{"type":"insufficient_quota"}}"#, .inconclusive),
      (401, "", .inconclusive),
      (400, "", .inconclusive),
      (500, "", .inconclusive),
      (nil, "", .inconclusive),
    ]
    for (status, body, expected) in cases {
      #expect(
        LLMModelDiscovery.probeAvailability(provider: .openAI, statusCode: status, body: body)
          == expected, "status \(String(describing: status))")
    }
  }

  @Test("Gemini answers, including the zero-quota lock")
  func geminiAnswers() {
    let cases: [(Int?, String, LLMModelAvailability)] = [
      (200, "", .available),
      (429, "Quota exceeded ... limit: 0, model: gemini-3.1-pro", .confirmedUnavailable),
      (429, "RESOURCE_EXHAUSTED: try again later", .inconclusive),
      (404, "", .confirmedUnavailable),
      (403, "", .confirmedUnavailable),
      (400, "API_KEY_INVALID", .inconclusive),
      (503, "", .inconclusive),
      (nil, "", .inconclusive),
    ]
    for (status, body, expected) in cases {
      #expect(
        LLMModelDiscovery.probeAvailability(provider: .gemini, statusCode: status, body: body)
          == expected, "status \(String(describing: status)) \(body)")
    }
  }

  @Test("Claude answers: busy and rate-limited are not sure, not available")
  func claudeAnswers() {
    let cases: [(Int?, String, LLMModelAvailability)] = [
      (200, "", .available),
      (404, #"{"type":"error","error":{"type":"not_found_error"}}"#, .confirmedUnavailable),
      (403, "", .confirmedUnavailable),
      (429, "", .inconclusive),
      (529, #"{"error":{"type":"overloaded_error"}}"#, .inconclusive),
      (500, "", .inconclusive),
      (402, "", .inconclusive),
      (nil, "", .inconclusive),
    ]
    for (status, body, expected) in cases {
      #expect(
        LLMModelDiscovery.probeAvailability(provider: .claude, statusCode: status, body: body)
          == expected, "status \(String(describing: status))")
    }
  }

  @Test("a model discovery was not sure about keeps its place among the choosable ones")
  func unsureRowsKeepTheirPlace() {
    func row(_ id: String, _ availability: LLMModelAvailability) -> LLMModelInfo {
      LLMModelInfo(
        id: id, displayName: id, provider: .openAI, availability: availability, isRemote: false)
    }
    let sorted = LLMModelDiscovery.sortedForPicker([
      row("Z-model", .available), row("Locked", .confirmedUnavailable),
      row("A-model", .inconclusive), row("M-model", .available),
    ])
    #expect(sorted.map(\.id) == ["A-model", "M-model", "Z-model", "Locked"])
  }

  @Test("the probe's answer reaches the row")
  func answerReachesRow() {
    let candidate = LLMModelDiscovery.DiscoveryCandidate(
      id: "gpt-6-luna", displayName: "GPT 6 Luna", isRemote: false)
    for availability in [LLMModelAvailability.available, .confirmedUnavailable, .inconclusive] {
      let row = LLMModelDiscovery.modelInfo(
        from: candidate, provider: .openAI, availability: availability)
      #expect(row.availability == availability)
      #expect(row.id == "gpt-6-luna")
    }
  }
}
