#!/usr/bin/env python3
"""The app's string catalog (Transcripts/Localizable.xcstrings): German is the source, written in the code; the other
languages are translations kept here.

  catalog.py sync <stringsdata folder>     add the texts the compiler found, mark the rest stale (extract.sh runs it)
  catalog.py todo <language> <out.json>    what a language still lacks, with the code around each text
  catalog.py merge <language> <in.json>    take translations in: {"key": "text"} or {"key": {"one": …, "other": …}}
  catalog.py check                         format specifiers, plural forms and missing translations, per language

Texts whose comment starts with "plural:" get plural forms (one/other; Polish, Russian and Ukrainian also few/many).
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOG = os.path.join(ROOT, "Transcripts", "Localizable.xcstrings")
CONTEXT = os.path.join(ROOT, "build", "localization", "context.json")
SOURCE = "de"
LANGUAGES = ["en", "fr", "es", "it", "pt-BR", "nl", "pl", "ru", "uk"]
PLURAL_FORMS = {"pl": ["one", "few", "many", "other"], "ru": ["one", "few", "many", "other"],
                "uk": ["one", "few", "many", "other"]}
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(lld|llu|ld|lu|d|u|@|lf|f|s)")


def forms(language):
    return PLURAL_FORMS.get(language, ["one", "other"])


def load():
    if os.path.exists(CATALOG):
        with open(CATALOG, encoding="utf-8") as f:
            return json.load(f)
    return {"sourceLanguage": SOURCE, "strings": {}, "version": "1.0"}


def save(catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items(), key=lambda item: item[0].lower()))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")


def is_plural(entry):
    return entry.get("comment", "").startswith("plural:")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def sync(folder):
    found = {}
    for path in sorted(glob.glob(os.path.join(folder, "*.stringsdata"))):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        source = data.get("source", "")
        if "/Sources/TranscriptsKit/" not in source:
            continue
        lines = open(source, encoding="utf-8").read().split("\n")
        for item in data.get("tables", {}).get("Localizable", []):
            key = item["key"]
            if not re.search(r"[A-Za-zÄÖÜäöüß]", SPECIFIER.sub("", key)):
                continue  # "%@ · %@", "%lld": nothing to translate
            line = item["location"]["startingLine"]
            entry = found.setdefault(key, {"comment": "", "locations": []})
            if item.get("comment"):
                entry["comment"] = item["comment"]
            entry["locations"].append({"file": os.path.relpath(source, ROOT), "line": line,
                                       "code": lines[line - 1].strip()[:240] if line <= len(lines) else ""})
    catalog = load()
    strings = catalog["strings"]
    added = 0
    for key, info in found.items():
        entry = strings.setdefault(key, {})
        if not entry.get("localizations"):
            added += 1
        entry["extractionState"] = "manual"
        if info["comment"]:
            entry["comment"] = info["comment"]
        else:
            entry.pop("comment", None)
        # German, the source: the key itself, or its plural forms.
        localizations = entry.setdefault("localizations", {})
        if not is_plural(entry):
            localizations[SOURCE] = unit(key)
    for key in [key for key in strings if not re.search(r"[A-Za-zÄÖÜäöüß]", SPECIFIER.sub("", key))]:
        del strings[key]
    stale = [key for key in strings if key not in found]
    for key in stale:
        strings[key]["extractionState"] = "stale"
    save(catalog)
    os.makedirs(os.path.dirname(CONTEXT), exist_ok=True)
    with open(CONTEXT, "w", encoding="utf-8") as f:
        json.dump(found, f, ensure_ascii=False, indent=1)
    print(f"{len(found)} texts, {added} new, {len(stale)} stale")


def translated(entry, language):
    localization = entry.get("localizations", {}).get(language)
    if not localization:
        return False
    if is_plural(entry):
        plural = localization.get("variations", {}).get("plural", {})
        return all(form in plural for form in forms(language))
    return "stringUnit" in localization


def todo(language, out):
    catalog = load()
    context = json.load(open(CONTEXT, encoding="utf-8")) if os.path.exists(CONTEXT) else {}
    items = []
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale" or translated(entry, language):
            continue
        item = {"key": key}
        if entry.get("comment"):
            item["comment"] = entry["comment"]
        if is_plural(entry):
            item["plural"] = forms(language)
        item["where"] = [f'{l["file"].split("Sources/TranscriptsKit/")[-1]}:{l["line"]}: {l["code"]}' for l in context.get(key, {}).get("locations", [])][:3]
        items.append(item)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print(f"{language}: {len(items)} to translate → {out}")


def merge(language, path):
    catalog = load()
    strings = catalog["strings"]
    with open(path, encoding="utf-8") as f:
        translations = json.load(f)
    taken, unknown = 0, []
    for key, value in translations.items():
        if key not in strings:
            unknown.append(key)
            continue
        entry = strings[key]
        localizations = entry.setdefault("localizations", {})
        if isinstance(value, dict):
            localizations[language] = {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}
        else:
            localizations[language] = unit(value)
        taken += 1
    save(catalog)
    print(f"{language}: {taken} taken" + (f", {len(unknown)} unknown keys: {unknown[:5]}" if unknown else ""))


def specifiers(text):
    """The arguments a format string takes, in argument order: [(number, type)]."""
    result, position = [], 0
    for match in SPECIFIER.finditer(text.replace("%%", "")):
        if match.group(1):
            number = int(match.group(1))
        else:
            position += 1
            number = position
        kind = {"lld": "int", "ld": "int", "d": "int", "llu": "int", "lu": "int", "u": "int",
                "@": "object", "s": "cstring", "f": "double", "lf": "double"}[match.group(2)]
        result.append((number, kind))
    return sorted(set(result))


def check():
    catalog = load()
    problems, missing = [], {language: 0 for language in [SOURCE] + LANGUAGES}
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            continue
        expected = specifiers(key)
        for language in [SOURCE] + LANGUAGES:
            if not translated(entry, language):
                missing[language] += 1
                continue
            localization = entry["localizations"][language]
            values = ([localization["stringUnit"]["value"]] if "stringUnit" in localization
                      else [v["stringUnit"]["value"] for v in localization["variations"]["plural"].values()])
            for value in values:
                if specifiers(value) != expected and not (is_plural(entry) and value.count("%") == 0 and len(expected) == 1):
                    problems.append(f"{language}: {key!r} → {value!r}")
    for problem in problems:
        print("format:", problem)
    print("missing:", ", ".join(f"{language} {count}" for language, count in missing.items()))
    return not problems and not any(missing.values())


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "sync":
        sync(sys.argv[2])
    elif command == "todo":
        todo(sys.argv[2], sys.argv[3])
    elif command == "merge":
        merge(sys.argv[2], sys.argv[3])
    elif command == "check":
        sys.exit(0 if check() else 1)
    else:
        print(__doc__)
        sys.exit(2)
