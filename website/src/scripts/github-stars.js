// GitHub star count in the shared header (#2849). Ported from the homepage
// shell the old chrome carried; #2816 retired it with that header.
//
// An unavailable count must not compromise navigation or invent social
// proof: every [data-stars] host is server-rendered with its plain "GitHub"
// label and only swaps to the star count once a valid number is in hand. The
// count is cached for an hour so a return visit paints it before the network
// answers; the API call carries a hard timeout so a slow GitHub costs nothing.
const REPO_API = 'https://api.github.com/repos/saurabhav88/EnviousWispr';
const CACHE_KEY = 'ew-github-stars';
const MAX_AGE_MS = 3600000;
const TIMEOUT_MS = 7000;

const valid = (value) =>
  Boolean(value) && Number.isInteger(value.count) && value.count >= 0 && Number.isFinite(value.at);

function display(value) {
  const text = new Intl.NumberFormat('en').format(value.count);
  const checked = new Date(value.at).toLocaleString();
  for (const host of document.querySelectorAll('[data-stars]')) {
    const count = host.querySelector('[data-stars-count]');
    if (!count) continue;
    count.textContent = text;
    host.dataset.starsReady = 'true';
    const link = host.closest('a');
    if (link) {
      link.title = `${text} GitHub stars, checked ${checked}`;
      link.setAttribute('aria-label', `EnviousWispr on GitHub, ${text} stars`);
    }
  }
}

function readCache() {
  try {
    return JSON.parse(localStorage.getItem(CACHE_KEY));
  } catch {
    return null; /* Optional cache. */
  }
}

function writeCache(value) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(value));
  } catch {
    /* Optional cache. */
  }
}

function install() {
  if (!document.querySelector('[data-stars]')) return;
  const cache = readCache();
  if (valid(cache)) display(cache);
  if (valid(cache) && Date.now() - cache.at <= MAX_AGE_MS) return;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
  fetch(REPO_API, { signal: controller.signal, headers: { Accept: 'application/vnd.github+json' } })
    .then((response) => {
      if (!response.ok) throw new Error('Count unavailable');
      return response.json();
    })
    .then((data) => {
      const value = { count: data.stargazers_count, at: Date.now() };
      if (!valid(value)) return;
      display(value);
      writeCache(value);
    })
    .catch(() => {
      /* The plain GitHub label stays. */
    })
    .finally(() => clearTimeout(timeout));
}

install();
