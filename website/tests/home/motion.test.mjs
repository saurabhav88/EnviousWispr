import test from 'node:test';
import assert from 'node:assert/strict';
import { createMotionController } from '../../src/scripts/home/motion.js';

// Protect animation eligibility and failure isolation. Real layout and media
// queries are validated separately in the production browser.
class Node extends EventTarget {
  dataset = {};
  isConnected = true;
  contains(value) {
    return value === this;
  }
}
function rig() {
  const window = new EventTarget(),
    document = new EventTarget(),
    media = new EventTarget();
  media.matches = false;
  Object.assign(document, {
    hidden: false,
    activeElement: null,
    documentElement: { dataset: {} },
    querySelectorAll: () => [],
  });
  const frames = new Map(),
    observers = new Set(),
    errors = [];
  let id = 0;
  class Observer {
    constructor(callback) {
      this.callback = callback;
      observers.add(this);
    }
    observe(node) {
      this.node = node;
    }
    disconnect() {
      observers.delete(this);
    }
  }
  const env = Object.assign(window, {
    document,
    matchMedia: () => media,
    IntersectionObserver: Observer,
    AbortController,
    Event,
    requestAnimationFrame: (fn) => {
      frames.set(++id, fn);
      return id;
    },
    cancelAnimationFrame: (n) => frames.delete(n),
    console: { error: (...args) => errors.push(args) },
  });
  const motion = createMotionController(env);
  return {
    motion,
    document,
    window,
    errors,
    frames,
    observers,
    visible(node, value = true) {
      for (const observer of observers)
        if (observer.node === node) observer.callback([{ isIntersecting: value }]);
    },
    step(now = 100) {
      const callbacks = [...frames.values()];
      frames.clear();
      callbacks.forEach((fn) => fn(now));
    },
    reduce(value) {
      media.matches = value;
      media.dispatchEvent(new Event('change'));
    },
  };
}

test('offscreen tasks do no work; entering and leaving view starts and stops frames', () => {
  const r = rig(),
    node = new Node();
  let ticks = 0;
  r.motion.timeline(node, () => {
    ticks++;
    return true;
  });
  assert.equal(r.frames.size, 0);
  r.visible(node);
  assert.equal(r.frames.size, 1);
  r.step();
  assert.equal(ticks, 1);
  r.visible(node, false);
  assert.equal(r.frames.size, 0);
  r.step();
  assert.equal(ticks, 1);
  r.motion.dispose();
});
test('page pause cannot be overridden by a manual wake', () => {
  const r = rig(),
    node = new Node();
  const clock = r.motion.timeline(node, () => true);
  r.visible(node);
  r.motion.setPaused(true);
  clock.wake({ allowFocused: true });
  assert.equal(r.frames.size, 0);
  assert.equal(r.document.documentElement.dataset.motion, 'paused');
  r.motion.setPaused(false);
  assert.equal(r.frames.size, 1);
  r.motion.dispose();
});
test('keyboard focus pauses autoplay, but an explicit replay can run until focus moves', () => {
  const r = rig(),
    node = new Node();
  const clock = r.motion.timeline(node, () => true);
  r.visible(node);
  node.dispatchEvent(new Event('focusin'));
  assert.equal(r.frames.size, 0);
  clock.wake({ allowFocused: true });
  assert.equal(r.frames.size, 1);
  node.dispatchEvent(new Event('focusin'));
  assert.equal(r.frames.size, 0);
  const event = new Event('focusout');
  Object.defineProperty(event, 'relatedTarget', { value: null });
  node.dispatchEvent(event);
  assert.equal(r.frames.size, 1);
  r.motion.dispose();
});
test('reduced motion settles the demo and cancels queued work', () => {
  const r = rig(),
    node = new Node();
  const preferences = [];
  r.motion.timeline(
    node,
    () => true,
    (value) => preferences.push(value),
  );
  r.visible(node);
  r.reduce(true);
  assert.equal(r.frames.size, 0);
  assert.equal(preferences.at(-1), true);
  r.reduce(false);
  assert.equal(r.frames.size, 1);
  assert.equal(preferences.at(-1), false);
  r.motion.dispose();
});
test('a finished manual example stops its clock until explicitly woken', () => {
  const r = rig(),
    node = new Node();
  let ticks = 0;
  const clock = r.motion.timeline(node, () => {
    ticks++;
    return false;
  });
  r.visible(node);
  r.step();
  assert.equal(ticks, 1);
  assert.equal(r.frames.size, 0);
  clock.wake();
  r.step();
  assert.equal(ticks, 2);
  assert.equal(r.frames.size, 0);
  r.motion.dispose();
});
test('one throwing animation does not prevent another from advancing', () => {
  const r = rig(),
    bad = new Node(),
    good = new Node();
  let failures = 0,
    ticks = 0;
  r.motion.timeline(
    bad,
    () => {
      throw Error('broken demo');
    },
    undefined,
    () => failures++,
  );
  r.motion.timeline(good, () => {
    ticks++;
    return true;
  });
  r.visible(bad);
  r.visible(good);
  r.step();
  r.step(200);
  assert.equal(failures, 1);
  assert.equal(ticks, 2);
  assert.equal(r.errors.length, 1);
  assert.equal(r.frames.size, 1);
  r.motion.dispose();
});
test('background and page-cache suspension preserve manual pause', () => {
  const r = rig(),
    node = new Node();
  r.motion.timeline(node, () => true);
  r.visible(node);
  r.document.hidden = true;
  r.document.dispatchEvent(new Event('visibilitychange'));
  assert.equal(r.frames.size, 0);
  r.document.hidden = false;
  r.document.dispatchEvent(new Event('visibilitychange'));
  assert.equal(r.frames.size, 1);
  r.window.dispatchEvent(new Event('pagehide'));
  assert.equal(r.frames.size, 0);
  r.motion.setPaused(true);
  r.window.dispatchEvent(new Event('pageshow'));
  assert.equal(r.frames.size, 0);
  r.motion.setPaused(false);
  assert.equal(r.frames.size, 1);
  r.motion.dispose();
});
test('resuming after hidden time does not advance the demo by that elapsed time', () => {
  const r = rig(),
    node = new Node(),
    deltas = [];
  r.motion.timeline(node, (delta) => {
    deltas.push(delta);
    return true;
  });
  r.visible(node);
  r.step(100);
  r.step(120);
  r.visible(node, false);
  r.visible(node, true);
  r.step(90000);
  assert.deepEqual(deltas, [0, 20, 0]);
  r.motion.dispose();
});
test('disposing a timeline releases its observer and prevents future wakeups', () => {
  const r = rig(),
    node = new Node();
  const clock = r.motion.timeline(node, () => true);
  r.visible(node);
  clock.dispose();
  assert.equal(r.frames.size, 0);
  assert.equal(r.observers.size, 0);
  clock.wake();
  assert.equal(r.frames.size, 0);
  r.motion.dispose();
});
test('disposing the page controller releases every observer and queued frame', () => {
  const r = rig();
  for (let i = 0; i < 3; i++) {
    const node = new Node();
    r.motion.timeline(node, () => true);
    r.visible(node);
  }
  r.motion.dispose();
  assert.equal(r.observers.size, 0);
  assert.equal(r.frames.size, 0);
  r.window.dispatchEvent(new Event('pageshow'));
  assert.equal(r.frames.size, 0);
});
