import { escapeHtml } from './text.js';
const gmailMark =
  '<svg viewBox="0 0 24 18" aria-hidden="true"><path fill="#4285f4" d="M0 3v13a2 2 0 0 0 2 2h3V6z"/><path fill="#34a853" d="M19 6v12h3a2 2 0 0 0 2-2V3z"/><path fill="#fbbc04" d="M19 6l5-3v-1a2 2 0 0 0-3.2-1.6L19 2z"/><path fill="#ea4335" d="M5 2l7 5 7-5v4l-7 5-7-5z"/><path fill="#c5221f" d="M0 3l5 3V2L3.2.4A2 2 0 0 0 0 2z"/></svg>';
const slackMark =
  '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="1" width="4" height="10" rx="2" fill="#36c5f0"/><rect x="1" y="9" width="10" height="4" rx="2" fill="#e01e5a"/><rect x="11" y="13" width="4" height="10" rx="2" fill="#ecb22e"/><rect x="13" y="11" width="10" height="4" rx="2" fill="#2eb67d"/><circle cx="5" cy="5" r="2" fill="#36c5f0"/><circle cx="19" cy="5" r="2" fill="#2eb67d"/><circle cx="19" cy="19" r="2" fill="#ecb22e"/><circle cx="5" cy="19" r="2" fill="#e01e5a"/></svg>';
const discordMark =
  '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M19.7 5.1a18 18 0 0 0-4.4-1.4l-.5 1a16 16 0 0 0-5.6 0l-.5-1a18 18 0 0 0-4.4 1.4C1.5 9.3.7 13.4 1.1 17.4a18 18 0 0 0 5.4 2.7l1.1-1.8-1.7-.8.4-.3a13 13 0 0 0 11.4 0l.4.3-1.7.8 1.1 1.8a18 18 0 0 0 5.4-2.7c.4-4-.4-8.1-3.2-12.3ZM8.3 14.6c-1.1 0-1.9-1-1.9-2.2s.8-2.2 1.9-2.2 1.9 1 1.9 2.2-.8 2.2-1.9 2.2Zm7.4 0c-1.1 0-1.9-1-1.9-2.2s.8-2.2 1.9-2.2 1.9 1 1.9 2.2-.8 2.2-1.9 2.2Z"/></svg>';
const teamsMark =
  '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="16" cy="5" r="3" fill="#7b83eb"/><circle cx="21" cy="7" r="2" fill="#5059c9"/><path fill="#5059c9" d="M16 10h8v7a4 4 0 0 1-8 0z"/><path fill="#7b83eb" d="M7 9h12v9a6 6 0 0 1-12 0z"/><rect x="1" y="6" width="13" height="13" rx="1.5" fill="#4b53bc"/><path stroke="#fff" stroke-width="1.7" d="M4 10h7M7.5 10v6"/></svg>';
const names = {
  slack: 'Slack',
  discord: 'Discord',
  teams: 'Microsoft Teams',
  gmail: 'Gmail',
  vscode: 'VS Code',
  notes: 'Notes',
  docs: 'Google Docs',
  keep: 'Google Keep',
  clinical: 'Clinical notes',
  claude: 'Claude Code',
  whatsapp: 'WhatsApp',
};
const vscodeIcon = {
  name: 'VS Code',
  color: '#007ACC',
  icon: 'M17.5 0L7 8.5 2.9 5.4 1 6.5v11l1.9 1.1L7 15.5 17.5 24l3.5-1.7V1.7L17.5 0zM4 14.2V9.8l3 2.2-3 2.2zm13.5 4.3L10 12l7.5-6.5v13z',
};
const icons = {
  slack: slackMark,
  discord: discordMark,
  teams: teamsMark,
  gmail: gmailMark,
  vscode:
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#007acc" d="' +
    vscodeIcon.icon +
    '"/></svg>',
  notes: '<span class="host-letter note-letter">▤</span>',
  docs: '<span class="host-letter docs-letter">▤</span>',
  keep: '<span class="host-letter keep-letter">▤</span>',
  clinical: '<span class="host-letter">✚</span>',
};
function mark(app) {
  return `<span class="host-logo host-logo-${app}">${icons[app] || icons.notes}</span>`;
}
const format =
  '<div class="host-format" aria-hidden="true"><b>B</b><i>I</i><u>U</u><span>≡</span><span>☷</span><span>↗</span></div>';
