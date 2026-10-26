---
name: duo-stats
description: Use when the user wants statistics of duo (Claude+Cursor review loop) sessions over a period - how often Cursor's reviews changed Claude's work, how much the user steered plans and decisions, review time and cost, merge request comments - for a periodic check or to show how the multi-agent setup performs.
---

# Duo statistics

Arguments: $ARGUMENTS

Measure two things over a period: **what Cursor's reviews changed** in Claude's work, and **how much the user
steered** the work (planning, decisions, corrections). Numbers come from the session transcripts. One of them needs
your judgement: whether a blocker Cursor raised led to a fix.

## 1. Count

The argument gives the period: two dates (`2026-10-01 2026-10-31`), one date (from then to today), a month
(`2026-10`), or "last N days". Default: the last 30 days. Text that is not a date limits the sessions (`--only`).

```bash
python3 -I ~/.config/ai/duo/tools/duo_stats.py --since <YYYY-MM-DD> [--until <first day not counted>] [--only <text>] <scratch dir>
```

It writes `stats.md` (totals and one row per session), `stats.json` and `rounds.md` (every review with blockers,
with Claude's answer). Read `stats.md` in full.

## 2. Judge the blocking rounds

Transcripts do not say whether Claude acted on a finding, and file edits do not show it either, since Claude also
edits through scripts. Read `rounds.md` and label every blocking finding by Claude's answer:

| Label | When |
|---|---|
| fixed | Claude changed the code or the plan as asked, or in another way that removes the problem |
| fixed partly | some of it |
| rejected | Claude kept the work and gave a reason |
| to the user | Claude put it to the user, or the round cap ended it |
| unknown | the answer does not say |

For a rejection, also note whether the reason holds up when you check the code (`rejected, Cursor wrong`) or not
(`rejected, Cursor right`). Only check where the answer makes a factual claim you can verify quickly; else mark it
`rejected, unchecked`. With more than about 40 rounds, split `rounds.md` among parallel subagents, and give each this
table and the file.

## 3. Report

Write the report in the user's language to `$DUO_HOME/.claude/duo-stats/<since>_<until>.md`. `$DUO_HOME` comes from
`jq -r .env.DUO_HOME ~/.claude/settings.json`; create the directory if needed. Order:

1. **Headline**, a few lines: sessions and requests; findings Cursor raised that Claude fixed; decisions the user
   made; reviewer comments per merge request.
2. **Cursor's effect**:
   - plan reviews and diff reviews, and how many had blockers;
   - blocking findings by label (step 2): the share fixed is how often Cursor changed Claude's work, and
     `rejected, Cursor right` counts Claude's misses;
   - plans revised after a review;
   - escalations;
   - linter and prose gate blocks;
   - [SHOULD]/[NIT] findings (raised, not counted as changes).
3. **The user's part**:
   - messages typed (words include pasted text, so say so);
   - plans approved by the user, and the median minutes between Cursor's verdict and the approval;
   - plans sent back with feedback;
   - decisions: Claude's recommendation taken, another option chosen, answered in own words; of those, the ones
     Cursor escalated;
   - asides.

   Taking the recommendation is still a decision. The user's steering shows in plans sent back, other options and
   own words.
4. **Cost**: Cursor minutes (median per plan review and per diff review, total), failed reviews, round caps,
   compactions.
5. **Outcome**: merge request comments from reviewers in the period, per ticket where autoduo fetched them. Earlier
   reports in the same directory give the trend: compare when there are some.
6. **Per session**: the table from `stats.md`.
7. **Public summary**: a short block safe to publish, such as in the README of a public repository. Use totals and
   rates only. Name no project, ticket, branch, repository, path, person or code, and say what the numbers come from
   (N sessions, the period, a solo developer).
8. **Caveats**: what the numbers cannot show. Sessions started before the period count only their part inside it.
   Older sessions used older hook wording and untagged findings. The fixed/rejected labels are your judgement.

Show the user the headline, the two main tables and the public summary, and give the report's path.
