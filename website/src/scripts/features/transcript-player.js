// Recording deck (#2816): five real recordings, click-to-load YouTube player,
// timestamped transcript in three views, prev/next with a card flip, swipe.
// Ported from the mock's transcript-player.js with these changes:
//   - the transcript JSON is fetched when the deck first comes into view or
//     on the first interaction, never on page load; a failed first fetch
//     re-arms so the next interaction retries;
//   - the page's build-time evidence for card 0 stays until a payload whose
//     id matches the selected case has fully validated and rendered off-DOM;
//     any card that fails afterwards shows its own unavailable state, never
//     another recording's numbers, including card 0 when revisited;
//   - every fetch carries the island's abort signal; player creation has its
//     own generation invalidated on disposal and pagehide; timers and the
//     card flip are cancelled on disposal; the flip obeys the shared motion
//     policy; load and error outcomes are announced through one live region.
import { guarded, keepRoot, enableControls, on } from './guard.js';

let apiPromise;
function youtubeAPI() {
  if (window.YT?.Player) return Promise.resolve(window.YT);
  if (apiPromise) return apiPromise;
  apiPromise = new Promise((resolve, reject) => {
    const prior = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => {
      prior?.();
      resolve(window.YT);
    };
    const script = document.createElement('script');
    script.src = 'https://www.youtube.com/iframe_api';
    script.onerror = () => {
      apiPromise = null;
      reject(Error('YouTube unavailable'));
    };
    document.head.append(script);
  });
  return apiPromise;
}
const stamp = (seconds) => {
  const s = Math.floor(seconds);
  return (s >= 3600 ? Math.floor(s / 3600) + ':' : '') + String(Math.floor(s / 60) % 60).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
};
const isPassage = (p) =>
  p &&
  typeof p === 'object' &&
  Number.isFinite(p.start) &&
  Number.isFinite(p.end) &&
  typeof p.raw === 'string' &&
  typeof p.polished === 'string' &&
  typeof p.polishSucceeded === 'boolean' &&
  Array.isArray(p.diff) &&
  p.diff.every((d) => d && typeof d.text === 'string' && ['equal', 'delete', 'insert'].includes(d.type));
function validPayload(loaded, item) {
  return (
    loaded &&
    typeof loaded === 'object' &&
    String(loaded.id) === item.id &&
    Number.isFinite(loaded.wordCount) &&
    Number.isFinite(loaded.umUhRemoved) &&
    Number.isFinite(loaded.polishMs) &&
    typeof loaded.provenance === 'string' &&
    Array.isArray(loaded.passages) &&
    loaded.passages.length > 0 &&
    loaded.passages.every(isPassage)
  );
}

