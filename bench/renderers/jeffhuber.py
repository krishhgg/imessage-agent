"""Renderer (d): jeffhuber/grokbot-imessage-skill, helper 1.4.8, protocol 1.2.

Rebuilt from bin/helper.py, bin/send_gate.py and SKILL.md (MIT, read, not
run). The agent writes a request file, polls, cats the response and deletes
it, all in one shell call per action. The response is json.dump with
indent=2 and ensure_ascii=False: the action's keys, then id, action, ok and
generated_at.

- fetch_messages reads every row after the cutoff, tapbacks and group events
  included, ordered by chat_identifier then date. ts is naive local time.
- Contacts map the last 10 phone digits or a lowercased email to
  "First Last". Nicknames are not read, so "Mom" matches nothing.
- chat_history filters by a substring of chat_identifier or sender, so a
  person's messages in group chats come along with the 1:1 thread.
- The host role has no list_chats, no group sends, no files and no tapbacks.
"""

import base64
import hashlib
import re

import jsonfmt
import reader

MAX_TEXT_SNIPPET = 600
MAX_CONTEXT = 8
BRIDGE = "/Users/alex/Library/Application Support/GrokBotIMessage"
PRODUCT = "/Library/Application Support/GrokBotIMessage/users/501"
HOST_ACTIONS = ("status", "review", "search", "chat_history", "response_stats",
                "contacts_lookup", "send_preview", "send")

_CODE = re.compile(
    r"(?:\b(?:code|verification|OTP|passcode|one[- ]time)\b[^0-9]{0,20}\b(\d{4,8})\b)"
    r"|(?:\b(\d{4,8})\b[^0-9]{0,20}\b(?:code|verification|OTP|passcode)\b)", re.IGNORECASE)
_CARD = re.compile(r"\b(?:\d[ -]?){13,19}\b")
_SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
_AUTO = re.compile("|".join([
    r"lyft:.*(requested|on their way|arrived|cancelled)", r"uber:.*(on|arriving|trip)",
    r"your .*verification code", r"your .*code is", r"verification code|one-time password|\botp\b",
    r"actblue|midterms|reelection|\bdonate\b|rush \$\d+", r"stop to quit|reply stop",
    r"error invalid number", r"delivered|out for delivery|package|shipment", r"check-in",
    r"bill is ready|statement is available", r"your appointment|appointment reminder"]), re.IGNORECASE)
_SHORT = re.compile(r"^[+]?[0-9]{3,6}$")
_REACTION = re.compile(r"^(liked|loved|laughed at|emphasized|questioned|disliked|reacted|removed a)"
                       "( a| an)? [“\"'￼]", re.IGNORECASE)
_ACKS = {"thx", "thanks", "ty", "ok", "okay", "k", "sure", "sounds good", "sounds good!", "for sure",
         "cool", "nice", "great", "got it", "yep", "yup", "nope"}


def redact(t):
    if not t:
        return t
    t = _CODE.sub("[REDACTED-2FA]", t)
    t = _CARD.sub(lambda m: "[REDACTED-CARD]" if len(re.sub(r"\D", "", m.group(0))) >= 13 else m.group(0), t)
    return _SSN.sub("[REDACTED-SSN]", t)


def _automated(chat_id, text):
    if _SHORT.match(chat_id or "") or "rbm.goog" in (chat_id or ""):
        return True
    return bool(text) and bool(_AUTO.search(text))


def _low_signal(text):
    if not text:
        return True
    t = text.strip()
    return bool(_REACTION.match(t)) or t.lower().rstrip("!. ") in _ACKS


def _norm(h):
    if not h:
        return ""
    s = h.strip()
    if "@" in s:
        return s.lower()
    d = re.sub(r"[^0-9]", "", s)
    return d[-10:] if len(d) >= 10 else ""


def contacts(fx):
    out = {}
    for p in fx.contacts["people"]:
        name = " ".join(x for x in (p.get("first"), p.get("last")) if x)
        for h in p["handles"]:
            k = _norm(h)
            if k:
                out.setdefault(k, name)
    return out


def _lookup(chat_id, sender, cts):
    for cand in (chat_id, sender):
        k = _norm(cand or "")
        if k and cts.get(k):
            return cts[k]
    return ""


def _group_label(parts, cts):
    names = []
    for h in parts:
        n = _lookup(h, h, cts)
        if n:
            names.append(n.split()[0])
        elif "@" in (h or ""):
            names.append(h)
        else:
            d = re.sub(r"[^0-9]", "", h or "")
            names.append("…" + d[-4:] if len(d) >= 4 else h)
    if len(names) <= 3:
        return ", ".join(names)
    return ", ".join(names[:3]) + " & %d others" % (len(names) - 3)


def _ts(fx, ns):
    return fx.dt(ns).replace(tzinfo=None).isoformat(timespec="seconds")


