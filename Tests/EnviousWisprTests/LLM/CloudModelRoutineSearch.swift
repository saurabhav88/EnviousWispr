import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #4353 PR 5 (D7 detail, Settings search, founder decisions 10 and 11): when a new model's
/// fallback setting ends in a request rejection, try the other settings of the app's closed
/// request menu, in the fixed order of `CloudModelRoutineCalls.Setting.searchMenu`.
///
/// Each alternative is sent through the SHIPPED connector by giving it an immutable, validated
/// list snapshot that holds one row for the candidate with that setting; no list file is
/// written. The candidate id, prompt, output-token policy, chat eligibility and file batching
/// stay the fallback's. Every request goes through the same `Meter` as the fallback.
extension CloudModelRoutine {

  // MARK: - One phase of logical calls

  /// What one phase (fallback, screening or confirmation) of one setting came to.
  struct PhaseResult: Encodable, Sendable {
    let setting: String
    let phase: CloudModelRoutineCalls.Phase
    /// The fixed input indices this phase was asked to polish, in order.
    let inputs: [Int]
    /// Milliseconds of each successful polish, in input order.
    let perInputMs: [Int]
    /// The closed class of the call that ended the phase early, if any.
    let errorClass: ErrorClass?
    /// OpenAI's omission memo is non-empty after the phase: a parameter was stripped.
    let memoAdapted: Bool
    /// Search phases only: some physical request did not carry exactly the parameters the
    /// tested setting sends. Nil for the fallback, which is judged by the memo alone.
    let requestsMatchedSetting: Bool?
    /// Physical exchanges granted for this phase's logical calls.
    let physicalAttempts: Int
    /// Unrounded timings for the median; not published.
    let times: [Double]

    private enum CodingKeys: String, CodingKey {
      case setting, phase, inputs, perInputMs, errorClass, memoAdapted, requestsMatchedSetting
      case physicalAttempts
    }

    var completed: Bool { errorClass == nil && perInputMs.count == inputs.count }
    /// A search phase proves its setting only when it completed with no adaptation.
    var provesSetting: Bool { completed && !memoAdapted && requestsMatchedSetting == true }
    var medianMs: Int? { times.isEmpty ? nil : Int(LiveSweepSupport.medianMs(times).rounded()) }
  }

  /// The strippable OpenAI parameters a setting sends, from the tested policy itself (not
  /// from the connector): `temperature` when included, `reasoning_effort` unless omitted.
  static func openAIParamsSent(by policy: CloudModelList.RequestPolicy) -> [String]? {
    guard case .openAI(let effort, let temperature) = policy else { return nil }
    var params: [String] = []
    if effort != .omit { params.append("reasoning_effort") }
    if temperature == .include { params.append("temperature") }
    return params.sorted()
  }

