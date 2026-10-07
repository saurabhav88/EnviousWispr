import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1914: warm-up policy and request shape.
///
/// Warm-up exists to pull a model's weights into LOCAL memory. Against a model
/// Ollama proxies to its own servers that is a network round trip which spends
/// the user's cloud quota for no benefit, and it fires on every settings change.
///
/// This suite also owns the removal of the last live `think: false` in the repo
/// (#272): two of three tested models silently ignore the boolean and emit
/// reasoning anyway, so it never was the control it appeared to be.
@Suite("Ollama warm-up policy (#1914)")
struct OllamaWarmupPolicyTests {

  private func model(
    _ name: String, isRemote: Bool, thinks: Bool
  ) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: name,
      canonicalName: OllamaSetupService.canonicalModelName(name),
      parameterSize: "4B",
      parameterBillions: 4.0,
      fileSizeBytes: 2_900_000_000,
      displayName: name,
      facts: OllamaModelFacts(isRemote: isRemote, thinks: thinks)
    )
  }

  // MARK: - Policy

  @Test("a local model warms, and carries its facts to the caller")
  func localModelWarms() {
    let local = model("llama3.2", isRemote: false, thinks: false)
    #expect(
      OllamaSetupService.warmupPolicy(for: local)
        == .run(facts: OllamaModelFacts(isRemote: false, thinks: false)))
  }

  /// The two-way control. Without the local case above, an implementation that
  /// skipped EVERYTHING would satisfy the remote test while silently disabling
  /// warm-up for every user — a pure regression with no visible symptom beyond
  /// a slower first polish.
  @Test("remoteness alone decides, in both directions, for otherwise identical models")
  func policyDiscriminatesOnRemotenessOnly() {
    let localThinking = model("qwen3", isRemote: false, thinks: true)
    let remoteThinking = model("qwen3", isRemote: true, thinks: true)
    #expect(
      OllamaSetupService.warmupPolicy(for: localThinking)
        == .run(facts: OllamaModelFacts(isRemote: false, thinks: true)))
    #expect(OllamaSetupService.warmupPolicy(for: remoteThinking) == .skipRemote)
  }

  /// A model absent from the catalog has UNKNOWN remoteness. Skipping is the
  /// safe direction: warm-up is best-effort and not guaranteed before any given
  /// dictation, so the cost is a marginally slower first polish, whereas warming
  /// a model that turns out to be remote spends the user's quota.
  @Test("an unknown model skips rather than guessing it is local")
  func unknownModelSkips() {
    #expect(OllamaSetupService.warmupPolicy(for: nil) == .skipUnknownModel)
  }

  // MARK: - Request body
  //
  // These exist because a mutation control caught their absence: with the body
  // built inline, changing the warm-up's thinking level from "low" to "high"
  // left every test in this suite green. Policy coverage is not body coverage.

  @Test("a non-thinking model's warm-up sends no think key at all")
  func nonThinkingWarmupOmitsThink() {
    let body = OllamaSetupService.makeWarmupRequestBody(model: "llama3.2", thinks: false)
    #expect(body["think"] == nil)
  }

  @Test("warm-up preserves its existing shape apart from the thinking key")
  func warmupShapeOtherwiseUnchanged() {
    let body = OllamaSetupService.makeWarmupRequestBody(model: "llama3.2", thinks: false)
    #expect(body["model"] as? String == "llama3.2")
    #expect(body["stream"] as? Bool == false)
    #expect(body["keep_alive"] as? String == "60m")
    #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 1)
    #expect((body["messages"] as? [[String: String]])?.count == 1)
  }

  /// `think` is a TOP-LEVEL key on `/api/chat`. Under `options` the daemon would
  /// accept and ignore it, which is indistinguishable from it working.
  @Test("warm-up puts think at the top level, not inside options")
  func warmupThinkIsTopLevel() {
    let body = OllamaSetupService.makeWarmupRequestBody(model: "qwen3", thinks: true)
    #expect((body["options"] as? [String: Any])?["think"] == nil)
    #expect(body["think"] as? String == "low")
  }

  @Test("skip receipts name the reason and never leak the remote host")
  func skipReasonWording() {
    #expect(OllamaSetupService.warmupSkipReason(for: nil) == "model not in catalog")
    #expect(
      OllamaSetupService.warmupSkipReason(for: model("m", isRemote: true, thinks: false))
        == "remote")
    #expect(
      OllamaSetupService.warmupSkipReason(for: model("m", isRemote: false, thinks: false))
        == "not skipped")
    // The host is the user's environment. The boolean answers every question we
    // have, so no reason string may contain a URL.
    for reason in [
      OllamaSetupService.warmupSkipReason(for: nil),
      OllamaSetupService.warmupSkipReason(for: model("m", isRemote: true, thinks: true)),
    ] {
      #expect(!reason.contains("http"))
      #expect(!reason.contains("ollama.com"))
    }
  }
}
