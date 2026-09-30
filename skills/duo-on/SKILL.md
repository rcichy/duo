---
name: duo-on
description: Turn ON the Claude+Cursor duo review loop for repos under $DUO_HOME (Cursor reviews plans and diffs via hooks). Use when the user says "duo on", "enable duo", or wants Cursor to review this work.
---

!`H="${DUO_HOME:-$(jq -r ".env.DUO_HOME // empty" "$HOME/.claude/settings.json")}"; [ -n "$H" ] || { echo "duo: DUO_HOME is not set — run install.sh <folder>"; exit 0; }; mkdir -p "$H/.claude" && touch "$H/.claude/duo.on" && echo "duo mode: ON (marker $H/.claude/duo.on)"`

Duo mode is now ON for any session whose cwd is under `$DUO_HOME`. Confirm this to the user in one line, then follow these rules for the rest of the session (or until `/duo-off`):

1. **Plan first.** For any non-trivial code change, enter plan mode (EnterPlanMode) and write the plan to the plan file before implementing. The plan starts with:
   - **Requirements (verbatim)**: the ticket title, description, acceptance criteria and definition of done, copied word for word. Transcribe screenshots or images the user sent into text here; Cursor cannot see images.
   - **Deviations from the ticket**: every place the plan does something other than the ticket asks or suggests, with the reason.

   When you call ExitPlanMode, a hook sends the plan to Cursor for review. The diff review later receives the approved plan, so it checks the code against these requirements too.
2. **Handle review findings by tag.** Cursor tags each finding:
   - `[BLOCKER]`: verify it against the code; fix it, or reject it with a one-line reason (plan: a "Reviewer notes" section). Only blockers consume one of the `DUO_MAX_ROUNDS` rounds.
   - `[SHOULD]` / `[NIT]`: take them only when they clearly help. Never add machinery just to satisfy the reviewer; rejecting with a reason is fine.
   - `[ESCALATE]`: a decision for the user. Ask the user with AskUserQuestion, giving Cursor's and your position; do not decide it yourself.

   Implement, then stop as normal: a Stop hook sends the uncommitted diff to Cursor and blocks the stop on blockers or escalations. Your final summary after a round is passed to the next round, so state clearly what you fixed and why you rejected the rest.
3. **Polish prose as part of implementing.** After the code is done and the tests pass, and before you stop, run the `no-ai-slop` skill over the non-code text you wrote or changed (docs, README, other `.md`/`.txt`/`.rst`). Edit in place: keep the author's voice and any wording the user gave verbatim, leave code, code comments, identifiers, commands and output samples alone, and do not expand sections nobody asked about. Do this before you stop; if you forget, the Stop hook blocks once and asks for it, before any Cursor call and without costing a review round.
4. **Asides.** A message starting with `/btw` (or `btw`) is a side question: answer it, do not implement, and expect no Cursor review that turn. The working diff stays unreviewed and goes to Cursor on the next normal turn.
5. **Never stage or commit.** `git add`/`commit`/`stash`/`push`/`reset`/`restore` are blocked by hook while duo is on. Leave everything unstaged for the user.
6. When you finish, summarize what Cursor raised, what you accepted vs rejected, and what the user decided on escalations.

If the current cwd is not under `$DUO_HOME`, tell the user the hooks will not fire here.
