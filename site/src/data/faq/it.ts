import { cli, links, requirements } from "../links";
import type { Question } from ".";

export const italian: Question[] = [
  {
    question: "Di cosa ha bisogno Parola?",
    answer: [
      {
        text: [
          `${requirements.it}. Per riassunti e titoli sul dispositivo serve anche Apple Intelligence attiva.`,
        ],
      },
    ],
  },
  {
    question: "È davvero gratis?",
    answer: [
      {
        text: [
          "Sì. Parola è open source con ",
          { href: links.license, label: "licenza MIT" },
          " e ogni funzione è inclusa nel download. Non c’è niente da comprare e nessun account da creare.",
        ],
      },
    ],
  },
  {
    question: "Il mio audio esce dal Mac?",
    answer: [
      {
        text: [
          "No. La trascrizione avviene sul tuo Mac. Parola va online solo per scaricare un modello, recuperare l’audio di un link che incolli o collegarsi a un servizio AI che aggiungi tu. Un servizio AI riceve il testo, mai l’audio, e Parola chiede conferma la prima volta.",
        ],
      },
    ],
  },
  {
    question: "Funziona offline?",
    answer: [
      {
        text: [
          "Sì. Una volta che un modello è sul tuo Mac, la trascrizione non ha bisogno della rete. Apple Speech non richiede alcun download da Parola, anche se macOS può scaricare i file delle lingue.",
        ],
      },
    ],
  },
  {
    question: "Quale motore conviene usare?",
    answer: [
      {
        text: [
          "Inizia con Apple Speech, che è pronto subito. Whisper Large v3 Turbo è più preciso e si scarica una volta sola (1,6 GB). Parakeet v3 è il motore multilingue più veloce e copre 25 lingue europee.",
        ],
      },
    ],
  },
  {
    question: "Quali lingue supporta?",
    answer: [
      {
        text: [
          "Nell’app puoi scegliere una delle 13 lingue o lasciare che Parola la riconosca. Parakeet v3 copre 25 lingue europee e la riga di comando accetta qualsiasi codice di lingua che Whisper conosce.",
        ],
      },
    ],
  },
  {
    question: "Come funzionano i link?",
    answer: [
      {
        text: [
          "Parola usa yt-dlp per scaricare l’audio, poi lo trascrive sul tuo Mac. Se yt-dlp non è installato, Parola propone di installarlo con Homebrew.",
        ],
      },
    ],
  },
  {
    question: "Come ricevo gli aggiornamenti?",
    answer: [
      {
        text: [
          "Le nuove versioni escono sulla ",
          { href: links.releases, label: "pagina Releases" },
          " di GitHub.",
        ],
      },
    ],
  },
  {
    question: "La mia azienda può distribuirlo?",
    answer: [
      {
        text: [
          "Sì. Parola legge una configurazione gestita, così l’IT può impostare il modello predefinito, limitare i motori e disattivare la dettatura, l’AI nel cloud, i download dei modelli o altre funzioni. La ",
          { href: links.deploymentDocs, label: "guida alla distribuzione" },
          " (in inglese) elenca tutte le chiavi.",
        ],
      },
    ],
  },
  {
    question: "Claude o un altro LLM possono usarlo?",
    answer: [
      {
        text: [
          "Sì. Parola include un server MCP. Aggiungilo a Claude Code e chiedi quello che ti serve con parole tue:",
        ],
      },
      { code: `claude mcp add parola -- ${cli} mcp` },
      {
        text: [
          "La ",
          { href: links.mcpDocs, label: "guida MCP" },
          " (in inglese) spiega come configurare Claude Desktop e gli altri client.",
        ],
      },
    ],
  },
  {
    question: "Qualcosa non va. Come lo segnalo?",
    answer: [
      { text: ["Esegui questo comando nel Terminale:"] },
      { code: `${cli} diagnostics` },
      {
        text: [
          "Il rapporto non contiene il testo delle trascrizioni, nomi di file o percorsi, e puoi leggerlo prima di allegarlo a una ",
          { href: links.issues, label: "segnalazione su GitHub" },
          ".",
        ],
      },
    ],
  },
];
