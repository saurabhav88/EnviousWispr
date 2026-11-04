import CryptoKit
import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #4353 PR 5 (D7 detail, Receipt and proposal contract): what one routine run measured.
///
/// It holds only ids, counts, hashes, closed classes and complete proposed rows; no prompt,
/// reply text, header, key or raw provider error. It is NOT publication-ready: binding the
/// receipt to the exact proposed list bytes is the proposal step's job (Chunk 6).
struct CloudModelRoutineReceipt: Encodable {
  static let schema = 1

  struct Provenance: Encodable {
    let repository: String?
    let workflow: String?
    let runID: String?
    let runAttempt: String?
    let event: String?
    let sourceSHA: String?

    /// GitHub Actions' own variables, when present. Nothing else from the environment.
    static func from(environment: [String: String]) -> Provenance {
      Provenance(
        repository: environment["GITHUB_REPOSITORY"], workflow: environment["GITHUB_WORKFLOW"],
        runID: environment["GITHUB_RUN_ID"], runAttempt: environment["GITHUB_RUN_ATTEMPT"],
        event: environment["GITHUB_EVENT_NAME"], sourceSHA: environment["GITHUB_SHA"])
    }
  }

  struct ListEvidence: Encodable {
    let updated: String
    let revision: String
    let sha256: String
  }

  struct InputEvidence: Encodable {
    let id: String
    let sha256: String
  }

  struct AbsenceEvidence: Encodable, Equatable {
    let state: String
    let firstMissingDay: String?
    let weeks: Int?
    let hiddenReason: String?

    init(_ absence: CloudModelRoutinePolicy.RowAbsence) {
      switch absence {
      case .present:
        (state, firstMissingDay, weeks, hiddenReason) = ("present", nil, nil, nil)
      case .missingForRoutineKey(let day, let count):
        (state, firstMissingDay, weeks, hiddenReason) = ("missingForRoutineKey", day, count, nil)
      case .hide(let proposal):
        (state, firstMissingDay, weeks, hiddenReason) = ("hide", nil, nil, proposal.hiddenReason)
      case .reappeared:
        (state, firstMissingDay, weeks, hiddenReason) = ("reappeared", nil, nil, nil)
      case .alreadyHidden(let present):
        (state, firstMissingDay, weeks, hiddenReason) = (
          present ? "alreadyHiddenPresent" : "alreadyHiddenMissing", nil, nil, nil
        )
      }
    }
  }

  struct CandidateResult: Encodable {
    let id: String
    let setting: String?
    /// `pass`, `fail`, or `notTried` (no list spelling for the compiled fallback).
    let outcome: String
    let errorClass: CloudModelRoutine.ErrorClass?
    let perInputMs: [Int]
    let medianMs: Int?
    /// Every success needed an OpenAI parameter strip. The row still records the unchanged
    /// fallback setting; the adaptation is not evidence for any other setting.
    let passViaAdaptation: Bool
    /// The provider's own date as it came (ISO 8601), apart from the `released` day.
    let sourceDate: String?
    /// The proposed list resolves this id like the captured list does (nil when not checked).
    let resolvesTheSame: Bool?
    let row: CloudModelRoutine.ProposedRow?
  }

  struct ExcludedModel: Encodable {
    let id: String
    /// A `LLMModelDiscovery.CatalogExclusion` raw value.
    let reason: String
  }

  struct ProviderResult: Encodable {
    let provider: String
    /// `complete` or `failed`. A failed catalog proposes nothing and advances no history.
    let catalog: String
    /// A closed class, never an error's text or type name.
    let catalogFailure: CloudModelRoutine.ErrorClass?
    let identityCount: Int
    /// Every excluded id with the shipped rule that removed it; `excluded` counts them.
    let excludedModels: [ExcludedModel]
    let excluded: [String: Int]
    let dispositions: [String: String]
    let candidates: [CandidateResult]
    let absence: [String: AbsenceEvidence]
    let stale: Bool
  }

