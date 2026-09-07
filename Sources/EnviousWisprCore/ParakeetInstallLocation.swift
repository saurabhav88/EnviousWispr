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
///
/// **Lives in Core on purpose (#2483 cloud round).** It started in the delivery
/// module, which meant `EnviousWisprASR` could not name it and had to default to
/// `ParakeetBackend`'s vendor directory instead. Three separate holes came out of
/// that one fact — the XPC path, the in-process legacy branch, and
/// `ActiveEngineOperation.load`, which reaches `loadModel()` without ever passing
/// through the adapter that injects. Patching entry points was losing to a
/// reviewer who could always find another; making the DEFAULT ours closes the set,
/// because a site that forgets to inject now fails safe instead of falling into
/// somebody else's directory.
public enum ParakeetInstallLocation {
  /// The directory's last path component, and it is load-bearing rather than
  /// cosmetic. FluidAudio reconstructs a repo directory from whatever parent it
  /// is handed — `AsrModels.repoPath(from:)` drops the last component and
  /// re-appends `repo.folderName` — so a directory named anything else would
  /// make our install location and the runtime's lookup location disagree while
  /// both looked correct in isolation.
  ///
  /// **It is NOT the Hugging Face repo slug**, and the two differ by exactly the
  /// suffix that makes them look interchangeable. `Repo.name` is
  /// `parakeet-tdt-0.6b-v3-coreml`; `Repo.folderName` falls through to
  /// `name.replacingOccurrences(of: "-coreml", with: "")`
  /// (`ModelNames.swift:265-266`), so the directory FluidAudio actually uses is
  /// this one. Taking the value from our own delivery manifest — which carries
  /// the slug — produced a directory the loader would never look in. The test
  /// `lastComponentSurvivesVendorReconstruction` reads the vendor's value at
  /// runtime rather than restating it here, which is what caught that.
  public static let repoFolderName = "parakeet-tdt-0.6b-v3"

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

  /// The directory Parakeet used to install into, kept ONLY as a read-only
  /// donor so an existing copy can be reproduced rather than re-downloaded
  /// (`LegacyDonorImport`).
  ///
  /// This is FluidAudio's shared per-repo cache. It is spelled out here rather
  /// than taken from `AsrModels.defaultCacheDirectory` so that this module does
  /// not depend on FluidAudio, and so the one remaining mention of the shared
  /// tree in our code sits next to the rule about it. **Nothing may pass this
  /// value as an install directory, a staging directory, or anything else a
  /// write or delete can reach.**
  public static func legacySharedDonor(appSupport: URL) -> URL {
    appSupport
      .appendingPathComponent("FluidAudio/Models", isDirectory: true)
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
