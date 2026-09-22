export function watchStory(): void {
  const story = document.querySelector<HTMLElement>("[data-story]");
  const device = story?.querySelector<HTMLElement>("[data-device]");
  const header = document.querySelector<HTMLElement>("[data-header]");
  if (!story || !device) return;

  const beats = [...story.querySelectorAll<HTMLElement>("[data-beat]")];
  let scene = -1;
  let queued = false;

  const visibleIn = (beat: HTMLElement, top: number, bottom: number) => {
    const box = beat.getBoundingClientRect();
    return Math.max(0, Math.min(box.bottom, bottom) - Math.max(box.top, top));
  };

  const update = () => {
    queued = false;
    const top = header?.getBoundingClientRect().bottom ?? 0;
    const bottom = device.getBoundingClientRect().top;
    let next = 0;
    let best = -1;
    beats.forEach((beat, index) => {
      const seen = visibleIn(beat, top, bottom);
      if (seen > 0 && seen >= best) {
        best = seen;
        next = index;
      }
    });
    if (best <= 0) next = scene < 0 ? 0 : scene;
    if (next === scene) return;
    scene = next;
    device.dataset.scene = String(next);
    device.dispatchEvent(new CustomEvent("scenechange", { detail: next }));
    beats.forEach((beat, index) => {
      beat.toggleAttribute("data-current", index === next);
      if (index <= next) beat.setAttribute("data-seen", "");
    });
  };

  const request = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };

  update();
  window.addEventListener("scroll", request, { passive: true });
  window.addEventListener("resize", request);
}
