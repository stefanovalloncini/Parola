import type { IconName } from "../components/Icon.astro";

export interface IncludedGroup {
  title: string;
  icon: IconName;
  items: string[];
}

const english: IncludedGroup[] = [
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

const italian: IncludedGroup[] = [
  {
    title: "Trascrizione",
    icon: "wave",
    items: [
      "File audio e video, uno alla volta o un'intera cartella",
      "Link da YouTube, Vimeo, SoundCloud e altri siti",
      "Una coda batch e cartelle monitorate",
      "Nomi di chi parla e tempi delle parole",
      "Traduzione, affiancata al testo",
    ],
  },
  {
    title: "Registrazione",
    icon: "speaker",
    items: [
      "Il microfono o qualsiasi suono del Mac",
      "Un invito a registrare quando apri Zoom, Teams o Webex",
      "Sottotitoli in tempo reale in un pannello sempre in primo piano",
    ],
  },
  {
    title: "Dettatura",
    icon: "bubble",
    items: [
      "Dettatura in qualsiasi app, con il tasto che scegli",
      "Stili per messaggi, email, note e codice",
      "Correzioni e snippet che si applicano mentre parli",
    ],
  },
  {
    title: "Esportazione",
    icon: "stack",
    items: [
      "Tredici formati con anteprima",
      "Sottotitoli impressi in una copia del video",
      "Note scritte direttamente in una cartella di Obsidian",
    ],
  },
  {
    title: "AI",
    icon: "sparkle",
    items: [
      "Riassunti, capitoli e chat",
      "Diciannove prompt, più i tuoi",
      "Apple Intelligence, Ollama o la tua chiave",
    ],
  },
  {
    title: "Automazione",
    icon: "terminal",
    items: [
      "Azioni per Comandi Rapidi e lo schema URL parola://",
      "Lo strumento da riga di comando parola",
      "Un server MCP per Claude e altri LLM",
    ],
  },
  {
    title: "Libreria",
    icon: "search",
    items: [
      "Ricerca in tutte le trascrizioni",
      "Righe preferite, elementi fissati ed etichette",
      "Eliminati di recente conserva le trascrizioni per 30 giorni",
    ],
  },
];

export const included = { en: english, it: italian };
