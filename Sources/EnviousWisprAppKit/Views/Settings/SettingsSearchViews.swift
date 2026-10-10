import AppKit
import SwiftUI

/// The search field's bounds, published so the window can draw the dropdown above both cards
/// (#3482 plan §3.3: never inside either card's clip shape).
struct SettingsSearchFieldAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// The Settings sidebar's search field (#3482 plan §3.3): magnifier, text, clear button. Up and
/// Down move the selection, Return chooses it, Escape clears the search without navigating.
struct SettingsSearchField: View {
  let model: SettingsSearchModel
  var isFocused: FocusState<Bool>.Binding
  let choose: (SettingsSearchRequest) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      TextField(
        String(localized: SettingsSearchCopy.placeholder),
        text: Binding(get: { model.query }, set: { model.setQuery($0) })
      )
      .textFieldStyle(.plain)
      .focused(isFocused)
      .onSubmit {
        if let request = model.submit() { choose(request) }
      }
      .onKeyPress(.downArrow) {
        guard model.isPanelPresented else { return .ignored }
        model.moveSelection(by: 1)
        return .handled
      }
      .onKeyPress(.upArrow) {
        guard model.isPanelPresented else { return .ignored }
        model.moveSelection(by: -1)
        return .handled
      }
      .onKeyPress(.tab) {
        // Focus stays in the search while its dropdown is open (§3.4).
        model.isPanelPresented ? .handled : .ignored
      }
      .onKeyPress(.escape) {
        guard !model.query.isEmpty else { return .ignored }
        model.reset(endedBy: .escape)
        return .handled
      }
      .settingsMapRegistration(.windowSearch)
      if !model.query.isEmpty {
        Button {
          model.reset(endedBy: .clear)
          isFocused.wrappedValue = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stTextTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(SettingsSearchCopy.clear))
        .help(Text(SettingsSearchCopy.clear))
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.stInputBorder, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .anchorPreference(key: SettingsSearchFieldAnchorKey.self, value: .bounds) { $0 }
  }
}

/// The dropdown under the search field (#3482 plan §3.3, founder's Slack-style mockup): about
/// 440 pt wide, about eight rows tall, scrolling inside itself. Only `st*` tokens, so it follows
/// Light and Dark.
struct SettingsSearchPanel: View {
  let model: SettingsSearchModel
  /// The height the window leaves under the search field. The list never grows past it, so at the
  /// smallest window every row, and the selected one, stays on screen.
  var availableHeight: CGFloat = .infinity
  let choose: (SettingsSearchRequest) -> Void

  static let rowHeight: CGFloat = 52
  static let visibleRows: CGFloat = 8

  var body: some View {
    Group {
      if model.showsNoResults {
        message(SettingsSearchCopy.noResults(model.query.trimmingCharacters(in: .whitespaces)))
      } else if !model.results.isEmpty {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(model.results, id: \.entryID) { result in
                row(result).id(result.entryID)
              }
            }
            .padding(6)
          }
          .frame(maxHeight: Self.listHeight(available: availableHeight))
          .onChange(of: model.selectedEntryID) { _, id in
            if let id { proxy.scrollTo(id) }
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.stInputBorder, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
  }

  /// About eight rows, or less when the window leaves less (the panel's own 1 pt border included).
  static func listHeight(available: CGFloat) -> CGFloat {
    max(0, min(rowHeight * visibleRows, available - 2))
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
  }

  private func row(_ result: SettingsSearchResult) -> some View {
    let selected = result.entryID == model.selectedEntryID
    let id = SettingsMapID(rawValue: result.entryID)
    let title = id.map(SettingsSearchPresentation.title(of:)) ?? result.entryID
    let breadcrumb = id.map(SettingsSearchPresentation.breadcrumb(of:)) ?? ""
    let secondary: Color = selected ? .white : .stTextSecondary
    return Button {
      if let request = model.request(for: result.entryID) { choose(request) }
    } label: {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.stRowLabel)
            .foregroundStyle(selected ? Color.white : Color.stTextPrimary)
            .lineLimit(1)
          if !breadcrumb.isEmpty {
            Text(breadcrumb).font(.stHelper).foregroundStyle(secondary).lineLimit(1)
          }
          if let hint = result.hint {
            Text(SettingsSearchCopy.matches(hint))
              .font(.stHelper).foregroundStyle(secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if selected {
          Text(SettingsSearchCopy.returnHint)
            .font(.stHelper)
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? Color.stAccentSolid : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Calls `onClose` when the window holding this view closes. The main window can stay retained
/// after closing (AppWindowCoordinator), so its search must be reset explicitly (#3482 §3.4).
struct SettingsWindowCloseObserver: NSViewRepresentable {
  let onClose: @MainActor () -> Void

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onClose = onClose
    DispatchQueue.main.async { context.coordinator.observe(nsView.window) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    var onClose: @MainActor () -> Void = {}
    private weak var window: NSWindow?
    // Written only on the main actor; read once more by deinit to remove the observer.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    func observe(_ window: NSWindow?) {
      guard let window, window !== self.window else { return }
      if let token { NotificationCenter.default.removeObserver(token) }
      self.window = window
      token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.onClose() }
      }
    }

    deinit {
      if let token { NotificationCenter.default.removeObserver(token) }
    }
  }
}

extension View {
  /// While the search dropdown is open the page and sidebar stay mounted and look the same, but
  /// cannot be clicked or reached by VoiceOver (#3482 §3.4); drafts and local state survive.
  func searchPanelBlocksBackground(_ isOpen: Bool) -> some View {
    allowsHitTesting(!isOpen).accessibilityHidden(isOpen)
  }
}

extension FocusedValues {
  /// The focused main window's "Find Settings" action (#3482 §3.3): focus its search field and
  /// show a retained search. Nil when no main window is focused, so the command is disabled.
  @Entry var settingsFind: (@MainActor () -> Void)?
}

/// Edit › Find Settings (Command-F), routed to the focused main window (#3482 §3.3).
package struct FindSettingsCommand: Commands {
  @FocusedValue(\.settingsFind) private var find

  package init() {}

  package var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button(String(localized: SettingsSearchCopy.findSettings)) { find?() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(find == nil)
    }
  }
}
