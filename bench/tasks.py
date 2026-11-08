"""The five DESIGN.md tasks, scripted per tool as a fresh Grok Bot session.

Each script lists what the agent would do with that tool's own docs: the skill
or tool-list load, the lookups it needs to find the chat, any retries, user
turns, and the shell approval card Grok Bot raises for every ExternalShell
call. The tool outputs come from the renderers, run against the fixture.

Counting rules:
- calls: skill loads, shell calls, MCP calls and built-in tool calls.
- steps: calls, plus one per Grok Bot shell approval card, native Mac dialog,
  Grok Bot consent card, question widget, clarifying question, in-chat
  approval, approval in a companion app, and permission grant.
- input tokens: o200k_base count of everything the tool puts in the model's
  context once: skill or tool-list text, every tool result (errors and
  approval messages included) and the user's replies. The task prompt is the
  same for every tool and is left out. The agent's own commands are left out
  too, but they are not the same size: on T1 to T3 they are 1,735 tokens for
  jeffhuber, 150 to 201 for imsg, steve228uk, cmer and the built-in tool, and
  40 for ours. Session.command_tokens counts them, and run.py reports a
  sensitivity table that adds them.
- possible: yes, partial (the tool can only approximate the task), no, or
  unverified. Unverified means the path exists but goes through osascript or
  UI scripting from the Grok Bot shell, which macOS may block with -1743 or an
  Accessibility check, or that it depends on a DESIGN.md spike that has not
  run. For ours the spike is named in parentheses, for example "unverified (S3)".
- grants: a T4 path that needs Accessibility counts one grant step, for every
  tool. Full Disk Access and Automation grants happen at setup for every tool
  and are not counted for any.
- history limits are the same for every tool that takes one: the unread count
  plus 4 in T1 (ours asks `unread -c 4`), 10 in T2 and 3 per chat in T4.
"""

import json
import os
import subprocess

import overhead
import tokens
from renderers import cmer, grokbot_builtin as gb, imsg, jeffhuber as jh, jimmyliu03 as jl, ours, ryannewsom as rn

TOOLS = ["ours", "imsg", "grokbot-builtin", "steve228uk", "jeffhuber", "RyanNewsom", "jimmyliu03", "cmer"]
TASKS = [
    ("T1", "Summarize unread messages"),
    ("T2", "Reply to Mom"),
    ("T3", "Find the address Dad sent last month"),
    ("T4", "React to the last message"),
    ("T5", "Send a photo to a group"),
]

# What the user types. T2 gives the reply text so every tool sends the same words.
REPLY = "Yes, I'll be there Sunday. Will call Nani tomorrow."
PHOTO = "~/Pictures/IMG_4420.HEIC"
PHOTO_ABS = "/Users/alex/Pictures/IMG_4420.HEIC"
# The fixture copy of the same photo. chat.db records it as 2.2 MB.
PHOTO_FIXTURE = "Attachments/76/09/CBF6F44C-5BD1-4B89-9C7E-1D3801BC9BAD/IMG_4420.HEIC"
SEND_OK = "Yes, send it"
APPROVED_IN_APP = "Approved it in Mac Bridge"

# Every tool with a history limit reads the same amount (bench/VERIFY.md, correction 1):
UNREAD_EXTRA = 4  # T1: each unread chat's unread count plus this many earlier messages
REPLY_LIMIT = 10  # T2: messages read before replying to Mom
REACT_LIMIT = 3   # T4: messages read per candidate chat before reacting

CALL_KINDS = ("skill", "shell", "mcp", "builtin")
STEP_KINDS = ("card", "dialog", "consent", "widget", "clarify", "approve", "app-approve", "grant")