export function init(host, motion, scope) {
  keepRoot(host, scope);
  const { signal } = scope;
  const cases = JSON.parse(host.dataset.recordingCases);
  if (!Array.isArray(cases) || !cases.length) throw new Error('deck: no cases');
  const body = host.querySelector('#case-transcript-body');
  const note = host.querySelector('#case-excerpt-note');
  const videoHost = host.querySelector('#case-video');
  const metrics = host.querySelectorAll('.recording-metrics dd');
  const provenance = host.querySelector('#measurement-provenance');
  const hint = host.querySelector('.transcript-hint');
  const modeButtons = [...host.querySelectorAll('[data-transcript-mode]')];
  let selected = 0;
  let mode = 'changes';
  let data = null;
  let player = null;
  let revision = 0;
  let playerGeneration = 0;
  let timer = null;
  let current = -1;
  let loading = false;
  let seekTo = 0;
  let firstFetchArmed = true;
  let flip = null;
  let hoverClose = null;

  function stop() {
    playerGeneration++;
    clearInterval(timer);
    timer = null;
    try {
      player?.destroy?.();
    } catch {
      /* a disposer never throws */
    }
    player = null;
    loading = false;
  }
  scope.defer(() => {
    stop();
    clearTimeout(hoverClose);
    try {
      flip?.cancel();
    } catch {
      /* a disposer never throws */
    }
  });

  function follow() {
    if (!player?.getCurrentTime || !data) return;
    const t = player.getCurrentTime();
    const i = data.passages.findIndex((p) => t >= p.start && t < p.end);
    if (i < 0 || i === current) return;
    current = i;
    body.querySelectorAll('.transcript-passage').forEach((e, n) => {
      e.classList.toggle('current', i === n);
      e.setAttribute('aria-current', String(i === n));
    });
    const row = body.children[i];
    if (row) body.scrollTop = row.offsetTop - 12;
  }
  function polling() {
    clearInterval(timer);
    timer = null;
    if (player && !document.hidden) timer = setInterval(guarded(scope, follow), 400);
  }
  async function play(at = 0) {
    seekTo = at;
    if (player?.seekTo) {
      player.seekTo(at, true);
      player.playVideo();
      follow();
      return;
    }
    if (loading) return;
    const item = cases[selected];
    const ticket = ++playerGeneration;
    if (!item.video) return;
    loading = true;
    try {
      const YT = await youtubeAPI();
      if (ticket !== playerGeneration || signal.aborted) return;
      videoHost.replaceChildren();
      const mount = document.createElement('div');
      videoHost.append(mount);
      player = new YT.Player(mount, {
        host: 'https://www.youtube-nocookie.com',
        videoId: item.video,
        playerVars: { playsinline: 1, origin: location.origin },
        events: {
          onReady: guarded(scope, (e) => {
            if (ticket !== playerGeneration || signal.aborted) {
              e.target.destroy();
              return;
            }
            loading = false;
            e.target.seekTo(seekTo, true);
            e.target.playVideo();
            polling();
          }),
          onStateChange: guarded(scope, follow),
          onError: guarded(scope, () => {
            if (ticket !== playerGeneration) return;
            loading = false;
            note.textContent = 'YouTube cannot play this video here. Use the Watch on YouTube link; the transcript is still available.';
            clearInterval(timer);
            timer = null;
          }),
        },
      });
    } catch {
      if (ticket !== playerGeneration || signal.aborted) return;
      loading = false;
      note.textContent = 'The video could not load. Use the Watch on YouTube link.';
    }
  }

  function passageRow(p, i, playable) {
    const row = document.createElement('div');
    row.className = 'transcript-passage' + (i === current ? ' current' : '');
    const time = document.createElement('span');
    time.className = 'transcript-time';
    time.textContent = playable ? '▶ Play from ' + stamp(p.start) : stamp(p.start);
    if (playable) {
      row.setAttribute('role', 'button');
      row.tabIndex = 0;
      row.setAttribute('aria-label', 'Play passage from ' + stamp(p.start));
      row.classList.add('seekable');
      const seek = () => {
        current = i;
        play(p.start);
        body.querySelectorAll('.transcript-passage').forEach((el, n) => {
          el.classList.toggle('current', n === i);
          el.setAttribute('aria-current', String(n === i));
        });
      };
      on(scope, row, 'click', () => {
        if (!window.getSelection()?.toString()) seek();
      });
      on(scope, row, 'keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          seek();
        }
      });
    }
    const text = document.createElement('p');
    text.id = `transcript-passage-text-${i}`;
    if (playable) row.setAttribute('aria-describedby', text.id);
    if (mode === 'changes') {
      for (const part of p.diff) {
        const el = document.createElement(part.type === 'delete' ? 'del' : part.type === 'insert' ? 'mark' : 'span');
        el.textContent = part.text;
        text.append(el);
      }
    } else text.textContent = mode === 'raw' ? p.raw : p.polished;
    row.append(time, text);
    if (!p.polishSucceeded) {
      const status = document.createElement('small');
      status.textContent = 'Polish unavailable for this passage. Original cleanup output shown.';
      row.append(status);
    }
    return row;
  }
  /** Build every row off-DOM first; only then replace the transcript. */
  function renderTranscript() {
    if (!data) return;
    const previous = body.scrollTop;
    const playable = Boolean(cases[selected].video);
    const fragment = document.createDocumentFragment();
    data.passages.forEach((p, i) => fragment.append(passageRow(p, i, playable)));
    body.replaceChildren(fragment);
    body.scrollTop = current >= 0 && body.children[current] ? body.children[current].offsetTop - 12 : previous;
  }
  function setModes(enabled) {
    for (const b of modeButtons) b.setAttribute('aria-disabled', String(!enabled));
  }
  function unavailable(message) {
    data = null;
    metrics.forEach((e) => (e.textContent = 'Unavailable'));
    provenance.textContent = 'Recording details could not load.';
    const p = document.createElement('p');
    p.textContent = message;
    body.replaceChildren(p);
    note.textContent = message;
    setModes(false);
  }
  async function load(item, ticket, keepEvidenceOnFailure) {
    try {
      const result = await fetch(item.transcript, { signal });
      if (!result.ok) throw Error('missing');
      const loaded = await result.json();
      if (ticket !== revision || signal.aborted) return;
      if (!validPayload(loaded, item)) throw Error('mismatch');
      data = loaded;
      renderTranscript();
      metrics[0].textContent = data.wordCount.toLocaleString();
      metrics[1].textContent = data.umUhRemoved.toLocaleString();
      metrics[2].textContent = stamp(Math.round(data.polishMs / 1000));
      provenance.textContent = data.provenance;
      note.textContent = item.video ? 'Transcript loaded.' : 'Transcript loaded. Timestamps refer to the local recording; synchronized playback is unavailable.';
      setModes(true);
    } catch (error) {
      if (ticket !== revision || signal.aborted) return;
      if (keepEvidenceOnFailure) {
        // Card 0's page evidence stays; a later interaction retries the fetch.
        firstFetchArmed = true;
        note.textContent = 'The full transcript could not load. The opening passages above are from this recording. Select a view or scroll to retry.';
      } else {
        unavailable('Transcript unavailable for this recording. Use the source link to watch it.');
      }
    }
  }
  function select(i) {
    stop();
    const ticket = ++revision;
    selected = i;
    current = -1;
    data = null;
    seekTo = 0;
    firstFetchArmed = false;
    const item = cases[i];
    host.querySelector('#recording-position').textContent = i + 1 + ' of ' + cases.length + ' recordings';
    hint.textContent = item.video
      ? 'Play the video to follow along. Click anywhere on a passage to play from that moment.'
      : 'Read the timestamped transcript below. Synchronized playback is not available for this recording.';
    host.querySelector('#case-title').textContent = item.name;
    host.querySelector('#case-subtitle').textContent = item.title;
    host.querySelector('#case-duration').textContent = item.duration;
    host.querySelector('#case-format').textContent = item.kind;
    host.querySelector('#case-source').textContent = item.source;
    const link = host.querySelector('#case-source-link');
    link.hidden = !item.video && !item.sourceUrl;
    link.textContent = item.video ? 'Watch on YouTube ↗' : 'View original source ↗';
    if (item.video) link.href = 'https://www.youtube.com/watch?v=' + item.video;
    else if (item.sourceUrl) link.href = item.sourceUrl;
    else link.removeAttribute('href');
    videoHost.replaceChildren();
    if (item.video) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'case-load';
      button.setAttribute('aria-label', 'Play ' + item.name + ' source video');
      button.innerHTML = '<span class="case-play">▶</span><strong>Watch and follow the transcript</strong><small>Click to load YouTube</small>';
      const img = document.createElement('img');
      img.className = 'case-thumbnail';
      img.src = 'https://i.ytimg.com/vi/' + item.video + '/hqdefault.jpg';
      img.alt = '';
      img.loading = 'lazy';
      button.prepend(img);
      on(scope, button, 'click', () => play());
      videoHost.append(button);
    } else {
      const p = document.createElement('div');
      p.className = 'case-source-pending';
      p.textContent = 'Local recording confirmed. Matching source video link pending.';
      videoHost.append(p);
    }
    host.querySelector('.measurement-info').open = false;
    // Every selection, including a return to card 0, shows its own pending
    // state; the page's build-time evidence belongs to the initial view only.
    metrics.forEach((e) => (e.textContent = 'Pending'));
    provenance.textContent = 'Loading recording details.';
    const p = document.createElement('p');
    p.textContent = 'Loading the transcript for this recording.';
    body.replaceChildren(p);
    note.textContent = 'Loading the transcript for ' + item.name + '.';
    setModes(false);
    load(item, ticket, false);
  }

  // First card: the page already carries its evidence. Fetch the full
  // transcript when the deck is in view or on the first interaction.
  const fireFirst = guarded(scope, () => {
    if (!firstFetchArmed) return;
    firstFetchArmed = false;
    load(cases[selected], revision, true);
  });
  const observer = new IntersectionObserver(
    guarded(scope, (entries) => {
      if (entries.some((e) => e.isIntersecting)) fireFirst();
    }),
    { threshold: 0.1 },
  );
  observer.observe(host);
  scope.defer(() => observer.disconnect());
  on(scope, host, 'pointerdown', fireFirst);
  on(scope, host, 'focusin', fireFirst);

  const info = host.querySelector('.measurement-info');
  on(scope, info, 'pointerenter', (e) => {
    if (e.pointerType === 'mouse') {
      clearTimeout(hoverClose);
      info.open = true;
    }
  });
  on(scope, info, 'pointerleave', (e) => {
    if (e.pointerType === 'mouse') {
      clearTimeout(hoverClose);
      hoverClose = setTimeout(
        guarded(scope, () => {
          if (!info.contains(document.activeElement)) info.open = false;
        }),
        180,
      );
    }
  });
  on(scope, info, 'keydown', (e) => {
    if (e.key === 'Escape') {
      info.open = false;
      info.querySelector('summary').focus();
    }
  });

  const card = host.querySelector('.recording-case');
  function turn(direction) {
    flip?.cancel();
    flip = null;
    select((selected + direction + cases.length) % cases.length);
    if (motion.allowed() && !motion.reduced.matches)
      flip = card.animate(
        [{ opacity: 0.25, transform: `translateX(${direction * 20}px) rotateY(${direction * 5}deg)` }, { opacity: 1, transform: 'none' }],
        { duration: 380, easing: 'cubic-bezier(.2,.7,.2,1)' },
      );
  }
  on(scope, host.querySelector('[data-recording-prev]'), 'click', () => turn(-1));
  on(scope, host.querySelector('[data-recording-next]'), 'click', () => turn(1));
  on(scope, motion.reduced, 'change', () => {
    if (motion.reduced.matches) {
      flip?.cancel();
      flip = null;
    }
  });
  const swipe = host.querySelector('.recording-heading');
  let start = null;
  on(scope, swipe, 'pointerdown', (e) => {
    if (e.pointerType === 'touch') start = { x: e.clientX, y: e.clientY };
  });
  on(scope, swipe, 'pointercancel', () => (start = null));
  on(scope, swipe, 'pointerup', (e) => {
    if (!start) return;
    const dx = e.clientX - start.x;
    const dy = e.clientY - start.y;
    start = null;
    if (Math.abs(dx) > 55 && Math.abs(dx) > Math.abs(dy) * 1.5) turn(dx < 0 ? 1 : -1);
  });
  for (const b of modeButtons)
    on(scope, b, 'click', () => {
      if (!data) {
        // No payload yet: retry the fetch, keep the view as it is.
        fireFirst();
        return;
      }
      mode = b.dataset.transcriptMode;
      modeButtons.forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      renderTranscript();
    });
  setModes(false);
  // The build-time passage rows on card 0 become seekable once the script is up.
  if (cases[selected].video) {
    host.querySelectorAll('#case-transcript-body .transcript-passage[data-start]').forEach((row) => {
      row.setAttribute('role', 'button');
      row.tabIndex = 0;
      row.classList.add('seekable');
      const at = Number(row.dataset.start);
      const seek = () => {
        fireFirst();
        play(at);
      };
      on(scope, row, 'click', () => {
        if (!window.getSelection()?.toString()) seek();
      });
      on(scope, row, 'keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          seek();
        }
      });
    });
    const loadButton = host.querySelector('[data-load-video]');
    if (loadButton) on(scope, loadButton, 'click', () => play());
  }
  on(scope, document, 'visibilitychange', polling);
  on(scope, window, 'pagehide', stop);
  enableControls(host);
}
