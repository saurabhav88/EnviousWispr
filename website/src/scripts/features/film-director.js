// One feature film (#2816): the four-phase story (listening, working,
// writing, result) for the dictionary, snippets, quick-add, correction and
// live-preview shells. Ported from the mock's film-director.js; scene data
// comes from the node's data-scenes attribute, rendered by FeatureFilm.astro.
// The live-preview renderer is imported only by the preview film, so pages
// without it never load native-preview.js.
import { DURATIONS, STATUS_WORDS } from '../../data/features/films.js';
import { guarded, keepRoot, enableControls, on } from './guard.js';

const pauseSvg =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M9 5v14M15 5v14"/></svg>';
const playSvg =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="m9 5 11 7-11 7z"/></svg>';

/** Write `value` into `el`, wrapping each mark in <mark>, showing only the first `count` characters. */
function text(el, value, marks = [], count = Infinity) {
  if (!el) return;
  const shown = Array.from(value).slice(0, count).join('');
  const key = shown + '|' + marks.join('|');
  if (el._renderKey === key) return;
  el._renderKey = key;
  el.replaceChildren();
  const hits = [];
  for (const word of marks) {
    const i = shown.indexOf(word);
    if (i >= 0) hits.push({ i, word });
  }
  hits.sort((a, b) => a.i - b.i);
  let pos = 0;
  for (const hit of hits) {
    if (hit.i < pos) continue;
    el.append(document.createTextNode(shown.slice(pos, hit.i)));
    const mark = document.createElement('mark');
    mark.textContent = hit.word;
    el.append(mark);
    pos = hit.i + hit.word.length;
  }
  el.append(document.createTextNode(shown.slice(pos)));
}

