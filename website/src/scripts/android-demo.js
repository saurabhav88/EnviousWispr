// #4161: plays the Android tap demo (components/AndroidDemo.astro) on a loop.
// One pure frame function of scene time, as the app's OnboardingDemo.kt tapFrame
// does, with the same seconds. The page ships the finished frame; this script
// only runs when motion is allowed, and stops while the figure is off screen,
// the tab is hidden, or the visitor pauses it.
const SCENE = 5; // DemoScene.TAP.seconds
const LANDS = 3.4; // DemoScript.TAP_LANDS
const LOOP = 6.8; // the landed email stays up a little longer on the web
const RAINBOW = ['#ff2a40', '#ff8c00', '#ffd700', '#adff2f', '#00fa9a', '#00ffff', '#1e90ff', '#4169e1', '#8a2be2'];
const RESTING = '#3a3547';

// DemoScript.between: 0 before `from`, 1 after `to`, smoothstep between.
function between(t, from, to) {
  const v = Math.min(1, Math.max(0, (t - from) / (to - from)));
  return v * v * (3 - 2 * v);
}

// OnboardingDemo.kt demoVoice: syllables about six a second, a breath between phrases.
function voice(t) {
  const phrase = t % 2.6;
  if (phrase > 1.9) return 0;
  const syllable = 0.55 + 0.45 * Math.sin(phrase * 2 * Math.PI * 5.5);
  const envelope = Math.min(phrase * 4, 1) * Math.min((1.9 - phrase) * 3, 1);
  return Math.min(1, Math.max(0, syllable * envelope));
}

export function tapFrame(t) {
  const open = between(t, 0.52, 0.78) * (1 - between(t, 2.62, 2.88));
  const approach = between(t, 0.12, 0.48);
  const toCheck = between(t, 2.05, 2.5);
  const exit = between(t, 2.76, 3.08);
  const retreat = between(t, 0.65, 0.92) * (1 - between(t, 2.05, 2.5));
  const contactAt = t < 2 ? 0.52 : 2.62;
  return {
    open,
    seconds: open > 0 ? Math.max(0, Math.floor(t - 0.52)) : 0,
    handDx: 114 - 114 * approach - 4 * toCheck + 100 * exit + 38 * retreat,
    handDy: 90 - 90 * approach + 140 * exit + 105 * retreat,
    handAlpha: between(t, 0.1, 0.3) * (1 - exit),
    pressed: (t >= 0.5 && t < 0.62) || (t >= 2.58 && t < 2.7),
    ring: (t - contactAt) / 0.35,
    landed: t >= LANDS,
    step: t >= LANDS ? 2 : t >= 0.9 ? 1 : 0,
  };
}

function init(root) {
  const card = root.querySelector('.ad-card');
  const pill = root.querySelector('.ad-pill');
  const bubble = root.querySelector('.ad-bubble');
  const clock = root.querySelector('.ad-clock');
  const ring = root.querySelector('.ad-ring');
  const hand = root.querySelector('.ad-hand');
  const bars = [...root.querySelectorAll('.ad-rail i')];
  const toggle = root.querySelector('[data-android-demo-toggle]');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let visible = false;
  let paused = false;
  let failed = false;
  let raf = 0;
  let last = 0;
  let elapsed = 0;

  function draw(t) {
    const f = tapFrame(Math.min(t, SCENE));
    const u = (n) => `calc(${n} * var(--u))`;
    pill.style.opacity = f.open;
    pill.style.transform = `translateX(${u(240 * (1 - f.open))})`;
    bubble.style.opacity = 1 - f.open;
    clock.textContent = `0:${String(f.seconds).padStart(2, '0')}`;
    const level = f.open > 0 ? voice(t) : 0;
    bars.forEach((bar, i) => {
      const band = Math.abs(i - 5) / 5; // the lowest band in the middle, the highest at the edges
      const body = level * (1 - 0.75 * band);
      const flick = level > 0.8 ? Math.max(0, band - 0.6) * 1.5 * level : 0;
      const v = Math.min(1, Math.max(0, body + flick));
      bar.style.height = `${(0.14 + 0.86 * v) * 100}%`;
      bar.style.background = v > 0.02 ? RAINBOW[i % RAINBOW.length] : RESTING;
    });
    const r = f.ring;
    ring.style.opacity = r >= 0 && r <= 1 ? (1 - r) * 0.8 : 0;
    ring.style.transform = `scale(${0.55 + Math.min(Math.max(r, 0), 1) * 0.8})`;
    hand.style.opacity = f.handAlpha;
    hand.style.transform = `translate(${u(f.handDx)}, ${u(f.handDy)})`;
    root.toggleAttribute('data-pressed', f.pressed);
    root.dataset.phase = f.landed ? 'landed' : 'typing';
    root.toggleAttribute('data-cursor', Math.floor(t * 3) % 2 === 0);
    root.dataset.step = String(f.step);
  }

  function rest() {
    // The finished frame the page ships: bubble idle, email landed, last step lit.
    pill.style.opacity = 0;
    bubble.style.opacity = 1;
    hand.style.opacity = 0;
    ring.style.opacity = 0;
    root.removeAttribute('data-pressed');
    root.dataset.phase = 'landed';
    root.dataset.step = '2';
  }

  const running = () => !failed && visible && !paused && !reduced.matches && !document.hidden;
  function tick(now) {
    raf = 0;
    if (!running()) return;
    if (last) elapsed = (elapsed + Math.min(now - last, 100) / 1000) % LOOP;
    last = now;
    try {
      draw(elapsed);
      raf = requestAnimationFrame(tick);
    } catch (error) {
      // A drawing error leaves the finished frame, never a half-drawn one.
      failed = true;
      rest();
      toggle.hidden = true;
      console.error('Android demo stopped; the finished frame remains.', error);
    }
  }
  function update() {
    if (running()) {
      if (!raf) {
        last = 0;
        raf = requestAnimationFrame(tick);
      }
    } else {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      if (reduced.matches) rest();
    }
    toggle.hidden = reduced.matches || failed;
    toggle.textContent = paused ? 'Play' : 'Pause';
    toggle.setAttribute('aria-label', paused ? 'Play the demonstration' : 'Pause the demonstration');
  }

  toggle.addEventListener('click', () => {
    paused = !paused;
    update();
  });
  reduced.addEventListener('change', update);
  document.addEventListener('visibilitychange', update);
  new IntersectionObserver((entries) => {
    visible = entries.some((e) => e.isIntersecting);
    update();
  }).observe(card);
  update();
}

for (const root of document.querySelectorAll('[data-android-demo]')) {
  try {
    init(root);
  } catch (error) {
    console.error('Android demo stopped; the finished frame remains.', error);
  }
}
