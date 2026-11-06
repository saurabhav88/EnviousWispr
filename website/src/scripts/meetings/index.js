// EnviousMeet page (#4432): FAQ, card cycler, hero video theme swap, lotus fit. Ported from the mock-up.
var FAQ = [
  ['Accuracy', 'How accurate are EnviousMeet transcripts?', ['The full transcript is written on your Mac by Parakeet or Whisper Large v3 Turbo, the same engines EnviousWispr uses for dictation.', 'Live words during the meeting use your Custom Words. You can play back any moment to check a line, and Transcribe again with another engine.', 'The best test is to record one meeting next to your current tool and compare.']],
  ['Accuracy', 'How does EnviousMeet know who said what?', ['When the call sound has speech in it, everything your microphone hears is marked You. People on the call get numbered labels, such as Speaker 1 and Speaker 2.', 'In the Zoom app, the Teams app, Google Meet, and Teams and Zoom on the web, EnviousMeet shows their real names when it has enough evidence. It never guesses a name.']],
  ['Apps', 'What apps and tools does it work with?', ['It notices calls in Zoom, Microsoft Teams, FaceTime, Webex, Slack, Dialpad Meetings, Gather, Lark and VooV Meeting.', 'In a browser, it notices Google Meet, Zoom, Teams, Webex, Whereby, Jitsi and Slack huddles. You can also start a recording yourself for any call or a meeting in the room.']],
  ['Apps', 'Does EnviousMeet work for in-person meetings?', ['Yes. Start a recording from the menu bar, and EnviousMeet records your microphone. Voices it can tell apart get numbered speaker labels.']],
  ['Apps', 'Can I record meetings that are not on my calendar?', ['Yes. The calendar is optional and only names your meetings. It never starts a recording.', 'EnviousMeet notices calls from the call app itself, and you can always start a recording from the menu bar.']],
  ['Apps', 'Can I use ChatGPT, Claude or Gemini for summaries?', ['Yes, with your own key. The transcript, your notes and the meeting details go straight to the provider you chose. They never pass through Envious Labs.']],
  ['Privacy', 'Is my data private? What happens to the audio after a meeting?', ['Meeting audio, transcripts, notes and calendar details are stored on your Mac. The audio stays until you delete it. Delete audio removes only the audio and keeps the transcript.', 'Only a cloud summary provider you choose receives the transcript, notes and meeting details.', 'Envious Labs gets anonymous usage counts that you can turn off, never audio, words, names or calendar events.']],
  ['Privacy', 'Does it work without internet?', ['Yes. After the one-time model downloads, the transcript is written on your Mac with no internet.', 'For summaries with no internet, choose EG-1, Apple Intelligence (macOS 26) or a model you run with Ollama on your Mac.']],
  ['Privacy', 'Does a bot join my call?', ['No. EnviousMeet records the sound on your Mac: your microphone and, on macOS 14.2 or later, the call sound. Nobody in the call sees a notetaker join.']],
  ['Privacy', 'Do I need to get consent?', ['Recording laws differ by place. In some places, everyone in a call or a room must agree before you record.', 'You are responsible for telling people and getting their consent where the law requires it. EnviousMeet asks you to agree to this before your first recording.']],
  ['Getting started', 'Is EnviousMeet really free?', ['Yes. EnviousMeet is part of EnviousWispr, which is free and open source. There is no account and no subscription.', 'A cloud summary under your own key is billed by that provider.']],
  ['Getting started', 'Why EnviousMeet instead of other AI notetakers?', ['It is free and open source, with no account. Your meeting audio never leaves your Mac, and it can work fully offline.', 'It can follow your mute button in the Zoom app, the Teams app and Google Meet in Chrome or Safari, and it lives in EnviousWispr, so the app you dictate with also takes your meeting notes.']],
  ['Getting started', 'What languages can I use?', ['Choose the transcript language on the Models tab, or leave it on Auto. Parakeet covers 25 languages, and Whisper covers 99 or more.']],
  ['Getting started', 'What do I need to run it?', ['A Mac with Apple Silicon (M1 or later) and macOS 14 or later. Recording the call sound needs macOS 14.2 or later. EnviousMeet is on the Mac only.']],
  ['Getting started', 'Does it work with AirPods?', ['Yes. Call sound is recorded from your Mac, also with AirPods. Only the sound your Mac plays is recorded, never your screen.']],
  ['Getting started', 'Why does it say Beta?', ['EnviousMeet came out in EnviousWispr 2.6.0. It works today, and we are still improving it with your feedback.']]
];



var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

