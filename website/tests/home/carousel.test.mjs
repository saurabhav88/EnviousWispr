import test from 'node:test';
import assert from 'node:assert/strict';
import { createCarousel } from '../../src/scripts/home/carousel.js';

// Assert coordination contracts, not browser physics. Scroll completion is explicit.
function fixture(t, nativeEnd = true) {
  const win = new EventTarget(), doc = new EventTarget(), rail = new EventTarget();
  win.cancelAnimationFrame = () => {};
  doc.defaultView = win;
  const controller = new AbortController(), disposers = [], calls = [], settled = [];
  Object.assign(rail, {
    ownerDocument: doc, scrollLeft: 0, clientWidth: 300, scrollWidth: 940, clientLeft: 0,
    getBoundingClientRect: () => ({ left: 0 }),
    scrollTo(options) { calls.push(options); if (options.behavior === 'instant') rail.scrollLeft = options.left; },
    children: [0, 320, 640].map(left => ({ getBoundingClientRect: () => ({ left: left - rail.scrollLeft, width: 300 }) })),
  });
  if (nativeEnd) rail.onscrollend = null;
  const motion = { paused: false, reduced: { matches: false } };
  let manual = 0;
  const carousel = createCarousel(rail, { signal: controller.signal, defer: fn => disposers.push(fn) }, motion,
    { onManual() { manual++; }, onSettle(index, detail) { settled.push({ index, ...detail }); } });
  t.after(() => { controller.abort(); disposers.forEach(fn => fn()); });
  const emit = (target, type, props = {}) => target.dispatchEvent(Object.assign(new Event(type), props));
  return { win, doc, rail, motion, carousel, calls, settled, emit, get manual() { return manual; } };
}
// Node has no ResizeObserver; install only the test environment's constructor.
globalThis.ResizeObserver = class { observe() {} disconnect() {} };

test('pause before the first scroll frame cancels the pending native animation', t => {
  const f = fixture(t);
  f.carousel.goTo(1);
  f.motion.paused = true;
  f.emit(f.doc, 'home:motion');
  assert.deepEqual(f.calls, [{ left: 320, behavior: 'smooth' }, { left: 0, behavior: 'instant' }]);
  assert.equal(f.carousel.moving, false);
});

test('held contact blocks tour advancement without treating vertical contact as selection', t => {
  const f = fixture(t);
  f.emit(f.rail, 'touchstart', { touches: [{}] });
  assert.equal(f.carousel.interacting, true);
  assert.equal(f.manual, 0);
  f.emit(f.win, 'touchend', { touches: [] });
  assert.equal(f.carousel.interacting, false);
  assert.equal(f.manual, 0);
});

test('rapid commands use the pending destination and settling uses actual geometry', t => {
  const f = fixture(t);
  f.carousel.step(1, { user: true });
  f.carousel.step(1, { user: true });
  assert.deepEqual(f.calls.map(c => c.left), [320, 640]);
  f.rail.scrollLeft = 320; // Browser/user interrupted before the requested last card.
  f.emit(f.rail, 'scroll'); f.emit(f.rail, 'scrollend');
  assert.equal(f.carousel.index, 1);
  assert.equal(f.settled.length, 1);
  assert.equal(f.settled[0].manual, true);
});

test('quiet fallback does not settle during held touch and completes after release', async t => {
  const f = fixture(t, false);
  f.emit(f.rail, 'touchstart', { touches: [{}] });
  f.rail.scrollLeft = 320;
  f.emit(f.rail, 'scroll');
  await new Promise(resolve => setTimeout(resolve, 210));
  assert.equal(f.settled.length, 0);
  f.emit(f.win, 'touchend', { touches: [] });
  await new Promise(resolve => setTimeout(resolve, 210));
  assert.equal(f.carousel.index, 1);
  assert.equal(f.settled.length, 1);
});
