const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Types `data-text` into a target word by word each time the device enters `scene`. */
export function typeOnScene(root: HTMLElement, scene: string): void {
  const device = root.closest<HTMLElement>("[data-device]");
  const target = root.querySelector<HTMLElement>("[data-typed]");
  const partial = root.querySelector<HTMLElement>("[data-partial]");
  if (!device || !target) return;

  const words = (target.dataset.text ?? "").split(" ");
  let timer = 0;

  const render = (count: number) => {
    target.textContent = words.slice(0, count).join(" ");
    if (partial) partial.textContent = words.slice(Math.max(0, count - 5), count).join(" ");
  };

  const start = () => {
    window.clearTimeout(timer);
    if (reduceMotion()) {
      render(words.length);
      return;
    }
    let count = 0;
    render(0);
    const step = () => {
      count += 1;
      render(count);
      if (count < words.length) timer = window.setTimeout(step, 150 + Math.random() * 90);
    };
    timer = window.setTimeout(step, 550);
  };

  render(words.length);
  device.addEventListener("scenechange", (event) => {
    if ((event as CustomEvent<number>).detail === Number(scene)) start();
  });
}
