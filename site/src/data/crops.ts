type Rect = readonly [x: number, y: number, width: number, height: number];

export interface Crop {
  wide: Rect;
  narrow: Rect;
  fade?: "both";
}

const pane: Rect = [244, 50, 936, 632];

export const crops = {
  interview: { wide: pane, narrow: [256, 88, 400, 340] },
  memo: { wide: pane, narrow: [248, 96, 400, 340] },
  lecture: { wide: pane, narrow: [256, 96, 400, 340] },
  export: { wide: [214, 124, 754, 509], narrow: [560, 130, 400, 340], fade: "both" },
  "dark-speakers": { wide: pane, narrow: [256, 88, 400, 340] },
  "dark-translation": { wide: pane, narrow: [480, 140, 400, 340], fade: "both" },
  "ai-summary": { wide: pane, narrow: [248, 96, 400, 340] },
  "ai-chat": { wide: pane, narrow: [252, 96, 400, 340] },
} satisfies Record<string, Crop>;

export type TabShot = keyof typeof crops;

export const cropOf = (name: TabShot): Crop => crops[name];
