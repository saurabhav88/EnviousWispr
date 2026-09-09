const PLAYER_LOAD_TIMEOUT_MS = 10000;

export function init(root, motion, scope) {
  const poster = root.querySelector('.review-poster');
  const card = root.querySelector('.proof-feature');
  let player,
    api,
    visible = false,
    suspended = false;
  let generation = 0;
  const permitted = () =>
    visible && !motion.paused && !document.hidden && !suspended && !scope.signal.aborted;
  function pause() {
    generation++;
    player?.pauseVideo?.();
  }

  // Use the player's readiness event; a loading iframe can miss an early pause.
  function loadAPI() {
    if (window.YT?.Player) return Promise.resolve(window.YT);
    if (!api)
      api = new Promise((resolve, reject) => {
        const previous = window.onYouTubeIframeAPIReady;
        const script = document.createElement('script');
        const timeout = setTimeout(() => reject(Error('Review player unavailable')), PLAYER_LOAD_TIMEOUT_MS);
        function ready() {
          clearTimeout(timeout);
          resolve(window.YT);
          if (typeof previous === 'function') previous();
        }
        window.onYouTubeIframeAPIReady = ready;
        script.src = 'https://www.youtube.com/iframe_api';
        script.onerror = () => {
          clearTimeout(timeout);
          reject(Error('Review player unavailable'));
        };
        scope.defer(() => {
          clearTimeout(timeout);
          script.onerror = null;
          if (window.onYouTubeIframeAPIReady === ready) window.onYouTubeIframeAPIReady = previous;
        });
        document.head.append(script);
      });
    return api;
  }

  poster.addEventListener(
    'click',
    async (event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
        return;
      event.preventDefault();
      const request = ++generation;
      try {
        const YT = await loadAPI();
        if (scope.signal.aborted || request !== generation) return;
        const iframe = document.createElement('iframe');
        iframe.className = 'review-embed';
        iframe.src =
          'https://www.youtube-nocookie.com/embed/tkV_A_6HFRQ?start=385&autoplay=0&enablejsapi=1&rel=0&playsinline=1&origin=' +
          encodeURIComponent(location.origin);
        iframe.title = 'Mostly Mac reviews EnviousWispr, starting at 6:25';
        iframe.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
        iframe.allowFullscreen = true;
        const focused = document.activeElement === poster;
        poster.replaceWith(iframe);
        if (focused) iframe.focus();
        const readyTimeout = setTimeout(() => {
          if (!scope.signal.aborted) scope.fallback(Error('Review player did not become ready'));
        }, PLAYER_LOAD_TIMEOUT_MS);
        scope.defer(() => clearTimeout(readyTimeout));
        player = new YT.Player(iframe, {
          events: {
            onReady({ target }) {
              clearTimeout(readyTimeout);
              if (scope.signal.aborted) {
                target.destroy();
                return;
              }
              if (request === generation && permitted()) target.playVideo();
              else target.pauseVideo();
            },
            onStateChange({ data, target }) {
              if ((data === 1 || data === 3) && !permitted()) target.pauseVideo();
            },
            onError() {
              scope.fallback(Error('Review playback unavailable'));
            },
          },
        });
      } catch (error) {
        if (!scope.signal.aborted) scope.fallback(error);
      }
    },
    { signal: scope.signal },
  );
  const observer = new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (!visible) pause();
  });
  observer.observe(card);
  document.addEventListener(
    'home:motion',
    () => {
      if (!permitted()) pause();
    },
    { signal: scope.signal },
  );
  window.addEventListener(
    'pagehide',
    () => {
      suspended = true;
      pause();
    },
    { signal: scope.signal },
  );
  window.addEventListener(
    'pageshow',
    () => {
      suspended = false;
    },
    { signal: scope.signal },
  );
  scope.defer(() => {
    generation++;
    observer.disconnect();
    player?.destroy?.();
  });
}
