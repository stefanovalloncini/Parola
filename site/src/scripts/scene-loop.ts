const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

type Step = [at: number, state: string];

interface Scene {
  root: HTMLElement;
  steps: Step[];
  duration: number;
  still: string;
  timers: number[];
}

function typeWords(target: HTMLElement, from: number, until: number, scene: Scene): void {
  const words = (target.dataset.text ?? "").split(" ");
  const span = Math.max(until - from, 1);
  target.textContent = "";
  words.forEach((_, index) => {
    const at = from + (span * (index + 1)) / words.length;
    scene.timers.push(
      window.setTimeout(() => {
        target.textContent = words.slice(0, index + 1).join(" ");
      }, at),
    );
  });
}

function play(scene: Scene): void {
  stop(scene);
  scene.steps.forEach(([at, state], index) => {
    scene.timers.push(
      window.setTimeout(() => {
        scene.root.dataset.state = state;
      }, at),
    );
    const next = scene.steps[index + 1]?.[0] ?? scene.duration;
    scene.root.querySelectorAll<HTMLElement>(`[data-type="${state}"]`).forEach((target) => {
      typeWords(target, at, next - 120, scene);
    });
  });
  scene.timers.push(window.setTimeout(() => play(scene), scene.duration));
}

function stop(scene: Scene): void {
  scene.timers.forEach((timer) => window.clearTimeout(timer));
  scene.timers = [];
}

function showStill(scene: Scene): void {
  stop(scene);
  scene.root.dataset.state = scene.still;
  scene.root.querySelectorAll<HTMLElement>("[data-type]").forEach((target) => {
    target.textContent = target.dataset.text ?? "";
  });
}

/** Runs `[data-scene-loop]` state machines while they're on screen; reduced motion shows the still. */
export function runSceneLoops(): void {
  const scenes: Scene[] = [...document.querySelectorAll<HTMLElement>("[data-scene-loop]")].map(
    (root) => ({
      root,
      steps: JSON.parse(root.dataset.sceneLoop ?? "[]") as Step[],
      duration: Number(root.dataset.duration ?? 8000),
      still: root.dataset.still ?? "",
      timers: [],
    }),
  );
  const byRoot = new Map(scenes.map((scene) => [scene.root, scene]));
  scenes.forEach(showStill);
  if (reduceMotion.matches) return;

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const scene = byRoot.get(entry.target as HTMLElement);
        if (!scene) continue;
        if (entry.isIntersecting) play(scene);
        else showStill(scene);
      }
    },
    { threshold: 0.35 },
  );
  scenes.forEach((scene) => observer.observe(scene.root));
}
