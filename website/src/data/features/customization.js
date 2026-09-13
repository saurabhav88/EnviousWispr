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
  { key: 'classic', name: 'Capsule', note: 'A small capsule with the rainbow mark and a timer. The pill EnviousWispr has always shown.' },
  { key: 'levelRail', name: 'Level Rail', note: 'A wider capsule with a live rainbow meter of your voice beside the timer.' },
  { key: 'readingWell', name: 'Reading Well', note: 'A wide panel that shows your words as you speak, growing a line at a time. Needs Live Preview switched on.' },
];

// Keys a visitor can try as the record key. Every one is a binding the app
// accepts on its own (ShortcutBinding.swift): the four modifiers, and the
// Globe key. Caps Lock is deliberately absent: the recorder drops it.
// `option` is the shipped default (right Option).
export const recordKeys = [
  { key: 'fn', name: 'Globe', caption: 'The Globe key, on its own. Hold it and talk.' },
  { key: 'control', name: 'Control', caption: 'Control, on its own. Hold it and talk.' },
  { key: 'option', name: 'Option', caption: 'Option, on its own. The right one is how EnviousWispr arrives.', isDefault: true },
  { key: 'command', name: 'Command', caption: 'Command, on its own. Hold it and talk.' },
  { key: 'shift', name: 'Shift', caption: 'Shift, on its own. Hold it and talk.' },
];
