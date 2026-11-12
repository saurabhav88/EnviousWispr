import EnviousWisprCore
import EnviousWisprLocalPolish
import SwiftUI

/// What the size cards need that does not change while the app runs: the measured facts and,
/// per size, the download's size and the version label. Built once at launch from the bundled
/// manifests (`WisprBootstrapper`).
struct EGOneSizeCatalog: Equatable, Sendable {
  var facts: EGOneSizeFacts = .none
  var downloadBytes: [EGOneSize: Int64] = [:]
  var displayVersions: [EGOneSize: String] = [:]
}

private struct EGOneSizeCatalogKey: EnvironmentKey {
  static let defaultValue = EGOneSizeCatalog()
}

extension EnvironmentValues {
  var egOneSizeCatalog: EGOneSizeCatalog {
    get { self[EGOneSizeCatalogKey.self] }
    set { self[EGOneSizeCatalogKey.self] = newValue }
  }
}

/// The words on a size card. Values, so tests read exactly what the cards show.
enum EGOneSizeCardCopy {
  static func title(_ size: EGOneSize) -> String {
    switch size {
    // Product names: not translated.
    case .full: "EG-1"
    case .mini: "EG-1 Mini"
    case .micro: "EG-1 Micro"
    }
  }

  static func tagline(_ size: EGOneSize) -> String {
    switch size {
    case .full:
      String(localized: "Best quality", comment: "AI Polish, EG-1 size card: the largest size.")
    case .mini:
      String(
        localized: "Fast all-rounder", comment: "AI Polish, EG-1 size card: the middle size.")
    case .micro:
      String(
        localized: "Smallest and fastest",
        comment: "AI Polish, EG-1 size card: the smallest size.")
    }
  }

  static func summary(_ size: EGOneSize) -> String {
    switch size {
    case .full:
      String(
        localized:
          "The most accurate. Pick it for long dictations, email and languages other than English.",
        comment: "AI Polish, EG-1 size card: what the largest size is for.")
    case .mini:
      String(
        localized:
          "Close to EG-1 on short dictation, at about half the memory. Weaker on long dictations.",
        comment: "AI Polish, EG-1 size card: what the middle size is for.")
    case .micro:
      String(
        localized:
          "The lightest. Good for short English dictation on Macs with little memory to spare. Weaker in other languages.",
        comment: "AI Polish, EG-1 size card: what the smallest size is for.")
    }
  }

  static let chooseASize = String(
    localized: "· choose a size",
    comment:
      "AI Polish: after the name EG-1 above its three size cards, as in \"EG-1 · choose a size\".")

  static let bestForThisMac = String(
    localized: "Best for this Mac",
    comment: "AI Polish, EG-1 size card: the pill on the size recommended for this Mac's memory.")

  /// "V1.3 · 4.7 GB", or the part that exists.
  static func versionAndSize(_ card: EGOneSizeCard) -> String {
    [
      card.displayVersion.map { "V\($0)" },
      card.downloadBytes.map { byteCount($0) },
    ].compactMap { $0 }.joined(separator: " · ")
  }

