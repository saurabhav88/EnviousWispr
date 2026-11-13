import AppKit
import EnviousWisprCore
import SwiftUI

/// #3147 PR4: a meeting's notes as blocks, edited in one native text view. Each block is one
/// paragraph, so typing, selection, input methods (marked text is never touched), paste and
/// undo are the system's own; every change the text view makes is turned into block edits and
/// applied to the app-owned draft (`MeetingNotesAccessing`, the meeting's documents owner),
/// never kept in this view. A gutter shows when each block was first typed (none for notes
/// written before blocks) and a task's tick. ⌘⇧7 makes the caret's block an action item or back
/// to text; ⌘↩ ticks or unticks it. A new block starts at `currentMs`: the playback position
/// after Stop, nil when nothing is known.
struct MeetingNotesBlockEditor: View {
  let meetingID: UUID
  let notes: any MeetingNotesAccessing
  var currentMs: @MainActor () -> Int? = { nil }

  var body: some View {
    let snapshot = notes.snapshot(for: meetingID)
    VStack(alignment: .leading, spacing: 8) {
      MeetingNotesTextView(
        meetingID: meetingID, notes: notes, snapshot: snapshot, currentMs: currentMs
      )
      .frame(minHeight: 240)
      .background(
        Color.stSectionBg, in: RoundedRectangle(cornerRadius: DesignRadius.lg)
      )
      .overlay(alignment: .topLeading) {
        if snapshot.canEdit, snapshot.document.markdown.isEmpty {
          Text(
            "Type your notes.", comment: "History, a meeting: the empty Notes box's placeholder."
          )
          .font(.stBody)
          .foregroundStyle(.stTextTertiary)
          .padding(.leading, MeetingNotesTextView.gutterWidth + 5)
          .padding(.top, MeetingNotesTextView.verticalInset)
          .allowsHitTesting(false)
        }
      }
      .overlay {
        if snapshot.saveState == .loading { ProgressView().controlSize(.small) }
      }
      .accessibilityLabel(Text("Notes", comment: "History, a meeting: the notes box."))
      status(snapshot)
    }
    .task(id: meetingID) { _ = await notes.flush(meetingID) }
    .onDisappear {
      let notes = notes
      let meetingID = meetingID
      Task { _ = await notes.flush(meetingID) }
    }
  }

  @ViewBuilder
  private func status(_ snapshot: MeetingNotesSnapshot) -> some View {
    switch snapshot.saveState {
    case .loading:
      EmptyView()
    case .saving:
      Text("Saving…", comment: "History, a meeting: the notes are being written to disk.")
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
    case .saved:
      if !snapshot.document.markdown.isEmpty {
        Text(
          "Saved on this Mac",
          comment: "History, a meeting: the notes are written to disk on this Mac."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
      }
    case .failed:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if snapshot.canEdit {
          Text(
            "Your notes could not be saved.",
            comment:
              "History, a meeting: saving the notes failed; the typed notes stay in the app until a save works."
          )
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            Task { _ = await notes.flush(meetingID) }
          } label: {
            Text("Try again", comment: "History, a meeting: saves the notes again.")
          }
          .buttonStyle(.link)
        } else {
          Text(
            "Your saved notes could not be read.",
            comment: "History, a meeting: the notes file could not be read."
          )
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            Task { _ = await notes.flush(meetingID) }
          } label: {
            Text("Try again", comment: "History, a meeting: reads the saved notes again.")
          }
          .buttonStyle(.link)
        }
      }
      .accessibilityIdentifier("history.meeting.notesSaveFailed")
    }
  }
}

// MARK: - Text to block edits

/// How the notes' blocks sit in the one text view, and how a change to its text becomes block
/// edits. The text is each block's text, one paragraph per block (`\n` between), so a UTF-16
/// offset in the text names a block and an offset inside it.
enum MeetingNotesTextMapping {
  static func text(_ document: MeetingNotesDocument) -> String {
    document.blocks.map(\.text).joined(separator: "\n")
  }

