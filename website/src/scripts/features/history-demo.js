// History page film (#2816): the accidental-Escape and relief story in five
// scenes. Ported from the mock's history-demo.js.
import { keepRoot, enableControls, on } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const scenes = [...root.querySelectorAll('.hs')];
  const play = root.querySelector('[data-history-play]');
  const words = root.querySelector('[data-history-words]');
  const copy = root.querySelector('[data-history-copy]');
  const caption = root.querySelector('[data-history-caption]');
  const count = root.querySelector('[data-history-count]');
  const durations = [3600, 2100, 1700, 4200, 2900];
  const captions = [
    'Say what’s on your mind.',
    'An accidental press of Escape.',
    'You know that feeling.',
    'History kept the text.',
    'Copy it. Breathe. Carry on.',
  ];
  const total = durations.reduce((a, b) => a + b, 0);
  const line = 'Let’s move the meeting to Friday.';
  const settledAt = durations[0] + durations[1] + durations[2] + 3000;
  let elapsed = 0;
  let paused = false;
  let clock;

  function controls() {
    const stopped = paused || !motion.allowed();
    play.textContent = stopped ? '▶' : 'Ⅱ';
    play.setAttribute('aria-label', stopped ? 'Play history demo' : 'Pause history demo');
    play.disabled = motion.reduced.matches;
    root.dataset.playing = String(!stopped);
  }
  function render() {
    let t = elapsed;
    let i = 0;
    while (i < durations.length - 1 && t >= durations[i]) t -= durations[i++];
    root.dataset.scene = String(i);
    scenes.forEach((s, n) => s.classList.toggle('active', n === i));
    words.textContent = i === 0 ? line.slice(0, Math.max(1, Math.floor(line.length * Math.min(1, t / 2500)))) : line;
    copy.textContent = i === 3 && t > 2800 ? '✓ Copied' : 'Copy';
    caption.textContent = captions[i];
    count.textContent = i + 1 + ' / 5';
    controls();
  }
  clock = scope.timeline(
    root,
    (d) => {
      if (paused) return false;
      elapsed = (elapsed + d) % total;
      render();
      return true;
    },
    (reduced) => {
      if (reduced) {
        elapsed = settledAt;
        render();
      }
      controls();
    },
  );
  if (scope.signal.aborted) return;
  on(scope, play, 'click', () => {
    if (motion.reduced.matches) return;
    const shouldPlay = paused || !motion.allowed();
    if (shouldPlay && motion.paused) motion.setPaused(false);
    paused = !shouldPlay;
    controls();
    clock.wake({ allowFocused: true });
  });
  on(scope, document, 'home:motion', controls);
  render();
  enableControls(root);
  controls();
}
