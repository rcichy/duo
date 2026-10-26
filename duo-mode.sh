#!/usr/bin/env bash
# Switch the duo loop on or off for one slot: the git checkout containing <dir> (see hooks/slot.sh).
# Usage: duo-mode.sh on|off|aside|status|marker [dir]
#   dir defaults to the session's project dir (CLAUDE_PROJECT_DIR), else the current directory
#   status  lists the slots where duo is on;  marker  prints the slot's on-switch path (for the status line)
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/hooks/slot.sh"

home="${DUO_HOME:-$(jq -r '.env.DUO_HOME // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
[ -n "$home" ] || { echo "duo: DUO_HOME is not set — run install.sh <folder>"; exit 1; }
cmd="${1:-status}"
root=$(duo_slot_root "${2:-${CLAUDE_PROJECT_DIR:-$PWD}}" "$home")
slot="${root#"$home"/}"

if [ "$cmd" = status ]; then
  on=$(ls "$home/.claude/duo.on.d" 2>/dev/null | sed 's/__/\//g')
  echo "duo is on in: ${on:-(no slot)}" | tr '\n' ' '; echo
  exit 0
fi

on=$(duo_slot_file "$home" "$root" duo.on) \
  || { [ "$cmd" = marker ] && exit 1; echo "duo: $root is not under DUO_HOME ($home); the hooks will not fire here"; exit 0; }

case "$cmd" in
  on)     mkdir -p "${on%/*}" && touch "$on" && echo "duo mode: ON for slot $slot" ;;
  off)    if [ -f "$on" ]; then rm -f "$on" && echo "duo mode: OFF for slot $slot"
          else echo "duo mode: was not on for slot $slot (on in: $(ls "$home/.claude/duo.on.d" 2>/dev/null | sed 's/__/\//g' | tr '\n' ' '))"; fi ;;
  aside)  f=$(duo_slot_file "$home" "$root" duo-aside); mkdir -p "${f%/*}" && : > "$f" \
            && echo "duo: aside - this turn is not sent to Cursor" ;;
  marker) printf '%s\n' "$on" ;;
  *)      echo "usage: duo-mode.sh on|off|aside|status|marker [dir]"; exit 2 ;;
esac
