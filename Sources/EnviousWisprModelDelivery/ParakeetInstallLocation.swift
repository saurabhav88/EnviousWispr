import Foundation

/// Where EnviousWispr keeps its Parakeet model bytes (#2483).
///
/// The single authority. Before #2483 three places answered this question
/// independently and all three answered `AsrModels.defaultCacheDirectory`,
/// which is FluidAudio's SHARED per-repo cache under
/// `~/Library/Application Support/FluidAudio/Models/`. That directory belongs
/// to the FluidAudio package and to every other app built on it, and treating
/// it as ours produced both halves of the same defect: we deleted files another
/// app had put there (#2483), and we refused to install when we could not
/// delete them (#2690).
///
/// **The rule this type exists to make structural: EnviousWispr creates,
/// modifies, moves and deletes nothing under `FluidAudio/`.** It is categorical
/// rather than filtered on purpose. A filter would need to answer "did we write
/// this file", and nothing on disk answers it — the admission marker records
/// what we VALIDATED, not what we WROTE, and we stamp one over pre-existing
/// files we never downloaded (`ModelDeliveryController.adoptedInPlace`). Byte
/// equality with our own manifest cannot separate our copy from a user's own
/// download of the same pinned revision either. Same reasoning the founder
/// ratified for the other shared cache on 2026-07-16
/// (`whisperkit-research.md` FACT: documents-huggingface-is-a-shared-cache-not-ours).
public enum ParakeetInstallLocation {
  /// The directory's last path component, and it is load-bearing rather than
  /// cosmetic. FluidAudio reconstructs a repo directory from whatever parent it
  /// is handed — `AsrModels.repoPath(from:)` drops the last component and
  /// re-appends `repo.folderName` — so a directory named anything else would
  /// make our install location and the runtime's lookup location disagree while
  /// both looked correct in isolation.
  public static let repoFolderName = "parakeet-tdt-0.6b-v3-coreml"

  /// Our owned install directory beneath a given Application Support root.
  ///
  /// A sibling of `EnviousWispr/Models/whisper`, which the multilingual family
  /// has used since #1386 PR-2. Parakeet was the last family still installing
  /// into somebody else's directory.
  public static func directory(appSupport: URL) -> URL {
    appSupport
      .appendingPathComponent("EnviousWispr/Models", isDirectory: true)
      .appendingPathComponent(repoFolderName, isDirectory: true)
  }

  /// The live location, for the one caller that has no injected root: the
  /// engine adapter's legacy branch, which runs when delivery is switched off
  /// or its manifest failed to load and therefore has no registration to read a
  /// directory from.
  ///
  /// It resolves the REAL Application Support root even under a test that
  /// redirected the delivery layer's root. That divergence is deliberate and
  /// narrow: any caller holding a `ParakeetDeliveryHandle` must read the
  /// handle's own `installDirectory` instead, so the only path reaching this
  /// property is the one with nothing better to read. What it must never do is
  /// resolve FluidAudio's shared directory, and it cannot.
  public static var live: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return directory(appSupport: appSupport)
  }
}