def _text(m):
    return m.raw_text_column or m.text or ""


def fetch(fx, cutoff_ns, search=None, substr=None):
    rows = []
    for m in fx.messages:
        if m.date_ns <= cutoff_ns:
            continue
        c = fx.chats[m.chat]
        text = _text(m)
        sender = m.handle or ""
        if substr and substr.lower() not in c.identifier.lower() and substr.lower() not in sender.lower():
            continue
        if search and search.lower() not in text.lower():
            continue
        rows.append({"chat_id": c.identifier, "display_name": c.display_name or "", "ts_ns": m.date_ns,
                     "ts": _ts(fx, m.date_ns), "is_from_me": m.from_me, "sender": sender, "text": text,
                     "_rowid": m.rowid})
    rows.sort(key=lambda r: (r["chat_id"], r["ts_ns"], r["_rowid"]))
    return rows


def _cutoff(fx, days):
    return fx.now_ns - int(days * 86400 * 10 ** 9)


def _respond(fx, req_id, action, result):
    result.update({"id": req_id, "action": action, "ok": True,
                   "generated_at": _ts(fx, fx.now_ns)})
    return jsonfmt.py(result, indent=2, ensure_ascii=False) + "\n"


def _error(req_id, action, msg):
    return jsonfmt.py({"id": req_id, "action": action, "ok": False, "error": msg,
                       "allowed_actions": sorted(HOST_ACTIONS)}, indent=2, ensure_ascii=False) + "\n"


def req_id(seed):
    return hashlib.sha256(seed.encode()).hexdigest()[:12]


def ls_bridge():
    block = ("total 0\n"
             "drwx------  2 alex  staff   64 Nov  6 00:30 .\n"
             "drwx------  5 alex  staff  160 Nov  2 18:04 ..\n")
    return ("%s/control/requests:\n%s\n%s/control/responses:\n%s" % (BRIDGE, block, BRIDGE, block))


def status(fx, rid):
    code = PRODUCT + "/libexec"
    return _respond(fx, rid, "status", {
        "helper_version": "1.4.8", "protocol_version": "1.2", "bridge_role": "host",
        "allowed_actions": sorted(HOST_ACTIONS), "product_id": "grokbot-imessage",
        # The hardened C wrapper sets IMESSAGE_PRODUCT_ID, so helper.py reports
        # product mode and no launchd label.
        "wrapper_mode": "product", "host_display_name": "Grok Bot", "launchd_label": None,
        "confirmation_helper_path": code + "/bin/grokbot-imessage-confirm", "code_root": code,
        "bridge_root": BRIDGE, "policy_dir": PRODUCT + "/config", "install_root": code,
        "python_version": "3.9.6",
        "read_policy": {"mode": "allowlist", "allowlist_entries": len(fx.chats), "blocklist_entries": 0,
                        "root_owned_required": True},
        "checks": {"chat_db_exists": True, "chat_db_readable": True, "confirmation_helper_exists": True,
                   "confirmation_helper_executable": True, "requests_dir_exists": True,
                   "responses_dir_exists": True},
    })


def review(fx, rid, days=2.0):
    days = float(days)
    cts = contacts(fx)
    msgs = fetch(fx, _cutoff(fx, days))
    parts = {}
    for c in fx.chats.values():
        parts[c.identifier] = [fx.handles[h][0] for h in c.member_ids]
    chats = {}
    order = []
    for m in msgs:
        if m["chat_id"] not in chats:
            order.append(m["chat_id"])
        chats.setdefault(m["chat_id"], []).append(m)
    need, low, skip = [], [], []
    for chat_id in order:
        ms = chats[chat_id]
        last = ms[-1]
        if last["is_from_me"]:
            continue
        last_text = last["text"] or ""
        display = last.get("display_name") or ""
        is_group = chat_id.startswith("chat") and not re.fullmatch(r"[+0-9@.]+", chat_id)
        if is_group:
            contact_name = ""
            if not display:
                display = _group_label(parts.get(chat_id, []), cts)
        else:
            contact_name = _lookup(chat_id, last["sender"], cts)
        label = contact_name or display or chat_id
        auto_last = _automated(chat_id, last_text)
        human = any(not x["is_from_me"] and not _automated(chat_id, x.get("text", "")) for x in ms)
        entry = {"chat_id": chat_id, "label": label, "contact_name": contact_name, "display_name": display,
                 "last_ts": last["ts"], "last_text": redact(last_text)[:MAX_TEXT_SNIPPET],
                 "context": [{"ts": x["ts"], "me": x["is_from_me"], "text": redact(x.get("text", "") or "")[:400]}
                             for x in ms[-MAX_CONTEXT:]],
                 "msg_count": len(ms)}
        if auto_last and not human:
            skip.append(entry)
        elif _low_signal(last_text):
            low.append(entry)
        else:
            need.append(entry)
    for b in (need, low, skip):
        b.sort(key=lambda e: e["last_ts"], reverse=True)
    return _respond(fx, rid, "review", {
        "days": days,
        "counts": {"needs_reply": len(need), "low_priority": len(low), "skip": len(skip),
                   "total_messages": len(msgs)},
        "needs_reply": need, "low_priority": low,
        "skip_summary": [{"chat_id": e["chat_id"], "label": e["label"], "last_ts": e["last_ts"]} for e in skip[:20]],
    })


