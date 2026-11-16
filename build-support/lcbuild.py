#!/usr/bin/env python3
"""Helpers for the Linux/xtool Makefile build of LiveContainer.

Replaces the Xcode-only steps that have no Linux equivalent:
  plist      - expand $(VAR) build settings in an Info.plist / entitlements
               file, merge generated keys, drop keys (Info.plist processing)
  xcstrings  - compile a .xcstrings catalog into <lang>.lproj/Localizable.strings
               (+ .stringsdict for plural variations), like xcstringstool
"""
import argparse
import json
import os
import plistlib
import re
import sys

VAR_RE = re.compile(r"\$[({]([A-Za-z0-9_]+)(?::[a-z0-9]+)?[)}]")

# Keys Apple defines as strings even when the value looks numeric. installd treats a
# numeric CFBundleVersion as missing ("bundleVersion must be set in placeholder
# attributes for an app extension placeholder").
STRING_KEYS = {
    "CFBundleVersion",
    "CFBundleShortVersionString",
    "CFBundleInfoDictionaryVersion",
    "MinimumOSVersion",
}


def expand(obj, env):
    if isinstance(obj, str):
        return VAR_RE.sub(lambda m: env.get(m.group(1), ""), obj)
    if isinstance(obj, list):
        return [expand(x, env) for x in obj]
    if isinstance(obj, dict):
        return {k: expand(v, env) for k, v in obj.items()}
    return obj


def parse_value(key, raw):
    # values given as JSON when they look like JSON, plain strings otherwise
    if key in STRING_KEYS:
        return raw
    if raw[:1] in "[{" or raw in ("true", "false") or re.fullmatch(r"-?\d+", raw):
        return json.loads(raw)
    return raw


def cmd_plist(args):
    env = dict(os.environ)
    for kv in args.var or []:
        k, _, v = kv.partition("=")
        env[k] = v
    data = {}
    if args.input:
        with open(args.input, "rb") as f:
            data = plistlib.load(f)
    # generated keys (GENERATE_INFOPLIST_FILE / INFOPLIST_KEY_*) only fill gaps,
    # explicit --set always wins
    for kv in args.default or []:
        k, _, v = kv.partition("=")
        data.setdefault(k, parse_value(k, v))
    for kv in args.set or []:
        k, _, v = kv.partition("=")
        data[k] = parse_value(k, v)
    for k in args.delete or []:
        data.pop(k, None)
    data = expand(data, env)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML, sort_keys=True)


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def lproj_name(lang):
    return lang  # Xcode keeps BCP-47 names: zh-Hans.lproj, pt-BR.lproj


def plural_dict(variations, spec="lld"):
    d = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
         "NSStringFormatValueTypeKey": spec}
    for cat, e in variations.get("plural", {}).items():
        d[cat] = e["stringUnit"]["value"].replace("%arg", "%" + spec)
    return d


def cmd_xcstrings(args):
    with open(args.input, encoding="utf-8") as f:
        cat = json.load(f)
    src = cat.get("sourceLanguage", "en")
    strings = {}   # lang -> {key: value}
    plurals = {}   # lang -> {key: stringsdict entry}
    for key, entry in cat["strings"].items():
        locs = entry.get("localizations", {})
        if src not in locs and entry.get("shouldTranslate", True):
            # untranslated source string: key is the value
            strings.setdefault(src, {})[key] = key
        for lang, loc in locs.items():
            if "variations" in loc and "plural" in loc["variations"]:
                other = loc["variations"]["plural"].get("other", {}).get("stringUnit", {}).get("value", key)
                m = re.search(r"%(?:\d+\$)?(l{0,2}[dui@fs])", other)
                spec = m.group(1) if m else "lld"
                plurals.setdefault(lang, {})[key] = {
                    "NSStringLocalizedFormatKey": "%#@value@",
                    "value": plural_dict(loc["variations"], spec),
                }
                strings.setdefault(lang, {})[key] = other
            elif "substitutions" in loc:
                fmt = loc.get("stringUnit", {}).get("value", key)
                sd = {"NSStringLocalizedFormatKey": fmt}
                for name, sub in loc["substitutions"].items():
                    spec = sub.get("formatSpecifier", "lld")
                    sd[name] = plural_dict(sub.get("variations", {}), spec)
                    # positional args: %#@arg1@ refers to argNum
                    if "argNum" in sub:
                        sd["NSStringLocalizedFormatKey"] = sd["NSStringLocalizedFormatKey"].replace(
                            "%#@" + name + "@", "%" + str(sub["argNum"]) + "$#@" + name + "@")
                plurals.setdefault(lang, {})[key] = sd
                strings.setdefault(lang, {})[key] = fmt
            elif "stringUnit" in loc:
                strings.setdefault(lang, {})[key] = loc["stringUnit"]["value"]
    for lang, table in strings.items():
        d = os.path.join(args.outdir, lproj_name(lang) + ".lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            for k in sorted(table):
                f.write('"%s" = "%s";\n' % (escape(k), escape(table[k])))
    for lang, table in plurals.items():
        d = os.path.join(args.outdir, lproj_name(lang) + ".lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.stringsdict"), "wb") as f:
            plistlib.dump(table, f, fmt=plistlib.FMT_XML)


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("plist")
    a.add_argument("-i", "--input")
    a.add_argument("-o", "--output", required=True)
    a.add_argument("--var", action="append", help="VAR=value for $(VAR) expansion")
    a.add_argument("--default", action="append", help="KEY=value, only if absent")
    a.add_argument("--set", action="append", help="KEY=value, always")
    a.add_argument("--delete", action="append", help="KEY to remove")
    a.set_defaults(func=cmd_plist)
    b = sp.add_parser("xcstrings")
    b.add_argument("input")
    b.add_argument("outdir")
    b.set_defaults(func=cmd_xcstrings)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
