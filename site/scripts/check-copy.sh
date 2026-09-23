#!/usr/bin/env bash
# Fails when site copy carries AI-flavored vocabulary, emoji, or another product's name.

set -u
cd "$(dirname "$0")/.."

files=$(find src -type f \( -name '*.astro' -o -name '*.ts' -o -name '*.md' -o -name '*.css' \))
[ -z "$files" ] && { echo "OK: no copy to check."; exit 0; }

scan() {
  # shellcheck disable=SC2086
  perl -CSD -ne "print \"\$ARGV:\$.: \$_\" if ($1); close ARGV if eof" $files </dev/null
}

vocabulary=$(scan '/\b(comprehensive|powerful|seamless(ly)?|robust|cutting-edge|revolutionary|enhanced|intuitive|unleash|unlock|harness|leverag(e|ing)|empower|elevate|effortless(ly)?|supercharge|delve|game-changer|blazing|in order to|it.s worth noting)\b/i && !/check-copy-allow/')
italian=$(scan '/\b(rivoluzionari[oaie]?|all.avanguardia|senza soluzione di continuit|innovativ[oaie]|robust[oaie]|intuitiv[oaie]|potentissim[oaie]|straordinari[oaie]?|incredibil[ei]|sfrutt(a|are|ando)|al fine di|[eè] importante notare|non solo\b.*\bma anche)/i && !/check-copy-allow/')
rivals=$(scan '/\b(mac ?whisper|superwhisper|voice ?ink|wispr|open ?whispr|otter\.ai|descript)\b/i')
emoji=$(scan '/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/')

bad=0
if [ -n "$vocabulary" ]; then printf 'AI-flavored vocabulary:\n%s\n\n' "$vocabulary"; bad=1; fi
if [ -n "$italian" ]; then printf 'AI-flavored Italian:\n%s\n\n' "$italian"; bad=1; fi
if [ -n "$rivals" ]; then printf 'Another product named in the copy:\n%s\n\n' "$rivals"; bad=1; fi
if [ -n "$emoji" ]; then printf 'Emoji literals:\n%s\n\n' "$emoji"; bad=1; fi
[ "$bad" -eq 1 ] && exit 1
echo "OK: copy is clean."
