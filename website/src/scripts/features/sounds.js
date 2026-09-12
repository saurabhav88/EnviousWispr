// Make it yours: play a start/stop sound pair (#2816). Ported from the mock's
// marketing.js; each button carries the emitted asset URLs in data-start and
// data-stop, so nothing is resolved from a script location.
export function init(root, motion, scope) {
  const status = root.querySelector('[data-sound-status]');
  const buttons = [...root.querySelectorAll('[data-sound]')];
  if (!status || !buttons.length) throw new Error('sounds: missing controls');
  let playing = null;
  let timer = null;
  let generation = 0;
  scope.defer(() => {
    clearTimeout(timer);
    playing?.pause();
  });
  for (const button of buttons) {
    button.addEventListener(
      'click',
      () => {
        const mine = ++generation;
        clearTimeout(timer);
        playing?.pause();
        const name = button.querySelector('span').textContent;
        playing = new Audio(button.dataset.start);
        status.textContent = 'Playing ' + name + ' start sound…';
        playing.onended = () => {
          if (mine !== generation) return;
          timer = setTimeout(() => {
            if (mine !== generation) return;
            playing = new Audio(button.dataset.stop);
            status.textContent = 'Playing stop sound…';
            playing.onended = () => {
              if (mine === generation) status.textContent = 'Start-and-stop pair finished.';
            };
            playing.play().catch(() => {
              status.textContent = 'Sound playback is unavailable.';
            });
          }, 450);
        };
        playing.play().catch(() => {
          if (mine === generation) status.textContent = 'Sound playback is unavailable.';
        });
      },
      { signal: scope.signal },
    );
  }
}
