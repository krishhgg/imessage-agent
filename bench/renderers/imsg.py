"""Renderer (b): openclaw/imsg `--json` output, rebuilt from its Swift source.

Sources read (MIT, not executed): Sources/imsg/OutputModels.swift,
RPCPayloads.swift, JSONLines.swift, StdoutWriter.swift, HelpPrinter.swift and
Commands/{History,Chats,Send,React}Command.swift, plus IMsgCore queries.

- `history` and `search` print one JSONSerialization object per line, compact,
  with "/" escaped. The object is MessagePayload with nil fields dropped, plus
  chat_identifier, chat_guid, chat_name, participants and is_group.
- `chats` prints one JSONEncoder ChatPayload per line, compact, "/" not escaped.
- `| jq -s` (what imsg's SKILL.md tells the agent to append) turns the lines
  into one array printed with a 2-space indent.

steve228uk/grok-bot-imessage is a skill that drives this same CLI, so it reuses
this module.
"""

import datetime as _dt
import json

import jsonfmt
import reader

HOME = "/Users/alex"
REACTION_NAMES = reader.TAPBACK_NAME
REACTION_EMOJI = dict(reader.TAPBACK_EMOJI)


def iso_utc(ns):
    ms = ns // 1000000 + reader.APPLE_EPOCH * 1000
    t = _dt.datetime(1970, 1, 1) + _dt.timedelta(milliseconds=ms)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ms % 1000)


def display_name(fx, handle):
    """ContactResolver.displayName: the nickname, else given and family name."""
    if not handle:
        return None
    p = fx.person(handle)
    if not p:
        return None
    return p.get("nickname") or " ".join(x for x in (p.get("first"), p.get("last")) if x)


def _sender(m):
    if m.from_me:
        return m.dest_caller or m.handle or ""
    return m.handle or ""


def _excluded(m):
    t = m.assoc_type or 0
    return 2000 <= t <= 2006 or 3000 <= t <= 3006


def _reactions_index(fx):
    cache = getattr(fx, "_imsg_reactions", None)
    if cache is not None:
        return cache
    rows = {}
    for m in fx.messages:
        if _excluded(m) and getattr(m, "target_rowid", None):
            rows.setdefault(m.target_rowid, []).append(m)
    out = {}
    for target, lst in rows.items():
        lst.sort(key=lambda r: (r.date_ns, r.rowid))
        state = []
        for r in lst:
            kind = r.assoc_type % 1000
            emoji = r.assoc_emoji if kind == 6 else REACTION_EMOJI.get(kind)
            key = (_sender(r), r.from_me, kind, emoji if kind == 6 else None)
            state = [e for e in state if e[0] != key]
            if r.assoc_type < 3000:
                state.append((key, r, emoji))
        out[target] = [(r, kind_emoji) for _, r, kind_emoji in state]
    fx._imsg_reactions = out
    return out


def _reaction_payload(fx, r, emoji):
    kind = r.assoc_type % 1000
    d = {"id": r.rowid, "type": REACTION_NAMES[kind], "emoji": emoji, "sender": _sender(r)}
    if not r.from_me:
        n = display_name(fx, r.handle)
        if n:
            d["sender_name"] = n
    d["is_from_me"] = r.from_me
    d["created_at"] = iso_utc(r.date_ns)
    return d


def attachment_payload(a):
    path = a.filename or ""
    d = {
        "filename": path,
        "transfer_name": a.transfer_name or "",
        "uti": a.uti or "",
        "mime_type": a.mime_type or "",
        "total_bytes": a.total_bytes or 0,
        "is_sticker": bool(a.is_sticker),
        "original_path": path.replace("~", HOME, 1) if path.startswith("~") else path,
        "missing": not a.on_disk,
    }
    return d


def _previews(fx, chat_id):
    """URL preview rows that imsg folds into the text row before them."""
    folded = {}
    for m in fx.chats[chat_id].messages:
        if m.duplicate_of:
            folded[m.duplicate_of] = m
    return folded


def _plain_guid(g):
    if not g:
        return g
    if g.startswith("p:") and "/" in g:
        return g.split("/", 1)[1]
    if g.startswith("bp:"):
        return g[3:]
    return g


