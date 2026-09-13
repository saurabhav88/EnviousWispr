// Features page entry (#2816). One motion controller per page; each island is
// imported only after its root is found, mounted through enhance() so a
// failure restores that island's static frame and leaves its siblings alone.
// A rejected import marks the untouched root unavailable.
import { createMotionController } from '../home/motion.js';
import { enhance } from '../home/enhance.js';

const islands = [
  ['[data-film]', () => import('./film-director.js'), true],
  ['[data-feature-loop]', () => import('./feature-loop.js')],
  ['[data-file-demo]', () => import('./file-demo.js')],
  ['[data-recording-cases]', () => import('./transcript-player.js')],
  ['[data-history-film]', () => import('./history-demo.js')],
  ['[data-privacy-film]', () => import('./privacy-demo.js')],
  ['[data-keyword-demo]', () => import('./keyword-demo.js')],
  ['[data-picker]', () => import('./pickers.js'), true],
  ['[data-sound-group]', () => import('./sounds.js')],
  ['[data-keybind-film]', () => import('./keybind-film.js')],
];

try {
  const motion = createMotionController();
  for (const [selector, load, many] of islands) {
    const roots = many ? [...document.querySelectorAll(selector)] : [document.querySelector(selector)].filter(Boolean);
    if (roots.length === 0) continue;
    load()
      .then((module) => {
        for (const root of roots) enhance(root, motion, module.init);
      })
      .catch((error) => {
        for (const root of roots) root.dataset.enhancement = 'unavailable';
        console.error('Feature enhancement could not load: ' + selector, error);
      });
  }
} catch (error) {
  console.error('Feature motion unavailable; static content remains.', error);
}
