// Any key can be your record key. The chosen key sits pressed; the demo moves
// the press from key to key, and a tap chooses a key and holds the demo there
// until the visitor has been idle for a while. Rendered from elapsed time so
// pausing and reduced motion read the same clock; the press itself is a CSS
// transition on the key's data-state.
import { keepRoot, enableControls, on } from './guard.js';

const DWELL = 2400; // how long each key stays pressed in the demo
const IDLE = 8000; // after a tap, how long before the demo moves on

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const caption = root.querySelector('[data-kp-caption]');
  const keys = [...root.querySelectorAll('[data-kp-key]')];
  if (!caption || keys.length < 2) throw new Error('key picker: missing parts');

  let elapsed = 0;
  let chosen = Math.max(0, keys.findIndex((k) => k.dataset.kpKey === root.dataset.chosen));
  let since = 0;
  let auto = true;

  function render() {
    root.dataset.chosen = keys[chosen].dataset.kpKey;
    keys.forEach((k, i) => {
      const active = i === chosen;
      k.setAttribute('aria-pressed', String(active));
      k.dataset.state = active ? 'pressed' : 'idle';
    });
    const words = keys[chosen].dataset.caption;
    if (caption.textContent !== words) caption.textContent = words;
  }

  const clock = scope.timeline(root, (delta) => {
    elapsed += delta;
    // Reduced motion: the chosen key stays where it is, nothing moves on its own.
    if (motion.reduced.matches) return true;
    // A demo press lasts DWELL; a tapped key holds for IDLE, then the demo
    // moves on from it straight away.
    if (elapsed - since >= (auto ? DWELL : IDLE)) {
      chosen = (chosen + 1) % keys.length;
      auto = true;
      since = elapsed;
      render();
    }
    return true;
  });
  if (scope.signal.aborted) return;

  keys.forEach((key, i) => {
    on(scope, key, 'click', () => {
      chosen = i;
      since = elapsed;
      auto = false;
      render();
      clock.wake({ allowFocused: true });
    });
  });
  render();
  enableControls(root);
}
