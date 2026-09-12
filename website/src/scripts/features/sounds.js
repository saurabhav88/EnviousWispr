// Make it yours: play a start/stop sound pair (#2816). Ported from the mock's
// marketing.js; each button carries the emitted asset URLs in data-start and
// data-stop. Disposal invalidates the generation, silences the current audio
// and clears the pending completion, so nothing plays after fallback.
import { keepRoot, enableControls, on, timer } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const status = root.querySelector('[data-sound-status]');
  const buttons = [...root.querySelectorAll('[data-sound]')];
  if (!status || !buttons.length) throw new Error('sounds: missing controls');
  let playing = null;
  let generation = 0;
  scope.defer(() => {
    generation++;
    try {
      if (playing) {
        playing.onended = null;
        playing.pause();
      }
    } catch {
      /* a disposer never throws */
    }
  });
  for (const button of buttons) {
    on(scope, button, 'click', () => {
      const mine = ++generation;
      if (playing) {
        playing.onended = null;
        playing.pause();
      }
      const name = button.querySelector('span').textContent;
      playing = new Audio(button.dataset.start);
      status.textContent = 'Playing ' + name + ' start sound…';
      playing.onended = () => {
        if (mine !== generation) return;
        timer(
          scope,
          () => {
            if (mine !== generation) return;
            playing = new Audio(button.dataset.stop);
            status.textContent = 'Playing stop sound…';
            playing.onended = () => {
              if (mine === generation) status.textContent = 'Start-and-stop pair finished.';
            };
            playing.play().catch(() => {
              if (mine === generation) status.textContent = 'Sound playback is unavailable.';
            });
          },
          450,
        );
      };
      playing.play().catch(() => {
        if (mine === generation) status.textContent = 'Sound playback is unavailable.';
      });
    });
  }
  enableControls(root);
}
