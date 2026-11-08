"""Renderer (a): the `imessage` CLI line format from DESIGN.md section 5 and
research/tokens.md section 5.

The CLI is not built yet. This module is the benchmark's reading of the
section 5 spec, so every "ours" number is a projection, not a measurement.

The functions take the parsed CLI arguments and return the exact text the CLI
would print. Write verbs return the result line the CLI prints after a send
or react; nothing is ever sent.
"""

import os
import re
import unicodedata


MAX_LINES = 200
MAX_BYTES = 12000
BODY_CUT = 400
SHOW_CAP = 8192
QUOTE_LEN = 30


def fmt_size(n):
    if n is None:
        return ""
    if n >= 1000000:
        return "%.1fMB" % (n / 1e6)
    if n >= 1000:
        return "%dKB" % round(n / 1e3)
    return "%dB" % n


def day_label(fx, dt):
    d = (fx.now.date() - dt.date()).days
    tail = dt.strftime("%a %b ") + str(dt.day)
    if d == 0:
        return "Today " + tail
    if d == 1:
        return "Yesterday " + tail
    if d < 7:
        return tail
    if dt.year == fx.now.year:
        return dt.strftime("%b ") + str(dt.day)
    return dt.strftime("%b ") + str(dt.day) + " " + str(dt.year)


def when_short(fx, dt, with_time_days=6):
    d = (fx.now.date() - dt.date()).days
    hm = dt.strftime("%H:%M")
    if d == 0:
        return hm
    if d == 1:
        return "Yesterday " + hm
    if d <= with_time_days:
        return dt.strftime("%a ") + hm
    if dt.year == fx.now.year:
        return dt.strftime("%b ") + str(dt.day)
    return dt.strftime("%b ") + str(dt.day) + " " + str(dt.year)


def chat_when(fx, dt):
    """Time column in `chats`: HH:MM today, then Yesterday, a weekday, a date."""
    d = (fx.now.date() - dt.date()).days
    if d == 0:
        return dt.strftime("%H:%M")
    if d == 1:
        return "Yesterday"
    if d <= 6:
        return dt.strftime("%a")
    if dt.year == fx.now.year:
        return dt.strftime("%b ") + str(dt.day)
    return dt.strftime("%b ") + str(dt.day) + " " + str(dt.year)


def member_names(fx, c, cap=None):
    names = [fx.short_name(h) for h in c.members]
    if cap and len(names) > cap + 1:
        return ", ".join(names[:cap]) + ", %d more" % (len(names) - cap)
    return ", ".join(names)


def chat_label(fx, c):
    if c.display_name:
        return c.display_name
    if c.is_group:
        return member_names(fx, c)
    if fx.person(c.identifier):
        p = fx.person(c.identifier)
        return p.get("nickname") or fx.full_name(c.identifier)
    if fx.short_name(c.identifier) == "You":
        return "You (notes)"
    return fx.short_name(c.identifier)


def chat_title(fx, c, with_you=True, cap=None):
    """`Family (group: Mom, Dad, You)`, or `group: Jordan, Taylor` when unnamed."""
    if not c.is_group:
        return chat_label(fx, c)
    members = member_names(fx, c, cap) + (", You" if with_you else "")
    if c.display_name:
        return "%s (group: %s)" % (c.display_name, members)
    return "group: " + members


def sender(fx, m):
    return "You" if m.from_me else fx.short_name(m.handle)


def visible(m):
    return not (m.is_tapback or m.is_placed_sticker or m.self_echo or m.duplicate_of)


def att_token(fx, a):
    kind = a.kind
    aid = "a%d" % a.rowid
    if kind == "photo":
        return "[photo %s %s]" % (aid, fmt_size(a.total_bytes))
    if kind == "video":
        return "[video %s %s]" % (aid, fmt_size(a.total_bytes))
    if kind == "voice":
        t = ' "%s"' % a.transcript if a.transcript else ""
        return "[voice %s%s]" % (aid, t)
    if kind == "sticker":
        return "[sticker %s]" % aid
    return "[file %s %s %s]" % (aid, a.transfer_name, fmt_size(a.total_bytes))


