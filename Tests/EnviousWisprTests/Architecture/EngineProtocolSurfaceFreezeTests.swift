import Foundation
import SwiftParser
import SwiftSyntax
import Testing

// MARK: - EngineProtocolSurfaceFreezeTests (#1741 Chunk 11)
//
// Companion to `EngineMutationInventoryFreezeTests`, kept in a separate file
// because the two ask different questions with different mechanics and
// different failure modes: that file asks "is every REFERENCE to a known
// engine-mutating name classified" (open-world — arbitrary call sites);
// this file asks "has the DECLARED SURFACE of a known, bounded list of
// protocols and concrete methods changed" (closed-world — a protocol's own
// requirement list, or one method's own signature, is a real, enumerable
// authority once the file it lives in is fixed).
//
// SCOPE, STATED HONESTLY (do not remove or soften this without a fresh
// grounding pass — see `EngineMutationInventoryFreezeTests`'s own Chunk 11
// doc comment for the two-consecutive-Codex-round history that makes this
// necessary): this suite freezes the exact signatures of TEN engine-facing
// protocols and TWO known concrete-only method surfaces not declared by any
// of the ten protocols (one, `WhisperKitEngineAdapter.unloadForRemoval()`,
// is reached only via a type-cast; the other,
// `ParakeetBackend.prepare(cacheOnly:progressCallback:)`, is reached via a
// type-cast at one call site AND via direct, uncast construction/ownership
// at another — `ASRServiceHandler.swift` builds and holds a concrete
// `ParakeetBackend` natively), all grounded as of 2026-07-23. It
// WILL catch: a member added to, removed from, or resignatured on any of
// the ten protocols (including a changed parameter label, type, return
// type, `async`/`throws`, property accessor kind, or an added overload); a
// changed inheritance clause; a member added only via a protocol extension
// declared in the SAME FILE as the protocol, with no matching requirement;
// and a signature change to either pinned concrete method. It will NOT, and
// cannot, catch: a brand-new protocol nobody has told it about, a
// brand-new concrete type, a new XPC route, an extension of one of these
// ten protocols declared in a DIFFERENT file (grounded 2026-07-23: none of
// the ten currently has one — Codex final-integration r1 flagged this as a
// theoretical future gap, not a present one — but the scanner does not look
// beyond each protocol's own declaration file), a
// macro-generated call, or a concrete engine type accessed with no
// protocol and no cast at all (the exact structural hole a proposed
// general downcast scanner had — Codex's second grounded review round
// found `ActiveEngineOperation.live(asrManager:whisperKitBackend:)` takes
// `WhisperKitBackend` as a plain typed parameter, no cast in sight). Those
// require the same kind of human grounding pass that found the ten
// protocols and two escape hatches here — this suite is a guardrail on top
// of that judgment, not a replacement for it.
@Suite struct EngineProtocolSurfaceFreezeTests {

  private struct ScanFailedError: Error, CustomStringConvertible {
    let context: String
    let reason: String
    var description: String {
      "Scan failed for \(context): \(reason). Never silently treated as clean."
    }
  }

  /// One frozen member/requirement signature. `condition` names the `#if`
  /// clause it lives under (e.g. `"DEBUG"`), or `nil` for an unconditional
  /// member — so a member moving in or out of a conditional block is a real
  /// change, not invisible.
  private struct MemberSignature: Hashable, CustomStringConvertible {
    let condition: String?
    let signature: String
    var description: String {
      condition.map { "[#if \($0)] \(signature)" } ?? signature
    }
  }

  /// One frozen surface: either a protocol's own requirement list (plus any
  /// same-file extension defaults) or one concrete type's method-by-name
  /// group (one or more overloads).
  private struct Surface {
    let name: String
    let file: String
    /// The `protocol Name: Inheritance` header, trimmed — `nil` for a
    /// concrete-method surface, which has no protocol header of its own.
    let header: String?
    let members: [MemberSignature]
  }

  // MARK: Parsing

