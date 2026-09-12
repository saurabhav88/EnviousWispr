// File Transcription demo (#2816): five scenes, drop a file, choose engines,
// transcribe/chunk/polish, results, brand outro. Ported from the mock's
// file-demo.js onto the shared motion controller and enhance() scope.
import { keepRoot, enableControls, on } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const scenes = [...root.querySelectorAll('.fd-scene')];
  const bars = [...root.querySelectorAll('.fd-progress i')];
  const toggle = root.querySelector('[data-fd-toggle]');
  const caption = root.querySelector('[data-fd-caption]');
  const process = root.querySelector('[data-fd-process]');
  const workNote = root.querySelector('[data-fd-work-note]');
  const passages = [...root.querySelectorAll('.fd-passage')];
  const durations = [4600, 5200, 8500, 5100, 4100];
  const captions = [
    'Bring your audio or video',
    'Local or cloud. Your choice.',
    'Transcribing, chunking, polishing',
    'Your recording, ready to read',
    'Powered by EnviousWispr',
  ];
  const total = durations.reduce((a, b) => a + b, 0);
  let elapsed = 0;
  let paused = false;
  let timeline;

  function controls() {
    const stopped = paused || !motion.allowed();
    toggle.textContent = stopped ? '▶' : 'Ⅱ';
    toggle.setAttribute('aria-label', stopped ? 'Play demo' : 'Pause demo');
    toggle.disabled = motion.reduced.matches;
    root.dataset.playing = String(!stopped);
  }
  function draw() {
    let rest = elapsed;
    let index = 0;
    while (index < durations.length - 1 && rest >= durations[index]) rest -= durations[index++];
    const p = rest / durations[index];
    root.dataset.scene = String(index);
    scenes.forEach((scene, i) => scene.classList.toggle('is-active', i === index));
    bars.forEach((bar, i) => bar.style.setProperty('--fill', i < index ? 1 : i === index ? p : 0));
    caption.textContent = captions[index];
    const drag = Math.min(1, Math.max(0, (p - 0.12) / 0.45));
    const ease = 1 - Math.pow(1 - drag, 3);
    root.style.setProperty('--drag-x', `${(1 - ease) * 82}px`);
    root.style.setProperty('--drag-y', `${(1 - ease) * -55}px`);
    root.style.setProperty('--drag-turn', `${(1 - ease) * -9}deg`);
    root.dataset.dropped = String(p > 0.62);
    root.dataset.selected = p > 0.55 ? 'both' : p > 0.23 ? 'transcription' : 'none';
    const phase = p < 0.24 ? 0 : p < 0.43 ? 1 : 2;
    root.dataset.process = String(phase);
    process.textContent = ['Transcribing your recording.', 'Making room for every passage.', 'Polishing, passage by passage.'][phase];
    const clean = phase === 2 ? Math.min(4, Math.floor(((p - 0.43) / 0.5) * 4)) : 0;
    passages.forEach((part, i) => {
      part.classList.toggle('clean', i < clean);
      part.classList.toggle('working', phase === 2 && i === clean);
    });
    workNote.textContent =
      phase === 0
        ? 'Writing down every word.'
        : phase === 1
          ? 'Dividing the transcript into manageable passages.'
          : clean === 4
            ? 'Bringing it together into one document.'
            : `Cleaning passage ${clean + 1} of 4 with EG-1.`;
    root.style.setProperty(
      '--work-progress',
      phase === 0 ? (p / 0.24) * 0.12 : phase === 1 ? 0.12 + ((p - 0.24) / 0.19) * 0.08 : 0.2 + ((p - 0.43) / 0.57) * 0.8,
    );
    controls();
  }
  timeline = scope.timeline(
    root,
    (delta) => {
      if (paused) return false;
      elapsed = (elapsed + delta) % total;
      draw();
      return true;
    },
    (reduced) => {
      if (reduced) {
        elapsed = 0;
        draw();
      }
      controls();
    },
  );
  if (scope.signal.aborted) return;
  on(scope, toggle, 'click', () => {
    if (motion.reduced.matches) return;
    const shouldPlay = paused || !motion.allowed();
    if (shouldPlay && motion.paused) motion.setPaused(false);
    paused = !shouldPlay;
    controls();
    timeline.wake({ allowFocused: true });
  });
  on(scope, document, 'home:motion', controls);
  draw();
  enableControls(root);
  controls();
}
