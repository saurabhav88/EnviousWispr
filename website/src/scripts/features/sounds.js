// Make it yours: play a start/stop sound pair (#2816). Each button carries the
// emitted asset URLs in data-start and data-stop; the button that is playing
// carries data-playing="start" then "stop" so the card can animate. Disposal
// invalidates the generation, silences the current audio and clears the
// pending completion, so nothing plays after fallback.
import { guarded, keepRoot, enableControls, on, timer } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const status = root.querySelector('[data-sound-status]');
  const buttons = [...root.querySelectorAll('[data-sound]')];
  if (!status || !buttons.length) throw new Error('sounds: missing controls');
  let playing = null;
  let generation = 0;
  const clear = () => {
    for (const b of buttons) delete b.dataset.playing;
  };
  scope.defer(() => {
    generation++;
    try {
      if (playing) {
        playing.onended = null;
        playing.pause();
      }
      clear();
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
      clear();
      const nameNode = button.querySelector('.sound-name');
      if (!nameNode) throw new Error('sounds: a card has no name');
      const name = nameNode.firstChild.textContent.trim();
      const unavailable = guarded(scope, () => {
        if (mine !== generation) return;
        clear();
        status.textContent = 'Sound playback is unavailable.';
      });
      playing = new Audio(button.dataset.start);
      button.dataset.playing = 'start';
      status.textContent = 'Playing ' + name + ': the start sound…';
      playing.onended = guarded(scope, () => {
        if (mine !== generation) return;
        timer(
          scope,
          () => {
            if (mine !== generation) return;
            playing = new Audio(button.dataset.stop);
            button.dataset.playing = 'stop';
            status.textContent = 'Playing ' + name + ': the stop sound…';
            playing.onended = guarded(scope, () => {
              if (mine !== generation) return;
              clear();
              status.textContent = name + ': start, then stop. That is what you hear around a recording.';
            });
            playing.play().catch(unavailable);
          },
          450,
        );
      });
      playing.play().catch(unavailable);
    });
  }
  enableControls(root);
}