def search(fx, rid, term, days=30.0, limit=100):
    days = float(days)
    cts = contacts(fx)
    msgs = fetch(fx, _cutoff(fx, days), search=term)
    msgs.sort(key=lambda r: (r["ts_ns"], r["_rowid"]), reverse=True)
    matches = [{"chat_id": m["chat_id"], "contact_name": _lookup(m["chat_id"], m["sender"], cts), "ts": m["ts"],
                "is_from_me": m["is_from_me"], "text": redact(m["text"])[:MAX_TEXT_SNIPPET]} for m in msgs[:limit]]
    return _respond(fx, rid, "search", {"term": term, "days": days, "match_count": len(matches),
                                        "matches": matches})


def resolve_filter(q, cts):
    digits = re.sub(r"[^0-9]", "", q)
    if len(digits) >= 10:
        return digits[-10:]
    if "@" in q:
        return q
    ql = q.lower().strip()
    for k, name in cts.items():
        if ql in name.lower():
            return k
    return q


def chat_history(fx, rid, chat, days=14.0, limit=100):
    days = float(days)
    cts = contacts(fx)
    sub = resolve_filter(chat.strip(), cts)
    msgs = fetch(fx, _cutoff(fx, days), substr=sub)
    msgs.sort(key=lambda r: (r["ts_ns"], r["_rowid"]))
    msgs = msgs[-limit:]
    out = [{"chat_id": m["chat_id"], "contact_name": _lookup(m["chat_id"], m["sender"], cts), "ts": m["ts"],
            "is_from_me": m["is_from_me"], "text": redact(m["text"])[:MAX_TEXT_SNIPPET]} for m in msgs]
    return _respond(fx, rid, "chat_history", {"chat_query": chat.strip(), "resolved_substr": sub,
                                              "count": len(out), "messages": out})


def contacts_lookup(fx, rid, name):
    nl = name.lower()
    matches = []
    for h, full in contacts(fx).items():
        if nl in full.lower():
            matches.append({"name": full, "email": h} if "@" in h else {"name": full, "phone_last10": h})
    return _respond(fx, rid, "contacts_lookup", {"query": name, "match_count": len(matches),
                                                 "matches": matches[:25]})


def _nonce(seed):
    return base64.urlsafe_b64encode(hashlib.sha256(seed.encode()).digest()[:24]).decode().rstrip("=")


def send_nonce(to, text):
    """The nonce send_preview hands out, which the send request must echo."""
    return _nonce(to + text)


def send_preview(fx, rid, to, text, service="iMessage"):
    cts = contacts(fx)
    return _respond(fx, rid, "send_preview", {
        "preview": {"to": to, "resolved_name": cts.get(_norm(to), ""), "service": service, "text": text,
                    "text_length": len(text), "blocked": False},
        "send_nonce": _nonce(to + text), "send_nonce_ttl_seconds": 60,
    })


def send(fx, rid, to, text, service="iMessage"):
    cts = contacts(fx)
    return _respond(fx, rid, "send", {"sent": {"to": to, "resolved_name": cts.get(_norm(to), ""),
                                               "service": service, "text_length": len(text),
                                               "sent_at": _ts(fx, fx.now_ns)}})


def request_command(rid, action, params):
    """The shell call SKILL.md tells the agent to run for one action."""
    body = jsonfmt.py({"id": rid, "action": action, "params": params}, ensure_ascii=False)
    return (
        'BRIDGE="%s"\nREQ_ID="%s"\n'
        'TMP="$BRIDGE/control/requests/.request-$REQ_ID.json.tmp"\n'
        'FINAL="$BRIDGE/control/requests/request-$REQ_ID.json"\n'
        "cat > \"$TMP\" <<EOF\n%s\nEOF\n"
        'mv "$TMP" "$FINAL"\n'
        "for i in {1..30}; do\n"
        '  if [[ -f "$BRIDGE/control/responses/response-$REQ_ID.json" ]]; then\n'
        '    RESPONSE="$BRIDGE/control/responses/response-$REQ_ID.json"\n'
        '    cat "$RESPONSE"\n    rm -f "$RESPONSE"\n    break\n  fi\n  sleep 0.5\ndone'
        % (BRIDGE, rid, body))
