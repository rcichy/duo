---
name: duo-on
description: Turn ON the Claude+Cursor duo review loop for the current slot (the git checkout of this session, under $DUO_HOME); Cursor reviews plans and diffs via hooks. Use when the user says "duo on", "enable duo", or wants Cursor to review this work.
---

!`"$HOME/.config/ai/duo/duo-mode.sh" on`

Duo mode is now ON for this slot: the git checkout this session was started in. Other slots (for example other clones of the same repo) are not affected. Confirm this to the user in one line, then follow these rules for the rest of the session (or until `/duo-off`):

1. **Plan first.** For any non-trivial code change, enter plan mode (EnterPlanMode) and write the plan to the plan file before implementing. The plan starts with:
   - **Requirements (verbatim)**: the ticket title, description, acceptance criteria and definition of done, copied word for word. Transcribe screenshots or images the user sent into text here; Cursor cannot see images.
   - **Deviations from the ticket**: every place the plan does something other than the ticket asks or suggests, with the reason. A deviation or a choice that changes what users see (a count, a filter result, an order) compared with the ticket, its design documents or another screen of the app is the user's decision: ask it with AskUserQuestion before ExitPlanMode, and record the answer here.
   - A deviation you decide on later, while implementing, goes into this section of the plan file too, with the user's answer: the diff review sees edits made after the approval.

   When you call ExitPlanMode, a hook sends the plan to Cursor for review. The diff review later receives the approved plan, so it checks the code against these requirements too.
2. **Handle review findings by tag.** Cursor tags each finding:
   - `[BLOCKER]`: verify it against the code; fix it, or reject it with a one-line reason (plan: a "Reviewer notes" section). Only blockers consume one of the `DUO_MAX_ROUNDS` rounds.
   - `[SHOULD]` / `[NIT]`: take them only when they clearly help. Never add machinery just to satisfy the reviewer; rejecting with a reason is fine.
   - `[ESCALATE]`: a decision for the user. Ask the user with AskUserQuestion, giving Cursor's and your position; do not decide it yourself.

   Implement, then stop as normal: a Stop hook sends the uncommitted diff to Cursor and blocks the stop on blockers or escalations. Your final summary after a round is passed to the next round, so state clearly what you fixed and why you rejected the rest. When Cursor approves (or the rounds run out), the hook asks you for a closing message: tell the user where the work stands and what they do next, without changing any files.
3. **The team review guide governs every line you add.** When `$DUO_HOME/review-guide.md` exists (the ticket's `CLAUDE.md` may point to a copy), it is how the team's reviewers judge the work, and Cursor reviews against it: a breach in new code is a blocker. Old code around yours that breaks a rule (no type annotations, say) is not a pattern to copy: write the new code the guide's way. Before you stop, go over your diff once against the guide's conventions. Where a linter can check a rule, the Stop hook runs it on your added lines first and sends you the findings to fix.
4. **Polish prose as part of implementing.** After the code is done and the tests pass, and before you stop, run the `no-ai-slop` skill over the non-code text you wrote or changed (docs, README, other `.md`/`.txt`/`.rst`). Edit in place: keep the author's voice and any wording the user gave verbatim, leave code, code comments, identifiers, commands and output samples alone, and do not expand sections nobody asked about. Do this before you stop; if you forget, the Stop hook blocks once and asks for it, before any Cursor call and without costing a review round.
5. **Asides.** A message starting with `/btw` (or `btw`) is a side question: answer it, do not implement, and expect no Cursor review that turn. The working diff stays unreviewed and goes to Cursor on the next normal turn.
6. **Never stage, commit or discard.** Git commands that stage, commit, discard or switch away from the work (`add`, `commit`, `stash`, `push`, `pull`, `reset`, `restore`, `checkout`, `switch`, `clean`, `rm`, `mv`, `merge`, `rebase`, `cherry-pick`, `revert`) are blocked by hook while duo is on. Read-only git (`status`, `diff`, `log`, `show`, `blame`) is fine. Leave everything unstaged for the user.
7. When you finish, summarize what Cursor raised, what you accepted vs rejected, and what the user decided on escalations.

If the output above says the directory is not under DUO_HOME, tell the user the hooks will not fire here.
