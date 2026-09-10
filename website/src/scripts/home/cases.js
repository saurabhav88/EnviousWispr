import cases from '../../data/home/cases.json';
import { mountDemo } from './demo.js';
import { bindSwipe } from './swipe.js';
const apps = ['vscode', 'clinical', 'keep', 'gmail', 'docs', 'slack', 'discord', 'notes', 'teams'];
export function init(root, motion, scope) {
  const stage = root.querySelector('.case-stage'),
    screen = root.querySelector('.case-screen'),
    art = root.querySelector('.case-scene');
  const assets = JSON.parse(stage.dataset.caseAssets),
    choices = root.querySelector('.audience-choices'),
    buttons = [...choices.querySelectorAll('button')];
  const tour = root.querySelector('#case-tour'),
    prev = root.querySelector('#case-prev'),
    next = root.querySelector('#case-next');
  let index = 0,
    artIndex = 0,
    elapsed = 0,
    auto = true,
    generation = 0,
    demo,
    clock,
    hovered = false;
  const phoneSizer = new ResizeObserver(() => {
    const phone = screen.querySelector('.host-keep');
    if (phone)
      screen.style.setProperty('--phone-well', Math.max(120, phone.clientWidth - 22) + 'px');
  });
  scope.defer(() => {
    generation++;
    phoneSizer.disconnect();
  });
  const announcement = document.createElement('span');
  announcement.className = 'visually-hidden';
  announcement.setAttribute('role', 'status');
  root.append(announcement);
  function render() {
    const item = cases[index],
      speech = index === 1 ? 4800 : 2200,
      phase =
        motion.reduced.matches || motion.paused || elapsed >= speech + 500
          ? 'finished'
          : elapsed < speech
            ? 'listening'
            : 'processing';
    const count = Math.min(
      item.raw.length,
      Math.max(2, Math.floor((elapsed / (speech * 0.96)) * item.raw.length)),
    );
    demo.set(phase, item.raw.slice(0, count), item.final, elapsed);
    tour.disabled = motion.paused || motion.reduced.matches;
    tour.title = motion.reduced.matches
      ? 'Reduced motion is enabled'
      : motion.paused
        ? 'Page animations are paused'
        : '';
  }
  function choose(nextIndex, manual = false) {
    index = nextIndex;
    const item = cases[index],
      current = ++generation;
    if (manual) auto = false;
    elapsed = manual || motion.reduced.matches || motion.paused ? 5400 : 0;
    buttons.forEach((button, i) => button.setAttribute('aria-pressed', String(i === index)));
    const selected = buttons[index];
    if (choices.scrollWidth > choices.clientWidth) {
      const left = selected.offsetLeft,
        right = left + selected.offsetWidth;
      if (left < choices.scrollLeft) choices.scrollLeft = left;
      else if (right > choices.scrollLeft + choices.clientWidth)
        choices.scrollLeft = right - choices.clientWidth;
    }
    stage.dataset.case = String(index);
    root.querySelector('.case-copy h3').textContent = item.title;
    root.querySelector('.case-copy p').textContent = item.note;
    root.querySelector('.case-status').textContent = item.upcoming
      ? 'Android coming soon'
      : item.sampleLabel || '';
    screen.classList.toggle('is-phone', item.upcoming === true);
    demo = mountDemo(
      screen,
      apps[index],
      {
        to: index === 3 ? 'Jordan' : undefined,
        title:
          index === 4 ? 'City life · Essay draft' : index === 7 ? 'Family message' : 'Story notes',
        room: index === 6 ? 'episode-planning' : undefined,
      },
      { lang: item.lang || 'en' },
    );
    phoneSizer.disconnect();
    if (item.upcoming) phoneSizer.observe(screen.querySelector('.host-keep'));
    root.querySelector('#case-count').textContent = index + 1 + ' / ' + cases.length;
    prev.disabled = index === 0;
    next.disabled = index === cases.length - 1;
    tour.textContent = auto ? 'Pause tour' : 'Play tour';
    render();
    if (manual) announcement.textContent = item.name + '. ' + item.title;
    // The initial picture is already lazy-loaded by the browser. Only subsequent
    // selections need a new decode; text never waits for an illustration.
    if (index !== artIndex) {
      const desired = new Image();
      const asset = assets[index];
      desired.sizes = art.sizes;
      desired.srcset = asset.srcset;
      desired.src = asset.src;
      desired
        .decode()
        .then(() => {
          if (current !== generation || scope.signal.aborted) return;
          art.srcset = asset.srcset;
          art.src = asset.src;
          art.width = asset.width;
          art.height = asset.height;
          artIndex = nextIndex;
          art.alt =
            'Illustrated ' +
            item.name.toLowerCase() +
            ' speaking toward a ' +
            (item.upcoming ? 'phone' : 'computer');
        })
        .catch(() => {
          /* Keep the previously loaded illustration and its accurate alt text. */
        });
    }
  }
  buttons.forEach((button, i) => {
    button.disabled = false;
    button.addEventListener('click', () => choose(i, true), { signal: scope.signal });
  });
  choices.addEventListener(
    'pointerdown',
    () => {
      auto = false;
      tour.textContent = 'Play tour';
    },
    { signal: scope.signal, passive: true },
  );
  prev.addEventListener('click', () => choose(Math.max(0, index - 1), true), {
    signal: scope.signal,
  });
  next.addEventListener('click', () => choose(Math.min(cases.length - 1, index + 1), true), {
    signal: scope.signal,
  });
  tour.disabled = false;
  tour.addEventListener(
    'click',
    () => {
      auto = !auto;
      tour.textContent = auto ? 'Pause tour' : 'Play tour';
      clock.wake({ allowFocused: auto });
    },
    { signal: scope.signal },
  );
  stage.addEventListener(
    'pointerenter',
    (event) => {
      if (event.pointerType === 'mouse') hovered = true;
    },
    { signal: scope.signal },
  );
  stage.addEventListener(
    'pointerleave',
    (event) => {
      if (event.pointerType !== 'mouse') return;
      hovered = false;
      clock.wake();
    },
    { signal: scope.signal },
  );
  choose(0);
  clock = scope.timeline(
    root,
    (delta) => {
      elapsed += delta;
      render();
      if (auto && elapsed > (index === 1 ? 8800 : 6200) && !hovered) {
        choose((index + 1) % cases.length);
        return true;
      }
      return (auto && !hovered) || elapsed < (index === 1 ? 5300 : 2700);
    },
    render,
  );
  bindSwipe(
    stage,
    scope,
    (direction) => {
      choose(Math.max(0, Math.min(cases.length - 1, index + direction)), true);
    },
    (event) => {
      auto = false;
      if (event.pointerType !== 'mouse') hovered = false;
      elapsed = Math.max(elapsed, 5400);
      tour.textContent = 'Play tour';
      render();
    },
  );
}