def one_line(text):
    return re.sub(r"\s*\n+\s*", " / ", text.strip())


def event_text(fx, m):
    actor = sender(fx, m)
    other = fx.short_name(m.other_handle) if m.other_handle else "someone"
    if m.item_type == 2:
        return '* %s renamed the group to "%s"' % (actor, m.group_title or "")
    if m.item_type == 1 and m.group_action_type == 0:
        return "* %s added %s" % (actor, other)
    if m.item_type == 1 and m.group_action_type == 1:
        return "* %s removed %s" % (actor, other)
    if m.item_type == 3:
        return "* %s left the group" % actor
    return "* %s group event %d" % (actor, m.item_type)


def reactions_token(fx, m):
    if not m.reactions and not m.stickers:
        return ""
    groups = []
    for e in sorted(m.reactions, key=lambda e: e["rowid"]):
        who = "You" if e["from_me"] else fx.short_name(e["handle"])
        for g in groups:
            if g[0] == e["emoji"]:
                g[1].append(who)
                break
        else:
            groups.append([e["emoji"], [who]])
    parts = ["%s%s" % (emo, ",".join(names)) for emo, names in groups]
    for s in m.stickers:
        parts.append("sticker by %s" % ("You" if s["from_me"] else fx.short_name(s["handle"])))
    return "[" + " ".join(parts) + "]"


def message_line(fx, m, on_screen=(), cut=BODY_CUT):
    dt = fx.dt(m.date_ns)
    head = "%d %s" % (m.rowid, dt.strftime("%H:%M"))
    if m.is_event:
        return head + " " + event_text(fx, m)
    bits = []
    if m.reply_rowid:
        r = "↩%d" % m.reply_rowid
        if m.reply_rowid not in on_screen:
            p = fx.by_rowid.get(m.reply_rowid)
            if p is not None:
                q = one_line(p.body)
                q = q[:QUOTE_LEN] + "…" if len(q) > QUOTE_LEN else q
                r += " (%s: %s)" % (sender(fx, p), q)
        bits.append(r)
    if m.unsent:
        bits.append("(unsent)")
        return head + " " + sender(fx, m) + ": " + " ".join(bits)
    text = one_line(m.body)
    if m.link and m.balloon and m.body.strip() == (m.link.get("url") or ""):
        site = m.link.get("site") or ""
        text = "[link %s: %s]" % (site, m.link.get("title") or "")
    elif len(text) > cut:
        extra = len(text) - cut
        text = text[:cut] + "…(+{:,} chars: imessage show {})".format(extra, m.rowid)
    if text:
        bits.append(text)
    for a in m.attachments:
        bits.append(att_token(fx, a))
    if m.unsent_parts:
        bits.append("(part unsent)")
    elif m.edited:
        bits.append("(edited)")
    if m.error:
        bits.append("(failed)")
    rt = reactions_token(fx, m)
    if rt:
        bits.append(rt)
    return head + " " + sender(fx, m) + ": " + " ".join(bits)


# ---------- target resolution ----------

class ResolveError(Exception):
    pass


def resolve(fx, who):
    w = who.strip()
    if re.fullmatch(r"\d{1,4}", w) and int(w) in fx.chats:
        return fx.chats[int(w)]
    if "@" in w or re.fullmatch(r"\+?[\d\s().-]{7,}", w):
        c = fx.direct_chat_for([w])
        if c:
            return c
        raise ResolveError('error: no chat with %s. fix: imessage chats' % w)
    people = fx.resolve_person(w)
    if len(people) == 1:
        c = fx.direct_chat_for(people[0]["handles"])
        if c:
            return c
    if len(people) > 1:
        names = ", ".join("%s (%s)" % (p.get("nickname") or p["first"], p["handles"][0]) for p in people)
        raise ResolveError('error: "%s" matches %d contacts: %s. fix: pass a chat id or phone' % (w, len(people), names))
    norm = unicodedata.normalize("NFC", w).casefold()
    groups = [c for c in fx.chats.values() if c.is_group and norm in chat_label(fx, c).casefold()]
    if len(groups) == 1:
        return groups[0]
    if groups:
        raise ResolveError('error: "%s" matches %d chats. fix: pass a chat id' % (w, len(groups)))
    raise ResolveError('error: no chat or contact matches "%s". fix: imessage chats' % w)


