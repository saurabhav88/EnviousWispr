import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// What an import attempt reports, and where (#2997, plan §3d).
///
/// One PostHog row per attempt (`snippets.imported`), a breadcrumb per terminal so a later
/// crash carries the import path, and exactly ONE app-owned Sentry error: the store refusing
/// an approved row as a duplicate although the locked baseline matched the review's, which
/// only our own row builder and commit disagreeing about "same trigger" can produce.
/// Everything here is shape, never content: counts, closed vocabularies, and a Bool. No
/// trigger, expansion, file name, path or error description reaches either vendor.
/// Observation only: nothing throws, nothing alters the flow.

/// The closed `source` vocabulary. A source's `sourceID` must be one of these raw values.
enum SnippetImportTelemetrySource: String, Sendable, CaseIterable {
  case paste
  case fileJSON = "file_json"
  case fileCSV = "file_csv"
  case fileText = "file_text"
  case fileOther = "file_other"
  case wisprFlow = "wispr_flow"
  case typeWhisper = "typewhisper"
}

/// The closed `outcome` vocabulary.
enum SnippetImportTelemetryOutcome: String, Sendable, CaseIterable {
  case completed
  case nothingFound = "nothing_found"
  case nothingCompatible = "nothing_compatible"
  case nothingApproved = "nothing_approved"
  case stale
  case failed
}

/// The closed `failure` vocabulary, present only on `failed`. Raw values, never descriptions.
enum SnippetImportTelemetryFailure: String, Sendable, CaseIterable {
  case unsupportedType = "unsupported_type"
  case tooLarge = "too_large"
  case unreadable
  case notOurs = "not_ours"
  case newerVersion = "newer_version"
  case malformed
  case tooMany = "too_many"
  case unusableEntry = "unusable_entry"
  case appNotFound = "app_not_found"
  case appStoreUnreadable = "app_store_unreadable"
  case storeBusy = "store_busy"
  case storeUnreadable = "store_unreadable"
  case coordinationUnavailable = "coordination_unavailable"
  case writeFailed = "write_failed"
  case invariantViolation = "invariant_violation"

  /// A load or parse error, classified. Unknown errors read as `unreadable`: the source
  /// could not be turned into candidates, and the vocabulary is closed on purpose.
  static func forLoadError(_ error: any Error) -> SnippetImportTelemetryFailure {
    switch error {
    case let source as SnippetImportSourceError:
      switch source {
      case .unsupportedType: return .unsupportedType
      case .tooLarge: return .tooLarge
      case .unreadable: return .unreadable
      case .malformedCSV: return .malformed
      case .exportedSnippets(let transfer):
        switch transfer {
        case .notAnEnviousWisprSnippetsFile: return .notOurs
        case .unsupportedVersion: return .newerVersion
        case .malformed: return .malformed
        }
      }
    case let validation as SnippetImportValidationError:
      switch validation {
      case .tooManySnippets: return .tooMany
      case .tooMuchText: return .tooLarge
      case .triggerTooLong, .expansionTooLong, .unusableTrigger, .unusableExpansion:
        return .unusableEntry
      }
    case let app as SnippetImportAppError:
      switch app {
      case .appNotFound: return .appNotFound
      case .unreadable: return .appStoreUnreadable
      case .tooManySourceEntries: return .tooMany
      }
    default:
      return .unreadable
    }
  }

  /// A commit error, classified. A duplicate refused at commit is the invariant violation:
  /// the review was built from the same list the commit compared against.
  static func forCommitError(_ error: SnippetsCoordinator.SnippetImportCommitError)
    -> SnippetImportTelemetryFailure
  {
    switch error {
    case .validation(let validation):
      switch validation {
      case .duplicateTrigger: return .invariantViolation
      case .triggerEmpty, .expansionEmpty, .keywordNotOneWord: return .unusableEntry
      }
    case .store(let store):
      switch store {
      case .busy: return .storeBusy
      case .existingFileUnreadable: return .storeUnreadable
      case .coordinationUnavailable: return .coordinationUnavailable
      case .writeFailed: return .writeFailed
      // `commitImport` maps this to `.stale`; a coordinator that returned it as `failed`
      // would be our defect. It does NOT file the Sentry error: that is gated on the exact
      // duplicate-at-commit case by the flow model, never on this classification.
      case .listChangedDuringReview: return .invariantViolation
      }
    case .other:
      return .writeFailed
    }
  }
}

