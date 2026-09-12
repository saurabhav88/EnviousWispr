// Failure isolation helpers for the feature islands (#2816).
//
// enhance() catches a throw during synchronous setup and inside registered
// timelines. Everything else an island does later (a click handler, a fetch
// continuation, a timer, a player callback) is outside that net, and a throw
// there would leave the island half-mutated while still marked ready. Every
// island therefore:
//   - wraps later work in `guarded()` so a programming error routes to the
//     island's fallback (which restores its static frame), while an abort
//     that already happened is ignored;
//   - snapshots its root's attributes and inline style at mount and restores
//     them through a non-throwing disposer, because enhance() snapshots
//     innerHTML only;
//   - enables its build-time-disabled controls only once mounting succeeded.
export function guarded(scope, fn) {
  return (...args) => {
    if (scope.signal.aborted) return undefined;
    try {
      const result = fn(...args);
      if (result && typeof result.then === 'function') {
        return result.catch((error) => {
          if (!scope.signal.aborted) scope.fallback(error);
        });
      }
      return result;
    } catch (error) {
      if (!scope.signal.aborted) scope.fallback(error);
      return undefined;
    }
  };
}

/** Snapshot root attributes and inline style; restore them on disposal. */
export function keepRoot(root, scope) {
  const attributes = [...root.attributes].map((a) => [a.name, a.value]);
  scope.defer(() => {
    try {
      for (const name of [...root.getAttributeNames()]) {
        if (!attributes.some(([n]) => n === name)) root.removeAttribute(name);
      }
      for (const [name, value] of attributes) root.setAttribute(name, value);
    } catch {
      /* a disposer never throws */
    }
  });
}

/** A setTimeout that is cleared on disposal and whose callback is guarded. */
export function timer(scope, fn, ms) {
  const id = setTimeout(guarded(scope, fn), ms);
  scope.defer(() => clearTimeout(id));
  return id;
}

/** Build-time-disabled controls inside the root become usable. */
export function enableControls(root) {
  for (const control of root.querySelectorAll('button[disabled][data-enables]')) control.disabled = false;
}

/** addEventListener with the scope's signal and a guarded handler. */
export function on(scope, target, type, fn, options = {}) {
  target.addEventListener(type, guarded(scope, fn), { ...options, signal: scope.signal });
}
