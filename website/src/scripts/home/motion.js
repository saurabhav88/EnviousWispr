/** Scheduling policy shared by the homepage's independent demonstrations. */
export function createMotionController(env = globalThis) {
  const doc = env.document;
  const reduced = env.matchMedia('(prefers-reduced-motion: reduce)');
  const tasks = new Set();
  const events = new env.AbortController();
  let paused = false;
  let suspended = false;
  let frame = 0;
  let last = 0;
  const allowed = () => !paused && !reduced.matches && !doc.hidden && !suspended;
  const runnable = (task) =>
    allowed() &&
    task.visible &&
    (!task.focused || task.userPlayback) &&
    !task.finished &&
    !task.failed &&
    task.node.isConnected;

  function stop() {
    if (frame) env.cancelAnimationFrame(frame);
    frame = 0;
    last = 0;
  }
  function schedule() {
    for (const task of tasks) task.node.dataset.animate = runnable(task) ? 'running' : 'paused';
    if (!Array.from(tasks).some(runnable)) {
      stop();
      return;
    }
    if (!frame) frame = env.requestAnimationFrame(tick);
  }
  function fail(task, error) {
    task.failed = true;
    try {
      task.onError(error);
    } catch (fallbackError) {
      env.console.error('Homepage fallback failed', fallbackError);
    }
    env.console.error('Homepage animation stopped', error);
  }
  function tick(now) {
    frame = 0;
    const delta = last ? Math.min(100, Math.max(0, now - last)) : 0;
    last = now;
    for (const task of tasks) {
      if (!runnable(task)) continue;
      try {
        task.finished = task.tick(delta) === false;
      } catch (error) {
        fail(task, error);
      }
    }
    schedule();
  }
  function sync() {
    doc.documentElement.dataset.motion = allowed() ? 'playing' : 'paused';
    for (const button of doc.querySelectorAll('[data-motion-control]')) {
      button.hidden = false;
      button.disabled = reduced.matches;
      button.textContent = button.classList.contains('icon-button')
        ? paused
          ? '▶'
          : 'Ⅱ'
        : paused
          ? 'Play motion'
          : 'Pause motion';
      button.setAttribute('aria-pressed', String(paused || reduced.matches));
      button.setAttribute(
        'aria-label',
        reduced.matches
          ? 'Reduced motion enabled'
          : paused
            ? 'Play page animations'
            : 'Pause page animations',
      );
    }
    for (const task of tasks) {
      if (task.failed) continue;
      try {
        task.onPreference(reduced.matches);
      } catch (error) {
        fail(task, error);
      }
    }
    doc.dispatchEvent(new env.Event('home:motion'));
    schedule();
  }
  function timeline(node, tick, onPreference = () => {}, onError = () => {}) {
    const listeners = new env.AbortController();
    const task = {
      node,
      tick,
      onPreference,
      onError,
      visible: false,
      focused: node.contains(doc.activeElement),
      userPlayback: false,
      finished: false,
      failed: false,
    };
    const observer = new env.IntersectionObserver(
      (entries) => {
        task.visible = entries[0].isIntersecting;
        schedule();
      },
      { threshold: 0.1 },
    );
    tasks.add(task);
    node.addEventListener(
      'focusin',
      () => {
        task.focused = true;
        task.userPlayback = false;
        schedule();
      },
      { signal: listeners.signal },
    );
    node.addEventListener(
      'focusout',
      (event) => {
        task.focused = node.contains(event.relatedTarget);
        schedule();
      },
      { signal: listeners.signal },
    );
    observer.observe(node);
    node.dataset.animate = 'paused';
    try {
      onPreference(reduced.matches);
    } catch (error) {
      fail(task, error);
    }
    task.dispose = () => {
      observer.disconnect();
      listeners.abort();
      tasks.delete(task);
      delete node.dataset.animate;
      schedule();
    };
    return {
      wake({ allowFocused = false } = {}) {
        task.finished = false;
        task.userPlayback = allowFocused;
        schedule();
      },
      dispose: task.dispose,
    };
  }
  doc.addEventListener('visibilitychange', sync, { signal: events.signal });
  reduced.addEventListener('change', sync, { signal: events.signal });
  env.addEventListener(
    'pagehide',
    () => {
      suspended = true;
      sync();
    },
    { signal: events.signal },
  );
  env.addEventListener(
    'pageshow',
    () => {
      suspended = false;
      sync();
    },
    { signal: events.signal },
  );
  for (const button of doc.querySelectorAll('[data-motion-control]'))
    button.addEventListener(
      'click',
      () => {
        paused = !paused;
        sync();
      },
      { signal: events.signal },
    );
  sync();
  return {
    timeline,
    allowed,
    reduced,
    get paused() {
      return paused;
    },
    setPaused(value) {
      paused = Boolean(value);
      sync();
    },
    dispose() {
      suspended = true;
      events.abort();
      for (const task of Array.from(tasks)) task.dispose();
      stop();
    },
  };
}
