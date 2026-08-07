import AppKit
import EnviousWisprCore
import Foundation

/// States in the Ollama guided-setup flow.
public enum OllamaSetupState: Equatable {
  case detecting
  case notInstalled
  case installedNotRunning
  case runningNoModels
  case pullingModel(progress: Double, status: String)
  case ready
  case error(String)
}

/// Warm-up state for the currently selected Ollama model.
public enum OllamaWarmupState: Equatable {
  case idle
  case warming(model: String)
  case warm(model: String, expiresAt: Date)
  case failed(model: String)

  /// Whether the given model is currently warm (not expired).
  public func isWarm(for model: String) -> Bool {
    if case .warm(let m, let expires) = self, m == model {
      return Date() < expires
    }
    return false
  }
}

/// Quality tier for Ollama catalog models.
public enum OllamaQualityTier: String, Sendable {
  case best = "best"
  case medium = "medium"
  case worst = "worst"

  public var label: String {
    switch self {
    case .best: return "Best"
    case .medium: return "Medium"
    case .worst: return "Fast"
    }
  }
}

/// A model entry in the Ollama catalog (curated or dynamic).
public struct OllamaModelCatalogEntry: Identifiable, Sendable {
  public let name: String
  public let displayName: String
  public let parameterCount: String
  public let qualityTier: OllamaQualityTier
  public let downloadSize: String
  public let isDownloaded: Bool
  /// #1914: true iff Ollama proxies this model to its own servers. Drives the
  /// Manage Models list's separate group and the suppression of size and quality
  /// columns,
  /// which are meaningless for a model that is not on this disk — a cloud row's
  /// `size` is manifest-only (316 bytes for a 158B model).
  ///
  /// Defaulted `false` ONLY because every curated suggestion is by definition a
  /// local pull; the downloaded path always supplies it explicitly from decoded
  /// facts. Unlike `OllamaDownloadedModel.facts`, no row here can be built from
  /// an undecoded `/api/tags` response.
  public let isRemote: Bool

  public var id: String { name }

  public init(
    name: String,
    displayName: String,
    parameterCount: String,
    qualityTier: OllamaQualityTier,
    downloadSize: String,
    isDownloaded: Bool = false,
    isRemote: Bool = false
  ) {
    self.name = name
    self.displayName = displayName
    self.parameterCount = parameterCount
    self.qualityTier = qualityTier
    self.downloadSize = downloadSize
    self.isDownloaded = isDownloaded
    self.isRemote = isRemote
  }
}

/// A model parsed from Ollama's /api/tags response.
public struct OllamaDownloadedModel: Sendable {
  public let exactName: String
  public let canonicalName: String
  public let parameterSize: String?
  public let parameterBillions: Double?
  public let fileSizeBytes: Int64
  public let displayName: String
  /// #1914: the daemon's own facts for THIS row, decoded by the single shared
  /// decoder. Required with no default: a defaulted value would let a row that
  /// was never decoded claim to be local, which is the same silent-fallback
  /// shape the runtime path deliberately made unrepresentable.
  public let facts: OllamaModelFacts
}

/// #1956: the hosted-catalog fetch, as a state rather than a bare array.
///
/// Four cases distinguish never attempted, an initial request in progress, a
/// validated non-empty result, and an initial failure. The client rejects an
/// empty or malformed provider document, so no state here means "Ollama offers
/// nothing."
///
/// `.loading` is explicit only for an INITIAL fetch. A refresh after a success
/// stays `.loaded` so the last good rows remain on screen; the stored refresh
/// task is what records that work is in flight.
package enum CloudCatalogState: Equatable {
  case idle
  case loading
  case loaded(ids: [String], fetchedAt: Date)
  case failed(reason: String)
}

/// #1956: the state of a hosted-model Add, which has to resolve a pullable name
/// before it can pull anything.
///
/// Both non-idle cases carry the advertised id they were started for, so a
/// failure can only ever render beneath the row that caused it. An unkeyed
/// `String?` would put one row's failure under another.
package enum HostedModelAddState: Equatable, Sendable {
  case idle
  case resolving(advertisedID: String)
  case failed(advertisedID: String, message: String)
}

/// #1956 injection seams for hosted Add. Method-local rather than stored, so no
/// initializer carries them and the three construction paths are untouched.
package typealias HostedShowTransport =
  @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// No `@Sendable`: a `@MainActor` function type is already `Sendable` under this
/// package's Swift 6 mode (swift-concurrency-patterns
/// `mainactor-fntype-implicitly-sendable`), so writing it would be redundant.
/// (pullable name, advertised id). The advertised id travels WITH the start
/// call rather than being stamped after it, so `pullModel` can choose honest
/// wording from its first line and no ordering rule has to be remembered.
package typealias HostedPullStarter = @MainActor (String, String) -> Void

/// Guides users through Ollama installation, server startup, and model pulling.
@MainActor
@Observable
public final class OllamaSetupService {

  // MARK: - Public State

  public private(set) var setupState: OllamaSetupState = .detecting
  public private(set) var pullProgress: Double = 0
  public private(set) var pullStatusText: String = ""
  public private(set) var currentPullingModel: String?
  public private(set) var downloadedModels: [OllamaDownloadedModel] = []
  public private(set) var warmupState: OllamaWarmupState = .idle

  /// #1956: what Ollama's own cloud endpoint last told us, and whether we have
  /// asked yet. Never written by any daemon path, and a failure here never
  /// touches `setupState` — the hosted catalog is a limb, so its absence must
  /// degrade the list rather than replace the settings pane with an error.
  package private(set) var cloudCatalog: CloudCatalogState = .idle

  /// #1956: the in-progress or failed hosted Add, if any. Written only by
  /// `addHostedModel`, and never by any daemon, pull, or catalog path.
  package private(set) var hostedModelAddState: HostedModelAddState = .idle

  /// #1956: which ADVERTISED id the current pull was started for, when a hosted
  /// Add started it. Nil for a local pull.
  ///
  /// Exists because a hosted row and the pull it triggered carry DIFFERENT names
  /// (`gpt-oss:20b` vs `gpt-oss:20b-cloud`), and the obvious fix — normalising
  /// both through `hostedCatalogKey` — collides in the other direction: a local
  /// `gpt-oss:20b` pull normalises to the same key, so the hosted row would show
  /// progress and a Cancel button for a download it did not start. Recording the
  /// exact id removes the guess instead of relocating it.
  ///
  /// Liveness is NOT read from this property. `rowIsPulling` requires
  /// `currentPullingModel` to be non-nil as well, so a value left behind here
  /// cannot match anything once the pull reaches any terminal — that keeps the
  /// five existing clear sites as the single authority on "a pull is running".
  package private(set) var hostedPullAdvertisedID: String?

  private let cloudCatalogClient: OllamaCloudCatalogClient
  private let cloudCatalogNow: @MainActor () -> Date
  private var cloudCatalogRefreshTask: Task<Void, Never>?

  // Per-pull generation token. Bumped on every pullModel/cancelPull call so stale
  // tasks can no-op their writes (Swift Task cancellation is cooperative; without
  // this, a late chunk or terminal-branch cleanup from an old task could clobber
  // the newer pull's state, most acutely on cancel-then-re-download-same-model).
  private var pullEpoch: UInt64 = 0

  /// #1956: the same generation guard as `pullEpoch`, for the window `pullEpoch`
  /// cannot cover.
  ///
  /// A hosted Add spends two `/api/show` round trips resolving a name BEFORE any
  /// pull exists. `cancelPull()` is what `onChange(llmProvider)` calls when the
  /// user leaves Ollama, and during that window it finds `pullTask == nil` and
  /// `currentPullingModel == nil`, so it correctly does nothing — and the
  /// resolution then calls `startPull` anyway, beginning a pull for a provider
  /// the user has already left. Worse, that late pull runs `pullModel`, which
  /// cancels whatever pull is current, so it can kill a pull the user started
  /// after switching back.
  ///
  /// Ported from `pullEpoch` rather than invented: same wrap-safe `&+=`, same
  /// read-it-before-you-act discipline, so there is one pattern in this file
  /// instead of two.
  private var hostedAddEpoch: UInt64 = 0

