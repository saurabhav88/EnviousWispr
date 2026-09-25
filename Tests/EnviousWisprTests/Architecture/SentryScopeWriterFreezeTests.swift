import CryptoKit
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3153: freezes every place the app can put a value on a Sentry scope, and every producer of a
/// pipeline breadcrumb, so a new one is a visible edit here.
///
/// Why: user feedback skips `beforeSend`, and a feedback report carries the global scope. Values
/// reach that scope unfiltered only through a writer that forgets `SentryEventSanitizer`. The
/// current writers filter at write time (`SentryScopeWriteSanitizationTests`); this suite makes
/// adding a writer, or a new `SentryBreadcrumb.add` producer whose stage/message/data need a
/// metadata-only review, fail until the inventory below is updated on purpose.
///
/// What it inventories, per call site (file, enclosing function, callee):
/// - `SentrySDK.addBreadcrumb`, `configureScope`, `setUser`, `addFeatureFlag` anywhere in `Sources/`.
/// - Every scope-mutating method call (`setTag`, `setContext`, `addAttachment`, ...) in a file that
///   imports Sentry, including one added inside an already-listed file or closure.
/// - Every `SentryBreadcrumb.add(stage:...)` producer.
/// Guards against a session that FORGETS; an author working to evade a syntax scan is a review
/// finding.
@Suite("Sentry scope writer freeze (#3153)", .serialized, .tags(.driftGuard))
struct SentryScopeWriterFreezeTests {

  static let sdkWriters: Set<String> = [
    "addBreadcrumb", "configureScope", "setUser", "addFeatureFlag",
  ]
  static let scopeMutators: Set<String> = [
    "setTag", "setTags", "removeTag", "setContext", "removeContext", "setExtra", "setExtras",
    "removeExtra", "setUser", "addAttachment", "clearAttachments", "addBreadcrumb",
    "clearBreadcrumbs", "setLevel", "setFingerprint", "setDist", "setEnvironment", "clear",
    "addFeatureFlag",
  ]

  /// SHA-256 of the sorted inventory lines. The failure message prints the inventory and the new
  /// value; update it only after reviewing the new site (filtered at write time? metadata only?).
  static let inventoryFingerprint =
    "8c2a653beb09b961c4d2f9adf5c4b9f26242dd4142c3580e8b49901a49489195"

  struct Site: Hashable, Comparable {
    let file: String
    let function: String
    let callee: String
    var line: String { "\(file)\t\(function)\t\(callee)" }
    static func < (a: Site, b: Site) -> Bool { a.line < b.line }
  }

  final class Scanner: SyntaxVisitor {
    let file: String
    let importsSentry: Bool
    private var functions: [String] = []
    private(set) var sites: [Site] = []

    init(file: String, tree: SourceFileSyntax) {
      self.file = file
      self.importsSentry = tree.statements.contains {
        $0.item.as(ImportDeclSyntax.self)?.path.trimmedDescription == "Sentry"
      }
      super.init(viewMode: .sourceAccurate)
    }

    private var function: String { functions.last ?? "<top>" }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
      functions.append(node.name.text)
      return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { functions.removeLast() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
      functions.append("init")
      return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { functions.removeLast() }
    /// A stored or computed PROPERTY is a site identity like a function; a local `let` is not,
    /// so only member-level variables push a name.
    private var pushedVariable: [Bool] = []
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
      let isMember = node.parent?.is(MemberBlockItemSyntax.self) == true
      pushedVariable.append(isMember)
      if isMember {
        functions.append("var \(node.bindings.first?.pattern.trimmedDescription ?? "<var>")")
      }
      return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) {
      if pushedVariable.removeLast() { functions.removeLast() }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        let base = member.base?.trimmedDescription ?? ""
        if base == "SentrySDK", SentryScopeWriterFreezeTests.sdkWriters.contains(name) {
          record("SentrySDK.\(name)")
        } else if base == "SentryBreadcrumb", name == "add" {
          record("SentryBreadcrumb.add")
        } else if importsSentry, !base.isEmpty, base != "SentrySDK",
          SentryScopeWriterFreezeTests.scopeMutators.contains(name)
        {
          record("\(base).\(name)")
        }
      } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
        ref.baseName.text == "add", node.arguments.first?.label?.text == "stage",
        file.hasSuffix("SentryBreadcrumb.swift")
      {
        // An unqualified producer inside `SentryBreadcrumb` itself.
        record("SentryBreadcrumb.add")
      }
      return .visitChildren
    }

