"""Runs the task suite for every tool and writes bench/results.md.

Usage:
  python3 -m venv bench/.venv && bench/.venv/bin/pip install tiktoken==0.14.0
  TZ=America/Los_Angeles bench/.venv/bin/python bench/run.py [--ours-bin PATH] [--fixture DIR] [--dump]

--ours-bin runs the real `imessage` CLI against the fixture for the read verbs
(chats, unread, read, search) in place of renderers/ours.py. Sends and
reactions always use the renderer, so the benchmark never sends anything.
--dump writes every main-table tool result to bench/out/<tool>/<task>/.
--no-write prints the tables and leaves results.md alone.

Besides the main tables, the run adds sensitivity rows: imsg without jq and
with plain-text output, chained reads for the shell tools, ours with the
DESIGN default of 2 unread context lines or a larger skill, T1 to T3 with the
agent's own commands counted, and T1 to T3 again with
Tests/Fixtures/contacts-firstname.json, where Mom and Dad are first names.

The output depends only on the fixture, the renderers and the skill counts, so
two runs print the same bytes.
"""

import argparse
from decimal import ROUND_HALF_UP, Decimal
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import overhead  # noqa: E402
import reader  # noqa: E402
import tasks  # noqa: E402
import tokens  # noqa: E402
from renderers import cmer, jimmyliu03  # noqa: E402

RESULTS = os.path.join(HERE, "results.md")
OUT = os.path.join(HERE, "out")


def overhead_rows():
    rows = []
    n, origin = overhead.ours_skill()
    rows.append(("ours", "skills/imessage/SKILL.md, loaded as a skill call", n,
                 "placeholder: DESIGN.md section 6 caps (body 400, description 40) plus frontmatter"
                 if origin == "placeholder" else origin))
    for tool, key in (("imsg", "imsg"), ("steve228uk", "steve228uk"), ("jeffhuber", "jeffhuber"),
                      ("RyanNewsom", "ryannewsom")):
        n, origin = overhead.file_tokens(key)
        what, lic = overhead.FILES[key][:2]
        rows.append((tool, "%s, loaded as a skill call" % what, n, "%s (%s)" % (origin, lic)))
    rows.append(("grokbot-builtin", "built-in iMessage tool definitions", 0, "not published, counted as 0"))
    defs = tokens.count(jimmyliu03.definitions_text())
    sk, origin = overhead.file_tokens("jimmyliu03_skill")
    rows.append(("jimmyliu03", "MCP tools/list (8 tools) and server instructions, always in context", defs,
                 "rebuilt from MCPServer.swift and BridgeToolbox.swift"))
    rows.append(("jimmyliu03", "apple-messages-reminders SKILL.md, loaded as a skill call", sk,
                 "%s (MIT)" % origin))
    rows.append(("cmer", "custom instructions pasted into Grok Bot, always in context",
                 tokens.count(cmer.GROK_INSTRUCTIONS), "rebuilt from GrokAdapter.swift"))
    rows.append(("cmer", "tool listing printed by `imessage-bridge call --agent grok-bot`, a shell call",
                 tokens.count(cmer.listing()), "rebuilt from the CLI's printTool"))
    return rows


def run_all(fx, ours_bin=None, opts=None, tools=None, task_ids=None):
    out = []
    for tid, _ in tasks.TASKS:
        if task_ids and tid not in task_ids:
            continue
        for tool in tools or tasks.TOOLS:
            out.append(tasks.run(fx, tool, tid, ours_bin=ours_bin, opts=opts))
    return out


COMMON = ("T1", "T2", "T3")


def totals(sessions, tool, task_ids=COMMON):
    """(calls, steps, tokens) summed over task_ids for one tool."""
    ss = [s for s in sessions if s.tool == tool and s.task in task_ids]
    return (sum(s.calls for s in ss), sum(s.steps for s in ss), sum(s.input_tokens for s in ss))


def _row(sessions, tool, task):
    return next(s for s in sessions if s.tool == tool and s.task == task)


def competitors():
    return [t for t in tasks.TOOLS if t != "ours"]


def ratio_span(sessions, base_tokens):
    """Lowest and highest competitor token ratio on T1 to T3, with the tools."""
    rs = sorted((totals(sessions, t)[2] / float(base_tokens), t) for t in competitors())
    return rs[0], rs[-1]


