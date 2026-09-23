import type { Locale } from "../i18n";

interface FileProp {
  ext: string;
  name: Record<Locale, string>;
  tint: string;
  x: number;
  y: number;
  r: number;
}

const files: FileProp[] = [
  {
    ext: "M4A",
    name: { en: "Interview.m4a", it: "Intervista.m4a" },
    tint: "#6b8a6b",
    x: 9,
    y: 16,
    r: -8,
  },
  {
    ext: "MP4",
    name: { en: "Lecture 4.mp4", it: "Lezione 4.mp4" },
    tint: "#54739e",
    x: 13,
    y: 45,
    r: 6,
  },
  {
    ext: "WAV",
    name: { en: "Standup.wav", it: "Riunione.wav" },
    tint: "#a07b5a",
    x: 8,
    y: 72,
    r: -4,
  },
  {
    ext: "MOV",
    name: { en: "Keynote.mov", it: "Presentazione.mov" },
    tint: "#7b6f95",
    x: 13,
    y: 96,
    r: 8,
  },
  {
    ext: "MP3",
    name: { en: "Episode 31.mp3", it: "Puntata 31.mp3" },
    tint: "#3f6048",
    x: 91,
    y: 14,
    r: 7,
  },
  {
    ext: "M4A",
    name: { en: "Memo 12 Sept.m4a", it: "Memo 12 set.m4a" },
    tint: "#6b8a6b",
    x: 87,
    y: 42,
    r: -6,
  },
  {
    ext: "MP4",
    name: { en: "Workshop.mp4", it: "Laboratorio.mp4" },
    tint: "#54739e",
    x: 92,
    y: 70,
    r: 5,
  },
  {
    ext: "OGG",
    name: { en: "Voice note.ogg", it: "Nota vocale.ogg" },
    tint: "#a07b5a",
    x: 87,
    y: 95,
    r: -8,
  },
];

const people = [
  { initials: { en: "M", it: "G" }, hue: "#6b8a6b", x: 9, y: 20 },
  { initials: { en: "T", it: "L" }, hue: "#54739e", x: 13, y: 55 },
  { initials: { en: "A", it: "S" }, hue: "#a07b5a", x: 8, y: 88 },
  { initials: { en: "S", it: "M" }, hue: "#7b6f95", x: 91, y: 18 },
  { initials: { en: "J", it: "E" }, hue: "#3f6048", x: 87, y: 52 },
  { initials: { en: "R", it: "F" }, hue: "#54739e", x: 92, y: 86 },
];

export function propsFor(locale: Locale) {
  return {
    files: files.map((file) => ({ ...file, name: file.name[locale] })),
    people: people.map((person) => ({ ...person, initials: person.initials[locale] })),
  };
}