  /// Canonical names of downloaded models. Backward-compatible with old Set<String> consumers.
  public var downloadedModelNames: Set<String> {
    Set(downloadedModels.map(\.canonicalName))
  }

  // MARK: - Model Catalog

  /// Curated suggestions for users who haven't downloaded models yet.
  /// `nonisolated`: immutable Sendable constant, readable from the pure catalog
  /// assembly (`dynamicCatalog(from:)`) and telemetry without a MainActor hop.
  public nonisolated static let modelCatalog: [OllamaModelCatalogEntry] = [
    OllamaModelCatalogEntry(
      name: "gemma3n:e4b", displayName: "Gemma 3 Nano (4B)", parameterCount: "4B",
      qualityTier: .best, downloadSize: "~6 GB"),
    OllamaModelCatalogEntry(
      name: "llama3.2", displayName: "Llama 3.2", parameterCount: "3B", qualityTier: .best,
      downloadSize: "~2 GB"),
    OllamaModelCatalogEntry(
      name: "llama3.2:1b", displayName: "Llama 3.2 (1B)", parameterCount: "1B",
      qualityTier: .medium, downloadSize: "~800 MB"),
    OllamaModelCatalogEntry(
      name: "mistral", displayName: "Mistral", parameterCount: "7B", qualityTier: .best,
      downloadSize: "~4 GB"),
    OllamaModelCatalogEntry(
      name: "phi3", displayName: "Phi-3 Mini", parameterCount: "3.8B", qualityTier: .medium,
      downloadSize: "~2.3 GB"),
    OllamaModelCatalogEntry(
      name: "gemma2:2b", displayName: "Gemma 2 (2B)", parameterCount: "2B", qualityTier: .medium,
      downloadSize: "~1.6 GB"),
    OllamaModelCatalogEntry(
      name: "gemma2", displayName: "Gemma 2", parameterCount: "9B", qualityTier: .best,
      downloadSize: "~5.5 GB"),
    OllamaModelCatalogEntry(
      name: "qwen2.5:3b", displayName: "Qwen 2.5 (3B)", parameterCount: "3B", qualityTier: .medium,
      downloadSize: "~1.9 GB"),
    OllamaModelCatalogEntry(
      name: "qwen2.5:7b", displayName: "Qwen 2.5 (7B)", parameterCount: "7B", qualityTier: .best,
      downloadSize: "~4.4 GB"),
    OllamaModelCatalogEntry(
      name: "tinyllama", displayName: "TinyLlama", parameterCount: "1.1B", qualityTier: .worst,
      downloadSize: "~638 MB"),
    OllamaModelCatalogEntry(
      name: "phi-2", displayName: "Phi-2", parameterCount: "2.7B", qualityTier: .worst,
      downloadSize: "~1.7 GB"),
  ]

  /// First-party curated metadata for models that are NOT publicly pullable (#1269).
  /// Entries here overlay display metadata onto a model the user already has, but are
  /// NEVER offered as undownloaded suggestions — `ollama pull` would 404 on them, so a
  /// suggestion row would render a dead Download button. EG-1 distribution ships
  /// separately (see the tuned-polish-provider wiring plan).
  public nonisolated static let curatedPrivateCatalog: [OllamaModelCatalogEntry] = [
    OllamaModelCatalogEntry(
      name: "eg-1", displayName: "EG-1", parameterCount: "4B",
      qualityTier: .best, downloadSize: "~2.9 GB")
  ]

  /// The single definition of "this Ollama model id is our own first-party model"
  /// (#1269, cloud review r1-r3). EXACT match only: the model `eg-1` or a tag of it
  /// (`eg-1:latest`, `eg-1:q4`). Deliberately NOT a loose prefix — a user-named
  /// `eg-10` or `eg-1-acme-client` is a DIFFERENT model that must route through the
  /// normal heuristics and report `custom` in telemetry. Future first-party variants
  /// ship as `curatedPrivateCatalog` entries, not as prefix carve-outs.
  public nonisolated static func isFirstPartyModel(_ modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return canonicalModelName(lower) == "eg-1" || lower.hasPrefix("eg-1:")
  }

  /// Dynamic catalog: downloaded models first (with real metadata), then undownloaded suggestions.
  ///
  /// #1956: hosted suggestions are supplied only from a `.loaded` cloud catalog.
  /// `.idle`, `.loading` and `.failed` all contribute nothing, so the list
  /// degrades to exactly its pre-#1956 contents rather than to a guess.
  public var dynamicCatalog: [OllamaModelCatalogEntry] {
    if case .loaded(let ids, _) = cloudCatalog {
      return Self.dynamicCatalog(from: downloadedModels, cloudCatalogIDs: ids)
    }
    return Self.dynamicCatalog(from: downloadedModels)
  }

  /// #1956: shared identity for a hosted model, which reaches us under two
  /// different names.
  ///
  /// Ollama ADVERTISES `glm-5.2` at its cloud endpoint but REGISTERS it locally
  /// as `glm-5.2:cloud`, and advertises `gpt-oss:120b` while registering
  /// `gpt-oss:120b-cloud`. Without one key for both, a model the user has already
  /// added would render twice: once as a downloaded row and once as a suggestion
  /// to add it.
  ///
  /// Strips ONE trailing `:cloud` or `-cloud`, then applies the existing
  /// `canonicalModelName`, so this extends the module's identity authority rather
  /// than becoming a second one. Only a trailing occurrence: a model legitimately
  /// named `cloud-thing` or `my:cloudy` keeps its name.
  ///
  /// `package` rather than internal because `OllamaCatalogPresentation` in
  /// AppKit applies the same key when it groups rows by tier, and a second copy
  /// of this rule there would be free to drift.
  package nonisolated static func hostedCatalogKey(_ name: String) -> String {
    var base = name
    for suffix in [":cloud", "-cloud"] where base.hasSuffix(suffix) {
      base = String(base.dropLast(suffix.count))
      break
    }
    return canonicalModelName(base)
  }

