"""Extract the Claude<->Cursor exchange of one duo session, for /duo-advisor.

Usage:
  duo_exchange.py --list [text]        duo sessions, newest first (only those whose directory, title or id has text)
  duo_exchange.py <session> <out dir>  writes the exchange of one session to <out dir>
<session> is a transcript (.jsonl), a session id, or text in the session's directory, title or id (a ticket key, a
branch name); with several matches the newest is used and the others are named.

Written to <out dir>:
  exchange.md  stats and a timeline: the user's messages, plans, Cursor's reviews with their findings, Claude's
               answers, questions put to the user, duo's gates, follow-ups
  plans/       every plan sent to ExitPlanMode, in full
  reviews/     every Cursor review, in full
  comments.md  the reviewers' merge request comments that autoduo fetched for the session's ticket, if any
"""

import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

PROJECTS = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "projects")
DUO_LOG_DIR = os.environ.get("DUO_LOG_DIR", os.path.expanduser("~/.claude/duo-log"))
# a Stop hook block or plan-review message written by duo (not the same words quoted in some tool output)
DUO_MARK = r'"content":"Stop hook feedback:\\n(Cursor|duo: Cursor)|"content":"Cursor (approved|has no blocking)|"content":"PreToolUse:ExitPlanMode hook error: Cursor'
TAG_RE = re.compile(r"\[(BLOCKER|SHOULD|NIT|ESCALATE)\]")
FINDING_RE = re.compile(r"^\s*(?:[-*]\s*)?\**\[(BLOCKER|SHOULD|NIT|ESCALATE)\]")
USER_CHARS, CLAUDE_CHARS, LINE_CHARS = 2000, 4000, 600

# Stop hook feedback openings written by duo's review-diff.sh -> what the event was
STOP_KINDS = [
    ("Cursor code review (round", "diff review: CHANGES (blockers)"),
    ("Cursor has no blocking findings but escalates", "diff review: CHANGES (escalations only)"),
    ("duo: Cursor approved the changes", "diff review: LGTM"),
    ("duo: Cursor's review rounds", "diff review: ROUND CAP"),
    ("duo: the Cursor diff review did not happen", "diff review: FAILED"),
    ("duo: the lines you added break rules", "gate: guide linter"),
    ("duo: this change includes non-code text", "gate: prose"),
]


def sessions() -> list[str]:
    """Top-level transcripts that went through a duo review, newest first."""
    files = glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
    if not files:
        return []
    hits = subprocess.run(["grep", "-lE", DUO_MARK, *files], capture_output=True, text=True).stdout.split()
    return sorted(hits, key=os.path.getmtime, reverse=True)


def header(path: str) -> dict[str, str]:
    """id, cwd and title of a transcript."""
    info = {"id": os.path.basename(path)[:-6], "cwd": "", "title": ""}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not info["cwd"] and '"cwd"' in line:
                info["cwd"] = json.loads(line).get("cwd", "")
            if '"custom-title"' in line or ('"ai-title"' in line and not info["title"]):
                entry = json.loads(line)
                info["title"] = entry.get("customTitle") or entry.get("aiTitle") or info["title"]
    return info


def resolve(arg: str) -> tuple[str, list[str]]:
    if arg.endswith(".jsonl") and os.path.isfile(arg):
        return arg, []
    found = [p for p in sessions() if arg in os.path.basename(p) or arg in os.path.dirname(p)]
    if not found:
        found = [p for p in sessions() if arg in header(p)["title"]]
    if not found:
        sys.exit(f"no duo session matches {arg!r}; try --list")
    return found[0], found[1:]


