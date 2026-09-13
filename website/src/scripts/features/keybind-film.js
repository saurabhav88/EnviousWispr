// Make it second nature: the default record key doing its two jobs. One
// timeline, two scenes (hold to talk, then hands-free), rendered from elapsed
// time so pausing, reduced motion and scene jumps all read the same clock.
// Sentences are typed into the document line; the pill counts real seconds
// with the app's own capsule frames.
import { keepRoot, enableControls, on } from './guard.js';

const HOLD = 'The two bigger ones need a proper rewrite, so I will have the next version over by Thursday.';
const FREE = ' Happy to walk through the pricing section on a call if that is easier than notes.';

// Each scene is a list of [at, patch] steps applied in order while at <= t.
const SCENES = [
  {
    key: 'hold',
    length: 6600,
    steps: [
      [0, { caption: 'Hold the right Option key and talk.', key: 'up', pill: 'hidden', typed: 0, done: false }],
      [350, { key: 'down' }],
      [550, { pill: 'shown', clockStart: 550 }],
      [3900, { caption: 'Let go, and your words land where your cursor was.' }],
      [4000, { key: 'up' }],
      [4150, { pill: 'hidden' }],
      [4350, { typing: [4350, 5500, 0, HOLD.length] }],
      [5600, { done: true }],
    ],
  },
  {
    key: 'handsfree',
    length: 8200,
    steps: [
      [0, { caption: 'Tap it twice to lock hands-free.', key: 'up', pill: 'hidden', typed: HOLD.length, done: false }],
      [350, { key: 'down' }],
      [500, { key: 'up', pill: 'shown', clockStart: 500 }],
      [700, { key: 'down' }],
      [850, { key: 'up', pill: 'handsfree' }],
      [1200, { caption: 'Hands off the keyboard. Talk as long as you like, up to an hour.' }],
      [4700, { caption: 'Tap once more when you are done.' }],
      [5000, { key: 'down' }],
      [5150, { key: 'up' }],
      [5300, { pill: 'hidden' }],
      [5500, { typing: [5500, 6700, HOLD.length, HOLD.length + FREE.length] }],
      [6800, { done: true }],
    ],
  },
];
const TOTAL = SCENES.reduce((a, s) => a + s.length, 0);
const FULL = HOLD + FREE;
const FRAMES = 7;

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const caption = root.querySelector('[data-kf-caption]');
  const text = root.querySelector('[data-kf-text]');
  const buttons = [...root.querySelectorAll('[data-kf-scene]')];
  if (!caption || !text || buttons.length !== SCENES.length) throw new Error('keybind film: missing parts');
  let elapsed = 0;

  function stateAt(time) {
    let t = time % TOTAL;
    let index = 0;
    while (t >= SCENES[index].length) t -= SCENES[index++].length;
    const scene = SCENES[index];
    const state = { scene: scene.key, key: 'up', pill: 'hidden', typed: 0, done: false, caption: '', clockStart: 0, typing: null };
    for (const [at, patch] of scene.steps) {
      if (at > t) break;
      Object.assign(state, patch);
    }
    if (state.typing) {
      const [from, to, a, b] = state.typing;
      const p = Math.min(1, Math.max(0, (t - from) / (to - from)));
      state.typed = Math.round(a + (b - a) * p);
    }
    const frame = state.pill === 'shown' ? Math.min(FRAMES - 1, Math.floor((t - state.clockStart) / 1000)) : 0;
    return { ...state, frame, index };
  }

  function render(reduced = motion.reduced.matches) {
    // With reduced motion the film stands still on its finished first scene.
    const state = reduced ? { ...stateAt(SCENES[0].length - 1), key: 'down', pill: 'shown', frame: 3, done: false } : stateAt(elapsed);
    root.dataset.scene = state.scene;
    root.dataset.key = state.key;
    root.dataset.pill = state.pill;
    root.dataset.frame = String(state.frame);
    root.dataset.done = String(state.done);
    const shown = FULL.slice(0, state.typed);
    if (text.textContent !== shown) text.textContent = shown;
    const words = reduced ? 'Hold the right Option key and talk. Let go, and your words land where your cursor was.' : state.caption;
    if (caption.textContent !== words) caption.textContent = words;
    buttons.forEach((b, i) => {
      const active = i === state.index;
      b.classList.toggle('selected', active);
      b.setAttribute('aria-pressed', String(active));
    });
  }

  const clock = scope.timeline(
    root,
    (delta) => {
      elapsed = (elapsed + delta) % TOTAL;
      render();
      return true;
    },
    (reduced) => render(reduced),
  );
  if (scope.signal.aborted) return;

  buttons.forEach((button, i) => {
    on(scope, button, 'click', () => {
      elapsed = SCENES.slice(0, i).reduce((a, s) => a + s.length, 0);
      render();
      clock.wake({ allowFocused: true });
    });
  });
  render();
  enableControls(root);
}
