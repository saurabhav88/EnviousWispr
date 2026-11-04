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
    let ref: String?
    let sourceSHA: String?

    /// GitHub Actions' own variables, when present. Nothing else from the environment.
    static func from(environment: [String: String]) -> Provenance {
      Provenance(
        repository: environment["GITHUB_REPOSITORY"], workflow: environment["GITHUB_WORKFLOW"],
        runID: environment["GITHUB_RUN_ID"], runAttempt: environment["GITHUB_RUN_ATTEMPT"],
        event: environment["GITHUB_EVENT_NAME"], ref: environment["GITHUB_REF"],
        sourceSHA: environment["GITHUB_SHA"])
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

  struct CandidateResult: Encodable {
    let id: String
    /// The FALLBACK setting (the compiled rule for this unlisted id).
    let setting: String?
    /// `pass` (fallback), `passViaSearch` (the fallback was rejected and a searched setting
    /// proved itself; `row` carries that setting), `fail`, or `notTried` (no list spelling
    /// for the compiled fallback).
    let outcome: String
    /// The fallback's closed failure class; a `passViaSearch` keeps `requestRejected` here.
    let errorClass: CloudModelRoutine.ErrorClass?
    /// The fallback's timings; a searched setting's timings are in `search`.
    let perInputMs: [Int]
    let medianMs: Int?
    /// Every success needed an OpenAI parameter strip. The row still records the unchanged
    /// fallback setting; the adaptation is not evidence for any other setting.
    let passViaAdaptation: Bool
    /// The provider's own date as it came (ISO 8601), apart from the `released` day.
    let sourceDate: String?
    /// For a fallback pass: the proposed list resolves this id like the captured list does.
    /// For a searched pass: it resolves exactly the chosen setting with the fallback's chat
    /// eligibility and file batching. Nil when not checked.
    let resolvesTheSame: Bool?
    let row: CloudModelRoutine.ProposedRow?
    /// The fallback phase as measured; never replaced by a search result.
    let fallback: CloudModelRoutine.PhaseResult?
    /// Present only when the fallback ended in `requestRejected`.
    let search: CloudModelRoutine.SearchEvidence?
    /// For a proposed row: how the id and its supported dated spellings resolve in the
    /// captured list (`before`) and in the list with the row added (`after`). The proposal
    /// checker compares these; it never re-derives capability or dated-id rules.
    let resolution: [CloudModelRoutine.VariantResolution]?
  }

  struct ExcludedModel: Encodable {
    let id: String
    /// A `LLMModelDiscovery.CatalogExclusion` raw value.
    let reason: String
  }

  struct ProviderResult: Encodable {
    let provider: String
    /// `complete` or `failed`. A failed catalog proposes nothing.
    let catalog: String
    /// A closed class, never an error's text or type name.
    let catalogFailure: CloudModelRoutine.ErrorClass?
    let identityCount: Int
    /// Every excluded id with the shipped rule that removed it; `excluded` counts them.
    let excludedModels: [ExcludedModel]
    let excluded: [String: Int]
    let dispositions: [String: String]
    let candidates: [CandidateResult]
  }

  let schema: Int
  let provenance: Provenance
  let observedAt: Date
  let list: ListEvidence
  let inputs: [InputEvidence]
  /// The instrument's view: `success`, `partial` (some candidate failed), `failure` (a
  /// catalog failed or the ledger refused a call) or `nochange` (nothing this receipt
  /// proposes). Not final: the proposal step (`propose.py`) owns the final proposal or no-change
  /// classification and never upgrades `failure` or `partial`.
  let outcome: String
  let providers: [ProviderResult]
  let calls: [CloudModelRoutineCalls.ExchangeRecord]
  /// One entry per granted physical exchange, in send order.
  let physicalRequests: [CloudModelRoutine.PhysicalRequestEvidence]
  let logicalCalls: Int
  let physicalExchanges: Int
  let unrecordedExchanges: Int
  let refusals: Int
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
    keys: Keys, list: CloudModelList, observedAt: Date, transports: Transports, provenance: CloudModelRoutineReceipt.Provenance
  ) async -> CloudModelRoutineReceipt {
    let meter = Meter()
    let keychain = keys.keychain
    var providers: [CloudModelRoutineReceipt.ProviderResult] = []
    var catalogFailed = false
    var anyCandidateFailed = false
    var anyProposal = false

    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let discovery = LLMModelDiscovery(cloudModelList: list, transport: transports.catalog)
      var catalogFailure: ErrorClass?
      var catalog: LLMModelDiscovery.CloudCatalog?
      do {
        catalog = try await discovery.fetchCatalog(
          provider: provider, apiKey: keys.values[provider] ?? "")
      } catch {
        catalogFailure = errorClass(error)
        catalogFailed = true
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
          if result.outcome != "pass" && result.outcome != "passViaSearch" {
            anyCandidateFailed = true
          }
          if result.row != nil { anyProposal = true }
          candidates.append(result)
        }
      }

      providers.append(
        .init(
          provider: provider.rawValue, catalog: catalog == nil ? "failed" : "complete",
          catalogFailure: catalogFailure, identityCount: catalog?.identities.count ?? 0,
          excludedModels: excludedModels, excluded: excluded, dispositions: dispositions,
          candidates: candidates))
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
      unrecordedExchanges: ledger.unrecordedCount, refusals: meter.refusals,
      publicationReady: false)
  }

  /// One candidate: three fixed dictations with the shipped (fallback) setting, then the
  /// settings search only if the fallback ended in `requestRejected`.
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
      keyID(provider) != nil
    else {
      return .init(
        id: id, setting: nil, outcome: "notTried", errorClass: nil, perInputMs: [], medianMs: nil,
        passViaAdaptation: false, sourceDate: sourceDate, resolvesTheSame: nil, row: nil,
        fallback: nil, search: nil, resolution: nil)
    }
    let fallback = await runPhase(
      id: id, provider: provider, setting: setting, phase: .fallback, inputIndices: inputIndices,
      list: list, keychain: keychain, meter: meter, transports: transports)
    let adapted = fallback.memoAdapted
    let released = releasedDay(candidate.releaseDate)

    guard fallback.completed else {
      guard fallback.errorClass == .requestRejected else {
        return .init(
          id: id, setting: setting.label, outcome: "fail",
          errorClass: fallback.errorClass ?? .other, perInputMs: fallback.perInputMs,
          medianMs: fallback.medianMs, passViaAdaptation: adapted, sourceDate: sourceDate,
          resolvesTheSame: nil, row: nil, fallback: fallback, search: nil, resolution: nil)
      }
      let (evidence, chosen) = await search(
        id: id, provider: provider, fallback: setting, fallbackCapabilities: capabilities,
        allowsFileBatch: allowsFileBatch, released: released, list: list, keychain: keychain,
        meter: meter, transports: transports)
      var row: ProposedRow?
      var resolves: Bool?
      var resolution: [VariantResolution]?
      if let (chosenSetting, confirmation) = chosen {
        let candidateRow = searchRow(
          provider: provider, id: id, released: released, policy: chosenSetting.policy,
          fallback: capabilities, allowsFileBatch: allowsFileBatch,
          medianMs: confirmation.medianMs)
        let proposed = try? listAdding(candidateRow, to: list)
        let ok =
          proposed.map {
            resolvesSetting(
              provider, id: id, policy: chosenSetting.policy,
              supportsChatCompletions: capabilities.supportsChatCompletions,
              allowsFileBatch: allowsFileBatch, in: $0)
          } ?? false
        resolves = ok
        row = ok ? candidateRow : nil
        if ok, let proposed {
          resolution = Self.resolution(provider, id: id, before: list, after: proposed)
        }
      }
      return .init(
        id: id, setting: setting.label, outcome: row == nil ? "fail" : "passViaSearch",
        errorClass: .requestRejected, perInputMs: fallback.perInputMs,
        medianMs: fallback.medianMs, passViaAdaptation: adapted, sourceDate: sourceDate,
        resolvesTheSame: resolves, row: row, fallback: fallback, search: evidence,
        resolution: resolution)
    }

    let median = fallback.medianMs
    let row = ProposedRow(
      provider: provider.rawValue, id: id, released: released,
      recommended: false, hidden: false, request: RequestJSON(policy),
      supportsChatCompletions: capabilities.supportsChatCompletions,
      allowsFileBatch: allowsFileBatch,
      medianPolishMs: median.flatMap { CloudModelList.medianPolishMsRange.contains($0) ? $0 : nil })
    let same: Bool
    var resolution: [VariantResolution]?
    if let proposed = try? listAdding(row, to: list) {
      same = resolvesTheSame(provider, id: id, before: list, after: proposed)
      if same { resolution = Self.resolution(provider, id: id, before: list, after: proposed) }
    } else {
      same = false
    }
    return .init(
      id: id, setting: setting.label, outcome: same ? "pass" : "fail",
      errorClass: same ? nil : .other, perInputMs: fallback.perInputMs, medianMs: median,
      passViaAdaptation: adapted, sourceDate: sourceDate, resolvesTheSame: same,
      row: same ? row : nil, fallback: fallback, search: nil, resolution: resolution)
  }
}
