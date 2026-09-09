import { renderHost } from '../../utils/home/app-shell.js';
import { renderDraft } from '../../utils/home/text.js';
import { createNativePreview } from './native-preview.js';

export function mountDemo(container, app, context = {}, { hero = false, lang = 'en' } = {}) {
  const template = document.createElement('template');
  template.innerHTML = renderHost(app, context);
  const host = template.content.firstElementChild;
  const output = document.createElement('div');
  output.className = hero ? 'hero-draft' : 'illustrated-result';
  output.lang = lang;
  const caret = document.createElement('span');
  caret.className = 'hero-empty-caret';
  caret.setAttribute('aria-hidden', 'true');
  host.querySelector('.host-draft-slot').append(caret, output);
  const native = createNativePreview();
  native.well.querySelector('.hero-native-words').lang = lang;
  container.replaceChildren(host, native.well, native.processing);
  let lastText;
  return {
    host,
    output,
    set(phase, raw, finished, elapsed = 0) {
      container.dataset.phase = phase;
      native.set(phase, raw, elapsed);
      output.hidden = phase !== 'finished';
      caret.hidden = phase === 'finished';
      if (finished !== lastText) {
        output.innerHTML = renderDraft(finished);
        lastText = finished;
      }
    },
  };
}