class Options(object):
    """Script choices that the sensitivity rows vary. The defaults are the main tables.

    chain: run independent reads (the T1 history reads, the two T4 chat reads)
      as one shell call for every shell tool that has them: ours, imsg, steve228uk.
    jq: imsg pipes through `jq -s`, as its skill's examples do.
    plain: imsg `history` and `chats` without --json (the text modes in
      HistoryCommand.swift and ChatsCommand.swift). T1 keeps
      `chats --unread-only --json`, because plain `chats` prints no unread count.
    unread_context: lines of context ours asks for with `imessage unread -c`.
      The default matches the 4 earlier messages every other tool reads in T1.
      The DESIGN.md default is 2.
    ours_skill: replaces the ours skill token count.
    """

    def __init__(self, chain=False, jq=True, plain=False, unread_context=UNREAD_EXTRA, ours_skill=None):
        self.chain, self.jq, self.plain = chain, jq, plain
        self.unread_context, self.ours_skill = unread_context, ours_skill


class Session(object):
    def __init__(self, fx, tool, task, ours_bin=None, opts=None):
        self.fx, self.tool, self.task, self.ours_bin = fx, tool, task, ours_bin
        self.opts = opts or Options()
        self.events = []
        self.possible = "yes"
        self.gate = ""
        self.note = ""

    def _add(self, kind, label, text=None, n=None):
        self.events.append({"kind": kind, "label": label, "text": text,
                            "tokens": n if n is not None else (tokens.count(text) if text else 0)})

    def context(self, label, text=None, n=None):
        self._add("context", label, text, n)

    def skill(self, label, text=None, n=None):
        self._add("skill", label, text, n)

    def shell(self, cmd, out):
        self._add("shell", cmd, out)
        self._add("card", "Grok Bot shell approval")

    def shells(self, pairs):
        """Independent shell commands: one call each, or one chained call with Options.chain."""
        if self.opts.chain and len(pairs) > 1:
            self.shell("; ".join(c for c, _ in pairs), "".join(o for _, o in pairs))
        else:
            for c, o in pairs:
                self.shell(c, o)

    def mcp(self, call, out):
        self._add("mcp", call, out)

    def builtin(self, call, out):
        self._add("builtin", call, out)

    def step(self, kind, label, reply=None):
        self._add(kind, label, reply)

    def result(self, possible, note="", gate=""):
        self.possible, self.note, self.gate = possible, note, gate

    @property
    def possible_label(self):
        return "%s (%s)" % (self.possible, self.gate) if self.gate else self.possible

    @property
    def calls(self):
        return sum(1 for e in self.events if e["kind"] in CALL_KINDS)

    @property
    def steps(self):
        return sum(1 for e in self.events if e["kind"] in CALL_KINDS + STEP_KINDS)

    @property
    def input_tokens(self):
        return sum(e["tokens"] for e in self.events)

    @property
    def command_tokens(self):
        """o200k_base count of the agent's own calls, from the event labels.
        Shell labels are the exact commands. MCP and built-in labels are short
        stand-ins for the JSON arguments and leave out send text."""
        return sum(tokens.count(e["label"]) for e in self.events if e["kind"] in ("shell", "mcp", "builtin"))

    # ---- ours: the read verbs can run through the real CLI ----

    def ours(self, *args):
        if self.ours_bin:
            return _run_bin(self.fx, self.ours_bin, args)
        return _ours_render(self.fx, args)


def _run_bin(fx, binary, args):
    env = dict(os.environ)
    env.update({
        "IMESSAGE_DB": fx.db_path,
        "IMESSAGE_CONTACTS": fx.contacts_path,
        "IMESSAGE_NOW": fx.now.isoformat(),
        "IMESSAGE_ATTACHMENTS": os.path.join(fx.root, "Attachments"),
        "TZ": fx.manifest["time_zone"],
    })
    p = subprocess.run([binary] + list(args), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=60)
    return p.stdout.decode("utf-8", "replace")


def _opt(args, name, default=None, cast=str):
    args = list(args)
    if name in args:
        return cast(args[args.index(name) + 1])
    return default


