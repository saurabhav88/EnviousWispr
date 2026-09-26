import test from 'node:test';
import assert from 'node:assert/strict';
import { createCarousel } from '../../src/scripts/home/carousel.js';

// Assert coordination contracts, not browser physics. Scroll completion is explicit.
function fixture(t, nativeEnd = true) {
  const win = new EventTarget(),
    doc = new EventTarget(),
    rail = new EventTarget();
  const frames = [];
  win.requestAnimationFrame = (fn) => frames.push(fn);
  win.cancelAnimationFrame = () => {};
  doc.defaultView = win;
  const controller = new AbortController(),
    disposers = [],
    calls = [],
    settled = [],
    previews = [];
  Object.assign(rail, {
    ownerDocument: doc,
    scrollLeft: 0,
    clientWidth: 300,
    scrollWidth: 940,
    clientLeft: 0,
    getBoundingClientRect: () => ({ left: 0 }),
    scrollTo(options) {
      calls.push(options);
      if (options.behavior === 'instant') rail.scrollLeft = options.left;
    },
    children: [0, 320, 640].map((left) => ({
      getBoundingClientRect: () => ({ left: left - rail.scrollLeft, width: 300 }),
    })),
  });
  if (nativeEnd) rail.onscrollend = null;
  const motion = { paused: false, reduced: { matches: false } };
  let manual = 0;
  const carousel = createCarousel(
    rail,
    { signal: controller.signal, defer: (fn) => disposers.push(fn) },
    motion,
    {
      onManual() {
        manual++;
      },
      onSettle(index, detail) {
        settled.push({ index, ...detail });
      },
      onPreview(index) {
        previews.push(index);
      },
    },
  );
  t.after(() => {
    controller.abort();
    disposers.forEach((fn) => fn());
  });
  const emit = (target, type, props = {}) =>
    target.dispatchEvent(Object.assign(new Event(type), props));
  return {
    win,
    doc,
    rail,
    motion,
    carousel,
    calls,
    settled,
    previews,
    flushFrames: () => frames.splice(0).forEach((fn) => fn()),
    emit,
    get manual() {
      return manual;
    },
  };
}
// Node has no ResizeObserver; install only the test environment's constructor.
globalThis.ResizeObserver = class {
  observe() {}
  disconnect() {}
};

test('pause before the first scroll frame cancels the pending native animation', (t) => {
  const f = fixture(t);
  f.carousel.goTo(1);
  f.motion.paused = true;
  f.emit(f.doc, 'home:motion');
  assert.deepEqual(f.calls, [
    { left: 320, behavior: 'smooth' },
    { left: 0, behavior: 'instant' },
  ]);
  assert.equal(f.carousel.moving, false);
});

test('held contact blocks tour advancement without treating vertical contact as selection', (t) => {
  const f = fixture(t);
  f.emit(f.rail, 'touchstart', { touches: [{}] });
  assert.equal(f.carousel.interacting, true);
  assert.equal(f.manual, 0);
  f.emit(f.win, 'touchend', { touches: [] });
  assert.equal(f.carousel.interacting, false);
  assert.equal(f.manual, 0);
});

test('rapid commands use the pending destination and settling uses actual geometry', (t) => {
  const f = fixture(t);
  f.carousel.step(1, { user: true });
  f.carousel.step(1, { user: true });
  assert.deepEqual(
    f.calls.map((c) => c.left),
    [320, 640],
  );
  f.rail.scrollLeft = 320; // Browser/user interrupted before the requested last card.
  f.emit(f.rail, 'scroll');
  f.emit(f.rail, 'scrollend');
  assert.equal(f.carousel.index, 1);
  assert.equal(f.settled.length, 1);
  assert.equal(f.settled[0].manual, true);
});

test('quiet fallback does not settle during held touch and completes after release', async (t) => {
  const f = fixture(t, false);
  f.emit(f.rail, 'touchstart', { touches: [{}] });
  f.rail.scrollLeft = 320;
  f.emit(f.rail, 'scroll');
  await new Promise((resolve) => setTimeout(resolve, 210));
  assert.equal(f.settled.length, 0);
  f.emit(f.win, 'touchend', { touches: [] });
  await new Promise((resolve) => setTimeout(resolve, 210));
  assert.equal(f.carousel.index, 1);
  assert.equal(f.settled.length, 1);
});


test('a new explicit selection notifies the tour owner even after stationary focus', (t) => {
  const f = fixture(t);
  f.emit(f.rail, 'focusin');
  assert.equal(f.manual, 1);
  // The section may restart its tour between these two independent actions.
  f.carousel.goTo(1, { user: true });
  assert.equal(f.manual, 2);
});

// Codex P2 on #2768: a stale marker made the first automatic slide after "Play tour" announce itself.
for (const [name, takeover] of [
  ['stationary focus', (f) => f.emit(f.rail, 'focusin')],
  ['a sideways wheel that cannot scroll', (f) => f.emit(f.rail, 'wheel', { deltaX: 40, deltaY: 0 })],
]) {
  test(`${name} stops the tour without marking the next automatic slide manual`, (t) => {
    const f = fixture(t);
    takeover(f);
    assert.equal(f.manual, 1);
    f.carousel.goTo(1); // The visitor pressed "Play tour"; this is the tour's first move.
    f.rail.scrollLeft = 320;
    f.emit(f.rail, 'scroll');
    f.emit(f.rail, 'scrollend');
    assert.deepEqual(f.settled, [{ index: 1, changed: true, manual: false }]);
  });
}

test('focus that interrupts an automatic slide still settles it as the visitor’s', (t) => {
  const f = fixture(t);
  f.carousel.goTo(1);
  f.emit(f.rail, 'focusin');
  assert.equal(f.manual, 1);
  assert.deepEqual(f.settled, [{ index: 0, changed: false, manual: true }]);
});

// Founder UAT 2026-09-25: the category highlight waited for the scroll to finish.
test('a picked card is shown at once, before the rail arrives', (t) => {
  const f = fixture(t);
  f.carousel.goTo(2, { user: true });
  assert.deepEqual(f.previews, [2]);
  assert.equal(f.settled.length, 0);
});

test('a free swipe shows each card it passes while still moving', (t) => {
  const f = fixture(t);
  for (const left of [100, 200, 480, 640]) {
    f.rail.scrollLeft = left;
    f.emit(f.rail, 'scroll');
    f.flushFrames();
  }
  assert.deepEqual(f.previews, [1, 2]);
  assert.equal(f.settled.length, 0);
  f.emit(f.rail, 'scrollend');
  assert.deepEqual(f.settled.map((s) => s.index), [2]);
});

test('a swipe that springs back restores the shown card', (t) => {
  const f = fixture(t);
  f.rail.scrollLeft = 200;
  f.emit(f.rail, 'scroll');
  f.flushFrames();
  f.rail.scrollLeft = 0;
  f.emit(f.rail, 'scrollend');
  assert.deepEqual(f.previews, [1]);
  assert.deepEqual(f.settled, [{ index: 0, changed: false, manual: true }]);
});
