"""Renderer (c): Grok Bot's built-in iMessage tools (0.79.2, unreleased).

Rebuilt from app/dist/local-exec-daemon/messages-worker.cjs (read, not run):
the `ti` item query, `us`/`mr` body decoding, `fi`/`xs`/`Is` mappers, `dt`
paging (newest `limit` items, 64,000-character budget, returned oldest first),
`Ke` people map and the find-chats, activity, find-contacts and send results.

Results are JSON.stringify output with no spacing. That the host passes them
to the model unchanged is an assumption.
"""

import jsonfmt
import reader
from renderers.imsg import iso_utc as iso
from typedstream import utf16_slice

OBJ = reader.OBJ
LIMITS = {"items": (50, 200), "search": (25, 100), "find-chats": (50, 500)}
BUDGET = 64000
PEOPLE_CAP = 200


def _target_guid(g):
    if not g:
        return None
    i = g.rfind("/")
    return g[i + 1:] if i >= 0 else (g[3:] if g.startswith("bp:") else g)


def _body(m):
    text = m.text or ""
    if m.runs:
        runs = []
        for start, length, attrs in m.runs:
            r = {"text": utf16_slice(text, start, length).replace(OBJ, "")}
            mention = attrs.get("__kIMMentionConfirmedMention")
            if isinstance(mention, str):
                r["mention"] = mention
            part = attrs.get("__kIMMessagePartAttributeName")
            if isinstance(part, (int, float)) and not isinstance(part, bool):
                r["part"] = int(part)
            runs.append(r)
        return {"text": text.replace(OBJ, ""), "runs": runs, "fallback": False}
    return {"text": text, "runs": [{"text": text}] if text else [], "fallback": False}


def _tapbacks(fx):
    cache = getattr(fx, "_gb_tapbacks", None)
    if cache is not None:
        return cache
    state = {}
    rows = sorted((m for m in fx.messages if m.is_tapback), key=lambda m: (m.date_ns, m.rowid))
    for m in rows:
        g = _target_guid(m.assoc_guid)
        if not g:
            continue
        handle = m.handle or None
        emoji = m.assoc_emoji or None
        if m.assoc_type < 3000:
            e = {"type": m.assoc_type, "fromMe": m.from_me, "date": iso(m.date_ns)}
            if emoji:
                e["emoji"] = emoji
            if handle:
                e["handle"] = handle
            state.setdefault(g, []).append(e)
        else:
            lst = state.get(g)
            if not lst:
                continue
            for i in range(len(lst) - 1, -1, -1):
                x = lst[i]
                if x["type"] == m.assoc_type - 1000 and x["fromMe"] == m.from_me \
                        and x.get("handle") == handle and x.get("emoji") == emoji:
                    del lst[i]
                    break
    fx._gb_tapbacks = state
    return state


def _attachment(a):
    d = {"id": a.rowid, "guid": a.guid}
    if a.filename:
        d["filename"] = a.filename.rsplit("/", 1)[-1]
    for k, v in (("transferName", a.transfer_name), ("mime", a.mime_type), ("uti", a.uti),
                 ("totalBytes", a.total_bytes)):
        if v is not None:
            d[k] = v
    return d


def item(fx, m):
    c = fx.chats[m.chat]
    if m.is_event:
        d = {"kind": "event", "id": m.rowid, "guid": m.guid, "chatGuid": c.guid,
             "date": iso(m.date_ns), "itemType": m.item_type}
        d["groupActionType"] = m.group_action_type
        if m.group_title:
            d["groupTitle"] = m.group_title
        if m.handle:
            d["handle"] = m.handle
        return d
    d = {"kind": "message", "id": m.rowid, "guid": m.guid, "chatGuid": c.guid, "date": iso(m.date_ns),
         "fromMe": m.from_me, "service": m.service, "body": _body(m),
         "tapbacks": list(_tapbacks(fx).get(m.guid, [])),
         "attachments": [_attachment(a) for a in m.attachments]}
    if m.handle:
        d["handle"] = m.handle
    if m.thread_guid:
        # The worker reads the reply_to_guid column here; the fixture stores
        # the same parent guid in thread_originator_guid.
        d["replyToGuid"] = m.thread_guid
        d["threadOriginatorGuid"] = m.thread_guid
    if m.date_edited:
        d["edited"] = {"date": iso(m.date_edited)}
    if m.date_retracted:
        d["unsent"] = {"date": iso(m.date_retracted)}
    return d


def _page(items, limit, kind):
    default, cap = LIMITS[kind]
    n = min(max(1, limit or default), cap)
    taken, size, cause = [], 2, None
    for it in reversed(items):
        if len(taken) >= n:
            cause = "limit"
            break
        add = len(jsonfmt.js(it)) + (1 if taken else 0)
        if taken and size + add > BUDGET:
            cause = "bytes"
            break
        taken.append(it)
        size += add
    taken.reverse()
    out = {"page": taken, "total": len(items)}
    if cause and taken:
        out["truncated"] = cause
        out["nextBefore"] = {"date": taken[0]["date"], "id": taken[0]["id"]}
    return out