def _ours_render(fx, args):
    verb, rest = args[0], list(args[1:])
    if verb == "chats":
        return ours.chats(fx, n=_opt(rest, "-n", 20, int), unread="--unread" in rest)
    if verb == "unread":
        return ours.unread(fx, context=_opt(rest, "-c", 2, int))
    if verb == "read":
        return ours.read(fx, rest[0], n=_opt(rest, "-n", 30, int))
    if verb == "search":
        return ours.search(fx, rest[0], in_=_opt(rest, "--in"))
    raise ValueError("no renderer for imessage %s" % verb)


def _unread_chats(fx):
    return [c for c in fx.chats_by_recent() if fx.unread(c.rowid)]


MOM, DAD = "+14155550101", "+14155550102"


def _contact_name(fx, handle):
    """The name a Contacts-only tool shows for a handle: first and last, no nickname."""
    return fx.full_name(handle)


def _names_note(fx, handle, short):
    full = _contact_name(fx, handle)
    return "names come back as %s, not %s" % (full, short) if full and full != short else ""


def _join(*notes):
    return "; ".join(n for n in notes if n)


# ---------------- ours ----------------

S1_NOTE = "the send depends on S1 (Automation grant tied to the bridge)"


def ours_tasks(s, t):
    fx = s.fx
    n, origin = overhead.ours_skill()
    if s.opts.ours_skill is not None:
        n, origin = s.opts.ours_skill, "sensitivity: %d-token skill" % s.opts.ours_skill
    s.skill("imessage skill (%s)" % origin, n=n)
    if t == "T1":
        c = str(s.opts.unread_context)
        s.shell("imessage unread -c %s" % c, s.ours("unread", "-c", c))
    elif t == "T2":
        s.shell("imessage read Mom -n %d" % REPLY_LIMIT, s.ours("read", "Mom", "-n", str(REPLY_LIMIT)))
        s.shell('imessage send Mom "%s"' % REPLY, ours.send(fx, "Mom", text=REPLY))
        s.step("dialog", "native approval dialog: Allow once")
        s.result("unverified", S1_NOTE, gate="S1")
    elif t == "T3":
        s.shell("imessage search address --in Dad", s.ours("search", "address", "--in", "Dad"))
    elif t == "T4":
        k = str(REACT_LIMIT)
        s.shell("imessage chats -n 5", s.ours("chats", "-n", "5"))
        # The preview shows chat 23's newest message is the user's own at 22:58.
        # A message from Jordan between 21:00 and 22:58 would not show, so the
        # agent reads chat 23 as well as chat 19 before picking the target.
        s.shells([("imessage read 23 -n " + k, s.ours("read", "23", "-n", k)),
                  ("imessage read 19 -n " + k, s.ours("read", "19", "-n", k))])
        s.shell("imessage react 41557 like", ours.react(fx, 41557, "like"))
        s.step("dialog", "native approval dialog: Allow once")
        s.step("grant", "Accessibility for the bridge (S3)")
        s.result("unverified", "tapbacks ship only if S3 passes; the chats preview cannot rule out a newer "
                               "incoming message in chat 23, so the agent reads it too", gate="S3")
    elif t == "T5":
        s.shell("imessage send Family --file %s" % PHOTO, ours.send(fx, "Family", file=PHOTO_FIXTURE))
        s.step("dialog", "native approval dialog: Allow once")
        s.result("unverified", "group file sends stay unverified until S2; " + S1_NOTE, gate="S1, S2")


# ---------------- imsg ----------------

def _imsg_skill(s):
    n, origin = overhead.file_tokens("imsg")
    s.skill("imsg SKILL.md (%s)" % origin, n=n)


def _osascript_note():
    return "osascript from the Grok Bot shell may get -1743"


ACCESSIBILITY_SHELL = "Accessibility for the Grok Bot shell"


def _imsg_hist(s, chat_id, limit):
    """One `imsg history` call as (command, output) under the session's options."""
    o = s.opts
    if o.plain:
        return ("imsg history --chat-id %d --limit %d" % (chat_id, limit),
                imsg.history(s.fx, chat_id, limit, plain=True))
    jq = " | jq -s" if o.jq else ""
    return ("imsg history --chat-id %d --limit %d --json%s" % (chat_id, limit, jq),
            imsg.history(s.fx, chat_id, limit, jq=o.jq))


