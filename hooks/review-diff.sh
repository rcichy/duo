#!/usr/bin/env bash
# Stop: Cursor reviews the uncommitted diff. A [BLOCKER] blocks the stop (one round, max DUO_MAX_ROUNDS per user
# request); [ESCALATE] items are handed to the user without a round. Never stages/commits.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0
cd "$DUO_ROOT" || exit 0
[ -n "$(duo_checkouts)" ] || exit 0

# A rebase, merge or cherry-pick in progress is the user's operation: its half-applied tree is not a change to review,
# and Claude may not finish it (staging is blocked while duo is on).
while IFS= read -r c; do
  g=$(git -C "$c" rev-parse --absolute-git-dir 2>/dev/null) || continue
  if [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ] || [ -f "$g/MERGE_HEAD" ] || [ -f "$g/CHERRY_PICK_HEAD" ] \
     || [ -f "$g/REVERT_HEAD" ]; then
    jq -n --arg c "$c" '{systemMessage:("duo: a rebase or merge is in progress in "+$c+"; no Cursor review until it ends")}'
    exit 0
  fi
done < <(duo_checkouts)

# An aside turn: answer the user, review nothing. The diff stays unreviewed, so the next
# ordinary turn still sends it to Cursor.
if duo_aside_consume; then
  duo_aside_record
  jq -n '{systemMessage:"duo: aside turn — skipped the Cursor review; the diff will be reviewed on the next normal turn"}'
  exit 0
fi

DIFF=$(duo_diff)
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

# Then the team guide's mechanical rules, on the added lines only. Claude fixes them before Cursor spends a call; a
# finding it keeps (with a reason) is not raised again, and Cursor sees it with the rest of the diff.
RULES=$(duo_new_code_findings)
RULES_SEEN="$DUO_STATE-rules-seen"
if [ -n "$RULES" ] && ! grep -qxF "$(printf '%s' "$RULES" | cksum)" "$RULES_SEEN" 2>/dev/null; then
  printf '%s\n' "$(printf '%s' "$RULES" | cksum)" >> "$RULES_SEEN"
  jq -n --arg f "$RULES" \
    '{decision:"block",systemMessage:"duo: new code breaks the team guide (ruff on the added lines); Claude fixes it before the Cursor review",reason:("duo: the lines you added break rules of the team guide (checked by ruff on the added lines only; not counted as a review round). Fix every one, then stop again. The code around yours not following a rule is no reason to break it: match the guide, not the old code. Only where the guide itself allows an exception (e.g. `except Exception` with a reason, a function-local import for a verified import cycle), keep the line and add `# noqa: <code>` with the reason in the same comment.\n\nFINDINGS:\n"+$f)}'
  exit 0
fi

# duo_handoff <system message> <instructions> -> blocks the stop once, so that Claude ends its turn by telling the user
# where the work stands and what they do next, instead of the turn just ending. The diff is marked reviewed before
# this is called, so the stop after the handoff goes through.
duo_handoff() {
  jq -n --arg m "$1" --arg r "$2" '{decision:"block",systemMessage:$m,reason:("duo: "+$r+"\n\nDo not change any files in this turn. Then end with a short message to the user, and stop.")}'
  exit 0
}
NEXT="the next step is the user's: review the changes, left uncommitted and unstaged (duo never stages or commits), then commit them or ask you for more changes"

ROUND=$(duo_round_status diff)
if [ "$ROUND" = cap ]; then
  echo "$HASH" > "$REVIEWED"
  duo_handoff "duo: diff review round cap reached for this request; the latest changes are not reviewed by Cursor" \
"Cursor's review rounds for this request are used up ($DUO_MAX_ROUNDS), so your latest changes were NOT reviewed by Cursor. In your message, say so plainly; list Cursor's last [BLOCKER] findings (below), each with what you did about it; name the tests you ran and their result, or say you ran none; and say that $NEXT. A new request gets fresh review rounds.

CURSOR'S LAST REVIEW:
$(cat "$DUO_STATE-diff-last-review" 2>/dev/null || echo '(not kept)')"
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
  # Claude may record a decision in the plan file after the approval (a deviation the user agreed to): without it, the
  # reviewer flags the deviation again as unexplained
  PLAN_FILE=$(cat "$DUO_PLAN_CACHE-file" 2>/dev/null)
  if [ -f "$PLAN_FILE" ] && [ "$(cat "$PLAN_FILE")" != "$(cat "$DUO_PLAN_CACHE")" ]; then
    PLANCTX+="PLAN CHANGES SINCE APPROVAL — Claude edited the plan file after the approval; these edits were not reviewed.
Treat each one as a deviation from the approved plan that Claude states: a reason it gives there, or a decision of the
user it records, counts as the stated reason.
$(diff -u <(cat "$DUO_PLAN_CACHE"; echo) <(cat "$PLAN_FILE"; echo) | tail -n +3)

"
  fi
fi
REVIEW=$(duo_review "$DUO_DIFF_MODEL" "You are a senior engineer reviewing uncommitted changes that another AI (Claude) made in
$DUO_WHERE. Read the surrounding code for context. Do NOT modify any files.
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

${PLANCTX}$(duo_aside_context)$([ -n "$RULES" ] && printf 'GUIDE CHECK — ruff findings on the added lines that Claude was asked to fix and kept; each needs a reason Claude\ngave in its reply, else it is a [BLOCKER]:\n%s\n\n' "$RULES")

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
  duo_save_review diff "$REVIEW"   # the next round sees what it escalated and Claude's answer, and does not raise it again
  jq -n --arg r "$REVIEW" \
    '{decision:"block",systemMessage:("duo: Cursor escalates decisions to you.\n"+$r),reason:("Cursor has no blocking findings but escalates decisions to the user (not counted as a round). Put each [ESCALATE] item to the user with AskUserQuestion, giving Cursor'"'"'s and your position, and act on the answers. Do NOT git add/commit/stash.\n\n"+$r)}'
  exit 0
fi
duo_handoff "duo: Cursor LGTM" \
"Cursor approved the changes (LGTM); nothing blocks them. In your message, say that Cursor approved them; name the tests you ran and their result, or say you ran none; list Cursor's non-blocking findings below ([SHOULD], [NIT]), if any, one line each with your opinion, without applying them, since the user decides; and say that $NEXT.

CURSOR'S REVIEW:
$REVIEW"
