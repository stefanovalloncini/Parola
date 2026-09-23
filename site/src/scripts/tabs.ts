const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

/** ARIA tabs that advance on their own while on screen, until the visitor picks one. */
export function watchTabs(root: HTMLElement): void {
  const tabs = [...root.querySelectorAll<HTMLButtonElement>("[data-tab]")];
  const panels = [...root.querySelectorAll<HTMLElement>("[data-panel]")];
  const dwell = parseFloat(getComputedStyle(root).getPropertyValue("--dwell")) * 1000 || 6000;
  let current = 0;
  let timer = 0;
  let chosen = false;
  let held = false;
  let onScreen = false;
  let remaining = dwell;
  let dueAt = 0;
  let advances = 0;

  const select = (index: number, focus = false) => {
    current = (index + tabs.length) % tabs.length;
    tabs.forEach((tab, i) => {
      const selected = i === current;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      panels[i]?.toggleAttribute("hidden", !selected);
    });
    if (focus) tabs[current]?.focus();
    schedule();
  };

  const arm = () => {
    window.clearTimeout(timer);
    const playing = onScreen && !chosen && !reduceMotion.matches;
    root.toggleAttribute("data-playing", playing);
    root.toggleAttribute("data-held", playing && held);
    if (!playing || held) return;
    dueAt = performance.now() + remaining;
    timer = window.setTimeout(() => {
      advances += 1;
      if (advances >= tabs.length) chosen = true;
      select(current + 1);
    }, remaining);
  };

  const schedule = () => {
    remaining = dwell;
    arm();
  };

  const choose = (index: number, focus = false) => {
    chosen = true;
    select(index, focus);
  };

  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => choose(i));
    tab.addEventListener("keydown", (event) => {
      const moves: Record<string, number> = { ArrowRight: 1, ArrowLeft: -1 };
      if (event.key in moves) {
        event.preventDefault();
        choose(i + (moves[event.key] ?? 0), true);
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault();
        choose(event.key === "Home" ? 0 : tabs.length - 1, true);
      }
    });
  });

  root.addEventListener("focusin", () => {
    chosen = true;
    arm();
  });
  root.addEventListener("pointerenter", () => {
    if (held) return;
    held = true;
    remaining = Math.max(dueAt - performance.now(), 0);
    arm();
  });
  root.addEventListener("pointerleave", () => {
    held = false;
    arm();
  });

  new IntersectionObserver(
    ([entry]) => {
      const visible = entry?.isIntersecting ?? false;
      if (visible === onScreen) return;
      onScreen = visible;
      if (visible) select(current);
      else arm();
    },
    { threshold: 0.35 },
  ).observe(root);
}
