import EnviousWisprCore
import Foundation

/// The Your Words list's one prepared result (#4086, finding D1). Search, the
/// category and Auto-learned pills, the count, page count, page slice, Select All
/// and the empty state all read the SAME filtered, sorted list; before this, each
/// read re-filtered and re-sorted the whole library, so one redraw or Edit click
/// paid for that work many times over.
///
/// The cache key is cheap on purpose: the coordinator's write counter stands in
/// for the library, so a read never compares or hashes the word array. A read with
/// an unchanged key returns the kept result; any change to the library, the query,
/// a pill or the locale (which the search and the sort both read) rebuilds it once.
/// Page changes, selection and Edit are not inputs, so they reuse it.
///
/// A plain reference held in the view's `@State`, not observable state: filling the
/// cache during a read is not a change any view should redraw for.
@MainActor
final class CustomTermListProjection {
  struct Input: Equatable {
    let libraryRevision: Int
    let query: String
    let category: WordCategory?
    let autoLearnedOnly: Bool
    let localeIdentifier: String
  }

  struct Result {
    let words: [CustomWord]
    /// `CustomTermListPolicy.selectableIDs` over `words`: Select All's target.
    let selectableIDs: Set<UUID>
    var pageCount: Int { CustomTermListPolicy.pageCount(of: words.count) }
  }

  private var kept: (input: Input, result: Result)?

  /// The kept result when `input` is unchanged; otherwise `build()` once, kept.
  func result(for input: Input, build: () -> Result) -> Result {
    if let kept, kept.input == input { return kept.result }
    let result = build()
    kept = (input, result)
    return result
  }
}
