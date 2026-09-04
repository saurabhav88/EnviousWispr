import EnviousWisprCore
import EnviousWisprLLM
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

  static let egOne = LocalEngineDescriptor(
    name: "EG-1", downloadSize: "2.9 GB", installHeadroom: "6 GB", showsLowMemoryNote: true)

  static let s1Mini = LocalEngineDescriptor(
    // 484,219,808 bytes. Stated DECIMAL, because that is what EG-1's "2.9 GB"
    // is and what Finder shows the user when they go looking for the space.
    // The publisher's card says "462 MiB" for the same file; quoting that here
    // would have the app disagree with the user's own disk.
    name: LLMProvider.s1Mini.displayName, downloadSize: "484 MB", installHeadroom: "1 GB",
    showsLowMemoryNote: false)
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
struct LocalEngineStatusCard: View {
  let runtime: EGOneRuntime
  let engine: LocalEngineDescriptor
  /// Removing a model is not just a delete: the caller owns the provider
  /// selection and must move the user off the engine being removed. Passed in
  /// rather than done here, because this view has no business writing settings.
  let onRemove: () -> Void

  private var isLowMemoryMac: Bool {
    ProcessInfo.processInfo.physicalMemory <= (8 << 30)
  }

  /// Whole-section content for the EG-1 provider: explainer with the
  /// founder-approved benchmark claim (real numbers, no competitor names),
  /// download flow with size disclosure, the green/yellow/red activation
  /// pill (a REAL inference probe, never process-exists), Remove Model, and
  /// the 8 GB heads-up. Copy rules: no em or en dashes in these strings.
  @ViewBuilder
  var body: some View {
    // The pitch (tuned, on-device, benchmark) lives in the "Why use EG-1" card
    // now (#1286); this card is just the actionable status/download/remove.
    if engine.showsLowMemoryNote, isLowMemoryMac {
      Label(
        "This Mac has 8 GB of memory. \(engine.name) may run slower here. "
          + "Dictation always works, even when polish is unavailable.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.stHelper)
      .foregroundStyle(.stWarning)
      .fixedSize(horizontal: false, vertical: true)
    }

    // One presentation value for the whole row (#2109). Hoisted above the
    // switch deliberately: when only some branches consumed it, the remaining
    // mappings were still ASSERTED by the agreement tests while the real row
    // rendered something else, so the tests described a value the UI did not
    // use. Every branch now reads from the tested value.
    let presentation = EGOneRowPresentation.forState(runtime.installState, engine: engine.name)
    switch runtime.installState {
    case .notInstalled:
      HStack {
        // NOT "one-time" (#2096): a new model revision downloads again, on its own, when an app
        // update ships one. Promising a single download was true only while EG-1 could never be
        // replaced, and that stopped being true the moment the automatic upgrade path existed.
        Text("Download size: \(engine.downloadSize)")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
        Spacer()
        if let action = presentation.primaryAction {
          Button(action) { runtime.startDownload() }
        }
      }
    case .downloading(let fraction, _):
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: max(0, min(1, fraction))) {
          // An UPGRADE says so and names the version arriving; a first install
          // keeps the original sentence (founder, 2026-08-17, from Live UAT).
          // Both used to read "Downloading \(engine.name) (\(engine.downloadSize))", so a user who
          // already had EG-1 could not tell a 2.9 GB upgrade from a 2.9 GB
          // first install and was never told which version was coming.
          //
          // The version comes from `presentation.versionLabel`, composed from
          // the manifest — never a literal here. A revision ships as a manifest
          // edit with no Swift change, so a hard-coded number would keep naming
          // the previous model after the real one moved on.
          Text(
            presentation.versionLabel.map { "Upgrading to \($0) (\(engine.downloadSize))" }
              ?? "Downloading \(engine.name) (\(engine.downloadSize))"
          )
          .font(.stHelper)
        }
        if let action = presentation.primaryAction {
          Button(action) { runtime.cancelDownload() }
            .buttonStyle(.borderless)
            .font(.stHelper)
        }
      }
    // #2109: an interrupted FIRST install. Ported from the founder ruling of
    // 2026-07-17 already shipped for Parakeet and WhisperKit — paused, Resume
    // anytime. This used to render through the failure branch with a red row
    // and a Try Again button, for something the user deliberately chose.
    case .paused:
      VStack(alignment: .leading, spacing: 4) {
        Text(presentation.message)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
        if let action = presentation.primaryAction {
          Button(action) { runtime.startDownload() }
        }
      }
    // A working older EG-1 is installed and the pinned one is not, so AI
    // cleanup is off until this finishes. The old revision is deliberately
    // NOT named: this app bundle does not contain its manifest, so any name
    // for it would be invented.
    case .updatePaused:
      VStack(alignment: .leading, spacing: 4) {
        Text(presentation.message)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          if let action = presentation.primaryAction {
            Button(action) { runtime.startDownload() }
          }
          Spacer()
          if presentation.showsRemove {
            Button("Remove Model") { onRemove() }
            .buttonStyle(.borderless)
            .font(.stHelper)
          }
        }
      }
    case .verifying:
      HStack {
        ProgressView().controlSize(.small)
        Text("Verifying download integrity")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }
    case .failed(let failure):
      Text(failureCopy(failure))
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
      if let action = presentation.primaryAction {
        Button(action) { runtime.startDownload() }
      }
    case .installed:
      HStack {
        Text("Status:")
        // #2109: the version, as a quiet secondary label. Deliberately not
        // prominent — Priya and Dr. Vasquez want to know which model they are
        // on, Frank and Meera must be able to ignore it entirely, and nobody
        // is being asked to make a decision here.
        //
        // Composed by `EGOneRowPresentation`, not here, so the same value the
        // tests assert is the value that renders. nil and blank both render
        // NOTHING: an absent label is honest, "Unknown version" is a string
        // Frank should never see, and `EG-1 V` with an empty tail reads as a
        // rendering bug.
        if let versionLabel = presentation.versionLabel {
          Text(versionLabel)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
        Spacer()
        healthLabel
        Button {
          runtime.activateAndProbe()
        } label: {
          Image(systemName: "arrow.clockwise")
            .settingsHoverQuiet()
        }
        .buttonStyle(.borderless)
        .help("Test that \(engine.name) is live")
        .accessibilityLabel("Test that \(engine.name) is live")
      }
      if let reason = healthDetail {
        Text(reason)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if presentation.showsRemove {
        Button("Remove Model") { onRemove() }
        .buttonStyle(.borderless)
        .font(.stHelper)
      }
    }
  }

