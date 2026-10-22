#!/usr/bin/env python3
"""Writes App/Localizable.xcstrings (English) from the app's string table, Sources/WarzagApp/Model/Strings.swift.

    python3 -I App/strings-catalog.py           regenerate the catalog
    python3 -I App/strings-catalog.py --check   exit 1 if the catalog is out of date

Strings.swift writes every string as String(localized: "<key>", defaultValue: "<English>"). An interpolation \\(value)
becomes %@ (%1$@, %2$@ ... when there are several); the app passes every value as a preformatted string. Translations
in the catalog are kept; only the English units are rewritten. LocalizationCatalogTests checks the same mapping.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/WarzagApp/Model/Strings.swift"
CATALOG = ROOT / "App/Localizable.xcstrings"
ENTRY = re.compile(r'String\(localized:\s*"([^"]+)",\s*defaultValue:\s*"((?:[^"\\]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def english(value: str) -> str:
    count = len(INTERPOLATION.findall(value))
    index = 0

    def placeholder(_match):
        nonlocal index
        index += 1
        return "%@" if count == 1 else f"%{index}$@"

    return INTERPOLATION.sub(placeholder, value).replace('\\"', '"').replace("\\\\", "\\")


def entries() -> dict:
    found = {}
    for key, value in ENTRY.findall(SOURCE.read_text(encoding="utf-8")):
        if key in found and found[key] != english(value):
            sys.exit(f"strings-catalog: key {key} has two different English texts")
        found[key] = english(value)
    return found


def build(existing: dict) -> dict:
    strings = {}
    old = existing.get("strings", {})
    for key, value in sorted(entries().items()):
        entry = old.get(key, {})
        localizations = dict(entry.get("localizations", {}))
        localizations["en"] = {"stringUnit": {"state": "translated", "value": value}}
        strings[key] = {"extractionState": "manual", "localizations": localizations}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def main() -> int:
    args = sys.argv[1:]
    if args in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if args not in ([], ["--check"]):
        print("usage: python3 -I App/strings-catalog.py [--check]", file=sys.stderr)
        return 2
    existing = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else {}
    text = json.dumps(build(existing), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args == ["--check"]:
        if CATALOG.exists() and CATALOG.read_text(encoding="utf-8") == text:
            return 0
        print("strings-catalog: App/Localizable.xcstrings is out of date; run python3 -I App/strings-catalog.py",
              file=sys.stderr)
        return 1
    CATALOG.write_text(text, encoding="utf-8")
    print(f"strings-catalog: {len(json.loads(text)['strings'])} strings -> {CATALOG.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