const draft = () => '<div class="host-draft-slot"></div>';
function conversation(app, context) {
  const slack = app === 'slack',
    discord = app === 'discord',
    teams = app === 'teams';
  const room = context.room || (discord ? 'project-chat' : teams ? 'Sofia' : 'team-updates');
  const rail = discord
    ? '<div class="host-server">EW</div><div class="host-server">◈</div><div class="host-server">+</div>'
    : teams
      ? '<span>◉</span><span class="active">▢</span><span>♧</span><span>▦</span><span>⋯</span>'
      : '<span class="workspace-square">E</span><span>⌂</span><span>▢</span><span>◉</span><span>⋯</span>';
  const side = teams
    ? `<strong>Chat <span>⌄</span></strong><div class="host-filters">Unread &nbsp; Channels</div><small>Favorites</small><span class="selected">S &nbsp; Sofia</span><small>Chats</small><span>Design team</span><span>Project updates</span>`
    : `<strong>${discord ? 'Envious community' : 'Envious workspace'} <span>⌄</span></strong><small>${discord ? 'Text channels' : 'Channels'}</small><span class="selected"># ${room}</span><span># general</span><span># design</span><small>${discord ? 'Voice channels' : 'Direct messages'}</small><span>${discord ? '♬ Lounge' : 'A &nbsp; Amira'}</span>`;
  const history = teams
    ? '<div class="teams-incoming">Could you send over the update?</div>'
    : `<div class="host-message"><span class="host-avatar">${discord ? 'L' : 'A'}</span><div><strong>${discord ? 'Leo' : 'Amira'} <small>10:42 AM</small></strong><p>Could you share an update when you get a chance?</p></div></div>`;
  const compose = discord
    ? `<div class="host-composer"><span class="discord-plus">+</span>${draft()}<div class="discord-tools" aria-hidden="true">◈ <b>GIF</b> ☺</div></div>`
    : `<div class="host-composer">${format}${draft()}<div class="host-compose-tools" aria-hidden="true"><span>＋ &nbsp; ☺ &nbsp; @ &nbsp; ♧</span><span class="host-send ${teams ? 'outline-send' : ''}">${teams ? '➤' : '➤ &nbsp;⌄'}</span></div></div>`;
  return `<div class="host-global"><span>${mark(app)}</span><span class="host-search">⌕ &nbsp; ${teams ? 'Search (Ctrl+Alt+E)' : slack ? 'Search Envious workspace' : 'Search'}</span><span class="host-own-avatar">S</span></div><div class="host-main"><aside class="host-rail" aria-hidden="true">${rail}</aside><aside class="host-sidebar" aria-hidden="true">${side}<div class="host-userbar">S &nbsp; Saurabh <span>⚙</span></div></aside><div class="host-conversation"><div class="host-channel"><strong>${teams ? '' : '# '}${room}</strong><span aria-hidden="true">⌕ &nbsp; ◉ &nbsp; ⋯</span></div>${slack || teams ? '<div class="host-channel-tabs">' + (teams ? 'Chat &nbsp; Shared' : 'Messages &nbsp; Files &nbsp; Pins') + '</div>' : ''}<div class="host-history" aria-hidden="true">${history}</div>${compose}</div></div>`;
}
function email(context) {
  return `<div class="gmail-top" aria-hidden="true"><span>☰</span>${mark('gmail')}<b>Gmail</b><span class="gmail-search">⌕ &nbsp; Search mail</span><span>⚙ &nbsp; ▦</span></div><div class="gmail-inbox" aria-hidden="true"><aside><span class="gmail-compose-button">✎ &nbsp;Compose</span><b>▣ &nbsp; Inbox</b><span>☆ &nbsp; Starred</span><span>◷ &nbsp; Snoozed</span><span>➤ &nbsp; Sent</span><span>▤ &nbsp; Drafts</span></aside><div class="gmail-mail-list"><div>□ &nbsp; ☆ <b>Project notes</b><span>Planning for next week</span></div><div>□ &nbsp; ☆ <b>Design team</b><span>Updated files</span></div><div>□ &nbsp; ☆ <b>Calendar</b><span>Meeting invitation</span></div><div>□ &nbsp; ☆ <b>${context.to || 'Maya'}</b><span>Our latest conversation</span></div></div></div><div class="gmail-compose"><div class="gmail-compose-title">New Message <span>− &nbsp;↗ &nbsp;×</span></div><div class="gmail-to"><span>To</span><span class="gmail-recipient">${context.to || 'Maya'} &nbsp;×</span></div><div class="gmail-subject">${context.subject || 'Project follow-up'}</div><div class="gmail-body">${draft()}</div><div class="gmail-format" aria-hidden="true">A &nbsp; Sans Serif &nbsp; <b>B</b> &nbsp;<i>I</i> &nbsp;<u>U</u> &nbsp;≡</div><div class="gmail-actions" aria-hidden="true"><span class="gmail-send">Send &nbsp;⌄</span><span>♧ &nbsp;↗ &nbsp;☺ &nbsp;△ &nbsp;▧</span><span>⋮ &nbsp;♜</span></div></div>`;
}
function coding() {
  return `<div class="code-title" aria-hidden="true"><span>Visual Studio Code</span><span>Search files & commands</span><span>− □ ×</span></div><div class="code-main"><aside class="code-rail" aria-hidden="true">▤<br>⌕<br>♧<br>▷<br>▦</aside><div class="code-editor" aria-hidden="true"><div class="code-file">configuration.ts &nbsp;×</div><pre><span>1</span> <b>export const</b> settings = {<br><span>2</span>   connection: {<br><span>3</span>     retries: <em>3</em>,<br><span>4</span>     timeout: <em>5000</em><br><span>5</span>   }<br><span>6</span> };</pre></div><div class="code-chat"><div class="code-chat-title">Chat <span>＋ ⋯</span></div><p class="code-chat-help" aria-hidden="true">Ask about your code<br>or describe a change.</p><div class="code-input"><small>＋ Add context</small>${draft()}<div class="code-input-bottom" aria-hidden="true"><span>Agent ⌄ &nbsp; Model ⌄</span><span>↑</span></div></div></div></div><div class="code-status" aria-hidden="true">⑂ main <span>TypeScript &nbsp; UTF-8</span></div>`;
}
function documentApp(app, context) {
  if (app === 'clinical')
    return `<div class="clinical-top">✚ Clinical notes <span>Practice workspace</span></div><div class="clinical-body"><aside aria-hidden="true"><b>Study case</b><span>Overview</span><span class="selected">Notes</span><span>History</span><span>Documents</span></aside><div class="clinical-notes"><div>Study notes <span>Practice case</span></div>${draft()}</div></div>`;
  if (app === 'keep')
    return `<div class="keep-top"><span>9:41</span><span>◉ ▰</span></div><div class="keep-nav">‹ <span>▣ &nbsp;♧</span></div><div class="keep-note"><h4>${context.title || 'Story notes'}</h4>${draft()}</div><div class="keep-bottom" aria-hidden="true">＋ &nbsp;◉ <span>Edited just now</span> ⋮</div>`;
  if (app === 'docs')
    return `<div class="docs-title">${mark('docs')}<div>${context.title || 'Essay draft'}<small>File &nbsp;Edit &nbsp;View &nbsp;Insert &nbsp;Format</small></div><span>Share</span></div><div class="docs-toolbar" aria-hidden="true">↶ ↷ &nbsp;100% &nbsp;Normal text &nbsp;Arial &nbsp;12 &nbsp;<b>B</b> &nbsp;<i>I</i> &nbsp;≡</div><div class="docs-page">${draft()}</div>`;
  return `<div class="notes-top" aria-hidden="true"><span class="notes-controls"><i></i><i></i><i></i><span>☷</span></span><span>Aa &nbsp;☷ &nbsp;▦ &nbsp;✎</span></div><div class="notes-body"><aside aria-hidden="true"><b>Notes</b><span class="selected">${context.title || 'Today'}</span><span>Ideas</span><span>Personal</span></aside><div class="notes-page"><small>Today &nbsp; 10:42 AM</small><h4>${context.title || 'Today’s notes'}</h4>${draft()}</div></div>`;
}