  /// Pure catalog assembly (extracted for testability, #1269 — behavior unchanged).
  ///
  /// #1956: `cloudCatalogIDs` carries the models Ollama's own cloud endpoint
  /// advertises. It defaults to empty, so every existing caller and test keeps
  /// the pre-#1956 output byte for byte.
  ///
  /// That array is the SOLE proof a suggestion is remote. Nothing here reads a
  /// name to decide remoteness — that is the name-based classification #1914
  /// deliberately replaced with capability reads, and re-introducing it for
  /// suggestions would reopen it by the back door.
  nonisolated static func dynamicCatalog(
    from downloadedModels: [OllamaDownloadedModel],
    cloudCatalogIDs: [String] = []
  ) -> [OllamaModelCatalogEntry] {
    let canonicalDownloaded = Set(downloadedModels.map(\.canonicalName))

    // Build catalog entries from downloaded models
    let downloadedEntries: [OllamaModelCatalogEntry] = downloadedModels.map { model in
      // Overlay curated metadata if we have a catalog match. First-party private
      // entries (EG-1) participate in the overlay only — the suggestions section
      // below deliberately draws from `modelCatalog` alone (#1269), so a not-yet-
      // downloaded private model can never render a dead public Download row.
      if let curated = (Self.modelCatalog + Self.curatedPrivateCatalog).first(where: {
        Self.canonicalModelName($0.name) == model.canonicalName
      }) {
        return OllamaModelCatalogEntry(
          name: model.exactName,
          // #1956: a hosted row keeps Ollama's own name. See `hostedDisplayName`
          // for why the curated name is wrong here even when one matches.
          displayName: model.facts.isRemote
            ? Self.hostedDisplayName(from: model.exactName)
            : curated.displayName,
          parameterCount: model.parameterSize ?? curated.parameterCount,
          qualityTier: curated.qualityTier,
          downloadSize: Self.formatFileSize(model.fileSizeBytes),
          isDownloaded: true,
          // #1914: carried on BOTH construction paths. A remote model can match
          // a curated row by name, so setting it only on the custom branch below
          // would silently lose remoteness for exactly the well-known models.
          isRemote: model.facts.isRemote
        )
      }

      // Unknown/custom model: infer metadata
      return OllamaModelCatalogEntry(
        name: model.exactName,
        // #1956: third and last construction path, same policy. Two registered
        // hosted models whose ids differ only after the colon rendered
        // identically before this.
        displayName: model.facts.isRemote
          ? Self.hostedDisplayName(from: model.exactName)
          : Self.inferDisplayName(from: model.exactName),
        parameterCount: model.parameterSize ?? "Unknown",
        qualityTier: Self.inferQualityTier(parameterBillions: model.parameterBillions),
        downloadSize: Self.formatFileSize(model.fileSizeBytes),
        isDownloaded: true,
        isRemote: model.facts.isRemote
      )
    }
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    // Undownloaded suggestions (preserve static catalog order)
    let suggestions: [OllamaModelCatalogEntry] = Self.modelCatalog.compactMap { entry in
      let canonical = Self.canonicalModelName(entry.name)
      guard !canonicalDownloaded.contains(canonical) else { return nil }
      return entry
    }

    // #1956: hosted suggestions, appended last so the two existing sections keep
    // their order and their meaning.
    //
    // Dedupe runs through `hostedCatalogKey` on BOTH sides, because a registered
    // row carries the pullable name (`glm-5.2:cloud`) while the endpoint
    // advertises the bare one (`glm-5.2`). Matching raw strings would let an
    // already-added model render a second time as an Add row.
    //
    // The registered row always wins: it is the one with real daemon-derived
    // facts, and it is what the picker can actually select.
    // Only REMOTE registrations suppress a hosted suggestion. A local `gpt-oss:20b`
    // is a different thing from Ollama's hosted `gpt-oss:20b`: it shares a name and
    // nothing else, and treating it as the registration hid an addable model.
    let hostedKeysDownloaded = Set(
      downloadedModels.filter { $0.facts.isRemote }.map { Self.hostedCatalogKey($0.exactName) })
    let hostedSuggestions: [OllamaModelCatalogEntry] = cloudCatalogIDs.compactMap { advertisedID in
      guard !hostedKeysDownloaded.contains(Self.hostedCatalogKey(advertisedID)) else { return nil }
      return OllamaModelCatalogEntry(
        name: advertisedID,
        displayName: Self.hostedDisplayName(from: advertisedID),
        // Size and quality are meaningless for a model that is not on this disk,
        // and `showsSizeAndQuality` suppresses both for any remote row, so these
        // are placeholders that never reach the screen rather than claims.
        parameterCount: "",
        qualityTier: .medium,
        downloadSize: "",
        isDownloaded: false,
        isRemote: true
      )
    }

    return downloadedEntries + suggestions + hostedSuggestions
  }

  // MARK: - Name Normalization

  /// Canonical name: strips `:latest` suffix only. All other tags preserved.
  ///
  /// Delegates to `LLMModelInfo.canonicalOllamaName` in Core so this rule has
  /// ONE implementation. `EnviousWisprServices` needs the same rule and cannot
  /// import this module (PR #1949 cloud review); duplicating it there would
  /// have made two authorities for one question. The 28 call sites of this
  /// name keep working unchanged.
  public nonisolated static func canonicalModelName(_ name: String) -> String {
    LLMModelInfo.canonicalOllamaName(name)
  }

  // MARK: - Parameter Size Parsing

  /// Parse Ollama parameter size strings like "3B", "3.2B", "500M", "1T" into billions.
  /// Returns nil if parsing fails.
  public nonisolated static func parseParameterSize(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let upper = trimmed.uppercased()
    let multiplier: Double

    if upper.hasSuffix("B") {
      multiplier = 1.0
    } else if upper.hasSuffix("M") {
      multiplier = 0.001
    } else if upper.hasSuffix("T") {
      multiplier = 1000.0
    } else {
      return nil
    }

    let numberPart = String(upper.dropLast())
    guard let value = Double(numberPart), value > 0 else { return nil }
    return value * multiplier
  }

  // MARK: - Weak Model Detection — DELETED (#1948)

  // `isWeakModel`, `weakModelFallbackPrefixes` and `sizeTagRegex` were removed here, not
  // extended. They decided which Ollama models got a simplified prompt from a hardcoded
  // prefix list (`tinyllama`, `phi-2`, `gemma2:2b`, `llama3.2`) plus a `:Nb` size regex —
  // a hand-authored prediction about which models other people install, and a size
  // threshold standing in for a capability nobody measured. Prompt selection now reads the
  // one fact the daemon reports: does this model run on the user's Mac or on Ollama's
  // servers. Same deletion, same reasoning, and immediately below the #1914 one.
  //
  // #1914: a hand-authored family-prefix list and its name-matching classifier
  // were DELETED here, not extended. They named four families and every thinking
  // model outside that list was mis-budgeted. A hand-authored membership set is
  // a prediction about which models other people install, and `/api/tags`
  // answers the question directly per model — verified in both directions
  // across 12 models, including one that reports no thinking capability at all.
  //
  // The replacement is `OllamaModelFacts.thinks`, decoded once in
  // `OllamaConnector.modelFacts(fromTagsRow:)` and carried per attempt. Do not
  // reintroduce a name-based fallback beside it: two authorities for one
  // question is the scatter this deletion removes.
  //
  // The retired symbol names are deliberately not written here, so that a grep
  // for them returns zero and stays usable as a residue check. They are in the
  // commit message and in `.claude/knowledge/ollama-operations.md` for anyone
  // searching history.

  // MARK: - Private

  private var ollamaProcess: Process?
  private var pullTask: Task<Void, Never>?
  private var warmupTask: Task<Void, Never>?

  private static let binaryPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
  private static let baseURL = "http://localhost:11434"
  private static let lastKnownStateKey = "OllamaSetupService.lastKnownReady"

  // MARK: - Detection Pipeline

  /// #1956: ONE designated initializer, three convenience paths.
  ///
  /// Every construction route funnels through here specifically so that adding a
  /// stored dependency cannot silently break one of them. That is not
  /// hypothetical: the first draft of this chunk added two stored `let`s and
  /// accounted for only two of the three initializers, which does not compile.
  /// A single designated initializer makes the next added dependency impossible
  /// to miss rather than merely something to remember.
  private init(
    cloudCatalogClient: OllamaCloudCatalogClient,
    now: @escaping @MainActor () -> Date,
    downloadedModels: [OllamaDownloadedModel]
  ) {
    self.cloudCatalogClient = cloudCatalogClient
    self.cloudCatalogNow = now
    self.downloadedModels = downloadedModels
  }

  public convenience init() {
    self.init(cloudCatalogClient: OllamaCloudCatalogClient(), now: Date.init, downloadedModels: [])
  }

  /// #1956 injection seam. `package` rather than public because a public
  /// initializer cannot carry a `package`-only parameter, and nothing outside
  /// this package constructs the service with a substitute client.
  ///
  /// The clock is `@MainActor () -> Date` with no `@Sendable`: under this
  /// package's Swift 6 mode a `@MainActor` function type is already `Sendable`
  /// (swift-concurrency-patterns `mainactor-fntype-implicitly-sendable`), so
  /// writing it would be redundant. It exists so the 15-minute reuse boundary is
  /// tested by advancing a clock rather than by sleeping
  /// (swift-patterns RULE: tests-no-real-time-scheduling-precision).
  package convenience init(
    cloudCatalogClient: OllamaCloudCatalogClient,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.init(cloudCatalogClient: cloudCatalogClient, now: now, downloadedModels: [])
  }

  /// #1914 test seam, approved by the founder on 2026-08-04 (test seams are a
  /// founder decision per `workflow-process.md` RULE: chunked-build-orchestration).
  /// Internal so it does not widen the public API.
  ///
  /// Live Ollama operations normally populate or mutate `downloadedModels`.
  /// This initializer lets the eviction wiring test distinguish populated
  /// remote and local catalogs without making a network request.
  convenience init(downloadedModelsForTesting: [OllamaDownloadedModel]) {
    self.init(
      cloudCatalogClient: OllamaCloudCatalogClient(), now: Date.init,
      downloadedModels: downloadedModelsForTesting)
  }

