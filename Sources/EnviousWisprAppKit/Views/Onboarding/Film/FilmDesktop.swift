import EnviousWisprCore
import SwiftUI

// The closing film's Mac desktop parts (#4528 chunk E): wallpaper, menu bar, Dock, windows with
// traffic lights, keycaps and the pointer, drawn after the approved mockup's `gen_film.py`
// (`mscreen`, `menubar`, `dock`, `mwin`, `mkey`, `PTR`). Every part is a pure function of the
// values it is handed; none keeps a clock, so the film's Pause holds them all.

/// The film's stage measurements (mockup `[data-ui="film"]`: the content width, 346 tall).
enum FilmMetrics {
  static let stageHeight: CGFloat = 346
  static let menuBarHeight: CGFloat = 20
  static let titleBarHeight: CGFloat = 24
  static let light: CGFloat = 9
  static let lightGap: CGFloat = 5
  static let dockTile: CGFloat = 26
  static let keyHeight: CGFloat = 26
  static let keyMinWidth: CGFloat = 30
  static let pointerSize: CGFloat = 20
  static let clickRing: CGFloat = 20
  /// The wallpaper's 160-degree CSS gradient as unit points.
  static let wallStart = UnitPoint(x: 0.33, y: 0)
  static let wallEnd = UnitPoint(x: 0.67, y: 1)
}

/// A whole Mac screen: wallpaper, menu bar, the scene's windows, the Dock.
struct FilmMacScreen<Content: View>: View {
  /// The front app's name in the menu bar, cross-faded between two names when the front app
  /// changes (`fNameMail` / `fNameSlack`). `second` is shown with opacity `secondShown`.
  let first: String
  var second: String? = nil
  var secondShown: Double = 0
  @ViewBuilder var content: Content

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(
        stops: [
          .init(color: .firstRunFilmWallTop, location: 0),
          .init(color: .firstRunFilmWallMid, location: 0.55),
          .init(color: .firstRunFilmWallBottom, location: 1),
        ],
        startPoint: FilmMetrics.wallStart, endPoint: FilmMetrics.wallEnd)
      content
      FilmMenuBar(first: first, second: second, secondShown: secondShown)
      FilmDock()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, DesignSpacing.sm)
    }
    .clipped()
  }
}

/// The menu bar: Apple, the front app, File Edit View, then EnviousWispr's icon, Wi-Fi, clock.
struct FilmMenuBar: View {
  let first: String
  var second: String? = nil
  var secondShown: Double = 0

  var body: some View {
    HStack(spacing: DesignSpacing.xl) {
      Image(systemName: "applelogo")
      ZStack(alignment: .leading) {
        Text(verbatim: first).fontWeight(.bold).opacity(1 - secondShown)
        if let second {
          Text(verbatim: second).fontWeight(.bold).opacity(secondShown)
        }
      }
      Text("File", comment: "Menu bar menu in the closing film's picture of a Mac.")
      Text("Edit", comment: "Menu bar menu in the closing film's picture of a Mac.")
      Text("View", comment: "Menu bar menu in the closing film's picture of a Mac.")
      Spacer(minLength: 0)
      HStack(spacing: DesignSpacing.lg) {
        RainbowLipsIcon(size: DesignSpacing.xxl, audioLevel: 0)
        Image(systemName: "wifi")
        Text("Thu 9:41", comment: "Clock in the closing film's picture of a Mac menu bar.")
      }
    }
    .font(.obCaptionSmall)
    .lineLimit(1)
    .foregroundStyle(Color.firstRunFilmMenuInk)
    .padding(.horizontal, DesignSpacing.lg)
    .frame(height: FilmMetrics.menuBarHeight)
    .frame(maxWidth: .infinity)
    .background(Color.firstRunFilmMenuBar)
  }
}

/// The Dock: seven apps on white tiles, each with its website logo (the mockup's Dock).
struct FilmDock: View {
  static let apps: [FilmAppLogo] = ["Gmail", "Slack", "Notes", "Safari", "Notion", "Xcode", "Terminal"]
    .compactMap(FilmAppLogo.named)