  /// Decimal units, one decimal for gigabytes: 4.7 GB, 2.1 GB, 805 MB.
  static func byteCount(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 {
      let gigabytes = (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(1)))
      return String(
        localized: "\(gigabytes) GB",
        comment: "A file size in gigabytes. %@ is a number such as 4.7.")
    }
    let megabytes = Int((Double(bytes) / 1e6).rounded())
    return String(
      localized: "\(megabytes) MB", comment: "A file size in megabytes. %lld is a whole number.")
  }

  /// "This Mac: 64 GB memory", and "· 48.1 GB in use" when the live figure is known (#4525).
  /// Macs report whole binary gigabytes.
  static func thisMac(physicalMemoryBytes: UInt64, usedBytes: UInt64?) -> String {
    let gigabytes = Int((Double(physicalMemoryBytes) / Double(1 << 30)).rounded())
    guard let usedBytes else {
      return String(
        localized: "This Mac: \(gigabytes) GB memory",
        comment: "AI Polish, above the EG-1 size cards. %lld is the Mac's installed memory in GB.")
    }
    let used = memoryGigabytes(usedBytes)
    return String(
      localized: "This Mac: \(gigabytes) GB memory · \(used) GB in use",
      comment:
        "AI Polish, above the EG-1 size cards. %1$lld is the Mac's installed memory in GB; %2$@ is the memory in use right now, such as 48.1."
    )
  }

  /// #4525: memory in binary gigabytes with one decimal, the unit Activity Monitor shows (5.5,
  /// 48.1). The decimal mark follows the Mac's region.
  static func memoryGigabytes(_ bytes: UInt64, locale: Locale = .current) -> String {
    (Double(bytes) / Double(1 << 30)).formatted(
      .number.precision(.fractionLength(1)).locale(locale))
  }

  static let tightOnThisMac = String(
    localized: "Tight on this Mac",
    comment: "AI Polish, EG-1 size card: the size needs more than half of the Mac's memory.")

  static let wontFitRightNow = String(
    localized: "Won't fit right now",
    comment:
      "AI Polish, EG-1 size card: the memory in use now plus this size is more than 90% of the Mac's memory.")

  static let startingIncludedInUse = String(
    localized: "Starting, included in use",
    comment:
      "AI Polish, EG-1 size card: this size is starting, so its memory is already part of the memory in use.")

  static let runningIncludedInUse = String(
    localized: "Running now, included in use",
    comment:
      "AI Polish, EG-1 size card: this size is running, so its memory is already part of the memory in use.")

  /// What VoiceOver reads for the memory row: the size's need and the Mac's memory in use now,
  /// as two separate sentences, then the warning or running note shown on the card.
  static func memoryAccessibilityValue(_ memory: EGOneSizeCard.Memory) -> String {
    let need = memoryGigabytes(UInt64(max(0, memory.bytes)))
    var parts = [
      String(
        localized: "Needs about \(need) GB.",
        comment: "AI Polish, EG-1 size card, VoiceOver: the memory this size needs, such as 5.5.")
    ]
    if let used = memory.systemUsedBytes {
      let usedText = memoryGigabytes(used)
      let mac = Int((Double(memory.macBytes) / Double(1 << 30)).rounded())
      parts.append(
        String(
          localized: "Mac is using \(usedText) GB of \(mac) GB now.",
          comment:
            "AI Polish, EG-1 size card, VoiceOver: memory in use now (%1$@, such as 48.1) of the Mac's memory (%2$lld GB)."
        ))
    }
    if let note = memoryNote(memory) { parts.append(note) }
    return parts.joined(separator: " ")
  }

  /// The line under the memory figure: the warning, or for a starting or running size with a
  /// live figure, that its memory is already counted. Nil when there is nothing to say.
  static func memoryNote(_ memory: EGOneSizeCard.Memory) -> String? {
    switch memory.warning {
    case .tight: return tightOnThisMac
    case .wontFitNow: return wontFitRightNow
    case nil: break
    }
    guard memory.systemUsedBytes != nil else { return nil }
    switch memory.activity {
    case .starting: return startingIncludedInUse
    case .ready: return runningIncludedInUse
    case .inactive: return nil
    }
  }

  static func status(_ card: EGOneSizeCard) -> String {
    switch card.state {
    case .notDownloaded:
      return String(
        localized: "Not downloaded", comment: "AI Polish, EG-1 size card: status line.")
    case .downloading(let fraction):
      let percent = Int((max(0, min(1, fraction)) * 100).rounded())
      return String(
        localized: "Downloading · \(percent)%",
        comment: "AI Polish, EG-1 size card: status line. %lld is the percent done.")
    case .verifying:
      return String(
        localized: "Checking the download",
        comment: "AI Polish, EG-1 size card: status line after the bytes arrived.")
    case .paused, .updatePaused:
      return String(
        localized: "Download paused", comment: "AI Polish, EG-1 size card: status line.")
    case .failed:
      return String(
        localized: "Download did not finish",
        comment: "AI Polish, EG-1 size card: status line after a failed download.")
    case .installed:
      if card.isInUse {
        return String(
          localized: "In use", comment: "AI Polish, EG-1 size card: this size polishes now.")
      }
      return String(
        localized: "Installed", comment: "AI Polish, EG-1 size card: downloaded, not in use.")
    }
  }
}

