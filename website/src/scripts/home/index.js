import { createMotionController } from './motion.js';
import { enhance } from './enhance.js';
import { initShell } from './shell.js';

// A missing section module leaves its build-time content intact.
initShell();
try {
  const motion = createMotionController();
  const sections = [
    ['opening', () => import('./hero.js')],
    ['apps', () => import('./apps.js')],
    ['engines', () => import('./engines.js')],
    ['polish', () => import('./cleanup.js')],
    ['people', () => import('./cases.js')],
    ['story', () => import('./founder.js')],
    ['community', () => import('./review.js')],
  ];
  for (const [id, load] of sections) {
    load()
      .then((module) => enhance(document.getElementById(id), motion, module.init))
      .catch((error) => console.error('Homepage enhancement could not load: ' + id, error));
  }
} catch (error) {
  console.error('Homepage motion unavailable; static content remains.', error);
}
