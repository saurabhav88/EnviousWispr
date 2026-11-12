import AppKit
import EnviousWisprAppKitTestSupport
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import EnviousWisprAppKit

/// Refreshes the screen atlas pictures (#4506, `design/atlas/`). Build and mockup sessions read
/// these pictures to see what the app looks like instead of inventing it.
///
/// Gated by `TEST_RUNNER_EW_RENDER_ATLAS=1`; it writes tracked files, so it never runs in an
/// ordinary lane. It renders with `DesignRenderHarness`'s own fixtures (pages through
/// `DesignPageCaptures.capturePage`, everything else through `DesignRenderHarness.capture`) into a
/// fresh `build/design-render/atlas-*` folder, then writes 1x copies into `design/atlas/pictures/`.
/// It replaces only pictures `atlas.json` marks `"kind": "harness"`; hand photos are never read
/// or written. A page becomes one tall picture: the manifest's scroll captures measure the page,
/// then one capture as tall as the page is taken.
@MainActor
@Suite(.tags(.harnessContract))
struct DesignAtlasRender {

  init() { _ = NSApplication.shared }

  nonisolated static let enabled = ProcessInfo.processInfo.environment["EW_RENDER_ATLAS"] == "1"
  static let atlasURL = RepoRoot.url.appending(path: "design/atlas")
  /// The atlas shows pages at the default 820pt window.
  static let window = 820

  struct Atlas: Decodable {
    let pictures: [Picture]
  }

  struct Picture: Decodable {
    let id: String
    let kind: String
    let source: Source?
  }

  struct Source: Decodable {
    let page: String?
    let manifest: String?
  }

  static func loadAtlas() throws -> Atlas {
    try JSONDecoder().decode(
      Atlas.self, from: Data(contentsOf: atlasURL.appending(path: "atlas.json")))
  }

  @Test("refresh every harness picture the atlas names, and no hand photo", .enabled(if: enabled))
  func renderAtlas() async throws {
    let atlas = try Self.loadAtlas()
    let manifest = try DesignRenderHarness.loadManifest()
    let staging = RepoRoot.url.appending(
      path:
        "build/design-render/atlas-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    )
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let pictures = Self.atlasURL.appending(path: "pictures")
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)

    let harness = atlas.pictures.filter { $0.kind == "harness" }
    #expect(!harness.isEmpty, "atlas.json names no harness pictures")
    var written: [String] = []
    for picture in harness {
      let source = try #require(picture.source, "\(picture.id): a harness picture needs a source")
      try Self.removeOldFiles(of: picture.id, in: pictures)
      for appearance in ["light", "dark"] {
        if let label = source.page {
          let shots = manifest.entries
            .filter {
              $0.fixture == "page:\(label)" && $0.window == Self.window
                && $0.appearance == appearance
            }
            .sorted { ($0.scroll ?? 0) < ($1.scroll ?? 0) }
          try #require(!shots.isEmpty, "\(picture.id): no \(Self.window) \(appearance) page entries")
          // Pass 1, the manifest's own scroll captures: the bottom offset gives the page length
          // (a lazy list reads its full length only at the bottom).
          var offsets: [CGFloat] = []
          _ = try await DesignPageCaptures.capturePage(
            label: label, width: CGFloat(shots[0].pageWidth), dark: appearance == "dark",
            names: shots.map(\.name), into: staging, offsets: { offsets.append($0) })
          let viewport = CGFloat(try #require(shots[0].viewport))
          let length = ((offsets.max() ?? 0) + viewport).rounded(.up)
          // Pass 2, one capture as tall as the page, so a header that stays pinned while
          // scrolling (the Dictation tab strip) appears once and nothing hides under it.
          let tall = try await DesignPageCaptures.capturePage(
            label: label, width: CGFloat(shots[0].pageWidth), dark: appearance == "dark",
            names: ["atlas-\(picture.id)-\(appearance)"], into: staging, viewport: length)
          let capture = try #require(tall.first, "\(picture.id): no full-length capture")
          let out = pictures.appending(path: "\(picture.id)-\(appearance).png")
          try Self.downsample(capture.url, to: out)
          written.append(out.lastPathComponent)
        } else {
          let name = try #require(source.manifest, "\(picture.id): no page or manifest source")
          let entry = try #require(
            manifest.entries.first { $0.name == "\(name)-\(appearance)" },
            "\(picture.id): no manifest entry \(name)-\(appearance)")
          let capture = try DesignRenderHarness.capture(entry, into: staging)
          let out = pictures.appending(path: "\(picture.id)-\(appearance).png")
          try Self.downsample(capture.url, to: out)
          written.append(out.lastPathComponent)
        }
      }
    }
    for name in written { print("ATLAS WROTE \(name)") }
    print(
      "ATLAS RUN: \(written.count) pictures for \(harness.count) atlas entries -> \(pictures.path)")
  }

  /// Delete the previous harness files of one picture. Hand photos have other ids.
  static func removeOldFiles(of id: String, in folder: URL) throws {
    for file in try FileManager.default.contentsOfDirectory(atPath: folder.path)
    where file.hasPrefix(id + "-") && file.hasSuffix(".png") {
      let rest = String(file.dropFirst(id.count + 1))
      // `<id>-light.png` or `<id>-dark.png`; never a longer id that starts with this one.
      let own = rest == "light.png" || rest == "dark.png"
      if own { try FileManager.default.removeItem(at: folder.appending(path: file)) }
    }
  }

  /// Write a 2x capture at 1x (half the pixels each way), keeping transparency.
  static func downsample(_ url: URL, to out: URL) throws {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.path)")
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.path)")
    let width = image.width / 2
    let height = image.height / 2
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "\(out.lastPathComponent)")
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let made = try #require(context.makeImage(), "\(out.lastPathComponent): no image")
    let destination = try #require(
      CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil),
      "\(out.path)")
    CGImageDestinationAddImage(destination, made, nil)
    try #require(CGImageDestinationFinalize(destination), "\(out.path): not written")
  }
}