  var body: some View {
    HStack(spacing: DesignSpacing.sm) {
      ForEach(Self.apps.indices, id: \.self) { i in
        FilmAppLogoView(logo: Self.apps[i], size: 17)
          .frame(width: FilmMetrics.dockTile, height: FilmMetrics.dockTile)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).fill(Color.white)
              .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
          )
      }
    }
    .padding(.horizontal, DesignSpacing.sm + 1)
    .padding(.vertical, DesignSpacing.xs + 1)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
        .fill(Color.firstRunFilmDock)
        .overlay(
          RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
    )
  }
}

/// A Mac window: traffic lights (lit while it is the front window), a title, then the body.
struct FilmWindow<Content: View>: View {
  let title: String
  /// 1 = the front window (colored lights), 0 = behind (grey lights).
  var active: Double = 1
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: DesignSpacing.sm) {
        FilmTrafficLights(lit: active)
          .padding(.trailing, DesignSpacing.sm)
        Text(verbatim: title)
          .font(.obCaptionSmall.weight(.semibold))
          .foregroundStyle(Color.obTextSecondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DesignSpacing.md + 1)
      .frame(height: FilmMetrics.titleBarHeight)
      .background(Color.obSurface)
      .overlay(alignment: .bottom) { Rectangle().fill(Color.firstRunRule).frame(height: 1) }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(Color.obCardBg)
    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    // The shadow belongs to a plain shape behind the window, not to its changing contents, so
    // a frame where the email or the lights change does not redraw the blur.
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
        .fill(Color.obCardBg)
        .shadow(color: .black.opacity(0.18), radius: 0.5)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 10)
    )
  }
}

/// Close, minimize, zoom: grey behind, colored when the window is in front.
struct FilmTrafficLights: View {
  var lit: Double

  private static let colors: [Color] = [
    .firstRunFilmLightRed, .firstRunFilmLightYellow, .firstRunFilmLightGreen,
  ]

  var body: some View {
    HStack(spacing: FilmMetrics.lightGap) {
      ForEach(Self.colors.indices, id: \.self) { i in
        Circle().fill(Color.firstRunRule)
          .overlay(Circle().fill(Self.colors[i]).opacity(lit))
          .frame(width: FilmMetrics.light, height: FilmMetrics.light)
      }
    }
  }
}

/// A keycap (mockup `mkey`). `held` 0...1 presses it down and turns it accent.
struct FilmKeyCap: View {
  let label: String
  var held: Double = 0

  var body: some View {
    Text(verbatim: label)
      .font(.firstRunCaption.weight(.semibold))
      .foregroundStyle(held > 0.5 ? Color.obAccent : Color.obTextPrimary)
      .padding(.horizontal, DesignSpacing.md)
      .frame(minWidth: FilmMetrics.keyMinWidth, minHeight: FilmMetrics.keyHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.obKeycapTop, .obSurface], startPoint: .top, endPoint: .bottom)
          )
          .shadow(color: Color.firstRunRule.opacity(1 - held), radius: 0, y: 2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
          .strokeBorder(held > 0.5 ? Color.obAccent : Color.firstRunRule, lineWidth: 1)
      )
      .offset(y: 2 * held)
  }
}

/// The pointer and the ring it leaves when it clicks.
struct FilmPointer: View {
  var clickScale: Double = 0
  var clickOpacity: Double = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      Circle()
        .strokeBorder(Color.obAccent, lineWidth: 2)
        .frame(width: FilmMetrics.clickRing, height: FilmMetrics.clickRing)
        .scaleEffect(clickScale)
        .opacity(clickScale > 0 ? clickOpacity : 0)
        .offset(x: -FilmMetrics.clickRing / 2 + 1, y: -FilmMetrics.clickRing / 2 + 1)
      ZStack {
        Image(systemName: "cursorarrow").foregroundStyle(Color.white)
          .font(.firstRunLabel.weight(.black))
        Image(systemName: "cursorarrow").foregroundStyle(Color.black)
          .font(.firstRunLabel)
      }
      .frame(
        width: FilmMetrics.pointerSize, height: FilmMetrics.pointerSize, alignment: .topLeading)
    }
    .frame(width: FilmMetrics.pointerSize, height: FilmMetrics.pointerSize, alignment: .topLeading)
  }
}

