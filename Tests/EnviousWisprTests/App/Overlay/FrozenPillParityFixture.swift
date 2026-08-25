import CoreGraphics
import Foundation

// The frozen parity oracle for the #2375 Phase 3 catalog migration (chunk C0).
//
// **Every value here was RUN, not read.** A characterization pass drove each
// request through the shipped reducer at `main` `da103706` and printed what it
// observed; these rows are that output transcribed. The distinction is the whole
// point of the chunk: the values Phase 3 must preserve do not come from one
// owner today — the definition fields come from `OverlayReducer` and both
// recording geometries come from the director's own substitution — so no single
// file can be read to produce "the base revision's answer".
//
// **THE SCHEMA IS DELIBERATELY RENAME-NEUTRAL and must stay that way.** It names
// none of C0's forbidden MIGRATION types anywhere, including in comments — a
// narrower claim than "no production type", which this comment used to make and
// which its own line 10 falsifies. Kinds and severities are
// Strings, widths and expiries are fixture-local enums, and the recording rows
// key on a fixture-local capability.
//
// The reason comments count: C1b's proof is that the renamed type's occurrence
// population is exactly the count measured before the work began, and that count
// comes from a plain text search — which cannot tell a comment from code. A
// mention here would enlarge the population silently, so the oracle would break
// the other proof that depends on it. The forbidden list is enumerated once, in
// `FrozenPillParityFixtureTests`, and enforced there rather than restated here.
//
// Nothing in this file is derived from any post-refactor implementation. A table
// that reads its expectations from the code under test proves only
// self-consistency.

// MARK: - Fixture-local value types

enum FrozenWidth: Equatable, Sendable {
  case fixed(CGFloat)
  /// The view pins its own width, so the call site's number is discarded.
  case measured
}

enum FrozenExpiry: Equatable, Sendable {
  case untilReplaced
  case after(seconds: Double, pausesOnHover: Bool)
}

struct FrozenAnnouncement: Equatable, Sendable {
  let text: String
  let isHighPriority: Bool
}

/// The notice fields, as Strings so the schema names no production enum.
struct FrozenNotice: Equatable, Sendable {
  let kind: String
  let text: String
  let secondary: String?
  let severity: String
  let isMultiline: Bool
  let actionLabel: String?
  let actionCase: String?
}

struct FrozenRow: Equatable, Sendable {
  let label: String
  /// False for `hidden`, which produces no definition and still announces.
  let hasDefinition: Bool
  /// `notice` for a notice-backed pill; otherwise the content's own tag.
  let contentTag: String
  let notice: FrozenNotice?
  let width: FrozenWidth?
  let fixedHeight: CGFloat?
  let expiry: FrozenExpiry?
  let announcement: FrozenAnnouncement?
}

/// Which capability state the recording pill was composed under. **A capability,
/// never a design** — these keys describe what the base revision could observe,
/// and the base revision has no notion of a user-chosen design.
enum FrozenRecordingCapability: String, Sendable {
  case withoutWords
  case withWords
}

struct FrozenRecordingRow: Equatable, Sendable {
  let capability: FrozenRecordingCapability
  /// What the director actually sizes the window to, which is NOT what the
  /// reducer returns for the with-words case.
  let effectiveWidth: CGFloat
  let fixedHeight: CGFloat?
  /// Captured so the surviving leaf adapter's equivalence is a measured row
  /// rather than an argument. It outlives C3b: C3b deletes the layout value,
  /// not the boolean the leaf still receives.
  let usesPreviewLayout: Bool
}

// MARK: - The frozen rows

enum FrozenPillParity {

