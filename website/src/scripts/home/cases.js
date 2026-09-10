import cases from '../../data/home/cases.json';
import { hydrateDemo } from './demo.js';
import { createCarousel } from './carousel.js';

export function init(root, motion, scope) {
  const viewport = root.querySelector('.case-carousel'),
    screens = [...root.querySelectorAll('.case-screen')],
    choices = root.querySelector('.audience-choices'),
    buttons = [...choices.querySelectorAll('button')],
    tour = root.querySelector('#case-tour'),
    prev = root.querySelector('#case-prev'),
    next = root.querySelector('#case-next');
  // Each lazy image stays paired with its own text; playback never waits for decoding (#2765).
  const demos = screens.map((screen, i) =>
    hydrateDemo(screen, cases[i].final, { lang: cases[i].lang || 'en' }),
  );
  const phoneSizer = new ResizeObserver((entries) => {
    for (const { target } of entries)
      target
        .closest('.case-screen')
        .style.setProperty('--phone-well', Math.max(120, target.clientWidth - 22) + 'px');
  });
  root.querySelectorAll('.host-keep').forEach((phone) => phoneSizer.observe(phone));
  scope.defer(() => phoneSizer.disconnect());
  const announcement = document.createElement('span');
  announcement.className = 'visually-hidden';
  announcement.setAttribute('role', 'status');
  root.append(announcement);
  let elapsed = 0,
    auto = true,
    direction = 1,
    prepared,
    clock,
    hovered = false;
  function finishExamples() {
    demos.forEach((demo, i) => demo.set('finished', '', cases[i].final));
    prepared = undefined;
  }
  function sync(index) {
    buttons.forEach((button, i) => button.setAttribute('aria-pressed', String(i === index)));
    const selected = buttons[index];
    if (choices.scrollWidth > choices.clientWidth) {
      const left = selected.offsetLeft,
        right = left + selected.offsetWidth;
      if (left < choices.scrollLeft) choices.scrollLeft = left;
      else if (right > choices.scrollLeft + choices.clientWidth)
        choices.scrollLeft = right - choices.clientWidth;
    }
    root.querySelector('#case-count').textContent = `${index + 1} / ${cases.length}`;
    prev.disabled = index === 0;
    next.disabled = index === cases.length - 1;
    tour.textContent = auto ? 'Pause tour' : 'Play tour';
    tour.disabled = motion.paused || motion.reduced.matches;
    tour.title = motion.reduced.matches
      ? 'Reduced motion is enabled'
      : motion.paused
        ? 'Page animations are paused'
        : '';
  }
  const carousel = createCarousel(viewport, scope, motion, {
    onManual() {
      auto = false;
      elapsed = 5400;
      finishExamples();
      tour.textContent = 'Play tour';
    },
    onSettle(index, { manual, changed }) {
      if (!changed && !manual && prepared === undefined) {
        sync(index);
        return;
      }
      const play = auto && prepared === index && !motion.paused && !motion.reduced.matches;
      finishExamples();
      elapsed = play ? 0 : 5400;
      sync(index);
      render();
      if (manual) announcement.textContent = cases[index].name + '. ' + cases[index].title;
      clock?.wake({ allowFocused: auto });
    },
  });
  function render() {
    const index = carousel.index,
      item = cases[index],
      speech = index === 1 ? 4800 : 2200;
    const phase =
      motion.reduced.matches || motion.paused || elapsed >= speech + 500
        ? 'finished'
        : elapsed < speech
          ? 'listening'
          : 'processing';
    const count = Math.min(
      item.raw.length,
      Math.max(2, Math.floor((elapsed / (speech * 0.96)) * item.raw.length)),
    );
    demos[index].set(phase, item.raw.slice(0, count), item.final, elapsed);
  }
  buttons.forEach((button, i) => {
    button.disabled = false;
    button.addEventListener('click', () => carousel.goTo(i, { user: true }), {
      signal: scope.signal,
    });
  });
  prev.addEventListener('click', () => carousel.step(-1, { user: true }), {
    signal: scope.signal,
  });
  next.addEventListener('click', () => carousel.step(1, { user: true }), {
    signal: scope.signal,
  });
  tour.addEventListener(
    'click',
    () => {
      auto = !auto;
      if (!auto) {
        elapsed = 5400;
        finishExamples();
        if (carousel.moving) carousel.stop();
      } else elapsed = 0;
      sync(carousel.index);
      if (!carousel.moving) render();
      clock.wake({ allowFocused: auto });
    },
    { signal: scope.signal },
  );
  viewport.addEventListener(
    'pointerenter',
    (event) => {
      if (event.pointerType === 'mouse') hovered = true;
    },
    { signal: scope.signal },
  );
  viewport.addEventListener(
    'pointerleave',
    (event) => {
      if (event.pointerType !== 'mouse') return;
      hovered = false;
      clock.wake();
    },
    { signal: scope.signal },
  );
  finishExamples();
  clock = scope.timeline(
    root,
    (delta) => {
      if (carousel.moving || carousel.interacting) return true;
      elapsed += delta;
      render();
      if (auto && !hovered && elapsed > (carousel.index === 1 ? 8800 : 6200)) {
        if (carousel.index === cases.length - 1) direction = -1;
        else if (carousel.index === 0) direction = 1;
        prepared = carousel.index + direction;
        demos[prepared].set(
          'listening',
          cases[prepared].raw.slice(0, 2),
          cases[prepared].final,
        );
        carousel.goTo(prepared);
      }
      return (auto && !hovered) || elapsed < (carousel.index === 1 ? 5300 : 2700);
    },
    () => {
      if (motion.paused || motion.reduced.matches) {
        elapsed = 5400;
        finishExamples();
      }
      sync(carousel.index);
      if (!carousel.moving) render();
    },
  );
}
