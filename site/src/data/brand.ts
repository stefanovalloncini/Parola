// Mirrors AppIconArtwork.swift so the site's mark is the Dock icon, bar for bar.
export const barFractions = [0.32, 0.62, 0.84, 0.5, 0.92, 0.5, 0.84, 0.62, 0.32] as const;

export type Mark = "pennino" | "waveform";

const canvas = 1024;
const center = canvas / 2;
const inset = (canvas * 100) / 1024;
const side = canvas - inset * 2;
const usableWidth = side * 0.56;
const usableHeight = side * 0.72;
const spacing = usableWidth / (barFractions.length * 2);
const barWidth = (usableWidth - spacing * (barFractions.length - 1)) / barFractions.length;
const centerIndex = Math.floor(barFractions.length / 2);
const nibWidth = barWidth * 4;

function centerOffset(index: number, mark: Mark): number {
  const steps = Math.abs(index - centerIndex);
  if (steps === 0) return 0;
  const centerWidth = mark === "pennino" ? nibWidth : barWidth;
  const offset = centerWidth / 2 + spacing + barWidth / 2 + (steps - 1) * (barWidth + spacing);
  return index < centerIndex ? -offset : offset;
}

export function brandBars(mark: Mark) {
  return barFractions.flatMap((fraction, index) => {
    if (mark === "pennino" && index === centerIndex) return [];
    const height = Math.max(barWidth * 1.1, usableHeight * fraction);
    return [
      {
        x: round(center + centerOffset(index, mark) - barWidth / 2),
        y: round(center - height / 2),
        width: round(barWidth),
        height: round(height),
      },
    ];
  });
}

export const nib = (() => {
  const top = center - usableHeight * 0.465;
  const height = usableHeight * 0.955;
  const half = nibWidth / 2;
  const lower = half - nibWidth * 0.086;
  const corner = nibWidth * 0.155;
  const at = (x: number, y: number) => `${round(center + x)} ${round(top + y)}`;
  const along = (x: number, fraction: number) => at(x, height * fraction);
  const holeY = top + height * 0.42;
  const slit = nibWidth * 0.086;
  return {
    outline: [
      `M${at(-half + corner, 0)}`,
      `L${at(half - corner, 0)}`,
      `Q${at(half, 0)} ${at(half, corner)}`,
      `L${along(half, 0.23)}`,
      `C${along(half, 0.3)} ${along(lower, 0.3)} ${along(lower, 0.353)}`,
      `C${along(lower, 0.644)} ${along(lower * 0.18, 0.922)} ${along(0, 1)}`,
      `C${along(-lower * 0.18, 0.922)} ${along(-lower, 0.644)} ${along(-lower, 0.353)}`,
      `C${along(-lower, 0.3)} ${along(-half, 0.3)} ${along(-half, 0.23)}`,
      `L${at(-half, corner)}`,
      `Q${at(-half, 0)} ${at(-half + corner, 0)}`,
      "Z",
    ].join(""),
    hole: { cx: round(center), cy: round(holeY), r: round(nibWidth * 0.15) },
    slit: {
      x: round(center - slit / 2),
      y: round(holeY),
      width: round(slit),
      height: round(top + height - holeY + slit),
    },
  };
})();

function round(value: number): number {
  return Math.round(value * 100) / 100;
}