  let schema: Int
  let provenance: Provenance
  let observedAt: Date
  let list: ListEvidence
  let inputs: [InputEvidence]
  /// `success`, `partial` (some candidate failed), `failure` (a catalog failed or the ledger
  /// refused a call) or `nochange` (nothing to propose).
  let outcome: String
  let providers: [ProviderResult]
  let calls: [CloudModelRoutineCalls.ExchangeRecord]
  /// One entry per granted physical exchange, in send order.
  let physicalRequests: [CloudModelRoutine.PhysicalRequestEvidence]
  let logicalCalls: Int
  let physicalExchanges: Int
  let unrecordedExchanges: Int
  let refusals: Int
  let history: CloudModelRoutinePolicy.AbsenceHistory
  let publicationReady: Bool

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The receipt as JSON, refused if any of `secrets` appears in it. The match is never
  /// printed or returned.
  func encoded(refusing secrets: [String]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    let text = String(decoding: data, as: UTF8.self)
    for secret in secrets where !secret.isEmpty && text.contains(secret) {
      throw CloudModelRoutine.HarnessFailure.secretInOutput
    }
    return data
  }
}

extension CloudModelRoutine {

  // MARK: - Run

  /// One routine run over the three providers, serially. Requires all keys (the caller
  /// checks `Keys.from(environment:)` first, before any request).
  static func run(
    keys: Keys, list: CloudModelList, history: CloudModelRoutinePolicy.AbsenceHistory,
    observedAt: Date, transports: Transports, provenance: CloudModelRoutineReceipt.Provenance
  ) async -> CloudModelRoutineReceipt {
    let meter = Meter()
    let keychain = keys.keychain
    var history = history
    var providers: [CloudModelRoutineReceipt.ProviderResult] = []
    var catalogFailed = false
    var anyCandidateFailed = false
    var anyProposal = false

    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let discovery = LLMModelDiscovery(cloudModelList: list, transport: transports.catalog)
      let outcome: CloudModelRoutinePolicy.CatalogOutcome
      var catalogFailure: ErrorClass?
      var catalog: LLMModelDiscovery.CloudCatalog?
      do {
        let fetched = try await discovery.fetchCatalog(
          provider: provider, apiKey: keys.values[provider] ?? "")
        catalog = fetched
        outcome = .complete(fetched)
      } catch {
        catalogFailure = errorClass(error)
        outcome = .failed
        catalogFailed = true
      }

      let observed = CloudModelRoutinePolicy.observeAbsence(
        history: history, provider: provider, outcome: outcome, observedAt: observedAt, list: list)
      history = observed.history
      var absence: [String: CloudModelRoutineReceipt.AbsenceEvidence] = [:]
      var stale = false
      switch observed.result {
      case .observed(let rows):
        for (id, row) in rows {
          absence[id] = .init(row)
          if case .hide = row { anyProposal = true }
        }
      case .stale: stale = true
      case .discoveryFailed: break
      }

      var candidates: [CloudModelRoutineReceipt.CandidateResult] = []
      var dispositions: [String: String] = [:]
      var excluded: [String: Int] = [:]
      var excludedModels: [CloudModelRoutineReceipt.ExcludedModel] = []
      if let catalog {
        for item in catalog.excluded {
          excluded[item.reason.rawValue, default: 0] += 1
          excludedModels.append(.init(id: item.id, reason: item.reason.rawValue))
        }
        let selection = CloudModelRoutinePolicy.selectCandidates(catalog: catalog, list: list)
        dispositions = selection.dispositions.mapValues(\.rawValue)
        for candidate in selection.selected {
          let result = await sweep(
            candidate, provider: provider, keychain: keychain, list: list, meter: meter,
            transports: transports)
          if result.outcome != "pass" { anyCandidateFailed = true }
          if result.row != nil { anyProposal = true }
          candidates.append(result)
        }
      }

      providers.append(
        .init(
          provider: provider.rawValue, catalog: catalog == nil ? "failed" : "complete",
          catalogFailure: catalogFailure, identityCount: catalog?.identities.count ?? 0,
          excludedModels: excludedModels, excluded: excluded, dispositions: dispositions, candidates: candidates,
          absence: absence, stale: stale))
    }

