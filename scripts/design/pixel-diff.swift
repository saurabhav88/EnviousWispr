// Compare two render runs pixel by pixel (#4506).
//
// Usage (through the supported entry point):
//   python3 scripts/design/pixel-diff.py <before-dir> <after-dir> --manifest <render-manifest.json> [--diff-dir <dir>]
//
// Every manifest entry names one capture, <name>.png, that must exist, decode and be non-empty in
// BOTH run folders. A PNG in either folder that the manifest does not name is an error.
//
// The metric is normalized decoded RGBA, not PNG bytes: ImageIO decodes each file and every pixel
// is converted, in this script, to straight (unpremultiplied) 16-bit RGBA, so compression, chunk
// order, metadata, sample width (8 or 16 bit), channel order and an opaque image stored with or
// without an alpha channel never count. No drawing into a premultiplied 8-bit context happens,
// because that rounding erases colour differences at partial alpha. Supported inputs: 1 (grey) or
// 3 (RGB) colour components, 8 or 16 integer bits, any CGImageAlphaInfo except alpha-only.
// Anything else (float samples, CMYK, a pair in different colour spaces) is reported as
// incompatible rather than converted, because a conversion could hide a difference.
//
// Exit status: 0 every capture present and identical; 1 at least one capture differs; 2 an input
// is missing, extra, empty, undecodable, a different size or an incompatible format, or usage is
// wrong. A highlighted diff image (<name>-diff.png, red = differing pixel) is written to the diff
// folder for every capture that differs (default: <after-dir>-diff).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error { let message: String }

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("pixel-diff: \(message)\n".utf8))
  exit(2)
}

struct Decoded {
  let width: Int
  let height: Int
  let colorSpace: String
  /// Straight RGBA, 16 bits per channel, row-major, 4 values per pixel.
  let rgba: [UInt16]
}

func decode(_ url: URL) throws -> Decoded {
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw Failure(message: "missing: \(url.path)")
  }
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    CGImageSourceGetCount(source) > 0,
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw Failure(message: "cannot decode: \(url.path)") }
  guard image.width > 0, image.height > 0 else {
    throw Failure(message: "empty image: \(url.path)")
  }
  guard let provider = image.dataProvider, let bytes = provider.data as Data? else {
    throw Failure(message: "no pixel data: \(url.path)")
  }
  let unsupported = { (why: String) in
    Failure(message: "unsupported pixel format (\(why)): \(url.path)")
  }
  let info = image.bitmapInfo
  if info.contains(.floatComponents) { throw unsupported("float samples") }
  let bpc = image.bitsPerComponent
  guard bpc == 8 || bpc == 16 else { throw unsupported("\(bpc) bits per component") }
  guard let space = image.colorSpace, space.model == .rgb || space.model == .monochrome else {
    throw unsupported("colour model")
  }
  let colors = space.numberOfComponents
  guard let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue),
    alpha != .alphaOnly
  else { throw unsupported("alpha info") }
  let hasExtra = alpha != .none
  let samples = colors + (hasExtra ? 1 : 0)
  let bytesPerSample = bpc / 8
  guard image.bitsPerPixel == samples * bpc else {
    throw unsupported("\(image.bitsPerPixel) bits per pixel for \(samples) samples")
  }
  let order = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
  let little16 = order == CGBitmapInfo.byteOrder16Little.rawValue
  let little32 = order == CGBitmapInfo.byteOrder32Little.rawValue
  if little32 && !(bpc == 8 && samples == 4) { throw unsupported("32-bit little-endian order") }
  if little16 && bpc != 16 { throw unsupported("16-bit little-endian order") }
  let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
  let realAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
  let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast

  let name: String
  if let named = space.name {
    name = named as String
  } else if let icc = space.copyICCData() as Data? {
    name = "icc:\(icc.count):\(icc.hashValue)"
  } else {
    name = "unnamed \(space.model.rawValue)"
  }

  var rgba = [UInt16](repeating: 0, count: image.width * image.height * 4)
  bytes.withUnsafeBytes { raw in
    let base = raw.bindMemory(to: UInt8.self)
    var sample = [UInt16](repeating: 0, count: samples)
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = y * image.bytesPerRow + x * samples * bytesPerSample
        for i in 0..<samples {
          let memoryIndex = little32 ? samples - 1 - i : i
          let at = pixel + memoryIndex * bytesPerSample
          if bpc == 8 {
            sample[i] = UInt16(base[at]) * 257
          } else {
            let hi = UInt16(base[little16 ? at + 1 : at])
            let lo = UInt16(base[little16 ? at : at + 1])
            sample[i] = hi << 8 | lo
          }
        }
        let colorStart = hasExtra && alphaFirst ? 1 : 0
        var a: UInt16 = 65535
        if realAlpha { a = sample[alphaFirst ? 0 : samples - 1] }
        var c = (0..<3).map { sample[colorStart + (colors == 1 ? 0 : $0)] }
        if premultiplied {
          c = c.map {
            a == 0 ? 0 : UInt16(min(65535, (UInt32($0) * 65535 + UInt32(a) / 2) / UInt32(a)))
          }
        }
        let out = (y * image.width + x) * 4
        rgba[out] = c[0]
        rgba[out + 1] = c[1]
        rgba[out + 2] = c[2]
        rgba[out + 3] = a
      }
    }
  }
  return Decoded(width: image.width, height: image.height, colorSpace: name, rgba: rgba)
}

