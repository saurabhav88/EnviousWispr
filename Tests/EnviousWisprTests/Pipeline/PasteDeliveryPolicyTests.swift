import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// The bake-off control plane (#2652).
//
// A reporter's dictation arrived twice in WebKit-backed fields, proven by exact
// character counts, and the defect does not reproduce here. Rather than ship a fix
// argued from a mechanism story, the cascade can be forced into candidate policies and
// measured against real applications.
//
// A test seam on a delivery guard is a bypass unless it cannot lie, and the specific lie
// available here is quiet: the harness stamps a variant on every scored row, so a
// process that fell back to the baseline while the harness believed it was measuring V2
// would produce a scorecard full of confident rows about a policy that never ran, with
// nothing downstream able to tell. These tests exist to make that state unreachable, not
// merely unlikely.
// THE WHOLE CONTROL PLANE IS `#if DEBUG`, so this whole suite is too.
//
// `resolve`, `variantEnvironmentKey`, `runIDEnvironmentKey`, `.webCmdV` and `.axOneWriter` are
// all compiled out of a release build on purpose — a release binary contains neither the
// candidate behaviour nor its raw values for an artifact scan to find. A test naming them
// compiled in Debug and broke `build-release`, and no local run could see it:
// `scripts/xcode-test.sh` builds Debug. `--release` is the flag that reproduces it.
#if DEBUG
@Suite("Paste delivery policy (#2652)", .tags(.productOutcome))
struct PasteDeliveryPolicyTests {

  // MARK: - Resolution fails closed

  @Test("no bake-off environment resolves to the shipped baseline, silently")
  func absentEnvironmentIsBaseline() {
    let resolved = PasteDeliveryPolicy.resolve(environment: [:])
    #expect(resolved.policy == .baseline)
    #expect(resolved.runID == nil)
    // Silence is correct HERE and only here: an ordinary debug session is not a rejected
    // bake-off, and logging one would train the operator to ignore the line that matters.
    #expect(resolved.rejection == nil)
  }

  @Test("an unknown variant is refused LOUDLY rather than guessed")
  func unknownVariantIsRefused() {
    let resolved = PasteDeliveryPolicy.resolve(environment: [
    PasteDeliveryPolicy.variantEnvironmentKey: "V9",
    PasteDeliveryPolicy.runIDEnvironmentKey: "run-1",
    ])
    #expect(resolved.policy == .baseline)
    // The rejection is the whole point. A silent fallback here is the one failure mode
    // that produces a plausible, wrong scorecard instead of an obvious error.
    #expect(resolved.rejection != nil)
    #expect(resolved.rejection?.contains("V9") == true)
  }

  @Test("a forced variant with no run id is refused")
  func missingRunIDIsRefused() {
    let resolved = PasteDeliveryPolicy.resolve(environment: [
    PasteDeliveryPolicy.variantEnvironmentKey: "V2"
    ])
    #expect(resolved.policy == .baseline)
    #expect(resolved.rejection != nil)
    #expect(resolved.runID == nil)
  }

  @Test("an empty run id is refused, not treated as present")
  func emptyRunIDIsRefused() {
    let resolved = PasteDeliveryPolicy.resolve(environment: [
    PasteDeliveryPolicy.variantEnvironmentKey: "V2",
    PasteDeliveryPolicy.runIDEnvironmentKey: "",
    ])
    #expect(resolved.policy == .baseline)
    #expect(resolved.rejection != nil)
  }

    @Test(
    "every declared variant resolves to its exact writer and timeout pair",
    arguments: [
        ("V0", PasteDeliveryPolicy.WriterPolicy.current, false),
        ("V1", .webCmdV, false),
        ("V2", .axOneWriter, false),
        ("V4", .current, true),
        ("V5", .webCmdV, true),
    ])
    func declaredVariantsResolveExactly(
    id: String, writer: PasteDeliveryPolicy.WriterPolicy, bounded: Bool
    ) {
    let resolved = PasteDeliveryPolicy.resolve(environment: [
        PasteDeliveryPolicy.variantEnvironmentKey: id,
        PasteDeliveryPolicy.runIDEnvironmentKey: "run-1",
    ])
    #expect(resolved.rejection == nil)
    #expect(resolved.policy.id == id)
    #expect(resolved.policy.writer == writer)
    #expect(resolved.policy.boundTier1MessagingTimeout == bounded)
    #expect(resolved.runID == "run-1")
    }