  /// The block holding UTF-16 offset `offset` of `text(document)`, and the offset inside it.
  /// An offset on a paragraph break belongs to the block that ends there.
  static func locate(_ offset: Int, in document: MeetingNotesDocument) -> (index: Int, offset: Int)?
  {
    var start = 0
    for (index, block) in document.blocks.enumerated() {
      let length = block.text.utf16.count
      if offset <= start + length { return offset >= start ? (index, offset - start) : nil }
      start += length + 1
    }
    return nil
  }

  /// The smallest change turning `old` into `new`: the UTF-16 range of `old` replaced, and the
  /// replacement. Bounds fall on Unicode scalar boundaries, never inside a UTF-16 pair.
  static func change(from old: String, to new: String) -> (range: Range<Int>, replacement: String) {
    let a = Array(old.unicodeScalars)
    let b = Array(new.unicodeScalars)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
      a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
    {
      suffix += 1
    }
    func utf16(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
      scalars.reduce(0) { $0 + $1.utf16.count }
    }
    let lower = utf16(a[..<prefix])
    let upper = lower + utf16(a[prefix..<(a.count - suffix)])
    var replacement = String.UnicodeScalarView()
    replacement.append(contentsOf: b[prefix..<(b.count - suffix)])
    return (lower..<upper, String(replacement))
  }

  /// The block edits that replace `range` (UTF-16, of `text(document)`) with `replacement`.
  /// Return typed at a caret is a split; a change inside one block is one text edit; a change
  /// across blocks clears the covered text, joins each following block into the first (which
  /// keeps its id and time), then inserts the replacement. Nil when the range is outside the
  /// text.
  static func edits(
    _ document: MeetingNotesDocument, range: Range<Int>, replacement: String,
    newID: () -> UUID = { UUID() }
  ) -> [MeetingNotesEdit]? {
    guard let (first, lower) = locate(range.lowerBound, in: document),
      let (last, upper) = locate(range.upperBound, in: document)
    else { return nil }
    let blocks = document.blocks
    if first == last {
      if range.isEmpty, replacement == "\n" {
        return [.split(blockID: blocks[first].id, offsetUTF16: lower, newBlockID: newID())]
      }
      return [.replaceText(blockID: blocks[first].id, rangeUTF16: lower..<upper, text: replacement)]
    }
    var edits: [MeetingNotesEdit] = []
    let firstLength = blocks[first].text.utf16.count
    if lower < firstLength {
      edits.append(
        .replaceText(blockID: blocks[first].id, rangeUTF16: lower..<firstLength, text: ""))
    }
    for index in (first + 1)...last {
      let cut = index == last ? upper : blocks[index].text.utf16.count
      if cut > 0 {
        edits.append(.replaceText(blockID: blocks[index].id, rangeUTF16: 0..<cut, text: ""))
      }
      edits.append(.joinWithPrevious(blockID: blocks[index].id))
    }
    if !replacement.isEmpty {
      edits.append(
        .replaceText(blockID: blocks[first].id, rangeUTF16: lower..<lower, text: replacement))
    }
    return edits
  }
}

// MARK: - The text view

/// The AppKit text view behind `MeetingNotesBlockEditor`.
struct MeetingNotesTextView: NSViewRepresentable {
  /// DESIGN.md `stBody` / `stHelper` are 14 pt; the token file has SwiftUI fonts only, and this
  /// text view needs an `NSFont` of the same size.
  static let fontSize: CGFloat = 14
  static let gutterWidth: CGFloat = 64
  static let verticalInset: CGFloat = 8

  let meetingID: UUID
  let notes: any MeetingNotesAccessing
  let snapshot: MeetingNotesSnapshot
  let currentMs: @MainActor () -> Int?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    layout.addTextContainer(container)
    let textView = NotesTextView(frame: .zero, textContainer: container)
    textView.delegate = context.coordinator
    textView.allowsUndo = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
    textView.font = NSFont.systemFont(ofSize: Self.fontSize)
    textView.textColor = NSColor(Color.stTextBody)
    textView.typingAttributes = NotesTextView.baseAttributes
    textView.coordinator = context.coordinator
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    context.coordinator.textView = textView
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.meetingID = meetingID
    coordinator.notes = notes
    coordinator.currentMs = currentMs
    coordinator.sync(snapshot)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    weak var textView: NotesTextView?
    var meetingID: UUID?
    var notes: (any MeetingNotesAccessing)?
    var currentMs: @MainActor () -> Int? = { nil }
    /// The text view's own undo history: a resync from the draft clears it without touching
    /// the window's other fields.
    let undo = UndoManager()
    /// The change the text view announced and has not yet made.
    private var pending: (range: Range<Int>, replacement: String)?
    private var syncing = false

