import type { Locale } from "../../i18n";
import { english } from "./en";
import { italian } from "./it";

type Part = string | { href: string; label: string };
export type Block = { text: Part[] } | { code: string };

export interface Question {
  question: string;
  answer: Block[];
}

export const faq: Record<Locale, Question[]> = { en: english, it: italian };