def moment(entry: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(entry.get("timestamp", "").replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def stamp(entry: dict) -> str:
    """Local time of an entry (the transcript itself is in UTC)."""
    when = moment(entry)
    return when.strftime("%Y-%m-%d %H:%M") if when else "?"


# duo's instructions to Claude end where Cursor's review starts: after one of these, else after the first blank line
REVIEW_STARTS = ("CURSOR'S REVIEW:\n", "CURSOR'S LAST REVIEW:\n")


def split_review(text: str) -> tuple[str, str]:
    """(duo's instruction to Claude, Cursor's review) of a review handed to Claude."""
    for start in REVIEW_STARTS:
        if start in text:
            head, _, review = text.partition(start)
            return head.strip(), review.strip()
    if text.startswith("Cursor approved the plan") or text.startswith("Cursor has no blocking findings;"):
        head, _, review = text.partition("\n")
        return head.strip(), review.strip()
    head, _, review = text.partition("\n\n")
    return head.strip(), review.strip()


def cut(text: str, n: int) -> str:
    text = text.strip()
    return text if len(text) <= n else text[:n] + f" [...{len(text) - n} more chars]"


def tool_text(content: object) -> str:
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content if isinstance(c, dict))
    return str(content)


def findings(review: str) -> list[str]:
    return [cut(line, LINE_CHARS) for line in review.splitlines() if FINDING_RE.match(line)]


def tag_counts(review: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in review.splitlines():
        m = FINDING_RE.match(line)
        if m:
            counts[m[1]] = counts.get(m[1], 0) + 1
    return counts


class Exchange:
    """Walks one transcript and collects the duo events."""

    def __init__(self, out: str) -> None:
        self.out = out
        self.lines: list[str] = []
        self.stats: dict[str, int] = {}
        self.pending: dict[str, str] = {}  # tool_use id -> ExitPlanMode / AskUserQuestion
        self.claude: list[str] = []  # Claude's text since the last event
        self.edited: list[str] = []
        self.cwd = ""
        self.plans = self.reviews = 0
        self.followups: list[str] = []
        self.full_next = False  # Claude's answer to a review is kept whole
        self.plan_files: dict[str, str] = {}  # plan file -> its content, as Claude's writes and edits left it
        self.plan_writes: dict[str, str] = {}  # tool_use id of a Write/Edit on a plan file -> the file
        self.plan_calls: dict[str, dict] = {}  # ExitPlanMode tool_use id -> its plan file, input, time, number
        self.plan_approved = False  # the last plan was approved and has not been sent again since
        self.plan_dirty = False  # Claude wrote or edited a plan file since the last ExitPlanMode
        self.plan_hook_msgs: dict[str, tuple[dict, str]] = {}  # ExitPlanMode id -> the plan hook's message, held for the result
        self.plan_sent_at: datetime | None = None
        self.started: datetime | None = None
        # one record per event, for /duo-stats: {"kind", "at" (ISO time), ...details}
        self.records: list[dict] = []
        self.last_review: dict | None = None  # its record, until the next review
        self.typed_since_review = 0
        self.last_plan = ""
        self.plan_verdict_at: datetime | None = None
        self.claude_at: datetime | None = None  # Claude's last output: a diff review starts when it stops

    def count(self, key: str, at: datetime | None = None, **data: object) -> dict:
        self.stats[key] = self.stats.get(key, 0) + 1
        record = {"kind": key, "at": at.isoformat() if at else None, **data}
        self.records.append(record)
        return record

    def flush(self) -> None:
        """Claude's last words and the files it edited since the previous event."""
        if self.edited:
            files = sorted({os.path.relpath(p, self.cwd) if self.cwd and p.startswith(self.cwd) else p for p in self.edited})
            self.lines.append(f"  edited: {', '.join(files)}")
        if self.claude:
            text = "\n".join(self.claude) if self.full_next else cut("\n".join(self.claude[-2:]), CLAUDE_CHARS)
            self.lines.append("  CLAUDE: " + text.strip().replace("\n", "\n    "))
            if self.full_next and self.last_review is not None and "answer" not in self.last_review:
                self.last_review["answer"] = text.strip()
            self.full_next = False
        self.claude, self.edited = [], []

    def event(self, when: str, title: str, body: str = "") -> None:
        self.flush()
        self.lines.append(f"\n### {when} {title}")
        if body:
            self.lines.append(body)

    def save(self, kind: str, name: str, text: str) -> str:
        if not self.out:  # a walk for its records only
            return ""
        path = os.path.join(self.out, kind, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return os.path.join(kind, name)

    def review(self, entry: dict, what: str, text: str) -> None:
        self.reviews += 1
        self.typed_since_review = 0
        instruction, review = split_review(text)
        counts = tag_counts(review)
        minutes = None
        start = self.plan_sent_at if what.startswith("plan") else self.claude_at
        if start and moment(entry):
            minutes = round((moment(entry) - start).total_seconds() / 60, 1)
        if what.startswith("plan"):
            self.plan_verdict_at = moment(entry)
        self.last_review = self.count(what, moment(entry), stage=what.split()[0], verdict=what.split(": ")[1].split()[0],
                                      tags=counts, minutes=minutes, findings=findings(review) or [cut(review, 2500)])
        for tag, n in counts.items():
            self.stats[f"findings {tag}"] = self.stats.get(f"findings {tag}", 0) + n
        slug = re.sub(r"[^a-z]+", "-", what.lower()).strip("-")
        saved = self.save("reviews", f"{self.reviews:02d}-{slug}.md",
                          f"# {what}, {stamp(entry)}\n\n## duo's instruction to Claude\n\n{instruction}\n\n"
                          f"## Cursor's review (its narration, then the verdict and the findings)\n\n{review}\n")
        tags = ", ".join(f"{n} {t}" for t, n in counts.items()) or "no tagged findings"
        took = f"; took {round(minutes)} min" if minutes is not None else ""
        body = "\n".join(f"  - {f}" for f in findings(review))
        self.event(stamp(entry), f"CURSOR {what} ({tags}{took}; full: {saved})", body)
        self.full_next = True

    def plan_sent(self, call_id: str, fresh: str = "") -> None:
        """The PLAN event of an ExitPlanMode call, once: the plan as the file held it when the call ran (the call's
        own input can predate a Write sent alongside it)."""
        call = self.plan_calls.get(call_id)
        if not call or call["emitted"]:
            return
        call["emitted"] = True
        tracked = self.plan_files.get(call["path"], "")
        plan = fresh or (tracked if self.plan_dirty else "") or call["input"] or tracked
        self.plan_dirty = False
        self.plans += 1
        saved = self.save("plans", f"{self.plans:02d}.md", plan) if plan else call["path"]
        self.count("plans sent to ExitPlanMode", call["at"], chars=len(plan), changed=bool(self.last_plan) and plan != self.last_plan)
        last = self.last_review
        if last is not None and last["stage"] == "plan" and "answer" not in last:
            # Claude often answers a plan review only in the plan it sends next: its notes on the review
            notes = re.findall(r"^#+ *(?:Reviewer notes|Review notes|Decisions)[^\n]*\n(?:(?!^#{1,2} ).*\n?)*", plan, re.M | re.I)
            changed = "changed" if plan != self.last_plan else "unchanged"
            last["answer"] = f"(answered with the next plan, {changed})\n" + "\n".join(n.strip() for n in notes)
        self.last_plan = plan
        self.plan_sent_at, self.plan_approved = call["at"], False
        self.event(call["when"], f"PLAN #{self.plans} submitted ({len(plan)} chars; full: {saved})",
                   "  headings: " + " | ".join(re.findall(r"^#+ (.+)$", plan, re.M)[:25]))

    def plan_file_result(self, entry: dict, block: dict) -> None:
        """Keeps the content of a plan file Claude wrote or edited; an edit after approval is an event."""
        path = self.plan_writes.pop(block.get("tool_use_id", ""), "")
        result = entry.get("toolUseResult")
        if not path or block.get("is_error") or not isinstance(result, dict):
            return
        if "oldString" in result:
            # originalFile is left out when Claude already had the file in context
            base = result["originalFile"] if isinstance(result.get("originalFile"), str) else self.plan_files.get(path)
            if base is None:
                return
            old, new = result["oldString"], result.get("newString", "")
            self.plan_files[path] = base.replace(old, new) if result.get("replaceAll") else base.replace(old, new, 1)
            self.plan_dirty = True
            if self.plan_approved:
                self.count("plan file edited after its approval", moment(entry))
                self.event(stamp(entry), "PLAN FILE EDITED after its approval: not reviewed again until the next "
                           "ExitPlanMode; until then the diff review gets the approved version",
                           "  + " + cut(new, 1500).replace("\n", "\n    "))
        elif isinstance(result.get("content"), str):
            self.plan_files[path] = result["content"]
            self.plan_dirty = True

    def user(self, entry: dict, text: str) -> None:
        when = stamp(entry)
        if text.startswith("Stop hook feedback:"):
            text = text.split("\n", 1)[1] if "\n" in text else ""
            for opening, what in STOP_KINDS:
                if text.startswith(opening):
                    if what.startswith("diff review") and what != "diff review: FAILED":
                        self.review(entry, what, text)
                    else:
                        self.count(what, moment(entry))
                        self.event(when, what.upper(), cut(text, 1500))
                    return
            if "Cursor" in text or text.startswith("duo:"):
                self.count("duo stop (unrecognised)", moment(entry))
                self.event(when, "DUO STOP (unrecognised wording)", cut(text, 1500))
            return
        if text.startswith("This session is being continued"):
            self.count("compactions", moment(entry))
            self.event(when, "COMPACTION (context summarised)")
            return
        m = re.search(r"<command-name>(/[^<]+)</command-name>", text)
        if m:
            self.count("commands", moment(entry), name=m[1])
            self.event(when, f"USER COMMAND {m[1]}")
            return
        if text.startswith("<"):
            return
        m = re.search(r"\.autoduo/followup-[\d-]+\.md", text)
        if m:
            self.followups.append(m[0])
            self.count("follow-ups (reviewer comments handed over)", moment(entry))
            self.event(when, f"FOLLOW-UP {m[0]}", cut(text, 400))
            return
        aside = re.match(r"\s*/?btw\b", text) is not None
        automated = text.startswith("autoduo:")
        kind = "automated messages" if automated else "asides" if aside else "user messages"
        self.count(kind, moment(entry), chars=len(text), words=len(text.split()))
        self.typed_since_review += not automated
        title = "AUTOMATED MESSAGE" if automated else "USER (aside)" if aside else "USER"
        self.event(when, title, "> " + cut(text, USER_CHARS).replace("\n", "\n> "))

    def tool_result(self, entry: dict, block: dict) -> None:
        self.plan_file_result(entry, block)
        call_id = block.get("tool_use_id", "")
        name = self.pending.pop(call_id, "")
        text = tool_text(block.get("content", ""))
        when = stamp(entry)
        if name == "AskUserQuestion":
            self.decisions(entry)
            self.event(when, "USER ANSWERED", cut(text, 4000))
        elif name == "ExitPlanMode":
            result = entry.get("toolUseResult")
            self.plan_sent(call_id, result.get("plan", "") if isinstance(result, dict) else "")
            if call_id in self.plan_hook_msgs:
                self.plan_hook_message(*self.plan_hook_msgs.pop(call_id))
            if re.search(r"Cursor reviewed the plan( and requests changes)? \(round", text):
                self.review(entry, "plan review: REVISE (blockers)", text)
            elif "escalates decisions to the user" in text:
                self.review(entry, "plan review: REVISE (escalations only)", text)
            elif "plan review did not happen" in text or "ExitPlanMode hook error: [" in text:
                self.count("plan review: FAILED", moment(entry))
                self.event(when, "PLAN REVIEW FAILED", cut(text, 800))
            elif (isinstance(result, dict) and "plan" in result) or text.startswith("User has approved your plan"):
                waited = (moment(entry) - self.plan_verdict_at).total_seconds() if self.plan_verdict_at and moment(entry) else None
                self.count("plans approved by the user", moment(entry), waited_s=waited)
                self.event(when, "USER APPROVED THE PLAN")
                self.plan_approved = True
            elif "doesn't want to proceed" in text:
                self.count("plans sent back by the user", moment(entry), chars=len(text))
                self.event(when, "USER SENT THE PLAN BACK", cut(text, 2000))
            else:
                self.count("plan calls interrupted", moment(entry))
                self.event(when, "PLAN CALL INTERRUPTED OR UNRECOGNISED", cut(text, 600))

    def assistant(self, entry: dict) -> None:
        for block in entry.get("message", {}).get("content", []) or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                self.claude.append(block["text"])
            elif block.get("type") == "tool_use":
                name, args = block.get("name", ""), block.get("input", {}) or {}
                path = args.get("file_path", "")
                if name in ("Edit", "Write") and re.search(r"/plans/[^/]*\.md$", path):
                    self.plan_writes[block["id"]] = path
                elif name in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
                    self.edited.append(path or "?")
                elif name == "ExitPlanMode":
                    self.pending[block["id"]] = name
                    self.plan_calls[block["id"]] = {"path": args.get("planFilePath", ""), "input": args.get("plan") or "",
                                                    "when": stamp(entry), "at": moment(entry), "emitted": False}
                elif name == "AskUserQuestion":
                    self.pending[block["id"]] = name
                    qs = [q.get("question", "") for q in args.get("questions", [])]
                    self.event(stamp(entry), "CLAUDE ASKS THE USER", "\n".join(f"  ? {cut(q, 600)}" for q in qs))

    def attachment(self, entry: dict) -> None:
        a = entry.get("attachment", {})
        if a.get("type") == "queued_command" and isinstance(a.get("prompt"), str):
            self.user(entry, a["prompt"])
        elif a.get("type") == "hook_system_message" and a.get("hookName") == "PreToolUse:ExitPlanMode":
            # shown before the call's result, which alone has the plan as it was sent: handled with the result
            self.plan_hook_msgs[a.get("toolUseID", "")] = (entry, a.get("content", ""))

    def decisions(self, entry: dict) -> None:
        """One record per question the user answered: did they take Claude's recommendation, another of its
        options, or answer in their own words; and was it a decision Cursor escalated."""
        result = entry.get("toolUseResult")
        if not isinstance(result, dict):
            self.count("decisions by the user", moment(entry), answer="unknown", escalated=False)
            return
        escalated = bool(self.last_review and self.last_review["tags"].get("ESCALATE") and not self.typed_since_review)
        for q in result.get("questions", []):
            answer = (result.get("answers") or {}).get(q.get("question", ""), "")
            labels = [o.get("label", "") for o in q.get("options", [])]
            picked = [a.strip() for a in answer.split(",")] if q.get("multiSelect") else [answer.strip()]
            if not answer:
                kind = "none"
            elif all(a in labels for a in picked):
                kind = "recommended" if all("(Recommended)" in a for a in picked) else "other option"
            else:
                kind = "own words"
            self.count("decisions by the user", moment(entry), answer=kind, escalated=escalated)

    def plan_hook_message(self, entry: dict, text: str) -> None:
        if text.startswith("Cursor approved the plan") or text.startswith("Cursor has no blocking"):
            self.review(entry, "plan review: APPROVE", text)
        elif "round cap" in text:
            self.count("plan review: ROUND CAP", moment(entry))
            self.event(stamp(entry), "PLAN REVIEW ROUND CAP", text)

    def walk(self, path: str) -> None:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = entry.get("type")
                if not self.cwd and entry.get("cwd"):
                    self.cwd = entry["cwd"]
                if not self.started and entry.get("timestamp"):
                    self.started = moment(entry)
                if kind == "assistant" and not entry.get("isSidechain"):
                    self.assistant(entry)
                    self.claude_at = moment(entry)
                elif kind == "attachment":
                    self.attachment(entry)
                elif kind == "user" and not entry.get("isSidechain"):
                    content = entry.get("message", {}).get("content")
                    if isinstance(content, str):
                        if not entry.get("isMeta") or content.startswith("Stop hook feedback:"):
                            self.user(entry, content)
                    else:
                        for block in content or []:
                            if block.get("type") == "tool_result":
                                self.tool_result(entry, block)
                            elif block.get("type") == "text" and not entry.get("isMeta"):
                                self.user(entry, block.get("text", ""))
        for call_id, held in list(self.plan_hook_msgs.items()):  # calls that never got a result (interrupted)
            self.plan_sent(call_id)
            self.plan_hook_message(*held)
        self.flush()


def memory_of(cwd: str, started: datetime | None) -> str:
    """Which memory directory the session's Claude used, and whether that was set only after the session started."""
    settings = os.path.join(cwd, ".claude", "settings.local.json")
    try:
        configured = json.load(open(settings)).get("autoMemoryDirectory", "")
    except (OSError, ValueError):
        configured = ""
    if not configured:
        return os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", cwd), "memory") + " (the per-directory default)"
    changed = datetime.fromtimestamp(os.path.getmtime(settings), timezone.utc).astimezone()
    note = ""
    if started and changed > started:
        note = (f"; {settings} was last changed {changed.strftime('%Y-%m-%d %H:%M')}, after the session started: "
                "the setting may have applied only from then on (settings are read at session start)")
    return os.path.expanduser(configured) + note


def inbox_of(cwd: str) -> str:
    """The autoduo inbox of the ticket the session ran in, if there is one."""
    d = cwd
    while d and d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, ".autoduo", "inbox")):
            return os.path.join(d, ".autoduo", "inbox")
        d = os.path.dirname(d)
    return ""


def comments(inbox: str) -> tuple[str, int]:
    """Every reviewer comment in the inbox, numbered C1.., with its file and the time autoduo fetched it."""
    out, n = [], 0
    for path in sorted(glob.glob(os.path.join(inbox, "*.md"))):
        text = open(path, encoding="utf-8", errors="replace").read()
        title = (re.search(r"^# (.+)$", text, re.M) or [None, os.path.basename(path)])[1]
        fetched = (re.search(r"^Fetched by autoduo on ([^.]+)", text, re.M) or [None, "?"])[1]
        out.append(f"\n# {os.path.basename(path)} (fetched {fetched}): {title}\n")
        for section in re.split(r"^## ", text, flags=re.M)[1:]:
            n += 1
            head, _, body = section.partition("\n")
            body = re.sub(r"<!--.*?-->", "", body, flags=re.S).strip()
            out.append(f"## C{n}: {head.strip()}\n{body}\n")
    return "\n".join(out), n


# what a Cursor prompt held: section heading in duo's prompts -> column name
PROMPT_PARTS = [
    ("TEAM REVIEW GUIDE", "guide"),
    ("APPROVED PLAN", "plan"),
    ("PREVIOUS ROUND", "prev round"),
    ("SIDE DISCUSSION", "asides"),
    ("GUIDE CHECK", "linter"),
    ("earlier messages omitted", "USER MSGS CUT"),
]


def calls(session: str) -> str:
    """What duo kept of each Cursor call: a table from the call archive, else a pointer to the /tmp answer log."""
    d = os.path.join(DUO_LOG_DIR, session)
    prompts = sorted(glob.glob(os.path.join(d, "*.prompt.md")))
    if not prompts:
        log = f"/tmp/claude-duo-{session}-answers.log"
        if os.path.isfile(log):
            return f"\n\n## Cursor calls\nOnly the raw answers were kept: {log}. The prompts were not.\n"
        return "\n\n## Cursor calls\nNot kept: duo's call archive (DUO_LOG_DIR) was off or predates this session.\n"
    rows = ["| call | model | rc | seconds | prompt chars | files read | prompt held |", "|---|---|---|---|---|---|---|"]
    for prompt in prompts:
        base = prompt[: -len(".prompt.md")]
        text = open(prompt, encoding="utf-8", errors="replace").read()
        answer = open(base + ".answer.md", encoding="utf-8", errors="replace").readline() if os.path.isfile(base + ".answer.md") else ""
        meta = dict(re.findall(r"(model|rc)=(\S+)", answer))
        secs = (re.search(r"rc=\S+ (\d+)s", answer) or [None, "?"])[1]
        reads = sum(1 for _ in open(base + ".reads")) if os.path.isfile(base + ".reads") else "-"
        held = ", ".join(name for mark, name in PROMPT_PARTS if mark in text)
        rows.append(f"| {os.path.basename(base)} | {meta.get('model', '?')} | {meta.get('rc', '?')} | {secs} | {len(text)} | {reads} | {held} |")
    return f"\n\n## Cursor calls\nArchive: {d} (<call>.prompt.md, .answer.md, .reads)\n\n" + "\n".join(rows) + "\n"


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "--list":
        text = sys.argv[2] if len(sys.argv) > 2 else ""
        for p in sessions():
            h = header(p)
            if text in p or text in h["title"]:
                when = datetime.fromtimestamp(os.path.getmtime(p), timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
                print(f"{when}  {h['id']}  {h['title'] or '-'}  {h['cwd']}")
        return
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, others = resolve(sys.argv[1])
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    h = header(path)
    ex = Exchange(out)
    ex.walk(path)
    memory = memory_of(h["cwd"], ex.started)
    inbox = inbox_of(h["cwd"])
    text, n = comments(inbox) if inbox else ("", 0)
    if text:
        with open(os.path.join(out, "comments.md"), "w", encoding="utf-8") as f:
            f.write(f"Reviewer comments fetched by autoduo from {inbox}\n{text}")
    stats = "\n".join(f"- {k}: {v}" for k, v in sorted(ex.stats.items()))
    head = [
        f"# Duo exchange: {h['title'] or h['id']}",
        f"- session: {h['id']}",
        f"- transcript: {path}",
        f"- directory: {h['cwd']}",
        f"- started: {ex.started.strftime('%Y-%m-%d %H:%M') if ex.started else '?'}; all times are local ({datetime.now().astimezone().strftime('%Z, UTC%z')}), the transcript itself is in UTC",
        f"- Claude's memory: {memory}",
        f"- reviewer comments: {f'{n} in comments.md (from {inbox})' if n else 'none found (no autoduo inbox)'}",
    ]
    if others:
        head.append(f"- other sessions that matched (older): {', '.join(os.path.basename(p)[:-6] for p in others[:5])}")
    with open(os.path.join(out, "exchange.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(head) + "\n\n## Stats\n" + stats + calls(h["id"]) + "\n## Timeline\n" + "\n".join(ex.lines) + "\n")
    print(f"{os.path.join(out, 'exchange.md')}: {ex.plans} plans, {ex.reviews} Cursor reviews, {n} reviewer comments")


if __name__ == "__main__":
    main()
