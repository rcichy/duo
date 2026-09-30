#!/usr/bin/env bash
# PreToolUse(ExitPlanMode): Cursor reviews the plan; denies ExitPlanMode until it approves (max rounds).
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

ROUND=$(duo_round plan)
[ "$ROUND" = cap ] && { jq -n '{systemMessage:"duo: plan review round cap reached, letting plan through"}'; exit 0; }

CTX=$(duo_user_context)
HDR=$(duo_task_header)
REVIEW=$(duo_ask "$DUO_PLAN_MODEL" "You are a senior engineer reviewing an implementation plan written by another AI (Claude).
The repository is the current directory. Inspect the code as needed. Do NOT modify any files.
Judge: correctness, missing edge cases, wrong assumptions about this codebase, scope creep, missing tests, simpler alternatives.
Respond with EXACTLY one word on the first line: APPROVE or REVISE
Then a concise bullet list of concrete, actionable changes (empty if APPROVE).

$HDR

TASK CONTEXT — the user's own messages to Claude, in order (the ground truth for what was asked; judge the plan against this, and flag anything the user asked for that is missing or anything done that they did not ask for):
$CTX

PLAN:
$PLAN")

if [ -z "$REVIEW" ]; then
  jq -n --arg e "$(duo_why_empty)" '{systemMessage:("duo: no plan review — proceeding without it. Cursor said: "+$e)}'; exit 0
fi

if head -1 <<<"$REVIEW" | grep -qi '^[[:space:]]*APPROVE'; then
  duo_reset_round plan
  printf '%s' "$PLAN" > "$DUO_PLAN_CACHE"   # the diff review checks the code against this
  jq -n --arg r "$REVIEW" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:("Cursor approved the plan.\n"+$r)}}'
else
  jq -n --arg r "$REVIEW" --arg n "$ROUND" --arg max "$DUO_MAX_ROUNDS" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Cursor reviewed the plan and requests changes (round "+$n+"/"+$max+"). Evaluate each point on its merits: incorporate the valid ones into the plan file; for any you disagree with, add a short \"Reviewer notes\" section to the plan explaining why. Then call ExitPlanMode again.\n\n"+$r)}}'
fi
