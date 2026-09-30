#!/usr/bin/env bash
# PreToolUse(ExitPlanMode): Cursor reviews the plan. A [BLOCKER] denies ExitPlanMode (one round, max
# DUO_MAX_ROUNDS per user request); [ESCALATE] items are sent back once for the user to decide, without a round.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0

PLAN=$(jq -r '.tool_input.plan // empty' <<<"$DUO_INPUT")
if [ -z "$PLAN" ]; then
  # Resolve the plan file THIS session wrote. Never fall back to "newest plan on disk":
  # that can hand the reviewer an unrelated plan from another project or session.
  TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  if [ -f "$TRANSCRIPT" ]; then
    PLAN_FILE=$(jq -r 'select(.type=="assistant") | .message.content[]?
                       | select(.type=="tool_use") | (.input.file_path // empty)
                       | select(test("/plans/[^/]*\\.md$"))' "$TRANSCRIPT" 2>/dev/null | tail -1)
    [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] && PLAN=$(cat "$PLAN_FILE")
  fi
fi
[ -z "$PLAN" ] && exit 0

ROUND=$(duo_round_status plan)
[ "$ROUND" = cap ] && { jq -n '{systemMessage:"duo: plan review round cap reached for this request, letting plan through"}'; exit 0; }

CTX=$(duo_user_context)
HDR=$(duo_task_header)
REVIEW=$(duo_review "$DUO_PLAN_MODEL" "You are a senior engineer reviewing an implementation plan written by another AI (Claude).
The repository is the current directory. Inspect the code as needed. Do NOT modify any files.
Review THIS plan only. Other work visible in the working tree or earlier in the session is out of scope unless
this plan changes or depends on it.

$(duo_review_guide)$(duo_rubric)

Answer format. The first line is exactly one word:
APPROVE  when there is no [BLOCKER] and no [ESCALATE] finding ([SHOULD] and [NIT] may follow)
REVISE   when there is at least one [BLOCKER] or [ESCALATE] finding
Then one line per finding: [TAG] problem — concrete change to the plan.
If there is nothing to change, answer with the single word APPROVE. Never return an empty answer, and never
invent findings to fill the list.

$HDR

TASK CONTEXT — the user's messages to Claude, in order, including attachments and answers to Claude's
questions (the ground truth for what was asked; flag anything asked for that is missing or anything planned
that was not asked for):
$CTX

$(duo_aside_context)

$(duo_previous_round plan)PLAN:
$PLAN" APPROVE REVISE)

if [ -z "$REVIEW" ]; then
  PLAN_HASH=$(md5 -q -s "$PLAN" 2>/dev/null || md5sum <<<"$PLAN" | cut -d' ' -f1)
  if [ "$(cat "$DUO_STATE-plan-failed" 2>/dev/null)" = "$PLAN_HASH" ]; then
    jq -n '{systemMessage:"duo: plan not reviewed by Cursor (already reported), letting it through"}'; exit 0
  fi
  echo "$PLAN_HASH" > "$DUO_STATE-plan-failed"
  jq -n --arg e "$(duo_failure_reason)" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("duo: the Cursor plan review did not happen (no usable answer after a retry; not counted as a round). Tell the user plainly that the plan was NOT reviewed by Cursor, with this reason, then call ExitPlanMode again (it will go through).\n\nReason: "+$e)}}'
  exit 0
fi

allow() {  # $1 = reason shown to the user
  duo_reset_round plan
  printf '%s' "$PLAN" > "$DUO_PLAN_CACHE"   # the diff review checks the code against this
  jq -n --arg r "$1" '{systemMessage:$r, hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'
  exit 0
}
deny() {  # $1 = instructions for Claude
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if duo_has_tag "$REVIEW" BLOCKER; then
  N=$(duo_round_consume plan); duo_save_review plan "$REVIEW"
  deny "Cursor reviewed the plan (round $N/$DUO_MAX_ROUNDS). Fix every [BLOCKER] in the plan file, or keep the plan and explain in a \"Reviewer notes\" section why the finding is wrong. Adopt [SHOULD]/[NIT] only when they clearly help; never add machinery just to satisfy the reviewer. Put every [ESCALATE] item to the user with AskUserQuestion (both positions) and record the answer in the plan. Then call ExitPlanMode again.

$REVIEW"
fi

if duo_has_tag "$REVIEW" ESCALATE && [ ! -f "$DUO_STATE-plan-escalated" ]; then
  touch "$DUO_STATE-plan-escalated"; duo_save_review plan "$REVIEW"
  deny "Cursor has no blocking findings but escalates decisions to the user (not counted as a round). Ask the user about each [ESCALATE] item with AskUserQuestion, giving Cursor's and your position, record the answers in a \"Decisions\" section of the plan, then call ExitPlanMode again.

$REVIEW"
fi

if duo_has_tag "$REVIEW" ESCALATE; then
  allow "Cursor has no blocking findings; its escalations were already put to the user.
$REVIEW"
fi
allow "Cursor approved the plan.
$REVIEW"
