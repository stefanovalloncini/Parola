const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

const levelLagPerBar = 0.05;
const previewRest = 1.6;

/** Plays the app's demo clip: words light up on their timestamps and the brand bars follow the level envelope. */
export function watchKaraoke(root: HTMLElement): void {
  const audio = root.querySelector<HTMLAudioElement>("audio");
  const button = root.querySelector<HTMLButtonElement>("[data-play]");
  const words = [...root.querySelectorAll<HTMLElement>("[data-s]")].map((el) => ({
    el,
    start: Number(el.dataset.s),
    end: Number(el.dataset.e),
  }));
  const bars = [...root.querySelectorAll<HTMLElement>("[data-bar]")];
  const levels = JSON.parse(root.dataset.levels ?? "[]") as number[];
  const rate = Number(root.dataset.rate ?? 20);
  const duration = Number(root.dataset.duration ?? 0);
  if (!audio || !button || words.length === 0) return;

  let onScreen = false;
  let frame = 0;
  let previewStart = performance.now();

  const level = (time: number) => (time < 0 ? 0 : (levels[Math.floor(time * rate)] ?? 0));

  const paint = (time: number) => {
    for (const word of words) {
      word.el.classList.toggle("is-spoken", time >= word.end);
      word.el.classList.toggle("is-current", time >= word.start && time < word.end);
    }
    const centre = (bars.length - 1) / 2;
    const resting = time >= duration;
    bars.forEach((bar, index) => {
      const lag = Math.abs(index - centre) * levelLagPerBar;
      const value = resting ? 1 : Math.min(Math.max(level(time - lag), 0), 1);
      bar.style.transform = `scaleY(${0.35 + 0.65 * value})`;
    });
  };

  const tick = () => {
    frame = 0;
    const playing = !audio.paused && !audio.ended;
    if (playing) {
      paint(audio.currentTime);
    } else if (onScreen && !reduceMotion.matches) {
      const elapsed = (performance.now() - previewStart) / 1000;
      const loop = duration + previewRest;
      paint(elapsed % loop);
    }
    if (playing || (onScreen && !reduceMotion.matches)) frame = requestAnimationFrame(tick);
  };

  const run = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  const setPlaying = (playing: boolean) => {
    root.toggleAttribute("data-audible", playing);
    button.setAttribute("aria-pressed", String(playing));
    const label = button.querySelector("[data-label]");
    if (label) label.textContent = playing ? "Pause" : "Play with sound";
  };

  button.addEventListener("click", () => {
    if (audio.paused) {
      if (audio.ended || audio.currentTime >= duration) audio.currentTime = 0;
      void audio.play();
    } else {
      audio.pause();
    }
  });
  audio.addEventListener("play", () => {
    setPlaying(true);
    run();
  });
  audio.addEventListener("pause", () => {
    setPlaying(false);
    previewStart = performance.now() - audio.currentTime * 1000;
    run();
  });
  audio.addEventListener("ended", () => {
    setPlaying(false);
    paint(duration);
  });

  paint(reduceMotion.matches ? duration : 0);
  new IntersectionObserver(([entry]) => {
    onScreen = entry?.isIntersecting ?? false;
    if (onScreen) {
      previewStart = performance.now();
      run();
    } else if (!audio.paused) {
      audio.pause();
    }
  }).observe(root);
}
