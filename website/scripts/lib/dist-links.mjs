const SITE_ORIGIN = 'https://enviouswispr.com';

function isAsciiSpace(ch) {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f';
}

function isTagNameBoundary(ch) {
  return !ch || isAsciiSpace(ch) || ch === '>' || ch === '/';
}

function findCloseTagEnd(lowerHtml, start, tagName) {
  const needle = `</${tagName}`;
  let pos = lowerHtml.indexOf(needle, start);
  while (pos !== -1) {
    let k = pos + needle.length;
    while (k < lowerHtml.length && isAsciiSpace(lowerHtml[k])) k++;
    if (lowerHtml[k] === '>') return k + 1;
    pos = lowerHtml.indexOf(needle, pos + 2);
  }
  return lowerHtml.length;
}

function parseStartTag(html, lt) {
  const n = html.length;
  let i = lt + 1;
  while (i < n && !isTagNameBoundary(html[i])) i++;
  const tagName = html.slice(lt + 1, i).toLowerCase();
  let href = null;

  while (i < n) {
    while (i < n && isAsciiSpace(html[i])) i++;
    if (i >= n) return { tagName, href, tagEnd: n };
    if (html[i] === '>') return { tagName, href, tagEnd: i + 1 };
    if (html[i] === '/') {
      i++;
      continue;
    }

    const nameStart = i;
    while (i < n && !isAsciiSpace(html[i]) && html[i] !== '=' && html[i] !== '>' && html[i] !== '/') {
      i++;
    }
    const attrName = html.slice(nameStart, i).toLowerCase();

    while (i < n && isAsciiSpace(html[i])) i++;
    let attrVal = '';
    if (i < n && html[i] === '=') {
      i++;
      while (i < n && isAsciiSpace(html[i])) i++;
      if (i < n && (html[i] === '"' || html[i] === "'")) {
        const quote = html[i++];
        const valStart = i;
        while (i < n && html[i] !== quote) i++;
        attrVal = html.slice(valStart, i);
        if (i < n && html[i] === quote) i++;
      } else {
        const valStart = i;
        while (i < n && !isAsciiSpace(html[i]) && html[i] !== '>') i++;
        attrVal = html.slice(valStart, i);
      }
      if (tagName === 'a' && attrName === 'href' && href === null) {
        href = attrVal;
      }
    }
  }

  return { tagName, href, tagEnd: n };
}

function extractAnchorHrefs(html) {
  const lower = html.toLowerCase();
  const hrefs = [];
  let i = 0;

  while (i < html.length) {
    const lt = html.indexOf('<', i);
    if (lt === -1) break;

    if (html.startsWith('<!--', lt)) {
      const end = html.indexOf('-->', lt + 4);
      i = end === -1 ? html.length : end + 3;
      continue;
    }

    const next = html[lt + 1];
    if (!next || !((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z'))) {
      i = lt + 1;
      continue;
    }

    const { tagName, href, tagEnd } = parseStartTag(html, lt);
    if (tagName === 'script' || tagName === 'style') {
      i = findCloseTagEnd(lower, tagEnd, tagName);
      continue;
    }

    if (tagName === 'a' && href !== null) {
      hrefs.push(href);
    }
    i = tagEnd;
  }

  return hrefs;
}

/**
 * Normalizes a resolved same-origin pathname to a built directory route key
 * (`/`, `/x/`, ...), or returns null if the path has no trailing slash and
 * is not an `index.html` target (`trailingSlash: 'always'`).
 */
export function normalizeRoutePath(pathname) {
  if (!pathname) return null;
  if (pathname === '/' || pathname === '/index.html') return '/';
  if (pathname.endsWith('/index.html')) {
    return pathname.slice(0, -'index.html'.length);
  }
  if (pathname.endsWith('/')) return pathname;
  return null;
}

/**
 * Extracts normalized same-origin internal link route keys from static HTML,
 * ignoring comments, `<script>`/`<style>` blocks, query strings, fragments,
 * external hosts, non-trailing-slash paths, and self-links.
 */
export function internalLinks(html, pageRoute, origin = SITE_ORIGIN) {
  const links = new Set();
  const baseUrl = `${origin}${pageRoute}`;

  for (const raw of extractAnchorHrefs(html)) {
    const rawHref = raw.trim();
    if (!rawHref) continue;

    let resolved;
    try {
      resolved = new URL(rawHref, baseUrl);
    } catch {
      continue;
    }

    if (resolved.origin !== origin) continue;
    resolved.search = '';
    resolved.hash = '';

    const route = normalizeRoutePath(resolved.pathname);
    if (!route || route === pageRoute) continue;
    links.add(route);
  }

  return links;
}
