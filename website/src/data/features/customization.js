// Make it yours page data (#2816). The six start/stop sounds are the app's
// real sounds, emitted as hashed assets so the page script can play them.
import whisperTickStart from '../../assets/features/sounds/whisperTick_start.wav?url&no-inline';
import whisperTickStop from '../../assets/features/sounds/whisperTick_stop.wav?url&no-inline';
import cloudPopStart from '../../assets/features/sounds/cloudPop_start.wav?url&no-inline';
import cloudPopStop from '../../assets/features/sounds/cloudPop_stop.wav?url&no-inline';
import velvetTapStart from '../../assets/features/sounds/velvetTap_start.wav?url&no-inline';
import velvetTapStop from '../../assets/features/sounds/velvetTap_stop.wav?url&no-inline';

export const sounds = [
  { key: 'whisperTick', name: 'Whisper Tick', start: whisperTickStart, stop: whisperTickStop },
  { key: 'cloudPop', name: 'Cloud Pop', start: cloudPopStart, stop: cloudPopStop },
  { key: 'velvetTap', name: 'Velvet Tap', start: velvetTapStart, stop: velvetTapStop },
];

export const pills = [
  { key: 'capsule', name: 'Capsule' },
  { key: 'rail', name: 'Level Rail' },
  { key: 'reading', name: 'Reading Well' },
];

export const positions = [
  { key: 'top', name: 'Top' },
  { key: 'bottom', name: 'Bottom' },
];

// 24 rail bar heights, the mock's 6 + (i*7) % 18 sequence.
export const railBars = Array.from({ length: 24 }, (_, i) => 6 + ((i * 7) % 18));
