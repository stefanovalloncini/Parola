import booksFill from "@phosphor-icons/core/fill/books-fill.svg?raw";
import broomFill from "@phosphor-icons/core/fill/broom-fill.svg?raw";
import chatTeardropDotsFill from "@phosphor-icons/core/fill/chat-teardrop-dots-fill.svg?raw";
import checkBold from "@phosphor-icons/core/bold/check-bold.svg?raw";
import exportFill from "@phosphor-icons/core/fill/export-fill.svg?raw";
import eyeSlashFill from "@phosphor-icons/core/fill/eye-slash-fill.svg?raw";
import fileAudioBold from "@phosphor-icons/core/bold/file-audio-bold.svg?raw";
import fileTextBold from "@phosphor-icons/core/bold/file-text-bold.svg?raw";
import filmStripFill from "@phosphor-icons/core/fill/film-strip-fill.svg?raw";
import folderLockFill from "@phosphor-icons/core/fill/folder-lock-fill.svg?raw";
import globeSimpleBold from "@phosphor-icons/core/bold/globe-simple-bold.svg?raw";
import highlighterFill from "@phosphor-icons/core/fill/highlighter-fill.svg?raw";
import keyboardFill from "@phosphor-icons/core/fill/keyboard-fill.svg?raw";
import lightningFill from "@phosphor-icons/core/fill/lightning-fill.svg?raw";
import listChecksBold from "@phosphor-icons/core/bold/list-checks-bold.svg?raw";
import lockFill from "@phosphor-icons/core/fill/lock-fill.svg?raw";
import microphoneFill from "@phosphor-icons/core/fill/microphone-fill.svg?raw";
import microphoneSlashBold from "@phosphor-icons/core/bold/microphone-slash-bold.svg?raw";
import musicNotesFill from "@phosphor-icons/core/fill/music-notes-fill.svg?raw";
import plugsBold from "@phosphor-icons/core/bold/plugs-bold.svg?raw";
import questionFill from "@phosphor-icons/core/fill/question-fill.svg?raw";
import recordFill from "@phosphor-icons/core/fill/record-fill.svg?raw";
import sparkleFill from "@phosphor-icons/core/fill/sparkle-fill.svg?raw";
import stopFill from "@phosphor-icons/core/fill/stop-fill.svg?raw";
import terminalWindowFill from "@phosphor-icons/core/fill/terminal-window-fill.svg?raw";
import translateBold from "@phosphor-icons/core/bold/translate-bold.svg?raw";
import treeStructureFill from "@phosphor-icons/core/fill/tree-structure-fill.svg?raw";
import videoCameraFill from "@phosphor-icons/core/fill/video-camera-fill.svg?raw";
import waveformBold from "@phosphor-icons/core/bold/waveform-bold.svg?raw";
import wifiHighBold from "@phosphor-icons/core/bold/wifi-high-bold.svg?raw";
import wifiSlashBold from "@phosphor-icons/core/bold/wifi-slash-bold.svg?raw";
import { drawing } from "./svg";

const sources = {
  books: booksFill,
  broom: broomFill,
  "chat-teardrop-dots": chatTeardropDotsFill,
  check: checkBold,
  export: exportFill,
  "eye-slash": eyeSlashFill,
  "file-audio": fileAudioBold,
  "file-text": fileTextBold,
  "film-strip": filmStripFill,
  "folder-lock": folderLockFill,
  "globe-simple": globeSimpleBold,
  highlighter: highlighterFill,
  keyboard: keyboardFill,
  lightning: lightningFill,
  "list-checks": listChecksBold,
  lock: lockFill,
  microphone: microphoneFill,
  "microphone-slash": microphoneSlashBold,
  "music-notes": musicNotesFill,
  plugs: plugsBold,
  question: questionFill,
  record: recordFill,
  sparkle: sparkleFill,
  stop: stopFill,
  "terminal-window": terminalWindowFill,
  translate: translateBold,
  "tree-structure": treeStructureFill,
  "video-camera": videoCameraFill,
  waveform: waveformBold,
  "wifi-high": wifiHighBold,
  "wifi-slash": wifiSlashBold,
};

export type GlyphName = keyof typeof sources;

export function glyph(name: GlyphName): string {
  return drawing(sources[name]).body;
}

export const hues = {
  sage: { top: "#8fb08c", bottom: "#557656", accent: "#6b8a6b" },
  slate: { top: "#7f9ecb", bottom: "#48648f", accent: "#54739e" },
  clay: { top: "#cfa37a", bottom: "#946d4a", accent: "#a07b5a" },
  plum: { top: "#a699c6", bottom: "#665a87", accent: "#7b6f95" },
  rose: { top: "#d98c80", bottom: "#a5554d", accent: "#b0655c" },
  teal: { top: "#7db3aa", bottom: "#44756e", accent: "#4f8279" },
  graphite: { top: "#6b736e", bottom: "#2f3531", accent: "#4a524d" },
};

export type Hue = keyof typeof hues;

export const docTypes = {
  MP3: { glyph: "music-notes", hue: "rose" },
  M4A: { glyph: "microphone", hue: "sage" },
  WAV: { glyph: "waveform", hue: "clay" },
  MP4: { glyph: "film-strip", hue: "slate" },
  MOV: { glyph: "video-camera", hue: "plum" },
  OGG: { glyph: "chat-teardrop-dots", hue: "teal" },
} satisfies Record<string, { glyph: GlyphName; hue: Hue }>;

export type DocExt = keyof typeof docTypes;
