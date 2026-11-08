"""Fixed per-session context for each tool: skill bodies, MCP tool lists,
server instructions and pasted custom instructions.

Third-party skill files are not copied into this repo. overhead_data/counts.json
keeps the o200k_base count and sha256 of each file as read from the
competitor checkouts under /tmp/s5-*. When a checkout is present and its hash
matches, the count is recomputed from the file. When it is missing, the cached
count is used. A hash mismatch keeps the cached count and prints a warning, so
results stay tied to the reviewed version.

Run `python3 overhead.py` to rewrite counts.json from the checkouts.
"""

import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import tokens  # noqa: E402

REPO = os.path.dirname(HERE)
CACHE = os.path.join(HERE, "overhead_data", "counts.json")
OURS_SKILL = os.path.join(REPO, "skills", "imessage", "SKILL.md")
# A placeholder for the whole ours SKILL.md, not a real skill. Competitor counts
# are whole files, frontmatter included, so this one is too: the DESIGN.md
# section 6 caps (body 400 tokens or fewer, description 40 or fewer) plus the
# frontmatter lines around the description.
OURS_BODY_MAX = 400
OURS_DESC_MAX = 40
OURS_FRONTMATTER = "---\nname: imessage\ndescription: \n---\n\n"
OURS_PLACEHOLDER = OURS_BODY_MAX + OURS_DESC_MAX + tokens.count(OURS_FRONTMATTER)
# The one concrete draft: research/tokens.md section 4, "Proposed SKILL.md, full file, 16 verbs".
OURS_DRAFT_SKILL = 628

FILES = {
    "imsg": ("openclaw/imsg .agents/skills/imsg/SKILL.md", "MIT",
             "/tmp/s5-openclaw_imsg/src/.agents/skills/imsg/SKILL.md"),
    "steve228uk": ("steve228uk/grok-bot-imessage skills/imessage-on-mac.md", "no license file",
                   "/tmp/s5-steve228uk_grok-bot-imessage/src/skills/imessage-on-mac.md"),
    "jeffhuber": ("jeffhuber/grokbot-imessage-skill SKILL.md", "MIT",
                  "/tmp/s5-jeffhuber_grokbot-imessage-skill/src/SKILL.md"),
    "ryannewsom": ("RyanNewsom/grokbot-imessage-reader SKILL.md", "MIT",
                   "/tmp/s5-RyanNewsom_grokbot-imessage-reader/src/SKILL.md"),
    "jimmyliu03_skill": ("jimmyliu03/grok-bot-imessage apple-messages-reminders SKILL.md", "MIT",
                         "/tmp/s5-jimmyliu03_grok-bot-imessage/src/plugins/grok-bot-mac-bridge/skills/"
                         "apple-messages-reminders/SKILL.md"),
}


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _cache():
    if os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as f:
            return json.load(f)
    return {}


def file_tokens(key):
    """Returns (tokens, origin) where origin is 'file' or 'cache'."""
    cached = _cache().get(key)
    path = FILES[key][2]
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if cached is None or cached["sha256"] == _sha(text):
            return tokens.count(text), "file"
        sys.stderr.write("warning: %s changed since counts.json was written; using the cached count\n" % path)
    if cached is None:
        raise SystemExit("no checkout and no cached count for %s" % key)
    return cached["tokens"], "cache"


def ours_skill():
    if os.path.exists(OURS_SKILL):
        with open(OURS_SKILL, encoding="utf-8") as f:
            return tokens.count(f.read()), "skills/imessage/SKILL.md"
    return OURS_PLACEHOLDER, "placeholder"


def refresh():
    out = {}
    for key, (what, lic, path) in sorted(FILES.items()):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        out[key] = {"what": what, "license": lic, "chars": len(text), "sha256": _sha(text),
                    "tokens": tokens.count(text)}
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    return out


if __name__ == "__main__":
    for k, v in sorted(refresh().items()):
        print("%-18s %6d tokens  %s" % (k, v["tokens"], v["what"]))