  /// Polish `inputIndices` with `setting` through the shipped connector built on `list`.
  /// Stops at the first failed input. The OpenAI omission memo is cleared before the phase,
  /// so it starts empty and is never cleared inside a logical call.
  static func runPhase(
    id: String, provider: LLMProvider, setting: CloudModelRoutineCalls.Setting,
    phase: CloudModelRoutineCalls.Phase, inputIndices: [Int], list: CloudModelList,
    keychain: KeychainManager, meter: Meter, transports: Transports
  ) async -> PhaseResult {
    let capabilities = provider.modelCapabilities(model: id, list: list)
    let evidenceStart = meter.requestEvidence.count
    var times: [Double] = []
    var failure: ErrorClass?
    if let keyID = keyID(provider),
      let connector = connector(
        provider, keychain: keychain, list: list,
        executor: meter.wrap(transports.polish(provider), provider: provider))
    {
      if provider == .openAI { OpenAIConnector.resetOmissions(model: id) }
      for index in inputIndices {
        let input = inputs[index]
        let call = CloudModelRoutineCalls.LogicalCallID(
          provider: provider, model: id, setting: setting, phase: phase, input: index)
        do {
          try meter.begin(call)
        } catch {
          failure = .harnessRefused
          break
        }
        let config = LLMProviderConfig(
          model: id, apiKeyKeychainId: keyID,
          outputTokens: LLMPolishStep.outputTokenPolicy(
            provider: provider, textCount: input.text.count, thinks: nil),
          temperature: 0, thinking: capabilities.thinkingControl.resolved)
        let envelope = LiveSweepSupport.productionEnvelope(
          provider: provider, modelID: id, transcript: input.text)
        let start = ContinuousClock.now
        do {
          let result = try await connector.polish(envelope: envelope, config: config, onToken: nil)
          meter.end()
          let elapsed = ContinuousClock.now - start
          times.append(
            Double(elapsed.components.seconds) * 1000
              + Double(elapsed.components.attoseconds) / 1e15)
          if LiveSweepSupport.problem(input: input.text, output: result.polishedText) != nil {
            failure = .unusableOutput
            break
          }
        } catch {
          meter.end()
          failure = errorClass(error)
          break
        }
      }
    } else {
      failure = .other
    }

    let memoAdapted =
      provider == .openAI && !OpenAIConnector.memoizedOmissions(model: id).isEmpty
    let evidence = meter.requestEvidence.dropFirst(evidenceStart).filter {
      $0.id.call.model == id && $0.id.call.setting == setting && $0.id.call.phase == phase
    }
    let matched: Bool?
    if phase == .fallback {
      matched = nil
    } else if let expected = openAIParamsSent(by: setting.policy) {
      matched = evidence.allSatisfy { $0.sentOpenAIParams == expected }
    } else {
      // Claude and Gemini have no parameter strip: every body is the tested setting's.
      matched = true
    }
    return PhaseResult(
      setting: setting.label, phase: phase, inputs: inputIndices,
      perInputMs: times.map { Int($0.rounded()) }, errorClass: failure, memoAdapted: memoAdapted,
      requestsMatchedSetting: matched, physicalAttempts: evidence.count, times: times)
  }

  // MARK: - Settings search

  /// How a search ended. Closed.
  enum SearchOutcome: String, Encodable, Sendable {
    /// One alternative passed screening and all three confirmations without adaptation.
    case passed
    /// Every permitted alternative was rejected as a bad request. Does not establish that
    /// every compiled setting fails or that an app release is required.
    case requestRejectedSearchExhausted
    /// No alternative proved its setting, but not every one was rejected (unusable output or
    /// adaptation).
    case noQualifyingSetting
    /// A failure that is not about the setting (key, access, quota, transport, server,
    /// harness or unclassified) stopped the search; `interruption` names it.
    case interrupted
    /// The fallback setting is not in the search menu, so the approved alternatives are not
    /// defined for it; nothing was sent.
    case fallbackOutsideMenu
  }

  struct SettingAttempt: Encodable, Sendable {
    let setting: String
    let request: RequestJSON
    let screening: PhaseResult
    let confirmation: PhaseResult?
    let qualified: Bool
  }

  struct SearchEvidence: Encodable, Sendable {
    /// Always `requestRejected`: the fallback's final class that started the search.
    let trigger: ErrorClass
    let fallbackSetting: String
    let attempts: [SettingAttempt]
    let outcome: SearchOutcome
    let interruption: ErrorClass?
    let chosenSetting: String?
    /// The issue the publication step files (Chunk 7); nothing is filed here.
    let issueIntent: String?
  }

  static let callRecipeIssueTitle = "Cloud model routine: call recipe"

  /// The classes after which the search tries the next alternative: the setting itself was
  /// refused, or its output was unusable. Every other class stops the search.
  static func searchContinues(after errorClass: ErrorClass) -> Bool {
    errorClass == .requestRejected || errorClass == .unusableOutput
  }

  /// The row a tested setting is sent with: the fallback's chat eligibility and file batching,
  /// the tested request policy. Used for the temporary snapshot and for the proposal.
  static func searchRow(
    provider: LLMProvider, id: String, released: String?, policy: CloudModelList.RequestPolicy,
    fallback: LLMModelCapabilities, allowsFileBatch: Bool, medianMs: Int?
  ) -> ProposedRow {
    ProposedRow(
      provider: provider.rawValue, id: id, released: released, recommended: false, hidden: false,
      request: RequestJSON(policy), supportsChatCompletions: fallback.supportsChatCompletions,
      allowsFileBatch: allowsFileBatch,
      medianPolishMs: medianMs.flatMap {
        CloudModelList.medianPolishMsRange.contains($0) ? $0 : nil
      })
  }