  /// A function's declaration text truncated at its first `{` — a protocol
  /// requirement never has a body at all, so this is a no-op for those; an
  /// extension's default implementation DOES have a real statement body,
  /// which is free to change without tripping this freeze (only what the
  /// function PROMISES is frozen, not how a default fulfills it).
  private static func truncatedAtBody(_ text: String) -> String {
    guard let braceIndex = text.firstIndex(of: "{") else { return text }
    return String(text[text.startIndex..<braceIndex]).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  /// Recognized protocol-member declaration kinds. Anything else (an
  /// `associatedtype`, `init`, `subscript`, macro expansion, or any future
  /// syntax this visitor does not recognize) fails the scan closed rather
  /// than being silently skipped — Codex's grounded review flagged exactly
  /// this as a real risk for a member-kind-unaware collector.
  ///
  /// A property is NEVER truncated at its first `{`, unlike a function: a
  /// protocol requirement's `{ get }` / `{ get set }` accessor spec is part
  /// of the SIGNATURE itself (it declares whether the property must be
  /// settable), not a body to strip. An extension's real computed-property
  /// body is kept whole too, for the same reason a function's is stripped —
  /// property bodies in this codebase's ten protocols are short, single-
  /// expression defaults where the distinction rarely matters, and keeping
  /// the whole text is simpler and cannot under-report a change.
  private static func normalizedSignature(of decl: DeclSyntax) throws -> String? {
    if let fn = decl.as(FunctionDeclSyntax.self) {
      return Self.truncatedAtBody(fn.trimmedDescription)
    }
    if let v = decl.as(VariableDeclSyntax.self) {
      return v.trimmedDescription
    }
    if decl.is(MissingDeclSyntax.self) { return nil }  // a bare `;` between members
    throw ScanFailedError(
      context: "protocol/extension member",
      reason: "unrecognized member declaration kind \(decl.kind) — fail closed rather than skip")
  }

  private static func collectMembers(
    _ list: MemberBlockItemListSyntax, condition: String?, into members: inout [MemberSignature]
  ) throws {
    for item in list {
      if let ifConfig = item.decl.as(IfConfigDeclSyntax.self) {
        for clause in ifConfig.clauses {
          guard case .decls(let nested) = clause.elements else {
            throw ScanFailedError(
              context: "#if clause inside a protocol/extension member block",
              reason: "clause does not contain a declaration list — fail closed rather than skip")
          }
          // `#else` has no condition expression of its own (Codex final-
          // integration r1: recording it as `nil` made it indistinguishable
          // from a genuinely unconditional top-level member — moving a
          // requirement from `#else` to unconditional code would then leave
          // the frozen signature unchanged). Labeled "else" instead, which
          // can never collide with a real condition's trimmed text.
          let clauseCondition = clause.condition?.trimmedDescription ?? "else"
          // A NESTED `#if` combines with its outer condition rather than
          // replacing it (same review round: replacing silently dropped the
          // outer guard, under-reporting the true compiled condition).
          let combinedCondition = [condition, clauseCondition].compactMap { $0 }.joined(
            separator: " && ")
          try collectMembers(nested, condition: combinedCondition, into: &members)
        }
        continue
      }
      guard let signature = try Self.normalizedSignature(of: item.decl) else { continue }
      members.append(MemberSignature(condition: condition, signature: signature))
    }
  }

  /// Parses `source` and collects `protocolName`'s own requirements plus any
  /// same-file `extension protocolName { ... }` default-implementation
  /// signatures — both are part of what the protocol actually promises.
  /// Shared by the live file-based scan AND the fixture tests below, so a
  /// fixture exercises the exact same collection path the live scan uses,
  /// never a parallel, simpler stand-in.
  private static func surfaceMembers(
    inParsedSource source: String, protocolName: String, context: String
  ) throws -> (header: String?, members: [MemberSignature]) {
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
      throw ScanFailedError(
        context: context, reason: "source did not parse cleanly (tree.hasError)")
    }

    final class Collector: SyntaxVisitor {
      let targetName: String
      var header: String?
      var members: [MemberSignature] = []
      var thrown: Error?
      init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == targetName else { return .skipChildren }
        let inheritance = node.inheritanceClause?.trimmedDescription ?? ""
        header = "protocol \(targetName) \(inheritance)".trimmingCharacters(in: .whitespaces)
        do {
          try EngineProtocolSurfaceFreezeTests.collectMembers(
            node.memberBlock.members, condition: nil, into: &members)
        } catch {
          thrown = error
        }
        return .skipChildren
      }
      override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ident = node.extendedType.as(IdentifierTypeSyntax.self),
          ident.name.text == targetName
        else { return .visitChildren }
        do {
          try EngineProtocolSurfaceFreezeTests.collectMembers(
            node.memberBlock.members, condition: nil, into: &members)
        } catch {
          thrown = error
        }
        return .skipChildren
      }
    }

    let collector = Collector(targetName: protocolName)
    collector.walk(tree)
    if let thrown = collector.thrown { throw thrown }
    return (collector.header, collector.members)
  }

  /// Reads `file` and collects `protocolName`'s frozen surface from it.
  private static func protocolSurface(named protocolName: String, in file: String) throws -> Surface
  {
    let url = RepoRoot.sourceURL(file)
    let source: String
    do {
      source = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw ScanFailedError(context: file, reason: "could not be read: \(error)")
    }
    let (header, members) = try surfaceMembers(
      inParsedSource: source, protocolName: protocolName, context: file)
    guard let header else {
      throw ScanFailedError(
        context: file,
        reason: "protocol \(protocolName) not found — fail closed, never report empty")
    }
    return Surface(name: protocolName, file: file, header: header, members: members)
  }

  /// Collects `typeName`'s own `methodName` declaration(s) from already-parsed
  /// `source` — scoped to `typeName`'s own actor/class/struct declaration and
  /// its same-file extensions ONLY. An unrelated type in the same file
  /// sharing `methodName` is never collected (Codex implementation-review
  /// r1: the prior version matched `methodName` anywhere in the file, a real
  /// fail-open — if the target method were removed while another type kept a
  /// same-named method, the "missing" check would be silently masked by the
  /// unrelated match). A type may legitimately overload a method (e.g.
  /// `ParakeetBackend.prepare` has three overloads); every matching
  /// declaration from the RIGHT type is collected as its own member,
  /// mirroring how a protocol's own overloaded requirements are handled.
  /// Shared by the live file-based scan AND the fixture tests below, so a
  /// fixture exercises the exact same type-scoping path, never a parallel,
  /// simpler stand-in.
  private static func concreteMethodMembers(
    inParsedSource source: String, typeName: String, methodName: String, context: String
  ) throws -> [MemberSignature] {
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
      throw ScanFailedError(
        context: context, reason: "source did not parse cleanly (tree.hasError)")
    }

    final class Collector: SyntaxVisitor {
      let typeName: String
      let methodName: String
      var foundType = false
      var matches: [String] = []
      init(typeName: String, methodName: String) {
        self.typeName = typeName
        self.methodName = methodName
        super.init(viewMode: .sourceAccurate)
      }
      private func scanMembers(_ list: MemberBlockItemListSyntax) {
        for item in list {
          guard let fn = item.decl.as(FunctionDeclSyntax.self), fn.name.text == methodName else {
            continue
          }
          matches.append(EngineProtocolSurfaceFreezeTests.truncatedAtBody(fn.trimmedDescription))
        }
      }
      override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == typeName else { return .visitChildren }
        foundType = true
        scanMembers(node.memberBlock.members)
        return .skipChildren
      }
      override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == typeName else { return .visitChildren }
        foundType = true
        scanMembers(node.memberBlock.members)
        return .skipChildren
      }
      override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == typeName else { return .visitChildren }
        foundType = true
        scanMembers(node.memberBlock.members)
        return .skipChildren
      }
      override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ident = node.extendedType.as(IdentifierTypeSyntax.self),
          ident.name.text == typeName
        else { return .visitChildren }
        foundType = true
        scanMembers(node.memberBlock.members)
        return .skipChildren
      }
    }
    let collector = Collector(typeName: typeName, methodName: methodName)
    collector.walk(tree)
    guard collector.foundType else {
      throw ScanFailedError(
        context: context, reason: "type `\(typeName)` not found — fail closed rather than guess")
    }
    guard !collector.matches.isEmpty else {
      throw ScanFailedError(
        context: context,
        reason:
          "type `\(typeName)` has no `\(methodName)` declaration — fail closed rather than report an empty surface"
      )
    }
    return collector.matches.map { MemberSignature(condition: nil, signature: $0) }
  }

  /// Reads `file` and pins ONE concrete method's own signature(s) by name —
  /// used for the two known concrete escape hatches.
  private static func concreteMethodSurface(
    typeName: String, methodName: String, in file: String
  ) throws -> Surface {
    let url = RepoRoot.sourceURL(file)
    let source: String
    do {
      source = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw ScanFailedError(context: file, reason: "could not be read: \(error)")
    }
    let members = try concreteMethodMembers(
      inParsedSource: source, typeName: typeName, methodName: methodName, context: file)
    return Surface(name: "\(typeName).\(methodName)", file: file, header: nil, members: members)
  }

  // MARK: Frozen surfaces — the ten protocols + two concrete escape hatches
  // grounded as of 2026-07-23 (#1741 Chunk 11). Adding an eleventh protocol
  // or a third escape hatch to this list is a deliberate grounding decision,
  // not something this suite can discover on its own — see the file-level
  // doc comment above.

  private static let targets: [(kind: String, name: String, file: String, method: String?)] = [
    ("protocol", "ASRBackend", "Sources/EnviousWisprASR/ASRProtocol.swift", nil),
    ("protocol", "ASRManagerInterface", "Sources/EnviousWisprASR/ASRManagerInterface.swift", nil),
    ("protocol", "ASREngineAdapter", "Sources/EnviousWisprPipeline/ASREngineAdapter.swift", nil),
    (
      "protocol", "ASREngineLanguageIdentifying",
      "Sources/EnviousWisprPipeline/ASREngineOptionalCapabilities.swift", nil
    ),
    (
      "protocol", "ASREngineWarmupCancelling",
      "Sources/EnviousWisprPipeline/ASREngineOptionalCapabilities.swift", nil
    ),
    (
      "protocol", "WhisperKitBackendDriving",
      "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", nil
    ),
    (
      "protocol", "WhisperKitIncrementalSession",
      "Sources/EnviousWisprASR/WhisperKitIncrementalSession.swift", nil
    ),
    (
      "protocol", "WhisperKitTranscribing",
      "Sources/EnviousWisprASR/WhisperKitIncrementalSession.swift", nil
    ),
    ("protocol", "ASRServiceProtocol", "Sources/EnviousWisprCore/ASRServiceProtocol.swift", nil),
    (
      "protocol", "ASREngineTelemetryProviding",
      "Sources/EnviousWisprPipeline/KernelTelemetryState.swift", nil
    ),
    (
      "concrete", "WhisperKitEngineAdapter",
      "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", "unloadForRemoval"
    ),
    ("concrete", "ParakeetBackend", "Sources/EnviousWisprASR/ParakeetBackend.swift", "prepare"),
  ]

  private static func liveSurfaces() throws -> [Surface] {
    try targets.map { target in
      if target.kind == "protocol" {
        return try protocolSurface(named: target.name, in: target.file)
      }
      return try concreteMethodSurface(
        typeName: target.name, methodName: target.method!, in: target.file)
    }
  }

  // MARK: Frozen signatures, re-derived from the real parser (measure with
  // the real tool, never hand-transcribed) as of 2026-07-23.

  private static let frozen: [String: Surface] = [
    "ASRBackend": Surface(
      name: "ASRBackend", file: "Sources/EnviousWisprASR/ASRProtocol.swift",
      header: "protocol ASRBackend : Actor",
      members: [
        MemberSignature(condition: nil, signature: "var isReady: Bool { get }"),
        MemberSignature(condition: nil, signature: "func prepare() async throws"),
        MemberSignature(
          condition: nil,
          signature: "func prepare(progressCallback: ProgressCallback?) async throws"
        ),
        MemberSignature(
          condition: nil,
          signature:
            "func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult"
        ),
        MemberSignature(condition: nil, signature: "func unload() async"),
        MemberSignature(condition: nil, signature: "var supportsStreaming: Bool { get }"),
        MemberSignature(
          condition: nil,
          signature: "func startStreaming(options: TranscriptionOptions) async throws"
        ),
        MemberSignature(
          condition: nil, signature: "func feedAudio(_ buffer: AVAudioPCMBuffer) async throws"),
        MemberSignature(
          condition: nil, signature: "func finalizeStreaming() async throws -> ASRResult"),
        MemberSignature(condition: nil, signature: "func cancelStreaming() async"),
        // Extension defaults (`extension ASRBackend { ... }`) — part of what
        // the protocol actually promises to a non-overriding conformer.
        MemberSignature(condition: nil, signature: "public var supportsStreaming: Bool { false }"),
        MemberSignature(
          condition: nil,
          signature: "public func startStreaming(options _: TranscriptionOptions) async throws"),
        MemberSignature(
          condition: nil,
          signature: "public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws"
        ),
        MemberSignature(
          condition: nil, signature: "public func finalizeStreaming() async throws -> ASRResult"),
        MemberSignature(condition: nil, signature: "public func cancelStreaming() async"),
        MemberSignature(
          condition: nil,
          signature: "public func prepare(progressCallback: ProgressCallback?) async throws"),
      ]),
    "ASRManagerInterface": Surface(
      name: "ASRManagerInterface", file: "Sources/EnviousWisprASR/ASRManagerInterface.swift",
      header: "protocol ASRManagerInterface : AnyObject",
      members: [
        MemberSignature(condition: nil, signature: "var activeBackendType: ASRBackendType { get }"),
        MemberSignature(condition: nil, signature: "var isModelLoaded: Bool { get }"),
        MemberSignature(condition: nil, signature: "var isStreaming: Bool { get }"),
        MemberSignature(condition: nil, signature: "var downloadProgress: Double { get }"),
        MemberSignature(condition: nil, signature: "var downloadPhase: String { get }"),
        MemberSignature(condition: nil, signature: "var downloadDetail: String { get }"),
        MemberSignature(condition: nil, signature: "var parakeetCacheOnly: Bool { get set }"),
        MemberSignature(condition: nil, signature: "func loadModel() async throws"),
        MemberSignature(condition: nil, signature: "func unloadModel() async"),
        MemberSignature(
          condition: nil, signature: "func setInitialBackendType(_ type: ASRBackendType)"),
        MemberSignature(
          condition: nil, signature: "func switchBackend(to type: ASRBackendType) async"),
        MemberSignature(
          condition: nil, signature: "var activeBackendSupportsStreaming: Bool { get async }"),
        MemberSignature(
          condition: nil,
          signature:
            "func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult"
        ),
        MemberSignature(
          condition: nil,
          signature: "func startStreaming(options: TranscriptionOptions) async throws"),
        MemberSignature(
          condition: nil, signature: "func feedAudio(_ buffer: AVAudioPCMBuffer) async throws"),
        MemberSignature(
          condition: nil, signature: "func finalizeStreaming() async throws -> ASRResult"),
        MemberSignature(condition: nil, signature: "func cancelStreaming() async"),
        MemberSignature(
          condition: nil, signature: "func noteTranscriptionComplete(policy: ModelUnloadPolicy)"),
        MemberSignature(condition: nil, signature: "func cancelIdleTimer()"),
        MemberSignature(condition: nil, signature: "func cancelInFlightLoad()"),
        MemberSignature(
          condition: nil,
          signature:
            "var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)? { get set }"
        ),
        MemberSignature(condition: nil, signature: "var feedsSharedProgressFile: Bool { get }"),
        MemberSignature(
          condition: nil, signature: "var onServiceInterrupted: (() -> Void)? { get set }"),
        // Extension defaults.
        MemberSignature(
          condition: nil,
          signature: "public var feedsSharedProgressFile: Bool { false }"),
        MemberSignature(
          condition: nil,
          signature: "public var parakeetCacheOnly: Bool {\n    get { false }\n    set {}\n  }"),
      ]),
    "ASREngineAdapter": Surface(
      name: "ASREngineAdapter", file: "Sources/EnviousWisprPipeline/ASREngineAdapter.swift",
      header: "protocol ASREngineAdapter : AnyObject, Sendable",
      members: [
        MemberSignature(condition: nil, signature: "var engineIdentity: ASREngineIdentity { get }"),
        MemberSignature(
          condition: nil, signature: "var capabilities: ASREngineCapabilities { get }"),
        MemberSignature(condition: nil, signature: "var readiness: ASREngineReadiness { get }"),
        MemberSignature(condition: nil, signature: "var lastWarmupInferenceMs: Int? { get }"),
        MemberSignature(condition: nil, signature: "func warmUp() async throws"),
        MemberSignature(
          condition: nil, signature: "var loadProgress: AsyncStream<ASRLoadProgressTick>? { get }"),
        MemberSignature(condition: nil, signature: "var lastObservedPhase: String { get }"),
        MemberSignature(condition: nil, signature: "var warmupStallGuardEligible: Bool { get }"),
        MemberSignature(
          condition: nil,
          signature:
            "func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws"
        ),
        MemberSignature(
          condition: nil, signature: "func acceptAudio(_ buffer: AudioBufferHandoff)"),
        MemberSignature(
          condition: nil,
          signature: "func finalize(batchSamples: [Float]?) async -> ASREngineOutcome"),
        MemberSignature(
          condition: nil,
          signature: "var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { get }"),
        MemberSignature(
          condition: nil,
          signature: "func retryDecode(inputSamples: [Float]) async -> ASREngineOutcome"),
        MemberSignature(
          condition: nil,
          signature: "func retryDecodeTimeoutSeconds(forSampleCount sampleCount: Int) -> Double"),
        MemberSignature(condition: nil, signature: "func bumpRetryGeneration()"),
        MemberSignature(condition: nil, signature: "func cancel() async"),
        MemberSignature(condition: nil, signature: "func recoverFromWedge() async"),
        MemberSignature(
          condition: nil,
          signature: "var onEngineInterrupted: (@MainActor () -> Void)? { get set }"),
        MemberSignature(
          condition: nil,
          signature: "func recoverFromASRInterruption() async -> ASRInterruptionRecoveryOutcome"),
        MemberSignature(
          condition: nil, signature: "func applyUnloadPolicy(_ policy: ModelUnloadPolicy)"),
        MemberSignature(condition: nil, signature: "var lastResult: ASRResult? { get }"),
        MemberSignature(condition: nil, signature: "func warmUpFromCache() async throws"),
        MemberSignature(condition: nil, signature: "func cancelPendingUnload()"),
        MemberSignature(
          condition: nil,
          signature:
            "func observeSpeechSegments(_ segments: [SpeechSegment], rawCaptureSamples: [Float])"),
        // Extension defaults (two separate `extension ASREngineAdapter { ... }` blocks).
        MemberSignature(
          condition: nil, signature: "public var lastObservedPhase: String { \"warmup\" }"),
        MemberSignature(
          condition: nil, signature: "public var lastWarmupInferenceMs: Int? { nil }"),
        MemberSignature(condition: nil, signature: "public func warmUpFromCache() async throws"),
        MemberSignature(condition: nil, signature: "public func cancelPendingUnload()"),
        MemberSignature(
          condition: nil,
          signature:
            "public func observeSpeechSegments(\n    _ segments: [SpeechSegment], rawCaptureSamples: [Float]\n  )"
        ),
        MemberSignature(
          condition: nil, signature: "public var warmupStallGuardEligible: Bool { false }"),
      ]),
    "ASREngineLanguageIdentifying": Surface(
      name: "ASREngineLanguageIdentifying",
      file: "Sources/EnviousWisprPipeline/ASREngineOptionalCapabilities.swift",
      header: "protocol ASREngineLanguageIdentifying : AnyObject",
      members: [
        MemberSignature(
          condition: nil, signature: "var lastLanguageDetection: LanguageDetectionResult? { get }")
      ]),
    "ASREngineWarmupCancelling": Surface(
      name: "ASREngineWarmupCancelling",
      file: "Sources/EnviousWisprPipeline/ASREngineOptionalCapabilities.swift",
      header: "protocol ASREngineWarmupCancelling : AnyObject",
      members: [
        MemberSignature(condition: nil, signature: "func cancelSessionlessWarmup() async")
      ]),
    "WhisperKitBackendDriving": Surface(
      name: "WhisperKitBackendDriving",
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift",
      header: "protocol WhisperKitBackendDriving : Actor",
      members: [
        MemberSignature(condition: nil, signature: "var isReady: Bool { get }"),
        MemberSignature(condition: nil, signature: "var modelVariantName: String { get }"),
        MemberSignature(condition: nil, signature: "var lastWarmupInferenceMs: Int? { get }"),
        MemberSignature(condition: nil, signature: "func prepare() async throws"),
        MemberSignature(
          condition: nil,
          signature:
            "func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult"
        ),
        MemberSignature(
          condition: nil,
          signature:
            "func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch"
        ),
        MemberSignature(
          condition: nil,
          signature:
            "func makeStreamingSession(options: TranscriptionOptions) async\n    -> (any WhisperKitIncrementalSession)?"
        ),
        MemberSignature(condition: nil, signature: "func unload() async"),
      ]),
    "WhisperKitIncrementalSession": Surface(
      name: "WhisperKitIncrementalSession",
      file: "Sources/EnviousWisprASR/WhisperKitIncrementalSession.swift",
      header: "protocol WhisperKitIncrementalSession : Sendable",
      members: [
        MemberSignature(
          condition: nil,
          signature:
            "func start(\n    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)\n  ) async"
        ),
        MemberSignature(
          condition: nil,
          signature:
            "func finalize(\n    finalSamples: [Float],\n    speechSegments: [SpeechSegment]\n  ) async -> IncrementalResult"
        ),
        MemberSignature(condition: nil, signature: "func cancel() async"),
        MemberSignature(condition: nil, signature: "func noteStopRequested() async"),
      ]),
    "WhisperKitTranscribing": Surface(
      name: "WhisperKitTranscribing",
      file: "Sources/EnviousWisprASR/WhisperKitIncrementalSession.swift",
      header: "protocol WhisperKitTranscribing : Sendable",
      members: [
        MemberSignature(
          condition: nil,
          signature:
            "func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws\n    -> [TranscriptionResult]"
        ),
        MemberSignature(condition: nil, signature: "func encodeText(_ text: String) -> [Int]"),
      ]),
    "ASRServiceProtocol": Surface(
      name: "ASRServiceProtocol", file: "Sources/EnviousWisprCore/ASRServiceProtocol.swift",
      header: "protocol ASRServiceProtocol",
      members: [
        MemberSignature(condition: nil, signature: "func ping(reply: @escaping (String) -> Void)"),
        MemberSignature(
          condition: nil,
          signature:
            "func loadModel(backendType: String, cacheOnly: Bool, reply: @escaping (NSError?) -> Void)"
        ),
        MemberSignature(condition: nil, signature: "func unloadModel(reply: @escaping () -> Void)"),
        MemberSignature(
          condition: nil, signature: "func getModelState(reply: @escaping (Bool, Bool) -> Void)"),
        MemberSignature(
          condition: nil,
          signature:
            "func transcribeSamples(\n    _ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool,\n    speechSegmentsData: Data?,\n    reply: @escaping (Data?, NSError?) -> Void)"
        ),
        MemberSignature(
          condition: nil,
          signature:
            "func startStreaming(\n    operationID: String, language: String, enableTimestamps: Bool,\n    reply: @escaping (NSError?) -> Void)"
        ),
        MemberSignature(
          condition: nil, signature: "func feedAudioBuffer(_ data: Data, frameCount: Int)"),
        MemberSignature(
          condition: nil,
          signature: "func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void)"
        ),
        MemberSignature(condition: nil, signature: "func cancelStreaming()"),
        MemberSignature(
          condition: nil,
          signature:
            "func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void)"),
        MemberSignature(
          condition: "DEBUG",
          signature: "func armBatchDecodeHold(trialID: String, reply: @escaping () -> Void)"),
        MemberSignature(
          condition: "DEBUG",
          signature: "func releaseBatchDecode(trialID: String, reply: @escaping () -> Void)"),
        MemberSignature(
          condition: "DEBUG", signature: "func clearBatchDecodeFault(reply: @escaping () -> Void)"),
      ]),
    "ASREngineTelemetryProviding": Surface(
      name: "ASREngineTelemetryProviding",
      file: "Sources/EnviousWisprPipeline/KernelTelemetryState.swift",
      header: "protocol ASREngineTelemetryProviding : AnyObject",
      members: [
        MemberSignature(
          condition: nil,
          signature: "var lastASRDiagnostics: KernelASRAdapterDiagnostics? { get }"),
        MemberSignature(condition: nil, signature: "var lastFailureError: (any Error)? { get }"),
      ]),
    "WhisperKitEngineAdapter.unloadForRemoval": Surface(
      name: "WhisperKitEngineAdapter.unloadForRemoval",
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", header: nil,
      members: [
        MemberSignature(condition: nil, signature: "package func unloadForRemoval() async")
      ]),
    "ParakeetBackend.prepare": Surface(
      name: "ParakeetBackend.prepare", file: "Sources/EnviousWisprASR/ParakeetBackend.swift",
      header: nil,
      members: [
        MemberSignature(condition: nil, signature: "public func prepare() async throws"),
        MemberSignature(
          condition: nil,
          signature: "public func prepare(progressCallback: ProgressCallback?) async throws"),
        MemberSignature(
          condition: nil,
          signature:
            "public func prepare(cacheOnly: Bool, progressCallback: ProgressCallback?) async throws"
        ),
      ]),
  ]

  // MARK: 1 — every target's live surface exactly matches the frozen one

  @Test("live protocol/concrete-method signatures exactly match the frozen surfaces")
  func liveSurfacesMatchFrozenSignatures() throws {
    let live = try Self.liveSurfaces()
    var failures: [String] = []
    for surface in live {
      guard let expected = Self.frozen[surface.name] else {
        failures.append("Surface `\(surface.name)` has no frozen entry at all.")
        continue
      }
      if surface.header != expected.header {
        failures.append(
          "Surface `\(surface.name)` header changed:\n  was: \(expected.header ?? "<none>")\n  now: \(surface.header ?? "<none>")"
        )
      }
      let liveSet = Set(surface.members)
      let expectedSet = Set(expected.members)
      let added = liveSet.subtracting(expectedSet)
      let removed = expectedSet.subtracting(liveSet)
      if !added.isEmpty {
        failures.append(
          "Surface `\(surface.name)` gained member(s):\n"
            + added.map { "  + \($0)" }.joined(separator: "\n"))
      }
      if !removed.isEmpty {
        failures.append(
          "Surface `\(surface.name)` lost member(s):\n"
            + removed.map { "  - \($0)" }.joined(separator: "\n"))
      }
    }
    #expect(
      failures.isEmpty,
      """
      \(failures.count) protocol/concrete-method surface change(s) detected:
      \(failures.joined(separator: "\n"))
      A new/removed/resignatured member means: if it is engine-mutating, add it to
      `EngineMutationInventoryFreezeTests.vocabulary` and classify its references; if it is a
      read-only query or policy/wiring member, update the frozen surface here deliberately.
      """)
  }

  // MARK: 2 — fixture proofs that the mechanism itself detects each named
  // change shape, not just that today's ten protocols happen to match.

  private static func members(of source: String, protocolName: String) throws -> Set<
    MemberSignature
  > {
    let (_, members) = try surfaceMembers(
      inParsedSource: source, protocolName: protocolName, context: "<fixture>")
    return Set(members)
  }

  @Test("adding a requirement changes the collected member set")
  func adversarialAddedRequirementIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func warmUp() async throws }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func warmUp() async throws\n func cancel() async }", protocolName: "P")
    #expect(before != after)
    #expect(after.count == before.count + 1)
  }

  @Test("removing a requirement changes the collected member set")
  func adversarialRemovedRequirementIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func warmUp() async throws\n func cancel() async }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func warmUp() async throws }", protocolName: "P")
    #expect(before != after)
  }

  @Test("renaming a requirement changes the collected member set")
  func adversarialRenamedRequirementIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func warmUp() async throws }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func warmUpEngine() async throws }", protocolName: "P")
    #expect(before != after)
  }

  @Test("a changed parameter label changes the collected member set")
  func adversarialChangedParameterLabelIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func prepare(cacheOnly: Bool) async throws }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func prepare(fromCache: Bool) async throws }", protocolName: "P")
    #expect(before != after)
  }

  @Test("a changed parameter type changes the collected member set")
  func adversarialChangedParameterTypeIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func retryDecode(inputSamples: [Float]) async }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func retryDecode(inputSamples: [Double]) async }", protocolName: "P")
    #expect(before != after)
  }

  @Test("adding `throws` to a requirement changes the collected member set")
  func adversarialAddedThrowsIsDetected() throws {
    let before = try Self.members(of: "protocol P { func warmUp() async }", protocolName: "P")
    let after = try Self.members(of: "protocol P { func warmUp() async throws }", protocolName: "P")
    #expect(before != after)
  }

  @Test("a property changing from get-only to get/set changes the collected member set")
  func adversarialChangedPropertyAccessorIsDetected() throws {
    let before = try Self.members(of: "protocol P { var isReady: Bool { get } }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { var isReady: Bool { get set } }", protocolName: "P")
    #expect(before != after)
  }

  @Test("an added overload sharing an existing base name changes the collected member set")
  func adversarialAddedOverloadIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func prepare() async throws }", protocolName: "P")
    let after = try Self.members(
      of:
        "protocol P { func prepare() async throws\n func prepare(cacheOnly: Bool) async throws }",
      protocolName: "P")
    #expect(before != after)
    #expect(after.count == before.count + 1)
  }

  @Test("a default-implementation BODY change alone does not change the frozen signature")
  func positiveControlBodyOnlyChangeIsIgnored() throws {
    let before = try Self.members(
      of:
        "protocol P { func cancelPendingUnload() }\nextension P { func cancelPendingUnload() {} }",
      protocolName: "P")
    let after = try Self.members(
      of:
        "protocol P { func cancelPendingUnload() }\nextension P { func cancelPendingUnload() { print(1) } }",
      protocolName: "P")
    #expect(before == after)
  }

  @Test(
    "a capability added only via an extension default, with no matching requirement, is still caught"
  )
  func adversarialExtensionOnlyMemberIsDetected() throws {
    let before = try Self.members(
      of: "protocol P { func warmUp() async throws }", protocolName: "P")
    let after = try Self.members(
      of: "protocol P { func warmUp() async throws }\nextension P { func cancel() async {} }",
      protocolName: "P")
    #expect(before != after)
  }

  @Test("a member moving into a #if DEBUG block is a real change, not invisible")
  func adversarialConditionalMemberChangeIsDetected() throws {
    let before = try Self.members(
      of: """
        protocol P {
          func warmUp() async throws
          func armHold() async
        }
        """, protocolName: "P")
    let after = try Self.members(
      of: """
        protocol P {
          func warmUp() async throws
          #if DEBUG
            func armHold() async
          #endif
        }
        """, protocolName: "P")
    #expect(before != after)
  }

  @Test("both branches of a differently-conditioned member are tracked with their own condition")
  func positiveControlConditionalMemberConditionIsCaptured() throws {
    let members = try Self.members(
      of: """
        protocol P {
          #if DEBUG
            func armHold() async
          #endif
        }
        """, protocolName: "P")
    #expect(members.contains { $0.condition == "DEBUG" && $0.signature.contains("armHold") })
  }

  @Test(
    "an #else member is labeled distinctly from a genuinely unconditional member, so moving a requirement from #else to unconditional code is a real detected change (Codex final-integration r1)"
  )
  func adversarialElseMemberIsDistinguishedFromUnconditional() throws {
    let members = try Self.members(
      of: """
        protocol P {
          #if DEBUG
            func armHold() async
          #else
            func releaseHold() async
          #endif
        }
        """, protocolName: "P")
    let releaseHold = members.first { $0.signature.contains("releaseHold") }
    #expect(releaseHold?.condition != nil, "an #else member must not be recorded as unconditional")
    // Moving it to genuinely unconditional code must be a real, detected change.
    let unconditional = try Self.members(
      of: "protocol P { func releaseHold() async }", protocolName: "P")
    #expect(members != unconditional)
  }

  @Test(
    "a nested #if combines with its outer condition rather than replacing it (Codex final-integration r1)"
  )
  func adversarialNestedConditionCombinesWithOuter() throws {
    let members = try Self.members(
      of: """
        protocol P {
          #if DEBUG
            #if os(macOS)
              func armHold() async
            #endif
          #endif
        }
        """, protocolName: "P")
    let armHold = members.first { $0.signature.contains("armHold") }
    #expect(armHold?.condition?.contains("DEBUG") == true)
    #expect(armHold?.condition?.contains("os(macOS)") == true)
  }

  @Test(
    "an unsupported protocol member kind fails the scan closed rather than being silently skipped")
  func adversarialUnsupportedMemberKindFailsClosed() throws {
    #expect(throws: ScanFailedError.self) {
      _ = try Self.members(of: "protocol P { associatedtype Foo }", protocolName: "P")
    }
  }

  @Test("malformed source fails the scan closed rather than being silently treated as clean")
  func adversarialMalformedSourceFailsClosed() throws {
    #expect(throws: ScanFailedError.self) {
      _ = try Self.members(of: "protocol P { func warmUp( {{{ !!! ###", protocolName: "P")
    }
  }

  @Test(
    "a missing protocol declaration fails the scan closed rather than reporting an empty surface")
  func adversarialMissingProtocolFailsClosed() throws {
    #expect(throws: ScanFailedError.self) {
      _ = try Self.protocolSurface(
        named: "DoesNotExist", in: "Sources/EnviousWisprASR/ASRProtocol.swift")
    }
  }

  @Test(
    "a missing concrete-method name fails the scan closed rather than reporting an empty surface")
  func adversarialMissingConcreteMethodFailsClosed() throws {
    #expect(throws: ScanFailedError.self) {
      _ = try Self.concreteMethodSurface(
        typeName: "ParakeetBackend", methodName: "thisMethodDoesNotExist",
        in: "Sources/EnviousWisprASR/ParakeetBackend.swift")
    }
  }

  @Test("a legitimately overloaded concrete method collects every overload as its own member")
  func positiveControlOverloadedConcreteMethodCollectsAll() throws {
    let surface = try Self.concreteMethodSurface(
      typeName: "ParakeetBackend", methodName: "prepare",
      in: "Sources/EnviousWisprASR/ParakeetBackend.swift")
    #expect(
      surface.members.count == 3,
      "expected all three `prepare` overloads, found: \(surface.members)")
  }

  @Test(
    "the target method missing from the NAMED type fails closed even when an unrelated type in the same file has a same-named method (Codex implementation-review r1)"
  )
  func adversarialMethodPresentOnWrongTypeFailsClosed() throws {
    // `Target` exists but has no `prepare`; only unrelated `Other` does —
    // scanning `Target.prepare` must fail closed, never silently match
    // `Other`'s method (the exact fail-open the prior version had).
    #expect(throws: ScanFailedError.self) {
      _ = try Self.concreteMethodMembers(
        inParsedSource: """
          struct Target {}
          struct Other { func prepare() async throws {} }
          """, typeName: "Target", methodName: "prepare", context: "<fixture>")
    }
  }

  @Test(
    "an unrelated same-named method on a DIFFERENT type is never collected — only the named type's own method counts"
  )
  func positiveControlUnrelatedSameNamedMethodIsIgnored() throws {
    let members = try Self.concreteMethodMembers(
      inParsedSource: """
        struct Target { func prepare() async throws {} }
        struct Other { func prepare() async throws {} }
        """, typeName: "Target", methodName: "prepare", context: "<fixture>")
    #expect(members.count == 1, "expected exactly Target's own prepare, found: \(members)")
  }
}
