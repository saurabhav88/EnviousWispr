// Make it yours page data (#2816). Every sound is one of the app's twelve real
// start/stop pairings, in the app's own order, with the app's own one-line
// description (RecordingSoundsSettingsView.swift), emitted as hashed assets so
// the page script can play them.
import dustMoteStart from '../../assets/features/sounds/dustMote_start.wav?url&no-inline';
import dustMoteStop from '../../assets/features/sounds/dustMote_stop.wav?url&no-inline';
import velvetHushStart from '../../assets/features/sounds/velvetHush_start.wav?url&no-inline';
import velvetHushStop from '../../assets/features/sounds/velvetHush_stop.wav?url&no-inline';
import mutedConfirmStart from '../../assets/features/sounds/mutedConfirm_start.wav?url&no-inline';
import mutedConfirmStop from '../../assets/features/sounds/mutedConfirm_stop.wav?url&no-inline';
import whisperTickStart from '../../assets/features/sounds/whisperTick_start.wav?url&no-inline';
import whisperTickStop from '../../assets/features/sounds/whisperTick_stop.wav?url&no-inline';
import roundPebbleStart from '../../assets/features/sounds/roundPebble_start.wav?url&no-inline';
import roundPebbleStop from '../../assets/features/sounds/roundPebble_stop.wav?url&no-inline';
import paperTapStart from '../../assets/features/sounds/paperTap_start.wav?url&no-inline';
import paperTapStop from '../../assets/features/sounds/paperTap_stop.wav?url&no-inline';
import softHushStart from '../../assets/features/sounds/softHush_start.wav?url&no-inline';
import softHushStop from '../../assets/features/sounds/softHush_stop.wav?url&no-inline';
import lowNodStart from '../../assets/features/sounds/lowNod_start.wav?url&no-inline';
import lowNodStop from '../../assets/features/sounds/lowNod_stop.wav?url&no-inline';
import cloudPopStart from '../../assets/features/sounds/cloudPop_start.wav?url&no-inline';
import cloudPopStop from '../../assets/features/sounds/cloudPop_stop.wav?url&no-inline';
import velvetTapStart from '../../assets/features/sounds/velvetTap_start.wav?url&no-inline';
import velvetTapStop from '../../assets/features/sounds/velvetTap_stop.wav?url&no-inline';
import satinShiftStart from '../../assets/features/sounds/satinShift_start.wav?url&no-inline';
import satinShiftStop from '../../assets/features/sounds/satinShift_stop.wav?url&no-inline';
import airGlintStart from '../../assets/features/sounds/airGlint_start.wav?url&no-inline';
import airGlintStop from '../../assets/features/sounds/airGlint_stop.wav?url&no-inline';

export const sounds = [
  { key: 'dustMote', name: 'Dust Mote', note: 'Soft filtered air, no tone.', start: dustMoteStart, stop: dustMoteStop },
  { key: 'velvetHush', name: 'Velvet Hush', note: 'Two close tones, gentle warmth.', start: velvetHushStart, stop: velvetHushStop },
  { key: 'mutedConfirm', name: 'Muted Confirm', note: 'Same pitch both ways, plain.', start: mutedConfirmStart, stop: mutedConfirmStop },
  { key: 'whisperTick', name: 'Whisper Tick', note: 'Barely-there tick.', start: whisperTickStart, stop: whisperTickStop, isDefault: true },
  { key: 'roundPebble', name: 'Round Pebble', note: 'Rounded, no edge.', start: roundPebbleStart, stop: roundPebbleStop },
  { key: 'paperTap', name: 'Paper Tap', note: 'Soft paper-like tap.', start: paperTapStart, stop: paperTapStop },
  { key: 'softHush', name: 'Soft Hush', note: 'Slow fade, like a breath.', start: softHushStart, stop: softHushStop },
  { key: 'lowNod', name: 'Low Nod', note: 'Low, warm, unhurried.', start: lowNodStart, stop: lowNodStop },
  { key: 'cloudPop', name: 'Cloud Pop', note: 'Tiny filtered-air pop.', start: cloudPopStart, stop: cloudPopStop },
  { key: 'velvetTap', name: 'Velvet Tap', note: 'Muted, compact tap.', start: velvetTapStart, stop: velvetTapStop },
  { key: 'satinShift', name: 'Satin Shift', note: 'Smooth two-tone shift.', start: satinShiftStart, stop: satinShiftStop },
  { key: 'airGlint', name: 'Air Glint', note: 'Clean, airy glint.', start: airGlintStart, stop: airGlintStop },
];

// The three recording pill designs, named as the app's Appearance page names
// them (RecordingPillDesign.displayName), with the app's own one-line summary.
export const pills = [
  { key: 'classic', name: 'Capsule', note: 'A small capsule with the rainbow mark and a timer.' },
  { key: 'levelRail', name: 'Level Rail', note: 'A wider capsule with a live rainbow meter of your voice beside the timer.' },
  { key: 'readingWell', name: 'Reading Well', note: 'A wide panel that shows your words as you speak, growing a line at a time.' },
];

export const modes = [
  { key: 'listening', name: 'Hold to talk' },
  { key: 'handsfree', name: 'Hands-free' },
];

export const positions = [
  { key: 'top', name: 'Top' },
  { key: 'bottom', name: 'Bottom' },
];

// The screen the Mac scene is drawn on: a 14-inch MacBook Pro at its default
// scaling, 1512 x 982 points with a 33-point menu bar. Every pill position
// below is the app's own placement arithmetic (OverlayPlacementState.swift)
// evaluated for that screen, in points from the top-left corner. The Dock is
// hidden, so the bottom of the visible area is the bottom of the screen.
export const screen = { width: 1512, height: 982, menuBar: 33 };

// Pill geometry in points. Capsule and Level Rail sit inside a 92-point box
// that the app keeps for the one-minute warning: centred in it at the top,
// bottom-aligned at the bottom. The box top is 8 points under the menu bar.
// Reading Well is sized to its words, so it sits 8 points under the menu bar.
const boxTop = screen.menuBar + 8; // 41
const capsuleHeight = 44;
const wellHeight = 99;
export const pillPlacement = {
  classic: { height: capsuleHeight, top: boxTop + (92 - capsuleHeight) / 2, bottom: screen.height - capsuleHeight },
  levelRail: { height: capsuleHeight, top: boxTop + (92 - capsuleHeight) / 2, bottom: screen.height - capsuleHeight },
  readingWell: { height: wellHeight, top: boxTop, bottom: screen.height - wellHeight },
};

// The default keybinds, as the app ships them (ShortcutBinding.swift):
// record = right Option alone, cancel = Escape, add a word = Control Shift W.
export const keybinds = [
  { key: 'record', name: 'Record', keys: ['⌥'], label: 'Right Option', note: 'Hold it to talk. Tap it twice to go hands-free.' },
  { key: 'cancel', name: 'Cancel', keys: ['esc'], label: 'Escape', note: 'Stops the recording without pasting.' },
  { key: 'quickAdd', name: 'Add a word', keys: ['⌃', '⇧', 'W'], label: 'Control Shift W', note: 'Teaches the app a word you have highlighted.' },
];
