#!/usr/bin/env bash
# PreToolUse(ExitPlanMode): Cursor reviews the plan; denies ExitPlanMode until it approves (max rounds).
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0

PLAN=$(jq -r '.tool_input.plan // empty' <<<"$DUO_INPUT")
if [ -z "$PLAN" ]; then
  PLAN_FILE=$(ls -t "$DUO_PLANS"/*.md 2>/dev/null | head -1)
  [ -n "$PLAN_FILE" ] && PLAN=$(cat "$PLAN_FILE")
fi
[ -z "$PLAN" ] && exit 0

ROUND=$(duo_round plan)
[ "$ROUND" = cap ] && { jq -n '{systemMessage:"duo: plan review round cap reached, letting plan through"}'; exit 0; }

CTX=$(duo_user_context)
REVIEW=$(duo_ask "You are a senior engineer reviewing an implementation plan written by another AI (Claude).
The repository is the current directory. Inspect the code as needed. Do NOT modify any files.
Judge: correctness, missing edge cases, wrong assumptions about this codebase, scope creep, missing tests, simpler alternatives.
Respond with EXACTLY one word on the first line: APPROVE or REVISE
Then a concise bullet list of concrete, actionable changes (empty if APPROVE).

TASK CONTEXT — the user's own messages to Claude, in order (the ground truth for what was asked; judge the plan against this, and flag anything the user asked for that is missing or anything done that they did not ask for):
$CTX

PLAN:
$PLAN")

if [ -z "$REVIEW" ]; then
  jq -n '{systemMessage:"duo: Cursor returned no output (check `agent login`), letting plan through"}'; exit 0
fi

if head -1 <<<"$REVIEW" | grep -qi '^[[:space:]]*APPROVE'; then
  duo_reset_round plan
  jq -n --arg r "$REVIEW" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:("Cursor approved the plan.\n"+$r)}}'
else
  jq -n --arg r "$REVIEW" --arg n "$ROUND" --arg max "$DUO_MAX_ROUNDS" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Cursor reviewed the plan and requests changes (round "+$n+"/"+$max+"). Evaluate each point on its merits: incorporate the valid ones into the plan file; for any you disagree with, add a short \"Reviewer notes\" section to the plan explaining why. Then call ExitPlanMode again.\n\n"+$r)}}'
fi
