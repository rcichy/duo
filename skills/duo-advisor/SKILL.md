---
name: duo-advisor
description: Use when the user wants a finished or running duo (Claude+Cursor review loop) session analysed - whether Cursor got the context it needed, whether Claude and Cursor decided well, why merge request reviewers still left comments - or asks how to change duo, its review guide or its checks so the next session gets fewer review comments.
---

# Duo advisor

Arguments: $ARGUMENTS

Read one duo session after the fact and advise on duo itself, the way an advisor reads a whole transcript. The question
to answer: **for each comment the human reviewers left, what change to duo would have made it unnecessary?** Every
finding ends in a concrete change, or in "not preventable" with the reason. Fewer comments must come from better work,
never from a weaker review: do not propose suppressing, softening or down-tagging anything the reviewers want.

## 1. Collect

```bash
python3 -I ~/.config/ai/duo/tools/duo_exchange.py --list [text]          # duo sessions, newest first
python3 -I ~/.config/ai/duo/tools/duo_exchange.py <session> <scratch dir>
```

`<session>` is the argument above: a session id, a transcript path, or text in the session's directory or title (a
ticket key, a branch). With no argument, list the sessions and ask the user which one (AskUserQuestion, the newest four).

Then read, in full:
- `exchange.md`: its header (memory directory, time zone), stats, the table of Cursor calls and the timeline. All
  its times are local. `comments.md`: the reviewers' comments, C1..Cn.
- The team review guide: `$DUO_HOME/review-guide.md` (`jq -r .env.DUO_HOME ~/.claude/settings.json`), or the copy the
  session's directory points to.
- The memory index named in the header of `exchange.md`. If the header says the setting changed after the session
  started, the first part of the session used the per-directory memory.
- Earlier reports: `$DUO_HOME/.claude/duo-advisor/*.md`.
- What you will propose changes to:
  - `~/.config/ai/duo/hooks/common.sh` (`duo_rubric`, context helpers), `review-plan.sh` and `review-diff.sh`;
  - `skills/duo-on/SKILL.md`;
  - `env` in `~/.claude/settings.json` (`DUO_NEW_CODE_RUFF` and the other `DUO_*` settings);
  - for an autoduo ticket, the generators of the briefs. Not the generated `.autoduo/prompt.md` and
    `followup-*.md`, but `~/.config/ai/autoduo/bin/autoduo` (the start prompt) and `lib/followup.sh`
    (`ad_followup_brief`).

Open `plans/` (each plan as Cursor received it), `reviews/` (duo's instruction, then Cursor's review) and the call
archive (`<call>.prompt.md`, `.answer.md`, `.reads`) whenever a question needs them. Without the archive, judge what
Cursor was given from the hook code and from what its review says it checked, and say so in the report.