def message_payload(fx, m, with_extras=True, preview=None):
    c = fx.chats[m.chat]
    d = {"id": m.rowid, "chat_id": m.chat, "guid": m.guid}
    reply = _plain_guid(m.thread_guid) or (
        _plain_guid(m.assoc_guid) if m.assoc_guid and not _excluded(m) else None)
    if reply:
        d["reply_to_guid"] = reply
    if m.thread_guid:
        d["thread_originator_guid"] = m.thread_guid
    if m.thread_part:
        d["thread_originator_part"] = m.thread_part
    parent = fx.by_guid.get(reply) if reply else None
    if parent is not None and not m.from_me:
        d["reply_to_text"] = parent.text or ""
        if parent.handle:
            d["reply_to_sender"] = parent.handle
    d["sender"] = _sender(m)
    if not m.from_me:
        n = display_name(fx, m.handle)
        if n:
            d["sender_name"] = n
    d["is_from_me"] = m.from_me
    text = m.text or ""
    if m.is_audio and m.attachments and m.attachments[0].transcript:
        text = m.attachments[0].transcript
    d["text"] = "" if m.unsent else text
    d["created_at"] = iso_utc(m.date_ns)
    if with_extras and not m.unsent:
        d["attachments"] = [attachment_payload(a) for a in m.attachments]
        d["reactions"] = [_reaction_payload(fx, r, e) for r, e in _reactions_index(fx).get(m.rowid, [])]
    else:
        d["attachments"] = []
        d["reactions"] = []
    if m.dest_caller:
        d["destination_caller_id"] = m.dest_caller
    if m.balloon:
        d["balloon_bundle_id"] = m.balloon
    if preview is not None:
        d["url_preview"] = {"id": preview.rowid, "guid": preview.guid,
                            "balloon_bundle_id": preview.balloon, "created_at": iso_utc(preview.date_ns)}
    if not m.from_me:
        d["is_read"] = m.is_read
    if m.date_edited:
        d["edited_at"] = iso_utc(m.date_edited)
    if m.unsent:
        d["unsent_at"] = iso_utc(m.date_retracted or m.date_edited)
    if not m.from_me and m.is_read and m.date_read:
        d["date_read"] = iso_utc(m.date_read)
    d["chat_identifier"] = c.identifier
    d["chat_guid"] = c.guid
    d["chat_name"] = c.display_name or ""
    d["participants"] = sorted(c.members)
    d["is_group"] = ";+;" in c.guid or ";+;" in c.identifier
    return d


def _history_messages(fx, chat_id, limit=50):
    """MessageStore.messages(chatID:limit:): reactions dropped, URL previews
    folded into the text row before them, newest first."""
    rows = [m for m in fx.chats[chat_id].messages if not _excluded(m) and not m.duplicate_of]
    rows.sort(key=lambda m: (-m.date_ns, -m.rowid))
    return rows[:limit]


def history_rows(fx, chat_id, limit=50):
    previews = _previews(fx, chat_id)
    return [message_payload(fx, m, preview=previews.get(m.rowid)) for m in _history_messages(fx, chat_id, limit)]


def history_plain(fx, chat_id, limit=50):
    """`imsg history` without --json, from HistoryCommand.swift lines 95 to 116:
    `<ISO> [sent|recv] <sender>: <body>` per message, newest first, then
    `  (N attachment[s])` under any message that has attachments. The sender
    is the raw handle for your own rows and the Contacts name for others.
    Unsent rows print `[unsent]` and edited rows get an `[edited] ` prefix
    (decodeMessageRow: date_retracted and date_edited above 0). The fixture
    has no polls, so pollDisplayText never applies."""
    out = []
    for m in _history_messages(fx, chat_id, limit):
        direction = "sent" if m.from_me else "recv"
        raw = m.handle or ""
        if m.dest_caller and (m.from_me or not raw):
            raw = m.dest_caller
        who = raw if m.from_me else (display_name(fx, raw) or raw)
        unsent = (m.date_retracted or 0) > 0
        text = m.text or ""
        if not unsent and m.is_audio and m.attachments and m.attachments[0].transcript:
            text = m.attachments[0].transcript
        if unsent:
            body = "[unsent]"
        elif (m.date_edited or 0) > 0:
            body = "[edited] " + text
        else:
            body = text
        out.append("%s [%s] %s: %s" % (iso_utc(m.date_ns), direction, who, body))
        # HistoryCommand.swift prints the count whenever message_attachment_join
        # has rows for the message, unsent or not.
        n = len(m.attachments)
        if n > 0:
            out.append("  (%d attachment%s)" % (n, "" if n == 1 else "s"))
    return "".join(line + "\n" for line in out)


def search_rows(fx, query, limit=50):
    q = query.lower()
    rows = [m for m in fx.messages if not _excluded(m) and not m.duplicate_of and q in (m.text or "").lower()]
    rows.sort(key=lambda m: (-m.date_ns, -m.rowid))
    return [message_payload(fx, m, with_extras=False) for m in rows[:limit]]