def _imsg_chats(s, limit):
    """`imsg chats --limit N` as (command, output): plain text under Options.plain, else JSON."""
    if s.opts.plain:
        return "imsg chats --limit %d" % limit, imsg.chats_plain(s.fx, limit)
    pipe = " | jq -s" if s.opts.jq else ""
    return "imsg chats --limit %d --json%s" % (limit, pipe), imsg.chats(s.fx, limit, jq=s.opts.jq)


def _imsg_select(s, word):
    if s.opts.plain:
        # Plain `imsg chats` has no filter. The agent reads the list and picks the chat.
        return _imsg_chats(s, 200)
    if s.opts.jq:
        cmd = ("imsg chats --limit 200 --json | jq -s '.[] | select((.contact_name // .display_name // .name "
               "// .identifier // \"\" | ascii_downcase) | contains(\"%s\"))'" % word)
        return cmd, imsg.chats(s.fx, 200, select=word)
    # Without jq the agent reads the whole chat list and picks the chat itself.
    return "imsg chats --limit 200 --json", imsg.chats(s.fx, 200)


def imsg_tasks(s, t):
    fx = s.fx
    jq = s.opts.jq
    pipe = " | jq -s" if jq else ""
    _imsg_skill(s)
    if t == "T1":
        s.shell("imsg chats --unread-only --json" + pipe, imsg.chats(fx, 20, unread_only=True, jq=jq))
        s.shells([_imsg_hist(s, c.rowid, len(fx.unread(c.rowid)) + UNREAD_EXTRA) for c in _unread_chats(fx)])
    elif t == "T2":
        s.shell(*_imsg_select(s, "mom"))
        s.shell(*_imsg_hist(s, 7, REPLY_LIMIT))
        s.shell('imsg send --chat-id 7 --text "%s" --json' % REPLY, imsg.send_result(fx, 7))
        s.result("unverified", _osascript_note())
    elif t == "T3":
        if s.opts.plain:
            s.shell('imsg search --query "address"', imsg.search_plain(fx, "address"))
        else:
            s.shell('imsg search --query "address" --json', imsg.search(fx, "address"))
    elif t == "T4":
        s.shell(*_imsg_chats(s, 5))
        s.shells([_imsg_hist(s, 23, REACT_LIMIT), _imsg_hist(s, 19, REACT_LIMIT)])
        s.shell("imsg react --chat-id 19 --reaction like --json", imsg.react_result(19, "like"))
        s.step("grant", ACCESSIBILITY_SHELL)
        s.result("unverified", "System Events UI scripting from the Grok Bot shell")
    elif t == "T5":
        s.shell(*_imsg_select(s, "family"))
        s.shell("imsg send --chat-id 12 --file %s --json" % PHOTO, imsg.send_result(fx, 12))
        s.result("unverified", _osascript_note())


# ---------------- steve228uk (thin skill over imsg) ----------------

def _steve_hist(s, chat_id, limit):
    return "imsg history --chat-id %d --limit %d --json" % (chat_id, limit), imsg.history(s.fx, chat_id, limit)