    /// Draws `snapshot`. The text is replaced only when it differs from the draft (a read, a
    /// refused edit, another editor), keeping the caret where it was; otherwise only the
    /// gutter and styles follow.
    func sync(_ snapshot: MeetingNotesSnapshot) {
      guard let textView, !textView.hasMarkedText() else { return }
      textView.blocks = snapshot.document.blocks
      textView.isEditable = snapshot.canEdit
      let text = MeetingNotesTextMapping.text(snapshot.document)
      if !MeetingDocumentHash.sameBytes(textView.string, text) {
        let selection = textView.selectedRange()
        syncing = true
        textView.string = text
        syncing = false
        undo.removeAllActions()
        let length = (text as NSString).length
        textView.setSelectedRange(
          NSRange(location: min(selection.location, length), length: 0))
      }
      textView.restyle()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textView(
      _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?
    ) -> Bool {
      guard !syncing, !textView.hasMarkedText(), let text else { return true }
      if text.contains("\r") {
        // Every line break form becomes a paragraph break, as one change.
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\r", with: "\n")
        textView.insertText(unified, replacementRange: range)
        return false
      }
      pending = (range.location..<(range.location + range.length), text)
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard !syncing, let textView, !textView.hasMarkedText(), let notes, let meetingID else {
        return
      }
      let snapshot = notes.snapshot(for: meetingID)
      let old = MeetingNotesTextMapping.text(snapshot.document)
      let new = textView.string
      defer { pending = nil }
      guard !MeetingDocumentHash.sameBytes(old, new) else { return }
      var change = MeetingNotesTextMapping.change(from: old, to: new)
      if let pending,
        Self.applying(pending, to: old).map({ MeetingDocumentHash.sameBytes($0, new) })
          == true
      {
        change = pending
      }
      guard snapshot.canEdit,
        let edits = MeetingNotesTextMapping.edits(
          snapshot.document, range: change.range, replacement: change.replacement)
      else {
        sync(snapshot)
        return
      }
      let atMs = currentMs()
      for edit in edits {
        let revision = notes.snapshot(for: meetingID).revision
        guard notes.apply(edit, to: meetingID, expectedRevision: revision, atMs: atMs) else {
          break
        }
      }
      // Whatever the draft now holds is what the view shows.
      sync(notes.snapshot(for: meetingID))
    }

    /// `old` with `change` made, or nil when its range is outside `old`.
    private static func applying(_ change: (range: Range<Int>, replacement: String), to old: String)
      -> String?
    {
      let ns = old as NSString
      guard change.range.upperBound <= ns.length else { return nil }
      return ns.replacingCharacters(
        in: NSRange(location: change.range.lowerBound, length: change.range.count),
        with: change.replacement)
    }

    /// The caret's block, from the text view's selection.
    private func caretBlock() -> MeetingNoteBlock? {
      guard let textView, let notes, let meetingID else { return nil }
      let document = notes.snapshot(for: meetingID).document
      guard
        let (index, _) = MeetingNotesTextMapping.locate(
          textView.selectedRange().location, in: document)
      else { return nil }
      return document.blocks[index]
    }

    /// Applies one block edit made outside the text (a kind or a tick).
    func applyOutsideText(_ make: (MeetingNoteBlock) -> MeetingNotesEdit?, block: MeetingNoteBlock?)
    {
      guard let notes, let meetingID, let block = block ?? caretBlock(), let edit = make(block)
      else { return }
      let snapshot = notes.snapshot(for: meetingID)
      guard snapshot.canEdit else { return }
      _ = notes.apply(edit, to: meetingID, expectedRevision: snapshot.revision, atMs: currentMs())
      sync(notes.snapshot(for: meetingID))
    }

    func toggleTask() {
      applyOutsideText(
        { .setKind(blockID: $0.id, kind: $0.kind == .task ? .text : .task) }, block: nil)
    }

    func toggleDone(_ block: MeetingNoteBlock?) {
      applyOutsideText(
        { $0.kind == .task ? .setDone(blockID: $0.id, done: !$0.done) : nil }, block: block)
    }
  }
}

