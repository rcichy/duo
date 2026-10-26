"""Statistics of the duo sessions in a period, for /duo-stats.

Usage: duo_stats.py [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--only text] <out dir>
  --since  first day counted (default: 30 days ago); --until  first day not counted (default: tomorrow)
  --only   only the sessions whose directory, title or id has text
Counts the events of every duo session that fall in the period (a session running across its edges counts only its
part inside), and the merge request comments autoduo fetched for the sessions' tickets in that period. Writes:
  stats.json  the totals and one row per session
  stats.md    the same as tables
  rounds.md   every review with a [BLOCKER], with Claude's answer, to judge which blockers led to a fix
"""

import glob
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta

sys.dont_write_bytecode = True  # no __pycache__ in the tools folder
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from duo_exchange import Exchange, header, inbox_of, sessions  # noqa: E402 - the path above is this tool's own


def day(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%d").astimezone()


def inbox_comments(inbox: str, since: datetime, until: datetime) -> int:
    """Reviewer comments autoduo fetched into the inbox within the period (one "## " section each)."""
    n = 0
    for path in glob.glob(os.path.join(inbox, "*.md")):
        text = open(path, encoding="utf-8", errors="replace").read()
        m = re.search(r"^Fetched by autoduo on (\d{4}-\d\d-\d\d \d\d:\d\d)", text, re.M)
        fetched = datetime.strptime(m[1], "%Y-%m-%d %H:%M").astimezone() if m else None
        if fetched and since <= fetched < until:
            n += len(re.findall(r"^## ", text, re.M))
    return n


def median(values: list[float]) -> float | None:
    return round(statistics.median(values), 1) if values else None


def session_stats(records: list[dict]) -> dict:
    """The numbers of one session (or of all of them) from its records in the period."""
    by = lambda kind: [r for r in records if r["kind"] == kind]  # noqa: E731
    reviews = [r for r in records if r["kind"].startswith(("plan review", "diff review")) and "tags" in r]
    plan_reviews = [r for r in reviews if r["stage"] == "plan"]
    diff_reviews = [r for r in reviews if r["stage"] == "diff"]
    blocking = lambda rs: [r for r in rs if r["kind"].endswith("(blockers)")]  # noqa: E731
    tags = lambda rs, tag: sum(r["tags"].get(tag, 0) for r in rs)  # noqa: E731
    # a plan revised after a review with blockers: the next plan sent differs from the one reviewed
    plans_revised = 0
    for i, r in enumerate(records):
        if r in blocking(plan_reviews):
            nxt = next((x for x in records[i + 1:] if x["kind"] == "plans sent to ExitPlanMode"), None)
            plans_revised += bool(nxt and nxt.get("changed"))
    decisions = by("decisions by the user")
    typed = by("user messages") + by("asides")
    approvals = by("plans approved by the user")
    return {
        "plans sent": len(by("plans sent to ExitPlanMode")),
        "plan reviews": len(plan_reviews),
        "plan reviews with blockers": len(blocking(plan_reviews)),
        "plan blockers": tags(plan_reviews, "BLOCKER"),
        "plans revised after blockers": plans_revised,
        "diff reviews": len(diff_reviews),
        "diff reviews with blockers": len(blocking(diff_reviews)),
        "diff blockers": tags(diff_reviews, "BLOCKER"),
        "SHOULD findings": tags(reviews, "SHOULD"),
        "NIT findings": tags(reviews, "NIT"),
        "escalations raised by Cursor": tags(reviews, "ESCALATE"),
        "plan reviews approving": sum(1 for r in plan_reviews if r["verdict"] == "APPROVE"),
        "diff reviews approving (LGTM)": sum(1 for r in diff_reviews if r["verdict"] == "LGTM"),
        "guide linter blocks": len(by("gate: guide linter")),
        "prose gate blocks": len(by("gate: prose")),
        "reviews failed": len(by("diff review: FAILED")) + len(by("plan review: FAILED")),
        "round caps hit": len(by("diff review: ROUND CAP")) + len(by("plan review: ROUND CAP")),
        "plan review minutes (median)": median([r["minutes"] for r in plan_reviews if r.get("minutes") is not None]),
        "diff review minutes (median)": median([r["minutes"] for r in diff_reviews if r.get("minutes") is not None]),
        "Cursor minutes (total)": round(sum(r.get("minutes") or 0 for r in reviews)),
        "user messages typed": len(typed),
        "words typed": sum(r.get("words", 0) for r in typed),
        "asides": len(by("asides")),
        "automated messages": len(by("automated messages")) + len(by("follow-ups (reviewer comments handed over)")),
        "decisions answered": len(decisions),
        "decisions: took Claude's recommendation": sum(1 for r in decisions if r["answer"] == "recommended"),
        "decisions: chose another option": sum(1 for r in decisions if r["answer"] == "other option"),
        "decisions: answered in own words": sum(1 for r in decisions if r["answer"] == "own words"),
        "decisions on Cursor's escalations": sum(1 for r in decisions if r.get("escalated")),
        "plans approved by the user": len(approvals),
        "minutes before approving a plan (median)": median([r["waited_s"] / 60 for r in approvals if r.get("waited_s") is not None]),
        "plans sent back by the user": len(by("plans sent back by the user")),
        "follow-ups with reviewer comments": len(by("follow-ups (reviewer comments handed over)")),
        "compactions": len(by("compactions")),
    }


def table(rows: list[tuple[str, object]]) -> str:
    return "| | |\n|---|---|\n" + "\n".join(f"| {k} | {'-' if v is None else v} |" for k, v in rows)


def main() -> None:
    args, out = sys.argv[1:-1], sys.argv[-1] if len(sys.argv) > 1 else ""
    if not out or out.startswith("--"):
        sys.exit(__doc__)
    opts = dict(zip(args[::2], args[1::2]))
    since = day(opts["--since"]) if "--since" in opts else (datetime.now() - timedelta(days=30)).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    until = day(opts["--until"]) if "--until" in opts else (datetime.now() + timedelta(days=1)).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    only = opts.get("--only", "")
    os.makedirs(out, exist_ok=True)

    rows, everything, rounds, inboxes = [], [], [], {}
    for path in sessions():
        if datetime.fromtimestamp(os.path.getmtime(path)).astimezone() < since:
            continue
        h = header(path)
        if only and only not in path and only not in h["title"]:
            continue
        ex = Exchange("")
        ex.walk(path)
        records = [r for r in ex.records if r["at"] and since <= datetime.fromisoformat(r["at"]) < until]
        if not any(r["kind"].startswith(("plan review", "diff review")) for r in records):
            continue
        everything += records
        inbox = inbox_of(h["cwd"])
        comments = inboxes.setdefault(inbox, inbox_comments(inbox, since, until)) if inbox else None
        rows.append({"session": h["id"], "title": h["title"], "directory": h["cwd"], "reviewer comments": comments,
                     **session_stats(records)})
        for r in records:
            if r["kind"].endswith("(blockers)"):
                rounds.append((h["title"] or h["id"], r))

    total = session_stats(everything)
    total = {"sessions": len(rows), "directories": len({r["directory"] for r in rows}),
             "reviewer comments fetched": sum(inboxes.values()), **total}
    period = f"{since:%Y-%m-%d} to {until - timedelta(days=1):%Y-%m-%d}"
    with open(os.path.join(out, "stats.json"), "w", encoding="utf-8") as f:
        json.dump({"period": period, "total": total, "sessions": rows}, f, ensure_ascii=False, indent=1)

    columns = ["title", "user messages typed", "decisions answered", "plans sent", "plan reviews with blockers",
               "diff reviews", "diff blockers", "escalations raised by Cursor",
               "reviewer comments"]
    per = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    per += ["| " + " | ".join("-" if r[c] is None else str(r[c]) for c in columns) + " |" for r in rows]
    with open(os.path.join(out, "stats.md"), "w", encoding="utf-8") as f:
        f.write(f"# Duo statistics, {period}\n\n## Totals\n\n{table(list(total.items()))}\n\n## Per session\n\n"
                + "\n".join(per) + "\n")
    with open(os.path.join(out, "rounds.md"), "w", encoding="utf-8") as f:
        f.write(f"# Reviews with a [BLOCKER], {period}\n\nFor each: Cursor's blocking findings, then Claude's answer to them.\n")
        for n, (title, r) in enumerate(rounds, 1):
            found = "\n".join(f"- {x}" for x in r["findings"] if "[BLOCKER]" in x.upper() or "[" not in x[:12])
            answer = (r.get("answer") or "(no answer kept)")[:4000]
            f.write(f"\n## R{n}: {title}, {r['kind']}, {r['at'][:16]}\n\n"
                    f"{found}\n\nCLAUDE:\n{answer}\n")
    print(f"{out}: {len(rows)} sessions, {len(rounds)} reviews with blockers, period {period}")


if __name__ == "__main__":
    main()