/// The count-only facts of one attempt.
struct SnippetImportAttemptReport: Sendable, Equatable {
  var source: SnippetImportTelemetrySource
  var outcome: SnippetImportTelemetryOutcome
  var candidates = 0
  var added = 0
  var skippedExisting = 0
  var skippedDuplicateBatch = 0
  var skippedUnticked = 0
  var excluded = 0
  var failure: SnippetImportTelemetryFailure?
}

/// The one Sentry-alerting shape an import can file (#2997). Carries counts only.
///
/// Filed when `SnippetsManager.importSnippets` rejects an approved addition as a duplicate
/// even though the locked baseline MATCHED the review's. Review built its rows from that same
/// list, so an approved row cannot collide unless the row builder and the commit disagree
/// about "same spoken words". A user, a disk, or another process cannot produce it: another
/// process changing the list is the `stale` outcome, never this.
struct SnippetImportReviewCommitMismatch: Error, StableSentryErrorIdentity, Sendable {
  let approved: Int
  let baseline: Int

  var sentryFingerprintDescriptor: String { "SnippetImportReviewCommitMismatch" }
  var sentrySemanticID: String { "snippets.import.review_commit_mismatch" }
}

/// One reporter per sheet, latching per attempt so an attempt can never emit twice even if a
/// terminal is reached by two paths.
@MainActor
final class SnippetImportReporter {
  static let stage = "snippets_import"

  private var reported = Set<UUID>()
  private let emit: @MainActor (SnippetImportAttemptReport) -> Void

  /// Production wiring: PostHog through `TelemetryService`, plus the breadcrumb.
  static func live() -> SnippetImportReporter {
    SnippetImportReporter { report in
      TelemetryService.shared.snippetsImported(
        source: report.source.rawValue, outcome: report.outcome.rawValue,
        candidates: report.candidates, added: report.added,
        skippedExisting: report.skippedExisting,
        skippedDuplicateBatch: report.skippedDuplicateBatch,
        skippedUnticked: report.skippedUnticked, excluded: report.excluded,
        failure: report.failure?.rawValue)
    }
  }

  init(emit: @escaping @MainActor (SnippetImportAttemptReport) -> Void) {
    self.emit = emit
  }

  /// Report an attempt's terminal once. A second call for the same attempt is ignored.
  func report(attempt: UUID, _ report: SnippetImportAttemptReport) {
    guard reported.insert(attempt).inserted else { return }
    SentryBreadcrumb.add(
      stage: Self.stage, message: "import \(report.outcome.rawValue)",
      level: report.outcome == .failed ? .warning : .info,
      data: Self.breadcrumbData(report))
    emit(report)
  }

  /// Files the one app-owned error. Separate from `report` so the PostHog row and the Sentry
  /// event are each exactly once, and so tests can assert the pair.
  func fileReviewCommitMismatch(approved: Int, baseline: Int) {
    SentryBreadcrumb.captureError(
      SnippetImportReviewCommitMismatch(approved: approved, baseline: baseline),
      category: .stateMismatch, stage: Self.stage,
      extra: ["approved": approved, "baseline": baseline],
      fingerprintDetail: "review_commit_mismatch")
  }

  /// The breadcrumb payload: the same counts as the PostHog row, nothing else.
  static func breadcrumbData(_ report: SnippetImportAttemptReport) -> [String: Any] {
    var data: [String: Any] = [
      "source": report.source.rawValue,
      "outcome": report.outcome.rawValue,
      "candidates": report.candidates,
      "added": report.added,
      "skipped_existing": report.skippedExisting,
      "skipped_duplicate_batch": report.skippedDuplicateBatch,
      "skipped_unticked": report.skippedUnticked,
      "excluded": report.excluded,
    ]
    if let failure = report.failure { data["failure"] = failure.rawValue }
    return data
  }
}