def chat_payload(fx, c):
    d = {
        "id": c.rowid,
        "name": c.display_name or c.identifier,
        "identifier": c.identifier,
        "service": c.service,
        "last_message_at": iso_utc(fx.last_date(c.rowid)),
        "guid": c.guid,
        "display_name": c.display_name or "",
    }
    if not c.is_group:
        n = display_name(fx, c.identifier)
        if n is None and len(c.members) == 1:
            n = display_name(fx, c.members[0])
        if n:
            d["contact_name"] = n
    d["is_group"] = ";+;" in c.guid
    d["participants"] = sorted(c.members)
    for key, val in (("account_id", c.account_id), ("account_login", c.account_login),
                     ("last_addressed_handle", c.last_addressed_handle)):
        if val:
            d[key] = val
    u = len(fx.unread(c.rowid))
    if u:
        d["unread_count"] = u
    return d


def chat_rows(fx, limit=20, unread_only=False):
    order = sorted(fx.chats.values(), key=lambda c: (-fx.last_date(c.rowid), -c.rowid))
    if unread_only:
        order = [c for c in order if fx.unread(c.rowid)]
    return [chat_payload(fx, c) for c in order[:limit]]


# ---------- what the shell prints ----------

def ndjson_messages(rows):
    return "".join(jsonfmt.apple(r) + "\n" for r in rows)


def ndjson_chats(rows):
    return "".join(jsonfmt.swift(r, no_slash_escape=True) + "\n" for r in rows)


def jq_slurp(rows):
    """`| jq -s`: one array, 2-space indent, "/" unescaped, UTF-8 kept."""
    return json.dumps(rows, indent=2, ensure_ascii=False) + "\n"


def jq_each(rows):
    """`| jq -s '.[] | select(...)'`: each match printed on its own."""
    return "".join(json.dumps(r, indent=2, ensure_ascii=False) + "\n" for r in rows)


def history(fx, chat_id, limit=50, jq=False, plain=False):
    if plain:
        return history_plain(fx, chat_id, limit)
    rows = history_rows(fx, chat_id, limit)
    return jq_slurp(rows) if jq else ndjson_messages(rows)


def chats(fx, limit=20, unread_only=False, jq=False, select=None):
    rows = chat_rows(fx, limit, unread_only)
    if select is not None:
        s = select.lower()
        picked = []
        for r in rows:
            # jq: .contact_name // .display_name // .name // .identifier // ""
            v = next((r[k] for k in ("contact_name", "display_name", "name", "identifier")
                      if r.get(k) is not None), "")
            if s in v.lower():
                picked.append(r)
        return jq_each(picked)
    return jq_slurp(rows) if jq else ndjson_chats(rows)


def chats_plain(fx, limit=20):
    """`imsg chats` without --json, from ChatsCommand.swift lines 69 to 81:
    `[<id>] <name> (<identifier>) last=<ISO>` per chat, newest first. The name
    is contactNameForChat with no chatInfo, so the group test looks at the
    identifier only, then falls back to the chat's name. No unread count."""
    order = sorted(fx.chats.values(), key=lambda c: (-fx.last_date(c.rowid), -c.rowid))
    out = []
    for c in order[:limit]:
        name = None
        if ";+;" not in c.identifier:
            name = display_name(fx, c.identifier)
            if name is None and len(c.members) == 1:
                name = display_name(fx, c.members[0])
        out.append("[%d] %s (%s) last=%s" % (c.rowid, name or c.display_name or c.identifier, c.identifier,
                                             iso_utc(fx.last_date(c.rowid))))
    return "".join(line + "\n" for line in out)


def search(fx, query, limit=50):
    return ndjson_messages(search_rows(fx, query, limit))


def search_plain(fx, query, limit=50):
    """`imsg search` without --json (BridgeIntroCommands.swift lines 71 to 77):
    `<ISO> [sent|recv] <sender>: <text>` per match, newest first, with the
    same sender rules as history_plain. Unsent rows print empty text."""
    q = query.lower()
    rows = [m for m in fx.messages if not _excluded(m) and not m.duplicate_of and q in (m.text or "").lower()]
    rows.sort(key=lambda m: (-m.date_ns, -m.rowid))
    out = []
    for m in rows[:limit]:
        direction = "sent" if m.from_me else "recv"
        raw = m.handle or ""
        if m.dest_caller and (m.from_me or not raw):
            raw = m.dest_caller
        who = raw if m.from_me else (display_name(fx, raw) or raw)
        text = "" if (m.date_retracted or 0) > 0 else (m.text or "")
        out.append("%s [%s] %s: %s" % (iso_utc(m.date_ns), direction, who, text))
    return "".join(line + "\n" for line in out)