  @ViewBuilder
  private var healthLabel: some View {
    switch runtime.health {
    case .green:
      Label("Live", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.stSuccess)
    case .yellow:
      Label("Attention", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.stWarning)
    case .red:
      Label("Not working", systemImage: "xmark.circle.fill")
        .foregroundStyle(.stError)
    }
  }

  /// Plain-language reason line under the health pill (nil for green).
  private var healthDetail: String? { Self.detail(for: runtime.health) }

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
      case "starting": return "The model is starting up. This takes a few seconds."
      case "paused_for_memory":
        return "Paused to free memory for other apps. Use the refresh button to restart it."
      case "probe_slow": return "Working, but responding slowly right now."
      case "probe_output_unexpected":
        return "The model responded, but not as expected. Try re-downloading it."
      case "downloading", "verifying": return nil
      // Installed, server not up. Ordinary and momentary — it is what every
      // switch to this engine looks like for a second. The default below
      // rendered "Something needs attention" for it, which reads as a fault,
      // and is what the founder saw after switching back to EG-1 (2026-09-04).
      case "not_started": return "Starting the model. This takes a few seconds."
      // The user paused their own download; their progress is kept.
      case "download_paused": return "Download paused. Resume anytime."
      // Reached only by a reason invented at runtime. Every reason the app
      // actually emits is named above, and `LocalEngineHealthCopyTests`
      // enumerates them from the producing code so a new one fails loudly
      // instead of landing here.
      default: return "Something needs attention. Try the refresh button."
      }
    case .red(let reason):
      switch reason {
      case "download_required": return "Download the model to get started."
      // The emitted reason is `update_required`. This branch used to read
      // `app_update_required`, which nothing produces — so it was dead, and the
      // real reason fell through to the generic line below. Found by the
      // enumeration test, not by reading.
      case "update_required":
        return "This model needs a newer version of EnviousWispr."
      case "crashed_twice":
        return "The model stopped twice in a row. Use the refresh button to try again."
      // The server is not up and nothing is starting it. Distinct from
      // `not_started`, which is yellow because something IS starting it.
      case "not_running": return "Not running. Use the refresh button to start it."
      // It answered the socket but failed a real inference probe, so a polish
      // request would fail too. Naming that beats the generic line.
      case "probe_failed":
        return "The model did not answer a test request. Use the refresh button to try again."
      default: return "Not running. Use the refresh button to try again."
      }
    }
  }

  private func failureCopy(_ failure: EGOneDownloadFailure) -> String {
    switch failure {
    case .network:
      return "Could not download the model from models.enviouslabs.co. "
        + "Check your connection. On a managed network, ask IT to allow this domain."
    case .checksum:
      return "The download did not verify correctly and was discarded. Please try again."
    case .disk:
      return "Not enough free disk space. The download needs about \(engine.installHeadroom) free during install."
    case .cancelled:
      return "Download canceled. Your progress is saved."
    case .rangeUnsupported, .http:
      return "The download server had a problem. Please try again in a few minutes."
    case .stubURL:
      return "This build has no download source configured."
    }
  }
}