def _cell(s, attr):
    if s.possible == "no":
        return "n/a"
    return str(getattr(s, attr))


def _md(text):
    return text.replace("|", "\\|")


def main_table(sessions):
    names = dict(tasks.TASKS)
    lines = ["| Task | Tool | Calls | Steps | Input tokens | Possible | Note |",
             "|---|---|---:|---:|---:|---|---|"]
    last = None
    for s in sessions:
        task = "%s %s" % (s.task, names[s.task]) if s.task != last else ""
        last = s.task
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            task, s.tool, _cell(s, "calls"), _cell(s, "steps"), _cell(s, "input_tokens"), s.possible_label,
            _md(s.note)))
    return "\n".join(lines)


def _round1(v):
    # Half-up rounding, so 1.25 prints as 1.3x everywhere (%.1f rounds half to even).
    return str(Decimal(repr(v)).quantize(Decimal("0.1"), ROUND_HALF_UP))


def _ratio(x, base):
    return _round1(float(x) / base) + "x" if base else "n/a"


def summary_table(sessions):
    by = {}
    for s in sessions:
        by.setdefault(s.tool, []).append(s)
    common = ("T1", "T2", "T3")
    base = by["ours"]
    b_steps = sum(s.steps for s in base if s.task in common)
    b_tok = sum(s.input_tokens for s in base if s.task in common)
    lines = ["| Tool | yes | partial | unverified | no | T1 to T3 calls | T1 to T3 steps | T1 to T3 input tokens "
             "| Steps vs ours | Tokens vs ours |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for tool in tasks.TOOLS:
        ss = by[tool]
        count = {k: sum(1 for s in ss if s.possible == k) for k in ("yes", "partial", "unverified", "no")}
        cs = [s for s in ss if s.task in common]
        steps = sum(s.steps for s in cs)
        tok = sum(s.input_tokens for s in cs)
        lines.append("| %s | %d | %d | %d | %d | %d | %d | %d | %s | %s |" % (
            tool, count["yes"], count["partial"], count["unverified"], count["no"], sum(s.calls for s in cs),
            steps, tok, _ratio(steps, b_steps), _ratio(tok, b_tok)))
    return "\n".join(lines)


def _x(v):
    return _round1(v) + "x"


# Each variant: label, the tool it changes, and the Options it runs with.
COMPETITOR_VARIANTS = [
    ("imsg as benchmarked (`--json | jq -s`)", "imsg", tasks.Options()),
    ("imsg without jq (compact NDJSON)", "imsg", tasks.Options(jq=False)),
    ("imsg without jq, plain-text `history` and `chats`", "imsg", tasks.Options(jq=False, plain=True)),
    ("imsg, independent reads chained in one shell call", "imsg", tasks.Options(chain=True)),
    ("imsg without jq, plain-text `history` and `chats`, reads chained", "imsg",
     tasks.Options(jq=False, plain=True, chain=True)),
    ("steve228uk as benchmarked", "steve228uk", tasks.Options()),
    ("steve228uk, independent reads chained in one shell call", "steve228uk", tasks.Options(chain=True)),
]

IMSG_SKILL_TOKENS = 1906  # overhead_data/counts.json, imsg SKILL.md

# Each ours variant: key, label, Options. The summary looks rows up by key.
OURS_VARIANTS = [
    ("main", "ours as benchmarked (`unread -c 4`, skill as in the fixed-context table)", tasks.Options()),
    ("c2", "ours with `unread -c 2`, the DESIGN default", tasks.Options(unread_context=2)),
    ("chain", "ours with independent reads chained", tasks.Options(chain=True)),
    ("draft", "ours with a 628-token skill, the size of the research/tokens.md section 4 draft",
     tasks.Options(ours_skill=overhead.OURS_DRAFT_SKILL)),
    ("big", "ours with a 1,906-token skill, the size of imsg's", tasks.Options(ours_skill=IMSG_SKILL_TOKENS)),
]


def sensitivity(fx, main, ours_bin=None):
    """Returns the markdown for the sensitivity section and a dict of numbers the summary uses."""
    _, _, base_tok = totals(main, "ours")
    _, base_steps, _ = totals(main, "ours")
    nums, comp_nums = {}, []
    nums["comp"] = comp_nums
    lines = ["| Variant | T1 to T3 calls | T1 to T3 steps | T1 to T3 tokens | Steps vs ours | Tokens vs ours "
             "| T4 steps | T4 tokens |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for label, tool, opts in COMPETITOR_VARIANTS:
        ss = run_all(fx, ours_bin, opts, tools=[tool])
        c, st, tok = totals(ss, tool)
        t4 = _row(ss, tool, "T4")
        lines.append("| %s | %d | %d | %d | %s | %s | %d | %d |" % (
            _md(label), c, st, tok, _ratio(st, base_steps), _ratio(tok, base_tok), t4.steps, t4.input_tokens))
        comp_nums.append((label, tool, st, tok))
    comp = "\n".join(lines)

    lines = ["| Ours variant | T1 to T3 steps | T1 to T3 tokens | Skill share of those tokens "
             "| Competitor token ratios on T1 to T3 | T4 steps | T4 tokens |",
             "|---|---:|---:|---:|---|---:|---:|"]
    for key, label, opts in OURS_VARIANTS:
        ss = run_all(fx, ours_bin, opts, tools=["ours"])
        _, st, tok = totals(ss, "ours")
        skill = sum(e["tokens"] for s in ss if s.task in COMMON for e in s.events if e["kind"] == "skill")
        (lo, lo_t), (hi, hi_t) = ratio_span(main, tok)
        t4 = _row(ss, "ours", "T4")
        lines.append("| %s | %d | %d | %d%% | %s (%s) to %s (%s) | %d | %d |" % (
            _md(label), st, tok, round(100.0 * skill / tok), _x(lo), lo_t, _x(hi), hi_t, t4.steps, t4.input_tokens))
        below = [t for t in competitors() if totals(main, t)[2] < tok]
        nums[key] = {"tokens": tok, "lo": (lo, lo_t), "hi": (hi, hi_t), "below": below}
    ours_tbl = "\n".join(lines)

    # The agent's own commands, added to each tool's T1 to T3 input tokens.
    cmd = {t: sum(s.command_tokens for s in main if s.tool == t and s.task in COMMON) for t in tasks.TOOLS}
    base_with = base_tok + cmd["ours"]
    lines = ["| Tool | T1 to T3 input tokens | Command tokens | Total with commands | Tokens vs ours, main "
             "| Tokens vs ours, with commands |", "|---|---:|---:|---:|---:|---:|"]
    for tool in tasks.TOOLS:
        tok = totals(main, tool)[2]
        lines.append("| %s | %d | %d | %d | %s | %s |" % (
            tool, tok, cmd[tool], tok + cmd[tool], _ratio(tok, base_tok), _ratio(tok + cmd[tool], base_with)))
    cmd_tbl = "\n".join(lines)
    rs = sorted(((totals(main, t)[2] + cmd[t]) / float(base_with), t) for t in competitors())
    nums["cmd"] = {"lo": rs[0], "hi": rs[-1], "tokens": cmd}

    alt = reader.Fixture(fx.root, contacts=CONTACTS_VARIANT)
    alt_s = run_all(alt, ours_bin, tools=None, task_ids=("T1", "T2", "T3"))
    _, alt_base_steps, alt_base_tok = totals(alt_s, "ours")
    lines = ["| Tool | T2 steps, nickname | T2 steps, first name | T2 tokens, nickname | T2 tokens, first name "
             "| T3 tokens, nickname | T3 tokens, first name | T1 to T3 tokens vs ours, nickname "
             "| T1 to T3 tokens vs ours, first name |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for tool in tasks.TOOLS:
        a2, b2 = _row(main, tool, "T2"), _row(alt_s, tool, "T2")
        a3, b3 = _row(main, tool, "T3"), _row(alt_s, tool, "T3")
        lines.append("| %s | %d | %d | %d | %d | %d | %d | %s | %s |" % (
            tool, a2.steps, b2.steps, a2.input_tokens, b2.input_tokens, a3.input_tokens, b3.input_tokens,
            _ratio(totals(main, tool)[2], base_tok), _ratio(totals(alt_s, tool)[2], alt_base_tok)))
    contacts_tbl = "\n".join(lines)
    (alo, alo_t), (ahi, ahi_t) = ratio_span(alt_s, alt_base_tok)
    nums["contacts"] = {"lo": (alo, alo_t), "hi": (ahi, ahi_t)}
    return comp, ours_tbl, cmd_tbl, contacts_tbl, nums


CONTACTS_VARIANT = "contacts-firstname.json"


def ours_skill_desc():
    n, origin = overhead.ours_skill()
    if origin == "placeholder":
        return ("a {:,}-token placeholder: the DESIGN.md section 6 caps of 400 body tokens and 40 description "
                "tokens, plus {} for the frontmatter lines".format(
                    n, n - overhead.OURS_BODY_MAX - overhead.OURS_DESC_MAX))
    return "the {:,}-token {}".format(n, origin)


def _and(items):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def summary(main, nums):
    _, base_steps, base_tok = totals(main, "ours")
    skill = sum(e["tokens"] for s in main if s.tool == "ours" and s.task in COMMON
                for e in s.events if e["kind"] == "skill")
    (lo, lo_t), (hi, hi_t) = ratio_span(main, base_tok)
    steps = sorted((totals(main, t)[1] / float(base_steps), t) for t in competitors())
    ours_rows = [s for s in main if s.tool == "ours"]
    yes = [s.task for s in ours_rows if s.possible == "yes"]
    unv = ["%s (%s)" % (s.task, s.gate) for s in ours_rows if s.possible == "unverified"]
    big, draft, c2 = nums["big"], nums["draft"], nums["c2"]
    out = []
    out.append(
        "On T1 to T3, the tasks every tool can at least attempt, the other tools use %s (%s) to %s (%s) the "
        "input tokens ours does. The highest ratio is %s, for %s. %s" % (
            _x(lo), lo_t, _x(hi), hi_t, _x(hi), hi_t,
            "No tool is 10x heavier than ours on T1 to T3." if hi < 10 else
            "At least one tool is 10x heavier than ours on T1 to T3."))
    out.append(
        "This replaces the first run's 1.1x to 17.7x range. That range came from scripts that asked "
        "steve228uk, the built-in tools and jeffhuber for more messages than the other tools. Every tool that "
        "takes a history limit now gets the same one, ours included (bench/VERIFY.md).")
    tie = [t for r, t in steps if r <= 1.0]
    out.append(
        "On steps (calls plus approval cards, dialogs, questions and grants), the other tools take %s (%s) to "
        "%s (%s) as many as ours on T1 to T3.%s" % (
            _x(steps[0][0]), steps[0][1], _x(steps[-1][0]), steps[-1][1],
            (" %s ties or beats ours on steps." % ", ".join(tie)) if tie else ""))
    below = big["below"]
    out.append(
        "Every ours number is a projection. It comes from `renderers/ours.py`, a renderer for the DESIGN.md "
        "section 5 CLI, which is not built yet. The ours skill is {}. It is {:,} of ours' {:,} T1 to T3 "
        "tokens ({}%). With the only concrete draft skill, 628 tokens (research/tokens.md section 4), the range "
        "is {} ({}) to {} ({}). If the real skill is as large as imsg's (1,906 tokens), the range becomes {} ({}) "
        "to {} ({}){}. With the DESIGN default of `unread -c 2` instead of 4, it is {} ({}) to {} ({}).".format(
            ours_skill_desc(), skill, base_tok, round(100.0 * skill / base_tok),
            _x(draft["lo"][0]), draft["lo"][1], _x(draft["hi"][0]), draft["hi"][1],
            _x(big["lo"][0]), big["lo"][1], _x(big["hi"][0]), big["hi"][1],
            (", and %s would use fewer tokens than ours" % " and ".join(below)) if below else "",
            _x(c2["lo"][0]), c2["lo"][1], _x(c2["hi"][0]), c2["hi"][1]))
    cm = nums["cmd"]
    out.append(
        "The main tables leave out the agent's own commands. Counting them moves the range to {} ({}) to {} ({}), "
        "mostly because jeffhuber's request files are {:,} tokens of commands on T1 to T3.".format(
            _x(cm["lo"][0]), cm["lo"][1], _x(cm["hi"][0]), cm["hi"][1], cm["tokens"]["jeffhuber"]))
    comp = {label: (tool, st, tok) for label, tool, st, tok in nums["comp"]}
    plain = comp[COMPETITOR_VARIANTS[2][0]]
    chained = comp[COMPETITOR_VARIANTS[3][0]]
    imsg_main = totals(main, "imsg")
    out.append(
        "imsg's ratio depends on how the agent calls it. Without `jq -s` and with plain-text `history` and "
        "`chats` it is "
        "{} ({:,} tokens) instead of {}. Chaining its five T1 history reads into one shell call cuts its T1 to T3 "
        "steps from {} to {} ({} ours).".format(
            _x(plain[2] / float(base_tok)), plain[2], _x(imsg_main[2] / float(base_tok)), imsg_main[1],
            chained[1], _x(chained[1] / float(base_steps))))
    c = nums["contacts"]
    out.append(
        "With Mom and Dad stored as first names (`%s`), jeffhuber and cmer find Mom without a failed call and "
        "a question, and the T1 to T3 range is %s (%s) to %s (%s)." % (
            CONTACTS_VARIANT, _x(c["lo"][0]), c["lo"][1], _x(c["hi"][0]), c["hi"][1]))
    five = []
    for tool in tasks.TOOLS:
        ss = [x for x in main if x.tool == tool]
        if tool != "ours" and not any(x.possible == "no" for x in ss):
            five.append("%s (%d yes, %d unverified)" % (
                tool, sum(1 for x in ss if x.possible == "yes"), sum(1 for x in ss if x.possible == "unverified")))
    out.append(
        "Ours is yes on %s and unverified on %s. Its sends in T2 and T5 depend on spike S1, which checks that "
        "the Automation grant goes to the bridge, the same -1743 risk that makes the osascript sends of other "
        "tools unverified. DESIGN.md also holds tapbacks back until S3 and group file sends until S2. %s" % (
            _and(yes), _and(unv),
            ("Other tools that attempt all five tasks: %s." % ", ".join(five)) if five else
            "No other tool attempts all five tasks."))
    return "\n\n".join(out)


def ours_caveat(main):
    _, _, base_tok = totals(main, "ours")
    skill = sum(e["tokens"] for s in main if s.tool == "ours" and s.task in COMMON
                for e in s.events if e["kind"] == "skill")
    return ("Ours rows come from `renderers/ours.py`, a renderer for a CLI that is not built yet, so they are "
            "projections, not measurements. The ours skill is {}. It is {:,} of ours' {:,} T1 to T3 tokens "
            "({}%).".format(ours_skill_desc(), skill, base_tok, round(100.0 * skill / base_tok)))


def overhead_table():
    lines = ["| Tool | Fixed context | Tokens | Source |", "|---|---|---:|---|"]
    for tool, what, n, src in overhead_rows():
        lines.append("| %s | %s | %d | %s |" % (tool, _md(what), n, _md(src)))
    return "\n".join(lines)


def trace(sessions):
    """Per session, the ordered events with their token counts."""
    out = []
    for s in sessions:
        out.append("%s %s (%s): %d calls, %d steps, %d tokens" % (
            s.task, s.tool, s.possible_label, s.calls, s.steps, s.input_tokens))
        for e in s.events:
            label = " ".join(e["label"].split())
            if len(label) > 110:
                label = label[:107] + "..."
            out.append("  %-11s %6d  %s" % (e["kind"], e["tokens"], label))
    return "\n".join(out)


def dump(sessions):
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    for s in sessions:
        d = os.path.join(OUT, s.tool, s.task)
        os.makedirs(d)
        for i, e in enumerate(s.events, 1):
            name = "%02d-%s.txt" % (i, re.sub(r"[^a-z-]", "", e["kind"]))
            with open(os.path.join(d, name), "w", encoding="utf-8") as f:
                f.write("# %s\n# tokens: %d\n\n%s" % (e["label"], e["tokens"], e["text"] or ""))


def _no_card_steps(sessions):
    """T1 to T3 steps per tool with every Grok Bot shell approval card removed."""
    steps = {}
    for x in sessions:
        if x.task in ("T1", "T2", "T3"):
            cards = sum(1 for e in x.events if e["kind"] == "card")
            steps[x.tool] = steps.get(x.tool, 0) + x.steps - cards
    order = sorted(tasks.TOOLS, key=lambda t: (steps.get(t, 0), tasks.TOOLS.index(t)))
    return ", ".join("%s %d" % (t, steps.get(t, 0)) for t in order)


def report(sessions, ours_mode, sens):
    comp, ours_tbl, cmd_tbl, contacts_tbl, nums = sens
    caveat = ours_caveat(sessions)
    parts = [
        "# S5 token benchmark results",
        "",
        "Generated by `bench/run.py` from the synthetic fixture in `Tests/Fixtures/`. "
        "Tokens are o200k_base counts from tiktoken. Each task is a fresh Grok Bot session.",
        "",
        "Ours: %s." % ours_mode,
        "",
        "## Summary",
        "",
        summary(sessions, nums),
        "",
        "## Per task",
        "",
        caveat,
        "",
        main_table(sessions),
        "",
        "## Per tool",
        "",
        "T1 to T3 are the tasks every tool can at least attempt. Ratios divide by the ours total. " + caveat,
        "",
        summary_table(sessions),
        "",
        "## Sensitivity",
        "",
        "Each row reruns the suite with one script choice changed. Everything else matches the main tables.",
        "",
        "### Competitor variants",
        "",
        "Ratios divide by the main ours row. Chained rows put independent reads in one shell call: the five "
        "T1 history reads and the two T4 history reads. The plain-text rows render `imsg history` and "
        "`imsg chats` without `--json`, following HistoryCommand.swift and ChatsCommand.swift. Only T1 keeps "
        "`imsg chats --unread-only --json`, because plain `imsg chats` prints no unread count. `imsg search` also "
        "runs without `--json` (BridgeIntroCommands.swift lines 71 to 77).",
        "",
        comp,
        "",
        "### Ours variants",
        "",
        "The ratio column divides the main competitor totals by this ours total and gives the lowest and "
        "highest. In the main run ours asks `unread` for 4 lines of context, the same 4 earlier messages every "
        "other tool with a limit reads in T1. The `-c 2` row uses the DESIGN.md default instead. The 628-token "
        "row uses the full draft SKILL.md in research/tokens.md section 4, written before DESIGN.md set the "
        "400-token body cap.",
        "",
        ours_tbl,
        "",
        "### Agent commands counted",
        "",
        "The main tables count what the tools return, not what the agent writes. This table adds the agent's "
        "commands on T1 to T3. Shell commands are counted as written. MCP and built-in calls are counted from "
        "the short call labels in the trace, which leave out the send text, so those counts run a little low.",
        "",
        cmd_tbl,
        "",
        "### Contacts variant",
        "",
        "`contacts.json` stores Mom and Dad as nicknames on cards named Meera Desai and Sunil Desai. "
        "`%s` stores them with \"Mom\" and \"Dad\" as first names and no nickname. Tools that read only "
        "first and last names (jeffhuber, cmer) find Mom directly with the second file. The last two columns "
        "divide each tool's T1 to T3 total by ours under the same contacts file." % CONTACTS_VARIANT,
        "",
        contacts_tbl,
        "",
        "## Known biases",
        "",
        "- Every ours row is a projection from a renderer, and the ours skill is a placeholder (see above).",
        "- The main tables leave out the agent's own commands. On T1 to T3 they are {:,} tokens for jeffhuber, "
        "{} for imsg, steve228uk, cmer and the built-in tool, and {} for ours. This favors jeffhuber most. "
        "The agent commands table shows the effect.".format(
            nums["cmd"]["tokens"]["jeffhuber"],
            "%d to %d" % (min(nums["cmd"]["tokens"][t] for t in ("imsg", "steve228uk", "cmer", "grokbot-builtin")),
                          max(nums["cmd"]["tokens"][t] for t in ("imsg", "steve228uk", "cmer", "grokbot-builtin"))),
            nums["cmd"]["tokens"]["ours"]),
        "- Every shell call counts one approval card, and built-in and MCP calls count none. With a standing "
        "`always` grant for `run-command` (research/grokbot.md), T1 to T3 steps are {}.".format(_no_card_steps(sessions)),
        "- The built-in tool definitions count as 0 tokens, because the schemas are server-side. This favors "
        "the built-in tool.",
        "- The built-in `ChatItems` limit parameter is assumed to be exposed to the model. The worker accepts "
        "it, but the model-facing schema is not published.",
        "- The built-in `FindContacts` is assumed to match nicknames with `contacts.json`.",
        "- Every competitor's attributedBody decoder is assumed to work on every row. RyanNewsom's, for "
        "example, is a byte heuristic.",
        "- Ours reads two chats in T4. Its `chats` preview shows each chat's newest message, and in the "
        "fixture chat 23's newest is the user's own at 22:58, so the preview cannot rule out an incoming "
        "message there newer than chat 19's at 21:00.",
        "",
        "## Fixed context",
        "",
        "Counted inside every task row above, once per session.",
        "",
        overhead_table(),
        "",
        "## How rows are counted",
        "",
        "- Calls are skill loads, shell calls, MCP calls and built-in tool calls.",
        "- Steps are calls plus every Grok Bot shell approval card (one per shell call), native Mac dialog, "
        "Grok Bot consent card, question widget, clarifying question, in-chat approval, approval in a "
        "companion app and permission grant.",
        "- Every T4 path that needs Accessibility counts one grant step, ours included. Full Disk Access and "
        "Automation grants happen at setup for every tool and are not counted for any.",
        "- Every tool that takes a history limit reads the same amount: the unread count plus 4 in T1, 10 in "
        "T2 and 3 per chat in T4. Ours asks `unread -c 4` in T1. The built-in `ChatItems` limit in T1 is the "
        "per-chat count from `IMessageActivity` plus 4. RyanNewsom, cmer and jeffhuber read fixed windows in T1 "
        "and take no limit there.",
        "- Input tokens are the skill or tool-list text, every tool result including errors and approval "
        "messages, and the user's replies. The task prompt and the agent's own commands are left out.",
        "- Possible is yes, partial when the tool can only approximate the task, no when it has no way to do "
        "it, or unverified. Unverified means the path runs osascript or UI scripting from the Grok Bot shell, "
        "which macOS may block with error -1743, or that DESIGN.md holds the feature back until a spike "
        "passes. For ours the spike is in parentheses.",
        "- Rows marked no show n/a, because the agent stops once it finds no matching command or tool.",
        "",
        "## Trace",
        "",
        "```",
        trace(sessions),
        "```",
        "",
    ]
    return "\n".join(parts)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ours-bin", help="path to the built imessage CLI; replaces renderers/ours.py for read verbs")
    ap.add_argument("--fixture", default=reader.DEFAULT_FIXTURE, help="fixture directory with chat.db")
    ap.add_argument("--dump", action="store_true", help="write every tool result under bench/out/")
    ap.add_argument("--no-write", action="store_true", help="print only, leave bench/results.md alone")
    args = ap.parse_args(argv)

    if args.ours_bin and not os.access(args.ours_bin, os.X_OK):
        raise SystemExit("--ours-bin %s is not an executable file" % args.ours_bin)
    fx = reader.Fixture(os.path.abspath(args.fixture))
    sessions = run_all(fx, ours_bin=args.ours_bin)
    mode = ("the real CLI via --ours-bin for read verbs, renderers/ours.py for send and react"
            if args.ours_bin else "renderers/ours.py, the DESIGN.md section 5 format")

    sens = sensitivity(fx, sessions, ours_bin=args.ours_bin)
    comp, ours_tbl, cmd_tbl, contacts_tbl, nums = sens

    print(summary(sessions, nums))
    print()
    print(main_table(sessions))
    print()
    print(summary_table(sessions))
    print()
    print(comp)
    print()
    print(ours_tbl)
    print()
    print(cmd_tbl)
    print()
    print(contacts_tbl)
    print()
    print(overhead_table())
    if args.dump:
        dump(sessions)
    if not args.no_write:
        with open(RESULTS, "w", encoding="utf-8") as f:
            f.write(report(sessions, mode, sens))


if __name__ == "__main__":
    main()
