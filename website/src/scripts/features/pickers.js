// Tab pickers (#2816): word packs (dictionary), benchmark views (dictation),
// pill design and position (customization). One island per [data-picker]
// root, which contains every control group AND every element a choice
// changes, so enhance()'s snapshot restores the whole thing. Groups are
// [data-choice-group] elements with a data-kind:
//   packs      → data-words / data-description on each button, output in
//                [data-pack-words] and [data-pack-description]
//   panels     → each button names a panel id in data-panel (inside the root)
//   classname  → the element with the group's data-target id (inside the
//                root) gets data-base plus the choice
import { keepRoot, enableControls, on } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const groups = [...root.querySelectorAll('[data-choice-group]')];
  if (!groups.length) throw new Error('picker: no choice groups');
  const inRoot = (id) => {
    const el = root.querySelector('#' + CSS.escape(id));
    if (!el) throw new Error('picker: target outside the island: ' + id);
    return el;
  };
  for (const group of groups) {
    const kind = group.dataset.kind;
    const buttons = [...group.querySelectorAll('[data-choice]')];
    if (!buttons.length) throw new Error('picker: a group has no choices');
    const choose = (button) => {
      buttons.forEach((b) => {
        b.classList.toggle('selected', b === button);
        b.setAttribute('aria-pressed', String(b === button));
      });
    };
    for (const button of buttons) {
      on(scope, button, 'click', () => {
        if (kind === 'packs') {
          const wordsList = JSON.parse(button.dataset.words);
          if (!Array.isArray(wordsList)) throw new Error('picker: pack words are not a list');
          const words = root.querySelector('[data-pack-words]');
          const description = root.querySelector('[data-pack-description]');
          const fragment = document.createDocumentFragment();
          for (const word of wordsList) {
            const span = document.createElement('span');
            span.textContent = String(word);
            fragment.append(span);
          }
          choose(button);
          words.replaceChildren(fragment);
          description.textContent = button.dataset.description;
        } else if (kind === 'panels') {
          const panels = buttons.map((b) => inRoot(b.dataset.panel));
          choose(button);
          buttons.forEach((b, i) => (panels[i].hidden = b !== button));
        } else if (kind === 'classname') {
          const target = inRoot(group.dataset.target);
          choose(button);
          target.className = group.dataset.base + ' ' + button.dataset.choice;
        } else {
          throw new Error('picker: unknown kind ' + kind);
        }
      });
    }
  }
  enableControls(root);
}
