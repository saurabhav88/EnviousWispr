export function initShell() {
  const menu = document.getElementById('mobile-menu');
  const toggle = document.querySelector('.menu-toggle');
  function closeMenu(returnFocus = false) {
    menu.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', 'Open navigation');
    if (returnFocus) toggle.focus();
  }
  toggle.addEventListener('click', () => {
    const open = menu.hidden;
    menu.hidden = !open;
    toggle.setAttribute('aria-expanded', String(open));
    toggle.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  });
  menu.addEventListener('click', (event) => {
    if (event.target.closest('a')) closeMenu();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !menu.hidden) closeMenu(true);
  });
  document.addEventListener('click', (event) => {
    if (!menu.hidden && !menu.contains(event.target) && !toggle.contains(event.target)) closeMenu();
  });
  const desktop = matchMedia('(min-width:1000px)');
  desktop.addEventListener('change', () => {
    if (desktop.matches) closeMenu();
  });
  closeMenu();
  toggle.hidden = false;

  const copy = document.getElementById('brew-copy');
  copy.addEventListener('click', async () => {
    const code = document.querySelector('.brew-install code');
    const status = document.getElementById('brew-status');
    try {
      await navigator.clipboard.writeText(code.textContent);
      status.textContent = 'Copied to clipboard.';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      status.textContent = 'Command selected. Copy it with your keyboard.';
    }
  });
  copy.hidden = false;

  // An unavailable count must not compromise navigation or invent social proof.
  const valid = (value) =>
    value && Number.isInteger(value.count) && value.count >= 0 && Number.isFinite(value.at);
  function displayStars(value) {
    for (const node of document.querySelectorAll('[data-stars]')) {
      node.textContent = '☆ ' + new Intl.NumberFormat('en').format(value.count);
      node.title = 'GitHub stars, checked ' + new Date(value.at).toLocaleString();
    }
  }
  let cache;
  try {
    cache = JSON.parse(localStorage.getItem('ew-github-stars'));
  } catch {
    /* Optional cache. */
  }
  if (valid(cache)) displayStars(cache);
  if (!valid(cache) || Date.now() - cache.at > 3600000) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 7000);
    fetch('https://api.github.com/repos/saurabhav88/EnviousWispr', {
      signal: controller.signal,
      headers: { Accept: 'application/vnd.github+json' },
    })
      .then((response) => {
        if (!response.ok) throw Error('Count unavailable');
        return response.json();
      })
      .then((data) => {
        const value = { count: data.stargazers_count, at: Date.now() };
        if (!valid(value)) return;
        displayStars(value);
        try {
          localStorage.setItem('ew-github-stars', JSON.stringify(value));
        } catch {
          /* Optional cache. */
        }
      })
      .catch(() => {})
      .finally(() => clearTimeout(timeout));
  }
}
