import AppKit
import EnviousWisprPostProcessing
import SwiftUI

/// The Blocked words window (#5006): every fix the user said no to twice, as
/// heard → fixed, with a local search, Remove (one Undo, for the latest
/// Remove) and Forget all behind an in-window confirm. The list, its count and
/// every store decision belong to `CustomWordsCoordinator` and `LearnMemory`;
/// this view only shows them and keeps the one Undo token.
struct BlockedWordsSheet: View {
  @Environment(CustomWordsCoordinator.self) private var customWords
  @Environment(\.dismiss) private var dismiss

  private typealias Copy = LearnFromEditsSettingsPresentation

  @State private var searchText = ""
  @FocusState private var searchFocused: Bool
  /// What the latest Remove took away; Undo puts exactly that back. Command-Z
  /// reaches it only while the search field is not being edited, so typing
  /// keeps its own text undo.
  @State private var undoToken: LearnMemory.UnblockToken?
  @State private var undoWord = ""
  @State private var note: LocalizedStringResource?
  @State private var confirmingForget = false
  /// Moves keyboard focus to the next Remove after a Remove.
  @FocusState private var focusedRow: String?

  private static let inset = DesignSpacing.xxl

  private var shown: [LearnMemory.BlockedPair] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return customWords.blockedPairs }
    return customWords.blockedPairs.filter {
      $0.heard.localizedCaseInsensitiveContains(query)
        || $0.fixed.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      Divider().overlay(Color.stDivider)
      header
      list
      Divider().overlay(Color.stDivider)
      if confirmingForget { confirm } else { footer }
    }
    .frame(minWidth: 460, minHeight: 420)
    .background(Color.stPageBg)
    .onAppear {
      customWords.refreshLearnMemorySummary()
      searchFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      customWords.refreshLearnMemorySummary()
    }
    .onExitCommand {
      if confirmingForget { confirmingForget = false } else { dismiss() }
    }
  }

  private var titleBar: some View {
    HStack(spacing: DesignSpacing.md) {
      Text(Copy.blockedTitle).font(.stRowTitle).foregroundStyle(Color.stTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: DesignSpacing.xl)
      Button {
        dismiss()
      } label: {
        EnviousCloseGlyph()
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(Copy.blockedClose))
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, DesignSpacing.xl)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      Text(Copy.blockedIntro).settingsReadingCopy()
        .fixedSize(horizontal: false, vertical: true)
      TextField(String(localized: Copy.blockedSearch), text: $searchText)
        .focused($searchFocused)
        .settingsFieldChrome(focused: $searchFocused)
        .accessibilityLabel(Text(Copy.blockedSearch))
    }
    .padding(Self.inset)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        let rows = shown
        if customWords.blockedPairs.isEmpty {
          emptyLine(String(localized: Copy.nothingBlocked))
        } else if rows.isEmpty {
          emptyLine(Copy.noMatch(searchText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        ForEach(rows) { pair in
          row(pair, next: rows.after(pair))
        }
      }
      .padding(.horizontal, Self.inset)
    }
  }

  private func emptyLine(_ text: String) -> some View {
    Text(text).font(.stHelper).foregroundStyle(.stTextSecondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, DesignSpacing.xxxl)
  }

  private func row(_ pair: LearnMemory.BlockedPair, next: LearnMemory.BlockedPair?) -> some View {
    VStack(spacing: 0) {
      Divider().overlay(Color.stDivider)
      HStack(spacing: DesignSpacing.lg) {
        HStack(spacing: DesignSpacing.sm) {
          Text(verbatim: pair.heard).foregroundStyle(.stTextSecondary)
          Image(systemName: "arrow.right").foregroundStyle(.stTextTertiary)
            .accessibilityHidden(true)
          Text(verbatim: pair.fixed).foregroundStyle(.stTextPrimary)
        }
        .font(.stBody)
        .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          remove(pair, next: next)
        } label: {
          EnviousButtonLabel(Copy.removeTitle)
        }
        .settingsButton(isEnabled: true)
        .focused($focusedRow, equals: pair.key)
        .accessibilityLabel(Copy.removeAccessibility(heard: pair.heard, fixed: pair.fixed))
      }
      .padding(.vertical, DesignSpacing.md)
    }
  }

  private var footer: some View {
    HStack(spacing: DesignSpacing.lg) {
      // A failure note sits beside Undo while the token is still valid, so a
      // failed Undo (or a failed later Remove) can still be retried.
      if let note {
        Text(note).font(.stHelper).foregroundStyle(.stTextSecondary)
      } else if undoToken != nil {
        Text(Copy.canLearnAgain(undoWord)).font(.stHelper).foregroundStyle(.stTextSecondary)
      }
      if undoToken != nil {
        Button {
          undo()
        } label: {
          EnviousButtonLabel(Copy.undoTitle)
        }
        .settingsButton(
          .quiet, isEnabled: true, shortcut: searchFocused ? nil : KeyboardShortcut("z", modifiers: .command))
      }
      if customWords.learnMemoryForgetFailed {
        Text(Copy.forgetFailed).font(.stHelper).foregroundStyle(.stTextSecondary)
      }
      Spacer(minLength: DesignSpacing.md)
      Button(role: .destructive) {
        confirmingForget = true
      } label: {
        EnviousButtonLabel(Copy.forgetAllTitle)
      }
      .settingsButton(isEnabled: customWords.learnMemoryStored)
      Button {
        dismiss()
      } label: {
        EnviousButtonLabel(Copy.doneTitle)
      }
      .settingsButton(.filled, isEnabled: true, shortcut: .defaultAction)
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, DesignSpacing.xl)
  }

  private var confirm: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      Text(Copy.forgetAlertTitle).font(.stRowLabel).foregroundStyle(.stTextPrimary)
      Text(Copy.forgetAlertMessage).settingsReadingCopy()
      HStack(spacing: DesignSpacing.lg) {
        Spacer(minLength: 0)
        Button {
          confirmingForget = false
        } label: {
          EnviousButtonLabel(verbatim: Copy.cancelTitle)
        }
        .settingsButton(.quiet, isEnabled: true)
        Button(role: .destructive) {
          forgetAll()
        } label: {
          EnviousButtonLabel(verbatim: Copy.forgetConfirm)
        }
        .settingsButton(isEnabled: true)
      }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, DesignSpacing.xl)
    .background(Color.stWarningSoft)
  }

  // MARK: - Actions

  private func remove(_ pair: LearnMemory.BlockedPair, next: LearnMemory.BlockedPair?) {
    switch customWords.unblock(pair) {
    case .removed(let token):
      undoToken = token
      undoWord = pair.fixed
      note = nil
    case .alreadyGone:
      note = nil
    case .notRemembered:
      note = Copy.removeFailed
      return
    }
    // The list was just refreshed: a neighbour another app copy removed meanwhile is gone.
    if let next, customWords.blockedPairs.contains(next) {
      focusedRow = next.key
    } else {
      searchFocused = true
    }
  }

  private func undo() {
    guard let token = undoToken else { return }
    switch customWords.undoUnblock(token) {
    case .restored:
      undoToken = nil
      note = nil
    case .expired:
      undoToken = nil
      note = Copy.undoExpired
    case .notRemembered:
      note = Copy.undoFailed
    }
  }

  private func forgetAll() {
    confirmingForget = false
    customWords.forgetLearnMemory()
    customWords.refreshLearnMemorySummary()
    if !customWords.learnMemoryForgetFailed {
      undoToken = nil
      note = nil
    }
  }
}

extension Array where Element: Identifiable {
  /// The element after `element`, else the one before it, for focus after a removal.
  fileprivate func after(_ element: Element) -> Element? {
    guard let index = firstIndex(where: { $0.id == element.id }) else { return nil }
    if index + 1 < count { return self[index + 1] }
    return index > 0 ? self[index - 1] : nil
  }
}
