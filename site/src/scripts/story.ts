export function watchStory(): void {
  const story = document.querySelector<HTMLElement>("[data-story]");
  const device = story?.querySelector<HTMLElement>("[data-device]");
  const header = document.querySelector<HTMLElement>("[data-header]");
  if (!story || !device) return;

  const beats = [...story.querySelectorAll<HTMLElement>("[data-beat]")];
  let scene = -1;
  let queued = false;

  const visibleIn = (box: DOMRect, top: number, bottom: number) =>
    Math.max(0, Math.min(box.bottom, bottom) - Math.max(box.top, top));

  const pick = (top: number, bottom: number) => {
    let next = -1;
    let best = 0;
    beats.forEach((beat, index) => {
      const seen = visibleIn(beat.getBoundingClientRect(), top, bottom);
      if (seen > 0 && seen >= best) {
        best = seen;
        next = index;
      }
    });
    if (next >= 0) return next;
    const last = beats.at(-1)?.getBoundingClientRect();
    return last && last.bottom < top ? beats.length - 1 : 0;
  };

  const update = () => {
    queued = false;
    const top = header?.getBoundingClientRect().bottom ?? 0;
    const next = pick(top, device.getBoundingClientRect().top);
    if (next === scene) return;
    scene = next;
    device.dataset.scene = String(next);
    device.dispatchEvent(new CustomEvent("scenechange", { detail: next }));
    beats.forEach((beat, index) => {
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
  new IntersectionObserver(([entry]) => {
    story.toggleAttribute("data-active", entry?.isIntersecting ?? false);
  }).observe(story);
}
