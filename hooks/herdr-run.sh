#!/usr/bin/env bash
# Runs one Cursor review inside a herdr pane (DUO_USE_HERDR=1, started by duo_ask_herdr in common.sh).
# Shows what the reviewer reads and says while it works, then hands the answer back to the waiting hook:
#   <state>-herdr-out  the review text (the assistant messages, one per line block)
#   <state>-stderr     Cursor's stderr, same file the direct call uses
#   <state>-herdr-rc   exit code, written last: its appearance tells the hook the run is over
# Usage: herdr-run.sh <state-prefix> <model> <repo-root> <timeout-seconds> <label>
set -uo pipefail
state="$1" model="$2" root="$3" secs="$4" label="$5"
stream="$state-herdr-stream.jsonl"
limit=()
for t in timeout gtimeout; do command -v "$t" >/dev/null 2>&1 && { limit=("$t" "$secs"); break; }; done

printf '\n\033[1m── duo: %s · %s · %s\033[0m\n' "$label" "$model" "$(date '+%H:%M:%S')"
cd "$root" || { echo 1 > "$state-herdr-rc"; exit 1; }

# stream-json gives tool calls and messages as they happen; the display filter must never die mid-run
# (a broken pipe would kill the reviewer), hence fromjson? and try.
${limit[@]+"${limit[@]}"} agent -p --trust --mode ask --model "$model" --output-format stream-json \
    "$(cat "$state-herdr-prompt")" 2>"$state-stderr" \
  | tee "$stream" \
  | jq -Rrj --unbuffered 'fromjson? | try (
      if .type == "tool_call" and .subtype == "started" then
        .tool_call | to_entries[] | select(.key | endswith("ToolCall"))
        | "  \u001b[2m→ \(.key | sub("ToolCall$"; "")) \(.value.args | (.path // .pattern // .command // .globPattern // tostring) | tostring | .[0:160])\u001b[0m\n"
      elif .type == "assistant" then
        "\n" + ([.message.content[]? | select(.type == "text") | .text] | join("")) + "\n"
      elif .type == "result" then
        "\u001b[2m── done in \(.duration_ms / 1000 | floor)s\u001b[0m\n"
      else empty end) catch empty'
rc=${PIPESTATUS[0]}
[ "$rc" = 124 ] && printf '\033[31m── timed out after %ss\033[0m\n' "$secs"
[ -s "$state-stderr" ] && { printf '\033[31m'; head -c 600 "$state-stderr"; printf '\033[0m\n'; }

# Messages joined by newlines, so a verdict sent as its own message stays on its own line
# (the final "result" event glues all messages together without separators).
jq -Rrs 'split("\n") | map(fromjson? // empty)
         | [.[] | select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | join("")]
         | join("\n")' "$stream" > "$state-herdr-out" 2>/dev/null
echo "$rc" > "$state-herdr-rc.tmp" && mv "$state-herdr-rc.tmp" "$state-herdr-rc"