/// Differing pixel mask on normalized RGBA.
func compare(_ a: Decoded, _ b: Decoded) -> [Bool] {
  (0..<(a.width * a.height)).map { pixel in
    let o = pixel * 4
    return a.rgba[o] != b.rgba[o] || a.rgba[o + 1] != b.rgba[o + 1]
      || a.rgba[o + 2] != b.rgba[o + 2] || a.rgba[o + 3] != b.rgba[o + 3]
  }
}

func writeDiff(_ mask: [Bool], width: Int, height: Int, to url: URL) throws {
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  for (index, differs) in mask.enumerated() {
    let offset = index * 4
    if differs {
      pixels[offset] = 255
      pixels[offset + 3] = 255
    } else {
      pixels[offset] = 128
      pixels[offset + 1] = 128
      pixels[offset + 2] = 128
      pixels[offset + 3] = 40
    }
  }
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let provider = CGDataProvider(data: Data(pixels) as CFData),
    let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw Failure(message: "cannot write diff image \(url.path)") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw Failure(message: "cannot write \(url.path)")
  }
}

func pngNames(in directory: URL) throws -> Set<String> {
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  return Set(names.filter { $0.lowercased().hasSuffix(".png") })
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
var manifestPath: String?
var diffPath: String?
var positional: [String] = []
while !arguments.isEmpty {
  let argument = arguments.removeFirst()
  switch argument {
  case "--manifest": manifestPath = arguments.isEmpty ? nil : arguments.removeFirst()
  case "--diff-dir": diffPath = arguments.isEmpty ? nil : arguments.removeFirst()
  default: positional.append(argument)
  }
}
guard positional.count == 2, let manifestPath else {
  fail("usage: pixel-diff <before-dir> <after-dir> --manifest <file> [--diff-dir <dir>]")
}
let before = URL(fileURLWithPath: positional[0])
let after = URL(fileURLWithPath: positional[1])
let diffDirectory = URL(fileURLWithPath: diffPath ?? (after.path + "-diff"))

let expected: [String]
do {
  let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
  guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let entries = root["entries"] as? [[String: Any]]
  else { fail("manifest has no entries list") }
  expected = try entries.map {
    guard let name = $0["name"] as? String, !name.isEmpty else {
      throw Failure(message: "entry without a name")
    }
    return name + ".png"
  }
} catch let error as Failure {
  fail(error.message)
} catch {
  fail("cannot read manifest \(manifestPath): \(error)")
}
if expected.isEmpty { fail("manifest lists no captures") }
if Set(expected).count != expected.count { fail("manifest names a capture twice") }

var problems: [String] = []
for directory in [before, after] {
  do {
    let present = try pngNames(in: directory)
    for extra in present.subtracting(expected).sorted() {
      problems.append("extra (not in manifest): \(directory.path)/\(extra)")
    }
  } catch {
    fail("cannot list \(directory.path): \(error)")
  }
}

var differing = 0
var identical = 0
for name in expected {
  do {
    let a = try decode(before.appending(path: name))
    let b = try decode(after.appending(path: name))
    guard a.width == b.width, a.height == b.height else {
      problems.append("\(name): size \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
      continue
    }
    guard a.colorSpace == b.colorSpace else {
      problems.append("\(name): incompatible colour space (\(a.colorSpace) vs \(b.colorSpace))")
      continue
    }
    let mask = compare(a, b)
    let count = mask.filter { $0 }.count
    print("\(name): \(count) differing pixels of \(a.width * a.height)")
    if count == 0 {
      identical += 1
    } else {
      differing += 1
      try FileManager.default.createDirectory(at: diffDirectory, withIntermediateDirectories: true)
      try writeDiff(
        mask, width: a.width, height: a.height,
        to: diffDirectory.appending(path: name.replacingOccurrences(of: ".png", with: "-diff.png")))
    }
  } catch let error as Failure {
    problems.append(error.message)
  } catch {
    problems.append("\(name): \(error)")
  }
}

for problem in problems { FileHandle.standardError.write(Data("pixel-diff: \(problem)\n".utf8)) }
print(
  "pixel-diff: \(expected.count) captures, \(identical) identical, \(differing) differing, \(problems.count) input problems"
)
if !problems.isEmpty { exit(2) }
if differing > 0 {
  print("pixel-diff: diff images in \(diffDirectory.path)")
  exit(1)
}
exit(0)
