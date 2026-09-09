export function init(root, motion, scope) {
  const video = root.querySelector('video');
  let visible = false,
    desired = false,
    generation = 0,
    loaded = false;
  function reconcile() {
    const play = visible && motion.allowed();
    if (play === desired) return;
    desired = play;
    const current = ++generation;
    if (!play) {
      video.pause();
      return;
    }
    if (!loaded) {
      for (const source of video.querySelectorAll('source[data-src]'))
        source.src = source.dataset.src;
      video.load();
      loaded = true;
    }
    video
      .play()
      .then(() => {
        if (current !== generation && !desired) video.pause();
      })
      .catch(() => {
        if (current !== generation) return;
        video.pause(); // The static poster is the fallback; do not fetch a GIF.
        desired = false;
      });
  }
  const observer = new IntersectionObserver(
    (entries) => {
      visible = entries[0].isIntersecting;
      reconcile();
    },
    { threshold: 0.1 },
  );
  observer.observe(root);
  document.addEventListener('home:motion', reconcile, { signal: scope.signal });
  scope.defer(() => {
    generation++;
    desired = false;
    observer.disconnect();
    video.pause();
  });
}
