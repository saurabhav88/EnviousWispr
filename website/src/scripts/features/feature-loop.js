// Directory page loop (#2816): cross-fades the lips, the "So many features"
// message and the six feature cards. Ported from the mock's feature-loop.js.
export function init(root, motion, scope) {
  const views = [...root.querySelectorAll('[data-loop-view]')];
  const durations = [2700, 1500, 1450, 1450, 1450, 1450, 1450, 1450];
  const total = durations.reduce((a, b) => a + b, 0);
  const fade = 260;
  let elapsed = 0;
  const ease = (t) => t * t * (3 - 2 * t);
  function render() {
    let time = motion.reduced.matches ? 0 : elapsed % total;
    let index = 0;
    while (time >= durations[index]) time -= durations[index++];
    let progress = Math.max(0, (time - (durations[index] - fade)) / fade);
    let blend = ease(progress);
    let next = (index + 1) % views.length;
    if (motion.paused) {
      if (blend >= 0.5) index = next;
      progress = 0;
      blend = 0;
      next = (index + 1) % views.length;
    }
    views.forEach((view, i) => {
      const incoming = i === next && progress > 0;
      const visible = i === index || incoming;
      view.hidden = !visible;
      if (!visible) return;
      const opacity = incoming ? blend : 1 - blend;
      view.style.opacity = String(opacity);
      view.style.transform = `translateY(${incoming ? (1 - blend) * 12 : -blend * 8}px) scale(${incoming ? 0.97 + 0.03 * blend : 1 - 0.02 * blend})`;
    });
    root.dataset.loopScene = views[index].dataset.loopName;
    root.dataset.lipsVisible = String(index === 0 || (next === 0 && progress > 0));
  }
  scope.timeline(
    root,
    (delta) => {
      elapsed = (elapsed + delta) % total;
      render();
      return true;
    },
    render,
  );
  render();
}