/// #4473: the three EG-1 size cards (founder's design, 2026-11). One row of cards; the size in
/// use is outlined. Every card is usable on every Mac: the "Best for this Mac" pill is advice.
///
/// The view draws `EGOneSizeCardPresenter`'s values and forwards button presses; it decides
/// nothing. A click anywhere on a card chooses that size, like the speech engine cards (founder
/// 2026-11-11); there is no separate Use button. Download and Cancel reach the size's own
/// runtime through `EGOneSizeActions`; Remove follows plan §3.1.1 S9.
struct EGOneSizeCards: View {
  let cards: [EGOneSizeCard]
  let measuredOn: String
  let perform: (EGOneSizeCard.Action, EGOneSize) -> Void

  static let cardSpacing: CGFloat = 12
  /// The narrowest a card may be in the row before the cards stack.
  static let cardMinimumWidth: CGFloat = 230
  static func rowMinimumWidth(_ count: Int) -> CGFloat {
    CGFloat(count) * cardMinimumWidth + CGFloat(max(0, count - 1)) * cardSpacing
  }

  /// Side by side at `width`, or one under the other.
  static func isStacked(width: CGFloat, count: Int) -> Bool {
    // 0 = not measured yet: draw the row, the common case, rather than flash a column.
    width > 0 && width < rowMinimumWidth(count)
  }

  /// The width the cards have, read from the layout (see `TranscribeFileView.polishStep` for
  /// why a background `GeometryReader` and not `onGeometryChange`, which is macOS 15).
  @State private var availableWidth: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Side by side while each card keeps a readable width; one under the other in a narrow
      // window, so a card is never squeezed until its pill, status and buttons break mid-word
      // (founder 2026-11-11). One set of card views in a switched layout, never two
      // alternatives: each card registers its buttons with the Settings Map once.
      let layout =
        Self.isStacked(width: availableWidth, count: cards.count)
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.cardSpacing))
        : AnyLayout(HStackLayout(alignment: .top, spacing: Self.cardSpacing))
      layout {
        ForEach(cards) { card in
          EGOneSizeCardView(card: card) { perform($0, card.size) }
        }
      }
      // In the row: one height for all cards, the tallest card's.
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear { availableWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in availableWidth = width }
        })
      if cards.contains(where: { $0.polishMilliseconds != nil || $0.memory != nil }),
        !measuredOn.isEmpty
      {
        Text(
          String(
            localized: "Polish time is for a short dictation, measured on an \(measuredOn).",
            comment:
              "AI Polish, footnote under the EG-1 size cards. %@ is a Mac model, such as Apple M5 Max."
          )
        )
        .font(.stRowHelper)
        .foregroundStyle(Color.stTextTertiary)
      }
    }
    .padding(.horizontal, PolishSectionLayout.rowPaddingH)
    .padding(.vertical, PolishSectionLayout.rowPaddingV)
  }
}

private struct EGOneSizeCardView: View {
  let card: EGOneSizeCard
  let perform: (EGOneSizeCard.Action) -> Void

  private static let radius: CGFloat = 10
  /// Height of `actionArea` as drawn over the card's bottom edge.
  @State private var actionAreaHeight: CGFloat = 0

