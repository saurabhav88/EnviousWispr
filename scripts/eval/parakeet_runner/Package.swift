// swift-tools-version: 5.9
import PackageDescription

// Standalone eval runner: loads Parakeet ONCE and transcribes a manifest of
// audio files. `fluidaudiocli transcribe` takes a single file per invocation
// and reloads the model each time, which is unusable for 1,890 cases.
//
// Depends on the SAME git URL + exact immutable revision the app pins in the
// root Package.swift (saurabhav88/FluidAudio @ 38e8994b) rather than a local
// path, so this provably runs the same pinned engine the app resolves. Do not
// repoint at a local checkout — a path dependency floats with whatever that
// checkout happens to hold, while this remote revision cannot drift.
let package = Package(
  name: "ParakeetRunner",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(
      url: "https://github.com/saurabhav88/FluidAudio.git",
      revision: "38e8994b38af1a16786b9cdc4bc3476a81449c19")
  ],
  targets: [
    .executableTarget(name: "ParakeetRunner", dependencies: ["FluidAudio"])
  ]
)
