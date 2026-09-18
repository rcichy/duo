#!/usr/bin/env bash
# Stop: Cursor reviews the uncommitted diff; blocks stop until LGTM (max rounds). Never stages/commits.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0
cd "$DUO_ROOT" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

DIFF=$(git diff)
while IFS= read -r f; do
  [ -n "$f" ] && DIFF+=$'\n'"$(git diff --no-index /dev/null "$f" 2>/dev/null)"
done < <(git ls-files --others --exclude-standard)
[ -z "$(tr -d '[:space:]' <<<"$DIFF")" ] && exit 0

HASH=$(md5 -q -s "$DIFF" 2>/dev/null || md5sum <<<"$DIFF" | cut -d' ' -f1)
REVIEWED="$DUO_STATE-diff-reviewed"
[ -f "$REVIEWED" ] && [ "$(cat "$REVIEWED")" = "$HASH" ] && exit 0

ROUND=$(duo_round diff)
if [ "$ROUND" = cap ]; then
  echo "$HASH" > "$REVIEWED"
  jq -n '{systemMessage:"duo: diff review round cap reached, stopping with changes unstaged"}'; exit 0
fi

CTX=$(duo_user_context)
REVIEW=$(duo_ask "You are reviewing uncommitted changes made by another AI (Claude) in the current repository.
Read surrounding code for context. Do NOT modify any files.
Look for: bugs, unhandled errors, broken contracts with callers, missing or weak tests, security issues, needless complexity.
Ignore style nits unless they hide a bug.
Respond with EXACTLY one word on the first line: LGTM or CHANGES
Then a concise bullet list: file:line — problem — suggested fix.

TASK CONTEXT — the user's own messages to Claude, in order (the ground truth for what was asked; judge the diff against this, and flag anything the user asked for that is missing or anything done that they did not ask for):
$CTX

DIFF:
$DIFF")

if [ -z "$REVIEW" ]; then
  jq -n '{systemMessage:"duo: Cursor returned no output (check `agent login`), stopping"}'; exit 0
fi

if head -1 <<<"$REVIEW" | grep -qi '^[[:space:]]*LGTM'; then
  echo "$HASH" > "$REVIEWED"; duo_reset_round diff
  jq -n --arg r "$REVIEW" '{systemMessage:("duo: Cursor LGTM. Changes left unstaged for your review.\n"+$r)}'
  exit 0
fi

jq -n --arg r "$REVIEW" --arg n "$ROUND" --arg max "$DUO_MAX_ROUNDS" \
  '{decision:"block",reason:("Cursor code review (round "+$n+"/"+$max+"). For each point: verify it against the actual code before acting. Fix what is real; for anything you disagree with, state why briefly and skip it. Do NOT git add/commit/stash. When done, summarize what you accepted vs rejected and stop again.\n\n"+$r)}'
