import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4346: the six how-it-works cards on EnviousMeet's last setup screen. When these fail, the
/// arrows or buttons skip or get stuck on a card, the cards keep moving while paused or under
/// Reduce Motion, or they move after the user changed card mid-wait.
@Suite("EnviousMeet how-it-works cards", .tags(.productOutcome))
@MainActor
struct MeetingSetupHowToTests {
  /// Records each wait; `fail` makes the wait throw, like a cancelled task.
  final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []
    var fail = false
    var count: Int { lock.withLock { durations.count } }
    var last: Duration? { lock.withLock { durations.last } }
    func record(_ duration: Duration) throws {
      try lock.withLock {
        durations.append(duration)
        if fail { throw CancellationError() }
      }
    }
  }

  /// A wait that never throws and returns only when released, so a cancelled task still
  /// reaches the post-wait check.
  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var entered: Bool { lock.withLock { continuation != nil } }
    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow = lock.withLock { () -> Bool in
          if released { return true }
          continuation = c
          return false
        }
        if resumeNow { c.resume() }
      }
    }
    func release() {
      let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        released = true
        defer { continuation = nil }
        return continuation
      }
      c?.resume()
    }
  }

  /// What a child answers when offered one width: the honest "does it fit" for wrapping text.
  @MainActor final class SizeBox { var size: CGSize = .zero }

  struct OfferedWidth: Layout {
    let width: CGFloat
    let box: SizeBox
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
      MainActor.assumeIsolated { box.size = size }
      return size
    }
    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
    }
  }

  /// Lets a wait pause the model it belongs to, as a user pressing Pause mid-wait.
  @MainActor final class Holder {
    var model: MeetingSetupHowToModel?
    func pause() { model?.pause() }
  }

  private func model(_ waits: Waits) -> MeetingSetupHowToModel {
    MeetingSetupHowToModel(sleep: { try waits.record($0) })
  }

  @Test("Next and Back move one card and wrap at both ends")
  func navigationWraps() {
    let model = MeetingSetupHowToModel(sleep: { _ in })
    #expect(MeetingSetupHowToModel.cardCount == 6)
    #expect(model.index == 0)
    model.previous()
    #expect(model.index == 5)
    model.next()
    #expect(model.index == 0)
    for _ in 0..<5 { model.next() }
    #expect(model.index == 5)
    model.next()
    #expect(model.index == 0)
  }

  @Test("one auto-advance step waits 8 seconds, then shows the next card")
  func autoAdvanceMovesOn() async {
    let waits = Waits()
    let model = model(waits)
    await model.autoAdvance(reduceMotion: false)
    #expect(waits.count == 1)
    #expect(waits.last == .seconds(8))
    #expect(model.index == 1)
  }

  @Test("paused or Reduce Motion: no wait and no move")
  func pausedAndReduceMotionStay() async {
    let waits = Waits()
    let model = model(waits)
    await model.autoAdvance(reduceMotion: true)
    #expect(waits.count == 0)
    #expect(model.index == 0)
    model.togglePause()
    #expect(model.paused)
    await model.autoAdvance(reduceMotion: false)
    #expect(waits.count == 0)
    #expect(model.index == 0)
    model.togglePause()
    #expect(model.paused == false)
    await model.autoAdvance(reduceMotion: false)
    #expect(model.index == 1)
  }

  @Test("a cancelled wait never moves the card")
  func cancelledWaitStays() async {
    let waits = Waits()
    waits.fail = true
    let model = model(waits)
    await model.autoAdvance(reduceMotion: false)
    #expect(waits.count == 1)
    #expect(model.index == 0)
  }

  @Test("pausing during the wait keeps the card")
  func pauseDuringWaitStays() async {
    let holder = Holder()
    let model = MeetingSetupHowToModel(sleep: { _ in await holder.pause() })
    holder.model = model
    await model.autoAdvance(reduceMotion: false)
    #expect(model.paused)
    #expect(model.index == 0)
  }

  @Test("a task cancelled during the wait never moves the card, even when the wait returns")
  func cancelledTaskStays() async {
    let gate = Gate()
    let model = MeetingSetupHowToModel(sleep: { _ in await gate.wait() })
    let task = Task { await model.autoAdvance(reduceMotion: false) }
    #expect(await settleUntilObserved { gate.entered })
    task.cancel()
    gate.release()
    await task.value
    #expect(model.index == 0)
  }

  @Test("at the narrowest window every card stacks and each picture fits its width")
  func picturesFitNarrowWidth() {
    _ = NSApplication.shared
    // 750-point minimum window: sidebar, page and panel padding leave about 424 points (#4346 r4).
    let narrow: CGFloat = 424
    #expect(MeetingSetupHowToCard.isStacked(width: narrow))
    #expect(MeetingSetupHowToCard.isStacked(width: 900) == false)
    let room = MeetingSetupHowToCard.illustrationWidth(width: narrow)
    #expect(room + 2 * MeetingSetupHowToCard.padding <= narrow)
    for index in 0..<MeetingSetupHowToModel.cardCount {
      // Offer the picture exactly its narrow width, as the card does; text may wrap, but a part
      // that cannot shrink (the real call card, the menu) answers wider than offered.
      let box = SizeBox()
      let host = NSHostingView(
        rootView: OfferedWidth(width: room, box: box) {
          MeetingSetupHowToCard.illustration(index: index, isVisible: true)
        })
      _ = host.fittingSize
      let needed = box.size.width
      print("HowToPicture \(index) needs=\(needed) room=\(room)")
      #expect(needed > 0, "card \(index + 1)'s picture measured nothing")
      #expect(needed <= room + 0.5, "card \(index + 1)'s picture needs \(needed) of \(room) points")
    }
    // Two-way control: the instrument can say no. The real call card (card 2) cannot shrink
    // below its 340-point card plus padding, so offered 300 it must answer wider than 300.
    let control = SizeBox()
    _ = NSHostingView(
      rootView: OfferedWidth(width: 300, box: control) {
        MeetingSetupHowToCard.illustration(index: 1, isVisible: true)
      }
    ).fittingSize
    print("HowToPicture control needs=\(control.size.width) offered=300")
    #expect(control.size.width > 300, "the width probe cannot see a picture that does not fit")
  }

  @Test("the real carousel draws its card at a wide and the narrowest window, not only its buttons")
  func carouselShowsACard() {
    _ = NSApplication.shared
    // #4346 UAT: a card row that waited for its measured width stayed 0 points tall, so the
    // last setup screen showed only Back, the dots, Pause and Next (49 points in all).
    var heights: [CGFloat: CGFloat] = [:]
    for width: CGFloat in [900, 424] {
      let host = NSHostingView(rootView: MeetingSetupHowTo().frame(width: width))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let height = host.fittingSize.height
      window.contentView = nil
      print("HowToCarousel width=\(width) height=\(height)")
      heights[width] = height
      // The buttons row alone is about 49 points; a card adds its picture (the call card alone
      // is well over 150 points).
      #expect(height > 200, "at \(width) the carousel is \(height) tall: no card is drawn")
    }
    // A width that never arrived lays every card out at 0 points wide, thousands of points tall.
    let wide = heights[900] ?? 0
    #expect(wide < 900, "at 900 the carousel is \(wide) tall: the cards never got their width")
  }

  @Test("Reduce Motion pauses the cards")
  func pauseIsSticky() {
    let model = MeetingSetupHowToModel(sleep: { _ in })
    model.pause()
    model.pause()
    #expect(model.paused)
  }
}
