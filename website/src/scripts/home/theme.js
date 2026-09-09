// Serialized into the document head so selection precedes the first paint.
// Keep this function self-contained: the server imports it without running it.
export function installTheme() {
  const root = document.documentElement;
  const system = matchMedia('(prefers-color-scheme: dark)');
  const valid = (value) => value === 'light' || value === 'dark';
  let override;
  try {
    const saved = localStorage.getItem('ew-website-theme');
    if (valid(saved)) override = saved;
  } catch {
    /* Storage can be unavailable; the choice still works for this visit. */
  }
  const query = new URLSearchParams(location.search).get('theme');
  if (valid(query)) override = query;

  function apply() {
    const theme = override || (system.matches ? 'dark' : 'light');
    root.dataset.theme = theme;
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', theme === 'dark' ? '#14101b' : '#fbf9ff');
    const button = document.querySelector('.theme-toggle');
    if (button) {
      button.textContent = theme === 'dark' ? '☀' : '☾';
      button.setAttribute(
        'aria-label',
        theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode',
      );
    }
  }
  apply();
  system.addEventListener('change', apply);
  window.addEventListener('pageshow', apply);
  window.addEventListener('storage', (event) => {
    if (event.key === 'ew-website-theme' || event.key === null) {
      override = valid(event.newValue) ? event.newValue : undefined;
      apply();
    }
  });
  function bind() {
    const button = document.querySelector('.theme-toggle');
    if (!button) return;
    button.addEventListener('click', () => {
      override = root.dataset.theme === 'dark' ? 'light' : 'dark';
      try {
        localStorage.setItem('ew-website-theme', override);
      } catch {
        /* Visit-local override remains. */
      }
      const url = new URL(location.href);
      url.searchParams.delete('theme');
      history.replaceState(history.state, '', url.pathname + url.search + url.hash);
      apply();
    });
    apply();
    button.hidden = false;
  }
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', bind, { once: true });
  else bind();
}
