import Foundation

// MARK: - Learn-from-edits proposal record (#996 §3.1 steps 8/10, §4)
//
// The pure, persisted representation of one "remember this correction?" card.
// Nothing here writes vocabulary or decides anything: the App coordinator owns
// every business transition and the Storage ledger owns durability.

/// The ordered pair a proposal is about, as ONE string that is safe to compare
/// and to persist. `v1:` plus the UTF-8 JSON encoding of the two-element array
/// `[NFC-casefolded original, NFC-casefolded corrected]` (§4): a JSON array
/// cannot be forged by an original that happens to contain a separator, and
/// casefolding means "Saira"/"saira" are one pair while "Saira"/"Sarah" are two.
package enum CorrectionPairKey {
  package static let version = "v1"

  package static func make(original: String, corrected: String) -> String {
    // Encoded by hand rather than through JSONEncoder so the key's bytes do
    // not depend on an encoder option (JSONEncoder escapes "/" by default):
    // minimal JSON string escaping, which every JSON decoder reads back as
    // exactly the two normalised strings. A key must never be a plausible
    // default, and this path cannot throw.
    "\(version):[" + jsonString(normalise(original)) + "," + jsonString(normalise(corrected)) + "]"
  }

  /// A JSON string literal with the minimal escaping the grammar requires.
  static func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case let s where s.value < 0x20:
        out += String(format: "\\u%04X", s.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  /// NFC first (so the casefold sees one composed form), then casefold.
  package static func normalise(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive], locale: nil)
  }
}

/// Which of the two Accept outcomes the card offers (§3.1 step 6).
package enum CorrectionProposalTargetState: Sendable, Equatable, Hashable, Codable {
  /// The corrected spelling already exists as a user word or an enabled pack
  /// term; Accept appends the original as a sound-alike to that word.
  case existingWord(UUID)
  /// Accept creates the corrected word with the original as its first sound-alike.
  case newWord

  private enum CodingKeys: String, CodingKey { case kind, wordID }
  private enum Kind: String, Codable { case existingWord, newWord }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .existingWord: self = .existingWord(try c.decode(UUID.self, forKey: .wordID))
    case .newWord: self = .newWord
    }
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .existingWord(let id):
      try c.encode(Kind.existingWord, forKey: .kind)
      try c.encode(id, forKey: .wordID)
    case .newWord:
      try c.encode(Kind.newWord, forKey: .kind)
    }
  }
}

/// The closed status set of §4. Decoding any other string throws
/// `CorrectionProposalDecodingError.unknownStatus`, which the ledger store
/// classifies as UNTRUSTED rather than mapping it to a plausible default.
package enum CorrectionProposalStatus: String, Sendable, Equatable, Codable, CaseIterable {
  case pending, accepting, accepted, rejected

  /// A proposal that can still change: `pending` may begin an attempt,
  /// `accepting` is one in flight. `accepted`/`rejected` are terminal.
  package var isTerminal: Bool { self == .accepted || self == .rejected }

  package init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let value = Self(rawValue: raw) else {
      throw CorrectionProposalDecodingError.unknownStatus(raw)
    }
    self = value
  }
}

package enum CorrectionProposalDecodingError: Error, Equatable {
  case unknownStatus(String)
}

/// The vocabulary operation an Accept attempt committed to BEFORE writing
/// (§3.1 step 10): persisted first so a crash between the intent and the
/// vocabulary write can be reconciled against the live word list.
package struct CorrectionAcceptingIntent: Sendable, Equatable, Codable {
  package enum Operation: String, Sendable, Equatable, Codable {
    case addAlias, createWord
  }

  package let pairKey: String
  package let operation: Operation
  /// The word the sound-alike lands on: an existing word's id, or the id
  /// allocated NOW for the word `createWord` will make.
  package let targetWordID: UUID

  package init(pairKey: String, operation: Operation, targetWordID: UUID) {
    self.pairKey = pairKey
    self.operation = operation
    self.targetWordID = targetWordID
  }
}

