"""JSON writers that match the byte output of the serializers each tool uses.

- apple(): Foundation JSONSerialization. Compact output has no spaces and
  escapes "/" as "\\/" unless no_slash_escape is set. Pretty output indents
  by 2, writes '"key" : value', and prints empty containers on three lines.
- swift(): Swift JSONEncoder. Compact, escapes "/" unless no_slash_escape.
- js(): JSON.stringify with no spacing.
- py(): Python json.dumps with the given indent and ensure_ascii.
Key order is the insertion order of the dicts passed in.
"""

import json
import math


def _num(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isfinite(v) and v == int(v) and abs(v) < 1e15:
            return str(int(v))
        return repr(v)
    raise TypeError(v)


def _str(s, escape_slash):
    out = json.dumps(s, ensure_ascii=False)
    if escape_slash:
        out = out.replace("/", "\\/")
    return out


def _write(v, escape_slash, pretty, level):
    if v is None:
        return "null"
    if isinstance(v, (bool, int, float)):
        return _num(v)
    if isinstance(v, str):
        return _str(v, escape_slash)
    ind = "  " * (level + 1) if pretty else ""
    end = "  " * level if pretty else ""
    if isinstance(v, dict):
        if not v:
            return "{\n\n" + end + "}" if pretty else "{}"
        sep = " : " if pretty else ":"
        items = [ind + _str(str(k), escape_slash) + sep + _write(x, escape_slash, pretty, level + 1)
                 for k, x in v.items()]
        if pretty:
            return "{\n" + ",\n".join(items) + "\n" + end + "}"
        return "{" + ",".join(items) + "}"
    if isinstance(v, (list, tuple)):
        if not v:
            return "[\n\n" + end + "]" if pretty else "[]"
        items = [ind + _write(x, escape_slash, pretty, level + 1) for x in v]
        if pretty:
            return "[\n" + ",\n".join(items) + "\n" + end + "]"
        return "[" + ",".join(items) + "]"
    raise TypeError(type(v))


def apple(v, pretty=False, sort_keys=False, no_slash_escape=False):
    if sort_keys:
        v = _sorted(v)
    return _write(v, not no_slash_escape, pretty, 0)


def swift(v, no_slash_escape=False, sort_keys=False):
    if sort_keys:
        v = _sorted(v)
    return _write(v, not no_slash_escape, False, 0)


def js(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def py(v, indent=None, ensure_ascii=True):
    return json.dumps(v, indent=indent, ensure_ascii=ensure_ascii)


def _sorted(v):
    if isinstance(v, dict):
        return {k: _sorted(v[k]) for k in sorted(v)}
    if isinstance(v, list):
        return [_sorted(x) for x in v]
    return v
