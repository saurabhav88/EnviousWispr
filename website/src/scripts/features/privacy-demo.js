// Why Offline film (#2816): cloud boardroom, scissors cut, the lips replace
// the cloud. Ported from the mock's privacy-demo.js.
import { keepRoot, enableControls, on } from './guard.js';

export function init(root, motion, scope) {
  keepRoot(root, scope);
  const durations = [5700, 3200, 5000];
  const titles = ['When dictation uses the cloud', 'Choose a local alternative', 'All on your Mac'];
  const captions = ['Your words are sent to a server.', 'Cut the connection. Use your Mac.', 'No account. No subscription.'];
  const play = root.querySelector('[data-privacy-play]');
  const title = root.querySelector('[data-privacy-title]');
  const caption = root.querySelector('[data-privacy-caption]');
  const story = root.querySelector('[data-privacy-story]');
  const packets = [...root.querySelectorAll('.word-packet')];
  const money = [...root.querySelectorAll('.cloud-money text')];
  const total = durations.reduce((a, b) => a + b, 0);
  const clamp = (x) => Math.max(0, Math.min(1, x));
  const ease = (x) => 1 - Math.pow(1 - clamp(x), 3);
  let elapsed = 0;
  let paused = false;
  let clock;
  let lastScene = -1;

  function controls() {
    const stopped = paused || !motion.allowed();
    play.textContent = stopped ? '▶' : 'Ⅱ';
    play.setAttribute('aria-label', stopped ? 'Play privacy demo' : 'Pause privacy demo');
    play.disabled = motion.reduced.matches;
    root.dataset.playing = String(!stopped);
  }
  function storyMarkup(i) {
    if (i === 2) return '<span class="privacy-final-name">EnviousWispr</span><br><span class="privacy-final-promise">Privacy first.</span>';
    if (i === 1) return 'Let’s keep<br>this local.';
    return 'Your words are<br><span class="privacy-money">$$$</span> for corporations.';
  }
  function draw() {
    let t = elapsed;
    let i = 0;
    while (i < durations.length - 1 && t >= durations[i]) t -= durations[i++];
    root.dataset.scene = String(i);
    const entry = ease(t / 850);
    const close = clamp((t - 900) / 300);
    const severed = clamp((t - 1200) / 850);
    const recoilPhase = clamp((t - 1200) / 1000);
    const recoil = recoilPhase > 0 ? 1 - Math.exp(-6 * recoilPhase) * Math.cos(13 * recoilPhase) : 0;
    root.style.setProperty('--jaw', close * (1 - ease((t - 1450) / 350)));
    root.style.setProperty('--exit', ease((t - 1850) / 600));
    root.style.setProperty('--entry', entry);
    root.style.setProperty('--close', close);
    root.style.setProperty('--severed', severed);
    root.style.setProperty('--recoil', recoil);
    root.style.setProperty('--snip', clamp(1 - Math.abs(t - 1250) / 250));
    root.style.setProperty('--reveal', motion.reduced.matches ? 1 : ease(t / 850));
    root.style.setProperty('--reveal-copy', motion.reduced.matches ? 1 : ease((t - 200) / 850));
    packets.forEach((packet, n) => {
      const p = ((elapsed + n * 850) % 2550) / 2550;
      packet.style.transform = `translate(${25 - 45 * p * p}px,${40 - 116 * p}px)`;
      packet.style.opacity = String(clamp(p * 7) * clamp((1 - p) * 7));
    });
    money.forEach((symbol, n) => {
      const p = ((elapsed + n * 600) % 1800) / 1800;
      symbol.style.opacity = String(Math.sin(p * Math.PI) * 0.65);
      symbol.style.transform = `translateY(${-p * 8}px)`;
    });
    if (lastScene !== i) {
      title.textContent = titles[i];
      caption.textContent = captions[i];
      story.innerHTML = storyMarkup(i);
      lastScene = i;
    }
    controls();
  }
  const settle = () => {
    elapsed = durations[0] + durations[1] + 1200;
    draw();
  };
  clock = scope.timeline(
    root,
    (d) => {
      if (paused) return false;
      elapsed = (elapsed + d) % total;
      draw();
      return true;
    },
    (reduced) => {
      if (reduced) settle();
      controls();
    },
  );
  if (scope.signal.aborted) return;
  on(scope, play, 'click', () => {
    if (motion.reduced.matches) return;
    const shouldPlay = paused || !motion.allowed();
    if (shouldPlay && motion.paused) motion.setPaused(false);
    paused = !shouldPlay;
    controls();
    clock.wake({ allowFocused: true });
  });
  on(scope, document, 'home:motion', controls);
  draw();
  enableControls(root);
  controls();
}
