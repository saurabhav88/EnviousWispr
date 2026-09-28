import Foundation
import Testing

@testable import EnviousWisprServices

/// #3269: the exact file a feedback report carries when the user ticks "Include diagnostics".
/// Expected bytes are literals. The envelope that carries it is FeedbackSenderTests.
@Suite("Feedback diagnostics file (#3269)", .tags(.observabilityContract))
struct FeedbackDiagnosticsSnapshotTests {

  static let takeID = "7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
  static let joinKey = "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

  /// A diary snapshot as the diary writes it.
  static let diary = Data(
    """
    {"schema_version":1,"entries":[{"take_id":"\(takeID)","first_observed_at":"2026-09-21T14:13:20Z",
    "terminal":{"backend":"parakeet","result":"completed","duration_ms":2400}}]}
    """.utf8)

  @Test("With a saved id: schema, the diary unchanged, and the join key")
  func fileWithJoinKey() throws {
    let snapshot = try #require(
      FeedbackDiagnosticsSnapshot.make(diarySnapshot: Self.diary, joinKey: Self.joinKey))
    let expected = """
      {
        "analytics_distinct_id" : "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
        "diary" : {
          "entries" : [
            {
              "first_observed_at" : "2026-09-21T14:13:20Z",
              "take_id" : "7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B",
              "terminal" : {
                "backend" : "parakeet",
                "duration_ms" : 2400,
                "result" : "completed"
              }
            }
          ],
          "schema_version" : 1
        },
        "schema_version" : 1
      }
      """
    #expect(snapshot.text == expected)
    #expect(snapshot.data == Data(expected.utf8))
  }

  @Test(
    "Without a saved id, or with a malformed one, the join field is absent",
    arguments: [nil, "not-an-id"])
  func fileWithoutJoinKey(joinKey: String?) throws {
    let snapshot = try #require(
      FeedbackDiagnosticsSnapshot.make(diarySnapshot: Self.diary, joinKey: joinKey))
    let object = try JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any]
    #expect(object?.keys.sorted() == ["diary", "schema_version"])
  }

  @Test(
    "No diary, an empty diary or an unreadable one gives no file, even with a saved id",
    arguments: [
      nil, Data(#"{"schema_version":1,"entries":[]}"#.utf8), Data("not json".utf8),
      Data(#"{"schema_version":2,"entries":[]}"#.utf8),
    ])
  func noDiaryNoFile(diary: Data?) {
    #expect(FeedbackDiagnosticsSnapshot.make(diarySnapshot: diary, joinKey: Self.joinKey) == nil)
  }
}
