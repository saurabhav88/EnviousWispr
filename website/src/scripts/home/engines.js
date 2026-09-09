import engines from '../../data/home/engines.json';
export function init(root, motion, scope) {
  const views = engines.map((engine, index) => ({
    engine,
    node: root.querySelectorAll('.engine-card')[index],
    index: 0,
    phase: 0,
    elapsed: 0,
  }));
  function render(view) {
    const { node, engine, index, phase } = view,
      example = engine.langs[index];
    node.dataset.phase = String(phase);
    const name = node.querySelector('.engine-lang b'),
      said = node.querySelector('.engine-said-text'),
      result = node.querySelector('.engine-result');
    name.textContent = example.name;
    name.lang = example.code || 'en';
    node.querySelector('.engine-lang i').textContent = example.english;
    said.textContent = example.said;
    result.textContent = example.text;
    for (const text of [said, result]) {
      text.lang = example.code || 'en';
      text.dir = example.dir || 'ltr';
    }
    node.querySelector('.engine-status').textContent = [
      'Listening…',
      'Transcribing on your Mac…',
      'Pasted ✓',
      '',
    ][phase];
    node.querySelector('.engine-elapsed').textContent = phase === 2 ? engine.elapsed : '';
    const fill = node.querySelector('.engine-progress i');
    fill.style.transitionDuration = phase === 1 ? engine.wait + 'ms' : '0s';
    fill.style.transform = 'scaleX(' + (phase === 0 ? 0 : 1) + ')';
  }
  function settle() {
    for (const view of views) {
      view.phase = 2;
      view.elapsed = 0;
      render(view);
    }
  }
  scope.timeline(
    root,
    (delta) => {
      for (const view of views) {
        view.elapsed += delta;
        const duration = view.phase === 1 ? view.engine.wait : [1800, 0, 2600, 350][view.phase];
        if (view.elapsed < duration) continue;
        view.elapsed = 0;
        if (view.phase === 3) {
          view.phase = 0;
          view.index = (view.index + 1) % view.engine.langs.length;
        } else view.phase++;
        render(view);
      }
      return true;
    },
    (reduced) => {
      if (reduced) settle();
    },
  );
  if (motion.reduced.matches) settle();
  else views.forEach(render);
}
