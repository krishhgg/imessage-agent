"""Load the synthetic chat.db fixture into normalized records.

Uses only the standard library plus typedstream.py. Opens the database read
only. Contacts come from contacts.json next to the database, or from another
contacts file in the same folder (the bench uses contacts-firstname.json for a
sensitivity run).
"""

import datetime as _dt
import json
import os
import plistlib
import re
import sqlite3
from zoneinfo import ZoneInfo

import typedstream

APPLE_EPOCH = 978307200
OBJ = "￼"

TAPBACK_EMOJI = {0: "❤️", 1: "👍", 2: "👎", 3: "😂", 4: "‼️", 5: "❓"}
TAPBACK_NAME = {0: "love", 1: "like", 2: "dislike", 3: "laugh", 4: "emphasis", 5: "question", 6: "custom"}

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIXTURE = os.path.normpath(os.path.join(HERE, "..", "Tests", "Fixtures"))


def ns_to_unix(ns):
    return ns / 1e9 + APPLE_EPOCH


def normalize_handle(h):
    if h is None:
        return ""
    h = h.strip()
    if "@" in h:
        return h.lower()
    digits = re.sub(r"\D", "", h)
    # A + before the first digit means the number already has its country code.
    has_country_code = re.match(r"[^0-9+]*\+", h) is not None
    if len(digits) == 10 and not has_country_code:
        digits = "1" + digits
    return "+" + digits if digits else h


def format_phone(h):
    d = re.sub(r"\D", "", h or "")
    if len(d) == 11 and d.startswith("1"):
        return "+1 (%s) %s-%s" % (d[1:4], d[4:7], d[7:])
    return h


class Attachment(object):
    def __init__(self, **kw):
        self.__dict__.update(kw)

    @property
    def kind(self):
        mime = self.mime_type or ""
        if self.is_sticker:
            return "sticker"
        if mime.startswith("image/"):
            return "photo"
        if mime.startswith("video/"):
            return "video"
        if mime.startswith("audio/") or self.is_audio:
            return "voice"
        return "file"


class Message(object):
    def __init__(self, **kw):
        self.reactions = []
        self.stickers = []
        self.__dict__.update(kw)

    @property
    def body(self):
        """Display text without attachment placeholders."""
        return (self.text or "").replace(OBJ, "")

    @property
    def is_tapback(self):
        return 2000 <= (self.assoc_type or 0) <= 3999

    @property
    def is_placed_sticker(self):
        return self.assoc_type == 1000

    @property
    def is_event(self):
        return (self.item_type or 0) != 0


class Chat(object):
    def __init__(self, **kw):
        self.__dict__.update(kw)


