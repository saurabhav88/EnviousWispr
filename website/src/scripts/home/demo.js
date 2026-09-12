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
  host.querySelector('.host-draft-slot').append(output);
  container.replaceChildren(host);
  return attachDemo(container, host, output, lang);
}

/** Attach playback once without replacing the server-rendered app or draft. */
export function hydrateDemo(container, finishedText, { lang = 'en' } = {}) {
  return attachDemo(
    container,
    container.querySelector('.host-app'),
    container.querySelector('.illustrated-result'),
    lang,
    finishedText,
  );
}

function attachDemo(container, host, output, lang, lastText) {
  const caret = document.createElement('span');
  caret.className = 'hero-empty-caret';
  caret.setAttribute('aria-hidden', 'true');
  caret.hidden = true;
  output.before(caret);
  const native = createNativePreview();
  native.well.querySelector('.hero-native-words').lang = lang;
  container.append(native.well, native.processing);
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
