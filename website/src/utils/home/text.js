export function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
}
export function renderDraft(text) {
  return text
    .split('\n\n')
    .map((p) => '<p>' + escapeHtml(p) + '</p>')
    .join('');
}
export function renderTokens(tokens) {
  return tokens
    .map(
      (t) =>
        '<span' +
        (t.cut ? ' class="is-cut"' : t.mark ? ' class="is-mark"' : '') +
        '>' +
        escapeHtml(t.t) +
        '</span>',
    )
    .join('');
}
