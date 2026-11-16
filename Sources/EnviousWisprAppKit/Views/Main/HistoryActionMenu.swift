import AppKit
import SwiftUI

/// #4611: History's More menu, drawn by the app (founder 2026-11-15: the approved mock's menu,
/// a rounded card with no arrow, over the system menu's look). It opens in its own small window
/// under the More button, takes the keyboard (Up, Down, Return, Right and Left for the Polish
/// submenu, Escape), and closes when an item runs, on Escape, or when the person clicks
/// anywhere else.
struct HistoryMenuItem: Identifiable {
  enum Kind {
    case action(() -> Void)
    case submenu([HistoryMenuItem])
    case divider
  }

  let id: String
  var title: String = ""
  var systemImage: String?
  var isChecked = false
  var isEnabled = true
  var isDestructive = false
  var kind: Kind

  static func divider(_ id: String) -> HistoryMenuItem { .init(id: id, kind: .divider) }

  var isSelectable: Bool {
    if case .divider = kind { return false }
    return isEnabled
  }
}

/// Opens one History menu at a time.
@MainActor
final class HistoryMenuPresenter {
  static let shared = HistoryMenuPresenter()

  private var panel: HistoryMenuPanel?
  private var openedFrom: NSView?

  /// Opens `items` under `anchor`, or hides the menu when it is already open from there. The
  /// menu window is only ever hidden (`orderOut`), never closed.
  func toggle(items: [HistoryMenuItem], from anchor: NSView) {
    if panel != nil, openedFrom === anchor {
      dismiss()
      return
    }
    dismiss()
    guard let window = anchor.window else { return }
    let host = NSHostingView(
      rootView: HistoryMenuView(items: items, dismiss: { [weak self] in self?.dismiss() }))
    host.sizingOptions = [.intrinsicContentSize]
    let size = host.fittingSize
    let below = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    var origin = NSPoint(x: below.minX, y: below.minY - DesignSpacing.sm - size.height)
    if let screen = window.screen?.visibleFrame, origin.y < screen.minY {
      origin.y = below.maxY + DesignSpacing.sm
    }
    let panel = HistoryMenuPanel(
      contentRect: NSRect(origin: origin, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.onResign = { [weak self] in self?.dismiss() }
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.contentView = host
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
    openedFrom = anchor
  }

  func dismiss() {
    guard let panel else { return }
    self.panel = nil
    openedFrom = nil
    panel.onResign = nil
    panel.orderOut(nil)
  }
}

private final class HistoryMenuPanel: NSPanel {
  var onResign: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func resignKey() {
    super.resignKey()
    onResign?()
  }
}

private struct HistoryMenuView: View {
  let items: [HistoryMenuItem]
  let dismiss: () -> Void

  /// The open submenu, if any, and the highlighted row in what is shown.
  @State private var submenu: [HistoryMenuItem]?
  @State private var highlighted: String?
  @FocusState private var focused: Bool

  private var shown: [HistoryMenuItem] { submenu ?? items }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if submenu != nil {
        row(
          HistoryMenuItem(
            id: "back",
            title: String(
              localized: "Back", comment: "History More menu: leaves the Polish again list."),
            systemImage: "chevron.left",
            kind: .action {
              submenu = nil
              highlighted = nil
            }))
        Divider().padding(.vertical, DesignSpacing.xs).padding(.horizontal, DesignSpacing.sm)
      }
      ForEach(shown) { item in
        if case .divider = item.kind {
          Divider().padding(.vertical, DesignSpacing.xs).padding(.horizontal, DesignSpacing.sm)
        } else {
          row(item)
        }
      }
    }
    .padding(DesignSpacing.sm)
    .frame(minWidth: 240, alignment: .leading)
    .fixedSize()
    .background(
      Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius - 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius - 4)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.downArrow) {
      move(1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      move(-1)
      return .handled
    }
    .onKeyPress(.return) {
      runHighlighted()
      return .handled
    }
    .onKeyPress(.rightArrow) {
      runHighlighted(submenuOnly: true)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      guard submenu != nil else { return .ignored }
      submenu = nil
      highlighted = nil
      return .handled
    }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  private func row(_ item: HistoryMenuItem) -> some View {
    Button {
      run(item)
    } label: {
      HStack(spacing: DesignSpacing.md) {
        Image(systemName: item.isChecked ? "checkmark" : (item.systemImage ?? "circle"))
          .opacity(item.isChecked || item.systemImage != nil ? 1 : 0)
          .frame(width: 16)
        Text(verbatim: item.title)
        Spacer(minLength: DesignSpacing.lg)
        if case .submenu = item.kind {
          Image(systemName: "chevron.right").font(.stHelper)
        }
      }
      .font(.stBody)
      .foregroundStyle(item.isDestructive ? Color.stError : Color.stTextPrimary)
      .opacity(item.isEnabled ? 1 : 0.4)
      .padding(.horizontal, DesignSpacing.md)
      .padding(.vertical, DesignSpacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        highlighted == item.id ? Color.stAccent.opacity(0.18) : .clear,
        in: RoundedRectangle(cornerRadius: DesignSpacing.sm)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!item.isEnabled)
    .onHover { inside in if inside { highlighted = item.id } }
    .accessibilityAddTraits(item.isChecked ? .isSelected : [])
  }

  private func run(_ item: HistoryMenuItem) {
    guard item.isEnabled else { return }
    switch item.kind {
    case .action(let action):
      if item.id == "back" {
        action()
      } else {
        dismiss()
        action()
      }
    case .submenu(let children):
      submenu = children
      highlighted = children.first(where: \.isSelectable)?.id
    case .divider:
      break
    }
  }

  private func runHighlighted(submenuOnly: Bool = false) {
    guard let id = highlighted, let item = shown.first(where: { $0.id == id }) else { return }
    if submenuOnly, case .submenu = item.kind {
      run(item)
    } else if !submenuOnly {
      run(item)
    }
  }

  private func move(_ step: Int) {
    let selectable = shown.filter(\.isSelectable)
    guard !selectable.isEmpty else { return }
    let current = selectable.firstIndex { $0.id == highlighted }
    let next =
      current.map { ($0 + step + selectable.count) % selectable.count }
      ?? (step > 0 ? 0 : selectable.count - 1)
    highlighted = selectable[next].id
  }
}

/// Hands the hosting AppKit view of a SwiftUI control to its owner, so a menu can open under it.
struct HistoryMenuAnchor: NSViewRepresentable {
  let holder: HistoryMenuAnchorHolder

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    holder.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) { holder.view = view }
}

@MainActor
final class HistoryMenuAnchorHolder {
  weak var view: NSView?
}
