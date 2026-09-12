// Recording deck (#2816): five real recordings, click-to-load YouTube player,
// timestamped transcript in three views, prev/next with a card flip, swipe.
// Ported from the mock's transcript-player.js with three changes:
//   - the transcript JSON is fetched when the deck first comes into view or
//     on the first interaction, never on page load;
//   - the first card's build-time evidence stays until a payload whose id
//     matches the selected case has parsed; a later card that fails shows its
//     own unavailable state, never another recording's numbers;
//   - the card flip runs through the shared motion controller's policy.
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

export function init(host, motion, scope) {
  const { signal } = scope;
  const cases = JSON.parse(host.dataset.recordingCases);
  const body = host.querySelector('#case-transcript-body');
  const note = host.querySelector('#case-excerpt-note');
  const videoHost = host.querySelector('#case-video');
  const metrics = host.querySelectorAll('.recording-metrics dd');
  const provenance = host.querySelector('#measurement-provenance');
  const hint = host.querySelector('.transcript-hint');
  const initialId = host.dataset.initialCase;
  let selected = 0;
  let mode = 'changes';
  let data = null;
  let player = null;
  let revision = 0;
  let timer = null;
  let current = -1;
  let loading = false;
  let seekTo = 0;
  let firstFetchArmed = true;

  function stop() {
    clearInterval(timer);
    timer = null;
    player?.destroy?.();
    player = null;
    loading = false;
  }
  scope.defer(stop);

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
    if (player && !document.hidden) timer = setInterval(follow, 400);
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
    const ticket = revision;
    if (!item.video) return;
    loading = true;
    try {
      const YT = await youtubeAPI();
      if (ticket !== revision || signal.aborted) return;
      videoHost.replaceChildren();
      const mount = document.createElement('div');
      videoHost.append(mount);
      player = new YT.Player(mount, {
        host: 'https://www.youtube-nocookie.com',
        videoId: item.video,
        playerVars: { playsinline: 1, origin: location.origin },
        events: {
          onReady: (e) => {
            if (ticket !== revision || signal.aborted) {
              e.target.destroy();
              return;
            }
            loading = false;
            e.target.seekTo(seekTo, true);
            e.target.playVideo();
            polling();
          },
          onStateChange: follow,
          onError: () => {
            if (ticket !== revision) return;
            loading = false;
            note.textContent = 'YouTube cannot play this video here. Use the Watch on YouTube link; the transcript is still available.';
            clearInterval(timer);
            timer = null;
          },
        },
      });
    } catch {
      if (ticket !== revision) return;
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
      row.addEventListener('click', () => {
        if (!window.getSelection()?.toString()) seek();
      });
      row.addEventListener('keydown', (e) => {
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
  function renderTranscript() {
    const previous = body.scrollTop;
    if (!data) return; // the build-time or unavailable state stays as rendered
    body.replaceChildren();
    const playable = Boolean(cases[selected].video);
    data.passages.forEach((p, i) => body.append(passageRow(p, i, playable)));
    body.scrollTop = current >= 0 && body.children[current] ? body.children[current].offsetTop - 12 : previous;
  }
  function unavailable(message) {
    data = null;
    metrics.forEach((e) => (e.textContent = 'Unavailable'));
    provenance.textContent = 'Recording details could not load.';
    body.replaceChildren();
    const p = document.createElement('p');
    p.textContent = message;
    body.append(p);
  }
  function validPayload(loaded, item) {
    return (
      loaded &&
      typeof loaded === 'object' &&
      String(loaded.id) === item.id &&
      Array.isArray(loaded.passages) &&
      Number.isFinite(loaded.wordCount) &&
      Number.isFinite(loaded.umUhRemoved) &&
      Number.isFinite(loaded.polishMs) &&
      typeof loaded.provenance === 'string'
    );
  }
  async function load(item, ticket, initial) {
    try {
      const result = await fetch(item.transcript);
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
      note.textContent = item.video ? '' : 'Timestamps refer to the local recording; synchronized playback is unavailable.';
    } catch (error) {
      if (ticket !== revision) return;
      if (initial) {
        // Card 0 keeps its build-time evidence; only say the full transcript is not loading.
        note.textContent = 'The full transcript could not load. The opening passages above are from the same recording.';
      } else {
        unavailable('Transcript unavailable for this recording. Use the source link to watch it.');
      }
    }
  }
  function select(i, { fetchNow = true } = {}) {
    stop();
    const ticket = ++revision;
    selected = i;
    current = -1;
    data = null;
    seekTo = 0;
    const item = cases[i];
    const initial = item.id === initialId;
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
      button.addEventListener('click', () => play());
      videoHost.append(button);
    } else {
      const p = document.createElement('div');
      p.className = 'case-source-pending';
      p.textContent = 'Local recording confirmed. Matching source video link pending.';
      videoHost.append(p);
    }
    note.textContent = '';
    host.querySelector('.measurement-info').open = false;
    if (!initial) {
      // A newly selected recording shows its own pending state, never the previous one's numbers.
      metrics.forEach((e) => (e.textContent = 'Pending'));
      provenance.textContent = 'Loading recording details.';
      body.replaceChildren();
      const p = document.createElement('p');
      p.textContent = 'Loading the transcript for this recording.';
      body.append(p);
    }
    if (fetchNow) load(item, ticket, initial);
    return ticket;
  }

  // First card: the page already carries its evidence. Fetch the full transcript
  // when the deck is in view or on the first interaction, whichever comes first.
  function armFirstFetch() {
    const fire = () => {
      if (!firstFetchArmed) return;
      firstFetchArmed = false;
      observer.disconnect();
      load(cases[selected], revision, true);
    };
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) fire();
      },
      { threshold: 0.1 },
    );
    observer.observe(host);
    scope.defer(() => observer.disconnect());
    host.addEventListener('pointerdown', fire, { once: true, signal });
    host.addEventListener('focusin', fire, { once: true, signal });
    return fire;
  }
  const fireFirst = armFirstFetch();

  const info = host.querySelector('.measurement-info');
  let hoverClose;
  info.addEventListener(
    'pointerenter',
    (e) => {
      if (e.pointerType === 'mouse') {
        clearTimeout(hoverClose);
        info.open = true;
      }
    },
    { signal },
  );
  info.addEventListener(
    'pointerleave',
    (e) => {
      if (e.pointerType === 'mouse')
        hoverClose = setTimeout(() => {
          if (!info.contains(document.activeElement)) info.open = false;
        }, 180);
    },
    { signal },
  );
  info.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Escape') {
        info.open = false;
        info.querySelector('summary').focus();
      }
    },
    { signal },
  );

  const card = host.querySelector('.recording-case');
  let flip;
  function turn(direction) {
    flip?.cancel();
    firstFetchArmed = false;
    select((selected + direction + cases.length) % cases.length);
    if (motion.allowed() && !motion.reduced.matches)
      flip = card.animate(
        [{ opacity: 0.25, transform: `translateX(${direction * 20}px) rotateY(${direction * 5}deg)` }, { opacity: 1, transform: 'none' }],
        { duration: 380, easing: 'cubic-bezier(.2,.7,.2,1)' },
      );
  }
  host.querySelector('[data-recording-prev]').addEventListener('click', () => turn(-1), { signal });
  host.querySelector('[data-recording-next]').addEventListener('click', () => turn(1), { signal });
  const swipe = host.querySelector('.recording-heading');
  let start = null;
  swipe.addEventListener(
    'pointerdown',
    (e) => {
      if (e.pointerType === 'touch') start = { x: e.clientX, y: e.clientY };
    },
    { signal },
  );
  swipe.addEventListener('pointercancel', () => (start = null), { signal });
  swipe.addEventListener(
    'pointerup',
    (e) => {
      if (!start) return;
      const dx = e.clientX - start.x;
      const dy = e.clientY - start.y;
      start = null;
      if (Math.abs(dx) > 55 && Math.abs(dx) > Math.abs(dy) * 1.5) turn(dx < 0 ? 1 : -1);
    },
    { signal },
  );
  host.querySelectorAll('[data-transcript-mode]').forEach((b) =>
    b.addEventListener(
      'click',
      () => {
        mode = b.dataset.transcriptMode;
        host.querySelectorAll('[data-transcript-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
        if (!data) fireFirst();
        renderTranscript();
      },
      { signal },
    ),
  );
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
      row.addEventListener('click', () => {
        if (!window.getSelection()?.toString()) seek();
      }, { signal });
      row.addEventListener(
        'keydown',
        (e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            seek();
          }
        },
        { signal },
      );
    });
    host.querySelector('[data-load-video]')?.addEventListener('click', () => play(), { signal });
  }
  document.addEventListener('visibilitychange', polling, { signal });
  window.addEventListener('pagehide', stop, { signal });
}
