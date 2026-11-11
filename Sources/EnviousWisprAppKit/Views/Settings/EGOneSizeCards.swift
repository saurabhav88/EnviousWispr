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

  static func useTitle(_ size: EGOneSize) -> String {
    String(
      localized: "Use \(title(size))",
      comment:
        "AI Polish, EG-1 size card: button that makes this downloaded size the one in use. %@ is the size's name, such as EG-1 Mini."
    )
  }

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

  /// "This Mac: 64 GB memory". Macs report whole binary gigabytes.
  static func thisMac(physicalMemoryBytes: UInt64) -> String {
    let gigabytes = Int((Double(physicalMemoryBytes) / Double(1 << 30)).rounded())
    return String(
      localized: "This Mac: \(gigabytes) GB memory",
      comment: "AI Polish, above the EG-1 size cards. %lld is the Mac's installed memory in GB.")
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
/// nothing. Download and Cancel reach the size's own runtime through `EGOneSizeActions`; Use
/// changes the preference; Remove follows plan §3.1.1 S9.
struct EGOneSizeCards: View {
  let cards: [EGOneSizeCard]
  let measuredOn: String
  let perform: (EGOneSizeCard.Action, EGOneSize) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // One height for the row: the tallest card's.
      HStack(alignment: .top, spacing: 12) {
        ForEach(cards) { card in
          EGOneSizeCardView(card: card) { perform($0, card.size) }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if hasFacts {
        Divider().overlay(Color.stDivider)
        facts
      }
      Spacer(minLength: 0)
      Divider().overlay(Color.stDivider)
      footer
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color.stInputBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .strokeBorder(
          card.isSelected ? Color.stAccentSolid : Color.stDivider,
          lineWidth: card.isSelected ? 1.5 : 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: EGOneSizeCardCopy.title(card.size)))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: EGOneSizeCardCopy.title(card.size))
          .font(.stRowTitle)
          .foregroundStyle(Color.stTextPrimary)
        Spacer(minLength: 6)
        if card.isRecommended {
          Text(EGOneSizeCardCopy.bestForThisMac)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.stAccentSolid))
        }
      }
      Text(EGOneSizeCardCopy.tagline(card.size))
        .font(.stHelper)
        .fontWeight(.semibold)
        .foregroundStyle(Color.stAccent)
      Text(EGOneSizeCardCopy.summary(card.size))
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
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
      Text(label).font(.stHelper).foregroundStyle(Color.stTextSecondary)
      Spacer(minLength: 6)
      Text(value).font(.stHelper).fontWeight(.semibold).monospacedDigit().foregroundStyle(tint)
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
    let tint = memory.isTight ? Color.stWarning : Color.stTextPrimary
    let used = Measurement(
      value: Double(memory.bytes) / 1e9, unit: UnitInformationStorage.gigabytes
    )
    .value.formatted(.number.precision(.fractionLength(1)))
    let mac = Int((Double(memory.macBytes) / Double(1 << 30)).rounded())
    return VStack(alignment: .leading, spacing: 6) {
      factRow(
        String(localized: "Memory", comment: "AI Polish, EG-1 size card: memory the size uses."),
        value: String(
          localized: "\(used) of \(mac) GB",
          comment:
            "AI Polish, EG-1 size card: memory the size uses, of the Mac's memory. First %@ is a number such as 4.9, then %lld the Mac's GB."
        ),
        mark: memory.isTight
          ? nil
          : (card.isLightest
            ? String(
              localized: "lightest",
              comment: "AI Polish, EG-1 size card: marks the size that uses the least memory.")
            : nil),
        tint: tint)
      if memory.isTight {
        Text(
          "Tight on this Mac",
          comment: "AI Polish, EG-1 size card: the size needs more than half of the Mac's memory."
        )
        .font(.stRowHelper)
        .foregroundStyle(Color.stWarning)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.stDivider)
          Capsule().fill(memory.isTight ? Color.stWarning : Color.stAccent)
            .frame(width: proxy.size.width * memory.fraction)
        }
      }
      .frame(height: 4)
      .accessibilityHidden(true)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if card.isInUse {
          Image(systemName: "checkmark.circle").foregroundStyle(Color.stSuccess)
            .accessibilityHidden(true)
        }
        Text(EGOneSizeCardCopy.status(card))
          .font(.stHelper)
          .fontWeight(card.isInUse ? .semibold : .regular)
          .foregroundStyle(card.isInUse ? Color.stSuccess : Color.stTextSecondary)
        Spacer(minLength: 6)
        Text(verbatim: EGOneSizeCardCopy.versionAndSize(card))
          .font(.stHelper)
          .foregroundStyle(Color.stTextTertiary)
      }
      if case .downloading(let fraction) = card.state {
        PolishProgressBar(fraction: fraction)
      }
      HStack(spacing: 10) {
        ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
          if action == .remove { Spacer(minLength: 6) }
          button(action)
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
      SettingsActionButton(
        verbatimTitle: EGOneSizeCardCopy.useTitle(card.size), isEnabled: true
      ) { perform(.use) }
      .settingsMapRegistration(.exempt(.egOneOtherSizeCard))
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
