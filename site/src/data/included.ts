import type { IconName } from "../components/Icon.astro";

export interface IncludedGroup {
  title: string;
  icon: IconName;
  items: string[];
}

export const included: IncludedGroup[] = [
  {
    title: "Transcription",
    icon: "wave",
    items: [
      "Audio and video files, one at a time or a whole folder",
      "Links from YouTube, Vimeo, SoundCloud and more",
      "A batch queue and watched folders",
      "Speaker labels and word timings",
      "Translation, shown side by side",
    ],
  },
  {
    title: "Recording",
    icon: "speaker",
    items: [
      "The microphone or anything your Mac plays",
      "A recording prompt when Zoom, Teams or Webex opens",
      "Live captions in a panel that stays on top",
    ],
  },
  {
    title: "Dictation",
    icon: "bubble",
    items: [
      "Dictation into any app, on a key you choose",
      "Styles for messages, email, notes and code",
      "Corrections and snippets that apply as you speak",
    ],
  },
  {
    title: "Export",
    icon: "stack",
    items: [
      "Thirteen formats with a live preview",
      "Captions burned into a copy of the video",
      "Notes written straight into an Obsidian folder",
    ],
  },
  {
    title: "AI",
    icon: "sparkle",
    items: [
      "Summaries, chapters and chat",
      "Nineteen prompts, plus your own",
      "Apple Intelligence, Ollama or your own key",
    ],
  },
  {
    title: "Automation",
    icon: "terminal",
    items: [
      "Shortcuts actions and a parola:// URL scheme",
      "The parola command-line tool",
      "An MCP server for Claude and other LLMs",
    ],
  },
  {
    title: "Library",
    icon: "search",
    items: [
      "Search across every transcript",
      "Favorite lines, pins and labels",
      "Recently Deleted keeps transcripts for 30 days",
    ],
  },
];