(function faq() {
  var list = document.getElementById('qlist'), ans = document.getElementById('answer'), last = '', btns = [];
  var box = document.querySelector('.faqbox'), narrow = window.matchMedia('(max-width: 680px)'), openI = 0;
  FAQ.forEach(function (f, i) {
    if (f[0] !== last) { var s = document.createElement('small'); s.textContent = f[0]; s.setAttribute('aria-hidden', 'true'); list.appendChild(s); last = f[0]; }
    var b = document.createElement('button'); b.type = 'button'; b.id = 'q' + i; b.textContent = f[1]; b.setAttribute('aria-controls', 'answer');
    list.appendChild(b); btns.push(b);
  });
  /* Desktop: a tab list with one answer panel. Phone: each question is a disclosure button that opens its answer below it. */
  function roles() {
    var phone = narrow.matches;
    if (phone) { list.removeAttribute('role'); ans.setAttribute('role', 'region'); }
    else { list.setAttribute('role', 'tablist'); ans.setAttribute('role', 'tabpanel'); }
    btns.forEach(function (b) {
      if (phone) { b.removeAttribute('role'); b.removeAttribute('aria-selected'); b.removeAttribute('tabindex'); }
      else { b.setAttribute('role', 'tab'); b.removeAttribute('aria-expanded'); }
    });
  }
  function show(i) {
    var phone = narrow.matches, open = !ans.hidden;
    btns.forEach(function (b, k) {
      var on = k === i && (!phone || open);
      b.classList.toggle('on', on);
      if (phone) b.setAttribute('aria-expanded', on ? 'true' : 'false');
      else { b.setAttribute('aria-selected', k === i ? 'true' : 'false'); b.tabIndex = k === i ? 0 : -1; }
    });
    var f = FAQ[i], d = document.createElement('div'); d.className = 'answer-in';
    var l = document.createElement('span'); l.className = 'lbl'; l.textContent = f[0]; d.appendChild(l);
    var h = document.createElement('h3'); h.textContent = f[1]; d.appendChild(h);
    f[2].forEach(function (t) { var p = document.createElement('p'); p.textContent = t; d.appendChild(p); });
    ans.innerHTML = ''; ans.appendChild(d); ans.setAttribute('aria-labelledby', 'q' + i);
    if (phone) { btns[i].after(ans); } else if (ans.parentNode !== box) { box.appendChild(ans); }
  }
  btns.forEach(function (b, k) {
    b.addEventListener('click', function () {
      if (narrow.matches && openI === k && !ans.hidden) { ans.hidden = true; show(k); return; }
      ans.hidden = false; openI = k; show(k);
    });
    b.addEventListener('keydown', function (e) {
      if (narrow.matches) return;
      var n = { ArrowDown: k + 1, ArrowRight: k + 1, ArrowUp: k - 1, ArrowLeft: k - 1, Home: 0, End: btns.length - 1 }[e.key];
      if (n === undefined) return;
      e.preventDefault(); n = (n + btns.length) % btns.length; openI = n; show(n); btns[n].focus();
    });
  });
  narrow.addEventListener('change', function () { ans.hidden = false; roles(); show(openI); });
  roles(); show(0);
})();

function cycler(items, onShow, ms, holder) {
  var i = 0, t = null, paused = false;
  function go(n) { i = (n + items) % items; onShow(i); clearTimeout(t); if (!reduce) t = setTimeout(function () { if (!paused) go(i + 1); else go(i); }, typeof ms === 'function' ? ms(i) : ms); }
  if (holder) { holder.addEventListener('mouseenter', function () { paused = true; }); holder.addEventListener('mouseleave', function () { paused = false; }); }
  return go;
}



(function spot() {
  var tabs = [].slice.call(document.querySelectorAll('#spotTabs button')), cards = [].slice.call(document.querySelectorAll('.flip')), cur = 0;
  /* Tabs and panels are linked for screen readers; only the shown card is exposed and focusable. */
  tabs.forEach(function (b, k) { b.id = 'spot-tab-' + k; b.setAttribute('aria-controls', 'spot-card-' + k); });
  cards.forEach(function (c, k) { c.id = 'spot-card-' + k; c.setAttribute('role', 'tabpanel'); c.setAttribute('aria-labelledby', 'spot-tab-' + k); });
  var go = cycler(6, function (i) {
    tabs.forEach(function (b, k) { b.classList.toggle('on', k === i); b.setAttribute('aria-selected', k === i ? 'true' : 'false'); b.tabIndex = k === i ? 0 : -1; });
    cards.forEach(function (c, k) {
      c.classList.remove('out'); if (k === cur && k !== i) c.classList.add('out'); c.classList.toggle('on', k === i);
      c.setAttribute('aria-hidden', k === i ? 'false' : 'true'); c.inert = k !== i;
    });
    cur = i;
    var sc = cards[i].querySelector('.sc'); if (sc) sc.replaceWith(sc.cloneNode(true));
  }, function (i) { return i < 2 ? 10000 : i === 2 ? 8000 : i === 3 ? 9000 : i === 5 ? 9000 : i === 4 ? 9000 : 4200; }, document.getElementById('deck'));
  tabs.forEach(function (b, k) {
    b.addEventListener('click', function () { go(k); });
    b.addEventListener('keydown', function (e) {
      var n = { ArrowDown: k + 1, ArrowRight: k + 1, ArrowUp: k - 1, ArrowLeft: k - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (n === undefined) return;
      e.preventDefault(); n = (n + tabs.length) % tabs.length; go(n); tabs[n].focus();
    });
  });
  go(0);
})();

(function video() {
  var v = document.getElementById('heroVideo');
  if (!v) return;
  var mq = window.matchMedia('(prefers-color-scheme: light)');
  function pick() {
    var forced = document.documentElement.getAttribute('data-theme');
    var light = forced ? forced === 'light' : mq.matches;
    var src = light ? '/meetings/enviousmeet-demo.mp4' : '/meetings/enviousmeet-demo-dark.mp4';
    if (v.getAttribute('src') !== src) {
      v.setAttribute('poster', light ? '/meetings/enviousmeet-poster.jpg' : '/meetings/enviousmeet-poster-dark.jpg');
      v.setAttribute('src', src); v.load(); if (!reduce) v.play().catch(function () {});
    }
  }
  pick();
  if (mq.addEventListener) mq.addEventListener('change', pick);
  new MutationObserver(pick).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  if (reduce) { v.removeAttribute('autoplay'); v.pause(); v.controls = true; }
})();

/* phones: scale the lotus to the screen */
(function () { var l = document.querySelector('.lotus'); if (!l) return;
  function fit() { l.style.setProperty('--ls', Math.min(.66, l.clientWidth / 1160).toFixed(4)); }
  fit(); window.addEventListener('resize', fit); })();
