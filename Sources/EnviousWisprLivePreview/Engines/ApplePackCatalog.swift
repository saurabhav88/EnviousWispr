import EnviousWisprCore
import Foundation

#if canImport(Speech)
  import Speech
#endif

/// One Apple speech language, as the settings page shows it (#2080).
package struct LivePreviewPack: Sendable, Equatable, Identifiable {
  /// BCP-47 tag, e.g. `fr-FR`. Also the identity, because Apple's set is keyed by locale.
  package var id: String { tag }
  package let tag: String
  /// Endonym where the system knows one, e.g. `Français`, falling back to the tag.
  package let nativeName: String
  /// Name in the user's own language, e.g. `French`.
  package let localizedName: String
  package let isInstalled: Bool

  package init(tag: String, nativeName: String, localizedName: String, isInstalled: Bool) {
    self.tag = tag
    self.nativeName = nativeName
    self.localizedName = localizedName
    self.isInstalled = isInstalled
  }
}

/// Reports which Apple speech packs exist and installs one on request (#2080).
///
/// **Separate from `LivePreviewEngine` on purpose.** That protocol is about the ONE engine
/// serving the current recording; this is a many-language query performed with no recording in
/// flight. Different cardinality, different lifetime, so folding it into the engine would have
/// made every engine implement a catalogue it has no use for.
///
/// Lives in this module rather than the app shell because every Apple Speech call already does
/// (#2078), and moving asset enumeration up to AppKit would re-create precisely the
/// app-shell-owns-engine-internals problem that module boundary was drawn to remove.
///
/// **Never reserves in order to enumerate.** `AssetInventory.status(forModules:)` reads
/// `.supported` until a locale is reserved, so it is useless as a cheap on-disk check;
/// `installedLocales` answers the whole set in one call with no claim taken.
package actor ApplePackCatalog {

  /// Every Apple entry point this type uses, as narrow async closures.
  ///
  /// **The injection seam is load-bearing, not ceremony.** Apple's inventory API is entirely
  /// static, so without this there is no way to drive `install(tag:)` from a test at all — the
  /// plan's "test against a fake inventory" would have been unimplementable. Production wraps the
  /// real calls; tests supply deterministic closures. No Speech type crosses into AppKit either
  /// way, because these are plain strings.
  package struct Dependencies: Sendable {
    package var supportedTags: @Sendable () async -> [String]
    package var installedTags: @Sendable () async -> [String]
    package var install: @Sendable (String) async throws -> Void

    package init(
      supportedTags: @escaping @Sendable () async -> [String],
      installedTags: @escaping @Sendable () async -> [String],
      install: @escaping @Sendable (String) async throws -> Void
    ) {
      self.supportedTags = supportedTags
      self.installedTags = installedTags
      self.install = install
    }
  }

  private let deps: Dependencies

  /// The one owner of every locale claim. Injected so a test drives the real transaction rather
  /// than a stand-in for it — the reason #2145 was invisible to this suite for two releases.
  private let claims: LocaleClaims

  package init(dependencies: Dependencies, claims: LocaleClaims = .shared) {
    self.deps = dependencies
    self.claims = claims
  }

  /// Every supported language with its current installed state.
  ///
  /// Read live every time. macOS stages these as auto-assets and may PURGE one to reclaim disk,
  /// so a pack that was installed last month can be gone; caching installed-ness would show the
  /// user a state the system no longer agrees with. This list is the same asset set System
  /// Settings shows, and if the two disagree we are the ones who are wrong.
  package func snapshot() async -> [LivePreviewPack] {
    let installed = Set(await deps.installedTags())
    let supported = await deps.supportedTags()
    return
      supported
      .map { tag in
        LivePreviewPack(
          tag: tag,
          nativeName: Self.nativeName(for: tag),
          localizedName: Self.localizedName(for: tag),
          isInstalled: installed.contains(tag)
        )
      }
      .sorted {
        $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
      }
  }

  /// Install one pack, claiming the locale only for as long as the install needs it.
  ///
  /// **Claim, install, finish — on EVERY exit path**, including the throwing one and cancellation.
  /// Releasing does not uninstall (measured: 8 installed before and after), so holding the claim
  /// afterwards would buy nothing while consuming one of five MACHINE-WIDE slots. That is why the
  /// cap never reaches the UI — it is not a limit on how many languages a user may keep — but it is
  /// also why a table filled by OTHER processes can still make this fail at capacity, which the
  /// model surfaces rather than swallowing.
  ///
  /// Returns a fresh snapshot rather than reporting success, so the caller renders what the
  /// system now says instead of what we assume it should say.
  ///
  /// **The claim is registered as IN USE for the whole transfer, not just while it is taken.**
  /// Claiming and then losing it before `downloadAndInstall` consumes it would fail the download
  /// for no visible reason, and a recording starting mid-transfer is exactly the thing that would
  /// take it — Apple's five slots are shared machine-wide.
  ///
  /// **Both halves go through `LocaleClaims` and nothing else.** This type used to carry its own
  /// reserve and release seams; #2145 found them making decisions the recognizer's copy made
  /// differently, on a claim neither of them owned. One transaction, one owner.
  package func install(tag: String) async throws -> [LivePreviewPack] {
    let locale = Locale(identifier: tag)
    try await claims.claim(locale, purpose: "download")
    do {
      try await deps.install(tag)
    } catch {
      await claims.finish(locale)
      throw error
    }
    await claims.finish(locale)
    return await snapshot()
  }

  static func nativeName(for tag: String) -> String {
    let locale = Locale(identifier: tag)
    return locale.localizedString(forIdentifier: tag)?.capitalized(with: locale)
      ?? locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? tag)
      ?? tag
  }

  /// Package-visible so the settings page names the active language through the SAME helper the
  /// rows use. Formatting it twice invites the header and the list to disagree about one language.
  package static func localizedName(for tag: String) -> String {
    Locale.current.localizedString(forIdentifier: tag)
      ?? Locale.current.localizedString(forLanguageCode: tag)
      ?? tag
  }
}

#if canImport(Speech)
  @available(macOS 26.0, *)
  extension ApplePackCatalog.Dependencies {
    /// The real Apple asset catalogue. Enumeration and installation only — claiming the locale is
    /// `LocaleClaims`' job, reached from `install(tag:)`, so this seam carries no claim policy at
    /// all and cannot drift from the recognizer's copy the way the deleted one did.
    package static var live: ApplePackCatalog.Dependencies {
      .init(
        supportedTags: {
          await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        },
        installedTags: {
          await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        },
        install: { tag in
          let locale = Locale(identifier: tag)
          let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
          guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
          else { return }  // Already present; Apple returns nil when there is nothing to fetch.
          try await request.downloadAndInstall()
        }
      )
    }
  }
#endif
