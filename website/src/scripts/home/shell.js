// The homepage's remaining shell behaviour: the Homebrew copy button. The
// menu moved to the shared header (scripts/site-nav.js, #2816) and the GitHub
// star count left with the old header.
export function initShell() {
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

}
