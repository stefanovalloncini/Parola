// Mirrors AppIconArtwork.swift so the site's mark is the Dock icon, bar for bar.
export const barFractions = [0.32, 0.62, 0.84, 0.5, 0.92, 0.5, 0.84, 0.62, 0.32] as const;

const canvas = 1024;
const inset = (canvas * 100) / 1024;
const side = canvas - inset * 2;
const usableWidth = side * 0.56;
const usableHeight = side * 0.72;
const spacing = usableWidth / (barFractions.length * 2);
const barWidth = (usableWidth - spacing * (barFractions.length - 1)) / barFractions.length;
const originX = inset + (side - usableWidth) / 2;

export const brandBars = barFractions.map((fraction, index) => {
  const height = Math.max(barWidth * 1.1, usableHeight * fraction);
  return {
    x: round(originX + index * (barWidth + spacing)),
    y: round(canvas / 2 - height / 2),
    width: round(barWidth),
    height: round(height),
  };
});

function round(value: number): number {
  return Math.round(value * 100) / 100;
}