def steve_tasks(s, t):
    fx = s.fx
    n, origin = overhead.file_tokens("steve228uk")
    s.skill("imessage-on-mac.md (%s)" % origin, n=n)
    chats20 = imsg.chats(fx, 20)
    if t == "T1":
        s.shell("imsg chats --limit 20 --json", chats20)
        s.shells([_steve_hist(s, c.rowid, len(fx.unread(c.rowid)) + UNREAD_EXTRA) for c in _unread_chats(fx)])
    elif t == "T2":
        s.shell("imsg chats --limit 20 --json", chats20)
        s.shell(*_steve_hist(s, 7, REPLY_LIMIT))
        s.step("widget", "question widget: Send this to Mom?", SEND_OK)
        s.shell('imsg send --to "%s" --text "%s" --service auto' % (MOM, REPLY),
                imsg.send_result(fx, 7, json_out=False))
        s.result("unverified", _osascript_note())
    elif t == "T3":
        s.shell('imsg search "address" --json', imsg.missing_option("query"))
        s.shell('imsg search --query "address" --json', imsg.search(fx, "address"))
        s.result("yes", "the documented positional search fails once")
    elif t == "T4":
        s.shell("imsg chats --limit 20 --json", chats20)
        s.shells([_steve_hist(s, 23, REACT_LIMIT), _steve_hist(s, 19, REACT_LIMIT)])
        s.shell("imsg react --help", imsg.help_text("react"))
        s.shell("imsg react --chat-id 19 --reaction like", imsg.react_result(19, "like", json_out=False))
        s.step("grant", ACCESSIBILITY_SHELL)
        s.result("unverified", "react is undocumented in the skill; System Events UI scripting")
    elif t == "T5":
        s.shell("imsg chats --limit 20 --json", chats20)
        s.shell("imsg send --help", imsg.help_text("send"))
        s.step("widget", "question widget: Send this photo to Family?", SEND_OK)
        s.shell("imsg send --chat-id 12 --file %s --service auto" % PHOTO, imsg.send_result(fx, 12, json_out=False))
        s.result("unverified", "file send is undocumented in the skill; " + _osascript_note())


# ---------------- Grok Bot built-in ----------------

def builtin_tasks(s, t):
    fx = s.fx
    s.context("built-in tool definitions (not available, counted as 0)", n=0)
    if t == "T1":
        since = fx.now_ns - 48 * 3600 * 10 ** 9
        act = gb.activity(fx, since)
        s.builtin("IMessageActivity since=48h", act)
        by_guid = {c.guid: c.rowid for c in fx.chats.values()}
        for entry in json.loads(act)["items"]:
            k = entry["count"] + UNREAD_EXTRA
            s.builtin("ChatItems chat=%s limit=%d" % (entry["chatGuid"], k),
                      gb.items(fx, by_guid[entry["chatGuid"]], limit=k))
        s.result("partial", "no unread state; reads every chat active in 48 h, its activity count plus %d items"
                 % UNREAD_EXTRA)
    elif t == "T2":
        hits = fx.resolve_person("Mom")
        s.builtin("FindContacts query=Mom", gb.find_contacts(fx, "Mom"))
        s.builtin("FindIMessageChats handle=%s" % MOM, gb.find_chats(fx, handle=MOM))
        s.builtin("ChatItems chat=%s limit=%d" % (fx.chats[7].guid, REPLY_LIMIT), gb.items(fx, 7, limit=REPLY_LIMIT))
        # `to` with service auto tries iMessage first. A chatId that starts with
        # `any;` would go out over SMS (research/grokbot.md, send behavior).
        s.builtin("SendIMessage to=%s service=auto" % MOM, gb.send(REPLY, to=MOM))
        s.step("consent", "Grok Bot send consent card")
        nick = any(p.get("nickname") == "Mom" for p in hits)
        s.result("yes", "assumes FindContacts matches the nickname" if nick else "")
    elif t == "T3":
        s.builtin("SearchIMessages needle=address", gb.search(fx, "address"))
        s.result("yes", _names_note(fx, DAD, "Dad"))
    elif t == "T4":
        s.result("no", "no tapback tool")
    elif t == "T5":
        s.result("no", "SendIMessage sends text only")


# ---------------- jeffhuber ----------------

