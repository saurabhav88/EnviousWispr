// One FAQ answer string feeds both copies on a /compare/ page: the visible
// answer and the FAQPage JSON-LD that search engines index. The two used to be
// written separately and drifted on eight pages (#3866), so an answer is now
// written once, with two inline marks the visible copy needs:
//
//   [link text](href)   a link
//   `code`              inline code
//
// `faqAnswerText` drops the marks for JSON-LD; `faqAnswerHtml` renders them for
// the page. Everything else in the string is plain text and is escaped.

const MARK = /\[([^\]]+)\]\(([^)\s]+)\)|`([^`]+)`/g;
const LINK_STYLE = 'color: var(--accent); text-decoration: underline;';

const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** Plain text of an answer, for JSON-LD. */
export function faqAnswerText(answer) {
  return answer.replace(MARK, (_, linkText, _href, code) => linkText ?? code);
}

/** HTML of an answer, for the visible FAQ. */
export function faqAnswerHtml(answer) {
  let html = '';
  let last = 0;
  for (const m of answer.matchAll(MARK)) {
    html += escapeHtml(answer.slice(last, m.index));
    const [, linkText, href, code] = m;
    html +=
      linkText !== undefined
        ? `<a href="${escapeHtml(href)}" style="${LINK_STYLE}">${escapeHtml(linkText)}</a>`
        : `<code>${escapeHtml(code)}</code>`;
    last = m.index + m[0].length;
  }
  return html + escapeHtml(answer.slice(last));
}
