import EnviousWisprCore
import SwiftUI

// The closing film's seven scenes (#4528 chunk E), after the approved mockup's `gen_film.py`.
// A scene is a pure function of one `FilmFrame`: every moving value is read from a
// `FilmScript` track at the frame's time, so a paused clock holds every element, and Reduce
// Motion draws each scene's final frame (`FilmFrame.still`).

/// What the person chose in Setup, shown in the first scene and the last (plain inputs, so the
/// film never reads the flow).
struct FilmSummary: Equatable, Sendable {
  /// The speech model's display name ("Parakeet Ultra").
  var speechModel: String
  /// The AI polish choice's display name, or nil when polish is off.
  var polish: String?
  /// The dictation key as words ("Right ⌥").
  var keyLabel: String
  /// The dictation key as it appears on a keycap ("⌥").
  var keyCap: String
}

/// One moment of one scene.
struct FilmFrame {
  let scene: FilmScene
  /// Seconds into the scene, held at the scene's length once it ends.
  let elapsed: Double
  /// Seconds into the scene without that hold, for the loops that keep going while the last
  /// scene waits (the breathing key). Frozen by Pause like everything else.
  let loop: Double
  /// Reduce Motion: draw the scene's final frame, with no moving parts.
  let still: Bool
  let summary: FilmSummary

  /// A track's value now; under Reduce Motion its final value.
  func value(_ track: FilmTrack) -> Double {
    still ? track.value(at: .greatestFiniteMagnitude) : track.value(at: elapsed)
  }

  /// An element the mockup keeps on screen under Reduce Motion (`data-rm="last"`).
  func kept(_ track: FilmTrack) -> Double { still ? 1 : value(track) }

  /// An element the mockup hides under Reduce Motion (`data-rm="hide"`): pointers, pills,
  /// held keys, the moving parts of a demonstration.
  func moving(_ track: FilmTrack) -> Double { still ? 0 : value(track) }
}

/// The stage for one frame.
struct FilmStage: View {
  let frame: FilmFrame

  var body: some View {
    Group {
      switch frame.scene {
      case .ready: FilmReadyScene(frame: frame)
      case .apps: FilmAppsScene(frame: frame)
      case .land: FilmLandScene(frame: frame)
      case .copied: FilmCopiedScene(frame: frame)
      case .learn: FilmLearnScene(frame: frame)
      case .more: FilmMoreScene(frame: frame)
      case .yours: FilmYoursScene(frame: frame)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: FilmMetrics.stageHeight)
    .background(Color.obSurface)
    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous))
    .accessibilityHidden(true)
  }
}

// MARK: - Captions

/// One caption: a title and a quieter line under it.
struct FilmCaptionLine {
  let title: String
  let subtitle: String
  let track: FilmTrack
}