def jeff_tasks(s, t):
    fx = s.fx
    n, origin = overhead.file_tokens("jeffhuber")
    s.skill("SKILL.md (%s)" % origin, n=n)
    if t in ("T4", "T5"):
        s.result("no", "host role has no tapbacks, group sends or files")
        return
    s.step("clarify", "which bridge folder?", "~/Library/Application Support/GrokBotIMessage")
    s.shell('ls -la "$BRIDGE/control/requests" "$BRIDGE/control/responses"', jh.ls_bridge())

    def req(action, params, out_fn):
        rid = jh.req_id("%s-%s-%s" % (t, action, sorted(params.items())))
        s.shell(jh.request_command(rid, action, params), out_fn(rid))

    req("status", {}, lambda rid: jh.status(fx, rid))
    if t == "T1":
        req("review", {"days": 2}, lambda rid: jh.review(fx, rid, 2))
        s.result("partial", "no unread state; triages the last 2 days")
    elif t == "T2":
        p = {"chat": "Mom", "days": 14, "limit": REPLY_LIMIT}
        req("chat_history", p, lambda rid: jh.chat_history(fx, rid, "Mom", limit=REPLY_LIMIT))
        notes = []
        if jh.resolve_filter("Mom", jh.contacts(fx)) == "Mom":
            full = _contact_name(fx, MOM)
            s.step("clarify", "Mom matched nothing. What is her name in Contacts?", full)
            p = {"chat": full, "days": 14, "limit": REPLY_LIMIT}
            req("chat_history", p, lambda rid: jh.chat_history(fx, rid, full, limit=REPLY_LIMIT))
            notes.append("contacts have no nicknames")
        req("send_preview", {"to": MOM, "text": REPLY, "service": "iMessage"},
            lambda rid: jh.send_preview(fx, rid, MOM, REPLY))
        s.step("approve", "show preview, wait for yes", SEND_OK)
        req("send", {"to": MOM, "text": REPLY, "service": "iMessage",
                     "send_nonce": jh.send_nonce(MOM, REPLY)},
            lambda rid: jh.send(fx, rid, MOM, REPLY))
        s.step("dialog", "native confirmation dialog")
        notes.append("group messages from Mom come along")
        s.result("yes", _join(*notes))
    elif t == "T3":
        req("search", {"term": "address", "days": 40, "limit": 100},
            lambda rid: jh.search(fx, rid, "address", 40))
        s.result("yes", _names_note(fx, DAD, "Dad"))


# ---------------- RyanNewsom ----------------

def ryan_tasks(s, t):
    fx = s.fx
    n, origin = overhead.file_tokens("ryannewsom")
    s.skill("SKILL.md (%s)" % origin, n=n)
    if t == "T1":
        s.shell("%s recent --hours 48" % rn.CMD, rn.recent(fx, 48))
        s.result("partial", "no unread state; last 5 messages per thread in 48 h")
    elif t == "T2":
        s.shell("%s thread --handle Mom --days 7 --limit %d" % (rn.CMD, REPLY_LIMIT),
                rn.thread(fx, "Mom", 7, REPLY_LIMIT))
        s.step("approve", "show recipient and text, wait for yes", SEND_OK)
        s.shell("osascript -e 'tell application \"Messages\" to send \"%s\" to participant \"%s\" "
                "of (1st account whose service type = iMessage)'" % (REPLY, MOM), rn.OSASCRIPT_OK)
        s.result("unverified", "raw osascript send; " + _osascript_note())
    elif t == "T3":
        s.shell("%s search --query address --days 40" % rn.CMD, rn.search(fx, "address", 40))
    elif t == "T4":
        s.result("no", "read-only helper; no tapbacks")
    elif t == "T5":
        s.shell('%s thread --handle "Family 🏡" --days 30 --limit 1' % rn.CMD, rn.thread(fx, "Family 🏡", 30, 1))
        s.step("approve", "show recipient and file, wait for yes", SEND_OK)
        s.shell("osascript -e 'tell application \"Messages\" to send (POSIX file \"%s\") to chat id "
                "\"any;+;chat836828054889214904\"'" % PHOTO_ABS, rn.OSASCRIPT_OK)
        s.result("unverified", "agent must build the chat GUID itself; " + _osascript_note())


# ---------------- jimmyliu03 ----------------

JIMMY_DEFAULT_LIMIT = 20  # BridgeToolbox.swift line 90


