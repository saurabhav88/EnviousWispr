import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2006 — the quarantine strip is THE fix: a translocated bundle carries
/// `com.apple.quarantine`, `FileManager` copies preserve it, and macOS then
/// translocates the placed copy again. These tests run against a real temp
/// bundle tree with real extended attributes, never a simulation of one.
@Suite("QuarantineStrip")
struct QuarantineStripTests {

  private static let attr = "com.apple.quarantine"
  private static let value = "0083;00000000;Safari;"

  private static func setQuarantine(_ url: URL) {
    _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Array(value.utf8).withUnsafeBufferPointer {
        setxattr(path, attr, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
      }
    }
  }

  private static func hasQuarantine(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path -> Bool in
      guard let path else { return false }
      return getxattr(path, attr, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
  }

  /// A bundle-shaped tree: root, a nested dir, and a nested file.
  private static func makeBundle() throws -> (root: URL, inner: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-strip-\(UUID().uuidString).app")
    let macos = root.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    let inner = macos.appendingPathComponent("EnviousWispr")
    try Data("binary".utf8).write(to: inner)
    return (root, inner)
  }

  @Test("strips the attribute from the root AND every descendant")
  func stripsRecursively() throws {
    let (root, inner) = try Self.makeBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    Self.setQuarantine(root)
    Self.setQuarantine(inner)
    // Positive control: the instrument can SEE the attribute before we strip.
    #expect(Self.hasQuarantine(root))
    #expect(Self.hasQuarantine(inner))

    #expect(FileManagerApplicationMover.stripQuarantine(at: root))

    #expect(!Self.hasQuarantine(root))
    // The nested one is the mutation control: a non-recursive implementation
    // clears the root, returns true, and leaves the bundle still trapped —
    // which is exactly the shipped bug wearing a passing test.
    #expect(!Self.hasQuarantine(inner))
  }

  @Test("a tree that never carried the attribute is untouched and still succeeds")
  func cleanTreeSucceeds() throws {
    let (root, inner) = try Self.makeBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!Self.hasQuarantine(root))

    #expect(FileManagerApplicationMover.stripQuarantine(at: root))

    #expect(!Self.hasQuarantine(root))
    #expect(!Self.hasQuarantine(inner))
    // ENOATTR is success, not failure: a clean bundle must not fail the install.
    #expect(FileManager.default.fileExists(atPath: inner.path))
  }

  @Test("a CLEAN item we cannot modify still succeeds (probe before removing)")
  func cleanButUnmodifiableItemSucceeds() throws {
    // An app in /Applications owned by root or another admin returns EPERM
    // from `removexattr` EVEN WHEN the attribute is absent. Removing
    // unconditionally would fail a perfectly clean destination copy and send
    // its user the wrong message (whole-diff review r3).
    //
    // Reproduced WITHOUT root by setting the user-immutable flag, which makes
    // `removexattr` fail while `getxattr` still reports the attribute absent —
    // exactly the shape of the ownership case. This is the test that
    // discriminates the fix: the clean-tree test above passes either way.
    let (root, inner) = try Self.makeBundle()
    defer {
      _ = inner.withUnsafeFileSystemRepresentation { $0.map { chflags($0, 0) } }
      try? FileManager.default.removeItem(at: root)
    }
    #expect(!Self.hasQuarantine(inner))
    let flagged = inner.withUnsafeFileSystemRepresentation { path -> Bool in
      guard let path else { return false }
      return chflags(path, UInt32(UF_IMMUTABLE)) == 0
    }
    // Positive control: if the flag did not take, this proves nothing.
    try #require(flagged)

    #expect(FileManagerApplicationMover.stripQuarantine(at: root))
  }

  @Test("replacing a QUARANTINED destination leaves the placed bundle clean")
  func replacingAQuarantinedDestinationYieldsACleanBundle() throws {
    // Cloud review P1 argued FileManager.replaceItemAt could merge the old
    // destination's quarantine back onto our clean staged bundle. Measured on
    // APFS 2026-08-10: it does not, with default options or with
    // .usingNewMetadataOnly. This test LOCKS that platform behaviour, so if a
    // future macOS changes it we find out here rather than from a user who
    // cannot update. The mover additionally re-verifies the destination after
    // placement, so the guarantee does not depend on this behaviour holding.
    let (dest, _) = try Self.makeBundle()
    let (stage, _) = try Self.makeBundle()
    defer {
      try? FileManager.default.removeItem(at: dest)
      try? FileManager.default.removeItem(at: stage)
    }
    Self.setQuarantine(dest)
    try #require(Self.hasQuarantine(dest))  // positive control
    #expect(!Self.hasQuarantine(stage))

    _ = try FileManager.default.replaceItemAt(
      dest, withItemAt: stage, backupItemName: nil, options: .usingNewMetadataOnly)

    #expect(!Self.hasQuarantine(dest))
  }

  @Test("a symlink inside the bundle is not followed; its target keeps its attribute")
  func doesNotFollowSymlinks() throws {
    let (root, _) = try Self.makeBundle()
    defer { try? FileManager.default.removeItem(at: root) }

    let outside = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-strip-outside-\(UUID().uuidString)")
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    Self.setQuarantine(outside)

    let link = root.appendingPathComponent("Contents/link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(FileManagerApplicationMover.stripQuarantine(at: root))

    // XATTR_NOFOLLOW: a link inside our bundle must never be usable to clear
    // the attribute on a file outside it.
    #expect(Self.hasQuarantine(outside))
  }
}
