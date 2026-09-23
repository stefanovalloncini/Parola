const whisperKit = "https://github.com/argmaxinc/WhisperKit";

export interface Credit {
  before: string;
  mark: string;
  after: string;
  name: string;
  href?: string;
}

export const credits: Record<"en" | "it", Credit[]> = {
  en: [
    {
      before: "Runs OpenAI's Whisper as",
      mark: "Core ML models on Apple Silicon",
      after: ".",
      name: "WhisperKit, by Argmax",
      href: whisperKit,
    },
    {
      before: "Tells the voices in a recorded file",
      mark: "apart",
      after: ", so each line gets a speaker.",
      name: "SpeakerKit, by Argmax",
      href: whisperKit,
    },
    {
      before: "Runs NVIDIA's Parakeet and the live speaker labels",
      mark: "on the Neural Engine",
      after: ".",
      name: "FluidAudio",
      href: "https://github.com/FluidInference/FluidAudio",
    },
    {
      before: "The",
      mark: "speech engine built into macOS 26",
      after: ", so there's nothing to download.",
      name: "Speech framework, by Apple",
    },
    {
      before: "Summaries, chapters and titles,",
      mark: "written on your Mac",
      after: ".",
      name: "Apple Intelligence",
    },
    {
      before: "Fetches the audio behind",
      mark: "a link you paste",
      after: ", from YouTube and many other sites.",
      name: "yt-dlp",
      href: "https://github.com/yt-dlp/yt-dlp",
    },
    {
      before: "Translates a finished transcript",
      mark: "on device",
      after: ", into the languages your Mac offers.",
      name: "Translation framework, by Apple",
    },
  ],
  it: [
    {
      before: "Esegue Whisper di OpenAI come",
      mark: "modelli Core ML su Apple Silicon",
      after: ".",
      name: "WhisperKit, di Argmax",
      href: whisperKit,
    },
    {
      before: "Distingue",
      mark: "le voci",
      after: " di un file registrato, così ogni riga ha il suo autore.",
      name: "SpeakerKit, di Argmax",
      href: whisperKit,
    },
    {
      before: "Esegue Parakeet di NVIDIA e le etichette dei parlanti in diretta",
      mark: "sul Neural Engine",
      after: ".",
      name: "FluidAudio",
      href: "https://github.com/FluidInference/FluidAudio",
    },
    {
      before: "Il",
      mark: "motore vocale integrato in macOS 26",
      after: ", quindi non c'è niente da scaricare.",
      name: "Framework Speech, di Apple",
    },
    {
      before: "Riassunti, capitoli e titoli,",
      mark: "scritti sul tuo Mac",
      after: ".",
      name: "Apple Intelligence",
    },
    {
      before: "Scarica l'audio che sta dietro",
      mark: "un link che incolli",
      after: ", da YouTube e da molti altri siti.",
      name: "yt-dlp",
      href: "https://github.com/yt-dlp/yt-dlp",
    },
    {
      before: "Traduce una trascrizione finita",
      mark: "sul dispositivo",
      after: ", nelle lingue che il tuo Mac mette a disposizione.",
      name: "Framework Translation, di Apple",
    },
  ],
};

export const openWork = {
  en: {
    title: "Built on open work.",
    lead: "The pieces under Parola are open source or part of macOS.",
    sourceBefore: "Parola itself is MIT licensed.",
    sourceMark: "Read every line",
    sourceAfter: ", change what you like.",
    button: "View the source on GitHub",
  },
  it: {
    title: "Costruito sull'open source.",
    lead: "Tutto quello che c'è sotto Parola è open source o fa parte di macOS.",
    sourceBefore: "Anche Parola ha licenza MIT.",
    sourceMark: "Leggi ogni riga",
    sourceAfter: ", cambia quello che vuoi.",
    button: "Vedi il codice su GitHub",
  },
};