  var body: some View {
    // The selection area is the WHOLE card (founder 2026-11-11: a bottom strip that does not
    // answer a click looks broken). The card's own buttons are laid over its bottom edge as
    // siblings, never children, so a press on Download or Remove does not also choose; the
    // label keeps their room with a hidden copy, and every other point of the card chooses.
    Button {
      perform(.use)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        header
        if hasFacts {
          Divider().overlay(Color.stDivider)
          facts
        }
        Spacer(minLength: 0)
        Divider().overlay(Color.stDivider)
        statusLine
        if hasActionArea {
          // The room the buttons laid over the bottom edge take. Their measured height, not a
          // hidden copy: a copy would register its buttons with the Settings Map a second time.
          Color.clear.frame(height: actionAreaHeight).accessibilityHidden(true)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // On the label, inside the hit region's frame, so the tint and the target are one
      // rectangle (the same arrangement as `EngineCard`).
      .settingsHoverRow(cornerRadius: Self.radius)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The combined children are the label: VoiceOver reads everything the card shows, facts
    // and warnings included, with no second copy of it to keep in step.
    .accessibilityElement(children: .combine)
    .accessibilityValue(card.isSelected ? SettingsCopy.selectedValue : "")
    .accessibilityAddTraits(card.isSelected ? [.isButton, .isSelected] : .isButton)
    .overlay(alignment: .bottom) {
      if hasActionArea {
        actionArea
          .background(
            GeometryReader { geo in
              Color.clear
                .onAppear { actionAreaHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, height in actionAreaHeight = height }
            }
          )
          .padding(14)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color.stInputBg)
    )
    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .strokeBorder(
          card.isSelected ? Color.stAccentSolid : Color.stDivider,
          lineWidth: card.isSelected ? 1.5 : 1
        )
        .allowsHitTesting(false)
    )
    .animation(.easeInOut(duration: 0.15), value: card.isSelected)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: EGOneSizeCardCopy.title(card.size)))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      // The pill is one line always; when the title and the pill do not fit on one line (a
      // narrow card, a longer translation) the pill goes under the title.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          titleText
          Spacer(minLength: 6)
          if card.isRecommended { recommendedPill }
        }
        VStack(alignment: .leading, spacing: 6) {
          titleText
          if card.isRecommended { recommendedPill }
        }
      }
      Text(EGOneSizeCardCopy.tagline(card.size))
        .font(.stHelper)
        .fontWeight(.semibold)
        .foregroundStyle(Color.stAccent)
        .fixedSize(horizontal: false, vertical: true)
      Text(EGOneSizeCardCopy.summary(card.size))
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var titleText: some View {
    Text(verbatim: EGOneSizeCardCopy.title(card.size))
      .font(.stRowTitle)
      .foregroundStyle(Color.stTextPrimary)
      .lineLimit(1)
      .fixedSize()
  }

  private var recommendedPill: some View {
    Text(EGOneSizeCardCopy.bestForThisMac)
      .font(.stRowLabel)
      .foregroundStyle(Color.white)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.stAccentSolid))
  }

  private var hasFacts: Bool {
    card.englishPercent != nil || card.internationalPercent != nil
      || card.polishMilliseconds != nil || card.memory != nil
  }

  @ViewBuilder
  private var facts: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let percent = card.englishPercent {
        scoreRow(
          String(localized: "English", comment: "AI Polish, EG-1 size card: exam score row."),
          percent: percent)
      }
      if let percent = card.internationalPercent {
        scoreRow(
          String(
            localized: "International",
            comment: "AI Polish, EG-1 size card: exam score in languages other than English."),
          percent: percent)
      }
      if let milliseconds = card.polishMilliseconds {
        factRow(
          String(
            localized: "Polish time",
            comment: "AI Polish, EG-1 size card: how long the polish of a short dictation takes."
          ),
          value: String(
            localized: "\(milliseconds) ms",
            comment: "AI Polish, EG-1 size card: a time in milliseconds."),
          mark: card.isFastest
            ? String(
              localized: "fastest", comment: "AI Polish, EG-1 size card: marks the fastest size.")
            : nil)
      }
      if let memory = card.memory {
        memoryRow(memory)
      }
    }
  }

  private func factRow(_ label: String, value: String, mark: String?, tint: Color = .stTextPrimary)
    -> some View
  {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(label).font(.stHelper).foregroundStyle(Color.stTextSecondary).lineLimit(1)
      Spacer(minLength: 6)
      Text(value).font(.stHelper).fontWeight(.semibold).monospacedDigit().foregroundStyle(tint)
        .lineLimit(1).fixedSize()
      if let mark {
        Text(verbatim: "· \(mark)").font(.stHelper).foregroundStyle(Color.stSuccess)
      }
    }
  }

  private func scoreRow(_ label: String, percent: Int) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(label).font(.stHelper).foregroundStyle(Color.stTextSecondary)
      Spacer(minLength: 6)
      Text(verbatim: "\(percent)%")
        .font(.stHelper).fontWeight(.semibold).monospacedDigit()
        .foregroundStyle(Color.stTextPrimary)
      HStack(spacing: 3) {
        ForEach(0..<5, id: \.self) { index in
          Capsule()
            .fill(percent >= 60 + index * 8 ? Color.stAccent : Color.stDivider)
            .frame(width: 12, height: 4)
        }
      }
      .accessibilityHidden(true)
    }
  }

  private func memoryRow(_ memory: EGOneSizeCard.Memory) -> some View {
    let warned = memory.warning != nil
    let tint = warned ? Color.stWarning : Color.stTextPrimary
    let need = EGOneSizeCardCopy.memoryGigabytes(UInt64(max(0, memory.bytes)))
    let mac = Int((Double(memory.macBytes) / Double(1 << 30)).rounded())
    return VStack(alignment: .leading, spacing: 6) {
      factRow(
        String(localized: "Memory", comment: "AI Polish, EG-1 size card: memory the size uses."),
        value: String(
          localized: "\(need) of \(mac) GB",
          comment:
            "AI Polish, EG-1 size card: memory the size uses, of the Mac's memory. First %@ is a number such as 4.9, then %lld the Mac's GB."
        ),
        mark: warned
          ? nil
          : (card.isLightest
            ? String(
              localized: "lightest",
              comment: "AI Polish, EG-1 size card: marks the size that uses the least memory.")
            : nil),
        tint: tint)
      if let note = EGOneSizeCardCopy.memoryNote(memory) {
        Text(note)
          .font(.stRowHelper)
          .foregroundStyle(warned ? Color.stWarning : Color.stTextSecondary)
      }
      // #4525: gray = the Mac's memory in use now; purple (orange when warned) = this size,
      // after gray for a size that is not running. Decorative: VoiceOver reads the row's value.
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.stDivider)
          Capsule().fill(Color.stTextTertiary)
            .frame(width: proxy.size.width * memory.usedFraction)
          Capsule().fill(warned ? Color.stWarning : Color.stAccent)
            .frame(width: proxy.size.width * memory.peakFraction)
            .offset(x: proxy.size.width * memory.peakStart)
        }
      }
      .frame(height: 4)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      String(localized: "Memory", comment: "AI Polish, EG-1 size card: memory the size uses."))
    .accessibilityValue(EGOneSizeCardCopy.memoryAccessibilityValue(memory))
  }

  private var statusLine: some View {
    // One line when it fits; the version under the status when it does not. No piece breaks.
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        statusText
        Spacer(minLength: 6)
        versionText
      }
      VStack(alignment: .leading, spacing: 4) {
        statusText
        versionText
      }
    }
  }

  private var statusText: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if card.isInUse {
        Image(systemName: "checkmark.circle").foregroundStyle(Color.stSuccess)
          .accessibilityHidden(true)
      }
      Text(EGOneSizeCardCopy.status(card))
        .font(.stHelper)
        .fontWeight(card.isInUse ? .semibold : .regular)
        .foregroundStyle(card.isInUse ? Color.stSuccess : Color.stTextSecondary)
        .lineLimit(1)
    }
    .fixedSize()
  }

  private var versionText: some View {
    Text(verbatim: EGOneSizeCardCopy.versionAndSize(card))
      .font(.stHelper)
      .foregroundStyle(Color.stTextTertiary)
      .lineLimit(1)
      .fixedSize()
  }

  private var hasActionArea: Bool {
    if case .downloading = card.state { return true }
    return !card.actions.isEmpty
  }

  private var actionArea: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .downloading(let fraction) = card.state {
        PolishProgressBar(fraction: fraction)
      }
      HStack(spacing: 10) {
        ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
          if action == .remove { Spacer(minLength: 6) }
          button(action).fixedSize()
        }
        if !card.actions.contains(.remove) { Spacer(minLength: 0) }
      }
    }
  }

  /// A size that is not the one in use repeats the selected card's actions, and a Settings Map
  /// identity may be on screen once, so only the selected card's buttons carry one.
  private func registration(_ id: SettingsMapID) -> SettingsMapRegistration {
    card.isSelected ? .mapped(id) : .exempt(.egOneOtherSizeCard)
  }

  @ViewBuilder
  private func button(_ action: EGOneSizeCard.Action) -> some View {
    switch action {
    case .download:
      SettingsActionButton(
        verbatimTitle: SettingsMapRef.id(.localModelDownload).title, isEnabled: true,
        emphasis: card.isRecommended || card.isSelected ? .filled : .outlined,
        systemImage: "arrow.down.to.line"
      ) { perform(.download) }
      .settingsMapRegistration(registration(.localModelDownload))
    case .resume:
      SettingsActionButton(
        verbatimTitle: SettingsMapRef.id(.localModelResume).title, isEnabled: true
      ) { perform(.resume) }
      .settingsMapRegistration(registration(.localModelResume))
    case .resumeUpgrade:
      SettingsActionButton(
        verbatimTitle: SettingsMapRef.id(.localModelResumeUpgrade).title, isEnabled: true
      ) { perform(.resumeUpgrade) }
      .settingsMapRegistration(registration(.localModelResumeUpgrade))
    case .finishUpgrade:
      SettingsActionButton(
        verbatimTitle: SettingsMapRef.id(.localModelFinishUpgrade).title, isEnabled: true
      ) { perform(.finishUpgrade) }
      .settingsMapRegistration(registration(.localModelFinishUpgrade))
    case .tryAgain:
      SettingsActionButton(
        verbatimTitle: SettingsMapRef.id(.localModelTryAgain).title, isEnabled: true
      ) { perform(.tryAgain) }
      .settingsMapRegistration(registration(.localModelTryAgain))
    case .cancel:
      PolishTextAction(
        title: SettingsMapRef.id(.localModelCancel).title, tint: .stTextPrimary
      ) { perform(.cancel) }
      .settingsMapRegistration(registration(.localModelCancel))
    case .use:
      // Never in a card's button list: the card itself is the control that chooses a size.
      EmptyView()
    case .testLive:
      PolishIconButton(
        systemName: "arrow.clockwise",
        help: SettingsMapRef.dynamic(
          .localModelTestLive, .localEngine(name: EGOneSizeCardCopy.title(card.size))
        ).title
      ) { perform(.testLive) }
      .settingsMapRegistration(registration(.localModelTestLive))
    case .remove:
      PolishTextAction(
        title: String(
          localized: "Remove",
          comment: "AI Polish, EG-1 size card: deletes this size's download.")
      ) { perform(.remove) }
      .settingsMapRegistration(.exempt(.bundledModelRemove))
    }
  }
}

/// #4525: the window that actually hosts the EG-1 section, so the memory sampler skips its read
/// while that window is hidden (occluded or minimized). Never the key window: a Settings window
/// behind another app's window is hidden even when it is key.
@MainActor
final class EGOneHostWindow {
  weak var window: NSWindow?
  /// Called when the section attaches to a window, so the first read happens then rather than
  /// up to one interval later. Set by the sampler's owner while its task runs.
  var didAttach: (() -> Void)?

  /// Attached to a window that is on screen. No window (not yet attached, or detached) is not
  /// visible; a closed window that is kept around is not visible either.
  var isVisible: Bool { window?.occlusionState.contains(.visible) ?? false }
}

/// Records the hosting window into `EGOneHostWindow` as it attaches. Draws nothing.
struct EGOneHostWindowReader: NSViewRepresentable {
  let host: EGOneHostWindow

  func makeNSView(context: Context) -> NSView { Probe(host: host) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Probe: NSView {
    let host: EGOneHostWindow
    init(host: EGOneHostWindow) {
      self.host = host
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    // Never takes a click meant for the controls drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      host.window = window
      if window != nil { host.didAttach?() }
    }
  }
}
