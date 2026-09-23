export interface Drawing {
  viewBox: string;
  fillRule: "evenodd" | undefined;
  body: string;
}

export function drawing(svg: string): Drawing {
  const source = svg.trim();
  const root = /^<svg([^>]*)>/.exec(source)?.[1] ?? "";
  return {
    viewBox: /viewBox="([^"]+)"/.exec(root)?.[1] ?? "0 0 24 24",
    fillRule: root.includes('fill-rule="evenodd"') ? "evenodd" : undefined,
    body: source.replace(/^<svg[^>]*>|<\/svg>$/g, "").replace(/<title>.*?<\/title>/, ""),
  };
}
