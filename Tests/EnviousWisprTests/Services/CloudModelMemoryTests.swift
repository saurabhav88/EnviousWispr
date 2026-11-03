import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4353 D1: each surface remembers the cloud model it had for each cloud provider, so a
/// provider round trip gives the user back the model they picked.
@Suite("Cloud model memory (#4353)", .tags(.productOutcome))
struct CloudModelMemoryTests {

  @Test("each provider keeps its own model, and recording one leaves the others alone")
  func providersAreIsolated() {
    var memory = CloudModelMemory()
    #expect(memory.model(for: .openAI) == nil)
    let accepted1 = memory.record("gpt-6-luna", for: .openAI)
    #expect(accepted1)
    let accepted2 = memory.record("claude-haiku-5-5", for: .claude)
    #expect(accepted2)
    let accepted3 = memory.record("gemini-2.0-flash", for: .gemini)
    #expect(accepted3)  // retired id: kept as is
    let accepted4 = memory.record("gpt-4o-mini", for: .openAI)
    #expect(accepted4)
    #expect(memory.model(for: .openAI) == "gpt-4o-mini")
    #expect(memory.model(for: .claude) == "claude-haiku-5-5")
    #expect(memory.model(for: .gemini) == "gemini-2.0-flash")
  }

  @Test("a stored memory decodes from a plain JSON object, ids byte for byte")
  func decodesLiteralJSON() throws {
    let json = #"{"openAI":"gpt-4o-audio-preview","claude":"claude-haiku-5-5"}"#
    let memory = try JSONDecoder().decode(CloudModelMemory.self, from: Data(json.utf8))
    #expect(memory.model(for: .openAI) == "gpt-4o-audio-preview")
    #expect(memory.model(for: .claude) == "claude-haiku-5-5")
    #expect(memory.model(for: .gemini) == nil)
  }

  @Test("a stored entry this build cannot use is dropped, not the whole memory")
  func decodingDropsUnusableEntries() throws {
    let json =
      #"{"openAI":"claude-haiku-5-5","futureProvider":"x-1","ollama":"llama3.2","gemini":"gemini-3.7-flash"}"#
    let memory = try JSONDecoder().decode(CloudModelMemory.self, from: Data(json.utf8))
    #expect(memory.model(for: .openAI) == nil)
    #expect(memory.model(for: .ollama) == nil)
    #expect(memory.model(for: .gemini) == "gemini-3.7-flash")
  }

  @Test("it encodes as a plain JSON object keyed by provider")
  func encodesPlainObject() throws {
    var memory = CloudModelMemory()
    memory.record("gpt-6-luna", for: .openAI)
    let data = try JSONEncoder().encode(memory)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(object == ["openAI": "gpt-6-luna"])
  }

  @Test("only cloud providers, and only their own ids, are remembered")
  func restrictsProvidersAndIds() {
    var memory = CloudModelMemory()
    let accepted5 = memory.record("llama3.2", for: .ollama)
    #expect(accepted5 == false)
    let accepted6 = memory.record("apple-intelligence", for: .appleIntelligence)
    #expect(accepted6 == false)
    let accepted7 = memory.record("gpt-4o-mini", for: .none)
    #expect(accepted7 == false)
    let accepted8 = memory.record("claude-haiku-5-5", for: .openAI)
    #expect(accepted8 == false)
    let accepted9 = memory.record("", for: .gemini)
    #expect(accepted9 == false)
    let accepted10 = memory.record("apple-intelligence", for: .claude)
    #expect(accepted10 == false)
    #expect(memory == CloudModelMemory())
  }

  @Test("an empty memory survives a save and load")
  func emptyRoundTrip() throws {
    let data = try JSONEncoder().encode(CloudModelMemory())
    #expect(String(decoding: data, as: UTF8.self) == "{}")
    #expect(try JSONDecoder().decode(CloudModelMemory.self, from: data) == CloudModelMemory())
  }
}
