"""Renderer (d): RyanNewsom/grokbot-imessage-reader, `imsg-read` output.

Rebuilt from Sources/main.swift (MIT, read, not run). Every command prints one
JSONSerialization object with sorted keys, compact, "/" escaped.

- A message is {attachment_count, chat_contact_name, chat_identifier,
  chat_name, date, is_from_me, sender, sender_name, text}. The date is local
  ISO 8601 with an offset. Text is the text column, else a heuristic
  attributedBody decode, so U+FFFC stays in. Rows with no text and no
  attachment are dropped. Tapback rows are kept, with text like
  'Laughed at "..."'.
- Contacts give "First Last". A name query matches full name, nickname or
  organization exactly, then falls back to first name.
- The tool reads only. Sending is a raw osascript call from the Grok Bot
  shell, which the skill tells the agent to run after a yes.
"""

import jsonfmt
import reader

RECENT_PER_THREAD = 5
MAX_THREADS = 40
DEFAULT_LIMIT = 200
CMD = "~/.local/bin/imsg-read"


def _key(h):
    if not h:
        return None
    t = h.strip()
    if "@" in t:
        return "e:" + t.lower()
    digits = "".join(ch for ch in t if ch.isdigit())
    if t and all(ch in "0123456789+-(). " for ch in t) and len(digits) >= 10:
        return "p:" + digits[-10:]
    return None


class Contacts(object):
    def __init__(self, fx):
        self.records = []
        self.name_by_key = {}
        for p in fx.contacts["people"]:
            full = " ".join(x for x in (p.get("first"), p.get("last")) if x)
            names = set(n.lower() for n in (full, p.get("nickname"), p.get("org")) if n)
            keys = set(k for k in (_key(h) for h in p["handles"]) if k)
            self.records.append({"display": full, "names": names,
                                 "first": (p.get("first") or "").lower(), "keys": keys})
        for r in sorted(self.records, key=lambda r: r["display"]):
            for k in r["keys"]:
                self.name_by_key.setdefault(k, r["display"])

    def name(self, h):
        k = _key(h)
        return self.name_by_key.get(k) if k else None

    def clusters(self, q):
        n = " ".join(q.lower().split())
        hits = [r for r in self.records if n in r["names"]]
        if not hits:
            hits = [r for r in self.records if r["first"] == n]
        return sorted(hits, key=lambda r: r["display"])


def _date(fx, ns):
    return fx.dt(ns).isoformat(timespec="seconds")


def _text(m):
    if m.raw_text_column:
        return m.raw_text_column
    return (m.text or "").strip()


def _msg(fx, cts, m):
    c = fx.chats[m.chat]
    sender = "me" if m.from_me else (m.handle or "")
    return {
        "date": _date(fx, m.date_ns), "text": _text(m), "is_from_me": m.from_me, "sender": sender,
        "sender_name": None if m.from_me else cts.name(m.handle or ""),
        "chat_contact_name": cts.name(c.identifier),
        "chat_name": c.display_name or c.identifier, "chat_identifier": c.identifier,
        "attachment_count": len(m.attachments),
    }


def _keep(m):
    return bool(_text(m)) or bool(m.attachments)


def _newest(rows):
    return sorted(rows, key=lambda m: (-m.date_ns, -m.rowid))


def _emit(obj):
    return jsonfmt.apple(obj, sort_keys=True) + "\n"


def recent(fx, hours=24, limit=DEFAULT_LIMIT):
    cts = Contacts(fx)
    cut = fx.now_ns - hours * 3600 * 10 ** 9
    last = {}
    for m in fx.messages:
        if m.date_ns >= cut:
            last[m.chat] = max(last.get(m.chat, 0), m.date_ns)
    per = max(1, min(RECENT_PER_THREAD, limit))
    threads = []
    for chat_id in sorted(last, key=lambda k: -last[k]):
        if len(threads) >= MAX_THREADS:
            break
        rows = [m for m in _newest(fx.chats[chat_id].messages) if m.date_ns >= cut and _keep(m)][:per]
        if not rows:
            continue
        c = fx.chats[chat_id]
        threads.append({"chat_name": c.display_name or c.identifier, "chat_identifier": c.identifier,
                        "chat_contact_name": cts.name(c.identifier),
                        "messages": [_msg(fx, cts, m) for m in reversed(rows)]})
    return _emit({"ok": True, "command": "recent", "hours": hours, "threads": threads, "blocked_count": 0})


def search(fx, query, days=30, limit=DEFAULT_LIMIT):
    cts = Contacts(fx)
    cut = fx.now_ns - days * 86400 * 10 ** 9
    scan = max(limit * 20, 2000)
    cand = [m for m in _newest(fx.messages) if m.date_ns >= cut and _keep(m)][:scan]
    q = query.lower()
    hits = [m for m in cand if q in _text(m).lower()][:limit]
    return _emit({"ok": True, "command": "search", "query": query, "days": days,
                  "messages": [_msg(fx, cts, m) for m in hits], "blocked_count": 0})


def thread(fx, handle, days=30, limit=DEFAULT_LIMIT):
    cts = Contacts(fx)
    cut = fx.now_ns - days * 86400 * 10 ** 9
    direct = any(c.identifier == handle or (c.display_name or "").lower() == handle.lower()
                 for c in fx.chats.values())
    by_key = {}
    for hid in sorted(fx.handles):
        h = fx.handles[hid][0]
        k = _key(h)
        if k and h not in by_key.setdefault(k, []):
            by_key[k].append(h)
    hset, resolved = {handle}, None
    if _key(handle):
        hset |= set(by_key.get(_key(handle), []))
    elif not direct:
        usable = []
        for r in cts.clusters(handle):
            hh = sorted(h for k in r["keys"] for h in by_key.get(k, []))
            if hh:
                usable.append((r["display"], hh))
        if len(usable) > 1:
            return _emit({"ok": False, "command": "thread", "ambiguous": True,
                          "error": "contact name '%s' matches %d contacts; retry with one of the candidate handles"
                          % (handle, len(usable)),
                          "candidates": [{"name": n, "handles": hh} for n, hh in usable], "blocked_count": 0})
        if usable:
            resolved = usable[0][0]
            hset = set(usable[0][1])
    hs = sorted(hset)

    def match(m):
        c = fx.chats[m.chat]
        members = set(c.members)
        return (m.handle in hset or c.identifier in hset
                or (c.display_name or "").lower() == handle.lower() or bool(members & hset))

    rows = [m for m in _newest(fx.messages) if m.date_ns >= cut and match(m) and _keep(m)][:limit]
    r = {"ok": True, "command": "thread", "handle": handle, "days": days,
         "messages": [_msg(fx, cts, m) for m in reversed(rows)], "blocked_count": 0}
    if resolved:
        r["resolved_contact_name"] = resolved
        r["resolved_handles"] = hs
    return _emit(r)


OSASCRIPT_OK = ""  # osascript prints nothing when `send` succeeds.
