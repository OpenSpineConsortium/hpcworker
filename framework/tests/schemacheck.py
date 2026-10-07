"""A JSON Schema check for the contract's schemas (interface/contract/*.schema.json), standard library
only, as the suite must run under Python 3.6 on the login node's stack. It knows the keywords the
contract's schemas use and nothing more, and refuses a schema that uses another, so a schema never
says more than every client's check can read: type, enum, const, pattern, minimum, required,
properties, additionalProperties, items, anyOf, allOf, not, $ref (inside the file, "#/$defs/<name>",
or to a schema beside it, "<file>.schema.json"), and the annotations $schema, $id, $defs, title and
description."""
import json
import os
import re

KNOWN = {"type", "enum", "const", "pattern", "minimum", "required", "properties", "additionalProperties", "items",
         "anyOf", "allOf", "not", "$ref", "$schema", "$id", "$defs", "title", "description"}
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def load(folder, name):
    with open(os.path.join(folder, name), encoding="utf-8") as fh:
        return json.load(fh)


def keywords(schema, where="#"):
    """-> the keywords the schema uses that this check does not know, with where they are"""
    bad = []
    if not isinstance(schema, dict):
        return bad
    for k, v in schema.items():
        if k not in KNOWN:
            bad.append("%s/%s" % (where, k))
        if k in ("properties", "$defs"):
            for name, sub in v.items():
                bad += keywords(sub, "%s/%s/%s" % (where, k, name))
        elif k in ("anyOf", "allOf"):
            for i, sub in enumerate(v):
                bad += keywords(sub, "%s/%s/%d" % (where, k, i))
        elif k in ("items", "not", "additionalProperties"):
            bad += keywords(v, "%s/%s" % (where, k))
    return bad


def _type_ok(name, value):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[name])


class Checker(object):
    def __init__(self, folder, name):
        self.folder, self.root = folder, load(folder, name)
        self.others = {name: self.root}

    def _resolve(self, ref, root):
        if ref.startswith("#/$defs/"):
            return root["$defs"][ref[len("#/$defs/"):]], root
        if ref not in self.others:
            self.others[ref] = load(self.folder, ref)
        return self.others[ref], self.others[ref]

    def errors(self, value, schema=None, root=None, at="$"):
        """-> the places where VALUE breaks the schema, each with why; [] when it holds"""
        schema = self.root if schema is None else schema
        root = self.root if root is None else root
        out = []
        if "$ref" in schema:
            sub, sub_root = self._resolve(schema["$ref"], root)
            out += self.errors(value, sub, sub_root, at)
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_type_ok(n, value) for n in names):
                return out + ["%s: %r is not of type %s" % (at, value, "/".join(names))]
        if "enum" in schema and value not in schema["enum"]:
            out.append("%s: %r is not one of %s" % (at, value, schema["enum"]))
        if "const" in schema and value != schema["const"]:
            out.append("%s: %r is not %r" % (at, value, schema["const"]))
        if "pattern" in schema and isinstance(value, str) and not re.search(schema["pattern"], value):
            out.append("%s: %r does not match %s" % (at, value, schema["pattern"]))
        if "minimum" in schema and isinstance(value, (int, float)) and value < schema["minimum"]:
            out.append("%s: %r is below %r" % (at, value, schema["minimum"]))
        if isinstance(value, dict):
            out += self._object(value, schema, root, at)
        if isinstance(value, list) and "items" in schema:
            for i, item in enumerate(value):
                out += self.errors(item, schema["items"], root, "%s[%d]" % (at, i))
        if "anyOf" in schema and not any(not self.errors(value, s, root, at) for s in schema["anyOf"]):
            out.append("%s: matches none of anyOf" % at)
        for s in schema.get("allOf", []):
            out += self.errors(value, s, root, at)
        if "not" in schema and not self.errors(value, schema["not"], root, at):
            out.append("%s: matches what it must not" % at)
        return out

    def _object(self, value, schema, root, at):
        out = ["%s: %s is missing" % (at, k) for k in schema.get("required", []) if k not in value]
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for k, v in value.items():
            if k in props:
                out += self.errors(v, props[k], root, "%s.%s" % (at, k))
            elif extra is False:
                out.append("%s: %s is not allowed" % (at, k))
            elif isinstance(extra, dict):
                out += self.errors(v, extra, root, "%s.%s" % (at, k))
        return out
