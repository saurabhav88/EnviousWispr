/** Recognize direction; each section keeps ownership of its selection and playback. */
export function bindSwipe(card, scope, onSwipe, onStart = () => {}) {
  const doc = card.ownerDocument,
    win = doc.defaultView,
    mobile = win.matchMedia('(max-width: 600px)'),
    contacts = new Set();
  let gesture;
  const listen = (target, type, handler, options = {}) =>
    target.addEventListener(type, handler, { ...options, signal: scope.signal });
  function reset() {
    const previous = gesture;
    gesture = undefined;
    card.classList.remove('is-swiping');
    card.style.removeProperty('--swipe-offset');
    if (previous && card.hasPointerCapture(previous.id)) card.releasePointerCapture(previous.id);
  }
  function clear() {
    contacts.clear();
    reset();
  }
  // Capture phase sees a second contact even when it starts outside this card.
  listen(
    win,
    'pointerdown',
    (event) => {
      contacts.add(event.pointerId);
      if (contacts.size > 1) reset();
    },
    { capture: true },
  );
  for (const type of ['pointerup', 'pointercancel']) {
    listen(
      win,
      type,
      (event) => {
        contacts.delete(event.pointerId);
        if (type === 'pointercancel' && gesture?.id === event.pointerId) reset();
      },
      { capture: true },
    );
  }
  listen(card, 'pointerdown', (event) => {
    if (contacts.size !== 1 || !event.isPrimary || event.button !== 0) return;
    if (event.pointerType === 'mouse' && !mobile.matches) return;
    if (event.target.closest('a, button, input, select, textarea, summary, [contenteditable]'))
      return;
    gesture = { id: event.pointerId, x: event.clientX, y: event.clientY, horizontal: false };
    card.setPointerCapture(event.pointerId);
    // Mobile-preview dragging should move the card, not select its demonstration text.
    if (event.pointerType === 'mouse') event.preventDefault();
    onStart(event);
  });
  listen(card, 'pointermove', (event) => {
    if (gesture?.id !== event.pointerId) return;
    const dx = event.clientX - gesture.x,
      dy = event.clientY - gesture.y;
    if (!gesture.horizontal) {
      if (Math.max(Math.abs(dx), Math.abs(dy)) < 10) return;
      if (Math.abs(dx) <= Math.abs(dy) * 1.2) {
        reset();
        return;
      }
      gesture.horizontal = true;
      card.classList.add('is-swiping');
    }
    if (event.cancelable) event.preventDefault();
    card.style.setProperty('--swipe-offset', Math.max(-28, Math.min(28, dx * 0.2)) + 'px');
  });
  listen(card, 'pointerup', (event) => {
    if (gesture?.id !== event.pointerId) return;
    const dx = event.clientX - gesture.x,
      dy = event.clientY - gesture.y,
      select = gesture.horizontal && Math.abs(dx) > 44 && Math.abs(dx) > Math.abs(dy) * 1.2;
    reset();
    if (select) onSwipe(dx < 0 ? 1 : -1);
  });
  listen(card, 'lostpointercapture', (event) => {
    if (gesture?.id === event.pointerId) reset();
  });
  listen(win, 'blur', clear);
  listen(doc, 'visibilitychange', () => {
    if (doc.hidden) clear();
  });
  listen(mobile, 'change', clear);
  card.setAttribute('data-swipeable', '');
  scope.defer(() => {
    clear();
    card.removeAttribute('data-swipeable');
  });
}
