import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// S1-mini's input format is a contract with a THIRD PARTY's weights (#2649).
///
/// Every other prompt in this app is a contract we own both halves of: if the
/// text and the model disagree, we can retrain. Here we cannot. The card is
/// explicit that skipping the system prompt or the control line, rewording
/// either, or sending a value outside the trained sets makes the model
/// hallucinate or garble its output. So these rows pin the text and the shape
/// rather than merely exercising the builder.
@Suite("S1-mini control-line prompt (#2649)", .tags(.driftGuard))
struct S1ControlLinePromptTests {
  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LLM
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  static func input(transcript: String = "so um i need to send the report by friday")
    -> PromptBuildInput
  {
    PromptBuildInput(
      transcript: transcript,
      provider: .s1Mini,
      modelID: LLMProvider.s1MiniModelName,
      appName: "Slack",
      language: nil,
      // A real term, deliberately: the rows below assert it does NOT reach the
      // model, which an empty list could not demonstrate.
      polishVocabulary: PolishVocabulary(
        terms: [CustomWord(canonical: "Kubernetes")], generation: 0),
      ollamaIsRemote: nil
    )
  }

  /// The literal a reviewer read, pinned byte for byte.
  @Test("the system prompt is the card's exact text")
  func systemPromptIsExact() {
    #expect(
      S1ControlLinePromptBuilder.systemPrompt
        == """
        You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.
        """)
    // A copy-paste of one builder's constant over another is caught here rather
    // than by a reader noticing.
    #expect(S1ControlLinePromptBuilder.systemPrompt != EGOnePromptBuilder.systemPrompt)
    #expect(S1ControlLinePromptBuilder.systemPrompt != EGOneEnvelopePromptBuilder.systemPrompt)
  }

  /// AND against the tracked artifact, which is the file the measurements in the
  /// plan were taken through. The literal above pins the bytes a reviewer read;
  /// this pins the bytes the runs used. Without both, the two copies could drift
  /// from the card together and stay green.
  @Test("the Swift literal is byte-identical to the tracked artifact")
  func literalMatchesArtifact() throws {
    let artifact = Self.repoRoot
      .appendingPathComponent("scripts/eval/prompts/s1-mini-control-line-v1.txt")
    // A check that cannot reach its subject is not a check.
    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "artifact not found at \(artifact.path)")
    let fileText = try String(contentsOf: artifact, encoding: .utf8)
    // Asserted rather than assumed: a future file that gained a `#` comment
    // header would make the comparison below quietly wrong, the way it would for
    // the EG-1 v1 artifact, which does carry one.
    #expect(
      !fileText.split(separator: "\n").contains {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
      })
    #expect(fileText.hasSuffix("\n"), "artifact should end with exactly one trailing newline")
    #expect(String(fileText.dropLast()) == S1ControlLinePromptBuilder.systemPrompt)
  }

  /// The control line is the model's actual API surface. Its three DEFAULT
  /// values are product decisions, not incidental strings: `lists` is the
  /// founder's choice of behaviour, and `semi-formal` is the only register that
  /// does not deliberately drop capitals and final periods. Since the pickers
  /// (#2649) these are the values a user who never opens them runs under, so a
  /// changed default here changes every install silently.
  @Test("the default control line is the shipped one, in the card's shape")
  func controlLineShape() {
    #expect(
      S1ControlSettings.default.controlLine
        == "[Styling: semi-formal] [Structure: lists] [Context: general]")
    #expect(S1ControlSettings.default.structure == .lists)
    #expect(S1ControlSettings.default.styling == .semiFormal)
    #expect(S1ControlSettings.default.context == .general)
  }

  /// The pickers change EXACTLY the first line. The transcript after it, the
  /// system prompt, and the message count are all untouched, or a picker could
  /// leak into the text the model is asked to clean.
  @Test("a non-default pick changes the control line and nothing else")
  func nonDefaultPickReachesTheLine() {
    var input = Self.input(transcript: "so um i need to send the report by friday")
    input = PromptBuildInput(
      transcript: input.transcript, provider: input.provider, modelID: input.modelID,
      appName: input.appName, language: input.language,
      polishVocabulary: input.polishVocabulary, ollamaIsRemote: nil,
      s1Control: S1ControlSettings(styling: .formal, structure: .prose, context: .email))
    let envelope = S1ControlLinePromptBuilder().build(input: input, mode: .message)
    let baseline = S1ControlLinePromptBuilder().build(
      input: Self.input(transcript: "so um i need to send the report by friday"), mode: .message)

    #expect(envelope.messages.count == baseline.messages.count)
    #expect(envelope.messages[0].content == baseline.messages[0].content)
    #expect(
      envelope.messages[1].content
        == "[Styling: formal] [Structure: prose] [Context: email]\nso um i need to send the report by friday"
    )
    // Two-way control: the baseline really is different, so the row above did
    // not pass by comparing a value to itself.
    #expect(envelope.messages[1].content != baseline.messages[1].content)
  }

  /// The user message shape, asserted on the RENDERED envelope rather than on
  /// the constants above, so a builder that assembled them wrongly still fails.
  @Test("the user message is the control line, a newline, then the bare transcript")
  func userMessageShape() {
    let envelope = S1ControlLinePromptBuilder().build(
      input: Self.input(transcript: "so um i need to send the report by friday"), mode: .message)

    #expect(envelope.messages.count == 2)
    #expect(envelope.messages[0].role == .system)
    #expect(envelope.messages[0].content == S1ControlLinePromptBuilder.systemPrompt)
    #expect(envelope.messages[1].role == .user)
    #expect(
      envelope.messages[1].content
        == "[Styling: semi-formal] [Structure: lists] [Context: general]\nso um i need to send the report by friday"
    )

    // The transcript is BARE. `EGOnePromptBuilder` wraps its transcript in
    // `<TRANSCRIPT>` because EG-1 was tuned that way; adding a wrapper here
    // would be off-distribution and the model could echo the tags into the
    // user's text. Asserting the absence keeps a future "consistency" edit from
    // introducing one.
    #expect(!envelope.messages[1].content.contains("TRANSCRIPT"))

    // Custom vocabulary is dropped, same as EG-1 and Apple Intelligence: the
    // model never saw a vocabulary section in training.
    #expect(!envelope.messages[1].content.contains("Kubernetes"))
    #expect(!envelope.messages[0].content.contains("Kubernetes"))

    // The app name is not injected either. It is in the input above precisely so
    // this row proves the builder ignores it.
    #expect(!envelope.messages[1].content.contains("Slack"))
  }

  /// The mode is documented as ignored. A row that only checked ONE mode could
  /// not tell "ignored" from "happens to match".
  @Test("every polish mode produces identical bytes")
  func modeIsIgnored() {
    let builder = S1ControlLinePromptBuilder()
    // `PolishMode` is not `CaseIterable`, so the modes are named. If one is
    // added, this row does not automatically cover it — stated rather than
    // implied, because a list that looks exhaustive and is not is worse than a
    // short one that says so.
    let modes: [PolishMode] = [.inline, .message, .structured, .edit]
    let rendered: [[String]] = modes.map { mode in
      builder.build(input: Self.input(), mode: mode).messages.map { $0.content }
    }
    for contents in rendered {
      #expect(contents == rendered[0])
    }
    #expect(rendered.count > 1, "a single mode cannot demonstrate that mode is ignored")
  }

  // MARK: - One prompt owner, both routes

  /// The managed provider and a copy the user pulled into Ollama themselves must
  /// receive the SAME prompt from the SAME builder. If they ever diverge the
  /// text exists twice and only one copy is pinned by the rows above.
  @Test("both routes select the same family")
  func bothRoutesShareOneFamily() {
    #expect(
      DefaultPromptPlanner.family(
        for: .s1Mini, modelID: LLMProvider.s1MiniModelName, ollamaIsRemote: nil,
        egOneFamily: .egOneEnvelope) == .s1ControlLine)

    for id in [
      "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
      "hf.co/superwhisper/s1-mini-gguf:f16",
      "HF.CO/SUPERWHISPER/S1-MINI-GGUF",
    ] {
      #expect(
        DefaultPromptPlanner.family(
          for: .ollama, modelID: id, ollamaIsRemote: false, egOneFamily: .egOneEnvelope)
          == .s1ControlLine, "\(id) must reach the S1-mini prompt")
      // And the hosted branch must not steal it: the training format outranks
      // where the model happens to be running.
      #expect(
        DefaultPromptPlanner.family(
          for: .ollama, modelID: id, ollamaIsRemote: true, egOneFamily: .egOneEnvelope)
          == .s1ControlLine, "\(id) hosted must still get the training prompt")
    }
  }

  /// Two-way control. A predicate that matched everything would satisfy the row
  /// above and silently send a stranger's model a prompt tuned for different
  /// weights, which is how a working setup gets quietly worse.
  @Test("a model that is not S1-mini does not get its prompt")
  func lookalikesAreNotMatched() {
    for id in [
      "s1-mini",                                  // bare name, not the repository
      "hf.co/superwhisper/s1-mini-gguf-acme",     // a renamed copy
      "hf.co/someoneelse/s1-mini-GGUF",           // different owner
      "qwen3:0.6b",                               // the base model
      "eg-1",
    ] {
      #expect(
        OllamaSetupService.isS1MiniModel(id) == false,
        "\(id) must not be treated as S1-mini")
      #expect(
        DefaultPromptPlanner.family(
          for: .ollama, modelID: id, ollamaIsRemote: false, egOneFamily: .egOneEnvelope)
          != .s1ControlLine, "\(id) must not receive the S1-mini prompt")
    }
    // EG-1 through Ollama still reaches its own family, so the new check above
    // it did not swallow the existing one. `.egOneFixed` and NOT the injected
    // `.egOneEnvelope` is correct and deliberate: an EG-1 pulled through Ollama
    // carries no manifest, so the app cannot learn which revision those bytes
    // are and holds the 1.1 prompt. That known limit is stated at
    // `DefaultPromptPlanner.family`; asserting the injected value here would
    // have made this row a demand to change shipped behaviour.
    #expect(
      DefaultPromptPlanner.family(
        for: .ollama, modelID: "eg-1", ollamaIsRemote: false, egOneFamily: .egOneEnvelope)
        == .egOneFixed)
  }

  /// The planner and the builder registry must agree, or the family is selected
  /// and a different builder renders it.
  @Test("the family resolves to this builder")
  func familyResolvesToThisBuilder() {
    #expect(DefaultPromptPlanner.builder(for: .s1ControlLine) is S1ControlLinePromptBuilder)
  }

  // MARK: - The licence-bound name

  /// The licence carries an ADDITIONAL TERM requiring this exact capitalisation
  /// wherever the model is identified. One owner, so a surface cannot spell it
  /// its own way.
  @Test("the display name is the exact licensed string")
  func displayNameIsLicenceExact() {
    #expect(LLMProvider.s1Mini.displayName == "S1-mini")
    #expect(LLMProvider.s1Mini.rawValue == "s1Mini")
    #expect(LLMProvider.s1MiniModelName == "s1-mini")
    // The managed route's model id must NOT equal the Ollama route's, or polish
    // telemetry merges the two and neither can be read — which is the query
    // #2634 was diagnosed from.
    #expect(LLMProvider.s1MiniModelName != "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
  }
}
