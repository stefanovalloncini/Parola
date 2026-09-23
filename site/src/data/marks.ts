import cerebras from "@lobehub/icons-static-svg/icons/cerebras-color.svg?raw";
import groq from "@lobehub/icons-static-svg/icons/groq.svg?raw";
import openai from "@lobehub/icons-static-svg/icons/openai.svg?raw";
import sparkle from "@phosphor-icons/core/fill/sparkle-fill.svg?raw";
import anthropic from "simple-icons/icons/anthropic.svg?raw";
import ollama from "simple-icons/icons/ollama.svg?raw";
import webex from "simple-icons/icons/webex.svg?raw";
import zoom from "simple-icons/icons/zoom.svg?raw";
import { drawing, type Drawing } from "./svg";

export interface Mark extends Drawing {
  background: string;
  color: string;
  scale: number;
}

function mark(svg: string, background: string, color: string, scale = 0.55): Mark {
  return { ...drawing(svg), background, color, scale };
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
};

export type MarkName = keyof typeof marks;
