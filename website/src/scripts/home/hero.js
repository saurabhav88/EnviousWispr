import examples from '../../data/home/hero.json';
import { mountDemo } from './demo.js';

export function init(root, motion, scope) {
  const canvas = root.querySelector('#opening-app');
  const replay = root.querySelector('#hero-replay'),
    next = root.querySelector('#hero-next');
  const title = root.querySelector('.hero-screen-chrome>span:last-child');
  const announcement = root.querySelector('.hero-demo-announcement');
  const endSpeech = 4800,
    endTranscribe = 5200,
    endPolish = 6100,
    endExample = 11600;
  let index = 0,
    elapsed = 0,
    manual = false,
    replayOnly = false,
    demo;
  function mount() {
    const example = examples[index];
    demo = mountDemo(canvas, example.app, example.context, { hero: true });
    canvas.dataset.example = example.app;
    title.textContent = `EnviousWispr in ${example.name} · ${index + 1} / ${examples.length}`;
  }
  function render() {
    const example = examples[index];
    const t = motion.reduced.matches ? endPolish : elapsed;
    const phase =
      t < endSpeech
        ? 'listening'
        : t < endTranscribe
          ? 'transcribing'
          : t < endPolish
            ? 'polishing'
            : 'finished';
    root.dataset.phase = phase;
    const words = example.raw.split(' '),
      count = Math.max(0, Math.min(words.length, Math.ceil(((t - 200) / 4200) * words.length)));
    demo.set(phase, words.slice(0, count).join(' '), example.text, t);
    for (const item of root.querySelectorAll('[data-hero-step]'))
      item.classList.toggle(
        'is-current',
        item.dataset.heroStep ===
          (phase === 'finished' ? 'finished' : phase === 'listening' ? 'listening' : 'processing'),
      );
    replay.disabled = motion.paused || motion.reduced.matches;
    if (manual && phase === 'finished') {
      announcement.textContent = `Finished ${example.name} draft. Nothing has been sent.`;
      manual = false;
    }
  }
  function advance(isManual = false) {
    index = (index + 1) % examples.length;
    elapsed = isManual ? endPolish : 0;
    manual = isManual;
    mount();
    render();
  }
  mount();
  const clock = scope.timeline(
    root.querySelector('.hero-product-demo'),
    (delta) => {
      elapsed += delta;
      if (replayOnly && elapsed >= endPolish) {
        render();
        return false;
      }
      if (elapsed >= endExample) advance();
      else render();
      return true;
    },
    render,
  );
  replay.addEventListener(
    'click',
    () => {
      elapsed = 0;
      manual = true;
      replayOnly = true;
      announcement.textContent = '';
      render();
      clock.wake({ allowFocused: true });
    },
    { signal: scope.signal },
  );
  next.addEventListener(
    'click',
    () => {
      replayOnly = true;
      advance(true);
      clock.wake();
    },
    { signal: scope.signal },
  );
  next.disabled = false;
  const measure = () =>
    root.style.setProperty(
      '--intro-copy-height',
      root.querySelector('.screen-hero-copy').offsetHeight + 'px',
    );
  const observer = new ResizeObserver(measure);
  observer.observe(root.querySelector('.screen-hero-copy'));
  scope.defer(() => observer.disconnect());
  measure();
  render();
}