To see the code a reviewer commented on, use the commit in the comment's blob links (`git -C <repo> show
<sha>:<path>`; the object usually survives a rebase). Without one, take the branch as it was when autoduo fetched the
comment (`git -C <repo> log -1 --before=<fetch time> <branch>`), or the current code, and say which. Never change the
session's checkout.

No `comments.md`? Ask the user for the merge request comments (pasted, or a file). Without any, audit the exchange
(steps 3 to 5) and say that the main question could not be answered.

## 2. Trace every reviewer comment

For each comment, check the evidence; do not guess. Fill in:

| Field | Question |
|---|---|
| Rule | The general rule behind it, in one line, or "one-off". |
| Written down, then | In the guide or the session's memory when the code was written? |
| Written down, now | In the guide or memory today (section, file)? |
| Plan | Did the plan cover the point, or state the opposite? (search `plans/`) |
| Cursor | Did a review raise it (file, tag)? If not: did its prompt hold what it needed, and did it read the file? |
| Claude | If raised: fixed, rejected (its reason), left as [SHOULD]/[NIT], or asked the user? |
| Cause | One, from the table below: the earliest point where it could have been stopped. Add MECHANICAL as a second tag when a linter could have found it. |
| Fix | The layer from step 4 that would have stopped it most cheaply. The most specific one wins: a guide rule that names the pattern beats a broader rubric line. |

| Cause | Meaning |
|---|---|
| GUIDE GAP | The rule is written nowhere that Claude or Cursor reads. |
| MEMORY ONLY | The rule is in Claude's memory but not the guide, so Cursor never saw it. |
| ENFORCEMENT | The guide has the rule and new code broke it; Cursor did not flag it, or flagged it too softly. |
| CONTEXT | Cursor lacked what it needed: a requirement, a design document, sibling code, a user decision, or a truncated prompt. |
| CLAUDE | Claude went against a requirement or rule it had: its plan stated the wrong behaviour, or it fixed one place and not the same mistake elsewhere. |
| DISMISSED | Claude rejected or left unapplied a point that Cursor or a reviewer had raised, and the reviewers raised it (again). |
| DEPTH | Cursor had everything it needed and missed a bug, such as an edge case it never traced. |
| DECISION | A product or scope question for a human. It counts as preventable only if it could have been asked before the MR. |
| NOT PREVENTABLE | Reviewer taste, new information, a change of mind. Say which. |

When a requirement only implied the point (the design says "nulls last", the bug is empty arrays sorting first),
choose DEPTH or CLAUDE if a careful reading of the quoted requirement covers it, else GUIDE GAP.

## 3. Audit the exchange

Beyond the comments, check:
- **Context**, per Cursor call: prompt size, user messages cut, the approved plan missing from a diff review, the guide
  missing. Did the plan quote the requirements verbatim? Were screenshots transcribed? What did Cursor read? A plan
  edited after its approval (a timeline event) is not what the diff review checks against.
- **Decisions**: findings Claude rejected that were right; code added only to satisfy Cursor; [BLOCKER]s that were
  really nits; an [ESCALATE] repeating a decision the user already made; rounds used, round caps hit, failed reviews,
  review durations; plans the user rejected, and what both models missed there.
- **Repeats**: a cause an earlier report already named means the fix proposed then did not work, or was not applied.

## 4. Propose changes

For each change, pick the layer that fits the cause:

1. **A check** for MECHANICAL: a rule code for `DUO_NEW_CODE_RUFF`, or a new check next to `hooks/new-code-check.py`.
2. **The review guide** for GUIDE GAP, MEMORY ONLY and a rule reviewers treat as stricter than the guide says. Write
   the rule the way the reviewers phrase it, generalised, under the right section.
3. **Cursor's instructions** (`duo_rubric`, the review prompts) for ENFORCEMENT and DEPTH.
4. **What Cursor is given** (prompt assembly in the hooks) for CONTEXT.
5. **Claude's instructions** (`duo-on` rules, the brief generators, the plan template) for CLAUDE, DISMISSED and plan gaps.
6. **Memory**, only for a fact about one repository that Claude needs and Cursor does not.

Duo's hooks and skills are project-neutral and may be public, so a change there must hold for any project.
Anything about one project's code goes into its review guide or memory.

Each proposal states:
- **Change**: the file and the exact text, as a diff or a quoted replacement.
- **Prevents**: the comments it covers (C3, C7), and why it would have matched the code at that line. A comment
  counts for every proposal that would stop it on its own; name the overlaps.
- **Cost**: false positives, extra rounds, a longer prompt.
- **Check**: how to confirm it works. Rerun the linter at the reviewed commit, or replay a review (below).

Rank the proposals by comments prevented, then by cost. A proposal that prevents no comment but saves rounds or
user time goes last, marked so.

## 5. Report

Write the report in the user's language to `$DUO_HOME/.claude/duo-advisor/<today, YYYY-MM-DD>-<the title in the
heading of exchange.md>.md` (create the directory if needed), in this order:

1. Verdict: N comments, how many preventable and by which cause; the top three changes.
2. The comment table: C, the comment in a few words, cause, fix. Under it, the other fields of step 2 per comment.
3. Exchange findings, each with its evidence (a review file, a timeline time).
4. The proposals, ranked, each with its change.
5. Repeats from earlier reports.

End the file with a line for later runs:
`<!-- duo-advisor: {"session": "<id>", "comments": <n>, "causes": {"<CAUSE>": <n>}, "proposals": ["<one line each>"]} -->`

Give the user the verdict, the comment table and the ranked proposals. Then ask which to apply: AskUserQuestion,
multiSelect, at most four options, so group the proposals by the file they change and say in the question that the
user can name single proposals by number instead. Apply only the chosen ones, and commit nothing. When a rule goes
into the review guide, add the session's ticket or merge request to the guide's list of sources, if it has one: it
tells a later run whether a ticket's comments already made it into the guide.

## Replay (optional; ask first, a call takes minutes)

To test a prompt change on the review that should have caught a comment: take that call's `<call>.prompt.md` from the
archive and apply the change to it. Check out the commit the reviewers saw in a temporary worktree (`git -C <repo>
worktree add --detach <tmp> <sha>`). Run `agent -p --trust --mode ask --model <model> --output-format text` there
with the changed prompt. A finding on the commented line means the change works. Remove the worktree afterwards.