def send_result(fx, chat_id, new_rowid=None, json_out=True):
    rid = new_rowid or (max(fx.by_rowid) + 1)
    guid = "E4C2A8D0-7B1F-4C3E-9A55-1D2F3B4C5D6E"
    if not json_out:
        return "sent\n"
    return jsonfmt.apple({"status": "sent", "id": rid, "guid": guid, "message_id": guid}) + "\n"


def react_result(chat_id, reaction="like", json_out=True):
    kind = {v: k for k, v in REACTION_NAMES.items()}[reaction]
    emoji = REACTION_EMOJI[kind]
    if not json_out:
        return "Sent %s reaction to chat %d\n" % (emoji, chat_id)
    return jsonfmt.swift({"success": True, "chat_id": chat_id, "reaction_type": reaction,
                          "reaction_emoji": emoji}, no_slash_escape=True) + "\n"


def missing_option(name):
    return "Missing required option: --%s\n" % name


# ---------- help text (HelpPrinter.renderCommand) ----------

DB_OPT = ("--db <value>", "Path to chat.db (defaults to ~/Library/Messages/chat.db)")
# Commander adds these runtime flags; the exact help strings live in the
# Commander package, which is not vendored in the repo. Approximated.
RUNTIME_OPTS = [("--log-level <value>", "Set log level (trace|debug|info|warn|error|critical)")]
RUNTIME_FLAGS = [("-v, --verbose", "Enable verbose logging"), ("--json", "Emit machine-readable JSON output")]

SPECS = {
    "send": {
        "abstract": "Send a message (text and/or attachment)",
        "discussion": None,
        "options": [
            DB_OPT,
            ("--to <value>", "phone number or email"),
            ("--chat-id <value>", "chat rowid"),
            ("--chat-identifier <value>", "chat identifier (e.g. iMessage;+;chat...)"),
            ("--chat-guid <value>", "chat guid"),
            ("--text <value>", "message body"),
            ("--file <value>", "path to attachment"),
            ("--service <value>", "service to use: imessage|sms|auto"),
            ("--region <value>", "default region for phone normalization"),
        ],
        "flags": [("--no-sms-fallback", "disable automatic iMessage->SMS fallback for text-only auto phone sends")],
        "examples": [
            'imsg send --to +14155551212 --text "hi"',
            'imsg send --to +14155551212 --text "hi" --file ~/Desktop/pic.jpg --service imessage',
            'imsg send --chat-id 1 --text "hi"',
        ],
    },
    "react": {
        "abstract": "Send a standard tapback through Messages UI automation",
        "discussion": (
            "Sends a standard tapback using Messages' last-or-selected-message shortcut.\n"
            "\n"
            "IMPORTANT LIMITATIONS:\n"
            "- Cannot reliably select a specific message; use bridge tapback for GUID targeting\n"
            "- Requires Messages.app to be running\n"
            "- The chat must exist in Messages' live AppleScript chats collection\n"
            "- Uses UI automation (System Events) which requires accessibility permissions\n"
            "- Opens the conversation directly and requires a visible, enabled Tapback button\n"
            "- Reports success only after a new outgoing reaction is recorded in the requested chat\n"
            "- If confirmation fails, inspect Messages before retrying; a retry may toggle a reaction\n"
            "\n"
            "Reaction types:\n"
            "  love (❤️), like (👍), dislike (👎), laugh (😂), emphasis (‼️), question (❓)\n"
            "\n"
            "Custom emoji tapbacks can be read from history/watch output, but cannot be\n"
            "sent reliably through Messages.app AppleScript automation."
        ),
        "options": [
            DB_OPT,
            ("--chat-id <value>", "chat rowid to react in"),
            ("--reaction, -r <value>", "reaction type: love, like, dislike, laugh, emphasis, question"),
        ],
        "flags": [],
        "examples": ["imsg react --chat-id 1 --reaction like", "imsg react --chat-id 1 -r love"],
    },
}


def help_text(name):
    s = SPECS[name]
    lines = ["imsg " + name, s["abstract"]]
    if s["discussion"]:
        lines.append("\n" + s["discussion"])
    lines += ["", "Usage:", "  imsg %s [options]" % name, "", "Options:"]
    for names, h in s["options"] + RUNTIME_OPTS:
        lines.append("  %s\t%s" % (names, h))
    for names, h in s["flags"] + RUNTIME_FLAGS:
        lines.append("  %s\t%s" % (names, h))
    lines.append("")
    lines.append("Examples:")
    for e in s["examples"]:
        lines.append("  " + e)
    return "\n".join(lines) + "\n"


SKILL_PATH = "/tmp/s5-openclaw_imsg/src/.agents/skills/imsg/SKILL.md"
