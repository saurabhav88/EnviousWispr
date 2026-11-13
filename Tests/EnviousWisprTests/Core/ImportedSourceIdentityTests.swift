import EnviousWisprCore
import Foundation
import Testing

/// An imported file's identity and an import row's source fields (#3147 PR3): the fingerprint
/// is stable for the same bytes and changes with size, duration or edge bytes; rows saved
/// before PR3 read as unlinked; Transcribe again with keeps the row's identity.
/// Class: `.productOutcome` — whether History plays the right original file, and whether a
/// re-transcription keeps the user's entry.
@Suite("Imported source identity and row fields (#3147 PR3)", .tags(.productOutcome))
struct ImportedSourceIdentityTests {

  private let head = Data(repeating: 1, count: 16)
  private let tail = Data(repeating: 2, count: 16)

  @Test("the same bytes give the same v1 fingerprint; size, duration or edges change it")
  func fingerprintIsStableAndSensitive() {
    let a = ImportedSourceIdentity.make(byteCount: 100, durationMs: 5_000, head: head, tail: tail)
    let b = ImportedSourceIdentity.make(byteCount: 100, durationMs: 5_000, head: head, tail: tail)
    #expect(a == b)
    #expect(a.fingerprint.hasPrefix("v1:100:5000:"))
    #expect(a.digest.count == 64)
    let changes = [
      ImportedSourceIdentity.make(byteCount: 101, durationMs: 5_000, head: head, tail: tail),
      ImportedSourceIdentity.make(byteCount: 100, durationMs: 5_001, head: head, tail: tail),
      ImportedSourceIdentity.make(
        byteCount: 100, durationMs: 5_000, head: Data(repeating: 3, count: 16), tail: tail),
      ImportedSourceIdentity.make(
        byteCount: 100, durationMs: 5_000, head: head, tail: Data(repeating: 3, count: 16)),
    ]
    for other in changes { #expect(other.digest != a.digest) }
  }

  @Test("a stored fingerprint matches, differs, or is a version this build cannot read")
  func storedFingerprintMatch() {
    let identity = ImportedSourceIdentity.make(byteCount: 9, durationMs: 1, head: head, tail: tail)
    #expect(identity.match(identity.fingerprint) == .same)
    #expect(identity.match("v1:9:1:" + String(repeating: "0", count: 64)) == .different)
    #expect(identity.match("v2:9:1:abc") == .unsupported)
  }

  @Test("a row saved before PR3 decodes with no source link and no attempt")
  func legacyRowDecodesUnlinked() throws {
    let row = Transcript(text: "raw", importedFileName: "a.m4a")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
    for key in ["sourceBookmark", "sourceFingerprint", "importAttemptID"] {
      json.removeValue(forKey: key)
    }
    let decoded = try JSONDecoder().decode(
      Transcript.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.sourceBookmark == nil)
    #expect(decoded.sourceFingerprint == nil)
    #expect(decoded.importAttemptID == nil)
  }

  @Test("source and attempt survive a save and reload and change nothing else")
  func sourceFieldsPersistAlone() throws {
    let attempt = UUID()
    let row = Transcript(text: "raw", polishedText: "Doc.", importedFileName: "a.m4a")
      .withSource(bookmark: Data([1, 2, 3]), fingerprint: "v1:1:1:ab")
      .withImportAttempt(attempt)
    let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(row))
    #expect(decoded.sourceBookmark == Data([1, 2, 3]))
    #expect(decoded.sourceFingerprint == "v1:1:1:ab")
    #expect(decoded.importAttemptID == attempt)
    #expect(decoded.polishedText == "Doc.")
  }

  @Test("Transcribe again keeps the entry's identity and takes the new content whole")
  func replacementKeepsIdentity() {
    let created = Date(timeIntervalSince1970: 1_000)
    let old = Transcript(
      text: "old words", polishedText: "Old.", duration: 61, createdAt: created,
      importedFileName: "talk.m4a",
      speakerAnalysis: .labeled(count: 2), speakerNames: ["s1": "Ana"],
      turns: [Turn(id: "t", speakerId: "s1", startMs: 0, endMs: 10, originalTextRange: 0..<3)],
      preferredVersion: nil, sourceBookmark: Data([9]), sourceFingerprint: "v1:1:1:aa",
      importAttemptID: UUID())
    let result = Transcript(
      text: "new words", polishedText: nil, duration: 5, backendType: .whisper,
      createdAt: Date(), processedText: "New.", speakerAnalysis: .single)
    let attempt = UUID()
    let replaced = old.replacingImportedContent(from: result, attemptID: attempt)
    #expect(replaced.id == old.id)
    #expect(replaced.createdAt == created)
    #expect(replaced.importedFileName == "talk.m4a")
    #expect(replaced.duration == 61, "the source file's duration stays")
    #expect(replaced.sourceBookmark == Data([9]))
    #expect(replaced.sourceFingerprint == "v1:1:1:aa")
    #expect(replaced.importAttemptID == attempt)
    #expect(replaced.text == "new words")
    #expect(replaced.polishedText == nil, "old derived text never survives")
    #expect(replaced.processedText == "New.")
    #expect(replaced.backendType == .whisper)
    #expect(replaced.turns == nil, "old turn ranges never index the new text")
    #expect(replaced.speakerNames == nil)
    #expect(replaced.speakerAnalysis == .single)
  }
}
