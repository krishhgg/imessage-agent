"""Minimal reader for NSArchiver typedstream blobs, written for this benchmark.

It handles the subset that Messages uses for attributedBody and for the edit
history in message_summary_info: objects, classes, shared strings, C strings,
integers, floats, length-prefixed byte strings, arrays and structs.
"""

import struct

TAG_INT16 = 0x81
TAG_INT32 = 0x82
TAG_FLOAT = 0x83
TAG_NEW = 0x84
TAG_NIL = 0x85
TAG_END = 0x86
REF_BASE = -110  # 0x92 as a signed byte


class TypedStreamError(ValueError):
    pass


class Obj:
    __slots__ = ("cls", "fields")

    def __init__(self):
        self.cls = None
        self.fields = []

    @property
    def class_name(self):
        return self.cls.name if self.cls else None

    def __repr__(self):
        return "Obj(%s, %r)" % (self.class_name, self.fields)


class Cls:
    __slots__ = ("name", "version", "superclass")

    def __init__(self, name, version):
        self.name = name
        self.version = version
        self.superclass = None


class Reader:
    def __init__(self, data):
        self.b = bytes(data)
        self.p = 0
        self.strings = []
        self.objects = []
        self._header()

    def _byte(self):
        if self.p >= len(self.b):
            raise TypedStreamError("unexpected end of stream")
        v = self.b[self.p]
        self.p += 1
        return v

    def _peek(self):
        if self.p >= len(self.b):
            raise TypedStreamError("unexpected end of stream")
        return self.b[self.p]

    def _take(self, n):
        if self.p + n > len(self.b):
            raise TypedStreamError("unexpected end of stream")
        v = self.b[self.p:self.p + n]
        self.p += n
        return v

    def _int_from(self, head):
        if head == TAG_INT16:
            return struct.unpack("<h", self._take(2))[0]
        if head == TAG_INT32:
            return struct.unpack("<i", self._take(4))[0]
        return head - 256 if head >= 128 else head

    def read_int(self):
        return self._int_from(self._byte())

    def _ref_index(self, head):
        return self._int_from(head) - REF_BASE

    def _header(self):
        version = self._byte()
        n = self._byte()
        sig = self._take(n)
        if sig != b"streamtyped":
            raise TypedStreamError("not a typedstream")
        self.version = version
        self.system_version = self.read_int()

    def read_shared_string(self):
        head = self._byte()
        if head == TAG_NIL:
            return None
        if head == TAG_NEW:
            n = self.read_int()
            s = self._take(n)
            self.strings.append(s)
            return s
        return self.strings[self._ref_index(head)]

    def read_c_string(self):
        head = self._peek()
        if head == TAG_NIL:
            self.p += 1
            return None
        if head == TAG_NEW:
            self.p += 1
            s = self.read_shared_string()
            self.objects.append(s)
            return s
        self.p += 1
        return self.objects[self._ref_index(head)]

    def read_class(self):
        head = self._byte()
        if head == TAG_NIL:
            return None
        if head == TAG_NEW:
            name = self.read_shared_string().decode("utf-8", "replace")
            version = self.read_int()
            cls = Cls(name, version)
            self.objects.append(cls)
            cls.superclass = self.read_class()
            return cls
        return self.objects[self._ref_index(head)]

    def read_object(self):
        head = self._byte()
        if head == TAG_NIL:
            return None
        if head == TAG_NEW:
            obj = Obj()
            self.objects.append(obj)
            obj.cls = self.read_class()
            while self._peek() != TAG_END:
                types = self.read_shared_string()
                obj.fields.extend(self.read_values(types))
            self.p += 1
            return obj
        return self.objects[self._ref_index(head)]

    def read_values(self, types):
        out = []
        i = 0
        t = types.decode("ascii", "replace") if isinstance(types, bytes) else types
        while i < len(t):
            v, i = self._read_one(t, i)
            out.append(v)
        return out

    def _read_one(self, t, i):
        c = t[i]
        if c in "cCsSiIlLqQ":
            return self.read_int(), i + 1
        if c in "fd":
            head = self._byte()
            if head == TAG_FLOAT:
                fmt, n = ("<f", 4) if c == "f" else ("<d", 8)
                return struct.unpack(fmt, self._take(n))[0], i + 1
            return float(self._int_from(head)), i + 1
        if c == "@":
            return self.read_object(), i + 1
        if c == "#":
            return self.read_class(), i + 1
        if c == "*":
            return self.read_c_string(), i + 1
        if c in "%:":
            return self.read_shared_string(), i + 1
        if c == "+":
            n = self.read_int()
            return self._take(n), i + 1
        if c == "[":
            j = i + 1
            while t[j].isdigit():
                j += 1
            count = int(t[i + 1:j])
            end = _matching(t, i, "[", "]")
            inner = t[j:end]
            if inner in ("c", "C"):
                return self._take(count), end + 1
            vals = []
            for _ in range(count):
                vals.extend(self.read_values(inner))
            return vals, end + 1
        if c == "{":
            end = _matching(t, i, "{", "}")
            body = t[i + 1:end]
            eq = body.find("=")
            fields = body[eq + 1:] if eq >= 0 else body
            return self.read_values(fields), end + 1
        raise TypedStreamError("unsupported type %r" % c)


def _matching(t, i, open_c, close_c):
    depth = 0
    for j in range(i, len(t)):
        if t[j] == open_c:
            depth += 1
        elif t[j] == close_c:
            depth -= 1
            if depth == 0:
                return j
    raise TypedStreamError("unbalanced type string")


def _ns_string(obj):
    if isinstance(obj, Obj):
        for f in obj.fields:
            if isinstance(f, bytes):
                return f.decode("utf-8", "replace")
    return None


def _plain(v):
    """Turn NSString, NSNumber, NSDictionary and NSArray objects into Python values."""
    if isinstance(v, Obj):
        name = v.class_name or ""
        if "String" in name and "Attributed" not in name:
            return _ns_string(v)
        if name in ("NSNumber", "NSValue"):
            return v.fields[1] if len(v.fields) > 1 else None
        if "Dictionary" in name:
            return _dict_from(v)
        if "Array" in name:
            return [_plain(x) for x in v.fields[1:]]
        return v
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def _dict_from(obj):
    f = obj.fields
    if not f:
        return {}
    n = f[0]
    out = {}
    for k in range(n):
        key = _plain(f[1 + 2 * k])
        out[key] = _plain(f[2 + 2 * k])
    return out


def read_root(data):
    """Read the first top-level value, which is preceded by its type string."""
    r = Reader(data)
    types = r.read_shared_string()
    vals = r.read_values(types)
    return vals[0] if vals else None


def decode_attributed(data):
    """Return (text, runs) for an archived NS(Mutable)AttributedString.

    runs is a list of (utf16_start, utf16_length, attributes dict).
    """
    root = read_root(data)
    if not isinstance(root, Obj):
        return "", []
    text = None
    runs = []
    pos = 0
    f = root.fields
    k = 0
    while k < len(f):
        v = f[k]
        if text is None and isinstance(v, Obj):
            text = _ns_string(v)
            k += 1
            continue
        if text is not None and isinstance(v, int) and k + 2 < len(f) and isinstance(f[k + 1], int):
            length = f[k + 1]
            attrs = _plain(f[k + 2])
            runs.append((pos, length, attrs if isinstance(attrs, dict) else {}))
            pos += length
            k += 3
            continue
        k += 1
    return text or "", runs


def utf16_slice(s, start, length):
    enc = s.encode("utf-16-le")
    return enc[2 * start:2 * (start + length)].decode("utf-16-le", "replace")