def jimmy_tasks(s, t):
    fx = s.fx
    s.context("MCP tool list (8 tools) and server instructions", jl.definitions_text())
    n, origin = overhead.file_tokens("jimmyliu03_skill")
    s.skill("apple-messages-reminders SKILL.md (%s)" % origin, n=n)
    if t == "T1":
        s.mcp("list_imessage_chats unread_only=true", jl.list_chats(fx, 20, True))
        for c in _unread_chats(fx):
            k = len(fx.unread(c.rowid)) + UNREAD_EXTRA
            s.mcp("read_imessage_history chat_id=%d limit=%d" % (c.rowid, k), jl.history(fx, c.rowid, k))
    elif t == "T2":
        s.mcp("list_imessage_chats", jl.list_chats(fx))
        s.step("clarify", "chat list has numbers only. Which one is Mom?", "+1 415-555-0101")
        s.mcp("read_imessage_history chat_id=7 limit=%d" % REPLY_LIMIT, jl.history(fx, 7, REPLY_LIMIT))
        s.step("approve", "confirm destination and text", SEND_OK)
        s.mcp("send_imessage chat_id=7", jl.approval_required(REPLY, 7))
        s.step("app-approve", "approve in Grok Bot Mac Bridge", APPROVED_IN_APP)
        s.mcp("send_imessage chat_id=7 (retry)", jl.send_ok())
        s.result("yes", "no names in the chat list")
    elif t == "T3":
        s.mcp("list_imessage_chats", jl.list_chats(fx))
        s.step("clarify", "chat list has numbers only. Which one is Dad?", "+1 415-555-0102")
        s.mcp("read_imessage_history chat_id=9", jl.history(fx, 9, JIMMY_DEFAULT_LIMIT))
        s.result("yes", "no search; scans the newest %d messages (the default)" % JIMMY_DEFAULT_LIMIT)
    elif t == "T4":
        s.result("no", "no tapback tool")
    elif t == "T5":
        s.result("no", "send_imessage is text only")


# ---------------- cmer ----------------

def cmer_tasks(s, t):
    fx = s.fx
    s.context("instructions the user pastes into Grok Bot", cmer.GROK_INSTRUCTIONS)
    if t in ("T4", "T5"):
        s.result("no", "send_message is text to one person; no tapbacks or files")
        return
    if t != "T1":
        s.shell(cmer.command(), cmer.listing())
    if t == "T1":
        s.shell(cmer.command("review_messages", "days=2"), cmer.review_messages(fx, 2))
        s.result("partial", "no unread state; triages the last 2 days")
    elif t == "T2":
        lim = "limit=%d" % REPLY_LIMIT
        out = cmer.get_conversation(fx, "Mom", limit=REPLY_LIMIT)
        s.shell(cmer.command("get_conversation", "chat=Mom", lim), out)
        notes = []
        if out.startswith("error: "):
            full = _contact_name(fx, MOM)
            s.step("clarify", "Mom matched nothing. What is her name in Contacts?", full)
            s.shell(cmer.command("get_conversation", "'chat=%s'" % full, lim),
                    cmer.get_conversation(fx, full, limit=REPLY_LIMIT))
            notes.append("contacts have no nicknames")
        s.step("approve", "show recipient and text, wait for yes", SEND_OK)
        s.shell(cmer.command("send_message", "'{\"to\": \"%s\", \"text\": \"%s\"}'" % (MOM, REPLY)),
                cmer.send_message(fx, MOM, REPLY))
        s.step("dialog", "native confirmation dialog")
        s.result("yes", _join(*notes))
    elif t == "T3":
        s.shell(cmer.command("search_messages", "query=address", "days=40"),
                cmer.search_messages(fx, "address", days=40))
        s.result("yes", _names_note(fx, DAD, "Dad"))


SCRIPTS = {
    "ours": ours_tasks, "imsg": imsg_tasks, "grokbot-builtin": builtin_tasks, "steve228uk": steve_tasks,
    "jeffhuber": jeff_tasks, "RyanNewsom": ryan_tasks, "jimmyliu03": jimmy_tasks, "cmer": cmer_tasks,
}


def run(fx, tool, task, ours_bin=None, opts=None):
    s = Session(fx, tool, task, ours_bin=ours_bin, opts=opts)
    SCRIPTS[tool](s, task)
    return s
