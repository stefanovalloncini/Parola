import { cli, links, requirements } from "../links";
import type { Question } from ".";

export const english: Question[] = [
  {
    question: "What does Parola need?",
    answer: [
      {
        text: [
          `${requirements.en}. Summaries and titles on device also need Apple Intelligence turned on.`,
        ],
      },
    ],
  },
  {
    question: "Is it really free?",
    answer: [
      {
        text: [
          "Yes. Parola is open source under the ",
          { href: links.license, label: "MIT license" },
          ", and every feature is in the download. There’s nothing to buy and no account to make.",
        ],
      },
    ],
  },
  {
    question: "Does my audio leave my Mac?",
    answer: [
      {
        text: [
          "No. Transcription runs on your Mac. Parola goes online only to download a model, fetch a link you paste, or reach an AI service you add yourself. An AI service gets text, never audio, and Parola asks before the first time.",
        ],
      },
    ],
  },
  {
    question: "Does it work offline?",
    answer: [
      {
        text: [
          "Yes. Once a model is on your Mac, transcription needs no connection. Apple Speech needs no download from Parola at all, though macOS may fetch its language files.",
        ],
      },
    ],
  },
  {
    question: "Which engine should I use?",
    answer: [
      {
        text: [
          "Start with Apple Speech, which is ready straight away. Whisper Large v3 Turbo is more accurate and downloads 1.6 GB once. Parakeet v3 is the fastest multilingual engine and covers 25 European languages.",
        ],
      },
    ],
  },
  {
    question: "Which languages does it support?",
    answer: [
      {
        text: [
          "In the app you can pick one of 13 languages or let Parola detect it. Parakeet v3 covers 25 European languages, and the command line takes any language code Whisper understands.",
        ],
      },
    ],
  },
  {
    question: "How do links work?",
    answer: [
      {
        text: [
          "Parola uses yt-dlp to download the audio, then transcribes it on your Mac. If yt-dlp isn’t installed, Parola offers to install it with Homebrew.",
        ],
      },
    ],
  },
  {
    question: "How do I get updates?",
    answer: [
      {
        text: [
          "New versions are published on the ",
          { href: links.releases, label: "Releases page" },
          " on GitHub.",
        ],
      },
    ],
  },
  {
    question: "Can my company deploy it?",
    answer: [
      {
        text: [
          "Yes. Parola reads a managed configuration, so IT can set the default model, limit the engines, and turn off dictation, cloud AI, model downloads or other features. The ",
          { href: links.deploymentDocs, label: "deployment guide" },
          " lists every key.",
        ],
      },
    ],
  },
  {
    question: "Can Claude or another LLM use it?",
    answer: [
      {
        text: [
          "Yes. Parola includes an MCP server. Add it to Claude Code, then ask in plain words:",
        ],
      },
      { code: `claude mcp add parola -- ${cli} mcp` },
      {
        text: [
          "The ",
          { href: links.mcpDocs, label: "MCP guide" },
          " covers Claude Desktop and other clients.",
        ],
      },
    ],
  },
  {
    question: "Something went wrong. How do I report it?",
    answer: [
      { text: ["Run this in Terminal:"] },
      { code: `${cli} diagnostics` },
      {
        text: [
          "The report holds no transcript text, file names or paths, so you can read it before you attach it to an ",
          { href: links.issues, label: "issue on GitHub" },
          ".",
        ],
      },
    ],
  },
];