  /// Run the full detection pipeline: binary -> server -> models.
  public func detectState() async {
    setupState = .detecting

    // Fast path: if the user previously reached .ready, try the server directly.
    if UserDefaults.standard.bool(forKey: Self.lastKnownStateKey) {
      if await isServerRunning() {
        if await hasAnyModels() {
          setupState = .ready
          return
        }
        setupState = .runningNoModels
        return
      }
    }

    // Full detection
    guard findOllamaBinary() != nil else {
      setupState = .notInstalled
      UserDefaults.standard.set(false, forKey: Self.lastKnownStateKey)
      return
    }

    guard await isServerRunning() else {
      // isServerRunning may have already set an .error state (port conflict)
      if case .error = setupState { return }
      setupState = .installedNotRunning
      return
    }

    if await hasAnyModels() {
      setupState = .ready
      UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
    } else {
      setupState = .runningNoModels
    }
  }

  // MARK: - Binary Discovery

  /// Locate the Ollama binary on disk. Returns the path or nil.
  public func findOllamaBinary() -> String? {
    // Check well-known paths first
    for path in Self.binaryPaths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Fallback: ask the shell
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["ollama"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }

    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let path = output, !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    else {
      return nil
    }
    return path
  }

  // MARK: - Server Health

  /// Check whether the Ollama server is reachable. Strict 3-second timeout.
  public func isServerRunning() async -> Bool {
    guard let url = URL(string: Self.baseURL) else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 3

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }

      if http.statusCode == 200 {
        return true
      }