    let ledger = meter.snapshot
    let outcome: String
    if catalogFailed || meter.refusals > 0 {
      outcome = "failure"
    } else if anyCandidateFailed {
      outcome = "partial"
    } else if anyProposal {
      outcome = "success"
    } else {
      outcome = "nochange"
    }
    return CloudModelRoutineReceipt(
      schema: CloudModelRoutineReceipt.schema, provenance: provenance, observedAt: observedAt,
      list: .init(
        updated: list.updated, revision: list.revision,
        sha256: CloudModelRoutineReceipt.sha256(list.documentBytes)),
      inputs: inputs.map {
        .init(id: $0.id, sha256: CloudModelRoutineReceipt.sha256(Data($0.text.utf8)))
      },
      outcome: outcome, providers: providers, calls: ledger.records,
      physicalRequests: meter.requestEvidence,
      logicalCalls: ledger.logicalCount, physicalExchanges: ledger.physicalCount,
      unrecordedExchanges: ledger.unrecordedCount, refusals: meter.refusals, history: history,
      publicationReady: false)
  }

  /// The fallback sweep of one candidate: three fixed dictations with the shipped setting.
  static func sweep(
    _ candidate: LLMModelDiscovery.DiscoveryCandidate, provider: LLMProvider,
    keychain: KeychainManager, list: CloudModelList, meter: Meter, transports: Transports
  ) async -> CloudModelRoutineReceipt.CandidateResult {
    let id = candidate.id
    let capabilities = provider.modelCapabilities(model: id, list: list)
    let allowsFileBatch = provider.allowsFileBatch(model: id, list: list)
    let sourceDate = candidate.releaseDate.map { ISO8601DateFormatter().string(from: $0) }
    guard let policy = fallbackPolicy(provider, capabilities: capabilities),
      let setting = CloudModelRoutineCalls.Setting(policy, provider: provider),
      let keyID = keyID(provider),
      let connector = connector(
        provider, keychain: keychain, list: list,
        executor: meter.wrap(transports.polish(provider), provider: provider))
    else {
      return .init(
        id: id, setting: nil, outcome: "notTried", errorClass: nil, perInputMs: [], medianMs: nil,
        passViaAdaptation: false, sourceDate: sourceDate, resolvesTheSame: nil, row: nil)
    }
    // The omission memo starts empty for the tested setting; never cleared inside a call.
    if provider == .openAI { OpenAIConnector.resetOmissions(model: id) }

    var times: [Double] = []
    var failure: ErrorClass?
    for (index, input) in inputs.enumerated() {
      let call = CloudModelRoutineCalls.LogicalCallID(
        provider: provider, model: id, setting: setting, phase: .fallback, input: index)
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
          Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
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

    let adapted =
      provider == .openAI && !OpenAIConnector.memoizedOmissions(model: id).isEmpty
    let perInputMs = times.map { Int($0.rounded()) }
    let median = times.isEmpty ? nil : Int(LiveSweepSupport.medianMs(times).rounded())
    guard failure == nil, times.count == inputs.count else {
      return .init(
        id: id, setting: setting.label, outcome: "fail", errorClass: failure ?? .other,
        perInputMs: perInputMs, medianMs: median, passViaAdaptation: adapted,
        sourceDate: sourceDate, resolvesTheSame: nil, row: nil)
    }

    let row = ProposedRow(
      provider: provider.rawValue, id: id, released: releasedDay(candidate.releaseDate),
      recommended: false, hidden: false, request: RequestJSON(policy),
      supportsChatCompletions: capabilities.supportsChatCompletions,
      allowsFileBatch: allowsFileBatch,
      medianPolishMs: median.flatMap { CloudModelList.medianPolishMsRange.contains($0) ? $0 : nil })
    let same: Bool
    if let proposed = try? listAdding(row, to: list) {
      same = resolvesTheSame(provider, id: id, before: list, after: proposed)
    } else {
      same = false
    }
    return .init(
      id: id, setting: setting.label, outcome: same ? "pass" : "fail",
      errorClass: same ? nil : .other, perInputMs: perInputMs, medianMs: median,
      passViaAdaptation: adapted, sourceDate: sourceDate, resolvesTheSame: same,
      row: same ? row : nil)
  }
}