enum FilmCaptions {
  static func lines(for scene: FilmScene, summary: FilmSummary) -> [FilmCaptionLine] {
    switch scene {
    case .ready:
      return [
        FilmCaptionLine(
          title: String(
            localized: "Congratulations! You are all set.",
            comment: "Closing film, first scene title after Setup finishes."),
          subtitle: String(
            localized: "Here is a quick refresher.",
            comment: "Closing film, first scene: the film that follows recaps how to dictate."),
          track: FilmScript.Captions.single)
      ]
    case .apps:
      return [
        FilmCaptionLine(
          title: String(
            localized: "Works in any app with a text box.",
            comment: "Closing film scene title: dictation works in every app."),
          subtitle: String(
            localized: "Email, chat, docs, code and more.",
            comment: "Closing film scene line under 'Works in any app with a text box.'"),
          track: FilmScript.Captions.single)
      ]
    case .land:
      let t = FilmScript.Captions.land
      return [
        FilmCaptionLine(
          title: String(
            localized: "Hold your key and talk.",
            comment: "Closing film caption: hold the dictation key while speaking."),
          subtitle: String(
            localized: "The pill shows EnviousWispr is listening.",
            comment: "Closing film caption under 'Hold your key and talk.'"),
          track: t[0]),
        FilmCaptionLine(
          title: String(
            localized: "Click away if you need to.",
            comment: "Closing film caption: you may click another window while dictating."),
          subtitle: String(
            localized: "Keep talking. Your place is remembered.",
            comment: "Closing film caption under 'Click away if you need to.'"),
          track: t[1]),
        FilmCaptionLine(
          title: String(
            localized: "Your words land where you started.",
            comment: "Closing film caption: text is pasted in the window where dictation began."),
          subtitle: String(
            localized: "EnviousWispr brings Mail back and pastes.",
            comment: "Closing film caption: the app returns to Mail, the starting app, and pastes."),
          track: t[2]),
      ]
    case .copied:
      let t = FilmScript.Captions.copied
      return [
        FilmCaptionLine(
          title: String(
            localized: "No text box selected?",
            comment: "Closing film caption: dictating with no text field focused."),
          subtitle: String(
            localized: "You clicked the desktop. Talk anyway.",
            comment: "Closing film caption under 'No text box selected?'"),
          track: t[0]),
        FilmCaptionLine(
          title: String(
            localized: "EnviousWispr copies your words.",
            comment: "Closing film caption: with no text field the text is put on the clipboard."),
          subtitle: String(
            localized: "The pill says: Copied. Press \u{2318}V to paste.",
            comment: "Closing film caption quoting the pill's own words. ⌘V is the paste shortcut."),
          track: t[1]),
        FilmCaptionLine(
          title: String(
            localized: "Press \u{2318}V wherever you want them.",
            comment: "Closing film caption: paste the copied words anywhere. ⌘V is paste."),
          subtitle: String(
            localized: "Anything you copied before comes back after.",
            comment: "Closing film caption: the earlier clipboard is restored after pasting."),
          track: t[2]),
      ]
    case .learn:
      let t = FilmScript.Captions.learn
      return [
        FilmCaptionLine(
          title: String(
            localized: "Fix a word once.",
            comment: "Closing film caption: correct a misheard word by hand one time."),
          subtitle: String(
            localized: "It heard \u{201C}twist\u{201D}. You type \u{201C}Tuist\u{201D}.",
            comment:
              "Closing film caption. 'twist' is what dictation heard; 'Tuist' (a developer tool name) is the right word. Keep both words as they are."
          ),
          track: t[0]),
        FilmCaptionLine(
          title: String(
            localized: "EnviousWispr learns it.",
            comment: "Closing film caption: the app adds the corrected word to its dictionary."),
          subtitle: String(
            localized: "Next time it writes Tuist. Use Undo if it learned wrong.",
            comment:
              "Closing film caption. 'Tuist' is a developer tool name; keep it. Undo is the pill's button."
          ),
          track: t[1]),
      ]
    case .more:
      return [
        FilmCaptionLine(
          title: String(
            localized: "And there is a lot more.",
            comment: "Closing film scene title before the features overview."),
          subtitle: String(
            localized: "Find all of it in Settings whenever you like.",
            comment: "Closing film scene line under 'And there is a lot more.'"),
          track: FilmScript.Captions.single)
      ]
    case .yours:
      return [
        FilmCaptionLine(
          title: String(
            localized: "Now it is your turn.",
            comment: "Closing film, last scene title: the person can start dictating."),
          subtitle: String(
            localized: "Hold \(summary.keyLabel) in any app and talk.",
            comment: "Closing film, last scene. %@ is the dictation key, for example 'Right ⌥'."),
          track: FilmScript.Captions.single)
      ]
    }
  }

  /// What VoiceOver reads for a scene (mockup `filmAria`): the stage is a picture, so the
  /// sentence carries the whole instruction.
  static func spoken(for scene: FilmScene, summary: FilmSummary) -> String {
    switch scene {
    case .ready:
      let polish =
        summary.polish
        ?? String(
          localized: "Off for now", comment: "Closing film: AI polish was skipped in Setup.")
      return String(
        localized:
          "Congratulations! You are all set. Speech model: \(summary.speechModel). AI polish: \(polish). Dictation key: \(summary.keyLabel).",
        comment:
          "VoiceOver for the closing film's first scene. The values are the speech model, the AI polish choice and the dictation key."
      )
    case .yours:
      return String(
        localized:
          "Now it is your turn. Hold \(summary.keyLabel) in any text box and talk. Look for EnviousWispr in your menu bar.",
        comment: "VoiceOver for the closing film's last scene. %@ is the dictation key.")
    case .apps:
      return String(
        localized: "Works in any app with a text box.",
        comment: "Closing film scene title: dictation works in every app.")
    case .land:
      return String(
        localized:
          "Hold your key and talk. Click away if you need to. Your words land where you started.",
        comment: "VoiceOver for the closing film's scene about words landing where you started.")
    case .copied:
      return String(
        localized:
          "No text box selected? EnviousWispr copies your words. Click any text box and press Command-V to paste them. Your earlier clipboard comes back after.",
        comment: "VoiceOver for the closing film's scene about copied words.")
    case .learn:
      return String(
        localized:
          "Fix a word once and EnviousWispr learns it. Use Undo if it learned the wrong word.",
        comment: "VoiceOver for the closing film's scene about learned words.")
    case .more:
      return String(
        localized: "And there is a lot more in Settings.",
        comment: "VoiceOver for the closing film's features scene.")
    }
  }
}

