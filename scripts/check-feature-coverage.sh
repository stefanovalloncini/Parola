#!/usr/bin/env bash
# Check that every interactive UI element has an .axLeaf identifier,
# every .axLeaf identifier is documented in docs/agent-coverage.md, and
# every command referenced from that doc exists in the catalog.
#
# Default mode is strict: fails (exit 1) on any violation.
# --soft prints warnings and always exits 0. Use during the rollout
# while the .axLeaf sweep is still landing.
set -euo pipefail

SOFT=false
for arg in "$@"; do
    case "$arg" in
        --soft) SOFT=true ;;
        -h|--help)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VIEWS_DIR="ParolaApp/ParolaApp/Views"
COMMANDS_DIR="ParolaApp/ParolaApp/Bridge/Commands"
COVERAGE_DOC="docs/agent-coverage.md"

FAILED=false

report() {
    local message="$1"
    if $SOFT; then
        printf 'WARN: %s\n' "$message"
    else
        printf 'ERROR: %s\n' "$message"
        FAILED=true
    fi
}

INTERACTIVE_REGEX='^[[:space:]]*(Button|MenuItem|Toggle|TextField|Picker|Slider|Menu)\('

if [ ! -d "$VIEWS_DIR" ]; then
    report "views directory not found: $VIEWS_DIR"
else
    interactive_files=$(grep -rlE "$INTERACTIVE_REGEX" "$VIEWS_DIR" --include='*.swift' || true)
    missing_leaf=""
    for file in $interactive_files; do
        buttons=$(grep -cE "$INTERACTIVE_REGEX" "$file" || true)
        leaves=$(grep -c '\.axLeaf(' "$file" || true)
        if [ "$buttons" -gt "$leaves" ]; then
            missing_leaf+="  $file ($buttons interactive, $leaves leaves)"$'\n'
        fi
    done
    if [ -n "$missing_leaf" ]; then
        report "interactive elements without matching .axLeaf:"$'\n'"$missing_leaf"
    fi
fi

if [ ! -f "$COVERAGE_DOC" ]; then
    report "coverage doc missing: $COVERAGE_DOC"
    declared=""
else
    declared=$(grep -rh '\.axLeaf(' "$VIEWS_DIR" --include='*.swift' 2>/dev/null \
        | sed -E 's/.*axLeaf\("([^"]+)"\).*/\1/' \
        | sort -u || true)
    documented=$(grep -E '^\| [A-Z][a-zA-Z]+\.' "$COVERAGE_DOC" \
        | awk -F'|' '{print $2}' \
        | tr -d ' ' \
        | sort -u || true)

    if [ -n "$declared" ]; then
        missing_doc=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$documented") || true)
        if [ -n "$missing_doc" ]; then
            report "axLeaf ids without a row in $COVERAGE_DOC:"$'\n'"$(printf '  %s\n' $missing_doc)"
        fi
    fi
fi

if [ -f "$COVERAGE_DOC" ] && [ -d "$COMMANDS_DIR" ]; then
    referenced_commands=$(grep -E '^\| [A-Z][a-zA-Z]+\.' "$COVERAGE_DOC" \
        | awk -F'|' '{print $3}' \
        | sed -E 's/\([^)]*\)//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' \
        | sort -u || true)
    declared_commands=$(grep -rh 'AutomationCommand(' "$COMMANDS_DIR" --include='*.swift' -A1 2>/dev/null \
        | grep -E 'name: "[^"]+"' \
        | sed -E 's/.*name: "([^"]+)".*/\1/' \
        | sort -u || true)

    if [ -n "$referenced_commands" ]; then
        missing_cmd=$(comm -23 <(printf '%s\n' "$referenced_commands") <(printf '%s\n' "$declared_commands") || true)
        if [ -n "$missing_cmd" ]; then
            report "commands referenced from $COVERAGE_DOC but missing in catalog:"$'\n'"$(printf '  %s\n' $missing_cmd)"
        fi
    fi
fi

if $FAILED; then
    exit 1
fi

echo "Feature coverage check passed."
