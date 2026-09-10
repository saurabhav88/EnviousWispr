/** Native scrolling owns movement; this adapter synchronizes settled selection. */
export function createCarousel(viewport, scope, motion, { onManual, onSettle }) {
  const slides = [...viewport.children],
    doc = viewport.ownerDocument,
    win = doc.defaultView,
    hasScrollEnd = 'onscrollend' in viewport,
    pointers = new Set(),
    keys = new Set();
  let index = 0,
    pending,
    moving = false,
    manual = false,
    ended = false,
    touches = 0,
    timer,
    resizeFrame,
    lastLeft = viewport.scrollLeft;
  const listen = (target, event, handler, options = {}) =>
    target.addEventListener(event, handler, { ...options, signal: scope.signal });
  const held = () => touches > 0 || pointers.size > 0 || keys.size > 0;
  const blocked = () => motion.paused || motion.reduced.matches || doc.hidden;
  function nearest() {
    const center = viewport.getBoundingClientRect().left + viewport.clientWidth / 2;
    let best = 0,
      distance = Infinity;
    slides.forEach((slide, i) => {
      const rect = slide.getBoundingClientRect(),
        next = Math.abs(rect.left + rect.width / 2 - center);
      if (next < distance) {
        best = i;
        distance = next;
      }
    });
    return best;
  }
  function finish(force = false) {
    if (held() && !force) {
      ended = true;
      return;
    }
    ended = false;
    clearTimeout(timer);
    const next = nearest(),
      changed = next !== index,
      wasMoving = moving;
    index = next;
    pending = undefined;
    moving = false;
    lastLeft = viewport.scrollLeft;
    const wasManual = manual;
    manual = false;
    if (wasMoving || changed) onSettle(index, { changed, manual: wasManual });
  }
  function fallback() {
    clearTimeout(timer);
    if (!held()) timer = setTimeout(() => finish(), 180);
  }
  function takeControl() {
    pending = undefined;
    if (!manual) {
      manual = true;
      onManual();
    }
  }
  function goTo(next, { user = false, instant = false } = {}) {
    const target = Math.max(0, Math.min(slides.length - 1, next));
    if (user) takeControl();
    const left = Math.max(
      0,
      Math.min(
        viewport.scrollWidth - viewport.clientWidth,
        viewport.scrollLeft +
          slides[target].getBoundingClientRect().left -
          viewport.getBoundingClientRect().left -
          viewport.clientLeft,
      ),
    );
    pending = target;
    ended = false;
    moving = true;
    if (Math.abs(left - viewport.scrollLeft) < 1) {
      viewport.scrollTo({ left, behavior: 'instant' });
      finish(true);
      return;
    }
    viewport.scrollTo({ left, behavior: instant || blocked() ? 'instant' : 'smooth' });
    if (instant || blocked()) finish(true);
    else if (!hasScrollEnd) fallback();
  }
  function step(direction, options) {
    goTo((pending ?? index) + direction, options);
  }
  function stop() {
    pointers.clear();
    touches = 0;
    keys.clear();
    goTo(nearest(), { instant: true });
  }
  listen(
    viewport,
    'scroll',
    () => {
      const left = viewport.scrollLeft;
      if (Math.abs(left - lastLeft) < 0.5) return;
      lastLeft = left;
      moving = true;
      if (pending === undefined) takeControl();
      if (!hasScrollEnd) fallback();
    },
    { passive: true },
  );
  if (hasScrollEnd) listen(viewport, 'scrollend', () => finish());
  listen(
    viewport,
    'pointerdown',
    (event) => {
      pointers.add(event.pointerId);
      if (pending !== undefined) takeControl();
    },
    { passive: true },
  );
  for (const type of ['pointerup', 'pointercancel']) {
    listen(
      win,
      type,
      (event) => {
        pointers.delete(event.pointerId);
        if (moving && (!hasScrollEnd || ended)) fallback();
      },
      { passive: true },
    );
  }
  listen(
    viewport,
    'touchstart',
    (event) => {
      touches = event.touches.length;
    },
    { passive: true },
  );
  for (const type of ['touchend', 'touchcancel']) {
    listen(
      win,
      type,
      (event) => {
        touches = event.touches.length;
        if (moving && (!hasScrollEnd || ended)) fallback();
      },
      { passive: true },
    );
  }
  listen(
    viewport,
    'wheel',
    (event) => {
      if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) takeControl();
    },
    { passive: true },
  );
  listen(viewport, 'keydown', (event) => {
    if (event.target !== viewport) return;
    const direction = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (!direction) return;
    event.preventDefault();
    keys.add(event.key);
    step(direction, { user: true });
  });
  listen(win, 'keyup', (event) => {
    keys.delete(event.key);
    if (moving && (!hasScrollEnd || ended)) fallback();
  });
  listen(viewport, 'focusin', () => {
    takeControl();
    if (moving) stop();
  });
  listen(win, 'blur', stop);
  listen(doc, 'home:motion', () => {
    if (blocked() && moving) stop();
  });
  listen(doc, 'visibilitychange', () => {
    if (doc.hidden && moving) stop();
  });
  const observer = new ResizeObserver(() => {
    win.cancelAnimationFrame(resizeFrame);
    resizeFrame = win.requestAnimationFrame(() => goTo(pending ?? index, { instant: true }));
  });
  observer.observe(viewport);
  index = nearest();
  scope.defer(() => {
    observer.disconnect();
    clearTimeout(timer);
    win.cancelAnimationFrame(resizeFrame);
  });
  return {
    slides,
    goTo,
    step,
    stop,
    get index() {
      return index;
    },
    get moving() {
      return moving;
    },
    get interacting() {
      return held();
    },
  };
}
