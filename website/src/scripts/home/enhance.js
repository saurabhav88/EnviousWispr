/** Own the resources and static fallback for one section, never the whole page. */
export function enhance(root, motion, setup) {
  if (!root) return;
  const original = root.innerHTML;
  const controller = new AbortController();
  const disposers = [];
  let failed = false;
  function fallback(error) {
    if (failed) return;
    failed = true;
    controller.abort();
    for (const dispose of disposers.splice(0)) dispose();
    root.innerHTML = original;
    root.dataset.enhancement = 'unavailable';
    console.error('Homepage section unavailable: ' + root.id, error);
  }
  const scope = {
    signal: controller.signal,
    defer(dispose) {
      if (failed) dispose();
      else disposers.push(dispose);
    },
    timeline(node, tick, preference) {
      const clock = motion.timeline(node, tick, preference, fallback);
      if (failed) clock.dispose();
      else disposers.push(() => clock.dispose());
      return clock;
    },
    fallback,
  };
  try {
    setup(root, motion, scope);
    if (!failed) root.dataset.enhancement = 'ready';
  } catch (error) {
    fallback(error);
  }
}
