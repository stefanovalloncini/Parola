import type { GlyphName, Hue } from "./icons";

export interface IncludedGroup {
  title: string;
  glyph: GlyphName;
  hue: Hue;
  items: string[];
}

const english: IncludedGroup[] = [
  {
    title: "Transcription",
    glyph: "waveform",
    hue: "sage",
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
    glyph: "microphone",
    hue: "rose",
    items: [
      "The microphone or anything your Mac plays",
      "A recording prompt when Zoom, Teams or Webex opens",
      "A timer that ends a recording on its own",
      "Live captions in a panel that stays on top",
    ],
  },
  {
    title: "Dictation",
    glyph: "keyboard",
    hue: "slate",
    items: [
      "Dictation into any app, on a key you choose",
      "Styles for messages, email, notes and code",
      "Corrections and snippets that apply as you speak",
    ],
  },
  {
    title: "Export",
    glyph: "export",
    hue: "clay",
    items: [
      "Thirteen formats with a live preview",
      "Captions burned into a copy of the video",
      "Notes written straight into an Obsidian folder",
    ],
  },
  {
    title: "AI",
    glyph: "sparkle",
    hue: "plum",
    items: [
      "Summaries, chapters and chat",
      "Nineteen prompts, plus your own",
      "Apple Intelligence, Ollama or your own key",
    ],
  },
  {
    title: "Automation",
    glyph: "terminal-window",
    hue: "graphite",
    items: [
      "Shortcuts actions and a parola:// URL scheme",
      "The parola command-line tool",
      "An MCP server for Claude and other LLMs",
    ],
  },
  {
    title: "Library",
    glyph: "books",
    hue: "teal",
    items: [
      "Search across every transcript",
      "Edit any line, and fix a name everywhere with find and replace",
      "Favorite lines, pins and labels",
      "Recently Deleted keeps transcripts for 30 days",
    ],
  },
];

const italian: IncludedGroup[] = [
  {
    title: "Trascrizione",
    glyph: "waveform",
    hue: "sage",
    items: [
      "File audio e video, uno alla volta o un’intera cartella",
      "Link da YouTube, Vimeo, SoundCloud e altri siti",
      "Una coda batch e cartelle monitorate",
      "Nomi di chi parla e timestamp di ogni parola",
      "Traduzione affiancata al testo",
    ],
  },
  {
    title: "Registrazione",
    glyph: "microphone",
    hue: "rose",
    items: [
      "Il microfono o qualsiasi audio riprodotto dal Mac",
      "Un invito a registrare quando apri Zoom, Teams o Webex",
      "Un timer che ferma la registrazione da solo",
      "Sottotitoli in tempo reale in un pannello sempre in primo piano",
    ],
  },
  {
    title: "Dettatura",
    glyph: "keyboard",
    hue: "slate",
    items: [
      "Dettatura in qualsiasi app, con il tasto che scegli",
      "Stili per messaggi, email, note e codice",
      "Correzioni e snippet che si applicano mentre parli",
    ],
  },
  {
    title: "Esportazione",
    glyph: "export",
    hue: "clay",
    items: [
      "Tredici formati con anteprima",
      "Sottotitoli impressi in una copia del video",
      "Note scritte direttamente in una cartella di Obsidian",
    ],
  },
  {
    title: "AI",
    glyph: "sparkle",
    hue: "plum",
    items: [
      "Riassunti, capitoli e chat",
      "Diciannove prompt, più i tuoi",
      "Apple Intelligence, Ollama o la tua chiave",
    ],
  },
  {
    title: "Automazione",
    glyph: "terminal-window",
    hue: "graphite",
    items: [
      "Azioni per Comandi Rapidi e lo schema URL parola://",
      "Lo strumento a riga di comando parola",
      "Un server MCP per Claude e altri LLM",
    ],
  },
  {
    title: "Libreria",
    glyph: "books",
    hue: "teal",
    items: [
      "Ricerca in tutte le trascrizioni",
      "Modifica qualsiasi riga e correggi un nome ovunque con Trova e sostituisci",
      "Righe preferite, trascrizioni fissate in alto ed etichette",
      "Eliminati di recente conserva le trascrizioni per 30 giorni",
    ],
  },
];

export const included = { en: english, it: italian };
