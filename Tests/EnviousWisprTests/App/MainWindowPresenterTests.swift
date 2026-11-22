import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #4842: the main window as an AppKit window. When this fails, the user sees the main window not
/// open, open at the wrong size or place, lose their saved size, keep stale content after a
/// reopen, or the Dock icon not update when it closes.
@MainActor
@Suite(.tags(.productOutcome))
struct MainWindowPresenterTests {
  init() { _ = NSApplication.shared }

  /// A presenter whose content counts how many roots it built, with no saved frame.
  private func presenter(builds: Counter) -> MainWindowPresenter {
    let presenter = MainWindowPresenter()
    presenter.makeContent = {
      builds.value += 1
      return AnyView(Text("main"))
    }
    presenter.restoreSavedFrame = { _, _ in false }
    presenter.frameName = Self.throwawayFrameName()
    return presenter
  }

  private final class Counter { var value = 0 }

  /// Never `main`: a test must not read or overwrite the user's saved main-window frame. An empty
  /// name turns AppKit's frame saving off, so no test leaves a saved frame behind.
  private static func throwawayFrameName() -> String { "" }

  /// Closes the window the way the red button does (AppKit calls the presenter as delegate).
  private func close(_ presenter: MainWindowPresenter, _ window: NSWindow) {
    window.performClose(nil)
    window.orderOut(nil)
  }

  @Test("the first open is the app's window: titled, sized, resizable, saved under main")
  func firstOpenShape() throws {
    let builds = Counter()
    let sut = presenter(builds: builds)
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    #expect(window.isVisible)
    #expect(window.title == AppConstants.appName)
    #expect(window.frameAutosaveName.isEmpty)
    #expect(MainWindowLayout.frameName == "main")
    #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
    #expect(window.contentMinSize == NSSize(width: 750, height: 400))
    #expect(window.contentLayoutRect.size == NSSize(width: 1100, height: 760))
    // After the SwiftUI host lays out, the window keeps its size: the host must not resize its
    // window to the content's ideal size (it shrank it to this tiny Text's size before).
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.contentLayoutRect.size == NSSize(width: 1100, height: 760))
    #expect(window.tabbingMode == .disallowed)
    #expect(window.isRestorable == false)
    #expect(window.isExcludedFromWindowsMenu)
    #expect(window.toolbarStyle == .unifiedCompact)
    #expect(builds.value == 1)
  }

  @Test("with no saved frame the first open is centered on the screen")
  func firstOpenCentered() throws {
    let sut = presenter(builds: Counter())
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    let visible = try #require(window.screen?.visibleFrame)
    // AppKit's `center()` puts the window slightly above the middle; within a quarter screen.
    #expect(abs(window.frame.midX - visible.midX) < 1)
    #expect(abs(window.frame.midY - visible.midY) < visible.height / 4)
  }

  @Test("a saved frame from an earlier launch wins over the first-open size")
  func savedFrameWins() throws {
    let sut = MainWindowPresenter()
    sut.makeContent = { AnyView(Text("main")) }
    let name = Self.throwawayFrameName()
    sut.frameName = name
    // Inside the screen's visible area, so AppKit has no reason to move it on show.
    let visible = try #require(NSScreen.main?.visibleFrame)
    let saved = NSRect(x: visible.minX + 40, y: visible.minY + 60, width: 900, height: 600)
    var askedFor: String?
    sut.restoreSavedFrame = { window, name in
      askedFor = name
      window.setFrame(saved, display: false)
      return true
    }
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    #expect(askedFor == name)
    #expect(window.frame == saved)
  }

  @Test("a resized window saves its frame under the presenter's name")
  func resizeIsSaved() throws {
    let sut = presenter(builds: Counter())
    // A throwaway key, removed below: never `main`, the user's own saved frame.
    let name = "ew-4842-test-\(UUID().uuidString)"
    sut.frameName = name
    let key = "NSWindow Frame \(name)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    #expect(window.frameAutosaveName == name)
    window.setFrame(window.frame.insetBy(dx: 20, dy: 20), display: false)
    // The saved value is the resized frame, not the opening one.
    #expect(UserDefaults.standard.string(forKey: key) == window.frameDescriptor)
  }

  @Test("a second show brings back the same window without rebuilding it")
  func secondShowRefocuses() throws {
    let builds = Counter()
    let sut = presenter(builds: builds)
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    window.miniaturize(nil)
    sut.show()
    #expect(sut.window === window)
    #expect(builds.value == 1)
  }

  @Test("after a close the next show is a new window with fresh content, and the close is reported")
  func reopenIsFresh() throws {
    let builds = Counter()
    let sut = presenter(builds: builds)
    var reported: [ObjectIdentifier] = []
    sut.onMainWindowClosed = { reported.append(ObjectIdentifier($0)) }
    sut.show()
    let first = try #require(sut.window)
    let firstContent = first.contentViewController
    close(sut, first)
    #expect(sut.window == nil)
    #expect(reported == [ObjectIdentifier(first)])
    sut.show()
    let second = try #require(sut.window)
    defer { close(sut, second) }
    #expect(second !== first)
    #expect(second.contentViewController !== firstContent)
    #expect(builds.value == 2)
  }

  @Test("a close notification for another window changes nothing")
  func otherWindowCloseIgnored() throws {
    let sut = presenter(builds: Counter())
    var reported = 0
    sut.onMainWindowClosed = { _ in reported += 1 }
    sut.show()
    let window = try #require(sut.window)
    defer { close(sut, window) }
    let other = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    sut.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))
    #expect(sut.window === window)
    #expect(reported == 0)
  }
}
