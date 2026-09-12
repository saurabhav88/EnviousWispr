// Shared header behaviour (#2816): the Features and Resources drop-downs and
// the phone menu. Ported from the approved mock's marketing.js nav half, with
// the link-click close and desktop-breakpoint reset the homepage shell had.
//
// The header is server-rendered as plain links and visible panels. This
// module upgrades each trigger link to a button, collapses the panels, and
// stamps data-nav-ready only after every binding succeeded, so a failure at
// any step leaves the no-script header exactly as it was delivered.
function install() {
  const header = document.querySelector('.site-header');
  if (!header || header.dataset.navReady) return;
  const nav = header.querySelector('.main-nav');
  const mobileLink = header.querySelector('[data-nav-mobile-trigger]');
  const parents = [...header.querySelectorAll('[data-nav-parent]')];
  if (!nav || !mobileLink || parents.length !== 2) return;

  // Trigger links become buttons; the panel keeps its id and content.
  const groups = parents.map((parent) => {
    const link = parent.querySelector('[data-nav-trigger]');
    const panel = parent.querySelector('[data-nav-panel]');
    const button = document.createElement('button');
    button.type = 'button';
    button.className = link.className;
    button.id = link.id;
    button.setAttribute('aria-controls', panel.id);
    button.setAttribute('aria-expanded', 'false');
    button.replaceChildren(...link.childNodes);
    link.replaceWith(button);
    panel.hidden = true;
    return { parent, button, panel };
  });
  const [products, resources] = groups;

  const mobile = document.createElement('button');
  mobile.type = 'button';
  mobile.className = mobileLink.className;
  mobile.setAttribute('aria-label', 'Open navigation');
  mobile.setAttribute('aria-expanded', 'false');
  mobile.setAttribute('aria-controls', nav.id);
  mobile.replaceChildren(...mobileLink.childNodes);
  mobileLink.replaceWith(mobile);

  function setPanel(group, open) {
    group.button.setAttribute('aria-expanded', String(open));
    group.panel.hidden = !open;
  }
  function setMobile(open, returnFocus = false) {
    nav.classList.toggle('open', open);
    mobile.setAttribute('aria-expanded', String(open));
    mobile.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
    if (!open) for (const group of groups) setPanel(group, false);
    if (returnFocus) mobile.focus();
  }

  products.button.addEventListener('click', () => {
    setPanel(products, products.panel.hidden);
    setPanel(resources, false);
  });
  resources.button.addEventListener('click', () => {
    setPanel(resources, resources.panel.hidden);
    setPanel(products, false);
  });
  mobile.addEventListener('click', () => setMobile(!nav.classList.contains('open')));

  // A chosen destination closes whatever was open.
  nav.addEventListener('click', (event) => {
    if (event.target.closest('a[href]')) {
      for (const group of groups) setPanel(group, false);
      setMobile(false);
    }
  });
  document.addEventListener('click', (event) => {
    if (!event.target.closest('[data-nav-parent]')) for (const group of groups) setPanel(group, false);
    if (nav.classList.contains('open') && !header.contains(event.target)) setMobile(false);
  });
  // Escape closes the innermost thing first: Features, then Resources, then the phone menu.
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (!products.panel.hidden) {
      setPanel(products, false);
      products.button.focus();
    } else if (!resources.panel.hidden) {
      setPanel(resources, false);
      resources.button.focus();
    } else if (nav.classList.contains('open')) {
      setMobile(false, true);
    }
  });
  const desktop = matchMedia('(min-width: 1000px)');
  desktop.addEventListener('change', () => {
    if (desktop.matches) setMobile(false);
  });

  header.dataset.navReady = 'true';
}

try {
  install();
} catch (error) {
  console.error('Site navigation enhancement unavailable; plain links remain.', error);
}