def _people(fx, handles):
    """resolveHandles: assumed to return the Contacts display name, First Last."""
    out = {}
    for h in handles[:PEOPLE_CAP]:
        n = fx.full_name(h)
        if n:
            out[h] = n
    return out


def _with_people(fx, result, handles):
    seen = []
    for h in handles:
        if h and h not in seen:
            seen.append(h)
    p = _people(fx, seen)
    if p:
        result["people"] = p
    return result


def _item_handles(items):
    hs = []
    for it in items:
        hs.append(it.get("handle"))
        if it["kind"] == "message":
            hs += [r.get("mention") for r in it["body"]["runs"]]
            hs += [t.get("handle") for t in it["tapbacks"]]
    return hs


def _chat_items(fx, chat_id):
    rows = [m for m in fx.chats[chat_id].messages if not m.is_tapback]
    rows.sort(key=lambda m: (m.date_ns, m.rowid))
    return [item(fx, m) for m in rows]


def items(fx, chat_id, limit=None):
    p = _page(_chat_items(fx, chat_id), limit, "items")
    res = {"kind": "items", "items": p.pop("page")}
    res.update(p)
    return jsonfmt.js(_with_people(fx, res, _item_handles(res["items"])))


def search(fx, needle, limit=None):
    q = needle.lower()
    rows = [m for m in fx.messages if not m.is_tapback and not m.is_event and q in (m.text or "").replace(OBJ, "").lower()]
    rows.sort(key=lambda m: (m.date_ns, m.rowid))
    p = _page([item(fx, m) for m in rows], limit, "search")
    res = {"kind": "search", "items": p.pop("page")}
    res.update(p)
    return jsonfmt.js(_with_people(fx, res, _item_handles(res["items"])))


def _chat(fx, c):
    d = {"id": c.rowid, "guid": c.guid, "identifier": c.identifier}
    if c.display_name:
        d["displayName"] = c.display_name
    d["service"] = c.service
    d["handles"] = [fx.handles[h][0] for h in c.member_ids]
    last = fx.last_date(c.rowid)
    if last:
        d["lastDate"] = iso(last)
    return d


def find_chats(fx, display_name=None, handle=None, limit=None):
    chats = []
    for c in fx.chats.values():
        d = _chat(fx, c)
        if display_name and (c.display_name or "") != display_name:
            continue
        if handle and handle not in d["handles"] and c.identifier != handle:
            continue
        chats.append(d)
    chats.sort(key=lambda d: d.get("lastDate", ""), reverse=True)
    default, cap = LIMITS["find-chats"]
    n = min(max(1, limit or default), cap)
    res = {"kind": "find-chats", "chats": chats[:n], "total": len(chats)}
    if len(chats) > n:
        res["truncated"] = "limit"
    hs = [h for d in res["chats"] for h in d["handles"]]
    return jsonfmt.js(_with_people(fx, res, hs))


def activity(fx, since_ns, until_ns=None):
    counts = {}
    for m in fx.messages:
        if m.is_tapback or m.is_event or m.date_ns < since_ns or (until_ns and m.date_ns >= until_ns):
            continue
        cnt, last = counts.get(m.chat, (0, 0))
        counts[m.chat] = (cnt + 1, max(last, m.date_ns))
    order = sorted(counts.items(), key=lambda kv: -kv[1][1])
    out = []
    for chat_id, (cnt, _) in order:
        c = fx.chats[chat_id]
        d = {"chatGuid": c.guid, "count": cnt, "handles": [fx.handles[h][0] for h in c.member_ids]}
        if c.display_name:
            d["displayName"] = c.display_name
        out.append(d)
    res = {"kind": "activity", "items": out}
    return jsonfmt.js(_with_people(fx, res, [h for d in out for h in d["handles"]]))


def find_contacts(fx, query, limit=25):
    people = fx.resolve_person(query)
    contacts = []
    for p in people[:limit]:
        phones = [reader.normalize_handle(h) for h in p["handles"] if "@" not in h]
        emails = [h.lower() for h in p["handles"] if "@" in h]
        name = " ".join(x for x in (p.get("first"), p.get("last")) if x)
        contacts.append({"name": name, "phones": phones, "emails": emails})
    res = {"kind": "find-contacts", "region": "US", "total": len(people)}
    if len(people) > len(contacts):
        res["truncated"] = "limit"
    res["contacts"] = contacts
    return jsonfmt.js(res)


def send(text, chat_id=None, to=None):
    res = {"kind": "send", "text": text}
    if chat_id is not None:
        res["chatId"] = chat_id
    else:
        res["to"] = to
    res.update({"service": "iMessage", "via": "applescript", "verified": True})
    return jsonfmt.js(res)
