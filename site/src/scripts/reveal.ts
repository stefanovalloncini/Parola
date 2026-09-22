const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

function wrapWords(root: HTMLElement): void {
  let index = 0;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes: Text[] = [];
  while (walker.nextNode()) nodes.push(walker.currentNode as Text);
  for (const node of nodes) {
    const parts = (node.textContent ?? "").split(/(\s+)/);
    const fragment = document.createDocumentFragment();
    for (const part of parts) {
      if (part.trim() === "") {
        fragment.append(part);
        continue;
      }
      const word = document.createElement("span");
      word.className = "word";
      word.style.setProperty("--i", String(index++));
      word.textContent = part;
      fragment.append(word);
    }
    node.replaceWith(fragment);
  }
}

/** Headlines marked `data-words` ink in word by word the first time they scroll into view. */
export function revealWords(): void {
  if (reduceMotion.matches) return;
  const headlines = [...document.querySelectorAll<HTMLElement>("[data-words]")];
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.remove("is-waiting");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -18% 0px" },
  );
  for (const headline of headlines) {
    wrapWords(headline);
    headline.classList.add("is-waiting");
    observer.observe(headline);
  }
}

/** Elements marked `data-loop` get `data-playing` while on screen, so their CSS scenes run only when seen. */
export function playWhenVisible(): void {
  const scenes = document.querySelectorAll<HTMLElement>("[data-loop]");
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        entry.target.toggleAttribute("data-playing", entry.isIntersecting && !reduceMotion.matches);
        if (entry.isIntersecting) entry.target.setAttribute("data-seen", "");
      }
    },
    { threshold: 0.3 },
  );
  scenes.forEach((scene) => observer.observe(scene));
}