export function init(node, motion, scope) {
  const kind = node.dataset.film;
  const duration = DURATIONS[kind];
  if (!duration) throw new Error('film: unknown kind ' + kind);
  const scenes = JSON.parse(node.dataset.scenes);
  const total = duration.reduce((a, b) => a + b, 0);
  keepRoot(node, scope);
  const raw = node.querySelector('[data-film-raw]');
  const play = node.querySelector('[data-film-play]');
  const title = node.querySelector('[data-film-title]');
  const where = node.querySelector('[data-film-where]');
  const status = node.querySelector('[data-film-status]');
  const count = node.querySelector('[data-film-count]');
  const saved = node.querySelector('[data-film-saved]');
  const choices = [...node.querySelectorAll('[data-film-choice]')];
  let out = node.querySelector('[data-film-out]');
  let native = null;
  let index = 0;
  let elapsed = 0;
  let stopped = false;
  let pinned = false;
  let clock;

  function controls() {
    const active = !stopped && motion.allowed();
    play.innerHTML = active ? pauseSvg : playSvg;
    play.setAttribute('aria-label', active ? 'Pause animation' : elapsed >= total ? 'Replay animation' : 'Play animation');
    play.setAttribute('aria-pressed', String(!active));
  }
  function stage() {
    let remainder = elapsed;
    for (let p = 0; p < duration.length; p++) {
      if (remainder < duration[p]) return [p, remainder / duration[p]];
      remainder -= duration[p];
    }
    return [3, 1];
  }
  function render(forceFinal = false) {
    const sample = scenes[index];
    const [stagePhase, stageProgress] = stage();
    const phase = forceFinal ? 3 : stagePhase;
    const progress = forceFinal ? 1 : stageProgress;
    node.dataset.phase = ['listening', 'working', 'writing', 'result'][phase];
    node.dataset.route = 'local';
    title.textContent = sample.title;
    where.textContent = sample.where;
    count.textContent = index + 1 + ' of ' + scenes.length;
    if (saved) saved.textContent = sample.saved || '';
    choices.forEach((button, i) => {
      button.classList.toggle('selected', i === index);
      button.setAttribute('aria-pressed', String(i === index));
    });
    for (const el of [raw, out]) if (el) el.lang = sample.lang || 'en';
    const words = STATUS_WORDS[kind] ?? STATUS_WORDS.default;
    status.textContent = phase === 3 ? sample.explain : words[phase];
    if (kind === 'quickadd') {
      text(raw, sample.raw, sample.raw_marks || []);
      text(out, sample.out);
    } else if (kind === 'preview') {
      const chars = Array.from(sample.raw);
      const draft = phase === 0 ? chars.slice(0, Math.max(1, Math.floor(chars.length * progress))).join('') : sample.raw;
      if (native) native.set('listening', draft, Math.min(elapsed, duration[0]));
      else if (out) out.textContent = draft;
    } else {
      text(
        raw,
        sample.raw,
        sample.raw_marks || [],
        phase === 0 ? Math.max(1, Math.floor(Array.from(sample.raw).length * Math.min(1, progress * 1.2))) : Infinity,
      );
      const outputCount =
        phase < 2 ? 0 : phase === 2 && kind !== 'snippets' ? Math.max(1, Math.ceil(Array.from(sample.out).length * progress)) : Infinity;
      text(out, sample.out, sample.out_marks || [], outputCount);
    }
    controls();
  }
  function settle() {
    if (kind === 'quickadd') {
      elapsed = duration[0] + duration[1] / 2;
      render();
    } else {
      elapsed = total;
      render(true);
    }
  }
  function select(next) {
    index = (next + scenes.length) % scenes.length;
    elapsed = total;
    pinned = true;
    stopped = true;
    render(true);
    clock?.wake({ allowFocused: true });
  }

  clock = scope.timeline(
    node,
    (delta) => {
      if (stopped) return false;
      elapsed += delta;
      if (elapsed >= total) {
        if (pinned) {
          stopped = true;
          settle();
          return false;
        }
        elapsed = 0;
        index = (index + 1) % scenes.length;
      }
      render();
      return true;
    },
    (reduced) => {
      if (reduced || motion.paused) settle();
      controls();
    },
  );
  if (scope.signal.aborted) return;
  on(scope, play, 'click', () => {
    if (motion.reduced.matches) {
      stopped = true;
      settle();
      return;
    }
    if (!stopped && motion.allowed()) {
      stopped = true;
      render();
      clock.wake({ allowFocused: true });
      return;
    }
    if (motion.paused) motion.setPaused(false);
    if (elapsed >= total) elapsed = 0;
    stopped = false;
    pinned = true;
    render();
    clock.wake({ allowFocused: true });
  });
  const prev = node.querySelector('[data-film-prev]');
  const next = node.querySelector('[data-film-next]');
  if (prev) on(scope, prev, 'click', () => select(index - 1));
  if (next) on(scope, next, 'click', () => select(index + 1));
  choices.forEach((button, i) => on(scope, button, 'click', () => select(i)));
  on(scope, node, 'keydown', (event) => {
    if (!event.target.matches('[data-film-choice]')) return;
    const shift = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (shift) {
      event.preventDefault();
      select(index + shift);
      choices[index].focus();
    }
  });
  on(scope, document, 'home:motion', controls);
  on(scope, window, 'pagehide', () => (node.dataset.animate = 'paused'));

  // The live-preview film owns its nested preview node; the real well replaces
  // the build-time snapshot once its module arrives. Until then the snapshot's
  // words element takes the draft text.
  if (kind === 'preview') {
    import('../home/native-preview.js')
      .then(
        guarded(scope, (module) => {
          native = module.createNativePreview();
          native.well.querySelector('.hero-native-words').setAttribute('data-film-out', '');
          node.querySelector('[data-native-preview]').replaceChildren(native.well);
          native.well.hidden = false;
          out = native.well.querySelector('.hero-native-words');
          render(stopped);
        }),
      )
      .catch((error) => {
        if (!scope.signal.aborted) scope.fallback(error);
      });
  }
  if (motion.reduced.matches || motion.paused) settle();
  else render();
  enableControls(node);
}
