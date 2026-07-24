// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vadrepro",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/saurabhav88/FluidAudio.git", revision: "e7948e1ac3e4eb0254201d19bb8496a4398c8476")
  ],
  targets: [
    .executableTarget(name: "vadrepro", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
  ]
)
