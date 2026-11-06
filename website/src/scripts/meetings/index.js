// EnviousMeet page (#4432): FAQ, card cycler, hero video theme swap, lotus fit. Ported from the mock-up.




var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

(function faq() {
  /* The questions and answers are rendered in the page (MeetFaq.astro), so search engines read them all.
     Desktop: a tab list with one visible answer panel. Phone: each question is a disclosure button. */
  var list = document.getElementById('qlist'), ans = document.getElementById('answer');
  if (!list || !ans) return;
  var btns = [].slice.call(list.querySelectorAll('button')), panels = [].slice.call(ans.querySelectorAll('.answer-in'));
  var box = document.querySelector('.faqbox'), narrow = window.matchMedia('(max-width: 680px)'), openI = 0;
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
    panels.forEach(function (p, k) { p.hidden = k !== i; });
    ans.setAttribute('aria-labelledby', 'q' + i);
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
  var i = 0, t = null, paused = false, stopped = false;
  function go(n) { i = (n + items) % items; onShow(i); clearTimeout(t); if (!reduce && !stopped) t = setTimeout(function () { if (!paused) go(i + 1); else go(i); }, typeof ms === 'function' ? ms(i) : ms); }
  if (holder) { holder.addEventListener('mouseenter', function () { paused = true; }); holder.addEventListener('mouseleave', function () { paused = false; }); }
  /* A visitor who picks an item takes over: automatic advancing stops for good. */
  go.stop = function () { stopped = true; clearTimeout(t); };
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
    b.addEventListener('click', function () { go.stop(); go(k); });
    b.addEventListener('keydown', function (e) {
      var n = { ArrowDown: k + 1, ArrowRight: k + 1, ArrowUp: k - 1, ArrowLeft: k - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (n === undefined) return;
      e.preventDefault(); go.stop(); n = (n + tabs.length) % tabs.length; go(n); tabs[n].focus();
    });
  });
  /* Keyboard focus inside the tabs or cards also stops the automatic advance. */
  var spotBox = document.querySelector('.spot'); if (spotBox) spotBox.addEventListener('focusin', function () { go.stop(); });
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