/// The caption box above the stage (mockup `filmcap`, 64 tall): lines rise in and away on
/// their tracks; Reduce Motion shows the last line only.
struct FilmCaption: View {
  let frame: FilmFrame

  var body: some View {
    let lines = FilmCaptions.lines(for: frame.scene, summary: frame.summary)
    ZStack {
      ForEach(lines.indices, id: \.self) { i in
        let shown =
          frame.still ? (i == lines.count - 1 ? 1 : 0) : lines[i].track.value(at: frame.elapsed)
        VStack(spacing: DesignSpacing.xs) {
          Text(verbatim: lines[i].title)
            .font(.firstRunTitle)
            .foregroundStyle(Color.obTextPrimary)
          Text(verbatim: lines[i].subtitle)
            .font(.firstRunCaption)
            .foregroundStyle(Color.obTextSecondary)
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .opacity(shown)
        .offset(y: 10 * (1 - shown))
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: FilmCaption.height)
    .accessibilityHidden(true)
  }

  static let height: CGFloat = 64
}

// MARK: - Scenes

/// READY: the person's own setup, three rows with checks.
struct FilmReadyScene: View {
  let frame: FilmFrame

  var body: some View {
    let s = frame.summary
    let rows: [(String, String, String)] = [
      (
        "mic",
        String(localized: "Speech model", comment: "Closing film summary row label."),
        s.speechModel
      ),
      (
        "sparkles",
        String(localized: "AI polish", comment: "Closing film summary row label."),
        s.polish
          ?? String(
            localized: "Off for now", comment: "Closing film: AI polish was skipped in Setup.")
      ),
      (
        "keyboard",
        String(localized: "Dictation key", comment: "Closing film summary row label."),
        s.keyLabel
      ),
    ]
    VStack(spacing: DesignSpacing.md) {
      ForEach(rows.indices, id: \.self) { i in
        let shown = frame.value(FilmScript.Ready.row(i))
        HStack(spacing: DesignSpacing.xl) {
          Image(systemName: rows[i].0)
            .font(.firstRunBody)
            .foregroundStyle(Color.obAccent)
            .frame(width: FilmReadyScene.tile, height: FilmReadyScene.tile)
            .background(
              RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .fill(Color.firstRunAccentSoft))
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: rows[i].1).font(.obCaption).foregroundStyle(Color.obTextSecondary)
            Text(verbatim: rows[i].2).font(.firstRunLabel).foregroundStyle(Color.obTextPrimary)
          }
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "checkmark.circle.fill")
            .font(.firstRunSay)
            .foregroundStyle(Color.white, Color.obSuccess)
        }
        .padding(.vertical, DesignSpacing.lg)
        .padding(.horizontal, DesignSpacing.xl)
        .frame(width: FilmReadyScene.rowWidth)
        .background(
          RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obCardBg)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
            .strokeBorder(Color.firstRunRule, lineWidth: 1)
        )
        .opacity(shown)
        .offset(y: 8 * (1 - shown))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  static let tile: CGFloat = 32
  static let rowWidth: CGFloat = 300
}

/// APPS: a wall of apps drifting up; a text box slides in; the pill appears beside it.
struct FilmAppsScene: View {
  let frame: FilmFrame

  /// 18 real apps with their brands' own logos (SVGL), in wall order.
  static let logos = FilmAppLogo.all
  static let tile: CGFloat = 48
  static let columns = 6
  static let drift: CGFloat = 36

