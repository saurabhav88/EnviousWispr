// swift-tools-version: 5.9
import PackageDescription

// Standalone eval runner: loads Parakeet ONCE and transcribes a manifest of
// audio files. `fluidaudiocli transcribe` takes a single file per invocation
// and reloads the model each time, which is unusable for 1,890 cases.
//
// Depends on the SAME git URL + revision the app pins in the root Package.swift
// (saurabhav88/FluidAudio @ afb9aab1) rather than a local path, so this provably
// runs the engine we ship. Do not repoint at ~/Developer/EnviousLabs/FluidAudio*
// — both of those checkouts are at different commits.
let package = Package(
  name: "ParakeetRunner",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(
      url: "https://github.com/saurabhav88/FluidAudio.git",
      revision: "afb9aab1efdad979bca22ca887a936ff2c1cd8ea")
  ],
  targets: [
    .executableTarget(name: "ParakeetRunner", dependencies: ["FluidAudio"])
  ]
)