class Fixture(object):
    def __init__(self, root=DEFAULT_FIXTURE, contacts="contacts.json"):
        self.root = root
        self.db_path = os.path.join(root, "chat.db")
        self.contacts_path = os.path.join(root, contacts)
        self.contacts_name = contacts
        with open(os.path.join(root, "manifest.json")) as f:
            self.manifest = json.load(f)
        with open(self.contacts_path) as f:
            self.contacts = json.load(f)
        self.tz = ZoneInfo(self.manifest["time_zone"])
        self.now_ns = self.manifest["fixture_now_ns"]
        self.now = _dt.datetime.fromtimestamp(ns_to_unix(self.now_ns), self.tz)
        self.owner_handles = set(normalize_handle(h) for h in self.contacts["owner"]["handles"])
        self.people = {}
        for p in self.contacts["people"]:
            for h in p["handles"]:
                self.people[normalize_handle(h)] = p
        db = sqlite3.connect("file:%s?mode=ro" % self.db_path, uri=True)
        db.row_factory = sqlite3.Row
        self._load(db)
        db.close()

    # ---- names ----

    def person(self, handle):
        return self.people.get(normalize_handle(handle))

    def short_name(self, handle):
        """Nickname or first name, else a formatted phone or the email."""
        if handle is None:
            return "Unknown"
        if normalize_handle(handle) in self.owner_handles:
            return "You"
        p = self.person(handle)
        if p:
            return p.get("nickname") or p["first"]
        return format_phone(handle) if "@" not in handle else handle

    def full_name(self, handle):
        """First and last name, the way Contacts shows a card. No nickname."""
        p = self.person(handle)
        if not p:
            return None
        return " ".join(x for x in (p.get("first"), p.get("last")) if x)

    def dt(self, ns):
        return _dt.datetime.fromtimestamp(ns_to_unix(ns), self.tz)

    # ---- loading ----

    def _load(self, db):
        self.handles = {}
        for r in db.execute("SELECT ROWID, id, service FROM handle"):
            self.handles[r["ROWID"]] = (r["id"], r["service"])

        self.chats = {}
        members = {}
        for r in db.execute("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id"):
            members.setdefault(r["chat_id"], []).append(r["handle_id"])
        for r in db.execute("SELECT * FROM chat ORDER BY ROWID"):
            self.chats[r["ROWID"]] = Chat(
                rowid=r["ROWID"], guid=r["guid"], identifier=r["chat_identifier"],
                display_name=r["display_name"] or "", service=r["service_name"],
                style=r["style"], is_group=r["style"] == 43,
                account_id=r["account_id"], account_login=r["account_login"],
                last_addressed_handle=r["last_addressed_handle"],
                member_ids=members.get(r["ROWID"], []), messages=[],
            )
        for c in self.chats.values():
            seen = []
            for hid in c.member_ids:
                h = self.handles[hid][0]
                if h not in seen:
                    seen.append(h)
            c.members = seen

        chat_of = {}
        for r in db.execute("SELECT chat_id, message_id FROM chat_message_join"):
            chat_of[r["message_id"]] = r["chat_id"]

        atts = {}
        for r in db.execute(
            "SELECT maj.message_id AS mid, a.* FROM message_attachment_join maj "
            "JOIN attachment a ON a.ROWID = maj.attachment_id ORDER BY maj.message_id, a.ROWID"
        ):
            ui = plistlib.loads(r["user_info"]) if r["user_info"] else {}
            on_disk_rel = (r["filename"] or "").replace("~/Library/Messages/Attachments/", "Attachments/")
            atts.setdefault(r["mid"], []).append(Attachment(
                rowid=r["ROWID"], guid=r["guid"], filename=r["filename"], uti=r["uti"],
                mime_type=r["mime_type"], transfer_name=r["transfer_name"],
                total_bytes=r["total_bytes"], is_sticker=bool(r["is_sticker"]),
                transfer_state=r["transfer_state"], is_outgoing=bool(r["is_outgoing"]),
                created_date=r["created_date"], transcript=ui.get("audio-transcription"),
                on_disk=os.path.exists(os.path.join(self.root, on_disk_rel)), is_audio=False,
                width=None, height=None,
            ))

        self.messages = []
        self.by_rowid = {}
        self.by_guid = {}
        for r in db.execute("SELECT * FROM message ORDER BY ROWID"):
            rowid = r["ROWID"]
            if rowid not in chat_of:
                continue  # Recently Deleted rows have no chat_message_join row
            text, runs = None, []
            if r["attributedBody"]:
                text, runs = typedstream.decode_attributed(r["attributedBody"])
            elif r["text"] is not None:
                text = r["text"]
            hid = r["handle_id"]
            handle = self.handles[hid][0] if hid in self.handles else None
            other = self.handles[r["other_handle"]][0] if r["other_handle"] in self.handles else None
            summary = plistlib.loads(r["message_summary_info"]) if r["message_summary_info"] else {}
            unsent_parts = list(summary.get("rp", []))
            edits = summary.get("ec", {})
            edited = bool(edits) and (r["date_edited"] or 0) != 0
            unsent_all = bool(r["date_retracted"]) or (
                bool(unsent_parts) and not text and (r["date_edited"] or 0) != 0)
            m_atts = atts.get(rowid, [])
            for a in m_atts:
                a.is_audio = bool(r["is_audio_message"])
            for start, length, attrs in runs:
                g = attrs.get("__kIMFileTransferGUIDAttributeName")
                if g:
                    for a in m_atts:
                        if a.guid == g:
                            w = attrs.get("__kIMInlineMediaWidthAttributeName")
                            h = attrs.get("__kIMInlineMediaHeightAttributeName")
                            a.width = int(w) if w else None
                            a.height = int(h) if h else None
            link = None
            if r["balloon_bundle_id"] == "com.apple.messages.URLBalloonProvider" and r["payload_data"]:
                link = _link_metadata(r["payload_data"])
            m = Message(
                rowid=rowid, guid=r["guid"], chat=chat_of[rowid], date_ns=r["date"],
                from_me=bool(r["is_from_me"]), handle_id=hid, handle=handle, other_handle=other,
                service=r["service"], text=text, raw_text_column=r["text"], runs=runs,
                item_type=r["item_type"] or 0, group_action_type=r["group_action_type"] or 0,
                group_title=r["group_title"], assoc_type=r["associated_message_type"] or 0,
                assoc_guid=r["associated_message_guid"], assoc_emoji=r["associated_message_emoji"],
                assoc_range=(r["associated_message_range_location"], r["associated_message_range_length"]),
                thread_guid=r["thread_originator_guid"], thread_part=r["thread_originator_part"],
                reply_rowid=None, attachments=m_atts, edited=edited, edit_count=sum(len(v) for v in edits.values()),
                unsent=unsent_all, unsent_parts=unsent_parts, date_edited=r["date_edited"] or 0,
                date_retracted=r["date_retracted"] or 0, is_read=bool(r["is_read"]),
                date_read=r["date_read"] or 0, is_delivered=bool(r["is_delivered"]),
                date_delivered=r["date_delivered"] or 0, is_sent=bool(r["is_sent"]), error=r["error"] or 0,
                balloon=r["balloon_bundle_id"], link=link, is_audio=bool(r["is_audio_message"]),
                dest_caller=r["destination_caller_id"], effect=r["expressive_send_style_id"],
                cache_has_attachments=bool(r["cache_has_attachments"]), self_echo=False,
                duplicate_of=None,
            )
            self.messages.append(m)
            self.by_rowid[rowid] = m
            self.by_guid[m.guid] = m
            self.chats[m.chat].messages.append(m)

        for m in self.messages:
            if m.thread_guid and m.thread_guid in self.by_guid:
                m.reply_rowid = self.by_guid[m.thread_guid].rowid
        self._fold_tapbacks()
        self._mark_echoes_and_link_duplicates()

    def _fold_tapbacks(self):
        """Replay adds and removes in ROWID order. Each actor keeps at most one
        reaction per message part, the way Messages shows them."""
        state = {}  # (target rowid, part) -> list of dicts in first-reaction order
        for m in self.messages:
            if not (m.is_tapback or m.is_placed_sticker):
                continue
            guid = m.assoc_guid or ""
            part = 0
            mm = re.match(r"^p:(\d+)/(.*)$", guid)
            if mm:
                part, guid = int(mm.group(1)), mm.group(2)
            elif guid.startswith("bp:"):
                guid = guid[3:]
            target = self.by_guid.get(guid)
            if target is None:
                continue
            m.target_rowid = target.rowid
            m.target_part = part
            actor = "me" if m.from_me else normalize_handle(m.handle)
            if m.is_placed_sticker:
                target.stickers.append({"actor": actor, "handle": m.handle, "from_me": m.from_me,
                                        "rowid": m.rowid, "date_ns": m.date_ns, "part": part})
                continue
            kind = m.assoc_type % 1000
            lst = state.setdefault((target.rowid, part), [])
            if m.assoc_type < 3000:
                emoji = m.assoc_emoji if kind == 6 else TAPBACK_EMOJI.get(kind)
                for i, e in enumerate(lst):
                    if e["actor"] == actor:
                        del lst[i]
                        break
                lst.append({"actor": actor, "handle": m.handle, "from_me": m.from_me, "kind": kind,
                            "type": TAPBACK_NAME[kind], "emoji": emoji, "rowid": m.rowid,
                            "guid": m.guid, "date_ns": m.date_ns, "part": part})
            else:
                for i, e in enumerate(lst):
                    if e["actor"] == actor and e["kind"] == kind and (kind != 6 or e["emoji"] == m.assoc_emoji):
                        del lst[i]
                        break
        for (rowid, part), lst in sorted(state.items()):
            self.by_rowid[rowid].reactions.extend(lst)

    def _mark_echoes_and_link_duplicates(self):
        for c in self.chats.values():
            prev = None
            for m in c.messages:
                if c.identifier and normalize_handle(c.identifier) in self.owner_handles and not m.from_me \
                        and prev is not None and prev.from_me and prev.text == m.text:
                    m.self_echo = True
                if m.link and prev is not None and prev.handle_id == m.handle_id \
                        and prev.from_me == m.from_me and m.link.get("url") and prev.text \
                        and m.link["url"] in prev.text and m.date_ns - prev.date_ns <= 5 * 10**9:
                    m.duplicate_of = prev.rowid
                    prev.link = m.link
                prev = m

    # ---- queries used by renderers ----

    def chat_messages(self, chat_id):
        return self.chats[chat_id].messages

    def last_date(self, chat_id):
        msgs = self.chats[chat_id].messages
        return max(m.date_ns for m in msgs) if msgs else 0

    def unread(self, chat_id):
        return [m for m in self.chats[chat_id].messages
                if not m.from_me and not m.is_read and not m.is_tapback and not m.is_event]

    def chats_by_recent(self):
        return sorted(self.chats.values(), key=lambda c: (-self.last_date(c.rowid), c.rowid))

    def resolve_person(self, name):
        """Nickname, first name or full name to handles."""
        q = name.strip().lower()
        out = []
        for p in self.contacts["people"]:
            names = [p.get("nickname", ""), p["first"], "%s %s" % (p["first"], p.get("last", ""))]
            if q in [n.lower() for n in names if n]:
                out.append(p)
        return out

    def direct_chat_for(self, handles):
        want = set(normalize_handle(h) for h in handles)
        for c in self.chats.values():
            if not c.is_group and normalize_handle(c.identifier) in want:
                return c
        return None


def _link_metadata(payload):
    try:
        p = plistlib.loads(payload)
    except Exception:
        return None
    objs = p.get("$objects", [])

    def deref(v):
        if isinstance(v, plistlib.UID):
            return objs[v.data]
        return v

    for o in objs:
        if isinstance(o, dict) and "title" in o and ("URL" in o or "originalURL" in o):
            url_obj = deref(o.get("URL") or o.get("originalURL"))
            url = deref(url_obj.get("NS.relative")) if isinstance(url_obj, dict) else None
            return {"title": deref(o.get("title")), "site": deref(o.get("siteName")),
                    "summary": deref(o.get("summary")), "url": url}
    return None


if __name__ == "__main__":
    fx = Fixture()
    print(len(fx.messages), "messages in", len(fx.chats), "chats")
    for key, spec in sorted(fx.manifest["tapback_net_state"].items()):
        m = fx.by_rowid[spec["rowid"]]
        got = {}
        for e in m.reactions:
            got.setdefault(str(e["part"]), []).append("%s %s" % (e["emoji"], fx.short_name(e["handle"]) if not e["from_me"] else "You"))
        want = {k: v for k, v in spec["parts"].items() if v}
        print(key, "ok" if got == want else "MISMATCH %r != %r" % (got, want))