/// The notes text view: a gutter at the left with each block's time and a task's tick.
final class NotesTextView: NSTextView {
  weak var coordinator: MeetingNotesTextView.Coordinator?
  var blocks: [MeetingNoteBlock] = [] { didSet { needsDisplay = true } }

  static var baseAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: MeetingNotesTextView.fontSize),
      .foregroundColor: NSColor(Color.stTextBody),
    ]
  }

  override var textContainerOrigin: NSPoint {
    NSPoint(x: MeetingNotesTextView.gutterWidth, y: textContainerInset.height)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    textContainer?.size = NSSize(
      width: max(0, newSize.width - MeetingNotesTextView.gutterWidth - 8),
      height: CGFloat.greatestFiniteMagnitude)
  }

  /// Paragraph styles from the blocks: a ticked task is struck through, a quote is quieter.
  func restyle() {
    guard let storage = textStorage else { return }
    let text = storage.string as NSString
    storage.beginEditing()
    storage.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: text.length))
    var location = 0
    for block in blocks {
      let length = (block.text as NSString).length
      let range = NSRange(location: location, length: min(length, max(0, text.length - location)))
      if block.kind == .task, block.done {
        storage.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor(Color.stTextTertiary), range: range)
      } else if block.kind == .quote {
        storage.addAttribute(.foregroundColor, value: NSColor(Color.stTextSecondary), range: range)
      }
      location += length + 1
    }
    storage.endEditing()
  }

  /// The top of each block's first line, in view coordinates.
  private func blockTops() -> [CGFloat] {
    guard let layoutManager, let textContainer else { return [] }
    layoutManager.ensureLayout(for: textContainer)
    let text = string as NSString
    var tops: [CGFloat] = []
    var location = 0
    for block in blocks {
      let rect: NSRect
      if location < text.length {
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      } else {
        rect = layoutManager.extraLineFragmentRect
      }
      tops.append(rect.minY + textContainerOrigin.y)
      location += (block.text as NSString).length + 1
    }
    return tops
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    let tops = blockTops()
    let timeAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(
        ofSize: MeetingNotesTextView.fontSize, weight: .regular),
      .foregroundColor: NSColor(Color.stTextTertiary),
    ]
    for (block, top) in zip(blocks, tops) {
      if let ms = block.startedAtMs {
        let label = Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))
        (label as NSString).draw(at: NSPoint(x: 4, y: top), withAttributes: timeAttributes)
      }
      if block.kind == .task,
        let image = NSImage(
          systemSymbolName: block.done ? "checkmark.square" : "square",
          accessibilityDescription: nil)
      {
        let side = MeetingNotesTextView.fontSize
        image.isTemplate = true
        NSColor(Color.stTextSecondary).set()
        image.draw(
          in: NSRect(
            x: MeetingNotesTextView.gutterWidth - side - 6, y: top + 2, width: side, height: side))
      }
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard point.x < MeetingNotesTextView.gutterWidth, isEditable else {
      super.mouseDown(with: event)
      return
    }
    let tops = blockTops()
    // The block whose first line starts at or above the click.
    if let index = tops.lastIndex(where: { $0 <= point.y }), blocks[index].kind == .task {
      coordinator?.toggleDone(blocks[index])
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, isEditable, !hasMarkedText() else {
      return super.performKeyEquivalent(with: event)
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == [.command, .shift],
      event.charactersIgnoringModifiers == "7"
        || event.charactersIgnoringModifiers == "&"
    {
      coordinator?.toggleTask()
      return true
    }
    if flags == [.command], event.keyCode == 36 {
      coordinator?.toggleDone(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