    private func record(_ callee: String) {
      sites.append(Site(file: file, function: function, callee: callee))
    }
  }

  static func scan(file: String, source: String) -> [Site] {
    let tree = Parser.parse(source: source)
    let scanner = Scanner(file: file, tree: tree)
    scanner.walk(tree)
    return scanner.sites
  }

  static func scanSources() throws -> [Site] {
    let root = RepoRoot.url.path
    let dir = RepoRoot.sourceURL("Sources")
    guard
      let walker = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
        errorHandler: { url, error in
          Issue.record("cannot enumerate \(url.path): \(error)")
          return true
        })
    else {
      Issue.record("cannot enumerate \(dir.path)")
      return []
    }
    var sites: [Site] = []
    for case let url as URL in walker {
      let relative = String(url.path.dropFirst(root.count + 1))
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        Issue.record("\(relative) is a symlink; the scan does not follow links, so it refuses one")
        continue
      }
      guard url.pathExtension == "swift" else { continue }
      sites += scan(file: relative, source: try String(contentsOf: url, encoding: .utf8))
    }
    return sites.sorted()
  }

  static func fingerprint(_ sites: [Site]) -> String {
    let joined = sites.map(\.line).joined(separator: "\n")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @Test("The scope-writer and breadcrumb-producer inventory is unchanged")
  func inventoryIsFrozen() throws {
    let sites = try Self.scanSources()
    // Controls: the scan reached the known writers, so an empty or partial walk cannot pass.
    #expect(sites.contains { $0.callee == "SentrySDK.configureScope" })
    #expect(sites.contains { $0.callee == "SentrySDK.addBreadcrumb" })
    #expect(sites.contains { $0.callee == "SentryBreadcrumb.add" })
    #expect(sites.contains { $0.callee == "scope.setTag" })
    let actual = Self.fingerprint(sites)
    #expect(
      actual == Self.inventoryFingerprint,
      """
      The Sentry scope-writer inventory changed. For each new line below, confirm the value is \
      filtered with SentryEventSanitizer at write time (scope writers) or is metadata only \
      (breadcrumb producers), then set inventoryFingerprint to \(actual).
      \(sites.map(\.line).joined(separator: "\n"))
      """)
  }

  @Test("Planted writers are detected")
  func plantedWritersAreDetected() {
    let source = """
      import Sentry
      enum Planted {
        static func a() { SentrySDK.setUser(User(userId: "x")) }
        static func b() { SentrySDK.addFeatureFlag(name: "f", result: true) }
        static func c() {
          SentrySDK.configureScope { scope in scope.addAttachment(Attachment(data: Data(), filename: "f")) }
        }
        static func d() { SentryBreadcrumb.add(stage: "x", message: "y") }
      }
      """
    let callees = Set(Self.scan(file: "Planted.swift", source: source).map(\.callee))
    #expect(
      callees == [
        "SentrySDK.setUser", "SentrySDK.addFeatureFlag", "SentrySDK.configureScope",
        "scope.addAttachment", "SentryBreadcrumb.add",
      ])
    // Negative control: a same-named call in a file that does not import Sentry is not a scope write.
    let unrelated = "enum U { static func f(d: inout [String: String]) { d.setTag(1) } }"
    #expect(Self.scan(file: "U.swift", source: unrelated).isEmpty)
  }
}