export function renderHost(app, input = {}) {
  const context = Object.fromEntries(
    Object.entries(input)
      .filter(([, v]) => v !== undefined && v !== null)
      .map(([k, v]) => [k, escapeHtml(String(v))]),
  );
  const custom = app === 'claude' || app === 'whatsapp';
  const content = custom
    ? personalApp(app)
    : ['slack', 'discord', 'teams'].includes(app)
      ? conversation(app, context)
      : app === 'gmail'
        ? email(context)
        : app === 'vscode'
          ? coding()
          : documentApp(app, context);
  return (
    '<div class="host-app host-' +
    escapeHtml(app) +
    (custom ? ' hero-host-' + app : '') +
    ' host-density-full" data-host-app="' +
    escapeHtml(app) +
    '" aria-label="Illustrated ' +
    escapeHtml(names[app] || app) +
    ' interface">' +
    content +
    '</div>'
  );
}
function personalApp(app) {
  const slot = '<div class="host-draft-slot hero-custom-slot"></div>';
  return app === 'claude'
    ? '<div class="hero-terminal-title">Terminal <span>~/projects/website</span></div><div class="hero-terminal-welcome"><strong>✳ Claude Code</strong><p>~/projects/website</p></div><div class="hero-terminal-prompt"><span aria-hidden="true">❯</span>' +
        slot +
        '</div><small class="hero-terminal-hint">? for shortcuts</small>'
    : '<div class="hero-wa-title"><span class="hero-wa-avatar">P</span><div><strong>Priya</strong><small>WhatsApp</small></div><span aria-hidden="true">⌕ &nbsp; ⋮</span></div><div class="hero-wa-history" aria-hidden="true"><small>Today</small><p>What time will you be here?</p></div><div class="hero-wa-compose"><span aria-hidden="true">＋</span>' +
        slot +
        '<span aria-hidden="true">➤</span></div>';
}
export { mark };
