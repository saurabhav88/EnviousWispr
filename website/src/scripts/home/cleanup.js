import polish from '../../data/home/polish.json';
import paths from '../../data/home/icons.json';
import { renderTokens } from '../../utils/home/text.js';
const icons = [
  'person',
  'wave',
  'undo',
  'calendar',
  'undo',
  'text',
  'mail',
  'list',
  'document',
  'text',
  'smile',
  'list',
];
export function init(root, motion, scope) {
  const choices = root.querySelector('#polish-dots'),
    buttons = [...choices.querySelectorAll('button')];
  const raw = root.querySelector('#polish-raw'),
    out = root.querySelector('#polish-out'),
    card = root.querySelector('.polish-card');
  const count = root.querySelector('#polish-count'),
    note = root.querySelector('#polish-note');
  const announce = document.createElement('span');
  announce.className = 'visually-hidden';
  announce.setAttribute('role', 'status');
  root.append(announce);
  let index = 0,
    elapsed = 0,
    pinned = false,
    reveal = 0,
    clock;
  function show(next, manual = false) {
    index = (next + polish.chips.length) % polish.chips.length;
    const sample = polish.chips[index];
    root.querySelector('#polish-name').textContent = sample.name;
    note.textContent = sample.note;
    root.querySelector('#polish-active-icon path').setAttribute('d', paths[icons[index]]);
    const where = root.querySelector('#polish-where');
    where.textContent = sample.where === 'mac' ? 'On your Mac' : 'With AI polish';
    where.className = 'polish-where is-' + sample.where;
    raw.innerHTML = renderTokens(sample.raw);
    out.innerHTML = renderTokens(sample.out);
    raw.lang = out.lang = sample.lang || 'en';
    count.textContent = index + 1 + ' of ' + polish.chips.length;
    buttons.forEach((button, i) => {
      button.classList.toggle('is-current', i === index);
      button.setAttribute('aria-current', String(i === index));
    });
    const active = buttons[index];
    if (choices.scrollWidth > choices.clientWidth) {
      const left = active.offsetLeft,
        right = left + active.offsetWidth;
      if (left < choices.scrollLeft) choices.scrollLeft = left;
      else if (right > choices.scrollLeft + choices.clientWidth)
        choices.scrollLeft = right - choices.clientWidth;
    }
    // A manual selection is immediately readable, including while page motion is paused.
    const settled = manual || motion.reduced.matches || motion.paused;
    raw.classList.toggle('is-live', settled);
    reveal = settled ? 0 : 340;
    if (manual) announce.textContent = sample.name + '. ' + sample.out.map((t) => t.t).join('');
  }
  function choose(next) {
    pinned = true;
    elapsed = 0;
    root.querySelector('.polish-nav').classList.add('is-used');
    show(next, true);
    clock.wake();
  }
  buttons.forEach((button, i) => {
    button.disabled = false;
    button.addEventListener('click', () => choose(i), { signal: scope.signal });
  });
  choices.addEventListener(
    'pointerdown',
    () => {
      pinned = true;
    },
    { signal: scope.signal, passive: true },
  );
  for (const [id, direction] of [
    ['polish-prev', -1],
    ['polish-next', 1],
  ]) {
    const button = root.querySelector('#' + id);
    button.disabled = false;
    button.addEventListener('click', () => choose(index + direction), { signal: scope.signal });
  }
  choices.addEventListener(
    'keydown',
    (event) => {
      const by = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
      if (!by) return;
      event.preventDefault();
      choose(index + by);
      buttons[index].focus();
    },
    { signal: scope.signal },
  );
  let touch;
  card.addEventListener(
    'touchstart',
    (event) => {
      const p = event.changedTouches[0];
      touch = { x: p.clientX, y: p.clientY };
    },
    { signal: scope.signal, passive: true },
  );
  card.addEventListener(
    'touchend',
    (event) => {
      if (!touch) return;
      const p = event.changedTouches[0],
        dx = p.clientX - touch.x,
        dy = p.clientY - touch.y;
      touch = null;
      if (Math.abs(dx) > 44 && Math.abs(dx) > Math.abs(dy)) choose(index + (dx < 0 ? 1 : -1));
    },
    { signal: scope.signal, passive: true },
  );
  clock = scope.timeline(
    root,
    (delta) => {
      if (reveal > 0) {
        reveal -= delta;
        if (reveal <= 0) raw.classList.add('is-live');
      }
      if (pinned) return reveal > 0;
      elapsed += delta;
      if (elapsed >= 4200) {
        elapsed = 0;
        show(index + 1);
      }
      return true;
    },
    (reduced) => {
      if (reduced || motion.paused) {
        reveal = 0;
        raw.classList.add('is-live');
      }
    },
  );
  const guards = root.querySelector('#polish-guards'),
    toggle = guards.querySelector('button');
  function setGuards(open) {
    guards.dataset.open = String(open);
    toggle.setAttribute('aria-expanded', String(open));
  }
  toggle.addEventListener(
    'click',
    () => setGuards(toggle.getAttribute('aria-expanded') !== 'true'),
    { signal: scope.signal },
  );
  toggle.hidden = false;
  setGuards(false);
  show(0);
}