  /// The id and both supported dated spellings resolve exactly `policy`, with the fallback's
  /// chat eligibility and file batching.
  static func resolvesSetting(
    _ provider: LLMProvider, id: String, policy: CloudModelList.RequestPolicy,
    supportsChatCompletions: Bool, allowsFileBatch: Bool, in list: CloudModelList
  ) -> Bool {
    [id, "\(id)-2030-01-01", "\(id)-20300101"].allSatisfy { variant in
      provider.listedRow(model: variant, list: list)?.request == policy
        && provider.modelCapabilities(model: variant, list: list).supportsChatCompletions
          == supportsChatCompletions
        && provider.allowsFileBatch(model: variant, list: list) == allowsFileBatch
    }
  }

  /// Search the alternatives after the fallback's final `requestRejected`. Returns the
  /// evidence and, on a pass, the chosen setting with its confirmation phase.
  static func search(
    id: String, provider: LLMProvider, fallback: CloudModelRoutineCalls.Setting,
    fallbackCapabilities: LLMModelCapabilities, allowsFileBatch: Bool, released: String?,
    list: CloudModelList, keychain: KeychainManager, meter: Meter, transports: Transports
  ) async -> (SearchEvidence, chosen: (CloudModelRoutineCalls.Setting, PhaseResult)?) {
    let menu = CloudModelRoutineCalls.Setting.searchMenu(provider)
    func evidence(
      _ attempts: [SettingAttempt], _ outcome: SearchOutcome, interruption: ErrorClass? = nil,
      chosen: String? = nil
    ) -> SearchEvidence {
      SearchEvidence(
        trigger: .requestRejected, fallbackSetting: fallback.label, attempts: attempts,
        outcome: outcome, interruption: interruption, chosenSetting: chosen,
        issueIntent: outcome == .requestRejectedSearchExhausted ? callRecipeIssueTitle : nil)
    }
    let alternatives = menu.filter { $0 != fallback }
    guard menu.contains(fallback),
      alternatives.count == CloudModelRoutineCalls.Limits.alternativeSettings(provider)
    else { return (evidence([], .fallbackOutsideMenu), nil) }

    var attempts: [SettingAttempt] = []
    for setting in alternatives {
      let row = searchRow(
        provider: provider, id: id, released: released, policy: setting.policy,
        fallback: fallbackCapabilities, allowsFileBatch: allowsFileBatch, medianMs: nil)
      guard let snapshot = try? listAdding(row, to: list),
        resolvesSetting(
          provider, id: id, policy: setting.policy,
          supportsChatCompletions: fallbackCapabilities.supportsChatCompletions,
          allowsFileBatch: allowsFileBatch, in: snapshot)
      else { return (evidence(attempts, .interrupted, interruption: .other), nil) }

      let screening = await runPhase(
        id: id, provider: provider, setting: setting, phase: .screening, inputIndices: [0],
        list: snapshot, keychain: keychain, meter: meter, transports: transports)
      guard screening.provesSetting else {
        attempts.append(
          .init(
            setting: setting.label, request: row.request, screening: screening,
            confirmation: nil, qualified: false))
        if let failure = screening.errorClass, !searchContinues(after: failure) {
          return (evidence(attempts, .interrupted, interruption: failure), nil)
        }
        continue
      }
      let confirmation = await runPhase(
        id: id, provider: provider, setting: setting, phase: .confirmation,
        inputIndices: inputIndices, list: snapshot, keychain: keychain, meter: meter,
        transports: transports)
      let qualified = confirmation.provesSetting
      attempts.append(
        .init(
          setting: setting.label, request: row.request, screening: screening,
          confirmation: confirmation, qualified: qualified))
      if qualified {
        return (evidence(attempts, .passed, chosen: setting.label), (setting, confirmation))
      }
      if let failure = confirmation.errorClass, !searchContinues(after: failure) {
        return (evidence(attempts, .interrupted, interruption: failure), nil)
      }
    }
    let allRejected = attempts.allSatisfy {
      ($0.confirmation?.errorClass ?? $0.screening.errorClass) == .requestRejected
    }
    return (
      evidence(
        attempts,
        allRejected && attempts.count == alternatives.count
          ? .requestRejectedSearchExhausted : .noQualifyingSetting),
      nil
    )
  }
}
