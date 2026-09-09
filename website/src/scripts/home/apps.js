export function init(root, motion, scope) {
  const viewport = root.querySelector('.compatible-viewport'),
    list = root.querySelector('.compatible-list');
  const duplicate = list.cloneNode(true);
  duplicate.classList.add('compatible-duplicate');
  duplicate.setAttribute('aria-hidden', 'true');
  list.after(duplicate);
  scope.defer(() => duplicate.remove());
  let hovered = false,
    touching = false,
    dragging = false,
    settling = false,
    settleTimer,
    offset = viewport.scrollLeft;
  const clock = scope.timeline(root, (delta) => {
    if (hovered || touching || dragging || settling) return false;
    const width = list.offsetWidth;
    if (!width) return false;
    offset = (offset + delta * 0.025) % width;
    viewport.scrollLeft = offset;
    return true;
  });
  function resume() {
    offset = viewport.scrollLeft;
    clock.wake();
  }
  function finishInteraction() {
    if (touching || dragging) return;
    clearTimeout(settleTimer);
    settling = false;
    resume();
  }
  function settle() {
    settling = true;
    clearTimeout(settleTimer);
    if (!touching && !dragging) settleTimer = setTimeout(finishInteraction, 180);
  }
  const passive = { passive: true, signal: scope.signal };
  viewport.addEventListener(
    'pointerenter',
    (event) => {
      if (event.pointerType === 'mouse') hovered = true;
    },
    passive,
  );
  viewport.addEventListener(
    'pointerleave',
    (event) => {
      if (event.pointerType !== 'mouse') return;
      hovered = false;
      resume();
    },
    passive,
  );
  viewport.addEventListener(
    'pointerdown',
    (event) => {
      if (event.pointerType === 'mouse') {
        dragging = true;
        settle();
      }
    },
    passive,
  );
  for (const eventName of ['pointerup', 'pointercancel']) {
    window.addEventListener(
      eventName,
      (event) => {
        if (event.pointerType !== 'mouse' || !dragging) return;
        dragging = false;
        settle();
      },
      passive,
    );
  }
  // Native panning cancels pointer events before the finger is lifted.
  viewport.addEventListener(
    'touchstart',
    () => {
      hovered = false;
      touching = true;
      settle();
    },
    passive,
  );
  for (const eventName of ['touchend', 'touchcancel']) {
    window.addEventListener(
      eventName,
      (event) => {
        if (!touching) return;
        touching = event.touches.length > 0;
        settle();
      },
      passive,
    );
  }
  viewport.addEventListener('wheel', settle, passive);
  viewport.addEventListener(
    'scroll',
    () => {
      if (settling) settle();
    },
    passive,
  );
  viewport.addEventListener(
    'scrollend',
    () => {
      if (settling) finishInteraction();
    },
    passive,
  );
  viewport.addEventListener('focusout', resume, { signal: scope.signal });
  const observer = new ResizeObserver(resume);
  observer.observe(list);
  scope.defer(() => observer.disconnect());
  scope.defer(() => clearTimeout(settleTimer));
}
