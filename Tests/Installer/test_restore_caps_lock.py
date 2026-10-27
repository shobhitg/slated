#!/usr/bin/python3 -I
"""scripts/restore-caps-lock.py against a stand-in hidutil, for every case in caps-lock-cases.json
(HIDRemapper's own tests check the same cases, so install.sh and Slated agree on which Caps Lock
entry is Slated's). Never runs the real hidutil. Run with `make test-scripts` (part of `make check`)."""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "restore-caps-lock.py")
CASES = os.path.join(ROOT, "Tests", "Installer", "caps-lock-cases.json")

# Logs every call to $FAKE_CALLS, prints $FAKE_MAPPINGS for --get as hidutil does, and appends
# --set's argument to $FAKE_SETS.
STAND_IN = """#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "property --get") cat "$FAKE_MAPPINGS" ;;
  "property --set") printf '%s\\n' "$3" >> "$FAKE_SETS" ;;
  *) echo "stand-in hidutil: unexpected $*" >&2; exit 1 ;;
esac
"""


def hidutil_output(mappings):
    """`hidutil property --get UserKeyMapping` as it really prints it."""
    if not mappings:
        return "(null)\n"
    entries = [
        "        {\n        HIDKeyboardModifierMappingDst = %d;\n        HIDKeyboardModifierMappingSrc = %d;\n    }"
        % (dst, src)
        for src, dst in mappings
    ]
    return "(\n" + ",\n".join(entries) + "\n)\n\n"


def run_case(case, work):
    home = os.path.join(work, "home")
    record = os.path.join(home, "Library/Application Support/Slated/caps-lock-mapping.json")
    os.makedirs(os.path.dirname(record))
    if case["recordText"] is not None:
        with open(record, "w", encoding="utf-8") as file:
            file.write(case["recordText"])
    mappings_file, sets_file, calls_file = (os.path.join(work, name) for name in ("mappings", "sets", "calls"))
    with open(mappings_file, "w", encoding="utf-8") as file:
        file.write(hidutil_output(case["current"]))
    bin_dir = os.path.join(work, "bin")
    os.makedirs(bin_dir)
    stand_in = os.path.join(bin_dir, "hidutil")
    with open(stand_in, "w", encoding="utf-8") as file:
        file.write(STAND_IN)
    os.chmod(stand_in, 0o755)
    env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""), FAKE_MAPPINGS=mappings_file,
               FAKE_SETS=sets_file, FAKE_CALLS=calls_file)
    result = subprocess.run(["/usr/bin/python3", "-I", SCRIPT, home], env=env, capture_output=True, text=True)
    problems = []
    if result.returncode != 0:
        problems.append("exited %d: %s" % (result.returncode, result.stderr.strip()))
    sets = open(sets_file, encoding="utf-8").read().splitlines() if os.path.exists(sets_file) else []
    if case["recordText"] is None and os.path.exists(calls_file):
        problems.append("ran hidutil without a record: %s" % open(calls_file, encoding="utf-8").read().split("\n"))
    if case["expected"] is None:
        if sets:
            problems.append("changed hidutil's mapping: %s" % sets)
    else:
        wanted = [
            {"HIDKeyboardModifierMappingSrc": src, "HIDKeyboardModifierMappingDst": dst} for src, dst in case["expected"]
        ]
        got = [json.loads(line)["UserKeyMapping"] for line in sets]
        if got != [wanted]:
            problems.append("set %s, expected %s" % (got, [wanted]))
    if os.path.exists(record):
        problems.append("left the record behind")
    return problems


def main():
    cases = json.load(open(CASES, encoding="utf-8"))["cases"]
    failed = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as work:
            problems = run_case(case, work)
        print(("✘ " if problems else "✔ ") + "restore-caps-lock.py: " + case["name"])
        for problem in problems:
            print("    " + problem)
        failed += bool(problems)
    print("\n%d passed, %d failed" % (len(cases) - failed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
