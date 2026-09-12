import { createCarousel } from './carousel.js';

export function init(root, motion, scope) {
  const choices = root.querySelector('#polish-dots'),
    buttons = [...choices.querySelectorAll('button')],
    prev = root.querySelector('#polish-prev'),
    next = root.querySelector('#polish-next'),
    count = root.querySelector('#polish-count'),
    raws = [...root.querySelectorAll('.polish-raw')];
  const announce = document.createElement('span');
  announce.className = 'visually-hidden';
  announce.setAttribute('role', 'status');
  root.append(announce);
  let elapsed = 0,
    pinned = false,
    reveal = 0,
    direction = 1,
    prepared,
    clock;
  function finishExamples() {
    raws.forEach((raw) => raw.classList.add('is-live'));
    prepared = undefined;
    reveal = 0;
  }
  const carousel = createCarousel(root.querySelector('.polish-carousel'), scope, motion, {
    onManual() {
      if (pinned) return;
      pinned = true;
      elapsed = 0;
      finishExamples();
      root.querySelector('.polish-nav').classList.add('is-used');
    },
    onSettle(index, { manual }) {
      if (prepared === index && !pinned && !motion.paused && !motion.reduced.matches) {
        reveal = 340;
        prepared = undefined;
      } else finishExamples();
      elapsed = 0;
      sync(index);
      if (manual) {
        const card = carousel.slides[index];
        announce.textContent =
          card.querySelector('h3').textContent +
          '. ' +
          card.querySelector('.polish-out').textContent;
      }
      clock?.wake();
    },
  });
  function sync(index) {
    count.textContent = `${index + 1} of ${buttons.length}`;
    prev.disabled = index === 0;
    next.disabled = index === buttons.length - 1;
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
  }
  buttons.forEach((button, i) => {
    button.disabled = false;
    button.addEventListener('click', () => carousel.goTo(i, { user: true }), {
      signal: scope.signal,
    });
  });
  choices.addEventListener(
    'keydown',
    (event) => {
      const by = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
      if (!by) return;
      event.preventDefault();
      const target = Math.max(
        0,
        Math.min(buttons.length - 1, buttons.indexOf(event.target) + by),
      );
      carousel.goTo(target, { user: true });
      buttons[target].focus();
    },
    { signal: scope.signal },
  );
  prev.addEventListener('click', () => carousel.step(-1, { user: true }), {
    signal: scope.signal,
  });
  next.addEventListener('click', () => carousel.step(1, { user: true }), {
    signal: scope.signal,
  });
  clock = scope.timeline(
    root,
    (delta) => {
      if (carousel.moving || carousel.interacting) return true;
      if (reveal > 0) {
        reveal -= delta;
        if (reveal <= 0) raws[carousel.index].classList.add('is-live');
      }
      if (pinned) return reveal > 0;
      elapsed += delta;
      if (elapsed >= 4200) {
        elapsed = 0;
        if (carousel.index === buttons.length - 1) direction = -1;
        else if (carousel.index === 0) direction = 1;
        prepared = carousel.index + direction;
        raws[prepared].classList.remove('is-live');
        carousel.goTo(prepared);
      }
      return true;
    },
    () => {
      if (motion.reduced.matches || motion.paused) finishExamples();
    },
  );
  sync(carousel.index);
}
