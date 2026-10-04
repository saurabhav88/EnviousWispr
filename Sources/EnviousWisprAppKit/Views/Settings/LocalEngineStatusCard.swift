import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import SwiftUI

/// Which bundled local engine a status card is about (#2649).
///
/// Everything here is a thing the CARD says that differs between engines. It is
/// a value rather than a switch on the provider so the card cannot silently
/// inherit the other engine's identity: adding a third engine means supplying
/// one of these, not remembering to extend a `case`.
struct LocalEngineDescriptor: Equatable {
  /// The display name. Licence-bound for S1-mini, so it reads the one owner
  /// rather than restating the string.
  let name: String
  /// What the user is told they are about to download.
  let downloadSize: String
  /// Free space the install needs. Scales with the download, so it cannot be a
  /// shared literal: EG-1's 6 GB would be an absurd demand for a 484 MB model
  /// and would refuse installs that fit perfectly well.
  let installHeadroom: String
  /// Whether to warn on an 8 GB Mac. EG-1 is 2.9 GB resident and genuinely
  /// strains one; S1-mini is a sixth of that and does not, so the warning would
  /// be noise that teaches users to ignore the real one.
  let showsLowMemoryNote: Bool
  /// The engine's context window, bound to its manifest by
  /// `LocalEngineDescriptorTests`. Here so the dictation-length promise in the
  /// explainer is DERIVED from the guard that enforces it, never typed.
  let contextTokens: Int

  /// Characters of dictated English per minute, for turning the guard's
  /// character ceiling into the "about N minutes" a user can act on. 150 words
  /// a minute at 5.5 characters a word plus the space. An estimate, stated as
  /// "about", and deliberately on the generous side of typical speech so the
  /// promise rounds down rather than up.
  static let charactersPerDictatedMinute = 850

  /// The longest dictation the shipped path polishes whole, to the nearest
  /// minute. Reads the pipeline's own ceiling so a guard change moves the
  /// copy with it (#2649 cloud review P2).
  var dictationMinutes: Int {
    let ceiling = LLMPolishStep.localPolishTranscriptCeiling(contextTokens: contextTokens)
    return Int((Double(ceiling) / Double(Self.charactersPerDictatedMinute)).rounded())
  }

  static let egOne = LocalEngineDescriptor(
    name: LLMProvider.egOne.displayName, downloadSize: "2.9 GB", installHeadroom: "6 GB",
    showsLowMemoryNote: true, contextTokens: 16384)

  static let s1Mini = LocalEngineDescriptor(
    // 484,219,808 bytes. Stated DECIMAL, because that is what EG-1's "2.9 GB"
    // is and what Finder shows the user when they go looking for the space.
    // The publisher's card says "462 MiB" for the same file; quoting that here
    // would have the app disagree with the user's own disk.
    name: LLMProvider.s1Mini.displayName, downloadSize: "484 MB", installHeadroom: "1 GB",
    showsLowMemoryNote: false, contextTokens: 8192)
}

/// The actionable status/download/remove card for a bundled local engine.
///
/// **Extracted rather than copied (#2649).** S1-mini shipped with no card at
/// all: its setup section rendered empty and there was no way to download it,
/// which the founder found in UAT on 2026-09-04. Writing a second card would
/// have duplicated 158 lines of install-state handling, and the two would have
/// drifted at the first state either engine handled alone.
///
/// This is a semantic no-op port for EG-1. Every comment travelled with the
/// code it explains, and the only edits turn a hard-coded engine into
/// `LocalEngineDescriptor`.
struct LocalEngineStatusCard<Middle: View>: View {
  let runtime: EGOneRuntime
  let engine: LocalEngineDescriptor
  /// Whether this card may START the engine's server.
  ///
  /// #2772: there is ONE local inference slot. On the Transcribe a File page this card shows
  /// the IMPORT's engine, and its refresh button would claim that slot outside any run,
  /// evicting dictation's runtime and leaving it evicted. What it costs to switch off is
  /// pre-run live diagnosis; installation state, the download and Remove Model are
  /// unaffected, and the run itself starts and awaits the server through `prepareLocalPolish`.
  /// Found by the cloud review of PR #2786.
  var allowsRuntimeActivation: Bool = true
  /// Removing a model is not just a delete: the caller owns the provider
  /// selection and must move the user off the engine being removed. Passed in
  /// rather than done here, because this view has no business writing settings.
  let onRemove: () -> Void
  /// Rows the host places between the install row and the remove row (S1-mini's
  /// writing-style dials, #3385).
  @ViewBuilder let middle: () -> Middle

