#!/bin/bash
# Tests for scripts/check-skill-tokens.sh: the real skill passes, both caps hold at their exact limits, and every
# frontmatter shape the parser can't measure correctly is refused.
#
# Usage: scripts/tests/skill-tokens-test.sh   (TOKEN_PYTHON as for check-skill-tokens.sh)
#
# In o200k_base, "a" and each " a" are one token, and k space-separated "b" words plus a newline are k + 1 tokens.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-skill-tokens.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/imessage-skill-tokens-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASSED=0
FAILED=0
RC=0

# expect <name> <exit code> <file> [text the output must hold]
expect() {
    local name="$1" want="$2" file="$3" text="${4:-}" out
    out="$("$CHECK" "$file" 2>&1)"
    RC=$?
    if [[ "$RC" == "$want" && ( -z "$text" || "$out" == *"$text"* ) ]]; then
        PASSED=$((PASSED + 1))
        echo "ok    $name"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL  $name (exit $RC, want $want)"
        printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

words() {
    local word="$1" n="$2" out="$1" i
    for ((i = 1; i < n; i++)); do out+=" $word"; done
    printf '%s' "$out"
}

# skill <file> <description line> <body tokens>
skill() {
    local file="$1" description="$2" body_tokens="$3"
    {
        printf -- '---\nname: imessage\n%s\n---\n' "$description"
        words b $((body_tokens - 1))
        printf '\n'
    } >"$file"
}

expect "the repo skill is within both caps" 0 "$ROOT/skill/imessage/SKILL.md" "skill tokens (o200k_base): description"

# The react line names every kind `react` takes (DESIGN.md section 5): the six named kinds and one recent emoji.
if grep -q -F 'react <msg> heart|like|dislike|laugh|emphasize|question|<recent emoji> [--remove]' \
    "$ROOT/skill/imessage/SKILL.md"; then
    PASSED=$((PASSED + 1))
    echo "ok    the skill names the six tapback kinds and the recent emoji kind"
else
    FAILED=$((FAILED + 1))
    echo "FAIL  the skill names the six tapback kinds and the recent emoji kind"
fi

skill "$T/at-cap.md" "description: $(words a 40)" 400
expect "a 40-token description and a 400-token body pass" 0 "$T/at-cap.md" "description 40 of 40, body 400 of 400"

skill "$T/description-over.md" "description: $(words a 41)" 10
expect "a 41-token description fails" 1 "$T/description-over.md" "description is 41 tokens, cap 40"

skill "$T/body-over.md" "description: short" 401
expect "a 401-token body fails" 1 "$T/body-over.md" "body is 401 tokens, cap 400"

skill "$T/quoted.md" "description: \"$(words a 40)\"" 10
expect "quotes around the description aren't counted" 0 "$T/quoted.md" "description 40 of 40"

printf '%s\n' '---' 'name: imessage' 'description: >-' "  $(words a 80)" '---' 'body' >"$T/folded.md"
expect "a folded block description is refused" 1 "$T/folded.md" "not as a block scalar"

printf '%s\n' '---' 'name: imessage' 'description: |' "  $(words a 80)" '---' 'body' >"$T/literal.md"
expect "a literal block description is refused" 1 "$T/literal.md" "not as a block scalar"

printf '%s\n' '---' 'name: imessage' 'description: short' "  $(words a 80)" '---' 'body' >"$T/continued.md"
expect "an indented continuation line is refused" 1 "$T/continued.md" "isn't a one-line"

printf '%s\n' '---' 'name: imessage' 'description: short' "description: $(words a 80)" '---' 'body' >"$T/repeated.md"
expect "a repeated key is refused" 1 "$T/repeated.md" "repeats description"

printf '%s\n' 'name: imessage' 'description: short' 'body' >"$T/no-frontmatter.md"
expect "a file without frontmatter is refused" 1 "$T/no-frontmatter.md" "has no frontmatter"

printf '%s\n' '---' 'name: imessage' 'description: short' 'body' >"$T/unclosed.md"
expect "unclosed frontmatter is refused" 1 "$T/unclosed.md" "no closing --- line"

printf '%s\n' '---' 'name: other' 'description: short' '---' 'body' >"$T/name.md"
expect "a different skill name is refused" 1 "$T/name.md" "name must be imessage"

printf '%s\n' '---' 'name: imessage' '---' 'body' >"$T/no-description.md"
expect "a missing description is refused" 1 "$T/no-description.md" "has no description"

expect "a missing file is refused" 1 "$T/missing.md" "not found"

out="$(TOKEN_PYTHON="$T/no-python" "$CHECK" 2>&1)"
RC=$?
if [[ "$RC" == 2 && "$out" == *"no Python with tiktoken"* ]]; then
    PASSED=$((PASSED + 1))
    echo "ok    a missing tokenizer exits 2"
else
    FAILED=$((FAILED + 1))
    echo "FAIL  a missing tokenizer exits 2 (exit $RC)"
fi

echo "skill token tests: $PASSED passed, $FAILED failed"
((FAILED == 0))