  @Test("only V0 is the baseline")
  func baselineIsExactlyV0() {
    #expect(PasteDeliveryPolicy.baseline.isBaseline)
    for id in ["V1", "V2", "V4", "V5"] {
    let resolved = PasteDeliveryPolicy.resolve(environment: [
        PasteDeliveryPolicy.variantEnvironmentKey: id,
        PasteDeliveryPolicy.runIDEnvironmentKey: "r",
    ])
    #expect(!resolved.policy.isBaseline, "\(id) must not read as the shipped baseline")
    }
  }

  // MARK: - The behaviour change itself

  // The disposition is where V2 actually differs from today, so these are the rows that
  // decide whether the arm tests what it claims. They assert the WEAKEST input that
  // satisfies each branch, because a test that only exercises the interesting case
  // cannot show that the boring cases were left alone.

  @Test("under the baseline, every outcome disposes exactly as it does today")
  func baselineDispositionIsUnchanged() {
    for (outcome, expected) in [
    (PasteService.AXInsertOutcome.verified, AXDirectDisposition.delivered),
    (.noMutation, .continueCascade),
    (.unverifiable, .stopUnverified),
    ] {
    let result = PasteService.AXInsertResult(
        outcome: outcome, submitted: nil, writeCall: .succeeded(attemptedText: "x"),
        declineReason: nil, settability: nil)
    #expect(dispositionForAXDirect(result, writerPolicy: .current) == expected)
    // And the policy-free overload it delegates to must agree, or the two answers to
    // one question could drift apart without anything noticing.
    #expect(dispositionForAXDirect(outcome) == expected)
    }
  }

    @Test("V2 stops the cascade once the setter RETURNED SUCCESS, even on no-mutation")
    func axOneWriterStopsAfterSuccessfulWrite() {
    let noMutationAfterWrite = PasteService.AXInsertResult(
        outcome: .noMutation, submitted: nil, writeCall: .succeeded(attemptedText: "hello"),
        declineReason: nil, settability: nil)
    // This is the reporter's exact shape: the write ran, verification said nothing
    // changed, and today that authorises a second writer.
    #expect(
        dispositionForAXDirect(noMutationAfterWrite, writerPolicy: .current)
          == .continueCascade)
    #expect(
        dispositionForAXDirect(noMutationAfterWrite, writerPolicy: .axOneWriter)
          == .stopUnverified)
    }

    @Test("V2 still allows the fallback when the setter was never called")
    func axOneWriterAllowsFallbackWhenNotAttempted() {
    // The coverage half, and the reason V2 keys on the write CALL rather than on the
    // outcome. Every pre-write decline lands here, including the Electron destinations
    // that never accept an AX write at all. Reading `.noMutation` alone would refuse
    // their fallback and lose automatic delivery for them entirely — a coverage loss
    // wearing a duplicate fix's clothes.
    let declined = PasteService.AXInsertResult.declined(.roleNotText)
    #expect(declined.writeCall == .notAttempted)
    #expect(dispositionForAXDirect(declined, writerPolicy: .axOneWriter) == .continueCascade)
    }

    @Test("V2 still allows the fallback when the setter was called and FAILED")
    func axOneWriterAllowsFallbackAfterFailedWrite() {
    // A failed setter mutated nothing, so refusing the fallback here would drop the
    // user's dictation for no safety gain. `.failed` exists as its own state precisely
    // so this case cannot be folded into either neighbour.
    let failed = PasteService.AXInsertResult.writeCallFailed(
        attemptedText: "hello", settability: nil)
    #expect(failed.writeCall == .failed(attemptedText: "hello"))
    #expect(dispositionForAXDirect(failed, writerPolicy: .axOneWriter) == .continueCascade)
    }

    @Test("V2 delivers, rather than merely stopping, when the write is positively verified")
    func axOneWriterDeliversOnVerified() {
    let verified = PasteService.AXInsertResult(
        outcome: .verified, submitted: .legacy, writeCall: .succeeded(attemptedText: "hi"),
        declineReason: nil, settability: nil)
    #expect(dispositionForAXDirect(verified, writerPolicy: .axOneWriter) == .delivered)
    }

    // MARK: - The attempted text cannot contradict the call state

    @Test("attempted text is present exactly when a write call was made")
    func attemptedTextTracksTheCallState() {
    // The first draft carried these as independent fields, which permitted
    // "not attempted, here is the text" and "succeeded, no text". Both are nonsense and
    // both would have corrupted the submission ledger the byte veto reads. The
    // associated value deletes the states rather than asking a reviewer to notice them.
    #expect(PasteService.AXWriteCall.notAttempted.attemptedText == nil)
    #expect(PasteService.AXWriteCall.failed(attemptedText: "a").attemptedText == "a")
    #expect(PasteService.AXWriteCall.succeeded(attemptedText: "b").attemptedText == "b")
    }
}
#endif