      // Port is in use by something other than Ollama
      setupState = .error(
        "Another app is using Ollama's port (11434). Close it and try again."
      )
      return false
    } catch {
      return false
    }
  }

  /// Check whether Ollama has at least one pulled model.
  public func hasAnyModels() async -> Bool {
    await refreshDownloadedModels()
    return !downloadedModels.isEmpty
  }

  // MARK: - Model Management

  /// #1956: fetch the hosted catalog from Ollama's cloud endpoint, at most once
  /// at a time, reusing a recent success.
  ///
  /// **The stored task owns the COMMIT, not just the transport.** If each caller
  /// committed state after awaiting a shared transport task, both would become
  /// runnable when the transport finished and the joining caller could resume
  /// first — returning while `cloudCatalog` was still `.loading`. That is the
  /// post-`await` stale-read shape swift-concurrency-patterns
  /// `actor-reentrancy-await` exists to prevent. Joining therefore means
  /// awaiting the commit, not awaiting the bytes.
  ///
  /// **The existing-task check precedes the freshness check deliberately**, so a
  /// `force: true` caller arriving during an in-flight refresh joins it rather
  /// than starting a second identical request.
  ///
  /// There is no `CancellationError` branch. This runs in a separate unstructured
  /// `Task`, which does not inherit caller cancellation
  /// (swift-concurrency-patterns `task-cancel-flag-not-abort`), so the only way
  /// to see one is a transport that throws it — and a transport-thrown
  /// cancellation is just a failure, which the ordinary `catch` already handles
  /// correctly.
  package func refreshCloudCatalog(force: Bool = false) async {
    if let existing = cloudCatalogRefreshTask {
      await existing.value
      return
    }

    if !force, case .loaded(_, let fetchedAt) = cloudCatalog,
      cloudCatalogNow().timeIntervalSince(fetchedAt) < 15 * 60
    {
      return
    }

    let previous = cloudCatalog
    // A refresh after a success keeps the last good rows visible. Only an
    // initial fetch shows `.loading`, because there is nothing else to show.
    if case .loaded = previous {} else { cloudCatalog = .loading }

    // Created and stored on `@MainActor` with no `await` between, so no second
    // caller can slip in and install a competing task.
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.cloudCatalogRefreshTask = nil }
      do {
        let ids = try await self.cloudCatalogClient.fetchIDs()
        // The clock is read at COMPLETION, not at request start: the reuse
        // window should begin when the answer arrived.
        self.cloudCatalog = .loaded(ids: ids, fetchedAt: self.cloudCatalogNow())
      } catch {
        // A failure never discards a prior success. Losing a good list because a
        // later refresh failed would be worse than showing a slightly stale one.
        if case .loaded = previous {
          self.cloudCatalog = previous
        } else {
          self.cloudCatalog = .failed(reason: "catalog_unavailable")
        }
      }
    }
    cloudCatalogRefreshTask = task
    await task.value
  }

  // MARK: - Hosted model Add (#1956)

  /// What one `/api/show` probe proved about a candidate name.
  ///
  /// Three cases, not two, because "the daemon said no" and "we could not get an
  /// answer" must never collapse. Only 404 is a denial; everything else — any
  /// other status, a non-HTTP response, a transport throw, a cancellation — is
  /// an absence of information, and treating it as denial is how a reachable
  /// model gets told it does not exist.
  /// A probe's answer, carrying the model IDENTITY on success.
  ///
  /// `proven` gained its payload from review r5. The earlier version was a bare
  /// case, which made two 200s indistinguishable from two DIFFERENT models and
  /// forced a refusal — see the `(.proven, .proven)` branch for why that broke
  /// Add for 8 of the 18 advertised models.
  private enum HostedCandidateOutcome: Equatable {
    case proven(identity: String)
    case absent
    case indeterminate
  }

  /// The identity fingerprint of an `/api/show` body, used only to decide
  /// whether two candidate NAMES are aliases of one model.
  ///
  /// `modified_at` is excluded because it is per-registration state, not model
  /// identity; everything else in the document is what the daemon knows about
  /// the model itself. Measured 2026-08-06: `gpt-oss:20b-cloud` and
  /// `gpt-oss:20b:cloud` produce byte-identical `details`, `capabilities` and
  /// `model_info`, including the same `parent_model` of `gpt-oss:20b`.
  ///
  /// A missing or unreadable body yields a value that cannot equal another, so
  /// an unparseable pair stays ambiguous and is refused rather than guessed.
  nonisolated static func hostedIdentityFingerprint(fromShowBody data: Data) -> String? {
    guard
      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    json.removeValue(forKey: "modified_at")

    // The body must actually SAY something about the model. Review r7: a 200
    // carrying `{}` or only `modified_at` parses fine and fingerprints to the
    // same empty document on both candidates, so two content-free responses
    // would compare equal and register a model neither of them identified.
    // Rejecting an unparseable body was not enough — the dangerous shape is
    // parseable and vacuous.
    //
    // `model_info` OR `details.family`, not `parent_model`: measured 2026-08-06,
    // `parent_model` is populated for a cloud model (`gpt-oss:20b`) and EMPTY
    // for a local one (`llama3.2:latest`, `gemma3n:e4b`), so requiring it would
    // reject a legitimate body. Both alternatives were present and non-empty on
    // all three, so the requirement is satisfied with redundancy while `{}`
    // still fails.
    //
    // Refusing wrongly costs an honest "could not confirm" the user can retry;
    // accepting wrongly registers an unverified model. The asymmetry is why this
    // fails closed.
    let details = json["details"] as? [String: Any]
    let hasFamily = ((details?["family"] as? String) ?? "").isEmpty == false
    let hasModelInfo = ((json["model_info"] as? [String: Any]) ?? [:]).isEmpty == false
    guard hasFamily || hasModelInfo else { return nil }

    guard
      let canonical = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    else { return nil }
    return String(decoding: canonical, as: UTF8.self)
  }

  private static let hostedAddAmbiguousMessage =
    "Ollama returned two valid names for this model. Add it in Ollama, then refresh this list."

  private static let hostedAddNoUsableNameMessage =
    "Ollama listed this model but did not return a name EnviousWispr can add. Try again after updating Ollama."

  /// Deliberately asserts no cause. Whether a signed-out user's `/api/show`
  /// succeeds is unverified (plan §2.5.5), so naming a cause here would risk a
  /// confident wrong claim in exactly the branch that exists to avoid one.
  private static let hostedAddUnreachableMessage =
    "EnviousWispr could not confirm this model's name with Ollama. Try again in a moment."

  /// #1956: abandon a hosted name resolution that is still probing.
  ///
  /// Separate from `cancelPull()` rather than folded into it, and the distinction
  /// is load-bearing. `cancelPull()` also fires when the user cancels an
  /// unrelated LOCAL download, and local Download buttons stay enabled while a
  /// hosted row resolves (`AIPolishSettingsView`'s `.disabled` scopes the
  /// resolving clause to remote rows). Bumping the epoch there would let
  /// cancelling one model's download silently abandon a different model's Add.
  ///
  /// Call this for "the user left Ollama", never for "a pull was cancelled".
  public func cancelHostedResolution() {
    hostedAddEpoch &+= 1
    // EVERY non-idle state, not just `.resolving` (review r8). A `.failed`
    // survives a provider round trip otherwise, so leaving Ollama and coming
    // back later re-renders an old error under a row where nothing has been
    // attempted since — and the conditions that produced it may well have
    // changed. Leaving Ollama ends the whole episode, failure included.
    hostedModelAddState = .idle
  }

  /// Add a hosted model by resolving its pullable name against the daemon.
  ///
  /// Ollama advertises a hosted model under one id and pulls it under another.
  /// The measured suffix pattern holds 18/18, but it is never used as proof or
  /// to skip a probe. Both candidates are probed in fixed dash-then-colon order,
  /// and only exactly one 200 paired with one 404 proves a pullable name.
  ///
  /// #1914's binding decision forbids name-based classification, and the #1956
  /// issue comment named that exact inference as a reason to reject this whole
  /// approach. So the shape informs nothing at runtime: the daemon decides.
  package func addHostedModel(advertisedID: String) async {
    await addHostedModel(
      advertisedID: advertisedID,
      show: { try await URLSession.shared.data(for: $0) },
      startPull: { self.pullModel($0, hostedAdvertisedID: $1) })
  }

  /// Injection overload. The production overload above routes through this exact
  /// body, so a test never exercises a reimplementation of the resolution.
  package func addHostedModel(
    advertisedID: String,
    show: HostedShowTransport,
    startPull: HostedPullStarter
  ) async {
    // Global gate, not per-row: the view disables every hosted Add button while
    // a resolution is in flight, and this is the floor under that. Without it a
    // second Add reaching `pullModel` would cancel the first one's pull.
    if case .resolving = hostedModelAddState { return }
    hostedModelAddState = .resolving(advertisedID: advertisedID)

    // Read BEFORE the probes, compared after. Any `cancelPull()` in between —
    // which is what leaving Ollama triggers — makes every branch below a no-op.
    hostedAddEpoch &+= 1
    let epoch = hostedAddEpoch

    let dashCandidate = "\(advertisedID)-cloud"
    let colonCandidate = "\(advertisedID):cloud"

    // Both are probed unconditionally. Stopping at the first 200 would make
    // probe ORDER the authority on the model's identity, which is the hidden
    // assumption this design exists to remove.
    let dashOutcome = await Self.probeHostedCandidate(dashCandidate, show: show)
    let colonOutcome = await Self.probeHostedCandidate(colonCandidate, show: show)

    // Superseded: the user cancelled, left Ollama, or started a replacement Add
    // while the probes ran. Start no pull and publish NO STATE AT ALL.
    //
    // Writing nothing is the whole fix, and an earlier version got this wrong in
    // a way review r4 caught. It cleared `.resolving` when the in-flight id
    // matched its own — but a user who leaves, returns, and retries the SAME
    // model produces a replacement whose id is identical, so the superseded task
    // reset the replacement's state to `.idle`, re-enabling every download
    // control while the replacement was still probing.
    //
    // Publishing nothing is unconditionally correct because whoever bumped the
    // epoch already owns the state: a replacement Add set `.resolving` for
    // itself, and `cancelHostedResolution` set `.idle`. There is no third
    // bumper, so there is no case left to clean up here.
    guard hostedAddEpoch == epoch else { return }

    switch (dashOutcome, colonOutcome) {
    case (.proven, .absent):
      hostedModelAddState = .idle
      startPull(dashCandidate, advertisedID)
    case (.absent, .proven):
      hostedModelAddState = .idle
      startPull(colonCandidate, advertisedID)

    case (.proven(let dashIdentity), .proven(let colonIdentity))
    where dashIdentity == colonIdentity:
      // ALIASES, not ambiguity. Two names, one model, proven by the bodies.
      //
      // This branch used to refuse, on the reasoning that nothing in a 200
      // proves the two names denote one model. That was true of a STATUS CODE
      // and false of the response body, and refusing broke Add for every
      // advertised id that already carries a tag — 8 of the 18 live on
      // 2026-08-06, including 4 of the 7 in the free group.
      //
      // The measurement that missed it is worth naming: the mapping probe that
      // established the suffix rule stopped at the FIRST 200, so it never asked
      // whether the second also answered. The production code asked both, and
      // only review r5 pointed the instrument at the question the code actually
      // depends on.
      hostedModelAddState = .idle
      startPull(dashCandidate, advertisedID)

    case (.proven, .proven):
      // Two names, two DIFFERENT models. Still refuse: registering the wrong one
      // is worse than asking the user to choose, and now the refusal fires only
      // when the daemon itself says they differ.
      hostedModelAddState = .failed(
        advertisedID: advertisedID, message: Self.hostedAddAmbiguousMessage)
    case (.absent, .absent):
      hostedModelAddState = .failed(
        advertisedID: advertisedID, message: Self.hostedAddNoUsableNameMessage)
    default:
      // At least one probe returned no information, so no combination here can
      // prove a name. Never claims the model is missing.
      hostedModelAddState = .failed(
        advertisedID: advertisedID, message: Self.hostedAddUnreachableMessage)
    }
  }

  /// Not `nonisolated`: `baseURL` is MainActor-isolated, and the transport is
  /// `@Sendable` so it leaves the actor on its own. Matching the isolation of
  /// the existing `refreshDownloadedModels` daemon call rather than inventing a
  /// second convention.
  private static func probeHostedCandidate(
    _ candidate: String, show: HostedShowTransport
  ) async -> HostedCandidateOutcome {
    guard let request = hostedShowRequest(candidate: candidate) else { return .indeterminate }
    do {
      let (data, response) = try await show(request)
      guard let http = response as? HTTPURLResponse else { return .indeterminate }
      switch http.statusCode {
      case 200:
        // A 200 whose body cannot be read is not a proven name. Treating it as
        // proven would put an unidentifiable model into the alias comparison,
        // where "no identity" must never compare equal to another.
        guard let identity = hostedIdentityFingerprint(fromShowBody: data) else {
          return .indeterminate
        }
        return .proven(identity: identity)
      case 404: return .absent
      default: return .indeterminate
      }
    } catch {
      return .indeterminate
    }
  }

  /// The body carries exactly one field, the candidate name. No user content, no
  /// identifier, and the existing localhost daemon boundary rather than a new
  /// public-internet call.
  private static func hostedShowRequest(candidate: String) -> URLRequest? {
    guard let url = URL(string: "\(baseURL)/api/show"),
      let body = try? JSONSerialization.data(withJSONObject: ["model": candidate])
    else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    return request
  }

  /// Refresh the list of downloaded models from GET /api/tags, parsing full metadata.
  public func refreshDownloadedModels() async {
    guard let url = URL(string: "\(Self.baseURL)/api/tags") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let models = json?["models"] as? [[String: Any]] else { return }
      downloadedModels = Self.parseDownloadedModels(fromTagsModels: models)
    } catch {
      // Silently ignore -- server may not be running
    }
  }

  /// #1914: whether a warm-up may run at all, and with which facts.
  ///
  /// Pure so the policy is testable without a server, in the same spirit as
  /// `OllamaConnector.makeEvictRequestBody`. Returning the FACTS rather than a
  /// bare Bool is deliberate: the caller needs `thinks` to build the body, and
  /// handing back one value keeps the decision and the data it implies together
  /// instead of letting the caller re-derive facts it might resolve differently.
  enum WarmupPolicy: Equatable {
    case run(facts: OllamaModelFacts)
    /// Ollama proxies this model to its own servers: nothing local to warm, and
    /// a request would spend the user's cloud quota for no benefit.
    case skipRemote
    /// The model is not in the catalog, so remoteness is UNKNOWN. Skipping is
    /// the safe direction — warm-up is best-effort by contract and not
    /// guaranteed before any given dictation, so the cost is a marginally
    /// slower first polish rather than a wrongly-spent cloud request.
    case skipUnknownModel
  }

  /// #1914: the warm-up `/api/chat` body, pure so its shape is testable without
  /// a server — the same treatment `OllamaConnector.makeEvictRequestBody` and
  /// `makeRequestBody` already get.
  ///
  /// This function is where the LAST live `think: false` in the repo was
  /// removed. Two of three tested models silently IGNORE the boolean and emit
  /// reasoning anyway (gemma4, gpt-oss; nemotron honoured it), so it never was
  /// the control it appeared to be. A thinking model gets an explicit `"low"`;
  /// a non-thinking one gets no key at all, matching the polish request exactly.
  ///
  /// Extracted only after a mutation control proved the inline version was
  /// untestable: changing `"low"` to `"high"` left every warm-up test green.
  /// Three-state, mirroring the polish request exactly: only a REPORTED
  /// thinking model gets `"low"`. Unknown sends no key, as pre-#1914 `main` did.
  nonisolated static func makeWarmupRequestBody(model: String, thinks: Bool?) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "messages": [["role": "user", "content": "hi"]],
      "stream": false,
      "keep_alive": "60m",
      "options": ["num_predict": 1],
    ]
    if thinks == true {
      body["think"] = "low"
    }
    return body
  }

  /// Retires an in-flight warm-up and any `.warming` state belonging to the
  /// model being switched away from. One owner so the two callers — the skip
  /// path and the normal model-switch path — cannot diverge.
  ///
  /// `.warm` is deliberately NOT cleared: a model that genuinely finished
  /// warming is still resident in Ollama's memory, so discarding that fact would
  /// make the app re-warm something already warm. Only the in-flight and
  /// pending-publish states are retired.
  private func cancelWarmupForModelSwitch() {
    warmupTask?.cancel()
    warmupTask = nil
    if case .warming = warmupState {
      warmupState = .idle
    }
  }

  nonisolated static func warmupPolicy(for matched: OllamaDownloadedModel?) -> WarmupPolicy {
    guard let matched else { return .skipUnknownModel }
    return matched.facts.isRemote ? .skipRemote : .run(facts: matched.facts)
  }

  /// Debug-log receipt wording. Never includes `remote_host` — the boolean is
  /// the whole answer and the host is the user's environment (`CLAUDE.md` §
  /// Privacy: metadata, never content or environment values).
  nonisolated static func warmupSkipReason(for matched: OllamaDownloadedModel?) -> String {
    switch warmupPolicy(for: matched) {
    case .run: return "not skipped"
    case .skipRemote: return "remote"
    case .skipUnknownModel: return "model not in catalog"
    }
  }

  /// #1914: the pure half of `refreshDownloadedModels`, extracted so the parsing
  /// is testable without a live server AND so there is exactly one place that
  /// turns `/api/tags` rows into catalog models.
  ///
  /// Facts come from `OllamaConnector.modelFacts(fromTagsRow:)` — the SAME
  /// decoder the per-attempt readiness path uses. This function must never read
  /// `remote_host` or `capabilities` itself: two readers of one wire format is
  /// how the Manage Models list and the runtime would come to disagree about the
  /// same model.
  nonisolated static func parseDownloadedModels(
    fromTagsModels models: [[String: Any]]
  ) -> [OllamaDownloadedModel] {
    disambiguateLocalCollisions(parseDownloadedModelsWithoutDisambiguation(fromTagsModels: models))
  }

  nonisolated private static func parseDownloadedModelsWithoutDisambiguation(
    fromTagsModels models: [[String: Any]]
  ) -> [OllamaDownloadedModel] {
    models.compactMap { model -> OllamaDownloadedModel? in
      guard let name = model["name"] as? String else { return nil }
      let canonical = canonicalModelName(name)

      // Parse details.parameter_size
      let details = model["details"] as? [String: Any]
      let parameterSize = details?["parameter_size"] as? String
      let parameterBillions = parameterSize.flatMap { parseParameterSize($0) }

      // Parse file size (Int64 for large models)
      let fileSizeBytes: Int64
      if let size = model["size"] as? Int64 {
        fileSizeBytes = size
      } else if let size = model["size"] as? Int {
        fileSizeBytes = Int64(size)
      } else {
        fileSizeBytes = 0
      }

      // Decoded from THIS row, never scanned across the payload. Read before the
      // display name because remoteness decides how that name is built.
      let facts = OllamaConnector.modelFacts(fromTagsRow: model)

      // #1956: the FOURTH construction site of this policy, and the one that
      // feeds the model-selection dropdown rather than Manage Models. Missing it
      // left the picker listing "Deepseek V4 Flash" three times and "Gpt Oss"
      // twice, which is what the founder screenshotted. See `hostedDisplayName`.
      let displayName =
        facts.isRemote ? hostedDisplayName(from: name) : inferDisplayName(from: name)

      return OllamaDownloadedModel(
        exactName: name,
        canonicalName: canonical,
        parameterSize: parameterSize,
        parameterBillions: parameterBillions,
        fileSizeBytes: fileSizeBytes,
        displayName: displayName,
        facts: facts
      )
    }
  }

  /// #1947: the LOCAL half of the same defect #1956 fixed for hosted rows.
  /// `inferDisplayName` drops everything after the colon, so two locally
  /// installed sizes of one family (`llama3.2:1b` and `llama3.2:3b`, say)
  /// both prettify to "Llama 3.2" — hosted rows dodge this by showing the
  /// exact name verbatim (`hostedDisplayName`), but doing the same for every
  /// local row would blank the prettification that already works for the
  /// overwhelmingly common non-colliding case. Instead, only names that
  /// ACTUALLY collide within this response get a disambiguating suffix.
  ///
  /// Two passes, because one suffix source is not always enough: pass 1
  /// appends the parsed parameter size (the same "(SIZE)" convention the
  /// curated static catalog already uses, e.g. `"Llama 3.2 (1B)"`), which
  /// resolves the common case (two different sizes of one family) without
  /// losing prettification. But two variants can share a size too (e.g. two
  /// quantizations of the same 3B checkpoint), so pass 2 re-checks for a
  /// SURVIVING collision after pass 1 and falls back to the exact tag for
  /// just those — `exactName` is unique by construction (Ollama will not
  /// list the same tag twice), so pass 2 cannot fail to resolve it.
  nonisolated private static func disambiguateLocalCollisions(
    _ models: [OllamaDownloadedModel]
  ) -> [OllamaDownloadedModel] {
    let localDisplayNames = models.filter { !$0.facts.isRemote }.map(\.displayName)
    guard localDisplayNames.count != Set(localDisplayNames).count else { return models }

    let sizeDisambiguated = renamingCollisions(in: models) { model in
      let suffix = model.parameterSize.map { " (\($0.uppercased()))" } ?? " (\(model.exactName))"
      return model.displayName + suffix
    }
    // Full replacement, not another suffix — appending the exact tag onto an
    // already-suffixed name (e.g. "Llama3 2 (3B)") would still not be unique
    // if two entries shared that same suffixed form, and reads worse besides.
    return renamingCollisions(in: sizeDisambiguated) { model in model.exactName }
  }

  /// Shared collision pass: among LOCAL rows only, find every `displayName`
  /// shared by more than one model and replace each with `rename(model)`.
  /// Idempotent when nothing collides (returns `models` unchanged).
  nonisolated private static func renamingCollisions(
    in models: [OllamaDownloadedModel],
    rename: (OllamaDownloadedModel) -> String
  ) -> [OllamaDownloadedModel] {
    var counts: [String: Int] = [:]
    for model in models where !model.facts.isRemote {
      counts[model.displayName, default: 0] += 1
    }
    let colliding = Set(counts.filter { $0.value > 1 }.keys)
    guard !colliding.isEmpty else { return models }

    return models.map { model in
      guard !model.facts.isRemote, colliding.contains(model.displayName) else { return model }
      return OllamaDownloadedModel(
        exactName: model.exactName,
        canonicalName: model.canonicalName,
        parameterSize: model.parameterSize,
        parameterBillions: model.parameterBillions,
        fileSizeBytes: model.fileSizeBytes,
        displayName: rename(model),
        facts: model.facts
      )
    }
  }

  /// Delete a model by name via DELETE /api/delete.
  ///
  /// #1305: `async` (was fire-and-forget inside its own Task) — returns after
  /// the server delete + `downloadedModels` mutation complete, so the delete
  /// button can sequence a discovery refresh on completion and the picker never
  /// disagrees with reality. Still never throws: errors remain swallow-and-log,
  /// so callers that don't sequence behave exactly as before. `transport` is a
  /// test seam (mirrors `OllamaConnector.networkExecutor`, #901) so the
  /// mutation-before-return contract is assertable without a live server.
  public func deleteModel(
    name: String,
    transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) async {
    guard let url = URL(string: "\(Self.baseURL)/api/delete") else { return }
    let body: [String: Any] = ["model": name]
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 30

    let send = transport ?? { try await URLSession.shared.data(for: $0) }
    do {
      let (_, response) = try await send(request)
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        downloadedModels.removeAll(where: { $0.exactName == name })
        // Reset warm-up if the deleted model was warmed or warming
        let canonical = Self.canonicalModelName(name)
        switch warmupState {
        case .warm(let m, _) where m == canonical,
          .warming(let m) where m == canonical:
          resetWarmup()
        default:
          break
        }
        // If current model was deleted, update setup state
        if downloadedModels.isEmpty {
          setupState = .runningNoModels
          UserDefaults.standard.set(false, forKey: Self.lastKnownStateKey)
        }
      }
    } catch {
      // Silently ignore delete errors -- user can try again
    }
  }

  // MARK: - Server Lifecycle

  /// Start the Ollama server, preferring the .app bundle, falling back to the CLI binary.
  public func startServer() {
    let appPath = "/Applications/Ollama.app"

    if FileManager.default.fileExists(atPath: appPath) {
      NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    } else if let binary = findOllamaBinary() {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: binary)
      process.arguments = ["serve"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { [weak self] _ in
        Task { @MainActor in
          self?.ollamaProcess = nil
        }
      }
      do {
        try process.run()
        ollamaProcess = process
      } catch {
        setupState = .error(
          "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
        )
        return
      }
    } else {
      setupState = .error(
        "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
      )
      return
    }

    // Poll until the server is up (up to 10 seconds)
    Task { [weak self] in
      let maxAttempts = 20
      for _ in 0..<maxAttempts {
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        guard let self else { return }

        if await self.isServerRunning() {
          if await self.hasAnyModels() {
            self.setupState = .ready
            UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
          } else {
            self.setupState = .runningNoModels
          }
          return
        }
      }

      self?.setupState = .error(
        "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
      )
    }
  }

  /// Terminate the managed Ollama server process on app quit.
  public func cleanup() {
    ollamaProcess?.terminate()
    ollamaProcess = nil
  }

  // MARK: - Model Pulling

  /// Pull a model by name, streaming progress updates.
  /// `hostedAdvertisedID` is non-nil only when a hosted Add started this, and it
  /// carries the id the ROW is keyed by. It decides two things: which row shows
  /// progress, and whether the status says Adding or Downloading.
  public func pullModel(_ modelName: String, hostedAdvertisedID: String? = nil) {
    // Cancel any in-flight pull and invalidate its epoch so stale writes no-op.
    pullTask?.cancel()
    pullTask = nil
    pullEpoch &+= 1
    let epoch = pullEpoch

    // Reset progress
    currentPullingModel = modelName
    // #1956: nil for a local download, so one cannot inherit a previous hosted
    // Add's id and light up the wrong row.
    hostedPullAdvertisedID = hostedAdvertisedID
    pullProgress = 0
    // #1956: a hosted registration moves 0 bytes and takes ~0.5 s. Calling it a
    // download here is the same false framing the Add label exists to remove.
    let opening = hostedAdvertisedID == nil ? "Starting download..." : "Adding..."
    pullStatusText = opening
    setupState = .pullingModel(progress: 0, status: opening)

    pullTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.performStreamingPull(modelName: modelName, epoch: epoch)
        guard self.pullEpoch == epoch else { return }
        // Pull stream succeeded. Clear pullTask so cancelPull() short-circuits
        // during the post-success refresh window (see cancelPull guard). Keep
        // setupState = .pullingModel(1.0, "success") from the last stream chunk
        // AND keep currentPullingModel = modelName so isPulling stays true and
        // the catalog UI stays disabled until the refresh confirms the new
        // model is visible. This prevents a duplicate pull for the same model
        // while /api/tags is in flight (up to 5s).
        self.pullTask = nil
        UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
        await self.refreshDownloadedModels()
        // Only commit to .ready if we are still the current pull. A newer
        // pullModel() during the refresh would have bumped pullEpoch and set
        // its own setupState; overwriting with .ready would clobber it.
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        self.setupState = .ready
      } catch is CancellationError {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        // Bug fix: don't force .runningNoModels if models exist
        if self.downloadedModels.isEmpty {
          self.setupState = .runningNoModels
        } else {
          self.setupState = .ready
        }
      } catch let urlError as URLError {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        self.setupState = .error(self.friendlyMessage(for: urlError))
      } catch {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        let message = error.localizedDescription.lowercased()
        let hosted = self.pullOperationIsHostedRegistration
        // A hosted registration writes a manifest and nothing else, so it cannot
        // plausibly exhaust the disk. Keeping the disk branch local-only means a
        // hosted failure never blames the user's free space for something that
        // needed none.
        if !hosted, message.contains("no space") || message.contains("errno 28") {
          self.setupState = .error(
            "Not enough disk space. The model needs about 2 GB free."
          )
        } else {
          self.setupState = .error(self.failedMessage(hosted: hosted))
        }
      }
    }
  }

  /// Cancel an in-progress model pull. Also clears stale row UI during the
  /// post-success refresh window (pullTask nil + currentPullingModel still
  /// set). Called from Cancel buttons AND from `onChange(llmProvider)` in
  /// `AIPolishSettingsView` when the user switches providers.
  public func cancelPull() {
    if pullTask != nil {
      // Active pull in flight: cancel, bump epoch, reset state.
      pullTask?.cancel()
      pullTask = nil
      pullEpoch &+= 1
      currentPullingModel = nil
      // Bug fix: don't force .runningNoModels if models exist
      if downloadedModels.isEmpty {
        setupState = .runningNoModels
      } else {
        setupState = .ready
      }
    } else if currentPullingModel != nil {
      // Post-success refresh window (pullTask was cleared at the commit point
      // but currentPullingModel is kept to hold the row UI). The download
      // already succeeded. Three things must happen:
      //   1. Bump pullEpoch so the pull Task's final guard (after the refresh
      //      await) bails and does NOT overwrite setupState. Otherwise a
      //      detectState() reassignment (e.g. .installedNotRunning after a
      //      provider switch/back) would be clobbered by a late .ready write.
      //   2. Clear currentPullingModel so callers like provider switch don't
      //      leave a stale "Downloading…" row visible if the user returns to
      //      Ollama settings before /api/tags finishes.
      //   3. Commit setupState = .ready here. The stream reported success, so
      //      Ollama has at least one model downloaded even if the /api/tags
      //      refresh hasn't updated downloadedModels yet. Without this, the
      //      Task's bail (step 1) would leave setupState stuck at
      //      .pullingModel(1.0, "success") until some later detectState()
      //      runs. Provider-switch path overwrites this moments later via
      //      detectState() on switch-back; same-pane Cancel just settles here.
      pullEpoch &+= 1
      currentPullingModel = nil
      setupState = .ready
    }
  }

  // MARK: - Model Warm-up

  /// Warm up a model by sending a minimal request to load it into GPU memory.
  /// Cancels any in-flight warm-up for a different model.
  public func warmUpModel(_ modelName: String) {
    let canonical = Self.canonicalModelName(modelName)

    // #1914: a remote model has nothing to warm. Warm-up exists to pull weights
    // into local memory; against a model on Ollama's servers it is a network
    // round trip that spends the USER'S cloud quota for no benefit, and it fires
    // on every settings change. No new warm-up task and no `/api/chat` request
    // start, and `warmupState` is never set to `.warming` for this model.
    //
    // Two things DO happen on this path, so the earlier "nothing observable"
    // wording was wrong: any warm-up belonging to the PREVIOUS model is retired
    // (below), and a debug-log task is spawned for the skip receipt.
    //
    // A model absent from `downloadedModels` also skips. We cannot tell whether
    // it is remote, and warm-up is best-effort by contract (it is not guaranteed
    // before any given dictation), so the cost of skipping is a marginally
    // slower first polish while the cost of guessing wrong is the user's quota.
    let matched = downloadedModels.first { $0.canonicalName == canonical }
    guard case .run(let facts) = Self.warmupPolicy(for: matched) else {
      // Retire any warm-up belonging to the PREVIOUS model before returning.
      // Skipping is about issuing no request for the NEW model; it must not
      // leave the old one running. Without this, switching from a warming local
      // model to a hosted one leaves that request in flight and it later
      // publishes `.warm` for a model the user is no longer using — a stale
      // checkmark, and a `warmupState` that disagrees with the armed model.
      // Ordering is load-bearing: the early return sits ABOVE the existing
      // cancellation below, so the cancellation has to be repeated here rather
      // than relied upon.
      cancelWarmupForModelSwitch()
      Task { [reason = Self.warmupSkipReason(for: matched)] in
        await AppLogger.shared.log(
          "warmup skipped (\(reason)) model=\(canonical)", level: .info, category: "LLM")
      }
      return
    }

    // Skip if already warm for this model and not expired
    if warmupState.isWarm(for: canonical) { return }

    // Skip if already warming this model
    if case .warming(let m) = warmupState, m == canonical { return }

    // Cancel any in-flight warm-up for a different model
    cancelWarmupForModelSwitch()

    warmupState = .warming(model: canonical)

    warmupTask = Task { [weak self] in
      defer { self?.warmupTask = nil }
      do {
        guard let url = URL(string: "\(Self.baseURL)/api/chat") else {
          self?.warmupState = .failed(model: canonical)
          return
        }

        let body = Self.makeWarmupRequestBody(model: modelName, thinks: facts.thinks)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.data(for: request)

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          self?.warmupState = .failed(model: canonical)
          return
        }

        let expirySeconds: TimeInterval = 55 * 60  // conservative vs 60m keep_alive
        self?.warmupState = .warm(
          model: canonical, expiresAt: Date().addingTimeInterval(expirySeconds))

        // Schedule state reset at expiry so the UI doesn't show a stale checkmark
        try? await Task.sleep(nanoseconds: UInt64(expirySeconds * 1_000_000_000))
        // Only reset if still warm for this model (not replaced by a newer warm-up)
        if case .warm(let m, _) = self?.warmupState, m == canonical {
          self?.warmupState = .idle
        }
      } catch is CancellationError {
        // Cancelled by a newer warm-up request; don't overwrite state
      } catch let error as URLError where error.code == .cancelled {
        // URLSession cancellation; same as above
      } catch {
        self?.warmupState = .failed(model: canonical)
      }
    }
  }

  /// Reset warm-up state (e.g., when provider changes away from Ollama).
  public func resetWarmup() {
    warmupTask?.cancel()
    warmupTask = nil
    warmupState = .idle
  }

  // MARK: - Streaming Pull (Private)

  private func performStreamingPull(modelName: String, epoch: UInt64) async throws {
    guard let url = URL(string: "\(Self.baseURL)/api/pull") else {
      throw LLMError.requestFailed("Invalid Ollama URL")
    }

    let body: [String: Any] = [
      "model": modelName,
      "stream": true,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 600  // 10 minutes

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw LLMError.requestFailed("Ollama pull request failed")
    }

    for try await line in bytes.lines {
      try Task.checkCancellation()
      // Drop stale writes from a task whose pull was superseded by a newer
      // pullModel()/cancelPull() call. Epoch mismatch → bail silently.
      guard pullEpoch == epoch else { return }

      guard let lineData = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else { continue }

      // Check for error response from Ollama
      if let errorMessage = json["error"] as? String {
        throw LLMError.requestFailed("Ollama pull error: \(errorMessage)")
      }

      let status = json["status"] as? String ?? ""

      // Calculate progress from total/completed bytes
      if let total = json["total"] as? Int64,
        let completed = json["completed"] as? Int64,
        total > 0
      {
        let progress = Double(completed) / Double(total)
        pullProgress = progress
        pullStatusText = status
        setupState = .pullingModel(progress: progress, status: status)
      } else {
        pullStatusText = status
        setupState = .pullingModel(progress: pullProgress, status: status)
      }

      if status == "success" {
        pullProgress = 1.0
        pullStatusText = status
        setupState = .pullingModel(progress: 1.0, status: status)
        break
      }
    }
  }

  // MARK: - Display Helpers

  /// Infer a display name from a raw Ollama model name.
  /// #1956: what a HOSTED row is called on screen. The name Ollama uses, verbatim.
  ///
  /// `inferDisplayName` drops everything after the colon, and for hosted rows
  /// that tag is the only thing distinguishing two models: of the 18 advertised
  /// on 2026-08-06, `gpt-oss:20b` and `gpt-oss:120b` both prettify to "Gpt Oss",
  /// as do `deepseek-v4-flash:0731` and `deepseek-v4-flash:preview`. Hosted rows
  /// also suppress the size and quality line (`showsSizeAndQuality`), so nothing
  /// else on the row breaks the tie — four of eighteen rows were two
  /// indistinguishable pairs, and the user could not tell which Add button
  /// selected which model.
  ///
  /// This applies to REGISTERED hosted rows too, not only advertised
  /// suggestions. That half is a #1914 defect this change inherits rather than
  /// introduces, and fixing only the new half would leave the same collision on
  /// the rows a user already has.
  ///
  /// It also overrides curated prettification: a hosted model can match a
  /// curated entry by name, and a curated display name is written for the local
  /// model, not for Ollama's hosted build of it.
  nonisolated static func hostedDisplayName(from name: String) -> String {
    name
  }

  nonisolated static func inferDisplayName(from name: String) -> String {
    let base = name.components(separatedBy: ":").first ?? name
    return base.replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  /// Infer quality tier from parameter count.
  nonisolated static func inferQualityTier(parameterBillions: Double?) -> OllamaQualityTier {
    guard let billions = parameterBillions else { return .medium }
    if billions >= 7.0 { return .best }
    if billions <= 2.0 { return .worst }
    return .medium
  }

  /// Format file size in bytes to human-readable string.
  nonisolated static func formatFileSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "Unknown" }
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 {
      return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576.0
    return String(format: "%.0f MB", mb)
  }

  // MARK: - Operation wording (#1956)

  /// What the in-flight operation is CALLED, everywhere outside the catalog row.
  ///
  /// Review r10: fixing the row and the opening status left the setup panel's
  /// step label, the disk-space branch and three URLError strings all still
  /// saying Download for an operation that moves 0 bytes. Rather than patch each
  /// one again, every one of them now reads this, so a new string cannot
  /// reintroduce the false framing by forgetting the distinction.
  ///
  /// Reads the live `hostedPullAdvertisedID`, which `pullModel` sets on its
  /// first lines from its own argument, so it is correct for the whole pull.
  package var pullOperationIsHostedRegistration: Bool { hostedPullAdvertisedID != nil }

  /// Step label for the setup panel while a pull runs.
  package var pullStepLabel: String {
    pullOperationIsHostedRegistration ? "Adding..." : "Downloading..."
  }

  private func failedMessage(hosted: Bool) -> String {
    hosted
      ? "Couldn't add the model. Check your internet connection and try again."
      : "Download failed. Check your internet connection and try again."
  }

  private func interruptedMessage(hosted: Bool) -> String {
    hosted
      ? "Adding the model was interrupted. Tap retry to try again."
      : "Download was interrupted. Tap retry to resume where you left off."
  }

  // MARK: - Error Mapping

  private func friendlyMessage(for urlError: URLError) -> String {
    let hosted = pullOperationIsHostedRegistration
    switch urlError.code {
    case .notConnectedToInternet:
      return failedMessage(hosted: hosted)
    case .cancelled, .networkConnectionLost, .timedOut:
      return interruptedMessage(hosted: hosted)
    default:
      return failedMessage(hosted: hosted)
    }
  }
}
