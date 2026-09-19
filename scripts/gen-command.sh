#!/usr/bin/env bash
# Scaffold an AutomationCommand and append it to the matching area file under
# ParolaApp/ParolaApp/Bridge/Commands/<Area>Commands.swift.
#
# Usage:
#   scripts/gen-command.sh --name <NAME> --area <AREA> [--args <spec> ...] [--dry-run]
#
# AREA is one of the cases on AutomationCommand.Area:
#   core | model | transcript | library | batch | recording |
#   dictation | prompt | settings | window | test | lifecycle
#
# Each --args spec is:
#   <name>:<kind>:<required>:<summary>
# where <kind> is one of:
#   string | boolean | integer | double | stringArray | object | any
# For a string enum use:
#   <name>:string:enum:a|b|c:<required>:<summary>
# <required> is "true" or "false".
#
# Examples:
#   scripts/gen-command.sh --name pingTest --area core
#   scripts/gen-command.sh --name setLevel --area settings \
#       --args level:string:enum:info|warning|error:true:"Threshold level"
#   scripts/gen-command.sh --name renameEntry --area library \
#       --args id:string:true:"Entry identifier" \
#       --args title:string:false:"New title"
#
# With --dry-run, prints the generated AutomationCommand to stdout without
# touching any file.
set -euo pipefail

NAME=""
AREA=""
ARGS=()
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --name)
            NAME="$2"
            shift 2
            ;;
        --area)
            AREA="$2"
            shift 2
            ;;
        --args)
            ARGS+=("$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$NAME" ] || [ -z "$AREA" ]; then
    echo "ERROR: --name and --area are required." >&2
    echo "Run with --help for usage." >&2
    exit 2
fi

VALID_AREAS="core model transcript library batch recording dictation prompt settings window test lifecycle"
case " $VALID_AREAS " in
    *" $AREA "*) ;;
    *)
        echo "ERROR: unknown area '$AREA'. Must be one of: $VALID_AREAS" >&2
        exit 2
        ;;
esac

area_to_filename() {
    local area="$1"
    local first
    first=$(printf '%s' "${area:0:1}" | tr '[:lower:]' '[:upper:]')
    printf '%s%sCommands.swift' "$first" "${area:1}"
}

format_arg_kind() {
    local kind="$1"
    case "$kind" in
        string) printf '.string()' ;;
        boolean) printf '.boolean' ;;
        integer) printf '.integer' ;;
        double) printf '.double' ;;
        stringArray) printf '.stringArray' ;;
        object) printf '.object' ;;
        any) printf '.any' ;;
        *)
            echo "ERROR: unknown arg kind '$kind'. Must be: string|boolean|integer|double|stringArray|object|any" >&2
            exit 2
            ;;
    esac
}

format_string_enum() {
    local raw_values="$1"
    local IFS='|'
    read -r -a vals <<< "$raw_values"
    local out=".string(enum: ["
    local first=true
    for v in "${vals[@]}"; do
        if $first; then
            first=false
        else
            out+=", "
        fi
        out+="\"$v\""
    done
    out+="])"
    printf '%s' "$out"
}

parse_arg_spec() {
    local spec="$1"
    local IFS=':'
    read -r -a parts <<< "$spec"

    local arg_name kind_swift required summary
    arg_name="${parts[0]:-}"
    if [ -z "$arg_name" ]; then
        echo "ERROR: arg spec missing name: '$spec'" >&2
        exit 2
    fi

    if [ "${parts[1]:-}" = "string" ] && [ "${parts[2]:-}" = "enum" ]; then
        kind_swift=$(format_string_enum "${parts[3]:-}")
        required="${parts[4]:-false}"
        summary="${parts[5]:-}"
    else
        kind_swift=$(format_arg_kind "${parts[1]:-}")
        required="${parts[2]:-false}"
        summary="${parts[3]:-}"
    fi

    case "$required" in
        true|false) ;;
        *)
            echo "ERROR: required field must be 'true' or 'false', got '$required' in '$spec'" >&2
            exit 2
            ;;
    esac

    printf '%s\t%s\t%s\t%s\n' "$arg_name" "$kind_swift" "$required" "$summary"
}

build_args_block() {
    if [ "${#ARGS[@]}" -eq 0 ]; then
        return 0
    fi
    printf '                args: [\n'
    local i=0
    for spec in "${ARGS[@]}"; do
        local parsed
        parsed=$(parse_arg_spec "$spec")
        local arg_name kind_swift required summary
        IFS=$'\t' read -r arg_name kind_swift required summary <<< "$parsed"
        printf '                    .init(name: "%s", kind: %s, required: %s, summary: "%s"),\n' \
            "$arg_name" "$kind_swift" "$required" "$summary"
        i=$((i+1))
    done
    printf '                ],\n'
}

build_command_block() {
    local args_block
    args_block=$(build_args_block || true)

    printf '\n'
    printf '            AutomationCommand(\n'
    printf '                name: "%s",\n' "$NAME"
    printf '                area: .%s,\n' "$AREA"
    printf '                summary: "TODO: describe %s.",\n' "$NAME"
    printf '                kind: .mutating,\n'
    if [ -n "$args_block" ]; then
        printf '%s\n' "$args_block"
    fi
    printf '                handler: { args, ctx in\n'
    printf '                    // TODO: implement %s on AppModel and call it here.\n' "$NAME"
    printf '                    _ = args\n'
    printf '                    _ = ctx\n'
    printf '                    return .object(["ok": .bool(true)])\n'
    printf '                }\n'
    printf '            ),\n'
}

BLOCK=$(build_command_block)

if $DRY_RUN; then
    printf '%s' "$BLOCK"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE_NAME=$(area_to_filename "$AREA")
TARGET="$REPO_ROOT/ParolaApp/ParolaApp/Bridge/Commands/$FILE_NAME"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

if grep -q "name: \"$NAME\"" "$TARGET"; then
    echo "ERROR: a command named '$NAME' already exists in $FILE_NAME." >&2
    exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

CLOSING_LINE=$(awk '/^        \]$/ {print NR; exit}' "$TARGET")
if [ -z "$CLOSING_LINE" ]; then
    echo "ERROR: could not find the closing ']' of the command array in $FILE_NAME." >&2
    exit 1
fi

head -n $((CLOSING_LINE - 1)) "$TARGET" > "$TMP"
# Command substitution ate the block's trailing newline; without it the closing ']' lands on the
# same line as the new command and the next run can no longer find it.
printf '%s\n' "$BLOCK" >> "$TMP"
tail -n +"$CLOSING_LINE" "$TARGET" >> "$TMP"

mv "$TMP" "$TARGET"
trap - EXIT

echo "Appended '$NAME' to $FILE_NAME."
echo "Open $TARGET and fill in the TODO."
