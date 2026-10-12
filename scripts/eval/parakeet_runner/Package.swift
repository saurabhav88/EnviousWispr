// swift-tools-version: 6.2
import PackageDescription

// Standalone eval runner: loads Parakeet ONCE and transcribes a manifest of
// audio files. `fluidaudiocli transcribe` takes a single file per invocation
// and reloads the model each time, which is unusable for 1,890 cases.
//
// Depends on the SAME git URL + exact immutable revision the app pins in the
// root Package.swift (saurabhav88/FluidAudio @ fb506037) rather than a local
// path, so this provably runs the same pinned engine the app resolves. Do not
// repoint at a local checkout — a path dependency floats with whatever that
// checkout happens to hold, while this remote revision cannot drift.
let package = Package(
  name: "ParakeetRunner",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(
      url: "https://github.com/saurabhav88/FluidAudio.git",
      // Same `traits: []` as the app: the NeMo text engine stays unlinked.
      revision: "fb506037d2b1917dbb2608b8e79872ec95acf384", traits: [])
  ],
  targets: [
    .executableTarget(name: "ParakeetRunner", dependencies: ["FluidAudio"])
  ],
  // Tools 6.2 is only for `traits:`; keep the Swift 5 language mode the 5.9
  // manifest compiled this runner with.
  swiftLanguageModes: [.v5]
)