/// "<key> held", bottom left of the screen.
struct FilmHeldKey: View {
  let keyCap: String
  var held: Double

  var body: some View {
    HStack(spacing: DesignSpacing.sm) {
      FilmKeyCap(label: keyCap, held: held)
      Text("held", comment: "Next to a key in the closing film: the dictation key is held down.")
        .font(.obCaptionSmall.weight(.semibold))
        .foregroundStyle(Color.firstRunFilmMenuInk)
    }
  }
}

// MARK: - The app's own pills, drawn still

/// The real recording pill (`RecordingOverlayView`, the capsule design), standing still: one
/// provider read and no poll (`.still`), the clock pinned to the scene's number, no breathing
/// hairline. The same picture-mode contract Settings' appearance tiles use (#2435).
struct FilmRecordingPill: View {
  let seconds: TimeInterval

  var body: some View {
    RecordingOverlayView(
      audioLevelProvider: { Self.level },
      recordingElapsedProvider: { seconds },
      livePreviewProvider: { .off },
      onContentHeightChange: { _ in },
      chrome: RecordingPillDesign.classic.chrome,
      isLocked: false,
      noticeText: nil,
      cadence: .still,
      animatesGlow: false,
      initialAudioLevel: Self.level,
      initialElapsed: seconds
    )
    .fixedSize()
    .transaction { $0.disablesAnimations = true }
    .allowsHitTesting(false)
  }

  /// Mid voice, so the lips read as talking.
  static let level: Float = 0.42
}

/// The real "Polishing..." and "Copied. Press ⌘V to paste" pill (`PolishingOverlayView`, which
/// is what the app shows for both, with the app's own words from `DictationNarrator`).
struct FilmProcessingPill: View {
  let label: String
  /// The film's clock, so the wheel turns with the film and holds when it is paused.
  let clockTime: Double

  var body: some View {
    // A picture: no breathing hairline, and the wheel follows the film's clock.
    PolishingOverlayView(label: label, animatesGlow: false, wheelClockTime: clockTime)
      .fixedSize()
      .allowsHitTesting(false)
  }
}

/// The learned-word pill, built from `CorrectionLearnedPillView`'s own parts (its copy, metrics,
/// capsule and `SpectralRail`) so the film can drive the Undo rail from its clock and pause it.
/// The live view animates the rail on its own timer and carries a real Undo button, which a
/// film must not have.
struct FilmLearnedPill: View {
  let word: String
  /// How far the Undo window has run, 0 to 1.
  var progress: Double
  var reduceMotion: Bool

  var body: some View {
    let model = LearnedCorrectionPillModel(
      id: Self.filmID, wordID: Self.filmID, canonical: word, kind: .added)
    HStack(spacing: UndoPillMetrics.rowGap) {
      Text(CorrectionLearnedPillCopy.sentence(for: model))
        .font(.system(size: UndoPillMetrics.sentenceSize, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
      Text(CorrectionLearnedPillCopy.undo)
        .font(.system(size: UndoPillMetrics.actionSize, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, UndoPillMetrics.actionPaddingAcross)
        .padding(.vertical, UndoPillMetrics.actionPaddingDown)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
    }
    .padding(.horizontal, UndoPillMetrics.sidePadding)
    .padding(.vertical, UndoPillMetrics.verticalPadding)
    .background(OverlayCapsuleBackground(animatesGlow: false))
    .overlay {
      SpectralRail(
        progress: progress, palette: .dark,
        showsBloom: RailMotion.showsBloom(reduceMotion: reduceMotion)
      )
      .padding(1.5)
    }
    .fixedSize()
    .allowsHitTesting(false)
  }

  private static let filmID = UUID(uuidString: "4528E000-0000-4000-8000-000000000000") ?? UUID()
}
