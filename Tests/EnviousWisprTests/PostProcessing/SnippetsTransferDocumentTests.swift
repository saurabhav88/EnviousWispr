import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2997 — the `EnviousWispr Snippets.json` file, written by Export and read by Import.
///
/// `.productOutcome`: when this fails, a user restoring on a new Mac is told their own
/// export is damaged, or a file from a newer version is read wrong, or someone else's JSON
/// is mistaken for ours.
@Suite("Snippets transfer document (#2997)", .tags(.productOutcome))
struct SnippetsTransferDocumentTests {

  private func encoded(_ document: SnippetsTransferDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
  }

  @Test("A v1 export decodes back to the same snippets and keyword")
  func roundTrip() throws {
    let snippets = [
      Snippet(trigger: "my email address", expansion: "hello@example.com"),
      Snippet(trigger: "sign off", expansion: "Best,\nSaurabh\n"),
    ]
    let written = SnippetsTransferDocument(
      version: SnippetsManager.currentVersion, keyword: "backslash", snippets: snippets)
    let read = try SnippetsTransferDocument(data: try encoded(written))
    #expect(read.version == written.version)
    #expect(read.keyword == written.keyword)
    #expect(read.snippets.map(\.id) == snippets.map(\.id))
    #expect(read.snippets.map(\.trigger) == snippets.map(\.trigger))
    #expect(read.snippets.map(\.expansion) == snippets.map(\.expansion))
  }

  /// The bytes v1 (#2584) wrote for one snippet, captured literally: sorted keys, pretty
  /// printed, `createdAt` as seconds since the reference date. A change to the encoder or
  /// the field names fails HERE, against shipped bytes, not against a fresh round trip.
  private static let shippedV1 = """
    {
      "keyword" : "backslash",
      "snippets" : [
        {
          "createdAt" : 778000000,
          "expansion" : "hello@example.com",
          "id" : "5F3A2C1E-0B7D-4E8A-9C21-3D4E5F6A7B8C",
          "trigger" : "my email address"
        }
      ],
      "version" : 1
    }
    """

  @Test("The literal bytes v1 shipped decode with every field intact")
  func shippedV1BytesDecode() throws {
    let read = try SnippetsTransferDocument(data: Data(Self.shippedV1.utf8))
    #expect(read.version == 1)
    #expect(read.keyword == "backslash")
    #expect(read.snippets.count == 1)
    #expect(read.snippets[0].id == UUID(uuidString: "5F3A2C1E-0B7D-4E8A-9C21-3D4E5F6A7B8C"))
    #expect(read.snippets[0].trigger == "my email address")
    #expect(read.snippets[0].expansion == "hello@example.com")
    #expect(read.snippets[0].createdAt == Date(timeIntervalSinceReferenceDate: 778_000_000))
  }

  @Test("Encoding one snippet the way Export does reproduces the shipped bytes")
  func encoderReproducesShippedBytes() throws {
    let document = SnippetsTransferDocument(
      version: 1, keyword: "backslash",
      snippets: [
        Snippet(
          id: UUID(uuidString: "5F3A2C1E-0B7D-4E8A-9C21-3D4E5F6A7B8C")!,
          trigger: "my email address", expansion: "hello@example.com",
          createdAt: Date(timeIntervalSinceReferenceDate: 778_000_000))
      ])
    #expect(String(decoding: try encoded(document), as: UTF8.self) == Self.shippedV1)
  }

  @Test("A file from a newer version is refused with the update message, not 'damaged'")
  func newerVersionIsUnsupported() throws {
    let data = try encoded(
      SnippetsTransferDocument(
        version: SnippetsManager.currentVersion + 1, keyword: "backslash", snippets: []))
    #expect(throws: SnippetsTransferError.unsupportedVersion(SnippetsManager.currentVersion + 1)) {
      try SnippetsTransferDocument(data: data)
    }
  }

  @Test("Valid JSON that is not ours is 'not an EnviousWispr snippets file'")
  func foreignJSONIsNotOurs() {
    for text in [
      "[]", "[{\"name\":\"a\",\"text\":\"b\"}]", "{\"format\":\"custom-words\",\"version\":1}",
      "42", "\"a string\"", "{}", "{\"version\":1}",
    ] {
      #expect(throws: SnippetsTransferError.notAnEnviousWisprSnippetsFile, Comment(rawValue: text)) {
        try SnippetsTransferDocument(data: Data(text.utf8))
      }
    }
  }

  @Test("Bytes that are not JSON, or our shape with a broken payload, are 'damaged'")
  func brokenBytesAreMalformed() {
    for text in [
      "not json", "{\"version\":1,\"snippets\":\"nope\"}",
      "{\"version\":1,\"snippets\":[{\"trigger\":1}]}", "{\"version\":0,\"snippets\":[]}",
      "{\"snippets\":[]}", "{\"version\":\"one\",\"snippets\":[]}",
    ] {
      #expect(throws: SnippetsTransferError.malformed, Comment(rawValue: text)) {
        try SnippetsTransferDocument(data: Data(text.utf8))
      }
    }
  }

  @Test("The keyword is decoded as a record only")
  func keywordIsCarriedNotApplied() throws {
    // The proof that an IMPORT leaves the store's keyword untouched lives with the store
    // and coordinator suites (chunk 3), where the writer is. This only pins that the value
    // survives decoding, so a future "restore keyword" could read it if the founder ever
    // asks for one.
    let data = try encoded(
      SnippetsTransferDocument(version: 1, keyword: "hey", snippets: []))
    let read = try SnippetsTransferDocument(data: data)
    #expect(read.keyword == "hey")
  }
}
