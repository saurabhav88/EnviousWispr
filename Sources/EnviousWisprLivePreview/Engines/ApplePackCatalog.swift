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
    package var reserve: @Sendable (String) async throws -> Void
    package var release: @Sendable (String) async -> Void
    package var install: @Sendable (String) async throws -> Void

    package init(
      supportedTags: @escaping @Sendable () async -> [String],
      installedTags: @escaping @Sendable () async -> [String],
      reserve: @escaping @Sendable (String) async throws -> Void,
      release: @escaping @Sendable (String) async -> Void,
      install: @escaping @Sendable (String) async throws -> Void
    ) {
      self.supportedTags = supportedTags
      self.installedTags = installedTags
      self.reserve = reserve
      self.release = release
      self.install = install
    }
  }

  private let deps: Dependencies

  package init(dependencies: Dependencies) {
    self.deps = dependencies
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
  /// **Reserve, install, release — and release on EVERY exit path**, including the throwing one
  /// and cancellation. Releasing does not uninstall (measured: 8 installed before and after), and
  /// reservations do not survive the process, so holding one afterwards would buy nothing while
  /// consuming one of the five slots. That is also why the five-slot cap never reaches the UI:
  /// it is not a limit on how many languages a user may keep.
  ///
  /// Returns a fresh snapshot rather than reporting success, so the caller renders what the
  /// system now says instead of what we assume it should say.
  /// **The claim is registered as IN USE for the whole transfer, not just while it is taken.**
  /// Reserving and then losing the claim before `downloadAndInstall` consumes it would fail the
  /// download for no visible reason, and a recording starting mid-transfer is exactly the thing
  /// that would take it — Apple's five slots are shared and it evicts to make room.
  package func install(tag: String) async throws -> [LivePreviewPack] {
    // `reserve` also REGISTERS this transfer's use, atomically, so nothing can evict the claim
    // between taking it and downloading into it.
    try await deps.reserve(tag)
    do {
      try await deps.install(tag)
    } catch {
      await releaseIfUnused(tag)
      throw error
    }
    await releaseIfUnused(tag)
    return await snapshot()
  }

  /// Hand back this transfer's claim, releasing the SYSTEM reservation only if nobody else is
  /// still using the locale.
  ///
  /// **An unconditional release here would break an in-flight recording.** A preview can be
  /// transcribing the same language this install just reused — reachable whenever the row the
  /// user pressed was stale — and dropping the shared claim takes the asset out from under an
  /// analyzer that is still reading it.
  private func releaseIfUnused(_ tag: String) async {
    // **Under the transaction lock, because checking and releasing must be ONE step.** Otherwise
    // a recording starting right now slips between them: this reads zero uses, the recording
    // reserves and registers, and then this releases the system claim out from under it. The
    // recognizer's end-of-session path already held the lock across the same pair; this one did
    // not, and that asymmetry was the bug.
    await LocaleReservations.shared.acquire()
    let remaining = await LocaleReservations.shared.endUse(tag)
    if remaining == 0 {
      await deps.release(tag)
    }
    await LocaleReservations.shared.release()
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
    /// The real Apple inventory. The reserve step routes to `ApplePreviewRecognizer.acquireLocaleForSession`
    /// deliberately: `reserve` returns FALSE when the locale is ALREADY reserved, so the return
    /// value is not a success flag and the authority has to be asked afterwards.
    package static var live: ApplePackCatalog.Dependencies {
      .init(
        supportedTags: {
          await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        },
        installedTags: {
          await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        },
        // ONE owner for the reservation dance, shared with the recognizer.
        //
        // This used to be a second, weaker copy that omitted the eviction step, and review
        // caught what that costs: after previewing five different languages the recognizer
        // holds all five slots, so the sixth Download would refuse and the button would
        // simply stop working for a multilingual user. Porting a guard means porting it
        // WHOLE — the partial copy is the defect.
        reserve: { tag in
          try await ApplePreviewRecognizer.acquireLocaleForSession(Locale(identifier: tag))
        },
        release: { tag in
          await AssetInventory.release(reservedLocale: Locale(identifier: tag))
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
