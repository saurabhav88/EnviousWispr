import test from 'node:test';
import assert from 'node:assert/strict';
import { init } from '../../src/scripts/features/key-picker.js';

// The Make it yours key picker, driven without a browser: the demo moves the
// press from key to key, a tap chooses a key and holds it, and reduced motion
// leaves the chosen key alone.
function element(dataset = {}) {
  const el = {
    dataset: { ...dataset },
    textContent: '',
    attributes: [],
    handlers: {},
    setAttribute(name, value) {
      el[name] = value;
    },
    getAttributeNames: () => [],
    removeAttribute() {},
    addEventListener(type, fn) {
      el.handlers[type] = fn;
    },
  };
  return el;
}

function rig({ reduced = false } = {}) {
  const caption = element();
  const keys = ['fn', 'control', 'option'].map((k) => element({ kpKey: k, caption: `${k} caption` }));
  const root = element({ chosen: 'control' });
  root.querySelector = () => caption;
  root.querySelectorAll = () => keys;
  let tick = null;
  const motion = { reduced: { matches: reduced }, paused: false };
  const scope = {
    signal: { aborted: false },
    defer() {},
    timeline(node, fn) {
      tick = fn;
      return { wake() {}, dispose() {} };
    },
  };
  init(root, motion, scope);
  return { root, caption, keys, advance: (ms) => tick(ms) };
}

const pressed = (keys) => keys.map((k) => k.dataset.state).join(',');

test('the demo starts on the marked key and moves the press along', () => {
  const { root, caption, keys, advance } = rig();
  assert.equal(root.dataset.chosen, 'control');
  assert.equal(pressed(keys), 'idle,pressed,idle');
  assert.equal(caption.textContent, 'control caption');
  advance(2000);
  assert.equal(root.dataset.chosen, 'control');
  advance(500);
  assert.equal(root.dataset.chosen, 'option');
  assert.equal(pressed(keys), 'idle,idle,pressed');
  assert.equal(keys[2]['aria-pressed'], 'true');
  advance(2500);
  assert.equal(root.dataset.chosen, 'fn');
});

test('a tap chooses a key and holds it before the demo moves on', () => {
  const { root, keys, advance } = rig();
  keys[0].handlers.click();
  assert.equal(root.dataset.chosen, 'fn');
  advance(7900);
  assert.equal(root.dataset.chosen, 'fn');
  advance(200);
  assert.equal(root.dataset.chosen, 'control');
  advance(2500);
  assert.equal(root.dataset.chosen, 'option');
});

test('reduced motion keeps the chosen key still but still takes a tap', () => {
  const { root, keys, advance } = rig({ reduced: true });
  advance(10000);
  assert.equal(root.dataset.chosen, 'control');
  keys[2].handlers.click();
  assert.equal(root.dataset.chosen, 'option');
  assert.equal(pressed(keys), 'idle,idle,pressed');
});
