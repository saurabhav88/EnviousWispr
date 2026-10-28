// #4161: close the header Download menu (a <details> element that opens with no
// script) on an outside click, on Escape, and when keyboard focus leaves it.
const menu = document.querySelector('[data-download-menu]');
if (menu) {
  const close = (returnFocus) => {
    if (!menu.open) return;
    menu.open = false;
    if (returnFocus) menu.querySelector('summary')?.focus();
  };
  document.addEventListener('click', (e) => {
    if (!menu.contains(e.target)) close(false);
  });
  menu.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') close(true);
  });
  menu.addEventListener('focusout', (e) => {
    if (e.relatedTarget && !menu.contains(e.relatedTarget)) close(false);
  });
}