  /// Definition parity for every request, keyed by label.
  ///
  /// Eighteen canonical request rows — the sixteen pipeline intents plus the two
  /// feature routes — and the two route-dependent outcomes of
  /// `reduceAccessibilityNotice`. **The eighteen already include BOTH Bluetooth
  /// routes**, which is what makes the duplicate observable; an earlier draft of
  /// this comment counted that second route again and described 21 rows against
  /// a table of 20.
  static let rows: [FrozenRow] = [
    // **Captured from a RECORDING, not from a fresh reducer.** A fresh reducer
    // already sits at `hidden`, so the dedup guard makes the request a no-op and
    // it announces nothing. That is a true measurement of the wrong transition.
    // The observed dictation-ending transition is recording -> hidden.
    //
    // Deliberately NOT claiming that production never sends hidden from an idle
    // state. The capture establishes which transition matters here, and says
    // nothing about which requests production can emit.
    //
    // Only this row is affected: every other intent differs from a fresh
    // reducer's starting intent, so each of them is new and announces normally.
    //
    // The same transition also cancels the armed expiry and emits
    // `recordingStateChanged(false)`, which is how Live Preview learns the
    // dictation ended. Those observations are OUTSIDE this fixture's
    // definition-parity schema and are recorded here purely as capture
    // provenance — so the next reader knows this row is a slice of a larger
    // observation. This comment does NOT claim another table asserts them.
    FrozenRow(
      label: "hidden", hasDefinition: false, contentTag: "none", notice: nil,
      width: nil, fixedHeight: nil, expiry: nil,
      announcement: FrozenAnnouncement(text: "Recording complete", isHighPriority: false)),

    FrozenRow(
      label: "recording", hasDefinition: true, contentTag: "recording", notice: nil,
      width: .fixed(185), fixedHeight: 92, expiry: .untilReplaced,
      announcement: FrozenAnnouncement(text: "Recording started", isHighPriority: true)),

    FrozenRow(
      label: "processing.transcribing", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "processing", text: "Transcribing...", secondary: nil, severity: "neutral",
        isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .measured, fixedHeight: nil, expiry: .untilReplaced,
      announcement: FrozenAnnouncement(text: "Processing transcription", isHighPriority: false)),

    FrozenRow(
      label: "clipboardFallback", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "processing", text: "Copied. Press ⌘V to paste", secondary: nil,
        severity: "neutral", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .measured, fixedHeight: nil,
      expiry: .after(seconds: 2.5, pausesOnHover: false),
      announcement: FrozenAnnouncement(text: "Text copied to clipboard", isHighPriority: true)),

    FrozenRow(
      label: "accessibilityToast", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "accessibilityToast", text: "Auto-paste needs Accessibility", secondary: nil,
        severity: "neutral", isMultiline: true, actionLabel: "Grant",
        actionCase: "grantAccessibility"),
      width: .fixed(300), fixedHeight: 56,
      expiry: .after(seconds: 6, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Accessibility permission needed for auto-paste", isHighPriority: true)),

    FrozenRow(
      label: "warning.polishFailed", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "notification", text: "Polish failed. Using raw text.", secondary: nil,
        severity: "warning", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(280), fixedHeight: 44,
      expiry: .after(seconds: 2.5, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Warning: Polish failed. Using raw text.", isHighPriority: false)),

    FrozenRow(
      label: "error.asrFailed", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "notification", text: "Transcription error. Try again.", secondary: nil,
        severity: "error", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(280), fixedHeight: 44,
      expiry: .after(seconds: 3, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Error: Transcription error. Try again.", isHighPriority: true)),

    // The ONLY content-sized notification: `fitToContent:` is passed
    // `style.isMultiline`, and advisory is the one style where that is true.
    FrozenRow(
      label: "advisory.zeroSignal", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "notification",
        text:
          "Audio isn't capturing. Your lid may be closed, your headset muted, or there may be a hardware issue. Please check your microphone settings.",
        secondary: nil, severity: "advisory", isMultiline: true, actionLabel: nil,
        actionCase: nil),
      width: .fixed(360), fixedHeight: nil,
      expiry: .after(seconds: 8, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text:
          "Audio isn't capturing. Your lid may be closed, your headset muted, or there may be a hardware issue. Please check your microphone settings.",
        isHighPriority: true)),

    FrozenRow(
      label: "interruption.deviceRemoved", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "notification", text: "Microphone disconnected.", secondary: nil,
        severity: "distress", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(280), fixedHeight: 44,
      expiry: .after(seconds: 2, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Interruption: Microphone disconnected.", isHighPriority: true)),

    FrozenRow(
      label: "passiveChip", hasDefinition: true, contentTag: "languageChip", notice: nil,
      width: .fixed(340), fixedHeight: 56,
      expiry: .after(seconds: 6, pausesOnHover: true),
      announcement: FrozenAnnouncement(text: "Detected Spanish", isHighPriority: false)),

    FrozenRow(
      label: "cachingModel", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "warmingUp", text: "Getting dictation ready…",
        secondary: "Parakeet is warming up after a restart", severity: "neutral",
        isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(300), fixedHeight: 56,
      expiry: .after(seconds: 2, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Getting dictation ready, one moment", isHighPriority: false)),

    FrozenRow(
      label: "engineReady", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "ready", text: "Ready — press to dictate", secondary: nil, severity: "neutral",
        isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(240), fixedHeight: 44,
      expiry: .after(seconds: 1.5, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Dictation ready. Press to start.", isHighPriority: true)),

    FrozenRow(
      label: "recoveringLastRecording", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "recovery", text: "Recovering your last recording…",
        secondary: "Anything saved lands in History", severity: "neutral", isMultiline: true,
        actionLabel: "Discard", actionCase: "discardRecovery"),
      width: .fixed(320), fixedHeight: 56,
      expiry: .after(seconds: 6, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Recovering your last recording. Press Discard to skip.", isHighPriority: true)),

    // `ready`, NOT `notification`: routing a success through the notification
    // leaf would paint it as a warning, which is the mis-kind this mapping
    // exists to stop.
    FrozenRow(
      label: "recoverySucceeded", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "ready", text: "Recovered your last recording", secondary: "Saved to History",
        severity: "neutral", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .fixed(300), fixedHeight: 56,
      expiry: .after(seconds: 3, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Recovered your last recording. Saved to History.", isHighPriority: true)),

    // THE DUPLICATE, both routes. These two rows are byte-identical in the base
    // revision, which is the measured form of the defect: they agree today and
    // nothing holds them to it.
    FrozenRow(
      label: "bluetoothAwareness.pipelineRoute", hasDefinition: true,
      contentTag: "bluetoothAwareness", notice: nil,
      width: .fixed(320), fixedHeight: nil, expiry: .untilReplaced,
      announcement: FrozenAnnouncement(
        text:
          "Bluetooth microphone detected. Wait a moment before speaking on a cold start.",
        isHighPriority: false)),

    FrozenRow(
      label: "bluetoothAwareness.featureRoute", hasDefinition: true,
      contentTag: "bluetoothAwareness", notice: nil,
      width: .fixed(320), fixedHeight: nil, expiry: .untilReplaced,
      announcement: FrozenAnnouncement(
        text:
          "Bluetooth microphone detected. Wait a moment before speaking on a cold start.",
        isHighPriority: false)),

    FrozenRow(
      label: "escapeRecovery", hasDefinition: true, contentTag: "escapeRecovery", notice: nil,
      width: .measured, fixedHeight: nil,
      expiry: .after(seconds: 3, pausesOnHover: true),
      announcement: FrozenAnnouncement(
        text: "Transcript cancelled. Press Undo to get it back, or find it in History.",
        isHighPriority: false)),

    // The one presentation with no matching intent, so the shipped announcement
    // switch has no arm for it. `nil` is asserted rather than the row omitted.
    FrozenRow(
      label: "importStatus.featureRoute", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "importStatus", text: "Imported 12 words", secondary: nil, severity: "neutral",
        isMultiline: true, actionLabel: nil, actionCase: nil),
      width: .measured, fixedHeight: nil,
      expiry: .after(seconds: 3, pausesOnHover: false),
      announcement: nil),

    // The accessibility path's two outcomes. The refused case is the one that
    // matters: it draws the CLIPBOARD definition while retaining the
    // ACCESSIBILITY announcement — the only place a definition and an
    // announcement legitimately come from different requests.
    FrozenRow(
      label: "accessibilityNotice.toastRefused", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "processing", text: "Copied. Press ⌘V to paste", secondary: nil,
        severity: "neutral", isMultiline: false, actionLabel: nil, actionCase: nil),
      width: .measured, fixedHeight: nil,
      expiry: .after(seconds: 2.5, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Accessibility permission needed for auto-paste", isHighPriority: true)),

    FrozenRow(
      label: "accessibilityNotice.toastShown", hasDefinition: true, contentTag: "notice",
      notice: FrozenNotice(
        kind: "accessibilityToast", text: "Auto-paste needs Accessibility", secondary: nil,
        severity: "neutral", isMultiline: true, actionLabel: "Grant",
        actionCase: "grantAccessibility"),
      width: .fixed(300), fixedHeight: 56,
      expiry: .after(seconds: 6, pausesOnHover: false),
      announcement: FrozenAnnouncement(
        text: "Accessibility permission needed for auto-paste", isHighPriority: true)),
  ]

  /// The two recording geometries the DIRECTOR substitutes.
  ///
  /// **Compare `withWords.effectiveWidth` (400) against the `recording` row's
  /// `width` (185) above: that is the dead-literal defect, measured rather than
  /// argued.** The reducer's 185/92 is the without-words answer and is discarded
  /// for the with-words case.
  static let recordingRows: [FrozenRecordingRow] = [
    FrozenRecordingRow(
      capability: .withoutWords, effectiveWidth: 185, fixedHeight: 92,
      usesPreviewLayout: false),
    FrozenRecordingRow(
      capability: .withWords, effectiveWidth: 400, fixedHeight: nil,
      usesPreviewLayout: true),
  ]
}
