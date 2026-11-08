#!/bin/bash
# Checks the skill's token caps (DESIGN.md section 6, docs/BUILD-PLAN.md "INSTALL.md, README.md and the skill").
#
# Usage: scripts/check-skill-tokens.sh [path/to/SKILL.md]
#
# The listing description (the frontmatter `description` value) must be 40 tokens or fewer and the body (everything
# after the closing `---` line) 400 tokens or fewer, counted with tiktoken's o200k_base encoding, the same count
# bench/tokens.py uses. Exits 1 when a cap is exceeded or the file is malformed, and 2 when tiktoken isn't available.
#
# TOKEN_PYTHON names a Python that has tiktoken. The default is bench/.venv/bin/python. The o200k_base file is read
# from <venv>/tiktoken-cache, where bench/tokens.py caches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${1:-$ROOT/skill/imessage/SKILL.md}"
PY="${TOKEN_PYTHON:-$ROOT/bench/.venv/bin/python}"
DESCRIPTION_CAP=40
BODY_CAP=400

if [[ ! -f "$SKILL" ]]; then
    echo "error: $SKILL not found" >&2
    exit 1
fi
if [[ ! -x "$PY" ]]; then
    echo "error: no Python with tiktoken at $PY fix: python3 -m venv bench/.venv && bench/.venv/bin/pip install tiktoken==0.14.0, or set TOKEN_PYTHON" >&2
    exit 2
fi

VENV="$(cd "$(dirname "$PY")/.." && pwd)"
export TIKTOKEN_CACHE_DIR="${TIKTOKEN_CACHE_DIR:-$VENV/tiktoken-cache}"

# -I keeps the interpreter isolated: no PYTHON* variables, no user site, no script or current folder on sys.path.
"$PY" -I - "$SKILL" "$DESCRIPTION_CAP" "$BODY_CAP" <<'PY'
import re
import sys

try:
    import tiktoken
except ImportError:
    print("error: tiktoken is not installed for this Python", file=sys.stderr)
    sys.exit(2)

path, description_cap, body_cap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, encoding="utf-8") as f:
    text = f.read()

lines = text.split("\n")
if not lines or lines[0].strip() != "---":
    print("error: %s has no frontmatter" % path, file=sys.stderr)
    sys.exit(1)
try:
    end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
except StopIteration:
    print("error: %s has no closing --- line" % path, file=sys.stderr)
    sys.exit(1)

# Every frontmatter line must be `key: value` on one line. A block scalar (`description: >-`), an indented
# continuation line or a repeated key would make the measured value differ from the one a skill host reads.
fields = {}
for number, line in enumerate(lines[1:end], start=2):
    if not line.strip():
        continue
    match = re.match(r"^([A-Za-z0-9_-]+):[ \t]*(.*?)[ \t]*$", line)
    if not match:
        print("error: %s line %d isn't a one-line `key: value` field" % (path, number), file=sys.stderr)
        sys.exit(1)
    key, value = match.group(1), match.group(2)
    if value[:1] in ("|", ">"):
        print("error: %s line %d: write %s on one line, not as a block scalar" % (path, number, key), file=sys.stderr)
        sys.exit(1)
    if key in fields:
        print("error: %s line %d repeats %s" % (path, number, key), file=sys.stderr)
        sys.exit(1)
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    fields[key] = value

if fields.get("name") != "imessage":
    print("error: frontmatter name must be imessage", file=sys.stderr)
    sys.exit(1)
description = fields.get("description", "")
if not description:
    print("error: frontmatter has no description", file=sys.stderr)
    sys.exit(1)

body = "\n".join(lines[end + 1:])
enc = tiktoken.get_encoding("o200k_base")
d = len(enc.encode(description, disallowed_special=()))
b = len(enc.encode(body, disallowed_special=()))
print("skill tokens (o200k_base): description %d of %d, body %d of %d" % (d, description_cap, b, body_cap))
failed = False
if d > description_cap:
    print("error: description is %d tokens, cap %d" % (d, description_cap), file=sys.stderr)
    failed = True
if b > body_cap:
    print("error: body is %d tokens, cap %d" % (b, body_cap), file=sys.stderr)
    failed = True
sys.exit(1 if failed else 0)
PY