# ---------- verbs ----------

def chats(fx, n=20, unread=False):
    """One line per chat: id, title, unread count, then the newest message with
    its time, sender and first 60 characters (DESIGN.md section 5)."""
    rows = []
    for c in fx.chats_by_recent():
        u = len(fx.unread(c.rowid))
        if unread and not u:
            continue
        rows.append((c, u))
    out = []
    for c, u in rows[:n]:
        vis = [m for m in c.messages if visible(m)]
        last = vis[-1] if vis else None
        line = "%d %s" % (c.rowid, chat_title(fx, c, with_you=False, cap=3))
        if u > 1:
            line += " %d unread" % u
        if last is not None:
            dt = fx.dt(last.date_ns)
            if last.is_event:
                prev = event_text(fx, last)
            elif last.unsent:
                prev = "(unsent)"
            else:
                prev = one_line(last.body)
                if not prev and last.attachments:
                    prev = "[%s]" % last.attachments[0].kind
                prev = prev[:60] + "…" if len(prev) > 60 else prev
            if last.is_event:
                line += " · %s %s" % (when_short(fx, dt), prev)
            else:
                line += " · %s %s: %s" % (when_short(fx, dt), sender(fx, last), prev)
            if u == 1:
                line += " (unread)"
        if c.service and c.service != "iMessage":
            line += " (%s)" % c.service
        out.append(line)
    if len(rows) > n:
        # Section 5 gives `chats` no paging flag, so the footer asks for a longer list.
        out.append("more: imessage chats -n %d" % (n + 20))
    return "\n".join(out) + "\n"


def unread(fx, context=2):
    """`imessage unread [-c 2]`: every unread message across chats, grouped by
    chat, newest chat first. Each run of unread messages gets up to `context`
    earlier lines, then a `-- unread` marker. Day separators work as in `read`."""
    groups = []
    for c in fx.chats_by_recent():
        vis = [m for m in c.messages if visible(m)]
        want = set(m.rowid for m in fx.unread(c.rowid))
        idx = [i for i, m in enumerate(vis) if m.rowid in want]
        if idx:
            groups.append((c, vis, idx))
    total = sum(len(idx) for _, _, idx in groups)
    tz = fx.now.tzname()
    out = ["unread · %d message%s in %d chat%s · times %s" % (
        total, "" if total == 1 else "s", len(groups), "" if len(groups) == 1 else "s", tz)]
    size = len(out[0].encode()) + 1
    for c, vis, idx in groups:
        idx_set = set(idx)
        shown = set()
        run_starts = set()
        for k, i in enumerate(idx):
            if k == 0 or idx[k - 1] != i - 1:
                run_starts.add(i)
                shown.update(range(max(0, i - context), i))
            shown.add(i)
        order = sorted(shown)
        on_screen = set(vis[i].rowid for i in order)
        block = ["chat %d %s · %d unread" % (c.rowid, chat_title(fx, c), len(idx))]
        last_day, prev = None, None
        for i in order:
            m = vis[i]
            if prev is not None and i != prev + 1:
                block.append("…")
            dt = fx.dt(m.date_ns)
            if dt.date() != last_day:
                block.append("-- " + day_label(fx, dt))
                last_day = dt.date()
            if i in run_starts:
                block.append("-- unread")
            block.append(message_line(fx, m, on_screen))
            prev = i
        bsize = sum(len(x.encode()) + 1 for x in block)
        if len(out) + len(block) > MAX_LINES or size + bsize > MAX_BYTES:
            # Section 5 gives `unread` only `-c`, so the footer points at the first chat left out.
            out.append("more: imessage read %d" % c.rowid)
            break
        out += block
        size += bsize
    return "\n".join(out) + "\n"


