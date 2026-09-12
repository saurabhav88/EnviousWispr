// Snippets page keyword demo (#2816): the trigger word cycles backslash,
// shortcut, insert with a typewriter. Ported from the mock's film-director.js.
import { keepRoot } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const words = ['backslash', 'shortcut', 'insert'];
  const field = root.querySelector('[data-keyword-text]');
  const example = root.querySelector('[data-keyword-example]');
  let elapsed = 0;
  let index = 0;
  const show = (value) => {
    field.textContent = value;
  };
  const settle = () => {
    show(words[index]);
    example.textContent = words[index];
  };
  scope.timeline(
    root,
    (delta) => {
      elapsed += delta;
      const word = words[index];
      const hold = 1900;
      const erase = word.length * 85;
      const type = words[(index + 1) % words.length].length * 115;
      if (elapsed < hold) show(word);
      else if (elapsed < hold + erase) show(word.slice(0, Math.max(0, word.length - Math.floor((elapsed - hold) / 85))));
      else if (elapsed < hold + erase + 250) show('');
      else if (elapsed < hold + erase + 250 + type) show(words[(index + 1) % words.length].slice(0, Math.floor((elapsed - hold - erase - 250) / 115)));
      else {
        index = (index + 1) % words.length;
        elapsed = 0;
        settle();
      }
      return true;
    },
    () => {
      if (motion.reduced.matches || motion.paused) settle();
    },
  );
  if (scope.signal.aborted) return;
  settle();
}
