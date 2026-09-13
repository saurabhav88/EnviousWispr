import test from 'node:test';
import assert from 'node:assert/strict';
import { init } from '../../src/scripts/features/keybind-film.js';

// The Make it yours keybind film, driven without a browser: a scene button
// must select its scene whether or not motion is reduced, and the story must
// land its text only after the key is released.
function element() {
  const el = {
    dataset: {},
    textContent: '',
    attributes: [],
    classes: new Set(),
    handlers: {},
    classList: {
      toggle(name, on) {
        if (on) el.classes.add(name);
        else el.classes.delete(name);
      },
    },
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
  const text = element();
  const buttons = [element(), element()];
  const root = element();
  root.querySelector = (selector) => (selector.includes('caption') ? caption : text);
  root.querySelectorAll = (selector) => (selector.includes('kf-scene') ? buttons : []);
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
  return { root, caption, text, buttons, advance: (ms) => tick(ms) };
}

test('a scene button selects its scene under reduced motion', () => {
  const { root, caption, buttons } = rig({ reduced: true });
  assert.equal(root.dataset.scene, 'hold');
  assert.ok(buttons[0].classes.has('selected'));
  buttons[1].handlers.click();
  assert.equal(root.dataset.scene, 'handsfree');
  assert.equal(root.dataset.pill, 'handsfree');
  assert.equal(root.dataset.key, 'up');
  assert.ok(buttons[1].classes.has('selected'));
  assert.equal(buttons[0]['aria-pressed'], 'false');
  assert.match(caption.textContent, /Tap it twice/);
  buttons[0].handlers.click();
  assert.equal(root.dataset.scene, 'hold');
  assert.equal(root.dataset.pill, 'shown');
});

test('holding shows the pill and releasing lands the text', () => {
  const { root, text, advance } = rig();
  assert.equal(root.dataset.pill, 'hidden');
  advance(1000);
  assert.equal(root.dataset.key, 'down');
  assert.equal(root.dataset.pill, 'shown');
  assert.equal(text.textContent, '');
  advance(1000);
  assert.equal(root.dataset.frame, '1');
  advance(4000);
  assert.equal(root.dataset.key, 'up');
  assert.equal(root.dataset.pill, 'hidden');
  assert.equal(root.dataset.done, 'true');
  assert.match(text.textContent, /by Thursday\.$/);
});
