const palette = [
  '#ff2a40',
  '#ff8c00',
  '#ffd700',
  '#adff2f',
  '#00fa9a',
  '#00ffff',
  '#1e90ff',
  '#4169e1',
  '#8a2be2',
];

/** Illustrated Reading Well, shared by hero and use-case demonstrations. */
export function createNativePreview() {
  const well = document.createElement('div');
  well.className = 'hero-native-well';
  well.setAttribute('aria-label', 'EnviousWispr live transcription preview');
  well.innerHTML =
    '<div class="hero-native-header"><span class="hero-native-clock">0:00</span><span class="hero-native-meter" aria-hidden="true"></span><span class="hero-native-mode">HANDS-FREE</span></div><div class="hero-native-words"></div>';
  const colors = palette.map((hex) =>
    [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16)),
  );
  const meter = well.querySelector('.hero-native-meter');
  const bars = Array.from({ length: 24 }, (_, i) => {
    const bar = document.createElement('i');
    const position = (i / 23) * 8,
      j = Math.min(7, Math.floor(position)),
      fraction = position - j;
    bar.style.setProperty(
      '--bar-color',
      'rgb(' +
        colors[j]
          .map((v, k) => Math.round(v * (1 - fraction) + colors[j + 1][k] * fraction))
          .join(',') +
        ')',
    );
    meter.append(bar);
    return bar;
  });
  const wheelBars = [
    [0, 4, 14, '#ff2d55'],
    [30, 7, 10, '#ff9f0a'],
    [60, 5, 12, '#ffd60a'],
    [90, 8, 9, '#30d158'],
    [120, 4, 14, '#34c759'],
    [150, 6, 11, '#32d8be'],
    [180, 5, 13, '#64d2ff'],
    [210, 8, 9, '#0a84ff'],
    [240, 4, 14, '#5e5ce6'],
    [270, 6, 12, '#bf5af2'],
    [300, 7, 10, '#ff2d55'],
    [330, 5, 13, '#ff9f0a'],
  ];
  const processing = document.createElement('div');
  processing.className = 'hero-native-processing';
  processing.innerHTML =
    '<svg class="hero-spectrum-wheel" viewBox="0 0 64 64" aria-hidden="true">' +
    wheelBars
      .map(
        ([deg, y, h, color]) =>
          '<rect x="30" y="' +
          y +
          '" width="4" height="' +
          h +
          '" rx="2" fill="' +
          color +
          '" transform="rotate(' +
          deg +
          ' 32 32)"/>',
      )
      .join('') +
    '</svg><span></span>';
  const clock = well.querySelector('.hero-native-clock'),
    words = well.querySelector('.hero-native-words'),
    label = processing.querySelector('span');
  const history = Array(24).fill(0.14);
  let lastTick = -1,
    lastElapsed = -1;
  well.hidden = processing.hidden = true;
  return {
    well,
    processing,
    set(phase, raw, elapsed = 0) {
      well.hidden = phase !== 'listening';
      processing.hidden = !['processing', 'polishing', 'transcribing'].includes(phase);
      label.textContent = phase === 'transcribing' ? 'Transcribing...' : 'Polishing...';
      if (phase !== 'listening') return;
      clock.textContent = '0:' + String(Math.floor(elapsed / 1000)).padStart(2, '0');
      if (words.textContent !== raw) {
        words.textContent = raw;
        words.scrollTop = words.scrollHeight;
      }
      if (elapsed < lastElapsed) {
        history.fill(0.14);
        lastTick = -1;
      }
      lastElapsed = elapsed;
      const tick = Math.floor(elapsed / 50);
      if (tick !== lastTick) {
        lastTick = tick;
        history.shift();
        history.push(
          0.14 +
            0.86 * (0.18 + 0.82 * Math.abs(Math.sin(elapsed * 0.007) * Math.cos(elapsed * 0.0019))),
        );
        bars.forEach((bar, i) =>
          bar.style.setProperty('--bar-height', (history[i] * 16).toFixed(2) + 'px'),
        );
      }
    },
  };
}
