// Shared header behaviour (#2816): the Features and Resources drop-downs and
// the phone menu. Ported from the approved mock's marketing.js nav half, with
// the link-click close and desktop-breakpoint reset the homepage shell had.
//
// The header is server-rendered as plain links and visible panels. This
// module validates every node it needs BEFORE touching the DOM, builds the
// replacement buttons detached, applies the swap in one pass, and stamps
// data-nav-ready only after every binding succeeded. If anything throws the
// mutations are rolled back, so a failure leaves the no-script header exactly
// as it was delivered.
function install() {
  const header = document.querySelector('.chrome-header');
  if (!header || header.dataset.navReady) return;

  // 1. Query and validate. Nothing is mutated in this phase.
  const nav = header.querySelector('.main-nav');
  const mobileLink = header.querySelector('[data-nav-mobile-trigger]');
  const parents = [...header.querySelectorAll('[data-nav-parent]')];
  if (!nav || !nav.id || !mobileLink || parents.length !== 2) return;
  const groups = parents.map((parent) => {
    const link = parent.querySelector('[data-nav-trigger]');
    const panel = parent.querySelector('[data-nav-panel]');
    if (!link || !panel || !panel.id || !link.id) throw new Error('site-nav: incomplete menu group');
    return { parent, link, panel };
  });

  // 2. Build replacements detached.
  const makeButton = (source, label) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = source.className;
    if (source.id) button.id = source.id;
    if (label) button.setAttribute('aria-label', label);
    button.setAttribute('aria-expanded', 'false');
    button.append(...[...source.childNodes].map((node) => node.cloneNode(true)));
    return button;
  };
  for (const group of groups) {
    group.button = makeButton(group.link);
    group.button.setAttribute('aria-controls', group.panel.id);
  }
  const mobile = makeButton(mobileLink, 'Open navigation');
  mobile.setAttribute('aria-controls', nav.id);
  const [products, resources] = groups;
  const controller = new AbortController();
  const { signal } = controller;

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

  // 3. Apply. Any throw from here rolls every mutation back.
  const applied = [];
  try {
    for (const group of groups) {
      group.link.replaceWith(group.button);
      applied.push(() => group.button.replaceWith(group.link));
      group.panel.hidden = true;
      applied.push(() => {
        group.panel.hidden = false;
      });
    }
    mobileLink.replaceWith(mobile);
    applied.push(() => mobile.replaceWith(mobileLink));

    products.button.addEventListener(
      'click',
      () => {
        setPanel(products, products.panel.hidden);
        setPanel(resources, false);
      },
      { signal },
    );
    resources.button.addEventListener(
      'click',
      () => {
        setPanel(resources, resources.panel.hidden);
        setPanel(products, false);
      },
      { signal },
    );
    mobile.addEventListener('click', () => setMobile(!nav.classList.contains('open')), { signal });
    // A chosen destination closes whatever was open.
    nav.addEventListener(
      'click',
      (event) => {
        if (event.target.closest('a[href]')) {
          for (const group of groups) setPanel(group, false);
          setMobile(false);
        }
      },
      { signal },
    );
    document.addEventListener(
      'click',
      (event) => {
        if (!event.target.closest('[data-nav-parent]')) for (const group of groups) setPanel(group, false);
        if (nav.classList.contains('open') && !header.contains(event.target)) setMobile(false);
      },
      { signal },
    );
    // Escape closes the innermost thing first: Features, then Resources, then the phone menu.
    document.addEventListener(
      'keydown',
      (event) => {
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
      },
      { signal },
    );
    const desktop = matchMedia('(min-width: 1000px)');
    desktop.addEventListener(
      'change',
      () => {
        if (desktop.matches) setMobile(false);
      },
      { signal },
    );
    header.dataset.navReady = 'true';
  } catch (error) {
    controller.abort();
    for (const undo of applied.reverse()) undo();
    nav.classList.remove('open');
    delete header.dataset.navReady;
    throw error;
  }
}

try {
  install();
} catch (error) {
  console.error('Site navigation enhancement unavailable; plain links remain.', error);
}