/// One durable proposal (§3.1 step 8). `id` and `pairKey` are immutable for
/// the record's life; everything the coordinator moves is a `var`.
package struct CorrectionProposal: Sendable, Equatable, Codable, Identifiable {
  package let id: UUID
  package let pairKey: String
  package let original: String
  package let corrected: String
  package let state: CorrectionProposalTargetState
  package let language: String?
  /// At most 120 UTF-16 units of the sentence around the edit, local only.
  /// Refreshed by `refreshMetadata` when the same pair is seen again (§3.1
  /// step 8 `refreshOpen`); never set directly.
  package private(set) var contextExcerpt: String?
  package private(set) var sourceBundleID: String?
  package var status: CorrectionProposalStatus
  /// Step 9's single overlay attempt, recorded durably before the request.
  package var overlayAttempted: Bool
  package var acceptingIntent: CorrectionAcceptingIntent?
  package let createdAt: Date
  package var updatedAt: Date
  package var resolvedAt: Date?
  /// The judge's `safeAlias` answer, stored as advisory data only (§3.1 step 7).
  package let advisorySafeAlias: Bool?

  package static let contextExcerptLimit = 120

  package init(
    id: UUID = UUID(),
    original: String,
    corrected: String,
    state: CorrectionProposalTargetState,
    language: String?,
    contextExcerpt: String?,
    sourceBundleID: String?,
    createdAt: Date,
    advisorySafeAlias: Bool?
  ) {
    self.id = id
    self.pairKey = CorrectionPairKey.make(original: original, corrected: corrected)
    self.original = original
    self.corrected = corrected
    self.state = state
    self.language = language
    self.contextExcerpt = contextExcerpt.map { Self.clampExcerpt($0) }
    self.sourceBundleID = sourceBundleID
    self.status = .pending
    self.overlayAttempted = false
    self.acceptingIntent = nil
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.resolvedAt = nil
    self.advisorySafeAlias = advisorySafeAlias
  }

  /// Step 8 `refreshOpen`: the same pair seen again updates only the context,
  /// the source app and `updatedAt`. Identity, creation time, status, the
  /// overlay-attempt flag and any accepting intent are untouched.
  package mutating func refreshMetadata(contextExcerpt: String?, sourceBundleID: String?, at time: Date) {
    self.contextExcerpt = contextExcerpt.map { Self.clampExcerpt($0) }
    self.sourceBundleID = sourceBundleID
    self.updatedAt = time
  }

  /// Truncates on a Character boundary at or below the UTF-16 limit, so a
  /// stored excerpt can never split a grapheme cluster.
  package static func clampExcerpt(_ text: String) -> String {
    guard text.utf16.count > contextExcerptLimit else { return text }
    var out = ""
    for ch in text {
      if out.utf16.count + ch.utf16.count > contextExcerptLimit { break }
      out.append(ch)
    }
    return out
  }
}

/// A rejection tombstone (§3.1 step 10): the pair the user said no to. Never
/// pruned; deleting an accepted word is not a lesson, Reject is.
package struct CorrectionRejectedPair: Sendable, Equatable, Codable {
  package let pairKey: String
  package let rejectedAt: Date
  package let language: String?

  package init(pairKey: String, rejectedAt: Date, language: String?) {
    self.pairKey = pairKey
    self.rejectedAt = rejectedAt
    self.language = language
  }
}

/// The whole persisted document (§4): `{ version, proposals, rejectedPairs }`.
package struct CorrectionProposalLedger: Sendable, Equatable, Codable {
  package static let currentVersion = 1

  package var version: Int
  package var proposals: [CorrectionProposal]
  package var rejectedPairs: [CorrectionRejectedPair]

  package init(
    version: Int = currentVersion,
    proposals: [CorrectionProposal] = [],
    rejectedPairs: [CorrectionRejectedPair] = []
  ) {
    self.version = version
    self.proposals = proposals
    self.rejectedPairs = rejectedPairs
  }

  package static let empty = CorrectionProposalLedger()

  package func proposal(id: UUID) -> CorrectionProposal? {
    proposals.first { $0.id == id }
  }

  package func isRejected(pairKey: String) -> Bool {
    rejectedPairs.contains { $0.pairKey == pairKey }
  }

  /// Open records: `pending` and `accepting` (the Pending badge counts both).
  package var openProposals: [CorrectionProposal] {
    proposals.filter { !$0.status.isTerminal }
  }

  /// The persisted-data invariants a document must satisfy to be TRUSTED
  /// (Codex 5a round 1). Checked after decoding and before every write, so a
  /// syntactically valid file cannot carry a key unrelated to its strings, two
  /// records with one id, or an in-flight Accept without its intent. These
  /// are shape invariants; which transitions are legal is the coordinator's.
  package func validationProblems() -> [String] {
    var problems: [String] = []
    if version != Self.currentVersion {
      problems.append("version \(version) is not \(Self.currentVersion)")
    }
    var ids = Set<UUID>()
    for p in proposals {
      if !ids.insert(p.id).inserted {
        problems.append("duplicate proposal id \(p.id)")
      }
      if p.pairKey != CorrectionPairKey.make(original: p.original, corrected: p.corrected) {
        problems.append("proposal \(p.id): pairKey does not match its strings")
      }
      if let excerpt = p.contextExcerpt, excerpt.utf16.count > CorrectionProposal.contextExcerptLimit {
        problems.append("proposal \(p.id): context excerpt over \(CorrectionProposal.contextExcerptLimit) units")
      }
      if let intent = p.acceptingIntent, intent.pairKey != p.pairKey {
        problems.append("proposal \(p.id): accepting intent names another pair")
      }
      if p.status == .accepting && p.acceptingIntent == nil {
        problems.append("proposal \(p.id): accepting without an intent")
      }
      if p.status.isTerminal && p.resolvedAt == nil {
        problems.append("proposal \(p.id): terminal without resolvedAt")
      }
      if !p.status.isTerminal && p.resolvedAt != nil {
        problems.append("proposal \(p.id): open record carries resolvedAt")
      }
    }
    var keys = Set<String>()
    for t in rejectedPairs where !keys.insert(t.pairKey).inserted {
      problems.append("duplicate rejection tombstone \(t.pairKey)")
    }
    return problems
  }
}