  private var isLowMemoryMac: Bool {
    ProcessInfo.processInfo.physicalMemory <= (8 << 30)
  }

  /// The rows of a bundled local engine in the AI Polish card (#3385, founder's Claude
  /// Design 2026-10-03): the install state row with its action, the host's middle rows, the
  /// remove row, and the 8 GB heads-up. Every state keeps a row, including the ones the design
  /// did not draw (update paused, failed, upgrades). Copy rules: no em or en dashes.
  @ViewBuilder
  var body: some View {
    // One presentation value for the whole row (#2109). Hoisted above the
    // switch deliberately: when only some branches consumed it, the remaining
    // mappings were still ASSERTED by the agreement tests while the real row
    // rendered something else, so the tests described a value the UI did not
    // use. Every branch now reads from the tested value.
    let presentation = EGOneRowPresentation.forState(runtime.installState, engine: engine.name)
    switch runtime.installState {
    case .notInstalled:
      // NOT "one-time" (#2096): a new model revision downloads again, on its own, when an app
      // update ships one. Promising a single download was true only while EG-1 could never be
      // replaced, and that stopped being true the moment the automatic upgrade path existed.
      PolishRow(
        icon: "arrow.down.circle",
        title: presentation.primaryAction ?? engine.name,
        subtitle: String(
          localized:
            "\(engine.downloadSize) download · needs \(engine.installHeadroom) free · stays on this Mac",
          comment:
            "AI Polish, local model: what downloading the model takes. The first %@ is its size, the second the free space it needs."
        )
      ) {
        SettingsActionButton(
          title: LocalizedStringResource(
            "Download", comment: "AI Polish, local model: starts the model download."),
          isEnabled: true, emphasis: .filled, size: .medium
        ) {
          runtime.startDownload()
        }
      }
    case .downloading(let fraction, let upgrade):
      // An UPGRADE says so and names the version arriving; a first install keeps the
      // original sentence (founder, 2026-08-17, from Live UAT). The version comes from
      // `presentation.versionLabel`, composed from the manifest, never a literal here.
      PolishRow(
        icon: "arrow.down.circle",
        title: EGOneRowPresentation.downloadingLine(
          engine: engine.name, upgrade: upgrade, downloadSize: engine.downloadSize),
        subtitle: String(
          localized:
            "You can keep dictating while \(engine.name) downloads.",
          comment: "AI Polish, local model: while the model downloads. %@ is the model name."),
        detail: {
          PolishProgressBar(fraction: fraction)
            .padding(.top, 6)
        },
        trailing: {
          HStack(spacing: 10) {
            Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
              .font(.stHelper)
              .monospacedDigit()
              .foregroundStyle(Color.stTextSecondary)
            if let action = presentation.primaryAction {
              PolishTextAction(title: action) { runtime.cancelDownload() }
            }
          }
        })
    // #2109: an interrupted FIRST install. Ported from the founder ruling of 2026-07-17
    // already shipped for Parakeet and WhisperKit: paused, Resume anytime. No percentage:
    // the paused state carries no progress, so any number would be invented.
    case .paused:
      PolishRow(icon: "pause.circle", title: presentation.message) {
        if let action = presentation.primaryAction {
          SettingsActionButton(
            title: LocalizedStringResource(stringLiteral: action), isEnabled: true,
            emphasis: .filled, size: .medium
          ) {
            runtime.startDownload()
          }
        }
      }
    // A working older EG-1 is installed and the pinned one is not, so AI cleanup is off until
    // this finishes. The old revision is deliberately NOT named: this app bundle does not
    // contain its manifest, so any name for it would be invented.
    case .updatePaused:
      PolishRow(
        icon: "exclamationmark.triangle", iconTint: .stWarning, title: presentation.message,
        adaptsTrailing: true
      ) {
        if let action = presentation.primaryAction {
          SettingsActionButton(
            title: LocalizedStringResource(stringLiteral: action), isEnabled: true,
            emphasis: .filled, size: .medium
          ) {
            runtime.startDownload()
          }
        }
      }
    case .verifying:
      PolishRow(
        icon: "checkmark.shield", showsSpinner: true,
        title: String(
          localized: "Verifying download integrity",
          comment: "AI Polish, local model: checking the downloaded file."),
        subtitle: String(
          localized: "Checking the file against its manifest before it is used.",
          comment: "AI Polish, local model: what verifying does.")
      ) {
        EmptyView()
      }
    case .failed(let failure):
      PolishRow(
        icon: "xmark.octagon", iconTint: .stError, title: failureCopy(failure),
        adaptsTrailing: true
      ) {
        if let action = presentation.primaryAction {
          SettingsActionButton(
            title: LocalizedStringResource(stringLiteral: action), isEnabled: true,
            emphasis: .filled, size: .medium
          ) {
            runtime.startDownload()
          }
        }
      }
    case .installed:
      // #2109: the version, as a quiet secondary label, composed by `EGOneRowPresentation`
      // so the value the tests assert is the value that renders. nil and blank both render
      // NOTHING: an absent label is honest and "EG-1 V" with an empty tail reads as a bug.
      // The size is the engine's download size, which is what it is: no disk reading is
      // claimed. The row is titled by the model rather than "Installed": the provider card
      // above already says Installed, and saying it twice was noise (founder review,
      // 2026-10-03).
      PolishRow(
        icon: "checkmark.circle",
        title: presentation.versionLabel ?? engine.name,
        subtitle: [engine.downloadSize, installedHealthLine]
          .compactMap { $0 }.joined(separator: " · ")
      ) {
        if allowsRuntimeActivation {
          HStack(spacing: 10) {
            healthLabel
            PolishIconButton(
              systemName: "arrow.clockwise",
              help: String(
                localized: "Test that \(engine.name) is live",
                comment: "AI Polish, local model: re-checks that the model answers. %@ is its name.")
            ) {
              runtime.activateAndProbe()
            }
          }
        } else {
          // Installed and ready to be used BY A RUN. Deliberately not a health reading: this
          // card is not allowed to start the server, so it cannot know, and a stale green
          // light is worse than none.
          Text("Ready for import")
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
      }
    }
    middle()
    if presentation.showsRemove { removeRow }
    if engine.showsLowMemoryNote, isLowMemoryMac {
      PolishRowDivider()
      PolishRow(
        icon: "exclamationmark.triangle", iconTint: .stWarning,
        title: String(
          localized:
            "This Mac has 8 GB of memory. \(engine.name) may run slower here. Dictation always works, even when polish is unavailable.",
          comment:
            "AI Polish, local model card: low-memory note. %@ is the model name, such as EG-1.")
      ) {
        EmptyView()
      }
    }
  }

  /// The health reason under "Installed" when the engine is not green; nothing extra when it
  /// is (the design's "Answered a test request in 0.4 s" is not shipped: the probe does not
  /// publish its timing).
  private var installedHealthLine: String? {
    allowsRuntimeActivation ? healthDetail : nil
  }

  @ViewBuilder
  private var removeRow: some View {
    PolishRowDivider()
    HStack(spacing: 12) {
      Text(
        String(
          localized:
            "Removing frees \(engine.downloadSize). Polish switches to Apple Intelligence.",
          comment:
            "AI Polish, local model: what Remove Model does. %@ is the model's size, such as 2.9 GB.")
      )
      .font(.stRowHelper)
      .foregroundStyle(Color.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      PolishTextAction(
        title: String(
          localized: "Remove Model", comment: "AI Polish, local model: deletes the model.")
      ) {
        onRemove()
      }
    }
    .padding(.leading, PolishSectionLayout.textIndent)
    .padding(.trailing, PolishSectionLayout.rowPaddingH)
    .padding(.vertical, PolishSectionLayout.rowPaddingV)
  }

  @ViewBuilder
  private var healthLabel: some View {
    switch runtime.health {
    case .green:
      ProviderStatusChip(status: ProviderStatus(label: String(localized: "Live"), tone: .ready))
    case .yellow:
      ProviderStatusChip(
        status: ProviderStatus(label: String(localized: "Attention"), tone: .needsSetup))
    case .red:
      ProviderStatusChip(
        status: ProviderStatus(label: String(localized: "Not working"), tone: .error))
    }
  }

  /// Plain-language reason line under the health pill (nil for green).
  private var healthDetail: String? { LocalEngineHealthCopy.detail(for: runtime.health) }

  private func failureCopy(_ failure: EGOneDownloadFailure) -> String {
    switch failure {
    case .network:
      return String(
        localized:
          "Could not download the model. Check your connection. On a managed network, ask IT whether models.enviouswispr.com is allowed.",
        comment:
          "AI Polish, local model card: why the model download failed. Keep models.enviouswispr.com exactly; it is a web address."
      )
    case .checksum:
      return String(
        localized: "The download did not verify correctly and was discarded. Please try again.",
        comment: "AI Polish, local model card: why the model download failed.")
    case .disk:
      return String(
        localized:
          "Not enough free disk space. The download needs about \(engine.installHeadroom) free during install.",
        comment:
          "AI Polish, local model card: why the model download failed. %@ is an amount of disk space, such as 6 GB."
      )
    case .cancelled:
      return String(
        localized: "Download canceled. Your progress is saved.",
        comment: "AI Polish, local model card: why the model download failed.")
    case .rangeUnsupported, .http:
      return String(
        localized: "The download server had a problem. Please try again in a few minutes.",
        comment: "AI Polish, local model card: why the model download failed.")
    case .stubURL:
      return String(
        localized: "This build has no download source configured.",
        comment: "AI Polish, local model card: why the model download failed.")
    }
  }
}

/// The plain-language reason under a local engine's health, outside the generic card so a
/// test can call it without naming the card's content type.
enum LocalEngineHealthCopy {
  /// Pure, and `static` so a test can enumerate every reason the app
  /// PRODUCES and require copy for each. As an instance property reading
  /// `runtime` this was unreachable, which is how two produced reasons
  /// reached the alarming default branch unnoticed.
  static func detail(for health: EGOneHealth) -> String? {
    switch health {
    case .green:
      return nil
    case .yellow(let reason):
      switch reason {
      case "starting":
        return String(
          localized: "The model is starting up. This takes a few seconds.",
          comment: "AI Polish, local model card: the reason under the health status.")
      case "paused_for_memory":
        return String(
          localized: "Paused to free memory for other apps. Use the refresh button to restart it.",
          comment: "AI Polish, local model card: the reason under the health status.")
      case "probe_slow":
        return String(
          localized: "Working, but responding slowly right now.",
          comment: "AI Polish, local model card: the reason under the health status.")
      case "probe_output_unexpected":
        return String(
          localized: "The model responded, but not as expected. Try re-downloading it.",
          comment: "AI Polish, local model card: the reason under the health status.")
      case "downloading", "verifying": return nil
      // Installed, server not up. Ordinary and momentary — it is what every
      // switch to this engine looks like for a second. The default below
      // rendered "Something needs attention" for it, which reads as a fault,
      // and is what the founder saw after switching back to EG-1 (2026-09-04).
      case "not_started":
        return String(
          localized: "Starting the model. This takes a few seconds.",
          comment: "AI Polish, local model card: the reason under the health status.")
      // The user paused their own download; their progress is kept.
      case "download_paused":
        return String(
          localized: "Download paused. Resume anytime.",
          comment: "AI Polish, local model card: the reason under the health status.")
      // Reached only by a reason invented at runtime. Every reason the app
      // actually emits is named above, and `LocalEngineHealthCopyTests`
      // enumerates them from the producing code so a new one fails loudly
      // instead of landing here.
      default:
        return String(
          localized: "Something needs attention. Try the refresh button.",
          comment: "AI Polish, local model card: the reason under the health status.")
      }
    case .red(let reason):
      switch reason {
      case "download_required":
        return String(
          localized: "Download the model to get started.",
          comment: "AI Polish, local model card: the reason under the health status.")
      // The emitted reason is `update_required`. This branch used to read
      // `app_update_required`, which nothing produces — so it was dead, and the
      // real reason fell through to the generic line below. Found by the
      // enumeration test, not by reading.
      case "update_required":
        return String(
          localized: "This model needs a newer version of EnviousWispr.",
          comment: "AI Polish, local model card: the reason under the health status.")
      case "crashed_twice":
        return String(
          localized: "The model stopped twice in a row. Use the refresh button to try again.",
          comment: "AI Polish, local model card: the reason under the health status.")
      // The server is not up and nothing is starting it. Distinct from
      // `not_started`, which is yellow because something IS starting it.
      case "not_running":
        return String(
          localized: "Not running. Use the refresh button to start it.",
          comment: "AI Polish, local model card: the reason under the health status.")
      // It answered the socket but failed a real inference probe, so a polish
      // request would fail too. Naming that beats the generic line.
      case "probe_failed":
        return String(
          localized:
            "The model did not answer a test request. Use the refresh button to try again.",
          comment: "AI Polish, local model card: the reason under the health status.")
      default:
        return String(
          localized: "Not running. Use the refresh button to try again.",
          comment: "AI Polish, local model card: the reason under the health status.")
      }
    }
  }
}