  var body: some View {
    let tiles = Self.logos + Self.logos.prefix(6)
    let drift = frame.still ? 0 : frame.value(FilmScript.Apps.drift)
    let box = frame.value(FilmScript.Apps.textBox)
    let pill = frame.value(FilmScript.Apps.pill)
    ZStack {
      // A plain grid, not a lazy one: 24 fixed tiles, all on stage, laid out once.
      Grid(horizontalSpacing: DesignSpacing.xl, verticalSpacing: DesignSpacing.xl) {
        ForEach(0..<(tiles.count / Self.columns), id: \.self) { row in
          GridRow {
            ForEach(0..<Self.columns, id: \.self) { column in
              let i = row * Self.columns + column
              FilmAppLogoView(logo: tiles[i], size: 24)
                .frame(width: Self.tile, height: Self.tile)
                .background(
                  RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                    .fill(Color.obCardBg)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                    .strokeBorder(Color.firstRunRule, lineWidth: 1))
            }
          }
        }
      }
      .padding(.top, DesignSpacing.xl + DesignSpacing.xxs)
      .offset(y: -Self.drift * drift)
      .frame(maxHeight: .infinity, alignment: .top)
      .mask(FilmEdgeFade(top: 0.12, bottom: 0.87))

      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Text("Any text box", comment: "Closing film: label on a sample text field.")
          .font(.firstRunEyebrow)
          .tracking(0.8)
          .textCase(.uppercase)
          .foregroundStyle(Color.firstRunTextTertiary)
        HStack(spacing: DesignSpacing.xxs) {
          Text("Start here", comment: "Closing film: sample text typed in a text field.")
            .font(.firstRunSay.weight(.regular))
            .foregroundStyle(Color.obTextPrimary)
          Rectangle().fill(Color.obAccent)
            .frame(width: 1.5, height: 18)
            .opacity(frame.still || FilmScript.Apps.caretVisible(at: frame.loop) ? 1 : 0)
        }
      }
      .padding(.vertical, DesignSpacing.xl + DesignSpacing.xxs)
      .padding(.horizontal, DesignSpacing.xxl)
      .frame(width: 320, height: 92, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous).fill(Color.obCardBg)
          .shadow(color: .black.opacity(0.14), radius: 15, y: 12)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous)
          .strokeBorder(Color.firstRunRule, lineWidth: 1)
      )
      .opacity(box)
      .offset(y: 40 * (1 - box))

      FilmRecordingPill(seconds: 0)
        .scaleEffect(0.65 + 0.35 * pill)
        .opacity(pill)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 34)
    }
  }
}

/// LAND: Mail in front; hold the key; click Slack; release; Mail comes back and the email lands.
struct FilmLandScene: View {
  let frame: FilmFrame
  typealias T = FilmScript.Land