def read(fx, who, n=30, before=None, after=None, around=None, since=None):
    try:
        c = resolve(fx, who)
    except ResolveError as e:
        return str(e) + "\n"
    vis = [m for m in c.messages if visible(m)]
    n = min(n, MAX_LINES)
    if before is not None:
        pool = [m for m in vis if m.rowid < before]
        window = pool[-n:]
    elif after is not None:
        pool = [m for m in vis if m.rowid > after]
        window = pool[:n]
    elif around is not None:
        idx = next((i for i, m in enumerate(vis) if m.rowid >= around), len(vis) - 1)
        lo = max(0, idx - n // 2)
        window = vis[lo:lo + n]
    else:
        window = vis[-n:]
    if since is not None:
        window = [m for m in window if m.date_ns >= since]
    on_screen = set(m.rowid for m in window)
    lines = []
    size = 0
    last_day = None
    kept = []
    for m in reversed(window):
        ln = message_line(fx, m, on_screen)
        if size + len(ln.encode()) + 40 > MAX_BYTES:
            break
        size += len(ln.encode()) + 1
        kept.append(m)
    kept.reverse()
    for m in kept:
        dt = fx.dt(m.date_ns)
        if dt.date() != last_day:
            lines.append("-- " + day_label(fx, dt))
            last_day = dt.date()
        lines.append(message_line(fx, m, on_screen))
    tz = fx.now.tzname()
    header = "chat %d %s · %d of %d · times %s" % (c.rowid, chat_title(fx, c), len(kept), len(vis), tz)
    out = [header] + lines
    if kept and vis and kept[0].rowid != vis[0].rowid:
        out.append("more: imessage read %d --before %d" % (c.rowid, kept[0].rowid))
    return "\n".join(out) + "\n"


def show(fx, rowid):
    m = fx.by_rowid.get(rowid)
    if m is None:
        return "error: no message %d. fix: imessage read <who>\n" % rowid
    c = fx.chats[m.chat]
    dt = fx.dt(m.date_ns)
    head = "%d %s %s in chat %d %s" % (m.rowid, day_label(fx, dt), dt.strftime("%H:%M"), c.rowid, chat_label(fx, c))
    body = m.body
    enc = body.encode()
    tail = ""
    if len(enc) > SHOW_CAP:
        body = enc[:SHOW_CAP].decode("utf-8", "ignore")
        tail = "\n…(+{:,} bytes: imessage show {} --from {})".format(len(enc) - SHOW_CAP, rowid, SHOW_CAP)
    return "%s\n%s: %s%s\n" % (head, sender(fx, m), body, tail)


def _fold(s):
    return unicodedata.normalize("NFC", s).casefold()


def search(fx, text, in_=None, since=None, n=20):
    chats_in = None
    if in_:
        try:
            chats_in = {resolve(fx, in_).rowid}
        except ResolveError as e:
            return str(e) + "\n"
    q = _fold(text)
    hits = [m for m in fx.messages if visible(m) and not m.is_event and q in _fold(m.body)
            and (chats_in is None or m.chat in chats_in) and (since is None or m.date_ns >= since)]
    hits.sort(key=lambda m: (-m.date_ns, -m.rowid))
    out = ['search "%s"%s · %d hit%s, newest first' % (
        text, (" in " + chat_label(fx, fx.chats[next(iter(chats_in))])) if chats_in else "",
        len(hits), "" if len(hits) == 1 else "s")]
    for m in hits[:n]:
        body = one_line(m.body)
        i = _fold(body).find(q)
        # About 120 characters around the match: research/tokens.md section 6,
        # "Avoiding whole-conversation dumps". DESIGN.md section 5 sets no snippet length.
        if len(body) > 120:
            lo = max(0, i - 40)
            snippet = body[lo:lo + 120]
            body = ("…" if lo else "") + snippet + ("…" if lo + 120 < len(body) else "")
        c = fx.chats[m.chat]
        out.append("%d %s · %s · %d %s: %s" % (c.rowid, chat_label(fx, c), when_short(fx, fx.dt(m.date_ns)),
                                              m.rowid, sender(fx, m), body))
    if len(hits) > n:
        out.append('more: imessage search "%s" --cursor %d' % (text, hits[n - 1].rowid))
    return "\n".join(out) + "\n"


def who(fx, name):
    people = fx.resolve_person(name)
    if not people:
        return 'error: no contact matches "%s". fix: imessage chats\n' % name
    out = []
    for p in people:
        handles = []
        for h in p["handles"]:
            services = sorted(set(fx.handles[i][1] for i in fx.handles if fx.handles[i][0] == h))
            label = reader_format(h)
            handles.append("%s (%s)" % (label, ", ".join(services)) if services else label)
        chats_with = []
        for c in fx.chats.values():
            if any(h in c.members for h in p["handles"]):
                chats_with.append("%d (direct)" % c.rowid if not c.is_group else "%d %s" % (c.rowid, chat_label(fx, c)))
        out.append("%s = %s %s · %s · chats: %s" % (
            p.get("nickname") or p["first"], p["first"], p.get("last", ""), " · ".join(handles), ", ".join(chats_with)))
    return "\n".join(out) + "\n"


def reader_format(h):
    d = re.sub(r"\D", "", h)
    if "@" not in h and len(d) == 11 and d.startswith("1"):
        return "+1 %s-%s-%s" % (d[1:4], d[4:7], d[7:])
    return h


def att(fx, aid):
    for m in fx.messages:
        for a in m.attachments:
            if a.rowid == aid:
                dims = " %dx%d" % (a.width, a.height) if a.width else ""
                if not a.on_disk:
                    return "error: a%d is in iCloud, not on this Mac. fix: open the chat in Messages to download it\n" % aid
                ext = ".jpg" if a.kind == "photo" else os.path.splitext(a.transfer_name)[1]
                return "a%d %s %s %s%s -> /tmp/imessage/a%d%s\n" % (aid, a.kind, a.transfer_name, fmt_size(a.total_bytes), dims, aid, ext)
    return "error: no attachment a%d\n" % aid


def _next_attachment_id(fx):
    return max(a.rowid for m in fx.messages for a in m.attachments) + 1


def send(fx, who, text=None, file=None, reply=None, new_rowid=None, approved=True):
    """Result of a send after the native approval. DESIGN.md section 2: the CLI
    prints `approved`, then the bridge's result line."""
    try:
        c = resolve(fx, who)
    except ResolveError as e:
        return str(e) + "\n"
    rid = new_rowid or (max(fx.by_rowid) + 1)
    parts = []
    if reply:
        parts.append("↩%d" % reply)
    if text:
        parts.append('"%s"' % text)
    if file:
        path = file if os.path.isabs(file) else os.path.join(fx.root, file)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        # The fixture photo is a stub; use the size chat.db records for it.
        for m in fx.messages:
            for a in m.attachments:
                if a.filename and path.endswith(a.filename.split("Attachments/", 1)[-1]):
                    size = a.total_bytes
        kind = "photo" if os.path.splitext(file)[1].lower() in (".heic", ".jpg", ".jpeg", ".png") else "file"
        parts.append("[%s a%d %s]" % (kind, _next_attachment_id(fx), fmt_size(size)))
    state = "submitted" if c.service == "SMS" else "delivered %s" % fx.now.strftime("%H:%M")
    head = "approved\n" if approved else ""
    return "%ssent %d to %s %s · %s\n" % (head, rid, chat_label(fx, c), " ".join(parts), state)


REACTION_EMOJI = {"love": "❤️", "like": "👍", "dislike": "👎", "laugh": "😂", "emphasize": "‼️", "question": "❓"}


def react(fx, rowid, reaction, approved=True):
    m = fx.by_rowid.get(rowid)
    if m is None:
        return "error: no message %d. fix: imessage read <who>\n" % rowid
    emoji = REACTION_EMOJI.get(reaction, reaction)
    body = one_line(m.body)
    q = body[:QUOTE_LEN] + "…" if len(body) > QUOTE_LEN else body
    head = "approved\n" if approved else ""
    return "%sreacted %s to %d (%s: %s) in chat %d · verified\n" % (head, emoji, rowid, sender(fx, m), q, m.chat)
