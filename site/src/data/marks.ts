import cerebras from "@lobehub/icons-static-svg/icons/cerebras-color.svg?raw";
import groq from "@lobehub/icons-static-svg/icons/groq.svg?raw";
import openai from "@lobehub/icons-static-svg/icons/openai.svg?raw";
import sparkle from "@phosphor-icons/core/fill/sparkle-fill.svg?raw";
import anthropic from "simple-icons/icons/anthropic.svg?raw";
import claude from "simple-icons/icons/claude.svg?raw";
import ollama from "simple-icons/icons/ollama.svg?raw";
import soundcloud from "simple-icons/icons/soundcloud.svg?raw";
import tiktok from "simple-icons/icons/tiktok.svg?raw";
import vimeo from "simple-icons/icons/vimeo.svg?raw";
import webex from "simple-icons/icons/webex.svg?raw";
import x from "simple-icons/icons/x.svg?raw";
import youtube from "simple-icons/icons/youtube.svg?raw";
import zoom from "simple-icons/icons/zoom.svg?raw";
import { drawing, type Drawing } from "./svg";

export interface Mark extends Drawing {
  background: string;
  color: string;
  scale: number;
  edge: boolean;
}

function mark(svg: string, background: string, color: string, scale = 0.55): Mark {
  return { ...drawing(svg), background, color, scale, edge: background === "#000" };
}

const intelligence = sparkle.replace(
  "<path",
  '<defs><linearGradient id="intelligence" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff9f43"/><stop offset=".35" stop-color="#f5577f"/><stop offset=".65" stop-color="#a45cf0"/><stop offset="1" stop-color="#3d8bff"/></linearGradient></defs><path fill="url(#intelligence)"',
);

export const marks = {
  intelligence: mark(intelligence, "#fff", "#fff", 0.6),
  ollama: mark(ollama, "#fff", "#000"),
  openai: mark(openai, "#000", "#fff"),
  anthropic: mark(anthropic, "#f0eee6", "#191919"),
  groq: mark(groq, "#f55036", "#fff"),
  cerebras: mark(cerebras, "#fff", "#1a1a1a", 0.6),
  zoom: mark(zoom, "#0b5cff", "#fff", 0.74),
  webex: mark(webex, "#000", "#fff"),
  youtube: mark(youtube, "#fff", "#ff0000", 0.6),
  vimeo: mark(vimeo, "#1ab7ea", "#fff"),
  soundcloud: mark(soundcloud, "#ff5500", "#fff", 0.6),
  x: mark(x, "#000", "#fff", 0.5),
  tiktok: mark(tiktok, "#000", "#fff"),
  claude: mark(claude, "#d97757", "#fff", 0.6),
};

export type MarkName = keyof typeof marks;
