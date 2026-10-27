#!/usr/bin/python3 -I
"""Puts Caps Lock back after a Slated that didn't quit cleanly (install.sh force-quit it, say).

The same rule as Slated itself (HIDRemapper in Sources/SlatedSystem/HIDRemapper.swift): the Caps Lock
-> F18 entry in hidutil's UserKeyMapping is Slated's only while Slated's record says so
(HOME/Library/Application Support/Slated/caps-lock-mapping.json). Then that entry is removed, the Caps
Lock entry the record says it replaced comes back, every other entry stays, and the record goes.
Without a record nothing is touched: the entry belongs to another tool, and hidutil isn't even run.
Tests/Installer/caps-lock-cases.json holds cases both implementations are checked against.

Usage: restore-caps-lock.py HOME
hidutil is looked up on PATH, so tests can stand one in.
"""

import json
import os
import shutil
import subprocess
import sys

CAPS_LOCK = 0x700000039
F18 = 0x70000006D
SRC = "HIDKeyboardModifierMappingSrc"
DST = "HIDKeyboardModifierMappingDst"


def hidutil(*arguments):
    tool = shutil.which("hidutil") or "/usr/bin/hidutil"
    return subprocess.run([tool, *arguments], capture_output=True, text=True, check=True).stdout


def parse_mappings(output):
    """hidutil prints an old-style plist (numbers come back as strings), or "(null)"."""
    converted = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "-"], input=output, capture_output=True, text=True)
    try:
        entries = json.loads(converted.stdout) if converted.returncode == 0 else []
    except ValueError:
        entries = []
    mappings = []
    for entry in entries if isinstance(entries, list) else []:
        try:
            mappings.append((int(str(entry[SRC]).strip()), int(str(entry[DST]).strip())))
        except (TypeError, KeyError, ValueError):
            continue
    return mappings


def restored(current, record):
    """The mappings to set once Slated's entry goes, or None to leave hidutil alone."""
    if (CAPS_LOCK, F18) not in current:
        return None
    mappings = [m for m in current if m != (CAPS_LOCK, F18)]
    replaced = (record or {}).get("replaced")
    if isinstance(replaced, dict):
        entry = (int(replaced[SRC]), int(replaced[DST]))
        if not any(src == entry[0] for src, _ in mappings):
            mappings.append(entry)
    return mappings


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = os.path.join(sys.argv[1], "Library/Application Support/Slated/caps-lock-mapping.json")
    if not os.path.exists(path):
        return  # Slated's Caps Lock mapping isn't in place
    try:
        with open(path, encoding="utf-8") as file:
            record = json.load(file)
    except (OSError, ValueError):
        record = {}  # present but unreadable: still Slated's entry, with nothing to put back
    if not isinstance(record, dict):
        record = {}
    try:
        mappings = restored(parse_mappings(hidutil("property", "--get", "UserKeyMapping")), record)
        if mappings is not None:
            setting = {"UserKeyMapping": [{SRC: src, DST: dst} for src, dst in mappings]}
            hidutil("property", "--set", json.dumps(setting, separators=(",", ":")))
            print("Put Caps Lock back the way it was before Slated")
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit("Couldn't put Caps Lock back (%s). Restarting the Mac does." % error)
    os.remove(path)


if __name__ == "__main__":
    main()