  var body: some View {
    let mailActive = frame.value(T.mailActive)
    let mailFront = frame.value(T.mailFront) > 0.5
    let pointer = frame.value(T.pointer)
    FilmMacScreen(
      first: String(localized: "Mail", comment: "App name in the closing film (Apple Mail)."),
      second: String(localized: "Slack", comment: "App name in the closing film (Slack)."),
      secondShown: 1 - mailActive
    ) {
      ZStack(alignment: .topLeading) {
        FilmWindow(
          title: String(
            localized: "New Message", comment: "Mail window title in the closing film."),
          active: mailActive
        ) {
          mailBody
        }
        .frame(width: 236, height: 214)
        .offset(x: 18, y: 34)
        .zIndex(mailFront ? 3 : 1)

        FilmWindow(
          title: String(localized: "Slack", comment: "App name in the closing film (Slack)."),
          active: 1 - mailActive
        ) {
          FilmSlackBody()
        }
        .frame(width: 190, height: 150)
        .offset(x: 196, y: 64)
        .zIndex(2)

        FilmPointer(
          clickScale: frame.value(T.clickScale), clickOpacity: frame.value(T.clickOpacity)
        )
        .offset(x: 150 + 158 * pointer, y: 168 - 26 * pointer)
        .opacity(frame.still ? 0 : 1)
        .zIndex(7)

        FilmHeldKey(keyCap: frame.summary.keyCap, held: frame.value(T.keyHeld))
          .offset(x: 14, y: FilmMetrics.stageHeight - 50 - FilmMetrics.keyHeight)
          .zIndex(6)

        FilmScenePills(
          recording: frame.moving(T.pillOpacity), recordingRise: frame.value(T.pillRise),
          recordingSeconds: T.pillSeconds,
          processing: frame.moving(T.polishing),
          processingLabel: DictationNarrator.copy(for: .polishing),
          clockTime: frame.loop
        )
        .zIndex(8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var mailBody: some View {
    let lines: [String?] = [
      String(localized: "Hi Priya,", comment: "Closing film: first line of a sample email."),
      nil,
      String(
        localized: "Can we move our call to Thursday at 3 pm?",
        comment: "Closing film: sample email sentence, dictated."),
      nil,
      String(localized: "Thanks so much!", comment: "Closing film: sample email sign-off."),
    ]
    return VStack(alignment: .leading, spacing: 0) {
      FilmMailField(
        label: String(localized: "To:", comment: "Email field label in the closing film."),
        value: String(
          localized: "Priya", comment: "Sample email recipient name in the closing film."))
      FilmMailField(
        label: String(localized: "Subject:", comment: "Email field label in the closing film."),
        value: String(localized: "Our call", comment: "Sample email subject in the closing film."))
      VStack(alignment: .leading, spacing: 0) {
        ForEach(lines.indices, id: \.self) { i in
          let shown = frame.kept(T.line(i))
          if let line = lines[i] {
            Text(verbatim: line)
              .fixedSize(horizontal: false, vertical: true)
              .opacity(shown)
              .offset(y: 10 * (1 - shown))
          } else {
            Color.clear.frame(height: 7)
          }
        }
      }
      .font(.obCaption)
      .foregroundStyle(Color.obTextPrimary)
      .padding(.vertical, DesignSpacing.md)
      .padding(.horizontal, DesignSpacing.lg)
    }
  }
}

/// One header line of the sample email ("To: Priya").
struct FilmMailField: View {
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: DesignSpacing.xs) {
      Text(verbatim: label).foregroundStyle(Color.obTextSecondary)
      Text(verbatim: value).foregroundStyle(Color.obTextPrimary)
    }
    .font(.obCaptionSmall)
    .padding(.vertical, DesignSpacing.sm)
    .padding(.horizontal, DesignSpacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.firstRunRule).frame(height: 1) }
  }
}

/// Slack's window body: the aubergine sidebar and four message lines.
struct FilmSlackBody: View {
  var body: some View {
    HStack(spacing: 0) {
      Color.firstRunFilmSlack.frame(width: 38)
      VStack(alignment: .leading, spacing: 7) {
        ForEach([0.7, 0.92, 0.55, 0.8], id: \.self) { width in
          GeometryReader { geo in
            Capsule().fill(Color.firstRunRule)
              .frame(width: geo.size.width * width, height: 6)
          }
          .frame(height: 6)
        }
      }
      .padding(9)
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }
}

/// The pills along the bottom of the screen: the real recording pill, then the real
/// processing pill in the same place (mockup `HUD_REC`, `HUD_WORK`, 48 from the bottom).
struct FilmScenePills: View {
  var recording: Double
  var recordingRise: Double
  var recordingSeconds: TimeInterval
  var processing: Double
  var processingLabel: String
  var clockTime: Double

