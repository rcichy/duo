#!/usr/bin/env bash
# Stop: Cursor reviews the uncommitted diff. A [BLOCKER] blocks the stop (one round, max DUO_MAX_ROUNDS per user
# request); [ESCALATE] items are handed to the user without a round. Never stages/commits.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0
cd "$DUO_ROOT" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# An aside turn: answer the user, review nothing. The diff stays unreviewed, so the next
# ordinary turn still sends it to Cursor.
if duo_aside_consume; then
  duo_aside_record
  jq -n '{systemMessage:"duo: aside turn — skipped the Cursor review; the diff will be reviewed on the next normal turn"}'
  exit 0
fi

DIFF=$(git diff)
while IFS= read -r f; do
  [ -n "$f" ] && DIFF+=$'\n'"$(git diff --no-index /dev/null "$f" 2>/dev/null)"
done < <(git ls-files --others --exclude-standard)
[ -z "$(tr -d '[:space:]' <<<"$DIFF")" ] && exit 0

HASH=$(md5 -q -s "$DIFF" 2>/dev/null || md5sum <<<"$DIFF" | cut -d' ' -f1)
REVIEWED="$DUO_STATE-diff-reviewed"
[ -f "$REVIEWED" ] && [ "$(cat "$REVIEWED")" = "$HASH" ] && exit 0
FAILED="$DUO_STATE-diff-failed"
[ -f "$FAILED" ] && [ "$(cat "$FAILED")" = "$HASH" ] && exit 0   # already reported to the user, don't loop

# Prose first, before Cursor spends a call: it reviews the polished text, not a draft.
if duo_prose_skill_available; then
  PROSE=$(duo_prose_pending)
  if [ -n "$PROSE" ]; then
    duo_prose_mark_done "$PROSE"
    jq -n --arg f "$PROSE" --arg s "$DUO_PROSE_SKILL" \
      '{decision:"block",reason:("duo: this change includes non-code text (not counted as a review round). Use the "+$s+" skill on the prose YOU wrote or rewrote in the files below, and edit them in place.\n- Keep the author'"'"'s voice, and keep any wording the user asked for verbatim.\n- Leave code, code comments, identifiers, command examples and output samples alone.\n- Do not restructure or expand sections the user did not ask you to change; the goal is sharper text, not more text.\nThen stop again.\n\nFILES:\n"+$f)}'
    exit 0
  fi
fi

ROUND=$(duo_round_status diff)
if [ "$ROUND" = cap ]; then
  echo "$HASH" > "$REVIEWED"
  jq -n '{systemMessage:"duo: diff review round cap reached for this request, stopping with changes unstaged"}'; exit 0
fi

CTX=$(duo_user_context)
HDR=$(duo_task_header)
PLANCTX=""
if [ -s "$DUO_PLAN_CACHE" ]; then
  PLANCTX="APPROVED PLAN — the plan for this task, already reviewed and approved, including the requirements it quotes.
Check the diff against it: flag anything built differently without a stated reason, and anything in the plan left
unimplemented.
$(cat "$DUO_PLAN_CACHE")

"
fi
REVIEW=$(duo_review "$DUO_DIFF_MODEL" "You are a senior engineer reviewing uncommitted changes that another AI (Claude) made in the current
repository. Read the surrounding code for context. Do NOT modify any files.
Judge the diff against the most recent request and the approved plan; earlier, finished work in the session is
out of scope unless this diff touches it.

$(duo_review_guide)$(duo_rubric)

Answer format. The first line is exactly one word:
LGTM     when there is no [BLOCKER] and no [ESCALATE] finding ([SHOULD] and [NIT] may follow)
CHANGES  when there is at least one [BLOCKER] or [ESCALATE] finding
Then one line per finding: [TAG] file:line — problem — suggested fix.
If there is nothing to change, answer with the single word LGTM. Never return an empty answer, and never invent
findings to fill the list.

$HDR

TASK CONTEXT — the user's messages to Claude, in order, including attachments and answers to Claude's
questions (the ground truth for what was asked; flag anything asked for that is missing or anything done that
was not asked for):
$CTX

${PLANCTX}$(duo_aside_context)

$(duo_previous_round diff)DIFF:
$DIFF" LGTM CHANGES)

if [ -z "$REVIEW" ]; then
  echo "$HASH" > "$FAILED"
  jq -n --arg e "$(duo_failure_reason)" \
    '{decision:"block",systemMessage:("duo: Cursor gave no usable diff review after a retry. "+$e),reason:("duo: the Cursor diff review did not happen (no usable answer after a retry; not counted as a round). Tell the user plainly in your final message that this diff was NOT reviewed by Cursor, with this reason, then stop.\n\nReason: "+$e)}'
  exit 0
fi

if duo_has_tag "$REVIEW" BLOCKER; then
  N=$(duo_round_consume diff); duo_save_review diff "$REVIEW"
  jq -n --arg r "$REVIEW" --arg n "$N" --arg max "$DUO_MAX_ROUNDS" \
    '{decision:"block",reason:("Cursor code review (round "+$n+"/"+$max+"). Verify every finding against the actual code. Fix each real [BLOCKER]; for one you disagree with, say why in one line. Take [SHOULD]/[NIT] only when they clearly help; never add machinery just to satisfy the reviewer. Put every [ESCALATE] item to the user (AskUserQuestion, both positions) instead of deciding it yourself. Do NOT git add/commit/stash. When done, summarize what you accepted and rejected, then stop again.\n\n"+$r)}'
  exit 0
fi

echo "$HASH" > "$REVIEWED"; duo_reset_round diff
if duo_has_tag "$REVIEW" ESCALATE; then
  jq -n --arg r "$REVIEW" \
    '{decision:"block",systemMessage:("duo: Cursor escalates decisions to you.\n"+$r),reason:("Cursor has no blocking findings but escalates decisions to the user (not counted as a round). Put each [ESCALATE] item to the user with AskUserQuestion, giving Cursor'"'"'s and your position, and act on the answers. Do NOT git add/commit/stash.\n\n"+$r)}'
  exit 0
fi
jq -n --arg r "$REVIEW" '{systemMessage:("duo: Cursor LGTM. Changes left unstaged for your review.\n"+$r)}'
