// Tab pickers (#2816): word packs (dictionary), benchmark views (dictation),
// pill design and position (customization). One mount per picker group; the
// group root carries data-picker and each button data-choice. Ported from the
// mock's marketing.js. What a choice does is declared on the group:
//   data-picker="packs"      → data-words / data-description on each button
//   data-picker="panels"     → each button names a panel id in data-panel
//   data-picker="classname"  → data-target element gets data-base + choice
export function init(root, motion, scope) {
  const kind = root.dataset.picker;
  const buttons = [...root.querySelectorAll('[data-choice]')];
  if (!buttons.length) throw new Error('picker: no choices');
  const { signal } = scope;
  function choose(button) {
    buttons.forEach((b) => {
      b.classList.toggle('selected', b === button);
      b.setAttribute('aria-pressed', String(b === button));
    });
  }
  for (const button of buttons) {
    button.addEventListener(
      'click',
      () => {
        choose(button);
        if (kind === 'packs') {
          const words = root.querySelector('[data-pack-words]');
          const description = root.querySelector('[data-pack-description]');
          words.replaceChildren();
          for (const word of JSON.parse(button.dataset.words)) {
            const span = document.createElement('span');
            span.textContent = word;
            words.append(span);
          }
          description.textContent = button.dataset.description;
        } else if (kind === 'panels') {
          for (const b of buttons) {
            const panel = document.getElementById(b.dataset.panel);
            if (panel) panel.hidden = b !== button;
          }
        } else if (kind === 'classname') {
          const target = document.getElementById(root.dataset.target);
          target.className = root.dataset.base + ' ' + button.dataset.choice;
        }
      },
      { signal },
    );
  }
}
