"""Capture the golden output of bench/renderers/ours.py on the fixture.

For every case this writes two files into this folder:
- <case>.txt: the exact text ours.py prints.
- <case>.json: the page record (Sources/IMCore/Pages.swift) that IMCoreTests decode and render with Format.

Only the success output of chats, unread, read, show and who is captured. Run it from the repo root with:

    python3 -I Tests/Fixtures/golden/capture.py

It needs only the standard library. Output is deterministic, so a second run writes the same bytes.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
BENCH = os.path.join(ROOT, "bench")
sys.path.insert(0, BENCH)

import reader  # noqa: E402
from renderers import ours  # noqa: E402

URL_BALLOON = "com.apple.messages.URLBalloonProvider"
KIND_NAME = {0: "heart", 1: "like", 2: "dislike", 3: "laugh", 4: "emphasize", 5: "question"}


def canonical(fx, c):
    if c.is_group:
        return "group:" + c.identifier
    return "handle:" + reader.normalize_handle(c.identifier)


def attachment_record(a):
    return {
        "rowid": a.rowid, "guid": a.guid, "kind": a.kind, "transferName": a.transfer_name or "",
        "mimeType": a.mime_type, "uti": a.uti, "totalBytes": a.total_bytes, "width": a.width,
        "height": a.height, "transcript": a.transcript, "onDisk": a.on_disk,
        "transferState": a.transfer_state if a.transfer_state is not None else 0,
    }


def strip_none(d):
    return {k: v for k, v in d.items() if v is not None}


def part_count(m):
    parts = set()
    for _, _, attrs in m.runs or []:
        p = attrs.get("__kIMMessagePartAttributeName")
        if p is not None:
            parts.add(int(p))
    return max(1, len(parts))


def message_record(fx, m):
    rec = {
        "rowid": m.rowid, "guid": m.guid, "chatRowID": m.chat, "dateNs": m.date_ns, "fromMe": m.from_me,
        "senderName": ours.sender(fx, m), "senderHandle": m.handle, "service": m.service, "text": m.body,
        "attachments": [strip_none(attachment_record(a)) for a in m.attachments],
        "edited": bool(m.edited), "unsent": bool(m.unsent), "partUnsent": bool(m.unsent_parts),
        "errorCode": m.error, "isRead": m.is_read, "dateDeliveredNs": m.date_delivered,
        "dateReadNs": m.date_read, "dateEditedNs": m.date_edited, "partCount": part_count(m),
        "agentSent": False,
    }
    if m.reply_rowid:
        p = fx.by_rowid[m.reply_rowid]
        rec["replyTo"] = {"rowid": p.rowid, "senderName": ours.sender(fx, p), "text": ours.one_line(p.body)}
    rec["reactions"] = []
    for e in sorted(m.reactions, key=lambda e: e["rowid"]):
        kind = e["emoji"] if e["kind"] == 6 else KIND_NAME[e["kind"]]
        rec["reactions"].append({
            "kind": kind, "actorName": "You" if e["from_me"] else fx.short_name(e["handle"]),
            "fromMe": e["from_me"], "part": e["part"], "rowid": e["rowid"],
        })
    rec["stickers"] = [{
        "actorName": "You" if s["from_me"] else fx.short_name(s["handle"]), "fromMe": s["from_me"],
        "part": s["part"], "rowid": s["rowid"],
    } for s in m.stickers]
    if m.is_event:
        if m.item_type == 2:
            kind = "renamed"
        elif m.item_type == 1 and m.group_action_type == 0:
            kind = "added"
        elif m.item_type == 1 and m.group_action_type == 1:
            kind = "removed"
        elif m.item_type == 3:
            kind = "left"
        else:
            kind = "other"
        rec["event"] = strip_none({
            "kind": kind, "actorName": ours.sender(fx, m),
            "otherName": fx.short_name(m.other_handle) if m.other_handle else None,
            "title": m.group_title, "itemType": m.item_type, "groupActionType": m.group_action_type,
        })
    if m.link and m.balloon == URL_BALLOON:
        rec["link"] = strip_none({"url": m.link.get("url"), "site": m.link.get("site"), "title": m.link.get("title")})
    return strip_none(rec)


def visible(c):
    return [m for m in c.messages if ours.visible(m)]


def chat_record(fx, c):
    vis = visible(c)
    rec = {
        "rowid": c.rowid, "guid": c.guid, "identifier": c.identifier, "canonical": {"rawValue": canonical(fx, c)},
        "displayName": c.display_name, "label": ours.chat_label(fx, c), "isGroup": c.is_group,
        "memberNames": [fx.short_name(h) for h in c.members], "service": c.service or "",
        "unreadCount": len(fx.unread(c.rowid)), "mergedChatRowIDs": [c.rowid],
    }
    if vis:
        rec["last"] = message_record(fx, vis[-1])
    return rec


def chat_ref(fx, c):
    return {"rowid": c.rowid, "label": ours.chat_label(fx, c), "isGroup": c.is_group}


# ---------- pages, built the way ours.py selects records ----------

def chats_page(fx, n=20, unread=False):
    rows = [c for c in fx.chats_by_recent() if not (unread and not fx.unread(c.rowid))]
    return {"chats": [chat_record(fx, c) for c in rows[:n]], "hasMore": len(rows) > n, "limit": n}


def unread_page(fx, context=2):
    groups, total = [], 0
    for c in fx.chats_by_recent():
        vis = visible(c)
        want = set(m.rowid for m in fx.unread(c.rowid))
        idx = [i for i, m in enumerate(vis) if m.rowid in want]
        if not idx:
            continue
        shown = set()
        for k, i in enumerate(idx):
            if k == 0 or idx[k - 1] != i - 1:
                shown.update(range(max(0, i - context), i))
            shown.add(i)
        order = sorted(shown)
        entries, prev = [], None
        for i in order:
            entries.append({"message": message_record(fx, vis[i]), "isUnread": i in idx,
                            "gapBefore": prev is not None and i != prev + 1})
            prev = i
        groups.append({"chat": chat_record(fx, c), "entries": entries, "unreadCount": len(idx)})
        total += len(idx)
    return {"groups": groups, "totalUnread": total}


def messages_page(fx, chat_id, n=30, before=None, after=None, around=None, since=None):
    c = fx.chats[chat_id]
    vis = visible(c)
    n = min(n, ours.MAX_LINES)
    if before is not None:
        window = [m for m in vis if m.rowid < before][-n:]
    elif after is not None:
        window = [m for m in vis if m.rowid > after][:n]
    elif around is not None:
        idx = next((i for i, m in enumerate(vis) if m.rowid >= around), len(vis) - 1)
        lo = max(0, idx - n // 2)
        window = vis[lo:lo + n]
    else:
        window = vis[-n:]
    if since is not None:
        window = [m for m in window if m.date_ns >= since]
    return {
        "chat": chat_record(fx, c), "messages": [message_record(fx, m) for m in window],
        "totalVisible": len(vis), "olderExists": bool(window) and window[0].rowid != vis[0].rowid,
    }


def message_detail(fx, rowid):
    m = fx.by_rowid[rowid]
    return {"message": message_record(fx, m), "chat": chat_ref(fx, fx.chats[m.chat]), "fromByte": 0,
            "totalBytes": len(m.body.encode())}


def contacts_page(fx, name):
    contacts = []
    for p in fx.resolve_person(name):
        handles = []
        for h in p["handles"]:
            services = sorted(set(fx.handles[i][1] for i in fx.handles if fx.handles[i][0] == h))
            handles.append({"id": h, "services": services})
        chats = [chat_ref(fx, c) for c in fx.chats.values() if any(h in c.members for h in p["handles"])]
        contacts.append({"shortName": p.get("nickname") or p["first"], "firstName": p["first"],
                         "lastName": p.get("last", ""), "handles": handles, "chats": chats})
    return {"query": name, "contacts": contacts}


def chat_of(fx, rowid):
    return fx.by_rowid[rowid].chat


def cases(fx):
    out = []

    def add(name, command, text, record):
        out.append((name, command, text, record))

    add("chats", "chats", ours.chats(fx), chats_page(fx))
    add("chats-n5", "chats -n 5", ours.chats(fx, n=5), chats_page(fx, n=5))
    add("chats-n3", "chats -n 3", ours.chats(fx, n=3), chats_page(fx, n=3))
    add("chats-unread", "chats --unread", ours.chats(fx, unread=True), chats_page(fx, unread=True))
    add("chats-unread-n2", "chats --unread -n 2", ours.chats(fx, n=2, unread=True), chats_page(fx, n=2, unread=True))

    for c in (2, 4, 0):
        add("unread-c%d" % c, "unread -c %d" % c, ours.unread(fx, context=c), unread_page(fx, context=c))

    reads = [
        ("read-12", "read 12", dict(who="12"), dict(chat_id=12)),
        ("read-mom-n10", "read Mom -n 10", dict(who="Mom", n=10), dict(chat_id=7, n=10)),
        ("read-23-n10", "read 23 -n 10", dict(who="23", n=10), dict(chat_id=23, n=10)),
        ("read-19-n10", "read 19 -n 10", dict(who="19", n=10), dict(chat_id=19, n=10)),
        ("read-31", "read 31", dict(who="31"), dict(chat_id=31)),
        ("read-56", "read 56", dict(who="56"), dict(chat_id=56)),
        ("read-2-n40", "read 2 -n 40", dict(who="2", n=40), dict(chat_id=2, n=40)),
        ("read-12-n200", "read 12 -n 200", dict(who="12", n=200), dict(chat_id=12, n=200)),
        ("read-9-before-41000", "read 9 --before 41000", dict(who="9", before=41000), dict(chat_id=9, before=41000)),
        ("read-7-after-41500", "read 7 --after 41500", dict(who="7", after=41500), dict(chat_id=7, after=41500)),
    ]
    since = fx.now_ns - 7 * 86400 * 10**9
    reads.append(("read-12-since", "read 12 --since 2026-10-30T01:30", dict(who="12", since=since),
                  dict(chat_id=12, since=since)))
    around = [
        ("multiline-long", 40458), ("link-single-row", 41434), ("link-two-rows", 40659), ("link-bare", 40930),
        ("failed-send", 41162), ("offloaded-photo", 40051), ("pdf-caption", 40677), ("photo-caption", 41428),
        ("placed-sticker", 41436), ("sticker", 40528), ("emoji-tapbacks", 41472), ("edited-twice", 40779),
        ("unsent-partial", 41232), ("unsent-legacy", 40908), ("unsent-incoming", 41483), ("voice", 40580),
        ("thread-reply", 41419), ("reply-part-1", 41432), ("group-rename", 40016), ("group-add", 40473),
        ("group-remove", 40829), ("group-leave", 41144), ("sms-fallback", 40258), ("rcs-tapback", 41001),
        ("two-photos", 40945), ("zwj", 41489), ("nfd", 41069), ("devanagari", 41204), ("tapback-target-a", 41418),
        ("long-body-2", 41266), ("self-echo", 40042),
    ]
    for name, rowid in around:
        cid = chat_of(fx, rowid)
        reads.append(("read-around-%s" % name, "read %d --around %d -n 12" % (cid, rowid),
                      dict(who=str(cid), n=12, around=rowid), dict(chat_id=cid, n=12, around=rowid)))
    for name, command, rargs, pargs in reads:
        add(name, command, ours.read(fx, **rargs), messages_page(fx, **pargs))

    for rowid in (40927, 40458, 41489, 41069, 41558, 40016, 41434, 40677, 41232, 40580):
        add("show-%d" % rowid, "show %d" % rowid, ours.show(fx, rowid), message_detail(fx, rowid))

    for name in ("Mom", "Dad", "Priya", "Arjun", "Jordan", "Jordan Kim", "Taylor", "Sam", "Chris", "meera desai"):
        slug = name.lower().replace(" ", "-")
        add("who-%s" % slug, "who %s" % name, ours.who(fx, name), contacts_page(fx, name))
    return out


def main():
    fx = reader.Fixture()
    index = []
    for name, command, text, record in cases(fx):
        if text.startswith("error:"):
            raise SystemExit("case %s printed an error line: %s" % (name, text))
        with open(os.path.join(HERE, name + ".txt"), "w", encoding="utf-8", newline="") as f:
            f.write(text)
        with open(os.path.join(HERE, name + ".json"), "w", encoding="utf-8", newline="") as f:
            f.write(json.dumps(record, ensure_ascii=False, sort_keys=True, indent=1) + "\n")
        verb = command.split()[0]
        index.append({"case": name, "command": "imessage " + command, "verb": verb})
    with open(os.path.join(HERE, "cases.json"), "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(index, ensure_ascii=False, indent=1) + "\n")
    print("wrote %d cases" % len(index))


if __name__ == "__main__":
    main()
