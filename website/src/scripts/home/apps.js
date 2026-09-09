export function init(root, motion, scope) {
  const viewport = root.querySelector('.compatible-viewport'),
    list = root.querySelector('.compatible-list');
  const duplicate = list.cloneNode(true);
  duplicate.classList.add('compatible-duplicate');
  duplicate.setAttribute('aria-hidden', 'true');
  list.after(duplicate);
  const manual = matchMedia('(max-width:999px), (pointer:coarse)');
  let hovered = false,
    offset = viewport.scrollLeft;
  const clock = scope.timeline(root, (delta) => {
    if (manual.matches || hovered) return false;
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
  viewport.addEventListener(
    'mouseenter',
    () => {
      hovered = true;
    },
    { signal: scope.signal },
  );
  viewport.addEventListener(
    'mouseleave',
    () => {
      hovered = false;
      resume();
    },
    { signal: scope.signal },
  );
  viewport.addEventListener('focusout', resume, { signal: scope.signal });
  manual.addEventListener('change', resume, { signal: scope.signal });
  const observer = new ResizeObserver(resume);
  observer.observe(list);
  scope.defer(() => observer.disconnect());
}