  var body: some View {
    ZStack(alignment: .bottom) {
      if recording > 0 {
        FilmRecordingPill(seconds: recordingSeconds)
          .opacity(recording)
          .offset(y: 8 * (1 - recordingRise))
      }
      if processing > 0 {
        FilmProcessingPill(label: processingLabel, clockTime: clockTime)
          .opacity(processing)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .padding(.bottom, 48)
  }
}

/// COPIED: no text box; the words wait as Copied; ⌘V in Notes; the old clipboard is back.
struct FilmCopiedScene: View {
  let frame: FilmFrame
  typealias T = FilmScript.Copied

  var body: some View {
    let finder = frame.value(T.finderActive)
    let pointer = frame.value(T.pointer)
    let notes = frame.kept(T.notes)
    let words = frame.kept(T.words)
    let row = frame.kept(T.clipboardRow)
    let keys = frame.moving(T.pasteKeysOpacity)
    let keysHeld = frame.value(T.pasteKeysHeld)
    FilmMacScreen(
      first: String(localized: "Finder", comment: "App name in the closing film (the Finder)."),
      second: String(localized: "Notes", comment: "App name in the closing film (Apple Notes)."),
      secondShown: 1 - finder
    ) {
      ZStack(alignment: .top) {
        FilmWindow(
          title: String(localized: "Notes", comment: "App name in the closing film (Apple Notes).")
        ) {
          HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignSpacing.sm) {
              Capsule().fill(Color.firstRunRule).frame(width: 52, height: 6)
              Capsule().fill(Color.firstRunRule).frame(width: 40, height: 6)
            }
            .padding(.vertical, DesignSpacing.md)
            .padding(.horizontal, DesignSpacing.sm)
            .frame(width: 72, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.obSurface)
            .overlay(alignment: .trailing) {
              Rectangle().fill(Color.firstRunRule).frame(width: 1)
            }
            Text("Call the bank about the card.", comment: "Closing film: sample dictated note.")
              .font(.firstRunCaption)
              .foregroundStyle(Color.obTextPrimary)
              .opacity(words)
              .offset(y: 10 * (1 - words))
              .padding(.vertical, DesignSpacing.lg)
              .padding(.horizontal, DesignSpacing.xl)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
        }
        .frame(width: 280, height: 132)
        .opacity(notes)
        .offset(y: 40 + 10 * (1 - notes))

        HStack(spacing: DesignSpacing.xs) {
          FilmKeyCap(label: "\u{2318}", held: keysHeld)
          FilmKeyCap(label: "V", held: keysHeld)
        }
        .opacity(keys)
        .offset(y: 182 + 6 * (1 - frame.value(T.pasteKeysRise)))
        .zIndex(6)

        HStack(spacing: DesignSpacing.sm) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.white, Color.obSuccess)
          Text(
            "Your earlier clipboard is back",
            comment: "Closing film: the clipboard from before the paste was restored.")
        }
        .font(.obCaption)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.vertical, DesignSpacing.xs + 1)
        .padding(.horizontal, DesignSpacing.lg)
        .background(Capsule().fill(Color.obCardBg))
        .overlay(Capsule().strokeBorder(Color.firstRunRule, lineWidth: 0.5))
        .opacity(row)
        .offset(y: 224 + 10 * (1 - row))
        .zIndex(6)

        ZStack(alignment: .topLeading) {
          FilmPointer(
            clickScale: frame.value(T.clickScale), clickOpacity: frame.value(T.clickOpacity)
          )
          .offset(x: 230 - 40 * pointer, y: 210 - 110 * pointer)
          .opacity(frame.still ? 0 : 1)

          FilmHeldKey(keyCap: frame.summary.keyCap, held: frame.value(T.keyHeld))
            .opacity(frame.moving(T.keyChip))
            .offset(x: 14, y: FilmMetrics.stageHeight - 50 - FilmMetrics.keyHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(7)

        FilmScenePills(
          recording: frame.moving(T.pillOpacity), recordingRise: frame.value(T.pillRise),
          recordingSeconds: T.pillSeconds,
          processing: frame.moving(T.toastOpacity),
          processingLabel: DictationNarrator.clipboardFallbackText,
          clockTime: frame.loop
        )
        .offset(y: 8 * (1 - frame.value(T.toastRise)) * (frame.value(T.toastOpacity) > 0 ? 1 : 0))
        .zIndex(8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}

/// LEARN: dictation heard "twist"; you type "Tuist" once; EnviousWispr learns it.
struct FilmLearnScene: View {
  let frame: FilmFrame
  typealias T = FilmScript.Learn

  /// Product words in the example (a developer tool's name and what dictation heard). They are
  /// examples, not sentences, and stay as they are in every language.
  static let heard = "twist"
  static let word = "Tuist"

  var body: some View {
    let selected = frame.still ? 0 : frame.value(T.selected)
    let misheard = frame.kept(T.misheard)
    let fix = frame.kept(T.fix)
    let pill = frame.kept(T.pillOpacity)
    let next = frame.kept(T.nextTime)
    FilmMacScreen(
      first: String(localized: "Slack", comment: "App name in the closing film (Slack).")
    ) {
      ZStack(alignment: .top) {
        FilmWindow(title: "Slack \u{00B7} #ios") {
          HStack(spacing: DesignSpacing.xs) {
            Text(
              "Run", comment: "Closing film: first word of 'Run Tuist generate before you build.'")
            Text(verbatim: Self.heard)
              .foregroundStyle(misheard > 0.5 ? Color.firstRunFilmMistakeText : Color.obTextPrimary)
              .strikethrough(misheard > 0.5, color: .firstRunFilmMistakeStrike)
              .padding(.horizontal, DesignSpacing.xxs)
              .background(
                RoundedRectangle(cornerRadius: DesignRadius.xs, style: .continuous)
                  .fill(
                    misheard > 0.5
                      ? Color.firstRunFilmMistakeWash : Color.obAccent.opacity(0.22 * selected)))
            Text(verbatim: Self.word)
              .fontWeight(.semibold)
              .foregroundStyle(Color.obAccent)
              .fixedSize()
              .modifier(FilmRevealWidth(fraction: fix))
              .opacity(fix)
            Text(
              "generate before you build.",
              comment:
                "Closing film: end of 'Run Tuist generate before you build.' (Tuist is a tool name)."
            )
          }
          .font(.obBody)
          .foregroundStyle(Color.obTextPrimary)
          .lineLimit(1)
          .fixedSize()
          .padding(.vertical, DesignSpacing.lg)
          .padding(.horizontal, DesignSpacing.xl)
        }
        .frame(width: 330, height: 104)
        .offset(y: 34)

        FilmLearnedPill(
          word: Self.word, progress: frame.still ? 1 : frame.value(T.undoWindow),
          reduceMotion: frame.still
        )
        .opacity(pill)
        .offset(y: 150 + 8 * (1 - (frame.still ? 1 : frame.value(T.pillRise))))
        .zIndex(6)

        FilmWindow(
          title: String(
            localized: "Next dictation", comment: "Window title in the closing film's learn scene.")
        ) {
          HStack(spacing: DesignSpacing.xs) {
            Text(verbatim: Self.word)
              .fontWeight(.semibold)
              .padding(.horizontal, DesignSpacing.xxs + 1)
              .background(
                RoundedRectangle(cornerRadius: DesignRadius.xs, style: .continuous)
                  .fill(Color.obAccent.opacity(0.16)))
            Text(
              "is set up. The build is green.",
              comment:
                "Closing film: end of 'Tuist is set up. The build is green.' (Tuist is a tool name)."
            )
          }
          .font(.obBody)
          .foregroundStyle(Color.obTextPrimary)
          .lineLimit(1)
          .padding(.vertical, DesignSpacing.md + 1)
          .padding(.horizontal, DesignSpacing.xl)
        }
        .frame(width: 330, height: 72)
        .opacity(next)
        .offset(y: 198 + 10 * (1 - next))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}

/// Shows the leading `fraction` of a view's width and pushes what follows by only that much
/// (the mockup's `max-width` reveal of the typed fix).
struct FilmRevealWidth: ViewModifier {
  let fraction: Double

  func body(content: Content) -> some View {
    FilmRevealLayout(fraction: fraction) { content }
      .clipped()
  }
}

private struct FilmRevealLayout: Layout {
  let fraction: Double

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let ideal = child.sizeThatFits(.unspecified)
    return CGSize(width: ideal.width * min(1, max(0, fraction)), height: ideal.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let child = subviews.first else { return }
    child.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
  }
}

/// MORE: the features in Settings, rising in, then drifting up.
struct FilmMoreScene: View {
  let frame: FilmFrame

  /// The features, with the symbols the app uses for them (SettingsPage icons). An even count:
  /// the wall is two columns.
  static let features: [(symbol: String, name: String)] = [
    (
      "waveform.badge.plus",
      String(localized: "Transcribe a File", comment: "Feature name in the closing film.")
    ),
    ("person.2.wave.2", "EnviousMeet"),
    ("curlybraces", String(localized: "Snippets", comment: "Feature name in the closing film.")),
    (
      "text.book.closed",
      String(localized: "Your Words", comment: "Feature name in the closing film.")
    ),
    (
      "textformat",
      String(localized: "Spoken punctuation", comment: "Feature name in the closing film.")
    ),
    (
      "clock.arrow.circlepath",
      String(localized: "History", comment: "Feature name in the closing film.")
    ),
    ("eye", String(localized: "Live preview", comment: "Feature name in the closing film.")),
    ("globe", String(localized: "Many languages", comment: "Feature name in the closing film.")),
    // #4528 (founder 2026-11-13): four more real features, so the wall runs past the faded
    // bottom edge while it drifts and reads as "there is more", not as the end of a list.
    (
      "keyboard",
      String(localized: "Keyboard shortcuts", comment: "Feature name in the closing film.")
    ),
    (
      "lock",
      String(localized: "Hands-free mode", comment: "Feature name in the closing film.")
    ),
    (
      "doc.on.doc",
      String(localized: "Copy last dictation", comment: "Feature name in the closing film.")
    ),
    (
      "speaker.wave.2",
      String(localized: "Dictation sounds", comment: "Feature name in the closing film.")
    ),
  ]

  var body: some View {
    let drift = frame.still ? 0 : frame.value(FilmScript.More.drift)
    Grid(horizontalSpacing: DesignSpacing.lg, verticalSpacing: DesignSpacing.lg) {
      ForEach(0..<(Self.features.count / 2), id: \.self) { row in
        GridRow {
          ForEach(0..<2, id: \.self) { column in
            tile(row * 2 + column)
          }
        }
      }
    }
    .padding(.vertical, 26)
    .padding(.horizontal, 22)
    .offset(y: -36 * drift)
    .frame(maxHeight: .infinity, alignment: .top)
    .mask(FilmEdgeFade(top: 0.1, bottom: 0.9))
  }

  private func tile(_ i: Int) -> some View {
    let shown = frame.value(FilmScript.More.tile(i))
    return
      HStack(spacing: DesignSpacing.lg) {
        Image(systemName: Self.features[i].symbol)
          .font(.firstRunCaption.weight(.semibold))
          .foregroundStyle(Color.obAccent)
          .frame(width: 30, height: 30)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
              .fill(Color.firstRunAccentSoft))
        Text(verbatim: Self.features[i].name)
          .font(.firstRunCaption.weight(.semibold))
          .foregroundStyle(Color.obTextPrimary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.vertical, DesignSpacing.lg)
      .padding(.horizontal, DesignSpacing.xl)
      .frame(minHeight: 50)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obCardBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
          .strokeBorder(Color.firstRunRule, lineWidth: 1)
      )
      .opacity(shown)
      .offset(y: 10 * (1 - shown))
  }
}

/// YOURS: the key, breathing, and where EnviousWispr lives in the menu bar.
struct FilmYoursScene: View {
  let frame: FilmFrame
  typealias T = FilmScript.Yours

  var body: some View {
    let key = frame.value(T.key)
    let keyBreath = frame.still ? 1 : T.breath(at: frame.loop, period: 2.4, delay: 0.6)
    let iconBreath = frame.still ? 1 : T.breath(at: frame.loop, period: 1.6, delay: 0)
    ZStack(alignment: .top) {
      HStack(spacing: 14) {
        Spacer(minLength: 0)
        Text("Wi-Fi", comment: "Menu bar item in the closing film's picture of a Mac.")
        RainbowLipsIcon(size: DesignSpacing.xxl, audioLevel: 0)
          .frame(width: 26, height: 20)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
              .fill(Color.firstRunAccentSoft)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
              .strokeBorder(Color.obAccent, lineWidth: 2)
          )
          .scaleEffect(iconBreath)
        Text("Thu 9:41", comment: "Clock in the closing film's picture of a Mac menu bar.")
      }
      .font(.obCaption.weight(.semibold))
      .foregroundStyle(Color.obTextSecondary)
      .padding(.horizontal, 14)
      .frame(height: 26)
      .background(Color.obCardBg.opacity(0.8))
      .overlay(alignment: .bottom) { Rectangle().fill(Color.firstRunRule).frame(height: 1) }

      Text("EnviousWispr lives here", comment: "Closing film: label pointing at the menu bar icon.")
        .font(.obCaptionSmall.weight(.semibold))
        .foregroundStyle(Color.obAccent)
        .opacity(frame.value(T.label))
        .offset(y: 32 + 10 * (1 - frame.value(T.label)))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 22)

      VStack(spacing: 18) {
        Text(verbatim: frame.summary.keyCap)
          .font(.firstRunDisplay)
          .foregroundStyle(Color.obAccent)
          .frame(minWidth: 120, minHeight: 72)
          .padding(.horizontal, DesignSpacing.xl)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [.obKeycapTop, .obSurface], startPoint: .top, endPoint: .bottom))
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
              .strokeBorder(Color.obAccent, lineWidth: 2)
          )
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.xl + DesignSpacing.xs, style: .continuous)
              .fill(Color.firstRunAccentSoft)
              .padding(-DesignSpacing.md)
          )
          .scaleEffect((0.65 + 0.35 * key) * keyBreath)
          .opacity(key)
        Text(
          "Look for EnviousWispr in your menu bar.",
          comment: "Closing film, last scene: where the app's icon is."
        )
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
        .opacity(frame.value(T.hint))
        .offset(y: 10 * (1 - frame.value(T.hint)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.top, 26)
    }
  }
}

/// The soft fade at the top and bottom of a drifting wall (mockup mask-image).
struct FilmEdgeFade: View {
  let top: Double
  let bottom: Double

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0), .init(color: .black, location: top),
        .init(color: .black, location: bottom), .init(color: .clear, location: 1),
      ], startPoint: .top, endPoint: .bottom)
  }
}
